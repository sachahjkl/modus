#+build !freestanding
package lex_tools

import "core:os"
import "core:strings"
import "core:testing"
import "modus:lex_parser"

@(private = "file")
format_expect :: proc(t: ^testing.T, input: string, expected: string) {
	buf: [8192]u8
	n, err := lex_format(input, buf[:])
	testing.expect_value(t, err, Format_Error.None)
	got := string(buf[:n])
	testing.expect_value(t, got, expected)

	// Strict idempotency check: formatting the output again yields identical bytes.
	buf2: [8192]u8
	n2, err2 := lex_format(got, buf2[:])
	testing.expect_value(t, err2, Format_Error.None)
	testing.expect_value(t, string(buf2[:n2]), got)
}

@(private = "file")
has_lint_kind :: proc(diags: []Lint_Diagnostic, kind: Lint_Kind) -> bool {
	for d in diags {
		if d.kind == kind {
			return true
		}
	}
	return false
}

@(test)
format_empty_and_refusals :: proc(t: ^testing.T) {
	buf: [64]u8

	// Empty and whitespace-only inputs produce 0 bytes with no error.
	n, err := lex_format("", buf[:])
	testing.expect_value(t, err, Format_Error.None)
	testing.expect_value(t, n, 0)

	n, err = lex_format("   \t\r\n  \n", buf[:])
	testing.expect_value(t, err, Format_Error.None)
	testing.expect_value(t, n, 0)

	// Zero-length output buffer on non-empty input refuses cleanly.
	n, err = lex_format("1 + 2", buf[:0])
	testing.expect_value(t, err, Format_Error.Buffer_Too_Small)
	testing.expect_value(t, n, 0)

	// Undersized buffer (missing room for trailing newline) refuses cleanly.
	n, err = lex_format("1 + 2", buf[:5])
	testing.expect_value(t, err, Format_Error.Buffer_Too_Small)
	testing.expect_value(t, n, 0)

	// Exact-size buffer succeeds (`1 + 2\n` = 6 bytes).
	n, err = lex_format("1 + 2", buf[:6])
	testing.expect_value(t, err, Format_Error.None)
	testing.expect_value(t, string(buf[:n]), "1 + 2\n")

	// Unclosed string literal refuses cleanly.
	n, err = lex_format(`"hello`, buf[:])
	testing.expect_value(t, err, Format_Error.Text_Without_End_Quote)
	testing.expect_value(t, n, 0)

	// Unknown byte refuses cleanly.
	n, err = lex_format("a ; b", buf[:])
	testing.expect_value(t, err, Format_Error.Unknown_Token)
	testing.expect_value(t, n, 0)

	// Unmatched closer and unclosed opener refuse cleanly.
	n, err = lex_format("a + 1)", buf[:])
	testing.expect_value(t, err, Format_Error.Unmatched_Close)
	testing.expect_value(t, n, 0)

	n, err = lex_format("{ a = 1", buf[:])
	testing.expect_value(t, err, Format_Error.Unclosed_Delimiter)
	testing.expect_value(t, n, 0)

	n, err = lex_format("{ a = [1, 2) }", buf[:])
	testing.expect_value(t, err, Format_Error.Unmatched_Close)
	testing.expect_value(t, n, 0)
}

@(test)
format_canonical_spacing_and_operators :: proc(t: ^testing.T) {
	format_expect(t, "1+2*3-4/2%5", "1 + 2 * 3 - 4 / 2 % 5\n")
	format_expect(t, "a<=b&&c>=d||e!=f", "a <= b && c >= d || e != f\n")
	format_expect(t, "a++b", "a ++ b\n")
	format_expect(t, "cfg.net.port??fallback.port??8080", "cfg.net.port ?? fallback.port ?? 8080\n")
	format_expect(t, "a|>f(b,_) |>g", "a |> f(b, _) |> g\n")
	format_expect(t, "(x)=>x*2", "(x) => x * 2\n")
	format_expect(t, "(src:Tree_Ref,size:Integer[MiB],opt:Enum=.Speed)=>src", "(src: Tree_Ref, size: Integer[MiB], opt: Enum = .Speed) => src\n")
	format_expect(t, "-1+-x", "-1 + -x\n")
	format_expect(t, "!flag&&!(a<=b)", "!flag && !(a <= b)\n")
	format_expect(t, "if -x>0 then -1 else -2", "if -x > 0 then -1 else -2\n")
	format_expect(t, "64MiB+500ms", "64 MiB + 500 ms\n")
	format_expect(t, "f().x", "f().x\n")
	format_expect(t, "({a=1}).a", "({ a = 1 }).a\n")
	format_expect(t, "xs[0].name", "xs[0].name\n")
	format_expect(t, "{}", "{}\n")
	format_expect(t, "{\n  \n}", "{}\n")
	format_expect(t, "[  \n ]", "[]\n")
	format_expect(t, "()", "()\n")
	format_expect(t, "{for x in xs if x>0:x=x*2}", "{ for x in xs if x > 0: x = x * 2 }\n")
	format_expect(t, "r with {width=10,height=20}", "r with { width = 10, height = 20 }\n")
	format_expect(t, "let a=1,b=2 in a+b", "let a = 1, b = 2 in a + b\n")
}

@(test)
format_multiline_declarations_and_comments :: proc(t: ^testing.T) {
	// Nested project declaration with leading and inline comments.
	input := strings.join({
		"// Header comment   ",
		"project{",
		"source=here(),// current tree   ",
		"",
		"",
		"inputs={",
		"modus=catalog,",
		"},",
		"outputs={",
		"default=recipe(catalog.odin_builder,{target=\"tools\",src=here()}),",
		"},",
		"}",
	}, "\n")
	defer delete(input)

	expected := strings.join({
		"// Header comment",
		"project {",
		"  source = here(), // current tree",
		"",
		"  inputs = {",
		"    modus = catalog,",
		"  },",
		"  outputs = {",
		"    default = recipe(catalog.odin_builder, { target = \"tools\", src = here() }),",
		"  },",
		"}",
		"",
	}, "\n")
	defer delete(expected)

	format_expect(t, input, expected)

	// Match expression with nested record patterns and guards.
	match_in := strings.join({
		"match cfg{",
		"cfg_all@{mode=.Verify,net={port=p},...} if p>1024=>p,",
		"_=>8080,",
		"}",
	}, "\n")
	defer delete(match_in)

	match_out := strings.join({
		"match cfg {",
		"  cfg_all @ { mode = .Verify, net = { port = p }, ... } if p > 1024 => p,",
		"  _ => 8080,",
		"}",
		"",
	}, "\n")
	defer delete(match_out)

	format_expect(t, match_in, match_out)

	// Multi-line let bindings and continuation pipes.
	let_in := strings.join({
		"let",
		"a=1,",
		"b=2",
		"in",
		"a",
		"|>add(b)",
		"|>double",
	}, "\n")
	defer delete(let_in)

	let_out := strings.join({
		"let",
		"  a = 1,",
		"  b = 2",
		"in",
		"a",
		"  |> add(b)",
		"  |> double",
		"",
	}, "\n")
	defer delete(let_out)

	format_expect(t, let_in, let_out)

	// String escapes and `${...}` interpolations stay untouched.
	interp := `let name = "world" in "hello \"${name}\"\n"`
	format_expect(t, interp, interp + "\n")
}

@(test)
format_idempotent_across_guide_snippets :: proc(t: ^testing.T) {
	// Verify every non-transcript ```lex block in docs/LEX.md and docs/COURSE.md
	// formats without error and is strictly idempotent.
	guide_paths := [?]string{"docs/LEX.md", "docs/COURSE.md"}
	blocks_checked := 0

	for path in guide_paths {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			continue
		}
		defer delete(data)
		text := string(data)

		in_lex := false
		block: strings.Builder
		strings.builder_init(&block)
		defer strings.builder_destroy(&block)

		rest := text
		for line in strings.split_lines_iterator(&rest) {
			trimmed := strings.trim_space(line)
			if !in_lex {
				if trimmed == "```lex" {
					in_lex = true
					strings.builder_reset(&block)
				}
				continue
			}
			if trimmed == "```" {
				in_lex = false
				src := strings.to_string(block)
				// Skip interactive console transcripts (lines prefixed with `> `).
				if strings.has_prefix(strings.trim_space(src), "> ") {
					continue
				}
				out1 := make([]u8, max(len(src) * 4 + 256, 4096))
				out2 := make([]u8, len(out1))
				n1, err1 := lex_format(src, out1)
				if err1 == .None {
					n2, err2 := lex_format(string(out1[:n1]), out2)
					testing.expect_value(t, err2, Format_Error.None)
					testing.expect_value(t, string(out2[:n2]), string(out1[:n1]))
					blocks_checked += 1
				}
				delete(out1)
				delete(out2)
				continue
			}
			strings.write_string(&block, line)
			strings.write_byte(&block, '\n')
		}
	}
	testing.expect(t, blocks_checked > 0)
}

@(test)
lint_clean_inputs_report_zero_diagnostics :: proc(t: ^testing.T) {
	clean_cases := [?]string{
		"1 + 2 * 3",
		"let x = 1, y = x + 2 in y * 3",
		"let f = (x) => x * 2 in f(21)",
		"let cfg = { port = 8080 } in cfg.port",
		"let { a, b } = rec in a + b",
		"let a = b + 1, b = 2 in a",
		"project { source = here(), outputs = { default = catalog.c.module(\"main.c\") } }",
		"match cfg { { mode = .Verify, net = { port = p }, ... } if p > 1024 => p, _ => 8080 }",
		"map([1, 2, 3], (x) => x * 2)",
		"{ for x in xs if x > 0: x = x * 2 }",
		`let name = "modus" in "hello ${name}"`,
		"(a + b) * c",
		"a |> f(b, _) |> g",
	}

	diags: [32]Lint_Diagnostic
	for src in clean_cases {
		count, truncated := lex_lint(src, diags[:])
		testing.expect_value(t, truncated, false)
		testing.expect_value(t, count, 0)
	}
}

@(test)
lint_detects_every_diagnostic_kind :: proc(t: ^testing.T) {
	diags: [32]Lint_Diagnostic

	// 1. Empty expression (empty and comment-only).
	count, truncated := lex_lint("", diags[:])
	testing.expect_value(t, truncated, false)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, diags[0].kind, Lint_Kind.Empty_Expression)

	count, _ = lex_lint("// only a comment\n", diags[:])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, diags[0].kind, Lint_Kind.Empty_Expression)

	// 2. Unused `let` binding.
	count, _ = lex_lint("let unused_var = 42, kept = 1 in kept", diags[:])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, diags[0].kind, Lint_Kind.Unused_Binding)
	testing.expect_value(t, diags[0].severity, Lint_Severity.Warning)
	testing.expect_value(t, diags[0].name, "unused_var")

	// 3. Shadowed `let` binding (outer x becomes unused too, inner x shadows outer x).
	count, _ = lex_lint("let x = 1 in let x = 2 in x", diags[:])
	testing.expect(t, has_lint_kind(diags[:count], .Shadowed_Binding))
	testing.expect(t, has_lint_kind(diags[:count], .Unused_Binding))

	// Shadowed `let` binding when outer binding IS used before inner shadows it.
	count, _ = lex_lint("let x = 1 in (x + (let x = 2 in x))", diags[:])
	testing.expect(t, has_lint_kind(diags[:count], .Shadowed_Binding))
	testing.expect(t, !has_lint_kind(diags[:count], .Unused_Binding))

	// 4. Duplicate record field.
	count, _ = lex_lint("{ port = 80, port = 443 }", diags[:])
	testing.expect(t, has_lint_kind(diags[:count], .Duplicate_Record_Field))
	testing.expect_value(t, diags[0].severity, Lint_Severity.Error)
	testing.expect_value(t, diags[0].name, "port")

	// 5. Redundant parentheses (double parens and single atom).
	count, _ = lex_lint("((1 + 2))", diags[:])
	testing.expect(t, has_lint_kind(diags[:count], .Redundant_Parentheses))

	count, _ = lex_lint("let x = (42) in x", diags[:])
	testing.expect(t, has_lint_kind(diags[:count], .Redundant_Parentheses))

	// 6. Empty record and empty list.
	count, _ = lex_lint("{}", diags[:])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, diags[0].kind, Lint_Kind.Empty_Record)

	count, _ = lex_lint("[]", diags[:])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, diags[0].kind, Lint_Kind.Empty_List)

	// 7. Empty / non-callable pipe target.
	count, _ = lex_lint("a |>", diags[:])
	testing.expect(t, has_lint_kind(diags[:count], .Empty_Pipe_Target))

	count, _ = lex_lint("a |> 12", diags[:])
	testing.expect(t, has_lint_kind(diags[:count], .Empty_Pipe_Target))

	// 8. Malformed tokens (unclosed string, unknown char, malformed hash).
	count, _ = lex_lint(`"unterminated`, diags[:])
	testing.expect(t, has_lint_kind(diags[:count], .Malformed_Token))

	count, _ = lex_lint("a ; b", diags[:])
	testing.expect(t, has_lint_kind(diags[:count], .Malformed_Token))

	count, _ = lex_lint("blake3:ABCD", diags[:])
	testing.expect(t, has_lint_kind(diags[:count], .Malformed_Token))

	// 9. Parse error.
	count, _ = lex_lint("let a = 1", diags[:])
	testing.expect(t, has_lint_kind(diags[:count], .Parse_Error))
}

@(test)
lint_truncation_and_storage_tier :: proc(t: ^testing.T) {
	// Tight diagnostic buffer sets truncated = true without overflowing.
	small: [1]Lint_Diagnostic
	count, truncated := lex_lint("let a = 1, b = 2, c = 3 in c", small[:])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, truncated, true)

	// Caller-owned storage tier handles declarations larger than LINT_INLINE_NODE_CAPACITY.
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "[\n")
	for i in 0 ..< 600 {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, "1")
	}
	strings.write_string(&b, "\n]")
	big_src := strings.to_string(b)

	node_cap := 2048
	nodes := make([]lex_parser.Ast_Node, node_cap)
	extra := make([]lex_parser.Node_Index, node_cap)
	scratch := make([]lex_parser.Node_Index, node_cap)
	ints := make([]i64, 64)
	defer delete(nodes)
	defer delete(extra)
	defer delete(scratch)
	defer delete(ints)

	storage := lex_parser.Tree_Storage{
		nodes            = nodes,
		extra_children   = extra,
		scratch_children = scratch,
		int_consts       = ints,
	}
	diags: [16]Lint_Diagnostic
	big_count, big_trunc := lex_lint_with_storage(big_src, storage, diags[:])
	testing.expect_value(t, big_trunc, false)
	testing.expect_value(t, big_count, 0)

	// Message formatting produces non-empty plain-English strings.
	msg_buf: [128]u8
	msg := lint_diagnostic_message({kind = .Unused_Binding, severity = .Warning, name = "x"}, msg_buf[:])
	testing.expect(t, strings.contains(msg, "'x'"))
}
