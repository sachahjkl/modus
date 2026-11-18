package foundation

import "core:strings"
import "core:testing"

// A line of an Odin source as a line of the Markdown of its comment: the
// marker and one space go, the indentation after them stays.
@(test)
comment_markdown_line_of_a_source :: proc(t: ^testing.T) {
	code, comment, is_comment := markdown_comment_line("\tName = 3, // (a, b) -> c.")
	testing.expect(t, code == "Name = 3," && comment == "(a, b) -> c." && is_comment)
	_, nested, _ := markdown_comment_line("\t//   - a nested item")
	testing.expect_value(t, nested, "  - a nested item")
	_, empty, empty_is_comment := markdown_comment_line("\t//")
	testing.expect(t, empty == "" && empty_is_comment)
	_, _, not_comment := markdown_comment_line("x := \"// not a comment\"")
	testing.expect(t, !not_comment)
}

@(test)
json_string_escapes :: proc(t: ^testing.T) {
	escaped :: proc(text: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		json_string_write(&b, text)
		return strings.to_string(b)
	}
	testing.expect_value(t, escaped("plain"), "\"plain\"")
	testing.expect_value(t, escaped("a \"quote\""), "\"a \\\"quote\\\"\"")
	testing.expect_value(t, escaped("a \\ b"), "\"a \\\\ b\"")
	testing.expect_value(t, escaped("</script><!--"), "\"\\u003c/script\\u003e\\u003c!--\"")
	testing.expect_value(t, escaped("a & b"), "\"a \\u0026 b\"")
	testing.expect_value(t, escaped("one\u2028two\u2029"), "\"one\\u2028two\\u2029\"")
	testing.expect_value(t, escaped("a\nb\x01\x7f"), "\"a\\nb\\u0001\\u007f\"")
	testing.expect_value(t, escaped("é ü"), "\"é ü\"")
	testing.expect_value(t, escaped("a\xffb"), "\"a\\ufffdb\"")
	testing.expect_value(t, escaped(""), "\"\"")
}

@(test)
png_size_of_a_file :: proc(t: ^testing.T) {
	header := []u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 4, 0, 0, 0, 3, 0}
	width, height, ok := png_size(header)
	testing.expect(t, ok)
	testing.expect_value(t, width, 1024)
	testing.expect_value(t, height, 768)
	_, _, short_ok := png_size(header[:20])
	testing.expect(t, !short_ok)
	not_png := make([]u8, len(header), context.temp_allocator)
	copy(not_png, header)
	not_png[1] = 'X'
	_, _, not_png_ok := png_size(not_png)
	testing.expect(t, !not_png_ok)
}
