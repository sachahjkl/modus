package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "core:fmt"
import "core:strings"
import "core:testing"

// The facts of several records and their text views, on the host
// (src/md/features/log_facts.md, "A fact of several records" and "Text
// views"): the serial line that the kernel writes reads back to the bytes
// of each record joined; the extraction refuses a text view that is not
// last and a call with another count of texts; the render writes each
// text whole.

@(private = "file")
VIEWS_TEST_FOLDER :: "src/modules/tests/fact_views_probe"

@(private = "file")
VIEWS_TEST_IMPORTS :: `package fact_views_probe

import "modus:system"
import "modus:contract/value_kinds"
`

@(private = "file")
views_test_source :: proc(declarations, body: string) -> Fact_Source {
	text := fmt.tprintf("%s\n%s\n\nwrite :: proc() {{\n%s\n}}\n", VIEWS_TEST_IMPORTS, declarations, body)
	return {path = VIEWS_TEST_FOLDER + "/main.odin", source = text}
}

// views_line gives the serial line of a fact of value bytes, as the kernel
// writes it: the record of each part of op.LOG_FACT_VALUE_CAPACITY bytes,
// the first starting the line and each next one continuing it.
@(private = "file")
views_line :: proc(hash: [module.HASH_SIZE]u8, key: u64, values: []u8) -> string {
	part_count := op.log_fact_part_count(len(values))
	builder := strings.builder_make(context.temp_allocator)
	for part in 0 ..< part_count {
		start := part * op.LOG_FACT_VALUE_CAPACITY
		end := min(len(values), start + op.LOG_FACT_VALUE_CAPACITY)
		fact := op.Log_Fact{module_hash = hash, key = key, value_count = u16(end - start), part = u8(part), part_count = u8(part_count)}
		copy(fact.values[:], values[start:end])
		line: [op.LOG_FACT_LINE_BYTES_MOST]u8
		strings.write_string(&builder, string(line[:op.log_fact_line(&fact, &line, part > 0)]))
	}
	return strings.to_string(builder)
}

// The line of a fact of several records reads back to its bytes, each
// record joined, at the edges: one record, two, a middle record of zeros,
// and the bound of the records; each line that the kernel never writes is
// refused: a count of 0, 1 and one past the bound, a "/" with no count, a
// missing "/", one "/" too many, and a space with no value before a "/".
@(test)
the_line_of_a_fact_of_several_records_reads_back :: proc(t: ^testing.T) {
	hash: [module.HASH_SIZE]u8
	hash[0], hash[1], hash[2], hash[3] = 0x1a, 0x2b, 0x3c, 0x4d
	KEY :: u64(0xfa0a_df38_a559_f4d1)
	counts := [?]int{1, op.LOG_FACT_VALUE_CAPACITY, op.LOG_FACT_VALUE_CAPACITY + 1, 3 * op.LOG_FACT_VALUE_CAPACITY + 7, op.LOG_FACT_VALUES_MOST}
	for count in counts {
		values := make([]u8, count, context.temp_allocator)
		for &value, index in values {
			value = u8(index % 251 + 1)
		}
		// A record of zeros in the middle of a fact of three records or more.
		if count > 2 * op.LOG_FACT_VALUE_CAPACITY {
			for &value in values[op.LOG_FACT_VALUE_CAPACITY:][:op.LOG_FACT_VALUE_CAPACITY] {
				value = 0
			}
		}
		line, ok := fact_line_parse(views_line(hash, KEY, values))
		testing.expectf(t, ok && line.value_count == count && line.part_count == op.log_fact_part_count(count), "a fact of %d bytes reads back %d bytes, %d records", count, line.value_count, line.part_count)
		testing.expectf(t, string(line.values[:count]) == string(values), "a fact of %d bytes reads back other bytes", count)
	}
	// Nine records: a last record of the rest of the bound, 16 bytes, is
	// read; one of 17 bytes passes the values of a fact and is refused,
	// never read past them.
	rest := op.LOG_FACT_VALUES_MOST - (op.LOG_FACT_RECORDS_MOST - 1) * op.LOG_FACT_VALUE_CAPACITY
	for last_bytes in ([2]int{rest, rest + 1}) {
		count := (op.LOG_FACT_RECORDS_MOST - 1) * op.LOG_FACT_VALUE_CAPACITY + last_bytes
		values := make([]u8, count, context.temp_allocator)
		for &value in values {
			value = 0x5a
		}
		text := views_line(hash, KEY, values)
		testing.expect(t, strings.contains(text, fmt.tprintf("*%d", op.LOG_FACT_RECORDS_MOST)))
		line, ok := fact_line_parse(text)
		if last_bytes == rest {
			testing.expect(t, ok && line.value_count == op.LOG_FACT_VALUES_MOST && line.part_count == op.LOG_FACT_RECORDS_MOST)
		} else {
			testing.expect(t, !ok)
		}
	}
	HEAD :: "#1a2b3c4d:fa0adf"
	refused := [?]string {
		HEAD + "*0 01",
		HEAD + "*1 01",
		fmt.tprintf("%s*%d 01", HEAD, op.LOG_FACT_RECORDS_MOST + 1),
		HEAD + "/01",
		HEAD + " 01/02",
		HEAD + "*2 01",
		HEAD + "*2 01/02/03",
		HEAD + "*2 /02",
		HEAD + "*2 01/0g",
		HEAD + "*",
	}
	for text in refused {
		_, parsed := fact_line_parse(text)
		testing.expectf(t, !parsed, "the text %q is read as a fact", text)
	}
	// A fact of two records whose first record is zeros: the count and a
	// "/" with no space.
	zeros, zeros_ok := fact_line_parse(HEAD + "*2/0d")
	testing.expect(t, zeros_ok && zeros.value_count == op.LOG_FACT_VALUE_CAPACITY + 1 && zeros.values[op.LOG_FACT_VALUE_CAPACITY] == 0x0d && zeros.values[0] == 0)
	// A last record of zeros: its "/" alone, and the values of the records
	// before it.
	last_zero, last_zero_ok := fact_line_parse(HEAD + "*2 01/")
	testing.expect(t, last_zero_ok && last_zero.value_count == op.LOG_FACT_VALUE_CAPACITY && last_zero.values[0] == 1)
}

// The fact types of text views that the extraction refuses: a field after
// a text view, and a call with fewer, more, or named texts than views, or
// a spread of them.
@(test)
a_fact_of_text_views_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	VIEW_TYPE :: "@(log_fact = \"probe: {status} {path}\")\nServed :: struct {\n\tstatus: u64,\n\tpath:   value_kinds.Text_View,\n}"
	Case :: struct {
		name:         string,
		declarations: string,
		body:         string,
	}
	cases := [?]Case {
		{"a field after a text view", "@(log_fact = \"probe: {path} {status}\")\nServed :: struct {\n\tpath:   value_kinds.Text_View,\n\tstatus: u64,\n}", "system.log_fact(.Info, Served{status = 1}, \"a\")"},
		{"no text for a view", VIEW_TYPE, "system.log_fact(.Info, Served{status = 1})"},
		{"two texts for one view", VIEW_TYPE, "system.log_fact(.Info, Served{status = 1}, \"a\", \"b\")"},
		{"a named text", VIEW_TYPE, "system.log_fact(.Info, Served{status = 1}, texts = \"a\")"},
		{"a spread of texts", VIEW_TYPE, "texts := []string{\"a\"}\nsystem.log_fact(.Info, Served{status = 1}, ..texts)"},
		{"a text for a fact type with no view", "@(log_fact = \"probe: {status}\")\nPlain :: struct {\n\tstatus: u64,\n}", "system.log_fact(.Info, Plain{status = 1}, \"a\")"},
		{"a second call with another count", VIEW_TYPE, "system.log_fact(.Info, Served{status = 1}, \"a\")\nsystem.log_fact(.Info, Served{status = 2})"},
	}
	for item in cases {
		sources := [1]Fact_Source{views_test_source(item.declarations, item.body)}
		facts, ok := facts_of_sources(sources[:])
		testing.expectf(t, !ok && len(facts) == 0, "the extraction takes %s", item.name)
	}
}

// view_bytes gives the 16 bytes of a text view, as the write makes them.
@(private = "file")
view_bytes :: proc(text: string, offset: u64) -> (view: [value_kinds.TEXT_VIEW_BYTES]u8) {
	length := u32(len(text))
	view[0], view[1], view[2], view[3] = u8(length), u8(length >> 8), u8(length >> 16), u8(length >> 24)
	if len(text) <= value_kinds.TEXT_VIEW_INLINE_BYTES_MOST {
		copy(view[4:], text)
		return
	}
	copy(view[4:8], text)
	for index in 0 ..< 8 {
		view[8 + index] = u8(offset >> (8 * u64(index)))
	}
	return
}

// The last case: a fact type of two text views is described, called with
// two texts, and its sentence holds each text whole: two short texts, a
// long one of the first record, and one past the first record, joined
// from its serial line; a view past its area is refused, never written.
@(test)
the_texts_of_a_fact_are_rendered_whole :: proc(t: ^testing.T) {
	declarations := "@(log_fact = \"probe: {status} {path} {line}\")\nServed :: struct {\n\tstatus: u64,\n\tpath:   value_kinds.Text_View,\n\tline:   value_kinds.Text_View,\n}"
	sources := [1]Fact_Source{views_test_source(declarations, "system.log_fact(.Info, Served{status = 7}, \"/a\", \"b\")")}
	facts, ok := facts_of_sources(sources[:])
	if !testing.expect(t, ok && len(facts) == 1) {
		return
	}
	served := facts[0]
	testing.expect_value(t, served.record.size, u32(8 + 2 * value_kinds.TEXT_VIEW_BYTES))
	testing.expect(t, len(served.record.fields) == 3 && served.record.fields[1].kind == .Text_View && served.record.fields[1].offset == 8 && served.record.fields[2].offset == 24)
	description: Module_Description
	if !testing.expect(t, facts_merge(&description, facts)) {
		return
	}
	file := facts_module_file(description)
	size := int(served.record.size)
	Case :: struct {
		path, line: string,
	}
	long := strings.repeat("p", op.LOG_FACT_VALUE_CAPACITY, context.temp_allocator)
	// The last case: a text of the area whose last byte is zero, which the
	// serial line cuts with the zeros after the values.
	cases := [?]Case{{"", ""}, {"/a", "short line"}, {"/modules/module_files/a", "b"}, {long, "/modules/after/the/first/record"}, {"x", "/modules/ends/with/zero\x00"}}
	for item in cases {
		values := make([]u8, size + op.LOG_FACT_TEXT_AREA_BYTES_MOST, context.temp_allocator)
		values[0] = 7
		area := 0
		texts := [2]string{item.path, item.line}
		for text, index in texts {
			view := view_bytes(text, u64(area))
			copy(values[8 + index * value_kinds.TEXT_VIEW_BYTES:], view[:])
			if len(text) > value_kinds.TEXT_VIEW_INLINE_BYTES_MOST {
				area += copy(values[size + area:], text)
			}
		}
		whole := values[:size + area]
		// The render writes a byte that is no character, the zero too, as "?".
		expected, _ := strings.replace_all(fmt.tprintf("probe: 7 %s %s", item.path, item.line), "\x00", "?", context.temp_allocator)
		sentence, rendered := fact_values_render(file, served.key, whole)
		testing.expectf(t, rendered && sentence == expected, "the texts %q and %q render %q", item.path, item.line, sentence)
		// The same fact through its serial line. The line holds the values
		// up to their last byte that is not zero, and the bytes after are
		// zero; the render reads the record and the whole area.
		hash := [module.HASH_SIZE]u8{}
		line, parsed := fact_line_parse(views_line(hash, served.key, whole))
		testing.expectf(t, parsed && line.value_count <= len(whole) && string(line.values[:len(whole)]) == string(whole), "the texts %q and %q do not read back from the line", item.path, item.line)
		line_sentence, line_rendered := fact_values_render(file, served.key, line.values[:size + op.LOG_FACT_TEXT_AREA_BYTES_MOST])
		testing.expectf(t, line_rendered && line_sentence == expected, "the line of the texts %q and %q renders %q", item.path, item.line, line_sentence)
		// The area one byte short: the view of the last long text passes
		// it, and the render refuses the fact.
		if area > 0 {
			_, short_rendered := fact_values_render(file, served.key, whole[:len(whole) - 1])
			testing.expect(t, !short_rendered)
		}
	}
	// A view of a short text with a byte past its length is refused.
	dirty := make([]u8, size, context.temp_allocator)
	view := view_bytes("ab", 0)
	view[15] = 1
	copy(dirty[8:], view[:])
	_, dirty_rendered := fact_values_render(file, served.key, dirty)
	testing.expect(t, !dirty_rendered)
	// An area past its bound is refused.
	past := make([]u8, size + op.LOG_FACT_TEXT_AREA_BYTES_MOST + 1, context.temp_allocator)
	_, past_rendered := fact_values_render(file, served.key, past)
	testing.expect(t, !past_rendered)
}
