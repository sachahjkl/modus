package text_rendering

import "modus:contract/glyph_cache"

// The private glyph cache (src/md/features/text_rendering.md, "The cache"):
// the glyphs that this copy of the package drew, in its own memory, which
// the budget of the process pays. No other process reads it, so its
// content and its evictions tell nothing to another process.
//
// An entry is one glyph: its key (the face, the font of the chain, the
// glyph index in that font, the text size and the position across a
// pixel) and its glyph entry in the form of a glyph cache. Its words take
// one run of blocks: BLOCK_WORDS words split and joined by halves, so a
// glyph is contiguous and a freed run joins its free neighbour. The order
// of use counts in frames: a glyph used in a frame goes to the newest end
// once in that frame, and a new glyph that finds no room evicts from the
// oldest end, never a glyph of the frame in progress. When the glyphs of
// the frame in progress fill the cache, a new glyph is drawn and not kept:
// the frame has the right pixels and costs more time. A glyph that the
// renderer refuses has an entry with no words, so it is not drawn again at
// each frame.
//
// The words of a key are a function of the key and of the font file, so
// an eviction never changes a pixel.

WORD_CAPACITY :: 1 << 18 // The words of the glyphs: 1 MiB.
BLOCK_WORDS :: 32 // The words of the smallest block.
BLOCK_COUNT :: WORD_CAPACITY / BLOCK_WORDS
// The sizes of a run: BLOCK_WORDS << 0 to BLOCK_WORDS << (ORDER_COUNT - 1),
// the largest block. The words are WORD_CAPACITY / GLYPH_WORDS_LIMIT runs
// of the largest block, which never join.
ORDER_COUNT :: 10
#assert(BLOCK_WORDS << (ORDER_COUNT - 1) == GLYPH_WORDS_LIMIT)
#assert(WORD_CAPACITY % GLYPH_WORDS_LIMIT == 0)
LARGEST_RUN_COUNT :: WORD_CAPACITY / GLYPH_WORDS_LIMIT
ENTRY_CAPACITY :: 4096 // The glyphs that the cache holds at most.
BUCKET_BITS :: 13
BUCKET_COUNT :: 1 << BUCKET_BITS // The places of the hash table: twice the entries.
#assert(BUCKET_COUNT == 2 * ENTRY_CAPACITY)
// An index of an entry or a block is stored plus one: 0 is no index, so
// the cache of all zero is empty and valid.
#assert(ENTRY_CAPACITY < 1 << 16 && BLOCK_COUNT < 1 << 16)

// The fields of a key, from bit 0: the face (4 bits), the font of the
// chain (4 bits), the glyph index (16 bits), the text size (16 bits) and
// the position (2 bits). A key is never 0, as a face of a key is never
// None.
KEY_FONT_SHIFT :: 4
KEY_GLYPH_SHIFT :: 8
KEY_SIZE_SHIFT :: 24
KEY_POSITION_SHIFT :: 40
#assert(POSITION_LIMIT <= 1 << 2)

Private_Entry :: struct {
	key:            u64, // key_of; 0: a free entry.
	glyph:          glyph_cache.Glyph_Entry, // word_offset: from the first word of the cache.
	frame:          u64, // The frame of its last use.
	newer, older:   u16, // Its neighbours in the order of use, plus one.
	next_in_bucket: u16, // The next entry of its place in the table, plus one; for a free entry, the next free entry.
	first_block:    u16, // The first block of its words.
	order:          u8, // The size of its run: BLOCK_WORDS << order words.
	has_words:      bool, // A glyph with no ink, and a glyph that the renderer refused, have no words.
	drawn:          bool, // false: the renderer refused its outline: the glyph is Missing.
}

Private_Cache :: struct {
	entries:        [ENTRY_CAPACITY]Private_Entry,
	entries_used:   int, // The entries taken once: the next new entry.
	free_entry:     u16, // The first free entry, plus one.
	buckets:        [BUCKET_COUNT]u16, // The first entry of each place, plus one.
	newest, oldest: u16, // The two ends of the order of use, plus one.
	words:          [WORD_CAPACITY]u32,
	// For the first block of a free run: its order plus one; 0 for each
	// other block.
	free_order:     [BLOCK_COUNT]u8,
	free_next:      [BLOCK_COUNT]u16, // The next free run of its order, plus one.
	free_previous:  [BLOCK_COUNT]u16, // The free run before it, plus one.
	free_heads:     [ORDER_COUNT]u16, // The first free run of each order, plus one.
	words_ready:    bool, // The words are runs of the largest block: the first take makes them.
}

// The glyph memory of a copy: the private glyph cache and the memory of the
// rasterizer, about 1.4 MiB. It is no global: a process receives it at the
// first glyph that needs it (memory_give), so a copy that never draws a
// glyph past the glyph caches pays nothing for it. It starts all zero, as
// the pages of a new memory object do.
Glyph_Memory :: struct {
	cache:  Private_Cache,
	raster: Raster_Memory,
}

// The counts of a private glyph cache, since the start of the process.
Private_Counts :: struct {
	drawn:    u64, // The glyphs drawn into the cache.
	refused:  u64, // The outlines that the renderer refused.
	evicted:  u64, // The glyphs that left the cache: each of an older frame.
	not_kept: u64, // The glyphs drawn and not kept, because the glyphs of their frame filled the cache.
	banded:   u64, // The glyphs drawn band by band: larger than the largest block, or before the copy had its glyph memory.
}

// Cache_State: what stays global of the cache of this copy, 56 bytes: the
// glyph memory once given, and the counts and the flags of the frames.
Cache_State :: struct {
	memory:        ^Glyph_Memory, // nil until memory_give.
	wanted:        bool, // A glyph needed the glyph memory, and the copy had none.
	frame_full:    bool, // The glyphs of the frame in progress fill the cache: frame_begin clears it.
	not_kept_told: bool, // not_kept_report gave its one report.
	counts:        Private_Counts,
}

cache_state: Cache_State

// memory_give makes a memory of the caller the glyph memory of this copy:
// on a machine, pages that display.text_memory_reserve takes from the
// budget of the process; in a host test, memory of the test. The memory
// must be all zero: the cache starts empty. A second give replaces the
// first, which the caller then owns again.
memory_give :: proc "contextless" (memory: ^Glyph_Memory) {
	cache_state.memory = memory
	cache_state.wanted = false
	cache_state.frame_full = false
}

// memory_wanted says if a glyph needed the glyph memory, which the copy has
// not received: the caller reserves it between two frames.
memory_wanted :: proc "contextless" () -> bool {
	return cache_state.wanted && cache_state.memory == nil
}

// key_of gives the key of a glyph. The caller has checked each field
// against its bound: the face, the font and the position are enums or
// below POSITION_LIMIT, the glyph index is a glyph of a font file (16
// bits), the size passed size_check.
GLYPH_INDEX_LIMIT :: 0xFFFF // The largest glyph index of a key.

key_of :: #force_inline proc "contextless" (face: Face, font: Outline_Font, glyph_index, size, position: int) -> u64 {
	return u64(face) | u64(font) << KEY_FONT_SHIFT | (u64(glyph_index) & 0xFFFF) << KEY_GLYPH_SHIFT | (u64(size) & 0xFFFF) << KEY_SIZE_SHIFT | u64(position) << KEY_POSITION_SHIFT
}

@(private)
bucket_of :: #force_inline proc "contextless" (key: u64) -> int {
	return int((key * 0x9E37_79B9_7F4A_7C15) >> (64 - BUCKET_BITS))
}

// counts gives the counts of the private glyph cache of this copy.
counts :: proc "contextless" () -> Private_Counts {
	return cache_state.counts
}

// not_kept_report gives the count of the glyphs drawn and not kept, once:
// report is true at the first call after the first such glyph, and never
// again. The caller writes its one line on the log: this package calls no
// operation of the kernel, so the host tests run it.
not_kept_report :: proc "contextless" () -> (count: u64, report: bool) {
	if cache_state.not_kept_told || cache_state.counts.not_kept == 0 {
		return cache_state.counts.not_kept, false
	}
	cache_state.not_kept_told = true
	return cache_state.counts.not_kept, true
}

// ---- The runs of blocks.

@(private)
free_push :: proc "contextless" (cache: ^Private_Cache, block, order: int) {
	head := cache.free_heads[order]
	cache.free_order[block] = u8(order + 1)
	cache.free_previous[block] = 0
	cache.free_next[block] = head
	if head != 0 {
		cache.free_previous[head - 1] = u16(block + 1)
	}
	cache.free_heads[order] = u16(block + 1)
}

@(private)
free_remove :: proc "contextless" (cache: ^Private_Cache, block, order: int) {
	previous, next := cache.free_previous[block], cache.free_next[block]
	if previous != 0 {
		cache.free_next[previous - 1] = next
	} else {
		cache.free_heads[order] = next
	}
	if next != 0 {
		cache.free_previous[next - 1] = previous
	}
	cache.free_order[block] = 0
	cache.free_previous[block] = 0
	cache.free_next[block] = 0
}

// order_of_words gives the order of the run that holds count words; ok is
// false for no word and past the largest block.
order_of_words :: proc "contextless" (count: int) -> (order: int, ok: bool) {
	if count < 1 || count > GLYPH_WORDS_LIMIT {
		return 0, false
	}
	blocks := (count + BLOCK_WORDS - 1) / BLOCK_WORDS
	for 1 << uint(order) < blocks {
		order += 1
	}
	return order, true
}

// run_take takes a free run of an order: the smallest free run at least as
// large, split by halves. ok is false when no run is that large.
@(private)
run_take :: proc "contextless" (cache: ^Private_Cache, order: int) -> (block: int, ok: bool) {
	if !cache.words_ready {
		cache.words_ready = true
		// From the last run to the first, so that the first take gives the
		// first block.
		for run := LARGEST_RUN_COUNT - 1; run >= 0; run -= 1 {
			free_push(cache, run << uint(ORDER_COUNT - 1), ORDER_COUNT - 1)
		}
	}
	for found in order ..< ORDER_COUNT {
		if cache.free_heads[found] == 0 {
			continue
		}
		block = int(cache.free_heads[found] - 1)
		free_remove(cache, block, found)
		split := found
		for split > order {
			split -= 1
			free_push(cache, block + (1 << uint(split)), split)
		}
		return block, true
	}
	return 0, false
}

// run_give gives back a run, joined with its free neighbour of the same
// size while there is one, up to the largest block.
@(private)
run_give :: proc "contextless" (cache: ^Private_Cache, block_given, order_given: int) {
	block, order := block_given, order_given
	for order < ORDER_COUNT - 1 {
		neighbour := block ~ (1 << uint(order))
		if int(cache.free_order[neighbour]) != order + 1 {
			break
		}
		free_remove(cache, neighbour, order)
		block = min(block, neighbour)
		order += 1
	}
	free_push(cache, block, order)
}

// ---- The entries.

@(private)
order_unlink :: proc "contextless" (cache: ^Private_Cache, index: int) {
	entry := &cache.entries[index]
	if entry.newer != 0 {
		cache.entries[entry.newer - 1].older = entry.older
	} else {
		cache.newest = entry.older
	}
	if entry.older != 0 {
		cache.entries[entry.older - 1].newer = entry.newer
	} else {
		cache.oldest = entry.newer
	}
	entry.newer, entry.older = 0, 0
}

@(private)
order_push_newest :: proc "contextless" (cache: ^Private_Cache, index: int) {
	entry := &cache.entries[index]
	entry.newer = 0
	entry.older = cache.newest
	if cache.newest != 0 {
		cache.entries[cache.newest - 1].newer = u16(index + 1)
	} else {
		cache.oldest = u16(index + 1)
	}
	cache.newest = u16(index + 1)
}

// entry_find gives the index of the entry of a key, or -1. The walk of a
// place ends after ENTRY_CAPACITY entries, whatever the links say.
entry_find :: proc "contextless" (cache: ^Private_Cache, key: u64) -> int {
	next := cache.buckets[bucket_of(key)]
	for _ in 0 ..< ENTRY_CAPACITY {
		if next == 0 {
			return -1
		}
		entry := &cache.entries[next - 1]
		if entry.key == key {
			return int(next - 1)
		}
		next = entry.next_in_bucket
	}
	return -1
}

@(private)
bucket_unlink :: proc "contextless" (cache: ^Private_Cache, index: int) {
	place := &cache.buckets[bucket_of(cache.entries[index].key)]
	if place^ == u16(index + 1) {
		place^ = cache.entries[index].next_in_bucket
		return
	}
	next := place^
	for _ in 0 ..< ENTRY_CAPACITY {
		if next == 0 {
			return
		}
		entry := &cache.entries[next - 1]
		if entry.next_in_bucket == u16(index + 1) {
			entry.next_in_bucket = cache.entries[index].next_in_bucket
			return
		}
		next = entry.next_in_bucket
	}
}

// evict_oldest removes the entry used the longest time ago, and gives back
// its words. false: the cache holds no entry, or its oldest entry is of
// the frame in progress, so each entry is: a glyph of the frame in
// progress is never evicted.
@(private)
evict_oldest :: proc "contextless" (cache: ^Private_Cache, frame: u64) -> bool {
	if cache.oldest == 0 {
		return false
	}
	index := int(cache.oldest - 1)
	entry := &cache.entries[index]
	if entry.frame == frame {
		return false
	}
	order_unlink(cache, index)
	bucket_unlink(cache, index)
	if entry.has_words {
		run_give(cache, int(entry.first_block), int(entry.order))
	}
	cache_state.counts.evicted += 1
	entry^ = {next_in_bucket = cache.free_entry}
	cache.free_entry = u16(index + 1)
	return true
}

// entry_take gives a free entry, out of the table and of the order: a
// free one, a new one, or the oldest, evicted. ok is false when each entry
// holds a glyph of the frame in progress.
@(private)
entry_take :: proc "contextless" (cache: ^Private_Cache, frame: u64) -> (index: int, ok: bool) {
	if cache.free_entry == 0 && cache.entries_used < ENTRY_CAPACITY {
		cache.entries_used += 1
		return cache.entries_used - 1, true
	}
	if cache.free_entry == 0 && !evict_oldest(cache, frame) {
		return 0, false
	}
	index = int(cache.free_entry - 1)
	cache.free_entry = cache.entries[index].next_in_bucket
	cache.entries[index] = {}
	return index, true
}

// entry_give gives back an entry that entry_take gave and that holds no
// glyph: it is in no list.
@(private)
entry_give :: proc "contextless" (cache: ^Private_Cache, index: int) {
	cache.entries[index] = {next_in_bucket = cache.free_entry}
	cache.free_entry = u16(index + 1)
}

// entry_insert puts a new entry in the table and at the newest end.
@(private)
entry_insert :: proc "contextless" (cache: ^Private_Cache, index: int, key: u64, frame: u64) {
	entry := &cache.entries[index]
	entry.key = key
	entry.frame = frame
	place := &cache.buckets[bucket_of(key)]
	entry.next_in_bucket = place^
	place^ = u16(index + 1)
	order_push_newest(cache, index)
}

// entry_touch notes a use of an entry: it goes to the newest end once in
// each frame.
@(private)
entry_touch :: proc "contextless" (cache: ^Private_Cache, index: int, frame: u64) {
	entry := &cache.entries[index]
	if entry.frame == frame {
		return
	}
	entry.frame = frame
	order_unlink(cache, index)
	order_push_newest(cache, index)
}

// words_take gives a run for count words, evicting from the oldest end
// until one is free. The entry that the caller holds is in no list, so it
// is never evicted. ok is false when only glyphs of the frame in progress
// are left and no run is free.
@(private)
words_take :: proc "contextless" (cache: ^Private_Cache, count: int, frame: u64) -> (block, order: int, ok: bool) {
	order = order_of_words(count) or_return
	for _ in 0 ..= ENTRY_CAPACITY {
		if block, ok = run_take(cache, order); ok {
			return block, order, true
		}
		if !evict_oldest(cache, frame) {
			break
		}
	}
	return 0, 0, false
}

// not_kept_glyph gives the words of a glyph that the render memory holds,
// drawn and not kept, and counts it. Its rows move to the start of the
// words, entry.width words each, as in the cache: a row moves to a place
// at or before its own, after the rows before it, so no row that is still
// to move is written.
@(private)
not_kept_glyph :: proc "contextless" (box: Raster_Box) -> (entry: glyph_cache.Glyph_Entry, words: [^]u32, source: Glyph_Source) {
	raster := &cache_state.memory.raster
	cache_state.frame_full = true
	cache_state.counts.not_kept += 1
	for row in 0 ..< box.row_count {
		copy(raster.words[row * box.width:][:box.width], raster.words[box.first_word + row * box.stride:][:box.width])
	}
	return {first_row = u16(box.first_row), row_count = u16(box.row_count), left = i16(box.left), width = u16(box.width)}, raw_data(raster.words[:]), .Not_Kept
}

// private_glyph gives the glyph of a key from the private glyph cache, and
// draws it there at its first use.
@(private)
private_glyph :: proc "contextless" (face: Face, font: Outline_Font, glyph_index, size, position: int) -> (entry: glyph_cache.Glyph_Entry, words: [^]u32, source: Glyph_Source) {
	// The key holds 16 bits of the glyph index: a larger index, which no
	// font file of TrueType gives, would be the key of another glyph.
	if glyph_index < 0 || glyph_index > GLYPH_INDEX_LIMIT {
		return {}, nil, .Missing
	}
	// No glyph memory yet: the glyph is drawn band by band through the
	// small band of the copy, with the right pixels, and the caller
	// reserves the memory before the next frame.
	if cache_state.memory == nil {
		cache_state.wanted = true
		cache_state.counts.banded += 1
		return {}, nil, .Banded
	}
	cache := &cache_state.memory.cache
	raster := &cache_state.memory.raster
	key := key_of(face, font, glyph_index, size, position)
	if index := entry_find(cache, key); index >= 0 {
		entry_touch(cache, index, state.frame)
		found := &cache.entries[index]
		if !found.drawn {
			return {}, nil, .Missing
		}
		return found.glyph, ([^]u32)(&cache.words[found.glyph.word_offset]), .Private_Cache
	}
	box, problem := glyph_raster(face, font, glyph_index, size, position)
	switch problem {
	case .Too_Large, .No_Memory:
		cache_state.counts.banded += 1
		return {}, nil, .Banded
	case .Refused, .None:
	}
	drawn := problem == .None
	count := box.row_count * box.width
	// A frame whose glyphs fill the cache draws each other new glyph and
	// keeps none: no search for room that cannot succeed.
	if cache_state.frame_full && drawn && count > 0 {
		return not_kept_glyph(box)
	}
	index, taken := entry_take(cache, state.frame)
	if !taken {
		if !drawn {
			cache_state.counts.refused += 1
			return {}, nil, .Missing
		}
		return not_kept_glyph(box)
	}
	if !drawn {
		cache_state.counts.refused += 1
	} else if count > 0 {
		block, order, has_room := words_take(cache, count, state.frame)
		if !has_room {
			entry_give(cache, index)
			return not_kept_glyph(box)
		}
		offset := block * BLOCK_WORDS
		for row in 0 ..< box.row_count {
			copy(cache.words[offset + row * box.width:][:box.width], raster.words[box.first_word + row * box.stride:][:box.width])
		}
		cache.entries[index].has_words = true
		cache.entries[index].first_block = u16(block)
		cache.entries[index].order = u8(order)
		cache.entries[index].glyph = {first_row = u16(box.first_row), row_count = u16(box.row_count), word_offset = u32(offset), left = i16(box.left), width = u16(box.width)}
	}
	cache.entries[index].drawn = drawn
	entry_insert(cache, index, key, state.frame)
	if !drawn {
		return {}, nil, .Missing
	}
	cache_state.counts.drawn += 1
	return cache.entries[index].glyph, ([^]u32)(&cache.words[cache.entries[index].glyph.word_offset]), .Private_Cache
}
