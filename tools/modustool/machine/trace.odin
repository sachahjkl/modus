package machine

import debug_object "modus:contract/debug_object"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "modustool:foundation"
import "modustool:build"
import "modustool:checks"

// The names of the procedures of a stack trace. A process that has the
// debug image names each frame itself: "fault::three + 0x8 in fault
// (src/modules/demonstrations/fault/main.odin:15)". The kernel gives a frame as "module +
// offset" (docs/MODULE_CONTRACT.md, section 8); the tool names such a
// frame from the debug object of the module, which the build wrote.

// procedure_at gives the name of the procedure of a debug object that
// holds an offset, and its source line. "" when no procedure holds it.
procedure_at :: proc(object: []u8, offset: u64) -> (name: string, file: string, line: u32) {
	if debug_object.check(object) != .None {
		return "", "", 0
	}
	place := debug_object.place_of(object, offset)
	return place.procedure, place.file, place.line
}

// trace_check reads a stack trace on a line of the log, after `text`:
// frames separated by ", ". A frame that the system named has its name
// before " + 0x" and its module after " in ". A frame "module + 0xOFFSET"
// is named from the debug object of the module. The names of the frames,
// from frame 0, must start with `names` (separated by spaces). A return
// address is the instruction after the call: the tool names the address
// before it.
trace_check :: proc(line: string, names: string) -> (found: string, ok: bool) {
	context.allocator = context.temp_allocator
	list := make([dynamic]string)
	frames := strings.split(strings.trim_space(line), ", ")
	for frame, number in frames {
		if strings.contains(frame, " in ") {
			end := strings.index(frame, " + 0x")
			if end < 0 {
				end = strings.index(frame, " in ")
			}
			append(&list, frame[:end])
			continue
		}
		parts := strings.split(frame, " + 0x")
		if len(parts) != 2 {
			return fmt.tprintf("the frame \"%s\" has no form \"module + 0xOFFSET\"", frame), false
		}
		offset, parsed := strconv.parse_u64_of_base(parts[1], 16)
		if !parsed {
			return fmt.tprintf("the frame \"%s\" has no offset", frame), false
		}
		object, read := foundation.read_file(build.debug_object_path(parts[0]))
		if !read {
			return fmt.tprintf("no debug object of the module %s", parts[0]), false
		}
		name, _, _ := procedure_at(object, number == 0 || offset == 0 ? offset : offset - 1)
		append(&list, name == "" ? "?" : name)
	}
	found = strings.join(list[:], " ")
	return found, strings.has_prefix(found, names)
}

// Re-exported from checks so callers in machine and tests keep one name.
FAULT_SOURCE_FILE :: checks.FAULT_SOURCE_FILE
source_lines_of_procedure :: checks.source_lines_of_procedure
test_debug_objects :: checks.test_debug_objects
