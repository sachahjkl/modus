#+build !freestanding
package lex_evaluator

import "core:fmt"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:contract/value_kinds"
import "modus:lex_parser"

@(private = "file")
v3_decl_ws :: proc(pools := Declaration_Pools{nodes = 16384, text_bytes = 256 * 1024}) -> ^Declaration_Workspace {
	ws := new(Declaration_Workspace, context.temp_allocator)
	nbytes := declaration_workspace_bytes(pools)
	raw := make([]u8, nbytes + 64, context.temp_allocator)
	addr := uintptr(raw_data(raw))
	aligned := (addr + 63) &~ uintptr(63)
	off := int(aligned - addr)
	ok := declaration_workspace_carve(ws, raw[off:off + nbytes], pools)
	assert(ok)
	return ws
}

@(private = "file")
v3_decl_eval :: proc(source: string, field_path: string = "", config: Declaration_Config = {}) -> (^Declaration_Workspace, Declaration_Result) {
	ws := v3_decl_ws()
	res := declaration_evaluate(ws, source, field_path, config)
	return ws, res
}

// Feature 1: Nested path overrides in `with` across Console and Declaration modes.
@(test)
v3_nested_with_overrides :: proc(t: ^testing.T) {
	// Multi-level nested override + mixed flat & nested in Declaration mode.
	src := `
let base = {
  top = 1,
  bad_sibling = 1 / 0,
  display = { font = .vector, size = 12, bad = 1 / 0 },
  net = { host = "a", port = 80, tls = { enabled = false, version = 1 } },
} in
base with {
  top = 2,
  display.font = .spleen,
  net.port = 8080,
  net.tls.enabled = true,
  net.host = 1 / 0,
}
`
	ws, res := v3_decl_eval(src, "display.font")
	testing.expectf(t, res.ok, "expected ok, got %v (%q)", res.failure_kind, res.detail)
	testing.expect_value(t, res.value.kind, Kind.Member)
	testing.expect_value(t, member_name_of(&ws.evaluation, res.value), "spleen")

	// Sibling fields and unforced leaf overrides stay lazy (1/0 never triggered!).
	ws2, res2 := v3_decl_eval(src, "net.tls.enabled")
	testing.expectf(t, res2.ok && res2.value.kind == .Boolean && value_boolean(res2.value), "net.tls.enabled failed: %v", res2.failure_kind)
	_ = ws2
	ws3, res3 := v3_decl_eval(src, "net.tls.version")
	testing.expect(t, res3.ok && value_integer(res3.value) == 1)
	_ = ws3
	ws4, res4 := v3_decl_eval(src, "top")
	testing.expect(t, res4.ok && value_integer(res4.value) == 2)
	_ = ws4
	// Forcing the poisoned leaf override triggers Division_By_Zero.
	_, res_bad := v3_decl_eval(src, "net.host")
	testing.expect_value(t, res_bad.failure_kind, declaration_eval.Failure_Kind.Division_By_Zero)

	// Console mode nested with on record literal inside let.
	crun := run_of(`let cfg = { a = { b = 1, c = 2 }, d = 3 } in (cfg with { a.b = 99 }).a.b`)
	testing.expectf(t, crun.ok && crun.value.integer == 99, "console nested with: %v (%v)", crun.ok, crun.evaluation.refusal.refusal)

	// Plan_Value and Project_Value tag preservation through nested with.
	plan_src := `
let p = plan { values = { display = { font = .vector } } } in
p with { values.display.font = .spleen }
`
	pws, pres := v3_decl_eval(plan_src)
	testing.expectf(t, pres.ok && pres.value.kind == .Plan_Value, "plan tag lost: %v (%v)", pres.value.kind, pres.failure_kind)
	pfont, pfok := declaration_force_path(pws, pres.value, "values.display.font")
	testing.expect(t, pfok && pfont.kind == .Member && member_name_of(&pws.evaluation, pfont) == "spleen")

	proj_src := `
let p = project { outputs = { default = 1, extra = 2 } } in
p with { outputs.default = 9 }
`
	prws, prres := v3_decl_eval(proj_src)
	testing.expectf(t, prres.ok && prres.value.kind == .Project_Value, "project tag lost: %v", prres.value.kind)
	pdef, pdok := declaration_force_path(prws, prres.value, "outputs.default")
	testing.expect(t, pdok && value_integer(pdef) == 9)

	// Refusals: missing intermediate, missing leaf, non-record intermediate, dotted path outside with, duplicate & prefix conflict.
	_, r1 := v3_decl_eval(`{ a = { b = 1 } } with { nope.b = 2 }`)
	testing.expect_value(t, r1.failure_kind, declaration_eval.Failure_Kind.Field_Unknown)

	_, r2 := v3_decl_eval(`{ a = { b = 1 } } with { a.nope = 2 }`)
	testing.expect_value(t, r2.failure_kind, declaration_eval.Failure_Kind.Field_Unknown)

	_, r3 := v3_decl_eval(`{ a = 42 } with { a.b = 2 }`)
	testing.expect_value(t, r3.failure_kind, declaration_eval.Failure_Kind.Type_Error)

	_, r4 := v3_decl_eval(`{ a.b = 1 }`)
	testing.expect_value(t, r4.failure_kind, declaration_eval.Failure_Kind.Parse_Error)
	c4 := run_of(`{ a.b = 1 }`)
	testing.expect_value(t, c4.evaluation.refusal.refusal, Refusal.Literal_Path_Outside_With)

	_, r5 := v3_decl_eval(`{ a = { b = 1 } } with { a.b = 2, a.b = 3 }`)
	testing.expect_value(t, r5.failure_kind, declaration_eval.Failure_Kind.Parse_Error)

	_, r6 := v3_decl_eval(`{ a = { b = 1 } } with { a = { b = 2 }, a.b = 3 }`)
	testing.expect_value(t, r6.failure_kind, declaration_eval.Failure_Kind.Parse_Error)
}

// Feature 2: Record field shorthand (punning) across Console and Declaration modes.
@(test)
v3_record_shorthand_punning :: proc(t: ^testing.T) {
	src := `
let host = "box", port = 8080, base = { host = "old", port = 80, tls = false } in
let r = { host, port, extra = true } in
let u = base with { host, port } in
{ rh = r.host, rp = r.port, uh = u.host, up = u.port, ut = u.tls }
`
	ws, res := v3_decl_eval(src, "uh")
	testing.expect(t, res.ok && value_text(&ws.evaluation, res.value) == "box")
	_, res2 := v3_decl_eval(src, "up")
	testing.expect(t, res2.ok && value_integer(res2.value) == 8080)

	crun := run_of(`let x = 3, y = 4, width = 5, height = 6 in area({ x, y, width, height })`)
	testing.expectf(t, crun.ok && crun.value.integer == 30, "console punning: %v (%v)", crun.ok, crun.evaluation.refusal.refusal)

	// Unbound variable in shorthand reports Unknown_Name at the field span.
	_, bad := v3_decl_eval(`{ missing_var }`, "missing_var")
	testing.expect_value(t, bad.failure_kind, declaration_eval.Failure_Kind.Unknown_Name)
	testing.expect_value(t, bad.detail, "missing_var")
}

// Feature 3: Typed unit literals, exact unit algebra, formatting, serialization, and Query_Cache.
@(test)
v3_typed_unit_literals_and_algebra :: proc(t: ^testing.T) {
	// All 9 unit names parse and evaluate identically in both modes.
	Unit_Case :: struct {
		expr: string,
		val:  i64,
		unit: value_kinds.Integer_Unit,
	}
	cases := [?]Unit_Case {
		{"64 bytes", 64, value_kinds.size_in(.Bytes)},
		{"16 KiB", 16, value_kinds.size_in(.Kibibytes)},
		{"32 MiB", 32, value_kinds.size_in(.Mebibytes)},
		{"2048 pages", 2048, value_kinds.size_in(.Pages)},
		{"128 blocks", 128, value_kinds.size_in(.Blocks)},
		{"500 ns", 500, value_kinds.time_in(.Nanoseconds)},
		{"250 us", 250, value_kinds.time_in(.Microseconds)},
		{"120 ms", 120, value_kinds.time_in(.Milliseconds)},
		{"5 s", 5, value_kinds.time_in(.Seconds)},
		// Algebra
		{"1 MiB + 512 KiB", 1536, value_kinds.size_in(.Kibibytes)},
		{"2 pages - 4096 bytes", 4096, value_kinds.size_in(.Bytes)},
		{"1 s - 250 ms", 750, value_kinds.time_in(.Milliseconds)},
		{"10 blocks + 5 blocks", 15, value_kinds.size_in(.Blocks)},
		{"3 * 64 MiB", 192, value_kinds.size_in(.Mebibytes)},
		{"64 MiB * 2", 128, value_kinds.size_in(.Mebibytes)},
		{"64 MiB / 2", 32, value_kinds.size_in(.Mebibytes)},
		{"1 MiB / 4 KiB", 256, {}},
		{"1 s / 250 ms", 4, {}},
		{"10 MiB % 3", 1, value_kinds.size_in(.Mebibytes)},
		{"1 MiB % 300 KiB", 124, value_kinds.size_in(.Kibibytes)},
		{"-(64 MiB)", -64, value_kinds.size_in(.Mebibytes)},
	}
	for item in cases {
		crun := run_of(item.expr)
		testing.expectf(t, crun.ok && crun.value.kind == .Integer && crun.value.integer == item.val && crun.value.integer_unit == item.unit,
			"console %q: got (%v, %d, %v), want (%d, %v) refusal=%v",
			item.expr, crun.ok, crun.value.integer, crun.value.integer_unit, item.val, item.unit, crun.evaluation.refusal.refusal)
		_, dres := v3_decl_eval(item.expr)
		testing.expectf(t, dres.ok && dres.value.kind == .Integer && value_integer(dres.value) == item.val && value_unit(dres.value) == item.unit,
			"decl %q: got (%v, %d, %v), want (%d, %v) fail=%v",
			item.expr, dres.ok, value_integer(dres.value), value_unit(dres.value), item.val, item.unit, dres.failure_kind)
	}

	// Comparisons across compatible units.
	for bexpr in ([?]string{"1 MiB = 1024 KiB", "1 MiB = 256 pages", "1 s > 999 ms", "500 us <= 1 ms", "10 blocks != 11 blocks"}) {
		crun := run_of(bexpr)
		testing.expectf(t, crun.ok && crun.value.kind == .Boolean && crun.value.integer == 1, "%q failed", bexpr)
	}

	// Unit refusals (incompatible dimensions, bare+unit, blocks vs pages, unit*unit, scalar/unit, scalar%unit, overflow).
	refused := [?]struct{ expr: string, want: Refusal } {
		{"64 MiB + 1", .Unit_Mismatch},
		{"1 MiB + 1 ms", .Unit_Mismatch},
		{"1 pages + 1 blocks", .Unit_Mismatch},
		{"2 MiB * 3 MiB", .Unit_Mismatch},
		{"10 / 2 MiB", .Unit_Mismatch},
		{"10 % 2 MiB", .Unit_Mismatch},
		{"1 MiB = 1048576", .Unit_Mismatch},
		{"1 MiB < 1 ms", .Unit_Mismatch},
		{"1000000000000000 MiB + 1 bytes", .Overflow},
	}
	for r in refused {
		crun := run_of(r.expr)
		testing.expectf(t, !crun.ok && crun.evaluation.refusal.refusal == r.want,
			"expected %v for %q, got ok=%v refusal=%v", r.want, r.expr, crun.ok, crun.evaluation.refusal.refusal)
	}

	// String interpolation formats units cleanly.
	irun := run_of(`"mem=${64 MiB}, t=${120 ms}"`)
	testing.expect(t, irun.ok && irun.value.text == "mem=64 MiB, t=120 ms")

	// Canonical serialization writes Value_Tag.Integer_Unit and validates cleanly.
	ws := v3_decl_ws()
	out_buf: [256]u8
	n, ok := declaration_evaluate_to_buffer(ws, `64 MiB`, "", {}, out_buf[:])
	testing.expect(t, ok && n > declaration_eval.OUTPUT_HEADER_BYTES)
	hdr, verr := declaration_eval.output_validate(out_buf[:n])
	testing.expect_value(t, verr, declaration_eval.Output_Refusal.None)
	testing.expect_value(t, hdr.status, declaration_eval.Output_Status.Ok)
	_, rdr1, _ := declaration_eval.output_read_header(out_buf[:n])
	tag1, _ := declaration_eval.output_read_tag(&rdr1)
	testing.expect_value(t, tag1, declaration_eval.Value_Tag.Integer_Unit)
	iv, iu, rerr1 := declaration_eval.output_read_integer_unit(&rdr1)
	testing.expect(t, rerr1 == .None && iv == 64 && iu == value_kinds.size_in(.Mebibytes))

	// Query_Cache distinguishes 64 MiB vs 64 vs 64 KiB on early cutoff!
	cache := new(Query_Cache, context.temp_allocator)
	cpools := Query_Cache_Pools{
		l1_entries = 32, l1_nodes = 4096, l1_extra = 4096, l1_int_consts = 256,
		l2_entries = 32, l2_deps = 64, l2_field_deps = 128, l2_bytes = 64 * 1024,
		tracker_imports = 32, tracker_fields = 128,
	}
	cbytes := query_cache_bytes(cpools)
	cmem := make([]u8, cbytes + 64, context.temp_allocator)
	caddr := uintptr(raw_data(cmem))
	coff := int(((caddr + 63) &~ uintptr(63)) - caddr)
	testing.expect(t, query_cache_carve(cache, cmem[coff:coff + cbytes], cpools, 7))

	dep_src := `{ budget = 64 MiB }`
	loader := Declaration_Loader {
		data = &dep_src,
		load_path = proc "contextless" (d: rawptr, p: string) -> (string, bool) {
			if p == "dep.lex" {
				return (^string)(d)^, true
			}
			return "", false
		},
	}
	root_src := `let d = import("dep.lex") in d.budget`
	buf1, buf2: [256]u8
	n1, ok1 := query_cache_evaluate_to_buffer(cache, ws, root_src, "", {loader = loader}, buf1[:])
	testing.expect(t, ok1)
	// Change 64 MiB -> 64 KiB: cache MUST miss and produce new bytes!
	dep_src = `{ budget = 64 KiB }`
	n2, ok2 := query_cache_evaluate_to_buffer(cache, ws, root_src, "", {loader = loader}, buf2[:])
	testing.expect(t, ok2)
	testing.expect(t, n1 == n2 && string(buf1[:n1]) != string(buf2[:n2]))
	_, rdr2, _ := declaration_eval.output_read_header(buf2[:n2])
	tag2, _ := declaration_eval.output_read_tag(&rdr2)
	testing.expect_value(t, tag2, declaration_eval.Value_Tag.Integer_Unit)
	v2, u2, rerr2 := declaration_eval.output_read_integer_unit(&rdr2)
	testing.expect(t, rerr2 == .None && v2 == 64 && u2 == value_kinds.size_in(.Kibibytes))
}

// Feature 4: O(N) dynamic record construction (`from_entries` and `{ for ... }`).
@(test)
v3_dynamic_record_construction :: proc(t: ^testing.T) {
	// from_entries: empty, normal, lazy values in Declaration mode.
	ws, res := v3_decl_eval(`from_entries([{ name = "b", value = 1 / 0 }, { name = "a", value = 42 }])`, "a")
	testing.expectf(t, res.ok && value_integer(res.value) == 42, "from_entries lazy failed: %v", res.failure_kind)
	_ = ws
	_, res_empty := v3_decl_eval(`fields(from_entries([]))`)
	testing.expect(t, res_empty.ok && res_empty.value.kind == .List && res_empty.value.meta == 0)

	// Record comprehension with destructuring, guard, captured outer variable, and laziness.
	comp_src := `
let scale = 10, items = [{ k = "beta", v = 2, keep = true }, { k = "skip", v = 1 / 0, keep = false }, { k = "alpha", v = 3, keep = true }] in
let r = { for { k, v, keep } in items if keep: k = v * scale } in
{ names = fields(r), a = r.alpha, b = r.beta }
`
	cws, cres := v3_decl_eval(comp_src, "a")
	testing.expectf(t, cres.ok && value_integer(cres.value) == 30, "comp a failed: %v (%q)", cres.failure_kind, cres.detail)
	fres, fok := declaration_force_path(cws, cws.evaluation.root_value, "names")
	testing.expect(t, fok && fres.kind == .List && fres.meta == 2)
	fn_items := list_items_of(&cws.evaluation, fres)
	testing.expect_value(t, value_text(&cws.evaluation, fn_items[0]), "alpha")
	testing.expect_value(t, value_text(&cws.evaluation, fn_items[1]), "beta")

	// Declaration-mode laziness of comprehension values: unused value `1 / 0` is never forced.
	_, lres := v3_decl_eval(`let r = { for k in ["ok", "boom"]: k = if k = "ok" then 7 else 1 / 0 } in r.ok`)
	testing.expectf(t, lres.ok && value_integer(lres.value) == 7, "comp lazy failed: %v", lres.failure_kind)

	// Large comprehension (> 16 fields) builds a Slice_Hash_Index on the resulting shape.
	var_names := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< 24 {
		append(&var_names, fmt.aprintf("\"f%02d\"", i, allocator = context.temp_allocator))
	}
	large_src := fmt.aprintf(`let r = {{ for k in [%s]: k = len(k) }} in r.f23`, strings.join(var_names[:], ", ", context.temp_allocator), allocator = context.temp_allocator)
	prof: Evaluation_Profile
	lws, large_res := v3_decl_eval(large_src, "", {profile = &prof})
	testing.expectf(t, large_res.ok && value_integer(large_res.value) == 3, "large comp failed: %v", large_res.failure_kind)
	testing.expect(t, prof.shape_indices_built >= 1)
	_ = lws

	// Console mode comprehension & from_entries.
	c1 := run_of(`({ for k in ["a", "b"]: k = 5 }).b`)
	testing.expectf(t, c1.ok && c1.value.integer == 5, "console comp: %v (%v)", c1.ok, c1.evaluation.refusal.refusal)
	c2 := run_of(`from_entries([{ name = "x", value = 9 }]).x`)
	testing.expectf(t, c2.ok && c2.value.integer == 9, "console from_entries: %v (%v)", c2.ok, c2.evaluation.refusal.refusal)

	// Refusals: non-list, non-text key, invalid key name, duplicate key, non-bool guard.
	testing.expect_value(t, run_of(`from_entries(42)`).evaluation.refusal.refusal, Refusal.Not_A_List)
	testing.expect_value(t, run_of(`from_entries([{ name = 1, value = 2 }])`).evaluation.refusal.refusal, Refusal.Field_Name_Invalid)
	testing.expect_value(t, run_of(`from_entries([{ name = "1bad", value = 2 }])`).evaluation.refusal.refusal, Refusal.Field_Name_Invalid)
	testing.expect_value(t, run_of(`from_entries([{ name = "a", value = 1 }, { name = "a", value = 2 }])`).evaluation.refusal.refusal, Refusal.Duplicate_Field)
	testing.expect_value(t, run_of(`{ for x in 42: "a" = x }`).evaluation.refusal.refusal, Refusal.Not_A_List)
	testing.expect_value(t, run_of(`{ for x in [1, 2]: "same" = x }`).evaluation.refusal.refusal, Refusal.Duplicate_Field)
	testing.expect_value(t, run_of(`{ for x in [1] if 42: "a" = x }`).evaluation.refusal.refusal, Refusal.Condition_Not_Boolean)
}

// Feature 5: Pattern matching (`match`) across both modes, guards, laziness, and TCO.
@(test)
v3_pattern_matching :: proc(t: ^testing.T) {
	// Literals, negative int, unit literal, bool, text, enum member, nested record, as-pattern, guards, wildcard.
	src := `
let classify = (v) => match v {
  0 => "zero",
  -1 => "minus_one",
  1024 KiB => "one_mib",
  true => "yes",
  "hi" => "greet",
  .Verify => "verify",
  r @ { mode = .Fast, net = { port = p }, ... } if p > 1000 => "fast:${p}",
  { mode = .Fast, ... } => "fast_low",
  x => "other",
} in {
  a = classify(0),
  b = classify(-1),
  c = classify(1 MiB),
  d = classify(true),
  e = classify("hi"),
  f = classify(.Verify),
  g = classify({ mode = .Fast, net = { port = 8080 }, unused = 1 / 0 }),
  h = classify({ mode = .Fast, net = { port = 80 }, extra = 1 / 0 }),
  i = classify(99),
}
`
	ws, res := v3_decl_eval(src)
	testing.expectf(t, res.ok, "match decl failed: %v (%q)", res.failure_kind, res.detail)
	wants := [?]struct{ f, w: string }{
		{"a", "zero"}, {"b", "minus_one"}, {"c", "one_mib"}, {"d", "yes"},
		{"e", "greet"}, {"f", "verify"}, {"g", "fast:8080"}, {"h", "fast_low"}, {"i", "other"},
	}
	for item in wants {
		fv, fok := declaration_force_path(ws, res.value, item.f)
		testing.expectf(t, fok && value_text(&ws.evaluation, fv) == item.w, "field %s: got %q, want %q", item.f, value_text(&ws.evaluation, fv), item.w)
	}

	// Console mode match.
	crun := run_of(`match 1 MiB { 1024 KiB => 10, _ => 0 }`)
	testing.expectf(t, crun.ok && crun.value.integer == 10, "console match: %v (%v)", crun.ok, crun.evaluation.refusal.refusal)

	// TCO inside match arms: 2000 recursive tail calls with depth_limit = 32!
	tco_src := `
let down = (n, acc) => match n {
  0 => acc,
  k => down(k - 1, acc + 1),
} in down(2000, 0)
`
	_, tco_res := v3_decl_eval(tco_src, "", {depth_limit = 32})
	testing.expectf(t, tco_res.ok && value_integer(tco_res.value) == 2000, "match TCO failed: %v", tco_res.failure_kind)

	// Refusal: No_Matching_Arm in both modes.
	_, nm_decl := v3_decl_eval(`match 5 { 1 => 10, 2 => 20 }`)
	testing.expect_value(t, nm_decl.failure_kind, declaration_eval.Failure_Kind.No_Matching_Arm)
	nm_con := run_of(`match 5 { 1 => 10, 2 => 20 }`)
	testing.expect_value(t, nm_con.evaluation.refusal.refusal, Refusal.No_Matching_Arm)

	// Non-Boolean guard refused.
	testing.expect_value(t, run_of(`match 1 { x if 42 => x }`).evaluation.refusal.refusal, Refusal.Condition_Not_Boolean)
}

// Feature 6: Safe field fallback (`??`) across both modes.
@(test)
v3_safe_field_fallback :: proc(t: ^testing.T) {
	// Present field skips lazy RHS (1/0 never runs).
	c1 := run_of(`{ a = 1 }.a ?? (1 / 0)`)
	testing.expectf(t, c1.ok && c1.value.integer == 1, "present ?? failed: %v", c1.evaluation.refusal.refusal)

	// Absent field evaluates RHS.
	c2 := run_of(`{ a = 1 }.b ?? 42`)
	testing.expect(t, c2.ok && c2.value.integer == 42)

	// Chained nested selection and right-associative fallback chain.
	src := `
let cfg = { net = { host = "a" } }, fb = { port = 9090 } in {
  p1 = cfg.net.port ?? fb.port ?? 8080,
  p2 = cfg.missing.deep ?? fb.missing ?? 8080,
  p3 = cfg.net.host ?? "none",
}
`
	ws, res := v3_decl_eval(src)
	testing.expect(t, res.ok)
	v1, ok1 := declaration_force_path(ws, res.value, "p1")
	v2, ok2 := declaration_force_path(ws, res.value, "p2")
	v3, ok3 := declaration_force_path(ws, res.value, "p3")
	testing.expect(t, ok1 && value_integer(v1) == 9090)
	testing.expect(t, ok2 && value_integer(v2) == 8080)
	testing.expect(t, ok3 && value_text(&ws.evaluation, v3) == "a")

	// Non-record base, non-record intermediate, runtime error inside present field, non-field LHS are ALL refused!
	testing.expect_value(t, run_of(`let n = 42 in n.a ?? 1`).evaluation.refusal.refusal, Refusal.Field_Unknown)
	testing.expect_value(t, run_of(`{ a = 42 }.a.b ?? 1`).evaluation.refusal.refusal, Refusal.Field_Unknown)
	testing.expect_value(t, run_of(`{ a = 1 / 0 }.a ?? 99`).evaluation.refusal.refusal, Refusal.Division_By_Zero)
	testing.expect_value(t, run_of(`1 ?? 2`).evaluation.refusal.refusal, Refusal.Coalesce_Not_Field_Access)
}

// Feature 7: Core pure List and Text stdlib functions in both Console and Declaration modes.
@(test)
v3_core_list_and_text_stdlib :: proc(t: ^testing.T) {
	// List + UTF-8 len, at, slice, any, all, flat_map, unique, sort_by.
	Int_Case :: struct { expr: string, want: i64 }
	icases := [?]Int_Case {
		{`len([1, 2, 3])`, 3},
		{`len([])`, 0},
		{`len("café")`, 4}, // 5 UTF-8 bytes, 4 code points!
		{`len("€\u{1D11E}")`, 2},
		{`len("")`, 0},
		{`at([10, 20, 30], 0)`, 10},
		{`at([10, 20, 30], 2)`, 30},
		{`len(slice([10, 20, 30, 40], 1, 3))`, 2},
		{`at(slice([10, 20, 30, 40], 1, 3), 0)`, 20},
		{`len(slice([10, 20], 2, 2))`, 0},
		{`len(flat_map([1, 2, 3], (x) => [x, x * 10]))`, 6},
		{`at(flat_map([1, 2], (x) => [x, x + 10]), 3)`, 12},
		{`len(unique([1, 2, 1, 3, 2]))`, 3},
		{`len(unique([1 MiB, 1024 KiB, 512 KiB]))`, 2},
		{`at(sort_by([30, 10, 20], (x) => x), 0)`, 10},
		{`at(sort_by([30, 10, 20], (x) => x), 2)`, 30},
		// Stability test for sort_by: equal keys preserve original order (id 1 before id 2).
		{`at(sort_by([{ k = 2, id = 1 }, { k = 1, id = 9 }, { k = 2, id = 2 }], (r) => r.k), 1).id`, 1},
		{`at(sort_by([{ k = 2, id = 1 }, { k = 1, id = 9 }, { k = 2, id = 2 }], (r) => r.k), 2).id`, 2},
		// Unit-aware sort_by
		{`at(sort_by([2 MiB, 512 KiB, 1 MiB], (x) => x), 0) / 1 KiB`, 512},
	}
	for item in icases {
		crun := run_of(item.expr)
		testing.expectf(t, crun.ok && crun.value.integer == item.want, "console %q: ok=%v got=%d want=%d ref=%v", item.expr, crun.ok, crun.value.integer, item.want, crun.evaluation.refusal.refusal)
		_, dres := v3_decl_eval(item.expr)
		testing.expectf(t, dres.ok && value_integer(dres.value) == item.want, "decl %q: ok=%v got=%d want=%d fail=%v", item.expr, dres.ok, value_integer(dres.value), item.want, dres.failure_kind)
	}

	// Short-circuiting any / all + empty lists + text predicates.
	Bool_Case :: struct { expr: string, want: bool }
	bcases := [?]Bool_Case {
		{`any([], (x) => true)`, false},
		{`all([], (x) => false)`, true},
		// Short-circuits on first match before dividing by zero!
		{`any([2, 0], (x) => if x = 2 then true else (1 / x) = 0)`, true},
		{`all([0, 2], (x) => if x = 0 then false else (1 / x) = 0)`, false},
		{`all([2, 4, 6], (x) => x % 2 = 0)`, true},
		{`starts_with("modus/lex", "modus")`, true},
		{`starts_with("modus/lex", "lex")`, false},
		{`ends_with("project.lex", ".lex")`, true},
		{`ends_with("project.lex", ".odin")`, false},
		{`contains("hello world", "lo wo")`, true},
		{`contains("hello world", "xyz")`, false},
		{`contains("abc", "")`, true},
	}
	for item in bcases {
		crun := run_of(item.expr)
		testing.expectf(t, crun.ok && crun.value.kind == .Boolean && (crun.value.integer != 0) == item.want, "console %q failed (%v)", item.expr, crun.evaluation.refusal.refusal)
		_, dres := v3_decl_eval(item.expr)
		testing.expectf(t, dres.ok && dres.value.kind == .Boolean && value_boolean(dres.value) == item.want, "decl %q failed (%v)", item.expr, dres.failure_kind)
	}

	// Text stdlib: split, join_text, replace_text, text sort_by, named args.
	Text_Case :: struct { expr, want: string }
	tcases := [?]Text_Case {
		{`join_text(split("a,b,c", ","), "-")`, "a-b-c"},
		{`join_text(split("", ","), ":")`, ""},
		{`join_text([], ",")`, ""},
		{`replace_text("foo bar foo", "foo", "baz")`, "baz bar baz"},
		{`replace_text("aaaa", "aa", "b")`, "bb"},
		{`replace_text("hello", "xyz", "!")`, "hello"},
		{`join_text(sort_by(["c", "a", "b"], (s) => s), "")`, "abc"},
		{`join_text(split(separator = "/", text = "x/y"), ".")`, "x.y"},
	}
	for item in tcases {
		crun := run_of(item.expr)
		testing.expectf(t, crun.ok && crun.value.text == item.want, "console %q: got %q want %q ref=%v", item.expr, crun.value.text, item.want, crun.evaluation.refusal.refusal)
		ws, dres := v3_decl_eval(item.expr)
		testing.expectf(t, dres.ok && value_text(&ws.evaluation, dres.value) == item.want, "decl %q: got %q want %q", item.expr, value_text(&ws.evaluation, dres.value), item.want)
	}

	// Refusals for stdlib edges.
	testing.expect_value(t, run_of(`at([1, 2], -1)`).evaluation.refusal.refusal, Refusal.Index_Out_Of_Bounds)
	testing.expect_value(t, run_of(`at([1, 2], 2)`).evaluation.refusal.refusal, Refusal.Index_Out_Of_Bounds)
	testing.expect_value(t, run_of(`at([1, 2], 0 MiB)`).evaluation.refusal.refusal, Refusal.Unit_Mismatch)
	testing.expect_value(t, run_of(`slice([1, 2], -1, 1)`).evaluation.refusal.refusal, Refusal.Index_Out_Of_Bounds)
	testing.expect_value(t, run_of(`slice([1, 2], 2, 1)`).evaluation.refusal.refusal, Refusal.Index_Out_Of_Bounds)
	testing.expect_value(t, run_of(`slice([1, 2], 0, 3)`).evaluation.refusal.refusal, Refusal.Index_Out_Of_Bounds)
	testing.expect_value(t, run_of(`flat_map([1], (x) => x)`).evaluation.refusal.refusal, Refusal.Not_A_List)
	testing.expect_value(t, run_of(`unique([(x) => x])`).evaluation.refusal.refusal, Refusal.Operator_Kinds)
	testing.expect_value(t, run_of(`sort_by([1, "a"], (x) => x)`).evaluation.refusal.refusal, Refusal.Operator_Kinds)
	testing.expect_value(t, run_of(`sort_by([1 MiB, 1 ms], (x) => x)`).evaluation.refusal.refusal, Refusal.Unit_Mismatch)
	testing.expect_value(t, run_of(`split("a,b", "")`).evaluation.refusal.refusal, Refusal.Empty_Separator)
	testing.expect_value(t, run_of(`replace_text("abc", "", "x")`).evaluation.refusal.refusal, Refusal.Empty_Separator)
	testing.expect_value(t, run_of(`len(42)`).evaluation.refusal.refusal, Refusal.Operator_Kinds)
}

// Feature 8: Optional parameter kind annotations, unit annotations, defaults, and metadata inspection.
@(test)
v3_param_annotations_and_defaults :: proc(t: ^testing.T) {
	// Positional defaults, named call defaults, closure capturing outer variable in default, and unit conversion.
	src := `
let base_mem = 4 MiB in
let build = (name: Text, size: Integer[MiB] = base_mem, opt: Enum = .Speed) =>
  "${name}:${size}:${opt}" in
{
  a = build("app"),
  b = build("app", 2048 KiB),
  c = build(opt = .Size, name = "srv"),
  d = build("x", 8 MiB, .Verify),
}
`
	ws, res := v3_decl_eval(src)
	testing.expectf(t, res.ok, "param annot decl failed: %v (%q)", res.failure_kind, res.detail)
	fa, _ := declaration_force_path(ws, res.value, "a")
	fb, _ := declaration_force_path(ws, res.value, "b")
	fc, _ := declaration_force_path(ws, res.value, "c")
	fd, _ := declaration_force_path(ws, res.value, "d")
	testing.expect_value(t, value_text(&ws.evaluation, fa), "app:4 MiB:Speed")
	testing.expect_value(t, value_text(&ws.evaluation, fb), "app:2 MiB:Speed")
	testing.expect_value(t, value_text(&ws.evaluation, fc), "srv:4 MiB:Size")
	testing.expect_value(t, value_text(&ws.evaluation, fd), "x:8 MiB:Verify")

	// Record destructuring pattern annotations & defaults.
	pat_src := `
let f = ({ src: Tree_Ref, mem: Integer[KiB] = 1 MiB, opt: Enum = .Speed }) => "${mem}:${opt}" in
f({ src = here() })
`
	here_h := blake3.hash(transmute([]u8)string("tree"))
	pws, pres := v3_decl_eval(pat_src, "", {has_here = true, here_hash = here_h})
	testing.expectf(t, pres.ok && value_text(&pws.evaluation, pres.value) == "1024 KiB:Speed", "pattern annot failed: %v (%q)", pres.failure_kind, pres.detail)

	// Console mode function annotations and defaults.
	crun := run_of(`let add = (a: Integer, b: Integer = 10) => a + b in add(5) + add(5, 2)`)
	testing.expectf(t, crun.ok && crun.value.integer == 22, "console param defaults: %v (%v)", crun.ok, crun.evaluation.refusal.refusal)

	// function_param_meta inspection API.
	mws, mres := v3_decl_eval(`(src: Tree_Ref, size: Integer[MiB], opt: Enum = .Speed) => src`)
	testing.expect(t, mres.ok && mres.value.kind == .Function)
	metas: [lex_parser.ARGUMENT_CAPACITY]Function_Param_Info
	mcount, mok := function_param_meta(&mws.evaluation, mres.value, metas[:])
	testing.expect(t, mok && mcount == 3)
	testing.expect(t, metas[0].name == "src" && metas[0].kind_annot == .Tree_Ref && !metas[0].has_default)
	testing.expect(t, metas[1].name == "size" && metas[1].kind_annot == .Integer && metas[1].unit == value_kinds.size_in(.Mebibytes) && !metas[1].has_default)
	testing.expect(t, metas[2].name == "opt" && metas[2].kind_annot == .Enum && metas[2].has_default)

	// Refusals: wrong kind, bare integer for Integer[MiB], non-exact unit conversion, incompatible unit, annotated pattern field wrong kind.
	r1 := run_of(`let f = (x: Text) => x in f(42)`)
	testing.expect_value(t, r1.evaluation.refusal.refusal, Refusal.Parameter_Kind)
	testing.expect_value(t, r1.evaluation.refusal.expected_annot, lex_parser.Param_Kind_Annot.Text)

	r2 := run_of(`let f = (s: Integer[MiB]) => s in f(64)`)
	testing.expect_value(t, r2.evaluation.refusal.refusal, Refusal.Unit_Mismatch)

	r3 := run_of(`let f = (s: Integer[MiB]) => s in f(100 bytes)`)
	testing.expect_value(t, r3.evaluation.refusal.refusal, Refusal.Unit_Mismatch)

	r4 := run_of(`let f = (s: Integer[MiB]) => s in f(10 ms)`)
	testing.expect_value(t, r4.evaluation.refusal.refusal, Refusal.Unit_Mismatch)

	r5 := run_of(`let f = ({ a: Integer }) => a in f({ a = "bad" })`)
	testing.expect_value(t, r5.evaluation.refusal.refusal, Refusal.Parameter_Kind)

	// Annotated callback in map checked eagerly!
	r6 := run_of(`map(["a"], (x: Integer) => x + 1)`)
	testing.expect_value(t, r6.evaluation.refusal.refusal, Refusal.Parameter_Kind)
}
