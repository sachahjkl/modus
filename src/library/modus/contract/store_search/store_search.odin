// Freestanding, zero-allocation commit-driven bigram store search index
// (src/md/data/performance_primitives.md).
//
// Maps all 65,536 ASCII-lowered byte pairs through a 32-bit Fibonacci mix into
// 4,096 inverted bitset buckets covering up to 256 files per subtree. Queries
// intersect their bigram buckets in O(|query|) word-AND operations to skip
// non-matching files before verifying exact ASCII case-insensitive matches on
// surviving candidates, guaranteeing 0% false negatives for every non-empty
// query (including 1-byte queries and arbitrary binary or UTF-8 content).
//
// Each Bigram_Index is keyed by the canonical 32-byte tree_hash of its
// immutable subtree. Across commits, Subtree_Index_Cache reuses unchanged
// subtrees in O(1) with no file watcher and reindexes only subtrees whose
// tree_hash changed.
package store_search

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/byte_order"

// Number of inverted bigram buckets per subtree index.
BIGRAM_BUCKET_COUNT :: 4096

// Number of 64-bit words in a per-file bigram signature (4,096 bits = 512 bytes).
SIGNATURE_WORDS :: BIGRAM_BUCKET_COUNT / 64

// Maximum number of files indexed by one subtree Bigram_Index.
MAX_FILES_PER_SUBTREE :: 256

// Number of 64-bit words in one subtree file bitset.
FILE_MASK_WORDS :: MAX_FILES_PER_SUBTREE / 64

// Bounded O(1) probe window for Subtree_Index_Cache lookup and eviction.
CACHE_PROBE_WINDOW :: 8

// 32-bit golden-ratio multiplier dispersing ASCII text bigrams across all 4,096 buckets.
@(private)
BIGRAM_HASH_MULTIPLIER :: u32(0x9E37_79B1)

#assert(BIGRAM_BUCKET_COUNT == 4096)
#assert(SIGNATURE_WORDS == 64)
#assert(FILE_MASK_WORDS == 4)

// Bitset identifying a subset of files inside one Bigram_Index.
File_Bitset :: [FILE_MASK_WORDS]u64

// Compact 4,096-bit bigram signature extracted from one file's bytes.
File_Bigram_Signature :: struct {
	words: [SIGNATURE_WORDS]u64,
}

// Inverted bigram index for one content-addressed subtree (up to 256 files).
Bigram_Index :: struct {
	tree_hash:   blake3.Hash,
	file_count:  u16,
	file_hashes: [MAX_FILES_PER_SUBTREE]blake3.Hash,
	postings:    [BIGRAM_BUCKET_COUNT]File_Bitset,
}

// One verified content match within a subtree index.
Search_Match :: struct {
	file_index:  u16,
	byte_offset: u32,
}

// Closed set of refusals returned by store search indexing and query routines.
Search_Refusal :: enum u8 {
	None                   = 0,
	Empty_Query            = 1,
	Nil_Index              = 2,
	Too_Many_Files         = 3,
	Zero_Tree_Hash         = 4,
	Content_Count_Mismatch = 5,
	Cache_Nil              = 6,
	Cache_Empty            = 7,
}

// One slot in a caller-supplied Subtree_Index_Cache.
Subtree_Cache_Slot :: struct {
	occupied:   bool,
	referenced: bool,
	index:      Bigram_Index,
}

// Fixed-capacity O(1) cache of subtree Bigram_Index entries keyed by tree_hash.
Subtree_Index_Cache :: struct {
	slots:           []Subtree_Cache_Slot,
	clock_hand:      u32,
	cache_hits:      u64,
	reindexed_count: u64,
}

// lower_ascii_byte folds ASCII uppercase letters 'A'..'Z' to 'a'..'z' and
// leaves every other byte (including non-ASCII UTF-8 and binary bytes) unchanged.
lower_ascii_byte :: #force_inline proc "contextless" (value: u8) -> u8 {
	if value >= 'A' && value <= 'Z' {
		return value + ('a' - 'A')
	}
	return value
}

// bigram_code packs two ASCII-lowered consecutive bytes into a 16-bit pair.
bigram_code :: #force_inline proc "contextless" (first, second: u8) -> u16 {
	return (u16(lower_ascii_byte(first)) << 8) | u16(lower_ascii_byte(second))
}

@(private)
bigram_bucket_lowered :: #force_inline proc "contextless" (first_lowered, second_lowered: u8) -> u16 {
	code := (u32(first_lowered) << 8) | u32(second_lowered)
	return u16((code * BIGRAM_HASH_MULTIPLIER) >> 20)
}

// bigram_bucket maps an ASCII-lowered byte pair to its inverted-index bucket
// in 0 ..< BIGRAM_BUCKET_COUNT.
bigram_bucket :: #force_inline proc "contextless" (first, second: u8) -> u16 {
	return bigram_bucket_lowered(lower_ascii_byte(first), lower_ascii_byte(second))
}

@(private)
hash_is_zero :: proc "contextless" (value: blake3.Hash) -> bool {
	accumulated: u8 = 0
	for b in value {
		accumulated |= b
	}
	return accumulated == 0
}

@(private)
hashes_equal :: proc "contextless" (left, right: blake3.Hash) -> bool {
	for index in 0 ..< blake3.HASH_SIZE {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

// index_build_for_file scans content once and extracts its 4,096-bit
// ASCII-lowered bigram signature. Handles empty, 1-byte, UTF-8, and binary
// inputs without allocation.
index_build_for_file :: proc "contextless" (content: []u8) -> (signature: File_Bigram_Signature) {
	if len(content) < 2 {
		return
	}
	previous := lower_ascii_byte(content[0])
	for index in 1 ..< len(content) {
		current := lower_ascii_byte(content[index])
		bucket := bigram_bucket_lowered(previous, current)
		signature.words[bucket >> 6] |= u64(1) << (bucket & 63)
		previous = current
	}
	return
}

// signature_may_contain_query returns false only when signature is missing at
// least one bigram of query (0% false negatives). Returns true for 1-byte
// queries because a single byte produces no bigram.
signature_may_contain_query :: proc "contextless" (signature: ^File_Bigram_Signature, query: []u8) -> bool {
	if signature == nil || len(query) == 0 {
		return false
	}
	if len(query) < 2 {
		return true
	}
	previous := lower_ascii_byte(query[0])
	for index in 1 ..< len(query) {
		current := lower_ascii_byte(query[index])
		bucket := bigram_bucket_lowered(previous, current)
		if (signature.words[bucket >> 6] & (u64(1) << (bucket & 63))) == 0 {
			return false
		}
		previous = current
	}
	return true
}

// index_reset clears index and binds it to the non-zero content-addressed
// subtree_hash.
index_reset :: proc "contextless" (index: ^Bigram_Index, subtree_hash: blake3.Hash) -> Search_Refusal {
	if index == nil {
		return .Nil_Index
	}
	if hash_is_zero(subtree_hash) {
		return .Zero_Tree_Hash
	}
	index^ = {}
	index.tree_hash = subtree_hash
	return .None
}

// index_add_file_signature transposes a precomputed File_Bigram_Signature into
// the inverted postings of index for the next file slot.
index_add_file_signature :: proc "contextless" (
	index: ^Bigram_Index,
	file_hash: blake3.Hash,
	signature: ^File_Bigram_Signature,
) -> (file_index: u16, refusal: Search_Refusal) {
	if index == nil {
		return 0, .Nil_Index
	}
	if int(index.file_count) >= MAX_FILES_PER_SUBTREE {
		return 0, .Too_Many_Files
	}
	slot := index.file_count
	index.file_hashes[slot] = file_hash
	if signature != nil {
		word_slot := slot >> 6
		bit_mask := u64(1) << (slot & 63)
		for word_index in 0 ..< SIGNATURE_WORDS {
			bits := signature.words[word_index]
			for bits != 0 {
				trailing := intrinsics.count_trailing_zeros(bits)
				bucket := (u32(word_index) << 6) | u32(trailing)
				index.postings[bucket][word_slot] |= bit_mask
				bits &= bits - 1
			}
		}
	}
	index.file_count = slot + 1
	return slot, .None
}

// index_add_file extracts the bigram signature of content and adds the file to
// index in one call.
index_add_file :: proc "contextless" (
	index: ^Bigram_Index,
	file_hash: blake3.Hash,
	content: []u8,
) -> (file_index: u16, refusal: Search_Refusal) {
	signature := index_build_for_file(content)
	return index_add_file_signature(index, file_hash, &signature)
}

// index_candidate_mask intersects the inverted posting bitsets for every
// adjacent byte pair in query. Returns all indexed files for 1-byte queries so
// no match is ever missed.
index_candidate_mask :: proc "contextless" (index: ^Bigram_Index, query: []u8) -> (candidates: File_Bitset, refusal: Search_Refusal) {
	if index == nil {
		return {}, .Nil_Index
	}
	if len(query) == 0 {
		return {}, .Empty_Query
	}
	count := int(index.file_count)
	if count > MAX_FILES_PER_SUBTREE {
		return {}, .Too_Many_Files
	}
	for word_index in 0 ..< FILE_MASK_WORDS {
		start := word_index * 64
		if start >= count {
			candidates[word_index] = 0
		} else if start + 64 <= count {
			candidates[word_index] = max(u64)
		} else {
			candidates[word_index] = (u64(1) << uint(count - start)) - 1
		}
	}
	if count == 0 || len(query) < 2 {
		return candidates, .None
	}
	previous := lower_ascii_byte(query[0])
	for index_in_query in 1 ..< len(query) {
		current := lower_ascii_byte(query[index_in_query])
		bucket := bigram_bucket_lowered(previous, current)
		previous = current
		posting := index.postings[bucket]
		remaining: u64 = 0
		for word_index in 0 ..< FILE_MASK_WORDS {
			candidates[word_index] &= posting[word_index]
			remaining |= candidates[word_index]
		}
		if remaining == 0 {
			break
		}
	}
	return candidates, .None
}

// find_case_insensitive locates the first ASCII case-insensitive occurrence of
// needle inside haystack. Works on arbitrary UTF-8 and binary byte slices.
find_case_insensitive :: proc "contextless" (haystack: []u8, needle: []u8) -> (offset: int, found: bool) {
	needle_length := len(needle)
	haystack_length := len(haystack)
	if needle_length == 0 || needle_length > haystack_length {
		return 0, false
	}
	first := lower_ascii_byte(needle[0])
	if needle_length == 1 {
		for index in 0 ..< haystack_length {
			if lower_ascii_byte(haystack[index]) == first {
				return index, true
			}
		}
		return 0, false
	}
	last := lower_ascii_byte(needle[needle_length - 1])
	limit := haystack_length - needle_length
	outer: for start := 0; start <= limit; start += 1 {
		if lower_ascii_byte(haystack[start]) != first {
			continue
		}
		if lower_ascii_byte(haystack[start + needle_length - 1]) != last {
			continue
		}
		for inner in 1 ..< needle_length - 1 {
			if lower_ascii_byte(haystack[start + inner]) != lower_ascii_byte(needle[inner]) {
				continue outer
			}
		}
		return start, true
	}
	return 0, false
}

// index_search_content filters candidate files through the bigram inverted
// index first and verifies exact ASCII case-insensitive matches only on
// surviving candidates. Records up to len(results) matches while returning the
// total match_count and exact number of candidates_checked.
index_search_content :: proc "contextless" (
	index: ^Bigram_Index,
	file_contents: [][]u8,
	query: []u8,
	results: []Search_Match,
) -> (match_count: int, candidates_checked: int, refusal: Search_Refusal) {
	if index == nil {
		return 0, 0, .Nil_Index
	}
	if len(query) == 0 {
		return 0, 0, .Empty_Query
	}
	count := int(index.file_count)
	if count > MAX_FILES_PER_SUBTREE {
		return 0, 0, .Too_Many_Files
	}
	if len(file_contents) < count {
		return 0, 0, .Content_Count_Mismatch
	}
	candidates, mask_refusal := index_candidate_mask(index, query)
	if mask_refusal != .None {
		return 0, 0, mask_refusal
	}
	for word_index in 0 ..< FILE_MASK_WORDS {
		bits := candidates[word_index]
		for bits != 0 {
			trailing := int(intrinsics.count_trailing_zeros(bits))
			file_index := word_index * 64 + trailing
			bits &= bits - 1
			candidates_checked += 1
			if byte_offset, matched := find_case_insensitive(file_contents[file_index], query); matched {
				if match_count < len(results) {
					results[match_count] = Search_Match {
						file_index  = u16(file_index),
						byte_offset = u32(byte_offset),
					}
				}
				match_count += 1
			}
		}
	}
	return match_count, candidates_checked, .None
}

// cache_init prepares a Subtree_Index_Cache over caller-supplied slots.
cache_init :: proc "contextless" (cache: ^Subtree_Index_Cache, slots: []Subtree_Cache_Slot) -> Search_Refusal {
	if cache == nil {
		return .Cache_Nil
	}
	if len(slots) == 0 {
		return .Cache_Empty
	}
	for &slot in slots {
		slot.occupied = false
		slot.referenced = false
	}
	cache.slots = slots
	cache.clock_hand = 0
	cache.cache_hits = 0
	cache.reindexed_count = 0
	return .None
}

@(private)
cache_home_slot :: #force_inline proc "contextless" (tree_hash: blake3.Hash, slot_count: int) -> int {
	copy_hash := tree_hash
	prefix := byte_order.read_u64_little_endian(copy_hash[:], 0)
	return int(prefix % u64(slot_count))
}

// index_reuse_subtree checks in O(1) whether cache already holds a built
// Bigram_Index for new_tree_hash. On hit, increments cache_hits and returns
// the existing index directly without reindexing any file in that subtree.
index_reuse_subtree :: proc "contextless" (
	cache: ^Subtree_Index_Cache,
	new_tree_hash: blake3.Hash,
) -> (reused: ^Bigram_Index, hit: bool) {
	if cache == nil || len(cache.slots) == 0 || hash_is_zero(new_tree_hash) {
		return nil, false
	}
	slot_count := len(cache.slots)
	home := cache_home_slot(new_tree_hash, slot_count)
	window := min(slot_count, CACHE_PROBE_WINDOW)
	for step in 0 ..< window {
		place := (home + step) % slot_count
		slot := &cache.slots[place]
		if slot.occupied && hashes_equal(slot.index.tree_hash, new_tree_hash) {
			slot.referenced = true
			cache.cache_hits += 1
			return &slot.index, true
		}
	}
	return nil, false
}

// index_acquire_subtree_slot reserves and resets a cache slot for a new or
// changed subtree_hash in O(1), evicting an unreferenced slot inside the probe
// window when needed, and increments reindexed_count.
index_acquire_subtree_slot :: proc "contextless" (
	cache: ^Subtree_Index_Cache,
	subtree_hash: blake3.Hash,
) -> (index: ^Bigram_Index, refusal: Search_Refusal) {
	if cache == nil {
		return nil, .Cache_Nil
	}
	if len(cache.slots) == 0 {
		return nil, .Cache_Empty
	}
	if hash_is_zero(subtree_hash) {
		return nil, .Zero_Tree_Hash
	}
	slot_count := len(cache.slots)
	home := cache_home_slot(subtree_hash, slot_count)
	window := min(slot_count, CACHE_PROBE_WINDOW)

	// Reuse existing matching slot or take the first unoccupied slot in window.
	chosen := -1
	for step in 0 ..< window {
		place := (home + step) % slot_count
		slot := &cache.slots[place]
		if !slot.occupied || hashes_equal(slot.index.tree_hash, subtree_hash) {
			chosen = place
			break
		}
	}
	if chosen < 0 {
		// Second-chance clock eviction inside the bounded probe window.
		start_step := int(cache.clock_hand % u32(window))
		for pass in 0 ..< 2 {
			for offset in 0 ..< window {
				step := (start_step + offset) % window
				place := (home + step) % slot_count
				if pass == 0 && cache.slots[place].referenced {
					cache.slots[place].referenced = false
					continue
				}
				chosen = place
				cache.clock_hand = u32((step + 1) % window)
				break
			}
			if chosen >= 0 {
				break
			}
		}
	}

	target := &cache.slots[chosen]
	target.occupied = true
	target.referenced = true
	_ = index_reset(&target.index, subtree_hash)
	cache.reindexed_count += 1
	return &target.index, .None
}
