#+build !freestanding
#+build !modus
package text_model

import "core:testing"
import "modus:graphics"

@(test)
syntax_language_detection_handles_extensions_and_plain :: proc(t: ^testing.T) {
	testing.expect_value(t, syntax_language_of_path("hello.c"), Syntax_Language.C)
	testing.expect_value(t, syntax_language_of_path("src/math.h"), Syntax_Language.C)
	testing.expect_value(t, syntax_language_of_path("project.lex"), Syntax_Language.Lex)
	testing.expect_value(t, syntax_language_of_path("recipes/sqlite.recipe"), Syntax_Language.Lex)
	testing.expect_value(t, syntax_language_of_path("src/main.odin"), Syntax_Language.Odin)
	testing.expect_value(t, syntax_language_of_path("notes.txt"), Syntax_Language.Plain)
	testing.expect_value(t, syntax_language_of_path(""), Syntax_Language.Plain)
	testing.expect_value(t, syntax_language_of_path("c"), Syntax_Language.Plain)
}

@(test)
syntax_highlights_c_keywords_types_directives_and_comments :: proc(t: ^testing.T) {
	src := "#include <stdint.h>\n/* multi\nline */\nlong square(long x) {\n  return x * x; // done\n}\n"
	text := new(Text)
	defer free(text)
	testing.expect_value(t, text_replace_whole(text, transmute([]u8)src), Edit_Problem.None)
	layout := new(Layout)
	defer free(layout)
	testing.expect_value(t, layout_compute(layout, text, 80, .Character), Layout_Problem.None)
	states := new(Syntax_States)
	defer free(states)
	testing.expect(t, syntax_compute(states, layout, text, .C))
	testing.expect_value(t, states.row_count, layout.row_count)

	// Row 0: `#include <stdint.h>` -> Directive
	row0 := transmute([]u8)string("#include <stdint.h>")
	cls0: [64]graphics.Code_Class
	_ = syntax_highlight_row(.C, row0, syntax_row_carry(states, 0), true, cls0[:len(row0)])
	testing.expect_value(t, cls0[0], graphics.Code_Class.Directive)
	testing.expect_value(t, cls0[8], graphics.Code_Class.Directive)

	// Row 2 (`line */`) starts inside block comment depth 1.
	testing.expect_value(t, syntax_row_carry(states, 2) & SYNTAX_CARRY_DEPTH_MASK, Syntax_Carry(1))
	row2 := transmute([]u8)string("line */")
	cls2: [32]graphics.Code_Class
	after2 := syntax_highlight_row(.C, row2, syntax_row_carry(states, 2), true, cls2[:len(row2)])
	testing.expect_value(t, cls2[0], graphics.Code_Class.Comment)
	testing.expect_value(t, after2 & SYNTAX_CARRY_DEPTH_MASK, Syntax_Carry(0))

	// Row 3: `long square(long x) {` -> Type, Name, Punctuation
	row3 := transmute([]u8)string("long square(long x) {")
	cls3: [64]graphics.Code_Class
	_ = syntax_highlight_row(.C, row3, syntax_row_carry(states, 3), true, cls3[:len(row3)])
	testing.expect_value(t, cls3[0], graphics.Code_Class.Type)        // long
	testing.expect_value(t, cls3[5], graphics.Code_Class.Name)        // square
	testing.expect_value(t, cls3[11], graphics.Code_Class.Punctuation) // (

	// Row 4: `  return x * x; // done` -> Keyword and line comment
	row4 := transmute([]u8)string("  return x * x; // done")
	cls4: [64]graphics.Code_Class
	_ = syntax_highlight_row(.C, row4, syntax_row_carry(states, 4), true, cls4[:len(row4)])
	testing.expect_value(t, cls4[2], graphics.Code_Class.Keyword)  // return
	testing.expect_value(t, cls4[16], graphics.Code_Class.Comment) // //
}

@(test)
syntax_highlights_lex_keywords_units_enums_and_hashes :: proc(t: ^testing.T) {
	line := "let h = blake3:0123abcd in plan { heap = 4 MiB, theme = .dark } |> sort(\"name\")"
	bytes := transmute([]u8)line
	cls: [128]graphics.Code_Class
	_ = syntax_highlight_row(.Lex, bytes, 0, true, cls[:len(bytes)])
	testing.expect_value(t, cls[0], graphics.Code_Class.Keyword)     // let
	testing.expect_value(t, cls[8], graphics.Code_Class.Literal)     // blake3:0123abcd
	testing.expect_value(t, cls[27], graphics.Code_Class.Keyword)    // plan
	testing.expect_value(t, cls[41], graphics.Code_Class.Literal)    // 4
	testing.expect_value(t, cls[43], graphics.Code_Class.Literal)    // MiB
	testing.expect_value(t, cls[56], graphics.Code_Class.Literal)    // .dark
	testing.expect_value(t, cls[64], graphics.Code_Class.Punctuation) // |
	testing.expect_value(t, cls[67], graphics.Code_Class.Keyword)    // sort
	testing.expect_value(t, cls[72], graphics.Code_Class.Literal)    // "name"
}

@(test)
syntax_highlights_odin_nested_comments_directives_and_raw_strings :: proc(t: ^testing.T) {
	src := "/* outer /* inner */ still */\n@(rodata)\nx := `raw\nline`\nfoo :: proc(a: u64) -> bool\n"
	text := new(Text)
	defer free(text)
	testing.expect_value(t, text_replace_whole(text, transmute([]u8)src), Edit_Problem.None)
	layout := new(Layout)
	defer free(layout)
	testing.expect_value(t, layout_compute(layout, text, 80, .Character), Layout_Problem.None)
	states := new(Syntax_States)
	defer free(states)
	testing.expect(t, syntax_compute(states, layout, text, .Odin))

	// Row 0 closes both nested comment levels.
	row0 := transmute([]u8)string("/* outer /* inner */ still */")
	cls0: [64]graphics.Code_Class
	after0 := syntax_highlight_row(.Odin, row0, 0, true, cls0[:len(row0)])
	testing.expect_value(t, after0, Syntax_Carry(0))
	testing.expect_value(t, cls0[22], graphics.Code_Class.Comment) // "still" still in comment!

	// Row 1: `@(rodata)` -> Directive
	row1 := transmute([]u8)string("@(rodata)")
	cls1: [32]graphics.Code_Class
	_ = syntax_highlight_row(.Odin, row1, syntax_row_carry(states, 1), true, cls1[:len(row1)])
	testing.expect_value(t, cls1[0], graphics.Code_Class.Directive)

	// Row 3 (`line``) carries backtick raw string state from row 2.
	testing.expect(t, (syntax_row_carry(states, 3) & SYNTAX_CARRY_BACKTICK) != 0)
	row3 := transmute([]u8)string("line`")
	cls3: [32]graphics.Code_Class
	after3 := syntax_highlight_row(.Odin, row3, syntax_row_carry(states, 3), true, cls3[:len(row3)])
	testing.expect_value(t, cls3[0], graphics.Code_Class.Literal)
	testing.expect_value(t, after3 & SYNTAX_CARRY_BACKTICK, Syntax_Carry(0))

	// Row 4: `foo :: proc(a: u64) -> bool` -> Keyword, Type
	row4 := transmute([]u8)string("foo :: proc(a: u64) -> bool")
	cls4: [64]graphics.Code_Class
	_ = syntax_highlight_row(.Odin, row4, syntax_row_carry(states, 4), true, cls4[:len(row4)])
	testing.expect_value(t, cls4[7], graphics.Code_Class.Keyword) // proc
	testing.expect_value(t, cls4[15], graphics.Code_Class.Type)   // u64
	testing.expect_value(t, cls4[23], graphics.Code_Class.Type)   // bool
}

@(test)
syntax_row_carry_refuses_out_of_range_and_plain :: proc(t: ^testing.T) {
	states: Syntax_States
	testing.expect_value(t, syntax_row_carry(nil, 0), Syntax_Carry(0))
	testing.expect_value(t, syntax_row_carry(&states, -1), Syntax_Carry(0))
	testing.expect_value(t, syntax_row_carry(&states, 999), Syntax_Carry(0))

	cls: [16]graphics.Code_Class
	_ = syntax_highlight_row(.Plain, transmute([]u8)string("return 42"), 0, true, cls[:9])
	for c in cls[:9] {
		testing.expect_value(t, c, graphics.Code_Class.None)
	}
}

@(test)
syntax_wrapped_tokens_keep_color_across_rows :: proc(t: ^testing.T) {
	text := new(Text)
	defer free(text)
	layout := new(Layout)
	defer free(layout)
	states := new(Syntax_States)
	defer free(states)

	src := "let h = blake3:0123456789abcdef\n// long wrapped comment text here\n"
	text_insert(text, transmute([]u8)src)
	// Wrap at 20 columns so both `blake3:0123456789abcdef` and the `//` comment split across two rows.
	layout_compute(layout, text, 20, .Character)
	testing.expect(t, syntax_compute(states, layout, text, .Lex))
	testing.expect(t, layout.row_count >= 4)

	// Row 1 is the wrapped tail of `blake3:0123456789abcdef` (`456789abcdef`): every byte must stay .Literal.
	testing.expect(t, !row_first_of_line(layout, 1))
	cls_row1: [64]graphics.Code_Class
	r1_len := row_bytes_end(layout, text, 1) - int(layout.rows[1].start)
	testing.expect(t, r1_len > 0)
	syntax_highlight_layout_row(.Lex, states, layout, text, 1, cls_row1[:r1_len])
	for i in 0 ..< r1_len {
		testing.expect_value(t, cls_row1[i], graphics.Code_Class.Literal)
	}

	// Row 3 is the wrapped tail of `// long wrapped comment text here`: every byte must stay .Comment.
	testing.expect(t, !row_first_of_line(layout, 3))
	cls_row3: [64]graphics.Code_Class
	r3_len := row_bytes_end(layout, text, 3) - int(layout.rows[3].start)
	testing.expect(t, r3_len > 0)
	syntax_highlight_layout_row(.Lex, states, layout, text, 3, cls_row3[:r3_len])
	for i in 0 ..< r3_len {
		testing.expect_value(t, cls_row3[i], graphics.Code_Class.Comment)
	}

	// Out-of-range row refuses cleanly without modifying out_classes.
	cls_bad: [4]graphics.Code_Class
	syntax_highlight_layout_row(.Lex, states, layout, text, -1, cls_bad[:])
	syntax_highlight_layout_row(.Lex, states, layout, text, 999, cls_bad[:])
	for c in cls_bad {
		testing.expect_value(t, c, graphics.Code_Class.None)
	}
}
