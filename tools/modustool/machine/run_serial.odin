package machine

import "core:fmt"
import "core:os"
import "modustool:build"

// The serial line of `modustool run`: QEMU writes the log of the kernel on
// its standard output, a line of a fact as its encoded values. The tool
// reads that output through a pipe and writes each line on its own output
// when the line is whole, a line of a fact as its sentence, by the same
// catalog and the same render as the checks of a machine test
// (build.fact_lines_render). The developer reads sentences, and the tests
// and the run read one form.

// The bytes of a partial line that the renderer holds while it waits for
// the end of a line of a fact. Past it, the line goes out as it is: a line
// that long is no line of a fact, and a reader must not wait for it.
SERIAL_LINE_HELD_MOST :: 4096

// Serial_Line_Renderer keeps the bytes of the line that has not ended.
Serial_Line_Renderer :: struct {
	catalog:   ^build.Fact_Catalog,
	held:      [dynamic]u8, // The start of a line that can be a line of a fact.
	passing:   bool, // The line now written is no line of a fact: its bytes go out as they come.
	write:     proc(data: rawptr, text: string), // Where the text goes.
	write_data: rawptr,
}

// serial_line_could_be_fact says if the start of a line can still become
// the head of a line of a fact: "[", a process name, "] #". A line that
// starts in another way goes out at once, so a prompt with no end of line
// is shown when it comes.
serial_line_could_be_fact :: proc(start: []u8) -> bool {
	if len(start) == 0 {
		return true
	}
	if start[0] != '[' {
		return false
	}
	close := -1
	for value, index in start {
		if value == ']' {
			close = index
			break
		}
		if value == '\n' {
			return false
		}
	}
	if close < 0 {
		return len(start) < SERIAL_LINE_HELD_MOST
	}
	mark := build.FACT_LINE_MARK
	for index in 0 ..< len(mark) {
		place := close + index
		if place >= len(start) {
			return true
		}
		if start[place] != mark[index] {
			return false
		}
	}
	return len(start) < SERIAL_LINE_HELD_MOST
}

// serial_renderer_feed takes bytes of the serial line as they come, and
// writes each line of a fact that ends as its sentence and each other byte
// as it is. A line of a fact that the catalog does not render stays raw.
serial_renderer_feed :: proc(renderer: ^Serial_Line_Renderer, bytes: []u8) {
	rest := bytes
	for len(rest) > 0 {
		end := -1
		for value, index in rest {
			if value == '\n' {
				end = index
				break
			}
		}
		piece := end < 0 ? rest : rest[:end + 1]
		rest = rest[len(piece):]
		if renderer.passing {
			renderer.write(renderer.write_data, string(piece))
		} else {
			append(&renderer.held, ..piece)
			if end >= 0 {
				rendered, _ := build.fact_lines_render(renderer.catalog, string(renderer.held[:]))
				renderer.write(renderer.write_data, rendered)
				clear(&renderer.held)
			} else if !serial_line_could_be_fact(renderer.held[:]) {
				renderer.write(renderer.write_data, string(renderer.held[:]))
				clear(&renderer.held)
				renderer.passing = true
			}
		}
		if end >= 0 {
			renderer.passing = false
		}
	}
}

// serial_renderer_end writes the bytes that a line held when the line
// stops with no end of line.
serial_renderer_end :: proc(renderer: ^Serial_Line_Renderer) {
	if len(renderer.held) > 0 {
		renderer.write(renderer.write_data, string(renderer.held[:]))
		clear(&renderer.held)
	}
	delete(renderer.held)
}

// run_with_rendered_serial runs a machine whose serial line is the standard
// output of QEMU (machine_command with no test output), and writes that
// line rendered on the output of the tool. The input of the tool stays the
// input of QEMU. It gives false when QEMU cannot start or ends with a
// failure.
run_with_rendered_serial :: proc(command: []string) -> bool {
	catalog, problem := build.fact_catalog_of_build(context.allocator)
	if problem != "" {
		fmt.eprintfln("modustool: the facts of the log cannot be rendered: %s", problem)
		return false
	}
	output_read, output_write, pipe_error := os.pipe()
	if pipe_error != nil {
		fmt.eprintfln("modustool: cannot create a pipe: %v", pipe_error)
		return false
	}
	host_process, start_error := os.process_start({command = command, stdin = os.stdin, stdout = output_write, stderr = os.stderr})
	// QEMU holds its copy: the read end sees the end of the output when
	// QEMU stops.
	os.close(output_write)
	if start_error != nil {
		os.close(output_read)
		fmt.eprintfln("modustool: cannot start %s: %v", command[0], start_error)
		return false
	}
	renderer := Serial_Line_Renderer {
		catalog = &catalog,
		write = proc(data: rawptr, text: string) {
			_, _ = os.write_string(os.stdout, text)
		},
	}
	buffer: [4096]u8
	for {
		count, read_error := os.read(output_read, buffer[:])
		if count > 0 {
			serial_renderer_feed(&renderer, buffer[:count])
			// A run lasts hours: the sentences of each read are written.
			free_all(context.temp_allocator)
		}
		if read_error != nil || count == 0 {
			break
		}
	}
	serial_renderer_end(&renderer)
	os.close(output_read)
	state, wait_error := os.process_wait(host_process)
	if wait_error != nil || !state.success {
		fmt.eprintfln("modustool: %s failed (code %d)", command[0], state.exit_code)
		return false
	}
	return true
}
