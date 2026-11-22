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
		write = proc(data: rawptr, text: string) {
			written := (^Serial_Written)(data)
			strings.write_string(&written.text, text)
			written.writes += 1
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
