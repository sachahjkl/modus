#+build !freestanding
package lex_evaluator

import "core:mem"
import "core:strings"
import "core:testing"
import "modus:contract/declaration_eval"

@(private = "file")
l4_workspace :: proc(scale: uint = 1) -> ^Declaration_Workspace {
	ws := new(Declaration_Workspace, context.temp_allocator)
	pools := declaration_pools_of_scale(scale)
	memory, _ := mem.alloc_bytes(declaration_workspace_bytes(pools), 64, context.temp_allocator)
	ok := declaration_workspace_carve(ws, memory, pools)
	assert(ok)
	return ws
}

// String escapes and `${expr}` interpolation: valid escapes, Unicode scalar
// values, nested interpolation, formatted scalar kinds, and strict refusals.
@(test)
l4_string_escapes_and_interpolation :: proc(t: ^testing.T) {
	ws := l4_workspace()
	cfg := Declaration_Config{stack_bytes = 2 * 1024 * 1024}

	// Refusals first: bad escapes, control chars, surrogate, out-of-range, unclosed interp.
	bad_parse := [?]string{
		`"bad \x"`,
		`"ctl \n"`,
		`"ctl \r"`,
		`"ctl \t"`,
		`"ctl \u{0}"`,
		`"ctl \u{1F}"`,
		`"ctl \u{7F}"`,
		`"ctl \u{9F}"`,
		`"surrogate \u{D800}"`,
		`"high \u{110000}"`,
		`"unclosed ${1 + 2"`,
	}
	for src in bad_parse {
		res := declaration_evaluate(ws, src, "", cfg)
		testing.expectf(t, !res.ok && res.failure_kind == .Parse_Error, "%q: got ok=%v fail=%v", src, res.ok, res.failure_kind)
	}

	// Functions, lists, and records are refused inside `${...}`.
	bad_kinds := [?]string{
		`"x=${(a) => a}"`,
		`"x=${[1, 2]}"`,
		`"x=${{ a = 1 }}"`,
	}
	for src in bad_kinds {
		res := declaration_evaluate(ws, src, "", cfg)
		testing.expectf(t, !res.ok && res.failure_kind == .Type_Error, "%q: got ok=%v fail=%v", src, res.ok, res.failure_kind)
	}

	// Escapes and interpolation successes — round-tripped through
	// declaration_evaluate_to_buffer + declaration_eval.output_validate!
	out_buf := make([]u8, 4096, context.temp_allocator)
	esc_src := `"a \"quoted\" \\ \$done \u{41}\u{1F600}"`
	res := declaration_evaluate(ws, esc_src, "", cfg)
	testing.expect(t, res.ok && res.value.kind == .Text)
	testing.expect_value(t, value_text(&ws.evaluation, res.value), "a \"quoted\" \\ $done A😀")
	w1, ok1 := declaration_evaluate_to_buffer(ws, esc_src, "", cfg, out_buf)
	testing.expect(t, ok1 && w1 > 0)
	_, ref1 := declaration_eval.output_validate(out_buf[:w1])
	testing.expect_value(t, ref1, declaration_eval.Output_Refusal.None)

	interp_src := `let name = "modus", ver = 2, ok = true, m = .Verify in "sys=${name} v${ver} ok=${ok} mode=${m}"`
	res = declaration_evaluate(ws, interp_src, "", cfg)
	testing.expect(t, res.ok && res.value.kind == .Text)
	testing.expect_value(t, value_text(&ws.evaluation, res.value), "sys=modus v2 ok=true mode=Verify")
	w2, ok2 := declaration_evaluate_to_buffer(ws, interp_src, "", cfg, out_buf)
	testing.expect(t, ok2 && w2 > 0)
	_, ref2 := declaration_eval.output_validate(out_buf[:w2])
	testing.expect_value(t, ref2, declaration_eval.Output_Refusal.None)

	// Nested interpolation with escaped quotes inside inner string.
	nested_src := `let x = 7 in "outer(${"inner=\"${x * 2}\""})"`
	res = declaration_evaluate(ws, nested_src, "", cfg)
	testing.expect(t, res.ok && value_text(&ws.evaluation, res.value) == `outer(inner="14")`)
	w3, ok3 := declaration_evaluate_to_buffer(ws, nested_src, "", cfg, out_buf)
	testing.expect(t, ok3 && w3 > 0)
	_, ref3 := declaration_eval.output_validate(out_buf[:w3])
	testing.expect_value(t, ref3, declaration_eval.Output_Refusal.None)

	// Assert refusal buffer with escapes validates cleanly on the wire.
	assert_src := `assert(false, "bad \"arg\" \u{2192} fix", 1)`
	w4, ok4 := declaration_evaluate_to_buffer(ws, assert_src, "", cfg, out_buf)
	testing.expect(t, ok4 && w4 > 0)
	hdr4, ref4 := declaration_eval.output_validate(out_buf[:w4])
	testing.expect_value(t, ref4, declaration_eval.Output_Refusal.None)
	testing.expect_value(t, hdr4.status, declaration_eval.Output_Status.Refused)
	testing.expect_value(t, hdr4.failure_kind, declaration_eval.Failure_Kind.Assertion_Failed)
}

// Boolean operators &&, ||, ! (short-circuit and strict Boolean typing) and
// list concatenation ++.
@(test)
l4_boolean_ops_and_list_concat :: proc(t: ^testing.T) {
	ws := l4_workspace()
	cfg := Declaration_Config{stack_bytes = 2 * 1024 * 1024}

	// Strict Boolean refusals.
	for bad in ([?]string{`!1`, `1 && true`, `true && 1`, `1 || false`, `false || 1`, `1 ++ [2]`, `[1] ++ "a"`}) {
		res := declaration_evaluate(ws, bad, "", cfg)
		testing.expectf(t, !res.ok && res.failure_kind == .Type_Error, "%q: got ok=%v fail=%v", bad, res.ok, res.failure_kind)
	}

	// Short-circuit: RHS division by zero is never evaluated.
	res := declaration_evaluate(ws, `false && (1 / 0 = 0)`, "", cfg)
	testing.expect(t, res.ok && res.value.kind == .Boolean && !value_boolean(res.value))
	res = declaration_evaluate(ws, `true || (1 / 0 = 0)`, "", cfg)
	testing.expect(t, res.ok && res.value.kind == .Boolean && value_boolean(res.value))

	// Precedence: ! > && > || and comparisons bind tighter than && / ||.
	res = declaration_evaluate(ws, `!(1 = 2) && 3 < 4 || false`, "", cfg)
	testing.expect(t, res.ok && value_boolean(res.value))
	res = declaration_evaluate(ws, `false && true || true && !false`, "", cfg)
	testing.expect(t, res.ok && value_boolean(res.value))

	// List concatenation ++.
	res = declaration_evaluate(ws, `[1, 2] ++ [3, 4] ++ [] ++ [5]`, "", cfg)
	testing.expect(t, res.ok && res.value.kind == .List)
	items := list_items_of(&ws.evaluation, res.value)
	testing.expect_value(t, len(items), 5)
	if len(items) == 5 {
		for i in 0 ..< 5 {
			testing.expect_value(t, value_integer(items[i]), i64(i + 1))
		}
	}
}

// Strict record destructuring in let bindings and function parameters:
// strict extra-field refusal, open `...`, lazy defaults, `r @ { ... }`,
// and laziness (unused broken sibling fields never forced).
@(test)
l4_record_destructuring :: proc(t: ^testing.T) {
	ws := l4_workspace()
	cfg := Declaration_Config{stack_bytes = 2 * 1024 * 1024}

	// Refusals: non-record, missing required field, extra field without `...`.
	res := declaration_evaluate(ws, `let { a } = 42 in a`, "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Type_Error)

	res = declaration_evaluate(ws, `let { a, b } = { a = 1 } in a`, "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Field_Unknown && res.detail == "b")

	res = declaration_evaluate(ws, `let { a } = { a = 1, extra = 2 } in a`, "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Field_Unknown && res.detail == "extra")

	res = declaration_evaluate(ws, `let f = ({ a }) => a in f({ a = 1, extra = 2 })`, "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Field_Unknown && res.detail == "extra")

	// Open `...` allows extra fields AND stays lazy on broken extra/sibling fields.
	res = declaration_evaluate(ws, `let { a, b, ... } = { a = 10, b = 1 / 0, extra = 1 / 0 } in a`, "", cfg)
	testing.expect(t, res.ok && value_integer(res.value) == 10)

	// Defaults: lazy when present (broken default never forced!), evaluated when absent.
	res = declaration_evaluate(ws, `let { a, b = 1 / 0 } = { a = 5, b = 7 } in a + b`, "", cfg)
	testing.expect(t, res.ok && value_integer(res.value) == 12)

	res = declaration_evaluate(ws, `let base = 100, { a, b = base + 5 } = { a = 3 } in a + b`, "", cfg)
	testing.expect(t, res.ok && value_integer(res.value) == 108)

	// Function parameter destructuring + as-pattern `r @ { ... }` + earlier param in default.
	res = declaration_evaluate(ws, `let f = (k, r @ { a, b = k * 2, ... }) => a + b + r.c in f(10, { a = 1, c = 4 })`, "", cfg)
	testing.expect(t, res.ok && value_integer(res.value) == 25)
}

// Pure collision-free stdlib: fold, zip, fields, values, has, extend,
// merge_deep, assert, trace.
@(test)
l4_pure_stdlib_and_diagnostics :: proc(t: ^testing.T) {
	ws := l4_workspace()
	cfg := Declaration_Config{stack_bytes = 2 * 1024 * 1024}

	// fold: left-associative, works with empty list and pipe.
	res := declaration_evaluate(ws, `[1, 2, 3, 4] |> fold(0, (acc, x) => acc * 10 + x)`, "", cfg)
	testing.expect(t, res.ok && value_integer(res.value) == 1234)
	res = declaration_evaluate(ws, `fold([], 99, (acc, x) => acc + x)`, "", cfg)
	testing.expect(t, res.ok && value_integer(res.value) == 99)
	res = declaration_evaluate(ws, `fold(123, 0, (a, b) => a)`, "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Type_Error)
	res = declaration_evaluate(ws, `fold([1], 0, (a) => a)`, "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Type_Error)

	// zip: pairs { first, second } truncated to shorter list.
	res = declaration_evaluate(ws, `zip([10, 20, 30], [1, 2]) |> map((p) => p.first + p.second)`, "", cfg)
	testing.expect(t, res.ok && res.value.kind == .List)
	zitems := list_items_of(&ws.evaluation, res.value)
	testing.expect_value(t, len(zitems), 2)
	if len(zitems) == 2 {
		testing.expect_value(t, value_integer(zitems[0]), i64(11))
		testing.expect_value(t, value_integer(zitems[1]), i64(22))
	}

	// fields & has: non-forcing (broken sibling fields NEVER forced!), UTF-8 sorted.
	res = declaration_evaluate(ws, `fields({ z = 1 / 0, a = 1 / 0, m = 1 / 0 })`, "", cfg)
	testing.expect(t, res.ok && res.value.kind == .List)
	fitems := list_items_of(&ws.evaluation, res.value)
	testing.expect_value(t, len(fitems), 3)
	if len(fitems) == 3 {
		testing.expect_value(t, value_text(&ws.evaluation, fitems[0]), "a")
		testing.expect_value(t, value_text(&ws.evaluation, fitems[1]), "m")
		testing.expect_value(t, value_text(&ws.evaluation, fitems[2]), "z")
	}

	res = declaration_evaluate(ws, `has({ a = 1 / 0 }, "a") && !has({ a = 1 / 0 }, "b")`, "", cfg)
	testing.expect(t, res.ok && value_boolean(res.value))

	// values: forces fields in canonical ascending UTF-8 key order.
	res = declaration_evaluate(ws, `values({ c = 3, a = 1, b = 2 })`, "", cfg)
	testing.expect(t, res.ok && res.value.kind == .List)
	vitems := list_items_of(&ws.evaluation, res.value)
	testing.expect_value(t, len(vitems), 3)
	if len(vitems) == 3 {
		testing.expect_value(t, value_integer(vitems[0]), i64(1))
		testing.expect_value(t, value_integer(vitems[1]), i64(2))
		testing.expect_value(t, value_integer(vitems[2]), i64(3))
	}

	// extend: shallow lazy field addition + override (with stays strictly override-only!).
	res = declaration_evaluate(ws, `let r = extend({ a = 1, bad = 1 / 0 }, { b = 2, a = 10 }) in r.a + r.b`, "", cfg)
	testing.expect(t, res.ok && value_integer(res.value) == 12)
	res = declaration_evaluate(ws, `fields(extend({ c = 1 }, { a = 2, b = 3 }))`, "", cfg)
	testing.expect(t, res.ok && len(list_items_of(&ws.evaluation, res.value)) == 3)

	// merge_deep: recursive lazy merge (overriding broken scalar never forces left;
	// merging nested records never forces unused broken siblings).
	res = declaration_evaluate(ws, `
let
  a = { net = { port = 80, broken = 1 / 0 }, dead = 1 / 0, keep = 5 },
  b = { net = { host = "local" }, dead = 42 },
  m = merge_deep(a, b)
in "${m.net.host}:${m.net.port}:${m.dead}:${m.keep}"
`, "", cfg)
	testing.expect(t, res.ok && value_text(&ws.evaluation, res.value) == "local:80:42:5")

	// merge_deep step-budget protection against deep nesting / exponential blowup.
	deep_b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 70 {
		strings.write_string(&deep_b, "{ a = ")
	}
	strings.write_string(&deep_b, "1")
	for _ in 0 ..< 70 {
		strings.write_string(&deep_b, " }")
	}
	deep_rec := strings.to_string(deep_b)
	res = declaration_evaluate(ws, strings.concatenate({"let x = ", deep_rec, " in merge_deep(x, x)"}, context.temp_allocator), "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Depth_Bound_Reached)

	// assert(cond, msg, value): lazy msg when true; Assertion_Failed with msg when false.
	res = declaration_evaluate(ws, `assert(true, 1 / 0, 77)`, "", cfg)
	testing.expect(t, res.ok && value_integer(res.value) == 77)
	res = declaration_evaluate(ws, `assert(false, "port must be positive", 77)`, "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Assertion_Failed && res.detail == "port must be positive")
	res = declaration_evaluate(ws, `assert(1, "bad", 77)`, "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Type_Error)

	// trace(msg, value): records to caller Trace_Log, sets res.traced, zero effect on value.
	tlog: Trace_Log
	tcfg := cfg
	tcfg.trace_log = &tlog
	res = declaration_evaluate(ws, `trace("step 1", trace("step 2", 42))`, "", tcfg)
	testing.expect(t, res.ok && value_integer(res.value) == 42 && res.traced)
	testing.expect_value(t, tlog.count, 2)
	testing.expect_value(t, tlog.entries[0].message, "step 1")
	testing.expect_value(t, tlog.entries[1].message, "step 2")

	// Diagnostics: byte span, force stack (non-tail call keeps caller frame),
	// and OSA nearest-name suggestions.
	res = declaration_evaluate(ws, `let f = (r) => r.heigth in 1 + f({ height = 10, width = 20 })`, "", cfg)
	testing.expect(t, !res.ok && res.failure_kind == .Field_Unknown && res.detail == "heigth")
	testing.expect(t, res.frame_count >= 2)
	testing.expect(t, res.span_end > res.span_start)
	testing.expect(t, res.suggestion_count >= 1 && res.suggestions[0] == "height")

	// Unknown top-level name gets nearest-name suggestion from bindings/stdlib.
	res = declaration_evaluate(ws, `extnd({ a = 1 }, { b = 2 })`, "", cfg)
	testing.expect(t, !res.ok && res.suggestion_count >= 1 && res.suggestions[0] == "extend")
}
