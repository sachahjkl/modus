#+build !freestanding
package lex_evaluator

import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/declaration_eval"

@(private = "file")
DECL_TEST_STACK :: 2 * 1024 * 1024

@(private = "file")
new_workspace :: proc() -> ^Declaration_Workspace {
	return new(Declaration_Workspace, context.temp_allocator)
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
	testing.expect_value(t, res.value.integer, i64(42))

	// Forcing .bad DOES fail with Division_By_Zero.
	res = declaration_evaluate(ws, "{ good = 42, bad = 1 / 0 }", "bad", cfg)
	testing.expect(t, !res.ok)
	testing.expect_value(t, res.failure_kind, declaration_eval.Failure_Kind.Division_By_Zero)

	// Sibling field calls an effectful command: selecting .good never triggers it.
	res = declaration_evaluate(ws, "{ good = 7, bad = shutdown() }", "good", cfg)
	testing.expect(t, res.ok && res.value.integer == 7)

	// Nested project outputs: selecting outputs.tools does not force outputs.image.
	res = declaration_evaluate(ws, "project {\n  outputs = {\n    tools = 100 + 23,\n    image = 1 / 0,\n  },\n}", "outputs.tools", cfg)
	testing.expect(t, res.ok && res.value.integer == 123)

	// Lazy `with`: overriding a broken field never forces the overridden value.
	res = declaration_evaluate(ws, "({ a = 1, b = 1 / 0 } with { b = 99 }).b", "", cfg)
	testing.expect(t, res.ok && res.value.integer == 99)
	res = declaration_evaluate(ws, "({ a = 1, b = 1 / 0 } with { b = 99 }).a", "", cfg)
	testing.expect(t, res.ok && res.value.integer == 1)

	// Lazy `if`: untaken branch is never forced.
	res = declaration_evaluate(ws, "if true then 11 else 1 / 0", "", cfg)
	testing.expect(t, res.ok && res.value.integer == 11)
	res = declaration_evaluate(ws, "if false then 1 / 0 else 22", "", cfg)
	testing.expect(t, res.ok && res.value.integer == 22)

	// Lazy `let`: unused broken binding is never forced.
	res = declaration_evaluate(ws, "let boom = 1 / 0, ok = 55 in ok", "", cfg)
	testing.expect(t, res.ok && res.value.integer == 55)

	// Memoization: forcing the same field a second time costs 0 additional steps.
	res = declaration_evaluate(ws, "{ x = 2 * 3 + 4, unused = 1 / 0 }", "", cfg)
	testing.expect(t, res.ok)
	v1, ok1 := declaration_force_path(ws, res.value, "x")
	testing.expect(t, ok1 && v1.integer == 10)
	steps_after_first := ws.evaluation.steps
	v2, ok2 := declaration_force_path(ws, res.value, "x")
	testing.expect(t, ok2 && v2.integer == 10)
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

	// Step/fuel bound stops infinite recursion cleanly.
	res := declaration_evaluate(ws, "let loop = (n) => loop(n + 1) in loop(0)", "", {budget = 120, depth_limit = 500, stack_bytes = DECL_TEST_STACK})
	testing.expect(t, !res.ok)
	testing.expect_value(t, res.failure_kind, declaration_eval.Failure_Kind.Step_Bound_Reached)
	testing.expect_value(t, res.steps_taken, u32(120))

	// Depth bound stops deep recursion before stack overflow.
	res = declaration_evaluate(ws, "let down = (n) => 1 + down(n + 1) in down(0)", "", {budget = 100_000, depth_limit = 24, stack_bytes = DECL_TEST_STACK})
	testing.expect(t, !res.ok)
	testing.expect_value(t, res.failure_kind, declaration_eval.Failure_Kind.Depth_Bound_Reached)

	// Stack byte bound stops deep recursion when tight.
	res = declaration_evaluate(ws, "let down = (n) => 1 + down(n + 1) in down(0)", "", {budget = 100_000, depth_limit = 500, stack_bytes = 32 * 1024})
	testing.expect(t, !res.ok)
	testing.expect_value(t, res.failure_kind, declaration_eval.Failure_Kind.Stack_Bound_Reached)

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
	testing.expect(t, res.ok && res.value.kind == .Integer && res.value.integer == 720)
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
		testing.expect_value(t, items[0].integer, i64(30))
		testing.expect_value(t, items[1].integer, i64(40))
		testing.expect_value(t, items[2].integer, i64(50))
		testing.expect_value(t, items[3].integer, i64(60))
	}

	res = declaration_evaluate(ws, source, "greeting", cfg)
	testing.expect(t, res.ok && res.value.kind == .Text && res.value.text == "hello modus")
	res = declaration_evaluate(ws, source, "equal_check", cfg)
	testing.expect(t, res.ok && res.value.kind == .Boolean && res.value.integer == 1)
	res = declaration_evaluate(ws, source, "diff_check", cfg)
	testing.expect(t, res.ok && res.value.kind == .Boolean && res.value.integer == 1)
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
	testing.expect(t, gt_follow.ok && gt_follow.value.kind == .Follow_Ref && gt_follow.value.text == "gui_toolkit")
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
