package build

import "core:testing"

// A comment that uses each construct of the subset.
@(private = "file")
COMMENT_WITH_EACH_CONSTRUCT :: "Seals a **text** with a *key*, as [the seal](system.word_wait) says. The second sentence.\nIt continues the paragraph.\n\n- `key`: 32 bytes;\n- `nonce`: 12 bytes, which\nnever repeat;\n  - a nested item.\n\n1. the first result;\n2. the second result.\n\n```odin\nx := seal(&key)\n```\n\n  a line   kept as it is"

// The text that a module carries: the marks go, the structure stays as
// plain lines, a code span keeps its backticks, and the first sentence is
// the first sentence with no mark.
@(test)
comment_markdown_text_that_a_module_carries :: proc(t: ^testing.T) {
	text := documentation_text_of_markdown(COMMENT_WITH_EACH_CONSTRUCT)
	expected := "Seals a text with a key, as the seal says. The second sentence. It continues the paragraph.\n\n- `key`: 32 bytes;\n- `nonce`: 12 bytes, which never repeat;\n  - a nested item.\n\n1. the first result;\n2. the second result.\n\n    x := seal(&key)\n\n  a line   kept as it is"
	testing.expect_value(t, text, expected)
	testing.expect_value(t, about_of(text, ""), "Seals a text with a key, as the seal says")
	testing.expect_value(t, markdown_first_sentence(COMMENT_WITH_EACH_CONSTRUCT), "Seals a text with a key, as the seal says")
	// A help line: the name of the export at its start goes, after the marks.
	testing.expect_value(t, about_of(documentation_text_of_markdown("**seal** gives a *sealed* text. More."), "seal"), "gives a sealed text")
	// A comment with no mark: its lines join, as before.
	testing.expect_value(t, documentation_text_of_markdown("A plain comment\non two lines.\n\nA second paragraph."), "A plain comment on two lines.\n\nA second paragraph.")
}

// The plain text of a line: a star of an expression stays; italics, bold
// and links go; code keeps its backticks or not.
@(test)
comment_markdown_inline_plain_text :: proc(t: ^testing.T) {
	testing.expect_value(t, markdown_inline_plain("a * b and 2*3*4", true), "a * b and 2*3*4")
	testing.expect_value(t, markdown_inline_plain("an *italic* and a **bold** word", true), "an italic and a bold word")
	testing.expect_value(t, markdown_inline_plain("`*x*` and [a link](term:handle)", true), "`*x*` and a link")
	testing.expect_value(t, markdown_inline_plain("`*x*` and [a link](term:handle)", false), "*x* and a link")
	testing.expect_value(t, markdown_inline_plain("[n % CAPACITY] and [x]", true), "[n % CAPACITY] and [x]")
	testing.expect_value(t, markdown_inline_plain("two\nlines", true), "two lines")
}
