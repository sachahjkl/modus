#+build !freestanding
#+build !modus
package lex_evaluator

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:hash_table"
import "modus:lex_parser"

// Opt-in performance measurement suite for Lex (M1-M5, W1-W3).
// Run with:
//   odin test src/library/modus/lex_evaluator -o:speed -define:MEASURE=true ...
// Never asserts wall-clock timings; prints min/median of MEASURE_ROUNDS,
// ns/op, peak memory, steps, and exact BLAKE3 checksums for cross-layer
// equivalence verification.

MEASURE :: #config(MEASURE, false)
MEASURE_ROUNDS :: 15

@(private = "file")
Measure_Stats :: struct {
	min_ns:    i64,
	median_ns: i64,
}

@(private = "file")
compute_stats :: proc(samples: []i64) -> Measure_Stats {
	slice.sort(samples)
	return {
		min_ns    = samples[0],
		median_ns = samples[len(samples) / 2],
	}
}

@(private = "file")
measure_workspace_make :: proc(allocator := context.allocator, scale: uint = 3) -> (ws: ^Declaration_Workspace, backing: []u8) {
	ws = new(Declaration_Workspace, allocator)
	pools := declaration_pools_of_scale(scale)
	backing = make([]u8, declaration_workspace_bytes(pools) + 64, allocator)
	// Align to 64 bytes.
	addr := uintptr(raw_data(backing))
	aligned_off := int((64 - (addr & 63)) & 63)
	ok := declaration_workspace_carve(ws, backing[aligned_off:aligned_off + declaration_workspace_bytes(pools)], pools)
	assert(ok)
	return ws, backing
}

// ---- Workload generators (deterministic from fixed seed/structure).

// M1: 1 file (~180 KiB) with a 4,096-field record literal + 4,096-element list.
@(private = "file")
generate_m1_source :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make_len_cap(0, 256 * 1024, allocator)
	strings.write_string(&b, "{\n  rec = {\n")
	for i in 0 ..< 4096 {
		fmt.sbprintf(&b, "    f_%04d = %d,\n", i, i * 3 + 1)
	}
	strings.write_string(&b, "  },\n  items = [\n")
	for i in 0 ..< 4096 {
		fmt.sbprintf(&b, "    %d,\n", i)
	}
	strings.write_string(&b, "  ],\n}\n")
	return strings.to_string(b)
}

// M2: 1,024-field base record + 64 `with` overlays (4 overrides each, strictly
// override-only) + 1,024 / 4,096 field lookups.
@(private = "file")
generate_m2_source :: proc(base_fields: int, overlays: int, lookups: int, allocator := context.allocator) -> string {
	b := strings.builder_make_len_cap(0, 128 * 1024, allocator)
	strings.write_string(&b, "let base = {\n")
	for i in 0 ..< base_fields {
		fmt.sbprintf(&b, "  k_%04d = %d,\n", i, i + 1)
	}
	strings.write_string(&b, "},\n")
	for ov in 0 ..< overlays {
		if ov == 0 {
			fmt.sbprintf(&b, "  ov_%02d = base with {{ ", ov)
		} else {
			fmt.sbprintf(&b, "  ov_%02d = ov_%02d with {{ ", ov, ov - 1)
		}
		for j in 0 ..< 4 {
			idx := (ov * 17 + j * 131) % base_fields
			fmt.sbprintf(&b, "k_%04d = %d", idx, ov * 1000 + j)
			if j < 3 {
				strings.write_string(&b, ", ")
			}
		}
		strings.write_string(&b, " },\n")
	}
	fmt.sbprintf(&b, "  final_rec = ov_%02d\nin\n  ", overlays - 1)
	// Sum `lookups` lookups (mix of overridden and base-only keys).
	for i in 0 ..< lookups {
		idx := (i * 29) % base_fields
		if i > 0 {
			strings.write_string(&b, " + ")
		}
		fmt.sbprintf(&b, "final_rec.k_%04d", idx)
	}
	strings.write_string(&b, "\n")
	return strings.to_string(b)
}

// M3: list of N records piped through filter |> map.
@(private = "file")
generate_m3_source :: proc(count: int, allocator := context.allocator) -> string {
	b := strings.builder_make_len_cap(0, 128 * 1024, allocator)
	strings.write_string(&b, "let items = [\n")
	for i in 0 ..< count {
		fmt.sbprintf(&b, "  {{ id = %d, score = %d }},\n", i, (i * 37) % 100)
	}
	strings.write_string(&b, "] in items |> filter((r) => r.score >= 50) |> map((r) => r.id + r.score)\n")
	return strings.to_string(b)
}

// M4a: tail-recursive accumulator of N calls.
@(private = "file")
generate_m4a_source :: proc(n: int, allocator := context.allocator) -> string {
	return fmt.aprintf("let sum = (n, acc) => if n = 0 then acc else sum(n - 1, acc + n) in sum(%d, 0)", n, allocator = allocator)
}

// M4b: non-tail recursion of depth N.
@(private = "file")
generate_m4b_source :: proc(depth: int, allocator := context.allocator) -> string {
	return fmt.aprintf("let walk = (d) => if d = 0 then 1 else 1 + walk(d - 1) in walk(%d)", depth, allocator = allocator)
}

// M5: string concatenation + equality checks (N items).
@(private = "file")
generate_m5_source :: proc(count: int, allocator := context.allocator) -> string {
	b := strings.builder_make_len_cap(0, 64 * 1024, allocator)
	strings.write_string(&b, "let mk = (name, ver) => \"pkg-\" + name + \"-\" + ver,\n  items = [")
	for i in 0 ..< count {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		fmt.sbprintf(&b, "if mk(\"mod%d\", \"1.%d\") = \"pkg-mod%d-1.%d\" then 1 else 0", i, i % 10, i, i % 10)
	}
	strings.write_string(&b, "] in items\n")
	return strings.to_string(b)
}

// Multi-file .lex DAG (N files total: catalog.lex, lib files, app files).
@(private = "file")
Measure_File_Map :: struct {
	names:   []string,
	sources: []string,
}

@(private = "file")
measure_map_load_path :: proc "contextless" (data: rawptr, path: string) -> (source: string, found: bool) {
	m := (^Measure_File_Map)(data)
	for name, i in m.names {
		if name == path {
			return m.sources[i], true
		}
	}
	return "", false
}

@(private = "file")
generate_w1_graph :: proc(total_files: int, allocator := context.allocator) -> (root_source: string, file_map: Measure_File_Map) {
	lib_count := min(40, max(2, total_files / 12))
	app_count := max(1, total_files - lib_count - 1)
	names := make([]string, lib_count + app_count, allocator)
	sources := make([]string, lib_count + app_count, allocator)

	// lib_00.lex .. lib_{lib_count-1}.lex
	for i in 0 ..< lib_count {
		names[i] = fmt.aprintf("lib_%02d.lex", i, allocator = allocator)
		b := strings.builder_make_len_cap(0, 2048, allocator)
		if i == 0 {
			strings.write_string(&b, "{\n  base_ver = 100,\n  scale = (x) => x * 2 + 1,\n")
		} else {
			fmt.sbprintf(&b, "let prev = import(\"lib_%02d.lex\") in {{\n  base_ver = prev.base_ver + %d,\n  scale = (x) => prev.scale(x) + %d,\n", i - 1, i, i)
		}
		for f in 0 ..< 16 {
			fmt.sbprintf(&b, "  cfg_%02d = {{ id = %d, weight = %d, name = \"lib_%02d_%02d\" }},\n", f, i * 100 + f, f * 3 + 1, i, f)
		}
		strings.write_string(&b, "}\n")
		sources[i] = strings.to_string(b)
	}

	// app_000.lex .. app_{app_count-1}.lex
	for i in 0 ..< app_count {
		idx := lib_count + i
		names[idx] = fmt.aprintf("app_%03d.lex", i, allocator = allocator)
		lib_idx := i % min(10, lib_count)
		b := strings.builder_make_len_cap(0, 2048, allocator)
		fmt.sbprintf(&b, "let lib = import(\"lib_%02d.lex\"), base = lib.cfg_%02d in {{\n", lib_idx, i % 16)
		fmt.sbprintf(&b, "  id = %d,\n  score = lib.scale(%d) + base.weight,\n", i, i + 1)
		fmt.sbprintf(&b, "  meta = base with {{ weight = %d }},\n", (i * 7) % 97)
		strings.write_string(&b, "}\n")
		sources[idx] = strings.to_string(b)
	}

	// Root catalog.lex exposing outputs.app_000 .. outputs.app_{app_count-1}
	rb := strings.builder_make_len_cap(0, 32 * 1024, allocator)
	strings.write_string(&rb, "{\n  outputs = {\n")
	for i in 0 ..< app_count {
		fmt.sbprintf(&rb, "    app_%d = import(\"app_%03d.lex\").score,\n", i, i)
	}
	strings.write_string(&rb, "  },\n}\n")

	return strings.to_string(rb), Measure_File_Map{names = names, sources = sources}
}

// Ten thousand console lines.
@(private = "file")
generate_w3_lines :: proc(allocator := context.allocator) -> []string {
	templates := [?]string{
		"1 + 2 * 3 - 4",
		"let x = 10, y = x * 2 in x + y",
		"[1, 2, 3, 4, 5, 6] |> filter((x) => x > 2) |> map((x) => x * 10)",
		"let f = (a, b) => a * a + b * b in f(3, 4)",
		"if 10 > 5 then \"ok\" + \"_yes\" else \"no\"",
		"let a = 7, b = a + 3, c = b * 2 in c - a",
		"map([10, 20, 30, 40], (n) => n / 5 + 1)",
		"filter([1, 2, 3, 4, 5, 6, 7, 8], (n) => n % 2 = 0)",
	}
	lines := make([]string, 10_000, allocator)
	for i in 0 ..< len(lines) {
		lines[i] = templates[i % len(templates)]
	}
	return lines
}

// Minimal console host for W3 benchmark.
@(private = "file")
Bench_Console_Host :: struct {
	scratch: [16 * 1024]u8,
	used:    int,
}

@(private = "file")
bench_console_host :: proc(h: ^Bench_Console_Host) -> Evaluation_Host {
	return {
		data = h,
		name_value = proc "contextless" (data: rawptr, name: string) -> (Host_Value, bool) {
			return {}, false
		},
		command_find = proc "contextless" (data: rawptr, name: string) -> (Command_Signature, bool) {
			return {}, false
		},
		record_memory = proc "contextless" (data: rawptr, size: int) -> ([]u8, bool) {
			return nil, false
		},
		call_run = proc "contextless" (data: rawptr, name: string, args: []Host_Value) -> (Host_Value, bool) {
			return {}, false
		},
		condition_value = proc "contextless" (data: rawptr, eval: ^Evaluation, cmd: string, before: []Host_Value, node: lex_parser.Node_Index) -> (Host_Value, bool) {
			return {}, false
		},
		fact_name_value = proc "contextless" (data: rawptr, eval: ^Evaluation, cmd: string, node: lex_parser.Node_Index) -> (Host_Value, bool) {
			return {}, false
		},
		values_add = proc "contextless" (data: rawptr, left, right: Host_Value) -> (Host_Value, bool) {
			h := (^Bench_Console_Host)(data)
			if left.kind != .Text || right.kind != .Text {
				return {}, false
			}
			need := len(left.text) + len(right.text)
			if need > len(h.scratch) - h.used {
				return {}, false
			}
			start := h.used
			copy(h.scratch[start:], left.text)
			copy(h.scratch[start + len(left.text):], right.text)
			h.used += need
			return {kind = .Text, text = string(h.scratch[start:h.used])}, true
		},
	}
}

@(test)
lex_measure_suite :: proc(t: ^testing.T) {
	if !MEASURE {
		// Fast non-timing smoke invariant: verify M2 small & M3 small produce deterministic results.
		ws, backing := measure_workspace_make(context.temp_allocator, 1)
		_ = backing
		src_m2 := generate_m2_source(32, 4, 32, context.temp_allocator)
		res_m2 := declaration_evaluate(ws, src_m2, "", {stack_bytes = 8 * 1024 * 1024})
		if !res_m2.ok {
			off := int(res_m2.offset)
			fmt.printfln("M2 snippet around %d: %q", off, src_m2[max(0, off - 30):min(len(src_m2), off + 30)])
		}
		testing.expectf(t, res_m2.ok, "M2 smoke failed: %v at %d:%d (%q) tree_refusal=%v", res_m2.failure_kind, res_m2.line, res_m2.column, res_m2.detail, ws.trees[0].refusal)
		testing.expect_value(t, res_m2.value.kind, Kind.Integer)

		src_m3 := generate_m3_source(32, context.temp_allocator)
		res_m3 := declaration_evaluate(ws, src_m3, "", {stack_bytes = 8 * 1024 * 1024})
		if !res_m3.ok {
			off := int(res_m3.offset)
			fmt.printfln("M3 snippet around %d: %q", off, src_m3[max(0, off - 30):min(len(src_m3), off + 30)])
		}
		testing.expectf(t, res_m3.ok, "M3 smoke failed: %v at %d:%d (%q) tree_refusal=%v", res_m3.failure_kind, res_m3.line, res_m3.column, res_m3.detail, ws.trees[0].refusal)
		testing.expect_value(t, res_m3.value.kind, Kind.List)
		return
	}

	fmt.println("================================================================")
	fmt.println("LEX BENCHMARK SUITE (v1 baseline / layer comparison)")
	fmt.printfln("sizeof(lex_parser.Ast_Node)=%d, sizeof(lex_parser.Syntax_Tree)=%d, sizeof(Value)=%d, sizeof(Thunk)=%d, sizeof(Declaration_Workspace)=%d",
		size_of(lex_parser.Ast_Node), size_of(lex_parser.Syntax_Tree), size_of(Value), size_of(Thunk), size_of(Declaration_Workspace))
	fmt.println("================================================================")

	samples: [MEASURE_ROUNDS]i64

	// ---- M1: parse large (~180 KiB: 4096-field record + 4096-item list)
	{
		src := generate_m1_source(context.temp_allocator)
		N :: 65536
		M1_INTERN_SYMS :: 8192
		M1_DUP_CAP :: 8192
		intern_groups := hash_table.slice_index_groups_for_entries(M1_INTERN_SYMS)
		dup_groups := hash_table.slice_index_groups_for_entries(M1_DUP_CAP)
		interner, intern_ok := lex_parser.interner_init(
			make([]u8, intern_groups * hash_table.GROUP_WIDTH, context.temp_allocator),
			make([]u32, intern_groups * hash_table.GROUP_WIDTH, context.temp_allocator),
			make([]lex_parser.Sym_Span, M1_INTERN_SYMS, context.temp_allocator),
			make([]u8, 256 * 1024, context.temp_allocator),
			0x9e3779b97f4a7c15,
		)
		assert(intern_ok)
		storage := lex_parser.Tree_Storage {
			nodes            = make([]lex_parser.Ast_Node, N, context.temp_allocator),
			extra_children   = make([]lex_parser.Node_Index, N, context.temp_allocator),
			scratch_children = make([]lex_parser.Node_Index, N, context.temp_allocator),
			int_consts       = make([]i64, 4096, context.temp_allocator),
			bindings         = make([]lex_parser.Node_Index, N, context.temp_allocator),
			functions        = make([]lex_parser.Node_Index, N, context.temp_allocator),
			interner         = &interner,
			dup_controls     = make([]u8, dup_groups * hash_table.GROUP_WIDTH, context.temp_allocator),
			dup_refs         = make([]u32, dup_groups * hash_table.GROUP_WIDTH, context.temp_allocator),
			dup_keys         = make([]u64, M1_DUP_CAP, context.temp_allocator),
			dup_nodes        = make([]lex_parser.Node_Index, M1_DUP_CAP, context.temp_allocator),
		}
		tree := new(lex_parser.Syntax_Tree, context.temp_allocator)
		node_count := 0
		refusal := lex_parser.Refusal.None
		for r in 0 ..< MEASURE_ROUNDS {
			lex_parser.interner_clear(&interner)
			start := time.tick_now()
			lex_parser.parse_declaration(src, storage, tree)
			samples[r] = time.duration_nanoseconds(time.tick_since(start))
			node_count = tree.node_count
			refusal = tree.refusal.refusal
		}
		st := compute_stats(samples[:])
		fmt.printfln("M1_parse_large (%d B): ok=%v refusal=%v nodes=%d min=%.3f ms median=%.3f ms (%.1f MiB/s)",
			len(src), refusal == .None, refusal, node_count,
			f64(st.min_ns) / 1e6, f64(st.median_ns) / 1e6,
			(f64(len(src)) / (1024.0 * 1024.0)) / (f64(st.min_ns) / 1e9))
	}

	// ---- M2: 1024-field base + 64 with overlays + 1024 and 4096 lookups
	for queries in ([?]int{1024, 4096}) {
		ws, _ := measure_workspace_make(context.temp_allocator, 3)
		src := generate_m2_source(1024, 64, queries, context.temp_allocator)
		last_res: Declaration_Result
		prof: Evaluation_Profile
		for r in 0 ..< MEASURE_ROUNDS {
			prof = {}
			start := time.tick_now()
			last_res = declaration_evaluate(ws, src, "", {stack_bytes = 16 * 1024 * 1024, depth_limit = 4096, profile = &prof})
			samples[r] = time.duration_nanoseconds(time.tick_since(start))
		}
		st := compute_stats(samples[:])
		fmt.printfln("M2_deep_with_overlays (1024f+64ov+%dq): ok=%v fail=%v val=%d steps=%d compacts=%d hash_lookups=%d min=%.3f ms median=%.3f ms",
			queries, last_res.ok, last_res.failure_kind, value_integer(last_res.value), last_res.steps_taken,
			prof.overlay_compacts, prof.shape_hash_lookups, f64(st.min_ns) / 1e6, f64(st.median_ns) / 1e6)
	}

	// ---- M3: list pipeline (512 items for v1 cap + 4096 items target)
	for count in ([?]int{512, 4096}) {
		ws, _ := measure_workspace_make(context.temp_allocator, 3)
		src := generate_m3_source(count, context.temp_allocator)
		last_res: Declaration_Result
		for r in 0 ..< MEASURE_ROUNDS {
			start := time.tick_now()
			last_res = declaration_evaluate(ws, src, "", {stack_bytes = 16 * 1024 * 1024})
			samples[r] = time.duration_nanoseconds(time.tick_since(start))
		}
		st := compute_stats(samples[:])
		fmt.printfln("M3_list_pipeline (N=%d): ok=%v fail=%v out_len=%d steps=%d min=%.3f ms median=%.3f ms",
			count, last_res.ok, last_res.failure_kind, last_res.value.meta, last_res.steps_taken,
			f64(st.min_ns) / 1e6, f64(st.median_ns) / 1e6)
	}

	// ---- M4a & M4b: deep recursion
	{
		ws, _ := measure_workspace_make(context.temp_allocator, 2)
		src_a := generate_m4a_source(50_000, context.temp_allocator)
		res_a: Declaration_Result
		prof_a: Evaluation_Profile
		for r in 0 ..< MEASURE_ROUNDS {
			prof_a = {}
			start := time.tick_now()
			res_a = declaration_evaluate(ws, src_a, "", {profile = &prof_a})
			samples[r] = time.duration_nanoseconds(time.tick_since(start))
		}
		st_a := compute_stats(samples[:])
		fmt.printfln("M4a_tail_recursion (50000): ok=%v fail=%v val=%d steps=%d tco=%d max_depth=%d min=%.3f ms median=%.3f ms",
			res_a.ok, res_a.failure_kind, value_integer(res_a.value), res_a.steps_taken,
			prof_a.tail_calls_total, prof_a.max_frame_depth, f64(st_a.min_ns) / 1e6, f64(st_a.median_ns) / 1e6)

		src_b := generate_m4b_source(1_000, context.temp_allocator)
		res_b: Declaration_Result
		for r in 0 ..< MEASURE_ROUNDS {
			start := time.tick_now()
			res_b = declaration_evaluate(ws, src_b, "")
			samples[r] = time.duration_nanoseconds(time.tick_since(start))
		}
		st_b := compute_stats(samples[:])
		fmt.printfln("M4b_nontail_recursion (1000): ok=%v fail=%v val=%d steps=%d min=%.3f ms median=%.3f ms",
			res_b.ok, res_b.failure_kind, value_integer(res_b.value), res_b.steps_taken,
			f64(st_b.min_ns) / 1e6, f64(st_b.median_ns) / 1e6)
	}

	// ---- M5: strings + equality (512 for v1 cap + 4096 target)
	for count in ([?]int{512, 4096}) {
		ws, _ := measure_workspace_make(context.temp_allocator, 3)
		src := generate_m5_source(count, context.temp_allocator)
		last_res: Declaration_Result
		for r in 0 ..< MEASURE_ROUNDS {
			start := time.tick_now()
			last_res = declaration_evaluate(ws, src, "", {stack_bytes = 16 * 1024 * 1024})
			samples[r] = time.duration_nanoseconds(time.tick_since(start))
		}
		st := compute_stats(samples[:])
		fmt.printfln("M5_strings (N=%d): ok=%v fail=%v out_len=%d steps=%d min=%.3f ms median=%.3f ms",
			count, last_res.ok, last_res.failure_kind, last_res.value.meta, last_res.steps_taken,
			f64(st.min_ns) / 1e6, f64(st.median_ns) / 1e6)
	}

	// ---- W1: 500-file DAG (lazy single output + full outputs force)
	{
		root_src, fmap := generate_w1_graph(500, context.temp_allocator)
		ws, _ := measure_workspace_make(context.temp_allocator, 4)
		cfg := Declaration_Config{
			loader = {data = &fmap, load_path = measure_map_load_path},
			stack_bytes = 16 * 1024 * 1024,
		}
		// (a) Lazy single output outputs.app_42
		last_lazy: Declaration_Result
		for r in 0 ..< MEASURE_ROUNDS {
			start := time.tick_now()
			last_lazy = declaration_evaluate(ws, root_src, "outputs.app_42", cfg)
			samples[r] = time.duration_nanoseconds(time.tick_since(start))
		}
		st_lazy := compute_stats(samples[:])
		fmt.printfln("W1a_500_file_lazy (outputs.app_42): ok=%v fail=%v val=%d imports=%d steps=%d min=%.3f ms median=%.3f ms",
			last_lazy.ok, last_lazy.failure_kind, value_integer(last_lazy.value), ws.import_count, last_lazy.steps_taken,
			f64(st_lazy.min_ns) / 1e6, f64(st_lazy.median_ns) / 1e6)

		// (b) Full outputs force + canonical serialize
		out_buf := make([]u8, 4 * 1024 * 1024, context.temp_allocator)
		start := time.tick_now()
		written, ok_full := declaration_evaluate_to_buffer(ws, root_src, "outputs", cfg, out_buf)
		full_ns := time.duration_nanoseconds(time.tick_since(start))
		hdr, _, _ := declaration_eval.output_read_header(out_buf[:written])
		hash := blake3.hash(out_buf[:written])
		fmt.printfln("W1b_500_file_full: ok=%v status=%v fail=%v imports=%d written=%d steps=%d time=%.3f ms blake3=%02x%02x%02x%02x",
			ok_full, hdr.status, hdr.failure_kind, ws.import_count, written, hdr.steps_taken,
			f64(full_ns) / 1e6, hash[0], hash[1], hash[2], hash[3])

		// ---- W2: Incremental 1-file edit on the 500-file DAG (caller-owned Query_Cache)
		qcache := new(Query_Cache, context.temp_allocator)
		qbytes := query_cache_bytes(QUERY_CACHE_DEFAULT_POOLS)
		qbacking, qerr := mem.alloc_bytes(qbytes, 64, context.temp_allocator)
		assert(qerr == nil && query_cache_carve(qcache, qbacking, QUERY_CACHE_DEFAULT_POOLS))
		qprof: Evaluation_Profile
		qcfg := Declaration_Config{
			loader      = {data = &fmap, load_path = measure_map_load_path},
			stack_bytes = 16 * 1024 * 1024,
			profile     = &qprof,
		}
		// Warm cache for outputs.app_0 and outputs.app_42.
		_, _ = query_cache_evaluate_to_buffer(qcache, ws, root_src, "outputs.app_0", qcfg, out_buf)
		_, _ = query_cache_evaluate_to_buffer(qcache, ws, root_src, "outputs.app_42", qcfg, out_buf)

		// (a) Edit 1 leaf (app_042.lex) and query unaffected outputs.app_0 -> instant L2 hit.
		for name, idx in fmap.names {
			if name == "app_042.lex" {
				fmap.sources[idx] = `let lib = import("lib_02.lex"), base = lib.cfg_10 in { id = 42, score = lib.scale(43) + base.weight + 100, meta = base with { weight = 7 } }`
				break
			}
		}
		qprof = {}
		for r in 0 ..< MEASURE_ROUNDS {
			start_w2 := time.tick_now()
			_, _ = query_cache_evaluate_to_buffer(qcache, ws, root_src, "outputs.app_0", qcfg, out_buf)
			samples[r] = time.duration_nanoseconds(time.tick_since(start_w2))
		}
		st_w2a := compute_stats(samples[:])
		fmt.printfln("W2a_incremental_unaffected (outputs.app_0): l2_hits=%d l2_misses=%d min=%.4f ms median=%.4f ms",
			qprof.cache_l2_hits, qprof.cache_l2_misses, f64(st_w2a.min_ns) / 1e6, f64(st_w2a.median_ns) / 1e6)

		// (b) Query affected outputs.app_42 after leaf edit -> L2 miss + L1 hits for unchanged imports.
		qprof = {}
		start_w2b := time.tick_now()
		w2b_n, w2b_ok := query_cache_evaluate_to_buffer(qcache, ws, root_src, "outputs.app_42", qcfg, out_buf)
		w2b_ns := time.duration_nanoseconds(time.tick_since(start_w2b))
		fmt.printfln("W2b_incremental_leaf_edit (outputs.app_42): ok=%v written=%d l1_hits=%d l1_misses=%d l2_misses=%d time=%.4f ms",
			w2b_ok, w2b_n, qprof.cache_l1_hits, qprof.cache_l1_misses, qprof.cache_l2_misses, f64(w2b_ns) / 1e6)

		// (c) Internal refactor of a pure-value leaf (app_000.lex computes same score = 4) -> early cutoff L2 hit on outputs.app_0!
		for name, idx in fmap.names {
			if name == "app_000.lex" {
				fmap.sources[idx] = `let lib = import("lib_00.lex"), base = lib.cfg_00, tmp = lib.scale(1) in { id = 0, score = tmp + base.weight, meta = base with { weight = 0 } }`
				break
			}
		}
		qprof = {}
		start_w2c := time.tick_now()
		w2c_n, w2c_ok := query_cache_evaluate_to_buffer(qcache, ws, root_src, "outputs.app_0", qcfg, out_buf)
		w2c_ns := time.duration_nanoseconds(time.tick_since(start_w2c))
		fmt.printfln("W2c_incremental_early_cutoff (outputs.app_0): ok=%v written=%d l2_hits=%d l2_misses=%d time=%.4f ms",
			w2c_ok, w2c_n, qprof.cache_l2_hits, qprof.cache_l2_misses, f64(w2c_ns) / 1e6)
	}

	// ---- W3: 10,000 console lines
	{
		lines := generate_w3_lines(context.temp_allocator)
		tree_bufs := new(lex_parser.Console_Tree_Buffers, context.temp_allocator)
		eval_bufs := new(Console_Eval_Buffers, context.temp_allocator)
		tree := new(lex_parser.Syntax_Tree, context.temp_allocator)
		eval := new(Evaluation, context.temp_allocator)
		host_state := new(Bench_Console_Host, context.temp_allocator)
		ok_count := 0
		for r in 0 ..< MEASURE_ROUNDS {
			ok_count = 0
			start := time.tick_now()
			for line in lines {
				host_state.used = 0
				lex_parser.parse_console(line, {}, tree_bufs, tree)
				evaluation_start(eval, tree, .Console, bench_console_host(host_state), eval_bufs)
				if _, ok := line_force(eval); ok {
					ok_count += 1
				}
			}
			samples[r] = time.duration_nanoseconds(time.tick_since(start))
		}
		st := compute_stats(samples[:])
		fmt.printfln("W3_console_hot_path (10000 lines): ok=%d/10000 min=%.3f ms median=%.3f ms (%.0f ns/line)",
			ok_count, f64(st.min_ns) / 1e6, f64(st.median_ns) / 1e6, f64(st.min_ns) / 10000.0)
	}
}
