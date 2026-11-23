#+build !freestanding
package lex_evaluator

import "core:mem"
import "core:slice"
import "core:testing"
import "modus:contract/declaration_eval"

@(private = "file")
qc_test_workspace :: proc(allocator: mem.Allocator, scale: uint = 1) -> ^Declaration_Workspace {
	ws := new(Declaration_Workspace, allocator)
	pools := declaration_pools_of_scale(scale)
	bytes := declaration_workspace_bytes(pools)
	backing, err := mem.alloc_bytes(bytes, 64, allocator)
	assert(err == nil)
	ok := declaration_workspace_carve(ws, backing, pools)
	assert(ok)
	return ws
}

@(private = "file")
qc_test_cache :: proc(allocator: mem.Allocator, pools: Query_Cache_Pools = QUERY_CACHE_DEFAULT_POOLS) -> ^Query_Cache {
	c := new(Query_Cache, allocator)
	bytes := query_cache_bytes(pools)
	backing, err := mem.alloc_bytes(bytes, 64, allocator)
	assert(err == nil)
	ok := query_cache_carve(c, backing, pools, 0x123456789abcdef0)
	assert(ok)
	return c
}

@(private = "file")
qc_map_load :: proc "contextless" (data: rawptr, path: string) -> (string, bool) {
	m := (^map[string]string)(data)
	src, ok := m[path]
	return src, ok
}

@(private = "file")
expect_cached_matches_uncached :: proc(
	t: ^testing.T,
	cache: ^Query_Cache,
	ws: ^Declaration_Workspace,
	source: string,
	field_path: string,
	cfg: Declaration_Config,
	label: string,
) -> []u8 {
	buf_cached := make([]u8, 64 * 1024, context.temp_allocator)
	buf_fresh := make([]u8, 64 * 1024, context.temp_allocator)
	wc, okc := query_cache_evaluate_to_buffer(cache, ws, source, field_path, cfg, buf_cached)
	fresh_cfg := cfg
	fresh_cfg.profile = nil
	fresh_cfg.compile_cache = nil
	wf, okf := declaration_evaluate_to_buffer(ws, source, field_path, fresh_cfg, buf_fresh)
	testing.expectf(t, okc == okf, "%s: ok mismatch cached=%v fresh=%v", label, okc, okf)
	testing.expectf(t, wc == wf, "%s: len mismatch cached=%d fresh=%d", label, wc, wf)
	hc, rc, refc := declaration_eval.output_read_header(buf_cached[:wc])
	hf, rf, reff := declaration_eval.output_read_header(buf_fresh[:wf])
	testing.expectf(t, refc == .None && reff == .None, "%s: header read failed (%v, %v)", label, refc, reff)
	testing.expectf(t, hc.status == .Ok && hf.status == .Ok, "%s: expected Ok status, got cached=%v (%v) fresh=%v (%v)", label, hc.status, hc.failure_kind, hf.status, hf.failure_kind)
	// Compare canonical payload bytes (header steps_taken may differ on early cutoff
	// after an internal refactor that kept the output value identical).
	testing.expectf(t, slice.equal(rc.bytes[rc.offset:], rf.bytes[rf.offset:]), "%s: canonical payload diverged between cached and fresh eval", label)
	return buf_cached[:wc]
}

@(test)
query_cache_carve_refusals :: proc(t: ^testing.T) {
	pools := Query_Cache_Pools{l1_entries = 16, l1_nodes = 256, l1_extra = 256, l1_int_consts = 64, l2_entries = 16, l2_deps = 64, l2_field_deps = 128, l2_bytes = 4096, tracker_imports = 64}
	need := query_cache_bytes(pools)
	c: Query_Cache
	// Nil cache pointer refused.
	backing, err := mem.alloc_bytes(need + 64, 64, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, !query_cache_carve(nil, backing, pools))
	// Undersized buffer refused.
	testing.expect(t, !query_cache_carve(&c, backing[:need - 1], pools))
	// Unaligned buffer refused.
	testing.expect(t, !query_cache_carve(&c, backing[1:1 + need], pools))
	// Exact aligned buffer accepted.
	testing.expect(t, query_cache_carve(&c, backing[:need], pools))
}

@(test)
query_cache_l1_and_l2_hits_and_leaf_invalidation :: proc(t: ^testing.T) {
	ws := qc_test_workspace(context.temp_allocator)
	cache := qc_test_cache(context.temp_allocator)

	files := make(map[string]string, 16, context.temp_allocator)
	files["lib.lex"] = `{ base = 100, unused = 999 }`
	files["a.lex"] = `let l = import("lib.lex") in { val = l.base + 1 }`
	files["b.lex"] = `let l = import("lib.lex") in { val = l.base + 2 }`
	root := `{ a = import("a.lex").val, b = import("b.lex").val }`

	prof: Evaluation_Profile
	cfg := Declaration_Config{loader = {data = &files, load_path = qc_map_load}, profile = &prof}

	// Cold run of "a": L2 miss, L1 misses for root, a, lib.
	expect_cached_matches_uncached(t, cache, ws, root, "a", cfg, "cold a")
	testing.expect_value(t, prof.cache_l2_misses, u64(1))
	testing.expect_value(t, prof.cache_l2_hits, u64(0))
	testing.expect_value(t, prof.cache_l1_misses, u64(3))

	// Cold run of "b": L2 miss, but root and lib hit L1 compile cache!
	prof = {}
	expect_cached_matches_uncached(t, cache, ws, root, "b", cfg, "cold b")
	testing.expect_value(t, prof.cache_l2_misses, u64(1))
	testing.expect_value(t, prof.cache_l1_hits, u64(2))   // root + lib
	testing.expect_value(t, prof.cache_l1_misses, u64(1)) // b

	// Warm repeat of "a": instant L2 hit (zero parses!).
	prof = {}
	expect_cached_matches_uncached(t, cache, ws, root, "a", cfg, "warm a")
	testing.expect_value(t, prof.cache_l2_hits, u64(1))
	testing.expect_value(t, prof.cache_l1_hits, u64(0))
	testing.expect_value(t, prof.cache_l1_misses, u64(0))

	// Edit leaf "b.lex": "a" stays an instant L2 hit, "b" misses and updates!
	files["b.lex"] = `let l = import("lib.lex") in { val = l.base + 20 }`
	prof = {}
	expect_cached_matches_uncached(t, cache, ws, root, "a", cfg, "a after editing b")
	testing.expect_value(t, prof.cache_l2_hits, u64(1))

	prof = {}
	out_b := expect_cached_matches_uncached(t, cache, ws, root, "b", cfg, "b after editing b")
	testing.expect_value(t, prof.cache_l2_misses, u64(1))
	testing.expect(t, prof.cache_l1_hits >= 2)
	testing.expect_value(t, prof.cache_l1_misses, u64(1)) // edited b parsed once only!
	_, r, _ := declaration_eval.output_read_header(out_b)
	tag, _ := declaration_eval.output_read_tag(&r)
	iv, _ := declaration_eval.output_read_i64(&r)
	testing.expect_value(t, tag, declaration_eval.Value_Tag.Integer)
	testing.expect_value(t, iv, i64(120))
}

@(test)
query_cache_early_cutoff_on_internal_refactor :: proc(t: ^testing.T) {
	ws := qc_test_workspace(context.temp_allocator)
	cache := qc_test_cache(context.temp_allocator)

	files := make(map[string]string, 16, context.temp_allocator)
	files["lib.lex"] = `{ base = 40 + 2, other = 1 }`
	files["mid.lex"] = `let l = import("lib.lex") in { doubled = l.base * 2 }`
	root := `{ out = import("mid.lex").doubled }`

	prof: Evaluation_Profile
	cfg := Declaration_Config{loader = {data = &files, load_path = qc_map_load}, profile = &prof}

	expect_cached_matches_uncached(t, cache, ws, root, "out", cfg, "cold")
	testing.expect_value(t, prof.cache_l2_misses, u64(1))

	// Internal refactor of lib.lex (changes `other` AND computes `base` differently,
	// while accessed field `base` stays 42): MUST trigger early cutoff L2 hit!
	files["lib.lex"] = `let half = 21 in { base = half * 2, other = 99999 }`
	prof = {}
	expect_cached_matches_uncached(t, cache, ws, root, "out", cfg, "early cutoff")
	testing.expect_value(t, prof.cache_l2_hits, u64(1))
	testing.expect_value(t, prof.cache_l2_misses, u64(0))

	// Subsequent query hits O(1) file-hash fast path (0 L1 parses!).
	prof = {}
	expect_cached_matches_uncached(t, cache, ws, root, "out", cfg, "post-cutoff fast path")
	testing.expect_value(t, prof.cache_l2_hits, u64(1))
	testing.expect_value(t, prof.cache_l1_misses, u64(0))

	// Now actually change `base` to 50: MUST invalidate and compute 100!
	files["lib.lex"] = `let half = 25 in { base = half * 2, other = 99999 }`
	prof = {}
	out := expect_cached_matches_uncached(t, cache, ws, root, "out", cfg, "real change")
	testing.expect_value(t, prof.cache_l2_misses, u64(1))
	_, r, _ := declaration_eval.output_read_header(out)
	_, _ = declaration_eval.output_read_tag(&r)
	iv, _ := declaration_eval.output_read_i64(&r)
	testing.expect_value(t, iv, i64(100))
}

@(test)
query_cache_negative_shape_dependencies :: proc(t: ^testing.T) {
	ws := qc_test_workspace(context.temp_allocator)
	cache := qc_test_cache(context.temp_allocator)

	files := make(map[string]string, 16, context.temp_allocator)
	files["dep.lex"] = `{ a = 1 }`

	prof: Evaluation_Profile
	cfg := Declaration_Config{loader = {data = &files, load_path = qc_map_load}, profile = &prof}

	// 1. `has(dep, "extra")` -> false, then add `extra = 2` -> MUST invalidate and return true!
	root_has := `{ present = has(import("dep.lex"), "extra") }`
	expect_cached_matches_uncached(t, cache, ws, root_has, "present", cfg, "has before")

	files["dep.lex"] = `{ a = 1, extra = 2 }`
	prof = {}
	out_has := expect_cached_matches_uncached(t, cache, ws, root_has, "present", cfg, "has after adding extra")
	testing.expect_value(t, prof.cache_l2_misses, u64(1))
	_, rh, _ := declaration_eval.output_read_header(out_has)
	_, _ = declaration_eval.output_read_tag(&rh)
	bv, _ := declaration_eval.output_read_u8(&rh)
	testing.expect_value(t, bv, u8(1))

	// 2. Destructuring with default + rest: `let { a, b = 99, ... } = import("dep.lex") in a + b`.
	// Adding `b = 5` to dep.lex MUST invalidate via shape_hash!
	files["dep.lex"] = `{ a = 1 }`
	root_pat := `{ sum = let { a, b = 99, ... } = import("dep.lex") in a + b }`
	out1 := expect_cached_matches_uncached(t, cache, ws, root_pat, "sum", cfg, "destructure before")
	_, r1, _ := declaration_eval.output_read_header(out1)
	_, _ = declaration_eval.output_read_tag(&r1)
	v1, _ := declaration_eval.output_read_i64(&r1)
	testing.expect_value(t, v1, i64(100))

	files["dep.lex"] = `{ a = 1, b = 5 }`
	prof = {}
	out2 := expect_cached_matches_uncached(t, cache, ws, root_pat, "sum", cfg, "destructure after adding b")
	testing.expect_value(t, prof.cache_l2_misses, u64(1))
	_, r2, _ := declaration_eval.output_read_header(out2)
	_, _ = declaration_eval.output_read_tag(&r2)
	v2, _ := declaration_eval.output_read_i64(&r2)
	testing.expect_value(t, v2, i64(6))
}

@(test)
query_cache_closure_fallback_and_trace_opt_out :: proc(t: ^testing.T) {
	ws := qc_test_workspace(context.temp_allocator)
	cache := qc_test_cache(context.temp_allocator)

	files := make(map[string]string, 16, context.temp_allocator)
	files["fn.lex"] = `{ inc = (x) => x + 1, k = 10 }`

	prof: Evaluation_Profile
	cfg := Declaration_Config{loader = {data = &files, load_path = qc_map_load}, profile = &prof}

	// Closure export: editing `inc` MUST invalidate (cannot early-cutoff closures).
	root_fn := `let m = import("fn.lex"), f = m.inc in { res = f(40) }`
	out1 := expect_cached_matches_uncached(t, cache, ws, root_fn, "res", cfg, "closure v1")
	_, r1, _ := declaration_eval.output_read_header(out1)
	_, _ = declaration_eval.output_read_tag(&r1)
	v1, _ := declaration_eval.output_read_i64(&r1)
	testing.expect_value(t, v1, i64(41))

	files["fn.lex"] = `{ inc = (x) => x + 2, k = 10 }`
	prof = {}
	out2 := expect_cached_matches_uncached(t, cache, ws, root_fn, "res", cfg, "closure v2")
	testing.expect_value(t, prof.cache_l2_misses, u64(1))
	_, r2, _ := declaration_eval.output_read_header(out2)
	_, _ = declaration_eval.output_read_tag(&r2)
	v2, _ := declaration_eval.output_read_i64(&r2)
	testing.expect_value(t, v2, i64(42))

	// `trace(...)` opt-out: MUST NOT serve from L2 cache; Trace_Log runs every time!
	root_trace := `{ res = trace("ping", 77) }`
	buf := make([]u8, 4096, context.temp_allocator)
	for run in 0 ..< 3 {
		tlog: Trace_Log
		tprof: Evaluation_Profile
		tcfg := Declaration_Config{trace_log = &tlog, profile = &tprof}
		w, ok := query_cache_evaluate_to_buffer(cache, ws, root_trace, "res", tcfg, buf)
		testing.expectf(t, ok && w > 0, "trace run %d failed", run)
		testing.expect_value(t, tprof.cache_l2_hits, u64(0))
		testing.expect_value(t, tprof.cache_l2_misses, u64(1))
		testing.expect_value(t, tlog.count, 1)
		testing.expect_value(t, tlog.entries[0].message, "ping")
	}
}

@(test)
query_cache_new_transitive_import_and_bounded_eviction :: proc(t: ^testing.T) {
	ws := qc_test_workspace(context.temp_allocator)
	// Intentionally tiny cache to exercise clean wraparound/reset under pressure.
	small_pools := Query_Cache_Pools {
		l1_entries      = 16,
		l1_nodes        = 512,
		l1_extra        = 512,
		l1_int_consts   = 64,
		l2_entries      = 16,
		l2_deps         = 64,
		l2_field_deps   = 128,
		l2_bytes        = 4096,
		tracker_imports = 64,
	}
	cache := qc_test_cache(context.temp_allocator, small_pools)

	files := make(map[string]string, 16, context.temp_allocator)
	files["lib.lex"] = `{ v = 10 }`
	files["extra.lex"] = `{ v = 10 }`
	root := `{ out = import("lib.lex").v }`

	prof: Evaluation_Profile
	cfg := Declaration_Config{loader = {data = &files, load_path = qc_map_load}, profile = &prof}

	expect_cached_matches_uncached(t, cache, ws, root, "out", cfg, "before transitive import")

	// Refactor lib.lex to introduce a new transitive import extra.lex (same value 10).
	// Cache must conservatively invalidate so extra.lex is added to the dependency set!
	files["lib.lex"] = `{ v = import("extra.lex").v }`
	prof = {}
	expect_cached_matches_uncached(t, cache, ws, root, "out", cfg, "new transitive import")
	testing.expect_value(t, prof.cache_l2_misses, u64(1))

	// Now edit extra.lex -> 99: MUST invalidate because extra.lex was recorded!
	files["extra.lex"] = `{ v = 99 }`
	prof = {}
	out := expect_cached_matches_uncached(t, cache, ws, root, "out", cfg, "edit new transitive import")
	testing.expect_value(t, prof.cache_l2_misses, u64(1))
	_, r, _ := declaration_eval.output_read_header(out)
	_, _ = declaration_eval.output_read_tag(&r)
	iv, _ := declaration_eval.output_read_i64(&r)
	testing.expect_value(t, iv, i64(99))

	// Push >32 distinct queries through the 16-slot cache to exercise clean eviction.
	for i in 0 ..< 40 {
		b := [1]Declaration_Binding{{name = "k", kind = .Integer, integer = i64(i)}}
		bcfg := Declaration_Config{bindings = b[:]}
		expect_cached_matches_uncached(t, cache, ws, `{ v = k * 3 }`, "v", bcfg, "eviction stress")
	}
}
