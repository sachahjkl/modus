#+build !freestanding
package store_search

import "core:fmt"
import "core:testing"
import "core:time"
import "modus:contract/blake3"
import "modus:contract/tree_hash"

MEASURE :: #config(MEASURE, false)

@(private = "file")
brute_force_search :: proc(file_contents: [][]u8, query: []u8, results: []Search_Match) -> int {
	count := 0
	for content, file_index in file_contents {
		if offset, ok := find_case_insensitive(content, query); ok {
			if count < len(results) {
				results[count] = Search_Match {
					file_index  = u16(file_index),
					byte_offset = u32(offset),
				}
			}
			count += 1
		}
	}
	return count
}

@(private = "file")
make_synthetic_repo :: proc(file_count: int) -> [][]u8 {
	files := make([][]u8, file_count)
	modules := [?]string{"kernel", "storage", "compositor", "console", "network", "quic", "draw_table", "powerbox", "debugger", "remote_display"}
	verbs := [?]string{"validate", "encode", "decode", "commit", "schedule", "present", "verify", "revoke", "connect", "flush"}
	nouns := [?]string{"handle", "budget", "ring", "region", "surface", "record", "block", "frame", "grant", "snapshot"}

	for index in 0 ..< file_count {
		buf := make([dynamic]u8, 0, 4096)
		header := fmt.tprintf("// synthetic file %03d module %s\npackage %s\n\n", index, modules[index % len(modules)], modules[index % len(modules)])
		append(&buf, ..transmute([]u8)header)
		for line in 0 ..< 45 {
			m := modules[(index + line * 3) % len(modules)]
			v := verbs[(index * 5 + line) % len(verbs)]
			n := nouns[(index * 7 + line * 2) % len(nouns)]
			text := fmt.tprintf("%s_%s_%s :: proc() {{ /* line %d of file %d */ }}\n", m, v, n, line, index)
			append(&buf, ..transmute([]u8)text)
		}
		// Inject sparse unique needles into specific files.
		if index == 17 || index == 143 {
			append(&buf, ..transmute([]u8)string("Unique_BinaryFuse_Needle_Alpha_99\n"))
		}
		if index == 88 {
			append(&buf, ..transmute([]u8)string("Multi Word Kernel Ring Completion Query\n"))
		}
		if index == 199 {
			// Include UTF-8 and raw binary bytes (non-UTF-8).
			raw := [?]u8{0x00, 0xFF, 0xFE, 0x80, 'B', 'i', 'n', 'X', 0xC3, 0xA9, 0x00, 0x7F}
			append(&buf, ..raw[:])
		}
		files[index] = buf[:]
	}
	return files
}

@(private = "file")
free_synthetic_repo :: proc(files: [][]u8) {
	for f in files {
		delete(f)
	}
	delete(files)
}

@(test)
refusals_and_boundary_capacities :: proc(t: ^testing.T) {
	// Nil index and zero hash refusals.
	testing.expect_value(t, index_reset(nil, blake3.hash(transmute([]u8)string("tree"))), Search_Refusal.Nil_Index)
	index := new(Bigram_Index)
	defer free(index)
	zero_hash: blake3.Hash
	testing.expect_value(t, index_reset(index, zero_hash), Search_Refusal.Zero_Tree_Hash)

	valid_hash := blake3.hash(transmute([]u8)string("subtree-root"))
	testing.expect_value(t, index_reset(index, valid_hash), Search_Refusal.None)

	// Empty query refused.
	matches: [8]Search_Match
	_, _, r_empty := index_search_content(index, nil, nil, matches[:])
	testing.expect_value(t, r_empty, Search_Refusal.Empty_Query)

	// Nil index refused on search and add.
	_, r_add_nil := index_add_file(nil, valid_hash, transmute([]u8)string("abc"))
	testing.expect_value(t, r_add_nil, Search_Refusal.Nil_Index)
	_, _, r_search_nil := index_search_content(nil, nil, transmute([]u8)string("a"), matches[:])
	testing.expect_value(t, r_search_nil, Search_Refusal.Nil_Index)

	// Empty index (0 files) searches cleanly with 0 matches and 0 candidates checked.
	m0, c0, r0 := index_search_content(index, nil, transmute([]u8)string("hello"), matches[:])
	testing.expect_value(t, r0, Search_Refusal.None)
	testing.expect_value(t, m0, 0)
	testing.expect_value(t, c0, 0)

	// Exact bound: 256 files succeed; 257th file refused with Too_Many_Files.
	contents := make([][]u8, MAX_FILES_PER_SUBTREE)
	defer delete(contents)
	sample := transmute([]u8)string("alpha beta gamma")
	for i in 0 ..< MAX_FILES_PER_SUBTREE {
		contents[i] = sample
		slot, r_add := index_add_file(index, valid_hash, sample)
		testing.expect_value(t, r_add, Search_Refusal.None)
		testing.expect_value(t, slot, u16(i))
	}
	_, r_over := index_add_file(index, valid_hash, sample)
	testing.expect_value(t, r_over, Search_Refusal.Too_Many_Files)

	// Content slice shorter than indexed file count refused.
	_, _, r_mismatch := index_search_content(index, contents[:MAX_FILES_PER_SUBTREE - 1], transmute([]u8)string("beta"), matches[:])
	testing.expect_value(t, r_mismatch, Search_Refusal.Content_Count_Mismatch)

	// Bounded results buffer reports full match_count without overflowing results.
	tiny_results: [2]Search_Match
	total_matches, _, r_ok := index_search_content(index, contents, transmute([]u8)string("BETA"), tiny_results[:])
	testing.expect_value(t, r_ok, Search_Refusal.None)
	testing.expect_value(t, total_matches, MAX_FILES_PER_SUBTREE)
	testing.expect_value(t, tiny_results[0].file_index, u16(0))
	testing.expect_value(t, tiny_results[1].file_index, u16(1))

	// Cache nil / empty / zero-hash refusals.
	cache: Subtree_Index_Cache
	testing.expect_value(t, cache_init(nil, nil), Search_Refusal.Cache_Nil)
	testing.expect_value(t, cache_init(&cache, nil), Search_Refusal.Cache_Empty)
	reused_nil, hit_nil := index_reuse_subtree(nil, valid_hash)
	testing.expect(t, reused_nil == nil && !hit_nil)
	_, r_acq_nil := index_acquire_subtree_slot(nil, valid_hash)
	testing.expect_value(t, r_acq_nil, Search_Refusal.Cache_Nil)
	_, r_acq_empty := index_acquire_subtree_slot(&cache, valid_hash)
	testing.expect_value(t, r_acq_empty, Search_Refusal.Cache_Empty)
}

@(test)
query_edges_and_binary_non_utf8_content :: proc(t: ^testing.T) {
	// Per-file signature checks on 0-byte, 1-byte, 2-byte, and binary content.
	sig_empty := index_build_for_file(nil)
	testing.expect(t, !signature_may_contain_query(&sig_empty, nil))
	testing.expect(t, signature_may_contain_query(&sig_empty, transmute([]u8)string("a")))
	testing.expect(t, !signature_may_contain_query(&sig_empty, transmute([]u8)string("ab")))

	sig_one := index_build_for_file(transmute([]u8)string("X"))
	testing.expect(t, signature_may_contain_query(&sig_one, transmute([]u8)string("x")))
	testing.expect(t, !signature_may_contain_query(&sig_one, transmute([]u8)string("xy")))

	binary_bytes := [?]u8{0x00, 0xFF, 0xFE, 0x80, 'Q', 'z', 0xC3, 0xA9, 0x01}
	sig_bin := index_build_for_file(binary_bytes[:])
	testing.expect(t, signature_may_contain_query(&sig_bin, []u8{0xFF, 0xFE}))
	testing.expect(t, signature_may_contain_query(&sig_bin, transmute([]u8)string("qZ")))
	testing.expect(t, signature_may_contain_query(&sig_bin, []u8{0xC3, 0xA9}))

	index := new(Bigram_Index)
	defer free(index)
	_ = index_reset(index, blake3.hash(transmute([]u8)string("edge-subtree")))

	f0 := transmute([]u8)string("")
	f1 := transmute([]u8)string("Z")
	f2 := transmute([]u8)string("ab")
	f3 := transmute([]u8)string("Hello World From Modus Store")
	f4 := binary_bytes[:]
	files := [?][]u8{f0, f1, f2, f3, f4}
	for content in files {
		_, r := index_add_file(index, blake3.hash(content), content)
		testing.expect_value(t, r, Search_Refusal.None)
	}

	results: [8]Search_Match

	// 1-byte query checks all files and finds case-insensitive 'z' in f1 and f4.
	m1, c1, r1 := index_search_content(index, files[:], transmute([]u8)string("z"), results[:])
	testing.expect_value(t, r1, Search_Refusal.None)
	testing.expect_value(t, c1, len(files))
	testing.expect_value(t, m1, 2)
	testing.expect_value(t, results[0].file_index, u16(1))
	testing.expect_value(t, results[1].file_index, u16(4))

	// 2-byte bigram query finds "AB" in f2.
	m2, _, r2 := index_search_content(index, files[:], transmute([]u8)string("AB"), results[:])
	testing.expect_value(t, r2, Search_Refusal.None)
	testing.expect_value(t, m2, 1)
	testing.expect_value(t, results[0].file_index, u16(2))
	testing.expect_value(t, results[0].byte_offset, u32(0))

	// Multi-word query finds case-insensitive match in f3.
	m3, _, r3 := index_search_content(index, files[:], transmute([]u8)string("world from modus"), results[:])
	testing.expect_value(t, r3, Search_Refusal.None)
	testing.expect_value(t, m3, 1)
	testing.expect_value(t, results[0].file_index, u16(3))
	testing.expect_value(t, results[0].byte_offset, u32(6))

	// Binary non-UTF-8 query finds exact byte sequence in f4.
	m4, _, r4 := index_search_content(index, files[:], []u8{0xFF, 0xFE, 0x80}, results[:])
	testing.expect_value(t, r4, Search_Refusal.None)
	testing.expect_value(t, m4, 1)
	testing.expect_value(t, results[0].file_index, u16(4))
	testing.expect_value(t, results[0].byte_offset, u32(1))
}

@(test)
commit_driven_tree_hash_subtree_reuse :: proc(t: ^testing.T) {
	SUBTREE_COUNT :: 8
	slots := make([]Subtree_Cache_Slot, 32)
	defer delete(slots)
	cache: Subtree_Index_Cache
	testing.expect_value(t, cache_init(&cache, slots), Search_Refusal.None)

	// Helper building a canonical tree_hash for a subtree of 2 files.
	compute_subtree_hash :: proc(name_a: string, bytes_a: []u8, name_b: string, bytes_b: []u8) -> blake3.Hash {
		e_a, _ := tree_hash.tree_entry_make(.Object, name_a, blake3.hash(bytes_a))
		e_b, _ := tree_hash.tree_entry_make(.Object, name_b, blake3.hash(bytes_b))
		entries := [2]tree_hash.Tree_Entry{e_a, e_b}
		buf: [tree_hash.HEADER_SIZE + 2 * tree_hash.ENTRY_SIZE]u8
		written, _ := tree_hash.tree_encode(entries[:], buf[:])
		digest, _ := tree_hash.tree_hash(buf[:written])
		return digest
	}

	Subtree_Data :: struct {
		hash:  blake3.Hash,
		files: [2][]u8,
	}

	// Commit 1: 8 distinct subtrees.
	commit1: [SUBTREE_COUNT]Subtree_Data
	for s in 0 ..< SUBTREE_COUNT {
		a := fmt.tprintf("subtree %d file alpha original content", s)
		b := fmt.tprintf("subtree %d file beta shared token_%d", s, s)
		commit1[s].files[0] = transmute([]u8)a
		commit1[s].files[1] = transmute([]u8)b
		commit1[s].hash = compute_subtree_hash("alpha.odin", commit1[s].files[0], "beta.odin", commit1[s].files[1])
	}

	// Index Commit 1: all 8 subtrees miss and are indexed.
	for s in 0 ..< SUBTREE_COUNT {
		_, hit := index_reuse_subtree(&cache, commit1[s].hash)
		testing.expect(t, !hit)
		idx, acq_ref := index_acquire_subtree_slot(&cache, commit1[s].hash)
		testing.expect_value(t, acq_ref, Search_Refusal.None)
		for content in commit1[s].files {
			_, r := index_add_file(idx, blake3.hash(content), content)
			testing.expect_value(t, r, Search_Refusal.None)
		}
	}
	testing.expect_value(t, cache.cache_hits, u64(0))
	testing.expect_value(t, cache.reindexed_count, u64(SUBTREE_COUNT))

	// Commit 2: modify 1 file in subtree 3 only; the other 7 tree hashes stay identical.
	commit2 := commit1
	modified_text := "subtree 3 file alpha updated_after_commit_two"
	commit2[3].files[0] = transmute([]u8)modified_text
	commit2[3].hash = compute_subtree_hash("alpha.odin", commit2[3].files[0], "beta.odin", commit2[3].files[1])
	testing.expect(t, commit2[3].hash != commit1[3].hash)

	commit2_indices: [SUBTREE_COUNT]^Bigram_Index
	for s in 0 ..< SUBTREE_COUNT {
		if reused, hit := index_reuse_subtree(&cache, commit2[s].hash); hit {
			commit2_indices[s] = reused
		} else {
			idx, acq_ref := index_acquire_subtree_slot(&cache, commit2[s].hash)
			testing.expect_value(t, acq_ref, Search_Refusal.None)
			for content in commit2[s].files {
				_, r := index_add_file(idx, blake3.hash(content), content)
				testing.expect_value(t, r, Search_Refusal.None)
			}
			commit2_indices[s] = idx
		}
	}
	// Exactly 7 unchanged subtrees reused in O(1), and only 1 subtree reindexed!
	testing.expect_value(t, cache.cache_hits, u64(SUBTREE_COUNT - 1))
	testing.expect_value(t, cache.reindexed_count, u64(SUBTREE_COUNT + 1))

	// Search across Commit 2 finds the updated string only in subtree 3 and untouched tokens in reused subtrees.
	results: [4]Search_Match
	found_updated := 0
	for s in 0 ..< SUBTREE_COUNT {
		m, _, r := index_search_content(commit2_indices[s], commit2[s].files[:], transmute([]u8)string("updated_after_commit_two"), results[:])
		testing.expect_value(t, r, Search_Refusal.None)
		found_updated += m
	}
	testing.expect_value(t, found_updated, 1)

	found_token_5 := 0
	for s in 0 ..< SUBTREE_COUNT {
		m, _, r := index_search_content(commit2_indices[s], commit2[s].files[:], transmute([]u8)string("token_5"), results[:])
		testing.expect_value(t, r, Search_Refusal.None)
		found_token_5 += m
	}
	testing.expect_value(t, found_token_5, 1)
}

@(test)
zero_false_negatives_against_brute_force_over_200_files :: proc(t: ^testing.T) {
	FILE_COUNT :: 200
	files := make_synthetic_repo(FILE_COUNT)
	defer free_synthetic_repo(files)

	index := new(Bigram_Index)
	defer free(index)
	testing.expect_value(t, index_reset(index, blake3.hash(transmute([]u8)string("repo-200"))), Search_Refusal.None)
	for content in files {
		_, r := index_add_file(index, blake3.hash(content), content)
		testing.expect_value(t, r, Search_Refusal.None)
	}

	queries := [?][]u8 {
		transmute([]u8)string("q"),
		transmute([]u8)string("Z"),
		transmute([]u8)string("ax"),
		transmute([]u8)string("99"),
		transmute([]u8)string("Unique_BinaryFuse_Needle_Alpha_99"),
		transmute([]u8)string("unique_binaryfuse_needle_alpha_99"),
		transmute([]u8)string("Multi Word Kernel Ring Completion Query"),
		transmute([]u8)string("powerbox_validate_budget"),
		transmute([]u8)string("COMPOSITOR_PRESENT_SURFACE"),
		transmute([]u8)string("file 143"),
		transmute([]u8)string("file 000"),
		transmute([]u8)string("file 199"),
		transmute([]u8)string("nonexistent_symbol_xyz_404"),
		transmute([]u8)string("package remote_display"),
		transmute([]u8)string("proc()"),
		{0x00, 0xFF, 0xFE, 0x80},
		{0xC3, 0xA9},
		{'b', 'i', 'n', 'x'},
	}

	indexed_results := make([]Search_Match, FILE_COUNT)
	brute_results := make([]Search_Match, FILE_COUNT)
	defer delete(indexed_results)
	defer delete(brute_results)

	for query in queries {
		got_count, checked, refusal := index_search_content(index, files, query, indexed_results)
		testing.expect_value(t, refusal, Search_Refusal.None)
		want_count := brute_force_search(files, query, brute_results)
		testing.expectf(t, got_count == want_count, "query %q: indexed=%d brute=%d", string(query), got_count, want_count)
		for i in 0 ..< want_count {
			testing.expect_value(t, indexed_results[i], brute_results[i])
		}
		// For the rare unique needle and absent query, bigram prefiltering must skip >95% of files.
		if string(query) == "Unique_BinaryFuse_Needle_Alpha_99" || string(query) == "nonexistent_symbol_xyz_404" {
			testing.expectf(t, checked < 10, "query %q checked %d / %d files; expected < 10", string(query), checked, FILE_COUNT)
		}
	}
}

@(test)
measure_store_search_speedup :: proc(t: ^testing.T) {
	if !MEASURE {
		return
	}
	FILE_COUNT :: 200
	ROUNDS :: 15
	ITERATIONS :: 2000

	files := make_synthetic_repo(FILE_COUNT)
	defer free_synthetic_repo(files)

	index := new(Bigram_Index)
	defer free(index)
	_ = index_reset(index, blake3.hash(transmute([]u8)string("measure-repo-200")))

	build_start := time.tick_now()
	total_bytes := 0
	for content in files {
		total_bytes += len(content)
		_, r := index_add_file(index, blake3.hash(content), content)
		testing.expect_value(t, r, Search_Refusal.None)
	}
	build_ms := time.duration_milliseconds(time.tick_since(build_start))

	queries := [?]string {
		"Unique_BinaryFuse_Needle_Alpha_99",
		"Multi Word Kernel Ring Completion Query",
		"nonexistent_symbol_xyz_404",
	}

	results := make([]Search_Match, FILE_COUNT)
	brute_results := make([]Search_Match, FILE_COUNT)
	defer delete(results)
	defer delete(brute_results)

	fmt.printfln("store_search: indexed %d files (%d KiB) in %.2f ms", FILE_COUNT, total_bytes / 1024, build_ms)
	for query_str in queries {
		query := transmute([]u8)query_str
		best_indexed_ns := max(i64)
		best_brute_ns := max(i64)
		last_checked := 0
		last_matches := 0

		for _ in 0 ..< ROUNDS {
			start := time.tick_now()
			for _ in 0 ..< ITERATIONS {
				m, checked, r := index_search_content(index, files, query, results)
				testing.expect_value(t, r, Search_Refusal.None)
				last_matches = m
				last_checked = checked
			}
			best_indexed_ns = min(best_indexed_ns, time.duration_nanoseconds(time.tick_since(start)))

			start = time.tick_now()
			for _ in 0 ..< ITERATIONS {
				bm := brute_force_search(files, query, brute_results)
				testing.expect_value(t, bm, last_matches)
			}
			best_brute_ns = min(best_brute_ns, time.duration_nanoseconds(time.tick_since(start)))
		}

		indexed_us := f64(best_indexed_ns) / (f64(ITERATIONS) * 1000.0)
		brute_us := f64(best_brute_ns) / (f64(ITERATIONS) * 1000.0)
		speedup := brute_us / max(indexed_us, 0.0001)
		fmt.printfln(
			"store_search: query %-40q matches=%d checked=%d/%d: indexed %.2f us vs brute %.2f us (%.1fx speedup)",
			query_str,
			last_matches,
			last_checked,
			FILE_COUNT,
			indexed_us,
			brute_us,
			speedup,
		)
	}
}
