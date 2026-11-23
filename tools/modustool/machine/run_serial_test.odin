#+build !freestanding
package machine

import "core:strings"
import "core:testing"
import module "modus:contract/module"
import "modustool:build"

// What a renderer wrote, and the count of its writes.
@(private = "file")
Serial_Written :: struct {
	text:   strings.Builder,
	writes: int,
}

@(private = "file")
serial_written_renderer :: proc(catalog: ^build.Fact_Catalog, written: ^Serial_Written) -> Serial_Line_Renderer {
	written.text = strings.builder_make(context.temp_allocator)
	return {
		catalog = catalog,
		write = proc(data: rawptr, text: string) -> bool {
			written := (^Serial_Written)(data)
			strings.write_string(&written.text, text)
			written.writes += 1
			return true
		},
		write_data = written,
	}
}

// The serial line of a run: a line of a fact becomes its sentence when it
// ends, even when its bytes come in many reads; a raw line stays as it is;
// a line of a fact of a module that the catalog does not hold stays raw; a
// prompt with no end of line goes out at once, before its line ends.
@(test)
the_serial_line_of_a_run_shows_each_fact_as_its_sentence :: proc(t: ^testing.T) {
	hash: [module.HASH_SIZE]u8
	for &value, index in hash {
		value = u8(index + 1)
	}
	other_hash: [module.HASH_SIZE]u8
	catalog := build.Fact_Catalog{allocator = context.temp_allocator}
	_ = build.fact_catalog_add(&catalog, hash, "", build.fact_render_file("probe: {value} {mark} {number}"))
	values: [16]u8
	values[0] = 7
	values[8] = 0xAB
	values[12] = 3
	line := build.fact_render_line(hash, build.FACT_RENDER_KEY, values[:])
	unknown := build.fact_render_line(other_hash, build.FACT_RENDER_KEY, values[:])
	written: Serial_Written
	renderer := serial_written_renderer(&catalog, &written)
	serial := strings.concatenate({"[root] a raw line\r\n[compositor] ", line, "\r\n[log] ", unknown, "\n> "}, context.temp_allocator)
	// One byte for each read: the worst cut of the lines.
	for index in 0 ..< len(serial) {
		serial_renderer_feed(&renderer, transmute([]u8)serial[index:][:1])
	}
	text := strings.to_string(written.text)
	testing.expectf(t, strings.has_prefix(text, "[root] a raw line\r\n[compositor] probe: 7 0x000000ab 3\r\n"), "the run shows %q", text)
	testing.expectf(t, strings.contains(text, strings.concatenate({"[log] ", unknown, "\n"}, context.temp_allocator)), "a fact of no module is not raw: %q", text)
	// The prompt came with no end of line: it is shown already.
	testing.expectf(t, strings.has_suffix(text, "> "), "the prompt waits for its end of line: %q", text)
	serial_renderer_end(&renderer)
	testing.expect_value(t, strings.to_string(written.text), text)
}

// The edges of the held start of a line: no byte, a byte that is no "[",
// a head that is no head of a fact, a head of a fact, and a line of a fact
// with no end of line past the bound, which goes out as it is.
@(test)
a_line_is_held_only_while_it_can_be_a_fact :: proc(t: ^testing.T) {
	testing.expect(t, serial_line_could_be_fact(nil))
	testing.expect(t, !serial_line_could_be_fact(transmute([]u8)string("x")))
	testing.expect(t, serial_line_could_be_fact(transmute([]u8)string("[")))
	testing.expect(t, serial_line_could_be_fact(transmute([]u8)string("[root")))
	testing.expect(t, serial_line_could_be_fact(transmute([]u8)string("[root] ")))
	testing.expect(t, serial_line_could_be_fact(transmute([]u8)string("[root] #")))
	testing.expect(t, !serial_line_could_be_fact(transmute([]u8)string("[root] a")))
	testing.expect(t, !serial_line_could_be_fact(transmute([]u8)string("[root]x")))
	long := make([]u8, SERIAL_LINE_HELD_MOST, context.temp_allocator)
	for &value in long {
		value = '#'
	}
	long[0] = '['
	testing.expect(t, !serial_line_could_be_fact(long), "a line past the bound is held")
	testing.expect(t, serial_line_could_be_fact(long[:SERIAL_LINE_HELD_MOST - 1]), "a line under the bound goes out")

	catalog := build.Fact_Catalog{allocator = context.temp_allocator}
	written: Serial_Written
	renderer := serial_written_renderer(&catalog, &written)
	serial_renderer_feed(&renderer, long)
	testing.expect_value(t, strings.builder_len(written.text), SERIAL_LINE_HELD_MOST)
	// The rest of that line goes out as it comes, and the next line is
	// held again.
	serial_renderer_feed(&renderer, transmute([]u8)string("tail\n[root"))
	testing.expect_value(t, strings.builder_len(written.text), SERIAL_LINE_HELD_MOST + len("tail\n"))
	serial_renderer_end(&renderer)
	testing.expect_value(t, strings.builder_len(written.text), SERIAL_LINE_HELD_MOST + len("tail\n[root"))
}
// With a catalog that renders nothing, the bytes that the renderer writes
// are the bytes that it was fed, for every cut of the input into reads: a
// NUL byte, invalid UTF-8, a lone carriage return, an empty read, a head
// of a fact held to its bound and closed at it, and a line whose mark of a
// fact comes after the bound.
@(test)
the_serial_line_keeps_each_byte_for_each_cut :: proc(t: ^testing.T) {
	at_bound := make([]u8, 1 + 4095 + 1, context.temp_allocator)
	at_bound[0] = '['
	for index in 1 ..< len(at_bound) - 1 {
		at_bound[index] = 'a'
	}
	at_bound[len(at_bound) - 1] = ']'
	late_mark := make([]u8, SERIAL_LINE_HELD_MOST + 10, context.temp_allocator)
	late_mark[0] = '['
	for index in 1 ..< len(late_mark) {
		late_mark[index] = 'b'
	}
	copy(late_mark[SERIAL_LINE_HELD_MOST + 2:], "] #")
	inputs := []string {
		"a\x00b\n[root] \x00\n",
		"\xff\xfe[\xc3\n[root] #\xe9\n",
		"[root] a\rb\r\n\r",
		"",
		strings.concatenate({string(at_bound), "\n[x"}, context.temp_allocator),
		strings.concatenate({string(late_mark), " tail\n"}, context.temp_allocator),
	}
	catalog := build.Fact_Catalog{allocator = context.temp_allocator}
	for input in inputs {
		for cut in ([?]int{1, 2, 7, 4096, max(int)}) {
			written: Serial_Written
			renderer := serial_written_renderer(&catalog, &written)
			for start := 0; start < len(input); start += cut {
				testing.expect(t, serial_renderer_feed(&renderer, transmute([]u8)input[start:][:min(cut, len(input) - start)]))
			}
			// An empty read changes nothing.
			testing.expect(t, serial_renderer_feed(&renderer, nil))
			testing.expect(t, serial_renderer_end(&renderer))
			testing.expectf(t, strings.to_string(written.text) == input, "a cut of %d changes %q into %q", cut, input, strings.to_string(written.text))
		}
	}
}

// A write that fails stops the renderer: no byte is written after it, and
// each feed and the end say so.
@(test)
a_failed_write_stops_the_serial_line :: proc(t: ^testing.T) {
	catalog := build.Fact_Catalog{allocator = context.temp_allocator}
	writes := 0
	renderer := Serial_Line_Renderer {
		catalog = &catalog,
		write = proc(data: rawptr, text: string) -> bool {
			(^int)(data)^ += 1
			return false
		},
		write_data = &writes,
	}
	testing.expect(t, !serial_renderer_feed(&renderer, transmute([]u8)string("one\ntwo\n")))
	testing.expect_value(t, writes, 1)
	testing.expect(t, !serial_renderer_feed(&renderer, transmute([]u8)string("three\n")))
	testing.expect(t, !serial_renderer_end(&renderer))
	testing.expect_value(t, writes, 1)
}

// bytes_write_whole: a writer that takes one byte at a time gets each byte
// in order; a writer that takes nothing, one that takes more than it was
// given, and one that fails stop the write; no bytes need no call.
@(test)
a_write_goes_on_until_each_byte_is_written :: proc(t: ^testing.T) {
	Sink :: struct {
		text:  strings.Builder,
		calls: int,
		mode:  int, // 0: one byte; 1: none; 2: one more than given; 3: a failure.
	}
	write_part :: proc(data: rawptr, bytes: []u8) -> (count: int, ok: bool) {
		sink := (^Sink)(data)
		sink.calls += 1
		switch sink.mode {
		case 0:
			strings.write_byte(&sink.text, bytes[0])
			return 1, true
		case 1:
			return 0, true
		case 2:
			return len(bytes) + 1, true
		}
		return 0, false
	}
	sink := Sink{text = strings.builder_make(context.temp_allocator)}
	testing.expect(t, bytes_write_whole(write_part, &sink, transmute([]u8)string("abc")))
	testing.expect(t, strings.to_string(sink.text) == "abc" && sink.calls == 3)
	sink.calls = 0
	testing.expect(t, bytes_write_whole(write_part, &sink, nil))
	testing.expect_value(t, sink.calls, 0)
	for mode in 1 ..= 3 {
		sink.mode = mode
		testing.expectf(t, !bytes_write_whole(write_part, &sink, transmute([]u8)string("abc")), "the mode %d writes", mode)
	}
}
