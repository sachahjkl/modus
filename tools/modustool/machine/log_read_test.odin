package machine

import "core:os"
import "core:strings"
import "core:testing"
import module "modus:contract/module"
import "modustool:build"
import "modustool:foundation"

// A machine for the tests of the reader of its log: its log file in a
// fresh folder, and a catalog of one sample module, so that the reader
// renders the lines of facts without the module files of a build.
@(private = "file")
log_read_test_machine :: proc(t: ^testing.T, folder: string, catalog: ^build.Fact_Catalog) -> (machine: Machine, hash: [module.HASH_SIZE]u8) {
	testing.expect(t, foundation.reset_folder(folder))
	for &value, index in hash {
		value = u8(index + 1)
	}
	catalog^ = build.Fact_Catalog {
		allocator = context.temp_allocator,
	}
	testing.expect_value(t, build.fact_catalog_add(catalog, hash, "", build.fact_render_file("probe: {value} {mark} {number}")), "")
	machine.output = strings.concatenate({folder, "/log.txt"}, context.temp_allocator)
	machine.fact_catalog = catalog
	machine.fact_rendered = make([dynamic]u8, context.temp_allocator)
	machine.fact_lines = make([dynamic]build.Fact_Line_Place, context.temp_allocator)
	return
}

// The serial port gives the line of a fact in parts: the reader sees the
// file cut at any byte of it. Each cut, its end of line too, gives no
// line of the fact and nothing raw of it; the whole line then gives its
// sentence once, and an ordered wait finds it. The file grows by each
// part, as the log of a machine does, so each read renders only the bytes
// after the last whole line.
@(test)
a_fact_line_cut_at_any_byte_is_read_whole_once :: proc(t: ^testing.T) {
	folder :: foundation.BUILD_FOLDER + "/log_read_test_cut"
	defer {
		_ = os.remove_all(folder)
	}
	catalog: build.Fact_Catalog
	machine, hash := log_read_test_machine(t, folder, &catalog)
	values := [16]u8{42, 0, 0, 0, 0, 0, 0, 0, 0x46, 0x47, 0x4f, 0x4c, 7, 0, 0, 0}
	raw_line := strings.concatenate({"[compositor] ", build.fact_render_line(hash, build.FACT_RENDER_KEY, values[:]), "\r\n"}, context.temp_allocator)
	rendered_line :: "[compositor] probe: 42 0x4c4f4746 7\r\n"
	plain_line :: "[input] input: a line between two facts\r\n"

	log := strings.builder_make(context.temp_allocator)
	expected := strings.builder_make(context.temp_allocator)
	for cut in 0 ..< len(raw_line) {
		// A plain line first, so that each fact line follows a line of
		// another process.
		strings.write_string(&log, plain_line)
		strings.write_string(&expected, plain_line)
		whole_before := strings.builder_len(log)
		strings.write_string(&log, raw_line[:cut])
		testing.expect(t, os.write_entire_file(machine.output, log.buf[:]) == nil)
		text := log_read(&machine)
		testing.expectf(t, text == strings.to_string(expected), "the cut at the byte %d gave a log that is not the whole lines before it", cut)
		testing.expect_value(t, machine.fact_raw_length, whole_before)

		strings.write_string(&log, raw_line[cut:])
		strings.write_string(&expected, rendered_line)
		testing.expect(t, os.write_entire_file(machine.output, log.buf[:]) == nil)
		testing.expectf(t, log_wait(&machine, rendered_line), "the wait did not find the line of the fact after the cut at the byte %d", cut)
		testing.expect_value(t, machine.seen, strings.builder_len(expected))
	}
	text := log_read(&machine)
	testing.expect_value(t, text, strings.to_string(expected))
	testing.expect_value(t, strings.count(text, rendered_line), len(raw_line))
	testing.expect_value(t, strings.count(text, build.FACT_LINE_MARK), 0)
	testing.expect_value(t, len(machine.fact_lines), len(raw_line))
	for place in machine.fact_lines {
		testing.expect_value(t, text[place.start:place.end], rendered_line)
		testing.expect_value(t, place.raw_count, len(raw_line))
	}
	testing.expect_value(t, machine.fact_raw_length, strings.builder_len(log))
}

// The input service and the compositor start at once, on their own
// processors: the line of the screen pages can come before the line of the
// wheel. The steps of the main scenario from "root: ok" to the screen pages
// find each line in that order, so no ordered wait moves the place of the
// log past a line that a later step needs.
@(test)
the_main_scenario_finds_the_screen_pages_before_the_wheel :: proc(t: ^testing.T) {
	folder :: foundation.BUILD_FOLDER + "/log_read_test_order"
	defer {
		_ = os.remove_all(folder)
	}
	catalog: build.Fact_Catalog
	machine, _ := log_read_test_machine(t, folder, &catalog)
	first, last := -1, -1
	for step, index in scenario {
		if step.text == "root: ok" {
			first = index
		}
		if step.fails_on == "compositor: one screen page" {
			last = index
		}
	}
	testing.expect(t, first >= 0 && last > first)
	if first < 0 || last <= first {
		return
	}
	WHEEL_LINE :: "input: ok, the mouse has a wheel"
	// The line of each step, in the order of the steps, except that the
	// line of the screen pages comes before the line of the wheel.
	log := strings.builder_make(context.temp_allocator)
	for step in scenario[first:last] {
		if step.text == WHEEL_LINE {
			strings.write_string(&log, "[compositor] ")
			strings.write_string(&log, scenario[last].text)
			strings.write_string(&log, "\r\n")
		}
		strings.write_string(&log, "[x] ")
		strings.write_string(&log, step.text)
		if step.kind == .Date {
			strings.write_string(&log, " 1795136402")
		}
		strings.write_string(&log, "\r\n")
	}
	testing.expect(t, strings.contains(strings.to_string(log), WHEEL_LINE))
	testing.expect(t, os.write_entire_file(machine.output, log.buf[:]) == nil)
	for step, offset in scenario[first:last + 1] {
		testing.expect(t, step.kind == .Wait || step.kind == .Date)
		if step.fails_on != "" {
			failure_line, text_found := log_wait_or_failure(&machine, step.text, step.fails_on, foundation.HANG_BOUND)
			if !testing.expectf(t, failure_line == "" && text_found, "step %d did not find \"%s\"", first + offset + 1, step.text) {
				return
			}
		}
		if !testing.expectf(t, log_wait(&machine, step.text, step.any_order), "step %d did not find \"%s\"", first + offset + 1, step.text) {
			return
		}
	}
}
