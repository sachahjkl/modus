#+build !freestanding
#+build !modus
package lex_evaluator

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:contract/plans_recipes"
import "modus:lex_parser"

@(private = "file")
DECL_TEST_STACK :: 2 * 1024 * 1024

@(private = "file")
new_workspace :: proc(scale: uint = 0) -> ^Declaration_Workspace {
	ws := new(Declaration_Workspace, context.temp_allocator)
	pools := declaration_pools_of_scale(scale)
	memory, _ := mem.alloc_bytes(declaration_workspace_bytes(pools), 64, context.temp_allocator)
	carved := declaration_workspace_carve(ws, memory, pools)
	assert(carved)
	return ws
}

@(private = "file")
hash_literal_of :: proc(tag: string) -> (hash: blake3.Hash, text: string) {
	hash = blake3.hash(transmute([]u8)tag)
	HEX :: "0123456789abcdef"
	hex := HEX
	buf := make([]u8, 7 + 64, context.temp_allocator)
	copy(buf[:7], "blake3:")
	for b, i in hash {
		buf[7 + i * 2] = hex[b >> 4]
		buf[7 + i * 2 + 1] = hex[b & 0x0f]
	}
	return hash, string(buf)
}

// Laziness proven: unforced fields with errors, effects, or unknown names
// never fail evaluation of another field; lazy `with`, lazy `if`, lazy `let`,
// and thunk memoization.
@(test)
declaration_laziness_is_strict :: proc(t: ^testing.T) {
	ws := new_workspace()
	cfg := Declaration_Config{stack_bytes = DECL_TEST_STACK}

	// Sibling field divides by zero: selecting .good returns 42 cleanly.
	res := declaration_evaluate(ws, "{ good = 42, bad = 1 / 0 }", "good", cfg)
	testing.expect(t, res.ok)
	testing.expect_value(t, res.value.kind, Kind.Integer)
	testing.expect_value(t, value_integer(res.value), i64(42))

	// Forcing .bad DOES fail with Division_By_Zero.
	res = declaration_evaluate(ws, "{ good = 42, bad = 1 / 0 }", "bad", cfg)
	testing.expect(t, !res.ok)
	testing.expect_value(t, res.failure_kind, declaration_eval.Failure_Kind.Division_By_Zero)

	// Sibling field calls an effectful command: selecting .good never triggers it.
	res = declaration_evaluate(ws, "{ good = 7, bad = shutdown() }", "good", cfg)
	testing.expect(t, res.ok && value_integer(res.value) == 7)

	// Nested project outputs: selecting outputs.tools does not force outputs.image.
	res = declaration_evaluate(ws, "project {\n  outputs = {\n    tools = 100 + 23,\n    image = 1 / 0,\n  },\n}", "outputs.tools", cfg)
	testing.expect(t, res.ok && value_integer(res.value) == 123)

	// Lazy `with`: overriding a broken field never forces the overridden value.
	res = declaration_evaluate(ws, "({ a = 1, b = 1 / 0 } with { b = 99 }).b", "", cfg)
	testing.expect(t, res.ok && value_integer(res.value) == 99)
	res = declaration_evaluate(ws, "({ a = 1, b = 1 / 0 } with { b = 99 }).a", "", cfg)
	testing.expect(t, res.ok && value_integer(res.value) == 1)

	// Strictly override-only `with`: an unknown patch field is refused eagerly
	// without forcing any broken field in either record.
	res = declaration_evaluate(ws, "{ a = 1 / 0 } with { b = 2 }", "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Field_Unknown && res.detail == "b")

	// Lazy `if`: untaken branch is never forced.
	res = declaration_evaluate(ws, "if true then 11 else 1 / 0", "", cfg)
	testing.expect(t, res.ok && value_integer(res.value) == 11)
	res = declaration_evaluate(ws, "if false then 1 / 0 else 22", "", cfg)
	testing.expect(t, res.ok && value_integer(res.value) == 22)

	// Lazy `let`: unused broken binding is never forced.
	res = declaration_evaluate(ws, "let boom = 1 / 0, ok = 55 in ok", "", cfg)
	testing.expect(t, res.ok && value_integer(res.value) == 55)

	// Memoization: forcing the same field a second time costs 0 additional steps.
	res = declaration_evaluate(ws, "{ x = 2 * 3 + 4, unused = 1 / 0 }", "", cfg)
	testing.expect(t, res.ok)
	v1, ok1 := declaration_force_path(ws, res.value, "x")
	testing.expect(t, ok1 && value_integer(v1) == 10)
	steps_after_first := ws.evaluation.steps
	v2, ok2 := declaration_force_path(ws, res.value, "x")
	testing.expect(t, ok2 && value_integer(v2) == 10)
	testing.expect_value(t, ws.evaluation.steps, steps_after_first)
}

// Cycle detection: direct self-reference, mutual let cycle, 3-way cycle,
// record field self-cycle, record field mutual cycle, and cross-file import cycle.
@(test)
declaration_cycle_detection :: proc(t: ^testing.T) {
	ws := new_workspace()
	cfg := Declaration_Config{stack_bytes = DECL_TEST_STACK}

	cycles := [?]string {
		"let a = a in a",
		"let a = b, b = a in a",
		"let a = b, b = c, c = a in a",
		"let r = { a = r.a } in r.a",
		"let r = { a = r.b, b = r.a } in r.a",
	}
	for src in cycles {
		res := declaration_evaluate(ws, src, "", cfg)
		testing.expectf(t, !res.ok && res.failure_kind == .Cycle_Detected, "%q: got ok=%v failure=%v, want Cycle_Detected", src, res.ok, res.failure_kind)
	}

	// Cross-file import cycle: a.lex imports b.lex which imports a.lex.
	bundle_buf: [2048]u8
	entries := [2]declaration_eval.Bundle_Input_Entry {
		{kind = .File_Path, path = "a.lex", content = "import(\"b.lex\")"},
		{kind = .File_Path, path = "b.lex", content = "import(\"a.lex\")"},
	}
	written, berr := declaration_eval.bundle_write(bundle_buf[:], entries[:])
	testing.expect_value(t, berr, declaration_eval.Bundle_Refusal.None)
	bundle_slice := bundle_buf[:written]
	cfg.loader = bundle_loader(&bundle_slice)

	res := declaration_evaluate(ws, "import(\"a.lex\")", "", cfg)
	testing.expect(t, !res.ok)
	testing.expect_value(t, res.failure_kind, declaration_eval.Failure_Kind.Cycle_Detected)

	// Cross-declaration hash cycle.
	ha, ha_lit := hash_literal_of("decl_a")
	hb, hb_lit := hash_literal_of("decl_b")
	hash_entries := [2]declaration_eval.Bundle_Input_Entry {
		{kind = .Declaration_Hash, hash = ha, content = strings.concatenate({"declaration(", hb_lit, ")"}, context.temp_allocator)},
		{kind = .Declaration_Hash, hash = hb, content = strings.concatenate({"declaration(", ha_lit, ")"}, context.temp_allocator)},
	}
	written, berr = declaration_eval.bundle_write(bundle_buf[:], hash_entries[:])
	testing.expect_value(t, berr, declaration_eval.Bundle_Refusal.None)
	bundle_slice = bundle_buf[:written]
	cfg.loader = bundle_loader(&bundle_slice)

	res = declaration_evaluate(ws, strings.concatenate({"declaration(", ha_lit, ")"}, context.temp_allocator), "", cfg)
	testing.expect(t, !res.ok)
	testing.expect_value(t, res.failure_kind, declaration_eval.Failure_Kind.Cycle_Detected)
}

// Strict bounds: step/fuel bound, recursion depth bound, stack bound, node
// pool bound, parser nesting bound; and valid terminating recursion succeeds.
@(test)
declaration_bounds_and_recursion :: proc(t: ^testing.T) {
	ws := new_workspace()

	// Step/fuel bound stops infinite tail recursion cleanly in O(1) frame depth.
	prof: Evaluation_Profile
	res := declaration_evaluate(ws, "let loop = (n) => loop(n + 1) in loop(0)", "", {budget = 120, depth_limit = 500, stack_bytes = DECL_TEST_STACK, profile = &prof})
	testing.expect(t, !res.ok)
	testing.expect_value(t, res.failure_kind, declaration_eval.Failure_Kind.Step_Bound_Reached)
	testing.expect(t, res.steps_taken <= 120)
	testing.expect(t, prof.max_frame_depth <= 4)

	// Depth bound stops deep non-tail recursion cleanly.
	res = declaration_evaluate(ws, "let down = (n) => 1 + down(n + 1) in down(0)", "", {budget = 100_000, depth_limit = 24, stack_bytes = DECL_TEST_STACK})
	testing.expect(t, !res.ok)
	testing.expect_value(t, res.failure_kind, declaration_eval.Failure_Kind.Depth_Bound_Reached)

	// Deep tail recursion (50,000 calls) succeeds in O(1) VM frames.
	prof = {}
	res = declaration_evaluate(ws, "let sum = (n, acc) => if n = 0 then acc else sum(n - 1, acc + n) in sum(50000, 0)", "", {stack_bytes = DECL_TEST_STACK, profile = &prof})
	testing.expectf(t, res.ok && res.value.kind == .Integer && value_integer(res.value) == 1250025000, "tail recursion failed: ok=%v fail=%v val=%d", res.ok, res.failure_kind, value_integer(res.value))
	testing.expect(t, prof.tail_calls_total >= 49999)
	testing.expect(t, prof.max_frame_depth <= 4)

	// Deep non-tail recursion (1,000 calls) succeeds on arena-backed VM frames.
	res = declaration_evaluate(ws, "let walk = (d) => if d = 0 then 1 else 1 + walk(d - 1) in walk(1000)", "", {stack_bytes = DECL_TEST_STACK})
	testing.expectf(t, res.ok && res.value.kind == .Integer && value_integer(res.value) == 1001, "non-tail recursion failed: ok=%v fail=%v val=%d", res.ok, res.failure_kind, value_integer(res.value))

	// Exponential DAG DoS in canonical serialization hits Step_Bound_Reached.
	dag_src := `let
  a = [1, 1], b = [a, a], c = [b, b], d = [c, c], e = [d, d],
  f = [e, e], g = [f, f], h = [g, g], i = [h, h], j = [i, i],
  k = [j, j], l = [k, k], m = [l, l], n = [m, m], o = [n, n],
  p = [o, o], q = [p, p], r = [q, q], s = [r, r], t = [s, s]
in t`
	dag_out := make([]u8, 64 * 1024, context.temp_allocator)
	dag_len, dag_ok := declaration_evaluate_to_buffer(ws, dag_src, "", {budget = 10_000, stack_bytes = DECL_TEST_STACK}, dag_out)
	testing.expect(t, dag_ok && dag_len >= declaration_eval.OUTPUT_HEADER_BYTES)
	dag_hdr, _, dag_hdr_err := declaration_eval.output_read_header(dag_out[:dag_len])
	testing.expect(t, dag_hdr_err == .None && dag_hdr.status == .Refused && dag_hdr.failure_kind == .Step_Bound_Reached)

	// Node pool bound refuses cleanly.
	res = declaration_evaluate(ws, "{ a = 1, b = 2, c = 3, d = 4 }", "", {node_limit = 4, stack_bytes = DECL_TEST_STACK})
	testing.expect(t, !res.ok)
	testing.expect_value(t, res.failure_kind, declaration_eval.Failure_Kind.Pool_Exhausted)

	// Hostile deeply nested parser input stops cleanly at Depth_Bound_Reached.
	deep := strings.concatenate({strings.repeat("(", 300, context.temp_allocator), "1", strings.repeat(")", 300, context.temp_allocator)}, context.temp_allocator)
	res = declaration_evaluate(ws, deep, "", {stack_bytes = DECL_TEST_STACK})
	testing.expect(t, !res.ok)
	testing.expect_value(t, res.failure_kind, declaration_eval.Failure_Kind.Depth_Bound_Reached)

	// Terminating recursion with conditional succeeds.
	res = declaration_evaluate(ws, "let fact = (n) => if n <= 1 then 1 else n * fact(n - 1) in fact(6)", "", {stack_bytes = DECL_TEST_STACK})
	testing.expect(t, res.ok && res.value.kind == .Integer && value_integer(res.value) == 720)
}

// Refused side effects, unknown commands, hostile import paths, and bad types.
@(test)
declaration_refuses_effects_and_hostile_imports :: proc(t: ^testing.T) {
	ws := new_workspace()
	cfg := Declaration_Config{stack_bytes = DECL_TEST_STACK}

	effects := [?]string {
		"shutdown()",
		"start(\"life\")",
		"plans.apply({ a = 1 })",
		"recipes.build(1)",
		"projects.update(1)",
		"collector.verify(\"server.log\")",
		"exit()",
	}
	for src in effects {
		res := declaration_evaluate(ws, src, "", cfg)
		testing.expectf(t, !res.ok && res.failure_kind == .Effect_Refused, "%q: got %v, want Effect_Refused", src, res.failure_kind)
	}

	res := declaration_evaluate(ws, "unknown_external_cmd(1)", "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Unknown_Command)

	bad_imports := [?]string {
		"import(\"../secret.lex\")",
		"import(\"a/../b.lex\")",
		"import(\"/etc/passwd.lex\")",
		"import(\"./pins.lex\")",
		"import(\"pins.txt\")",
		"import(\"\")",
	}
	for src in bad_imports {
		res = declaration_evaluate(ws, src, "", cfg)
		testing.expectf(t, !res.ok && res.failure_kind == .Import_Path_Refused, "%q: got %v, want Import_Path_Refused", src, res.failure_kind)
	}

	res = declaration_evaluate(ws, "import(\"missing.lex\")", "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Import_Not_Found)

	res = declaration_evaluate(ws, "if 1 then 2 else 3", "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Type_Error)

	res = declaration_evaluate(ws, "filter([1, 2], (x) => x)", "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Type_Error)
}

// Multi-line map, filter, |>, comparisons, and string concatenation.
@(test)
declaration_map_filter_pipe_and_comparisons :: proc(t: ^testing.T) {
	ws := new_workspace()
	cfg := Declaration_Config{stack_bytes = DECL_TEST_STACK}

	source := `// Filter and map over a list using multi-line pipe.
let
  nums = [1, 2, 3, 4, 5, 6],
  big = nums
    |> filter((x) => x > 2)
    |> map((x) => x * 10),
in {
  values = big,
  greeting = "hello" + " " + "modus",
  equal_check = 10 = 10,
  diff_check = "a" != "b",
}
`
	res := declaration_evaluate(ws, source, "values", cfg)
	testing.expect(t, res.ok && res.value.kind == .List)
	items := list_items_of(&ws.evaluation, res.value)
	testing.expect_value(t, len(items), 4)
	if len(items) == 4 {
		testing.expect_value(t, value_integer(items[0]), i64(30))
		testing.expect_value(t, value_integer(items[1]), i64(40))
		testing.expect_value(t, value_integer(items[2]), i64(50))
		testing.expect_value(t, value_integer(items[3]), i64(60))
	}

	res = declaration_evaluate(ws, source, "greeting", cfg)
	testing.expect(t, res.ok && res.value.kind == .Text && value_text(&ws.evaluation, res.value) == "hello modus")
	res = declaration_evaluate(ws, source, "equal_check", cfg)
	testing.expect(t, res.ok && res.value.kind == .Boolean && value_boolean(res.value))
	res = declaration_evaluate(ws, source, "diff_check", cfg)
	testing.expect(t, res.ok && res.value.kind == .Boolean && value_boolean(res.value))
}

// End-to-end real pins.lex, project.lex, and plan.lex evaluation +
// deterministic canonical serialization & contract validation.
@(test)
declaration_end_to_end_pins_project_and_plan :: proc(t: ^testing.T) {
	ws := new_workspace()

	here_hash, _ := hash_literal_of("kernel-source-tree-v1")
	gt_key_hash, gt_key_lit := hash_literal_of("publisher-gui-toolkit")
	odin_hash, odin_lit := hash_literal_of("module-odin-compiler")
	nasm_hash, nasm_lit := hash_literal_of("module-nasm")
	wren_decl_hash, wren_decl_lit := hash_literal_of("wren-declaration-tree")
	tool_tree_hash, tool_tree_lit := hash_literal_of("tool-tree")
	gt_tree_hash, gt_tree_lit := hash_literal_of("gt-tree")

	pins_source := strings.concatenate({
		"// Pinned declaration inputs.\n",
		"{\n",
		"  tool = { commit = \"a1b2c3\", tree = ", tool_tree_lit, " },\n",
		"  gt   = { publisher = ", gt_key_lit, ", number = 41, tree = ", gt_tree_lit, " },\n",
		"}\n",
	}, context.temp_allocator)

	wren_source := strings.concatenate({"{\n  lib = module(", nasm_lit, "),\n  broken = 1 / 0,\n}\n"}, context.temp_allocator)

	catalog_source := strings.concatenate({
		"{\n",
		"  odin = {\n",
		"    builder = module(", odin_lit, "),\n",
		"    module = (src_path) => recipe(module(", odin_lit, "), { path = src_path }),\n",
		"  },\n",
		"  nasm = module(", nasm_lit, "),\n",
		"  git = {\n",
		"    source = (address, branch) => { kind = .Git, address = address, branch = branch },\n",
		"  },\n",
		"}\n",
	}, context.temp_allocator)

	keys_source := strings.concatenate({"{\n  gui_toolkit = ", gt_key_lit, ",\n}\n"}, context.temp_allocator)

	project_source := strings.concatenate({
		"// Real project.lex declaration.\n",
		"let\n",
		"  pins = import(\"pins.lex\"),\n",
		"  wren = declaration(", wren_decl_lit, "),\n",
		"in\n",
		"project {\n",
		"  source = here(),\n",
		"  inputs = {\n",
		"    modus = catalog,\n",
		"    gt = follow(publisher = keys.gui_toolkit, name = \"gui_toolkit\"),\n",
		"    tool_src = catalog.git.source(address = \"https://example.invalid/tool\", branch = \"main\"),\n",
		"    pinned_gt_tree = pins.gt.tree,\n",
		"    pinned_tool_tree = pins.tool.tree,\n",
		"  },\n",
		"  outputs = {\n",
		"    default = catalog.odin.module(\"src/modules/server\"),\n",
		"    tools = catalog.odin.module(\"tools/modustool\"),\n",
		"    wren_lib = wren.lib,\n",
		"    unused_broken = 1 / 0,\n",
		"  },\n",
		"  console = {\n",
		"    modules = [catalog.odin.builder, catalog.nasm],\n",
		"    stores = [store(\"kernel\", .Read, .Write)],\n",
		"  },\n",
		"}\n",
	}, context.temp_allocator)

	plan_source := strings.concatenate({
		"// Real system plan.lex declaration.\n",
		"let\n",
		"  custom_catalog = catalog with { nasm = module(", odin_lit, ") },\n",
		"in\n",
		"plan {\n",
		"  substitution = { mode = .Verify },\n",
		"  modules = [custom_catalog.nasm, module(", nasm_lit, ")],\n",
		"  settings = { font = .spleen, keyboard_layout = .french },\n",
		"}\n",
	}, context.temp_allocator)

	// Pack pins.lex and wren declaration into a read-only contract bundle.
	bundle_buf: [8192]u8
	entries := [2]declaration_eval.Bundle_Input_Entry {
		{kind = .File_Path, path = "pins.lex", content = pins_source},
		{kind = .Declaration_Hash, hash = wren_decl_hash, content = wren_source},
	}
	b_written, b_err := declaration_eval.bundle_write(bundle_buf[:], entries[:], true, here_hash)
	testing.expect_value(t, b_err, declaration_eval.Bundle_Refusal.None)
	testing.expect_value(t, declaration_eval.bundle_validate(bundle_buf[:b_written]), declaration_eval.Bundle_Refusal.None)
	bundle_slice := bundle_buf[:b_written]

	bindings := [2]Declaration_Binding {
		{name = "catalog", kind = .Lex_Source, source = catalog_source},
		{name = "keys", kind = .Lex_Source, source = keys_source},
	}
	cfg := Declaration_Config {
		loader      = bundle_loader(&bundle_slice),
		bindings    = bindings[:],
		has_here    = true,
		here_hash   = here_hash,
		stack_bytes = DECL_TEST_STACK,
	}

	// 1. Evaluate pins.lex directly and validate canonical output.
	out_buf: [8192]u8
	pins_len, pins_ok := declaration_evaluate_to_buffer(ws, pins_source, "", cfg, out_buf[:])
	testing.expect(t, pins_ok)
	pins_hdr, pins_val_err := declaration_eval.output_validate(out_buf[:pins_len])
	testing.expect_value(t, pins_val_err, declaration_eval.Output_Refusal.None)
	testing.expect_value(t, pins_hdr.status, declaration_eval.Output_Status.Ok)

	// Verify pins.gt.tree and pins.tool.tree match exact hashes.
	r_gt := declaration_evaluate(ws, pins_source, "gt.tree", cfg)
	testing.expect(t, r_gt.ok && r_gt.value.kind == .Hash)
	got_gt, _ := hash_of(&ws.evaluation, r_gt.value)
	testing.expect_value(t, got_gt, gt_tree_hash)

	r_tool := declaration_evaluate(ws, pins_source, "tool.tree", cfg)
	testing.expect(t, r_tool.ok && r_tool.value.kind == .Hash)
	got_tool, _ := hash_of(&ws.evaluation, r_tool.value)
	testing.expect_value(t, got_tool, tool_tree_hash)

	// 2. Evaluate project.lex lazily: select outputs.tools, outputs.wren_lib,
	// inputs.gt, console — NEVER triggering outputs.unused_broken or wren.broken!
	tools_len, tools_ok := declaration_evaluate_to_buffer(ws, project_source, "outputs.tools", cfg, out_buf[:])
	testing.expect(t, tools_ok)
	tools_hdr, tools_err := declaration_eval.output_validate(out_buf[:tools_len])
	testing.expect_value(t, tools_err, declaration_eval.Output_Refusal.None)
	testing.expect_value(t, tools_hdr.status, declaration_eval.Output_Status.Ok)
	testing.expect_value(t, out_buf[declaration_eval.OUTPUT_HEADER_BYTES], u8(declaration_eval.Value_Tag.Recipe_Ref))

	wren_res := declaration_evaluate(ws, project_source, "outputs.wren_lib", cfg)
	testing.expect(t, wren_res.ok && wren_res.value.kind == .Module_Ref)
	wren_mod_hash, _ := hash_of(&ws.evaluation, wren_res.value)
	testing.expect_value(t, wren_mod_hash, nasm_hash)

	gt_follow := declaration_evaluate(ws, project_source, "inputs.gt", cfg)
	testing.expect(t, gt_follow.ok && gt_follow.value.kind == .Follow_Ref && value_follow_name(&ws.evaluation, gt_follow.value) == "gui_toolkit")
	follow_pub, _ := hash_of(&ws.evaluation, gt_follow.value)
	testing.expect_value(t, follow_pub, gt_key_hash)

	console_len, console_ok := declaration_evaluate_to_buffer(ws, project_source, "console", cfg, out_buf[:])
	testing.expect(t, console_ok)
	console_hdr, console_err := declaration_eval.output_validate(out_buf[:console_len])
	testing.expect_value(t, console_err, declaration_eval.Output_Refusal.None)
	testing.expect_value(t, console_hdr.status, declaration_eval.Output_Status.Ok)

	src_res := declaration_evaluate(ws, project_source, "source", cfg)
	// here() is a tree, an input that names its kind.
	testing.expect(t, src_res.ok && src_res.value.kind == .Tree_Ref)
	got_src, _ := hash_of(&ws.evaluation, src_res.value)
	testing.expect_value(t, got_src, here_hash)

	// 3. Evaluate plan.lex whole and validate canonical output.
	plan_len, plan_ok := declaration_evaluate_to_buffer(ws, plan_source, "", cfg, out_buf[:])
	testing.expect(t, plan_ok)
	plan_hdr, plan_err := declaration_eval.output_validate(out_buf[:plan_len])
	testing.expect_value(t, plan_err, declaration_eval.Output_Refusal.None)
	testing.expect_value(t, plan_hdr.status, declaration_eval.Output_Status.Ok)
	testing.expect_value(t, out_buf[declaration_eval.OUTPUT_HEADER_BYTES], u8(declaration_eval.Value_Tag.Plan))

	// Check that `with` overrode `nasm` to `odin_hash` in plan.modules[0].
	plan_mods := declaration_evaluate(ws, plan_source, "modules", cfg)
	testing.expect(t, plan_mods.ok && plan_mods.value.kind == .List)
	mod_items := list_items_of(&ws.evaluation, plan_mods.value)
	testing.expect_value(t, len(mod_items), 2)
	if len(mod_items) == 2 {
		m0, _ := hash_of(&ws.evaluation, mod_items[0])
		m1, _ := hash_of(&ws.evaluation, mod_items[1])
		testing.expect_value(t, m0, odin_hash)
		testing.expect_value(t, m1, nasm_hash)
	}

	// 4. Canonical determinism: different field orders produce byte-identical output!
	out_a, out_b: [512]u8
	len_a, ok_a := declaration_evaluate_to_buffer(ws, "{ b = 2, a = 1, c = 3 }", "", cfg, out_a[:])
	len_b, ok_b := declaration_evaluate_to_buffer(ws, "{ c = 3, a = 1, b = 2 }", "", cfg, out_b[:])
	testing.expect(t, ok_a && ok_b && len_a == len_b)
	testing.expect_value(t, blake3.hash(out_a[declaration_eval.OUTPUT_HEADER_BYTES:len_a]), blake3.hash(out_b[declaration_eval.OUTPUT_HEADER_BYTES:len_b]))
}

// declaration takes a tree: declaration(here()) reads the declaration of
// the source tree, as the guides show it, and the hash of one exact
// declaration still names one. A module file and a text name no
// declaration, and are refused.
@(test)
a_declaration_is_read_from_a_tree :: proc(t: ^testing.T) {
	ws := new_workspace()
	here_hash, _ := hash_literal_of("the source tree of a project")
	_, module_lit := hash_literal_of("a module file")
	declaration_source := "{\n  name = \"kernel\",\n}\n"
	bundle_buf: [4096]u8
	entries := [1]declaration_eval.Bundle_Input_Entry {
		{kind = .Declaration_Hash, hash = here_hash, content = declaration_source},
	}
	written, bundle_refusal := declaration_eval.bundle_write(bundle_buf[:], entries[:], true, here_hash)
	testing.expect_value(t, bundle_refusal, declaration_eval.Bundle_Refusal.None)
	bundle_slice := bundle_buf[:written]
	cfg := Declaration_Config{loader = bundle_loader(&bundle_slice), has_here = true, here_hash = here_hash, stack_bytes = DECL_TEST_STACK}

	res := declaration_evaluate(ws, strings.concatenate({"declaration(module(", module_lit, ")).name"}, context.temp_allocator), "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Type_Error && res.detail == "declaration", "a module file is no declaration")
	res = declaration_evaluate(ws, "declaration(\"kernel\").name", "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Type_Error && res.detail == "declaration", "a text is no declaration")

	res = declaration_evaluate(ws, "declaration(here()).name", "", cfg)
	testing.expect(t, res.ok && res.value.kind == .Text && value_text(&ws.evaluation, res.value) == "kernel", "declaration(here()) reads the source tree")
}

// A refusal of the conversion of a recipe is the failure Recipe_Refused,
// with the words of that refusal: a bare hash in the arguments, a tree
// below the first level, a source_date that is a text. A builder given by
// a bare hash is a type error of recipe.
@(test)
a_refused_recipe_says_why :: proc(t: ^testing.T) {
	ws := new_workspace()
	here_hash, here_lit := hash_literal_of("collatz source")
	_, builder_lit := hash_literal_of("the C builder")
	cfg := Declaration_Config{has_here = true, here_hash = here_hash, stack_bytes = DECL_TEST_STACK}
	Case :: struct {
		arguments: string,
		refusal:   plans_recipes.Recipe_Refusal,
	}
	cases := [?]Case {
		{strings.concatenate({"{ source = ", here_lit, " }"}, context.temp_allocator), .Untyped_Hash},
		{"{ deep = { source = here() } }", .Nested_Input},
		{"{ source = here(), source_date = \"today\" }", .Unsupported_Argument},
	}
	for item in cases {
		source := strings.concatenate({"recipe(module(", builder_lit, "), ", item.arguments, ")"}, context.temp_allocator)
		res := declaration_evaluate(ws, source, "", cfg)
		testing.expectf(t, !res.ok && res.failure_kind == .Recipe_Refused, "%s: %v", item.arguments, res.failure_kind)
		testing.expect_value(t, res.detail, plans_recipes.recipe_refusal_words[item.refusal])
	}
	res := declaration_evaluate(ws, strings.concatenate({"recipe(", builder_lit, ", { source = here() })"}, context.temp_allocator), "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Type_Error && res.detail == "recipe", "a builder by a bare hash is refused")
}

// The buffer of the written arguments holds the largest recipe that
// converts: MAX_RECIPE_INPUTS module files under names of the largest
// length, and argument bytes of exactly MAX_RECIPE_ARG_BYTES. One more byte
// of the text is refused with the words of a recipe too large, not as a
// fault of a pool.
@(test)
the_largest_recipe_fits_its_written_arguments :: proc(t: ^testing.T) {
	ws := new_workspace()
	_, builder_lit := hash_literal_of("the C builder")
	recipe_source :: proc(builder_lit: string, text_bytes: int) -> string {
		parts := make([dynamic]string, context.temp_allocator)
		append(&parts, "recipe(module(", builder_lit, "), {\n")
		for index in 0 ..< plans_recipes.MAX_RECIPE_INPUTS {
			name := make([]u8, plans_recipes.MAX_ENTRY_NAME_BYTES, context.temp_allocator)
			for &item in name {
				item = 'n'
			}
			name[0] = 'a' + u8(index / 26)
			name[1] = 'a' + u8(index % 26)
			_, module_lit := hash_literal_of(string(name))
			append(&parts, "  ", string(name), " = module(", module_lit, "),\n")
		}
		text := make([]u8, text_bytes, context.temp_allocator)
		for &item in text {
			item = 'x'
		}
		append(&parts, "  t = \"", string(text), "\",\n})\n")
		return strings.concatenate(parts[:], context.temp_allocator)
	}
	// The record of the other fields: its head (5 bytes), the name "t" (5),
	// the tag (1) and the length of the text (4), then the text.
	text_bytes := plans_recipes.MAX_RECIPE_ARG_BYTES - 15
	// The source holds the text of the largest arguments and the lines of
	// each input: past the bound of a declaration file, which a caller
	// raises with text_bytes_most.
	cfg := Declaration_Config{stack_bytes = DECL_TEST_STACK, text_bytes_most = 256 * 1024}
	res := declaration_evaluate(ws, recipe_source(builder_lit, text_bytes), "", cfg)
	testing.expectf(t, res.ok && res.value.kind == .Recipe_Ref, "the largest recipe converts: %v %s", res.failure_kind, res.detail)
	testing.expect_value(t, ws.recipe_spec.input_count, u32(plans_recipes.MAX_RECIPE_INPUTS))
	testing.expect_value(t, ws.recipe_spec.arguments_length, u32(plans_recipes.MAX_RECIPE_ARG_BYTES))

	res = declaration_evaluate(ws, recipe_source(builder_lit, text_bytes + 1), "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Recipe_Refused, "one more byte is refused")
	testing.expect_value(t, res.detail, plans_recipes.recipe_refusal_words[.Arguments_Too_Large])
}

// Records larger than 1,024 fields and deeply nested large records serialize
// cleanly in canonical UTF-8 key order without hitting static field or name
// pool caps.
@(test)
a_record_has_the_most_fields_and_the_pool_the_most_names :: proc(t: ^testing.T) {
	ws := new_workspace(2)
	cfg := Declaration_Config{stack_bytes = DECL_TEST_STACK, text_bytes_most = 256 * 1024}
	fields :: proc(builder: ^strings.Builder, prefix: string, count: int) {
		for index in 0 ..< count {
			fmt.sbprintf(builder, "%s%d = %d,\n", prefix, index, index)
		}
	}
	serialize :: proc(ws: ^Declaration_Workspace, source: string, cfg: Declaration_Config) -> declaration_eval.Failure_Kind {
		res := declaration_evaluate(ws, source, "", cfg)
		if !res.ok {
			return res.failure_kind
		}
		output := make([]u8, 1024 * 1024, context.temp_allocator)
		_, failure := declaration_serialize_value(ws, res.value, output)
		return failure
	}
	for count in ([?]int{DECLARATION_RECORD_FIELDS_LIMIT, DECLARATION_RECORD_FIELDS_LIMIT + 500}) {
		builder := strings.builder_make(context.temp_allocator)
		strings.write_string(&builder, "{\n")
		fields(&builder, "f", count)
		strings.write_string(&builder, "}\n")
		failure := serialize(ws, strings.to_string(builder), cfg)
		testing.expectf(t, failure == .None, "a record of %d fields: %v", count, failure)
	}
	// Three nested large records succeed with zero static 2048-name cap.
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "{\n")
	fields(&builder, "outer", DECLARATION_RECORD_FIELDS_LIMIT - 1)
	strings.write_string(&builder, "inner = {\n")
	fields(&builder, "f", DECLARATION_RECORD_FIELDS_LIMIT - 1)
	strings.write_string(&builder, "last = { x = 1 },\n")
	strings.write_string(&builder, "},\n}\n")
	failure := serialize(ws, strings.to_string(builder), cfg)
	testing.expectf(t, failure == .None, "three nested large records: %v", failure)
}

// A file past the share of text of the scale 0: refused there for its node
// pool, with the pool named, then evaluated whole at the scale that
// declaration_scale_after gives. The scales at their edges, and a memory
// too short or off its alignment, which no workspace takes.
@(test)
a_declaration_file_past_64_kib_takes_a_larger_scale :: proc(t: ^testing.T) {
	testing.expect_value(t, declaration_scale_of_text(0), uint(0))
	testing.expect_value(t, declaration_scale_of_text(DECLARATION_UNIT_TEXT_BYTES), uint(0))
	testing.expect_value(t, declaration_scale_of_text(DECLARATION_UNIT_TEXT_BYTES + 1), uint(1))
	testing.expect_value(t, declaration_scale_of_text(lex_parser.DECLARATION_TEXT_BYTES_MOST), uint(DECLARATION_SCALE_MOST))
	testing.expect_value(t, declaration_scale_of_text(max(u64)), uint(DECLARATION_SCALE_MOST))
	testing.expect_value(t, declaration_pools_of_scale(1), Declaration_Pools{nodes = 2 * DECLARATION_NODE_POOL, text_bytes = 2 * DECLARATION_TEXT_ARENA})

	// A list of small records: about 8 nodes for each 20 bytes, so a file of
	// 80 KiB passes the node pool of the scale 0.
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "{ items = [\n")
	count := 0
	for strings.builder_len(builder) < 80 * 1024 {
		fmt.sbprintf(&builder, "  {{ a = %d, b = %d }},\n", count, count + 1)
		count += 1
	}
	strings.write_string(&builder, "], n = 7 }\n")
	source := strings.to_string(builder)
	cfg := Declaration_Config{stack_bytes = DECL_TEST_STACK, text_bytes_most = lex_parser.DECLARATION_TEXT_BYTES_MOST}
	scale := uint(0)
	small := new_workspace(scale)
	res := declaration_evaluate(small, source, "n", cfg)
	testing.expectf(t, !res.ok && res.failure_kind == .Pool_Exhausted, "the scale 0 runs out: %v", res.failure_kind)
	testing.expect_value(t, small.exhausted, Declaration_Pool.Nodes)
	next, larger := declaration_scale_after(small, scale)
	testing.expect(t, larger && next == 1)
	for {
		ws := new_workspace(next)
		res = declaration_evaluate(ws, source, "n", cfg)
		if res.ok {
			break
		}
		next, larger = declaration_scale_after(ws, next)
		if !testing.expectf(t, larger, "no scale holds the file: %v", res.failure_kind) {
			return
		}
	}
	testing.expect(t, res.value.kind == .Integer && value_integer(res.value) == 7)
	_, larger = declaration_scale_after(small, DECLARATION_SCALE_MOST)
	testing.expect(t, !larger)

	// A refusal that no pool of the scale makes gives no larger scale.
	ws := new_workspace()
	res = declaration_evaluate(ws, "{ a = ", "", cfg)
	testing.expect(t, !res.ok)
	_, larger = declaration_scale_after(ws, 0)
	testing.expect(t, !larger)

	// No workspace on a memory one byte short, or off the alignment.
	pools := declaration_pools_of_scale(0)
	memory, _ := mem.alloc_bytes(declaration_workspace_bytes(pools) + 64, 64, context.temp_allocator)
	other := new(Declaration_Workspace, context.temp_allocator)
	testing.expect(t, !declaration_workspace_carve(other, memory[:declaration_workspace_bytes(pools) - 1], pools))
	testing.expect(t, !declaration_workspace_carve(other, memory[1:], pools))
	testing.expect(t, other.nodes == nil && other.vm_pools.text_arena == nil)
	testing.expect(t, declaration_workspace_carve(other, memory, pools))
}

// Per-shape Slice_Hash_Index boundary and overlay compaction tests (L3):
// - <= 16 fields: direct Sym_Id scan, no hash index built.
// - 17 fields (one past SHAPE_HASH_INDEX_THRESHOLD): hash index built and hit.
// - 1024 fields + 20 chained overlays (crossing OVERLAY_COMPACT_THRESHOLD):
//   compacts without forcing broken sibling fields; miss returns Field_Unknown.
@(test)
declaration_shape_hash_index_and_overlay_compaction :: proc(t: ^testing.T) {
	make_rec_src :: proc(count: int, query_field: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "let r = {\n")
		for i in 0 ..< count {
			fmt.sbprintf(&b, "  f_%04d = %d,\n", i, i * 10 + 1)
		}
		fmt.sbprintf(&b, "  broken = 1 / 0,\n}} in r.%s\n", query_field)
		return strings.to_string(b)
	}

	ws := new_workspace(2)
	prof: Evaluation_Profile

	// 15 + 1 = 16 fields (at inline threshold): no hash index built.
	res := declaration_evaluate(ws, make_rec_src(15, "f_0014"), "", {stack_bytes = DECL_TEST_STACK, profile = &prof})
	testing.expect(t, res.ok && value_integer(res.value) == 141)
	testing.expect_value(t, prof.shape_indices_built, u64(0))
	testing.expect_value(t, prof.shape_hash_lookups, u64(0))

	// 16 + 1 = 17 fields (one past threshold): per-shape Slice_Hash_Index built and hit.
	prof = {}
	res = declaration_evaluate(ws, make_rec_src(16, "f_0015"), "", {stack_bytes = DECL_TEST_STACK, profile = &prof})
	testing.expect(t, res.ok && value_integer(res.value) == 151)
	testing.expect_value(t, prof.shape_indices_built, u64(1))
	testing.expect(t, prof.shape_hash_lookups >= 1)

	// Missing field on indexed >16-field shape returns Field_Unknown cleanly.
	prof = {}
	res = declaration_evaluate(ws, make_rec_src(32, "no_such_field"), "", {stack_bytes = DECL_TEST_STACK, profile = &prof})
	testing.expect(t, !res.ok && res.failure_kind == .Field_Unknown && res.detail == "no_such_field")
	testing.expect(t, prof.shape_indices_built >= 1)

	// 20 chained overlays over a 64-field record containing a broken field:
	// crosses OVERLAY_COMPACT_THRESHOLD (16) and compacts without forcing broken!
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "let r0 = {\n  broken = 1 / 0,\n")
	for i in 0 ..< 64 {
		fmt.sbprintf(&b, "  k_%02d = %d,\n", i, i)
	}
	strings.write_string(&b, "},\n")
	for ov in 1 ..= 20 {
		fmt.sbprintf(&b, "  r%d = r%d with {{ k_%02d = %d }},\n", ov, ov - 1, ov % 64, ov * 100)
	}
	strings.write_string(&b, "in r20.k_01 + r20.k_20 + r20.k_60\n")
	prof = {}
	res = declaration_evaluate(ws, strings.to_string(b), "", {stack_bytes = DECL_TEST_STACK, profile = &prof})
	testing.expectf(t, res.ok && value_integer(res.value) == 100 + 2000 + 60, "overlay compact failed: ok=%v fail=%v val=%d", res.ok, res.failure_kind, value_integer(res.value))
	testing.expect(t, prof.overlay_compacts >= 1)
	testing.expect(t, prof.shape_indices_built >= 1)
}
