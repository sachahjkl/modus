package checks

import "core:fmt"
import "core:strings"
import "modus:contract/blake3"
import debug_object "modus:contract/debug_object"
import "modustool:build"
import "modustool:foundation"

// The source file of the module fault, as its debug object names it.
FAULT_SOURCE_FILE :: foundation.DEMONSTRATION_MODULE_SOURCES + "fault/main.odin"

// source_lines_of_procedure gives the first and the last line (from 1) of a
// procedure of the top level of an Odin source: the line that starts with
// "<name> :: " and has "proc", to the first line after it that is "}".
source_lines_of_procedure :: proc(source: string, name: string) -> (first_line: int, last_line: int, found: bool) {
	start := strings.concatenate({name, " :: "}, context.temp_allocator)
	number := 0
	rest := source
	for line in strings.split_lines_iterator(&rest) {
		number += 1
		if first_line == 0 {
			if strings.has_prefix(line, start) && strings.contains(line, "proc") {
				first_line = number
			}
			continue
		}
		if strings.trim_right(line, " \t\r") == "}" {
			return first_line, number, true
		}
	}
	return 0, 0, false
}

// test_debug_objects reads the debug object of the module fault, which the
// build wrote, against the linked file of the module. `check` runs it after
// its build: the linked file is no test input, so no test part reads it
// (src/md/infrastructure/full_check.md, "The derivations of the check"). It
// checks the procedure fault::three found by an address inside it, the line
// of its first instruction, an address outside every procedure, the hash of
// the module, and a changed copy that a reader refuses.
test_debug_objects :: proc() -> bool {
	context.allocator = context.temp_allocator
	fail :: proc(format: string, args: ..any) -> bool {
		fmt.eprintf("modustool: test failed: the debug object of fault: ")
		fmt.eprintfln(format, ..args)
		return false
	}
	object := foundation.read_file(build.debug_object_path("fault")) or_return
	elf := foundation.read_file(foundation.join(foundation.MODULE_BUILD_FOLDER, "/fault/linked.elf")) or_return
	module_file := foundation.read_file(foundation.module_path("fault")) or_return
	if fault := debug_object.check(object); fault != .None {
		return fail("%s", debug_object.fault_sentences[fault])
	}
	hash, _ := debug_object.module_hash_of(object)
	if hash != blake3.hash(module_file) {
		return fail("it names another module")
	}
	// The address of fault::three, from the symbol table of the ELF file
	// with the code of the tool that does not write the debug object.
	header, sections, has_sections := build.elf_sections(elf)
	code_start, code_end := build.elf_code_range(elf, header)
	three: build.Debug_Procedure
	for item in build.elf_function_symbols(elf, sections, code_start, code_end) {
		if item.name == "fault::three" {
			three = item
		}
	}
	if !has_sections || three.size == 0 {
		return fail("the linked file has no procedure fault::three")
	}
	for offset in ([]u64{three.start, three.start + three.size / 2, three.start + three.size - 1}) {
		place := debug_object.place_of(object, offset)
		if place.procedure != "fault::three" || place.offset_in_procedure != offset - three.start || place.procedure[:place.package_count] != "fault" {
			return fail("the offset %x is in %s + %x, not in fault::three + %x", offset, place.procedure, place.offset_in_procedure, offset - three.start)
		}
	}
	// The lines of three come from the source itself: a line added above
	// the procedure moves them, and the check moves with them.
	source := foundation.read_file(FAULT_SOURCE_FILE) or_return
	first_line, last_line, has_lines := source_lines_of_procedure(string(source), "three")
	if !has_lines {
		return fail("%s has no procedure three", FAULT_SOURCE_FILE)
	}
	first := debug_object.place_of(object, three.start)
	if first.file != FAULT_SOURCE_FILE || int(first.line) < first_line || int(first.line) > last_line {
		return fail("the first instruction of fault::three is at %s:%d, not in %s:%d to %d", first.file, first.line, FAULT_SOURCE_FILE, first_line, last_line)
	}
	outside := debug_object.place_of(object, code_end + 0x1000)
	if outside.procedure != "" || outside.file != "" {
		return fail("the offset %x, after the code, is in %s at %s:%d", code_end + 0x1000, outside.procedure, outside.file, outside.line)
	}
	// The size of the first procedure made larger than the code: it
	// covers the procedure after it.
	changed := make([]u8, len(object))
	copy(changed, object)
	changed[size_of(debug_object.Header) + 4] = 0xFF
	changed[size_of(debug_object.Header) + 5] = 0xFF
	changed[size_of(debug_object.Header) + 6] = 0xFF
	if parts, fault := debug_object.tables(object); fault != .None || len(parts.procedures) < 2 || debug_object.check(changed) == .None {
		return fail("a procedure that covers the next one is not refused")
	}
	if debug_object.check(object[:len(object) - 1]) != .Size_Differs {
		return fail("an object one byte short is not refused")
	}
	// The tie to the module: the object is the one of this module file,
	// and of no other.
	other_hash := hash
	other_hash[0] ~= 1
	if !debug_object.describes_module(object, hash) || debug_object.describes_module(object, other_hash) {
		return fail("it does not say that it describes its module only")
	}
	// The source file of the first instruction has the hash of the file
	// of the repository.
	source_of_line, has_source := debug_object.source_line_of(object, three.start)
	source_file := foundation.read_file(FAULT_SOURCE_FILE) or_return
	if !has_source || source_of_line.path != FAULT_SOURCE_FILE || !source_of_line.content_hash_known || source_of_line.content_hash != blake3.hash(source_file) {
		return fail("the source file of fault::three is %s, and its hash is not the hash of " + FAULT_SOURCE_FILE, source_of_line.path)
	}
	// The parameter of fault::three and its type.
	address, has_address := debug_object.variable_by_name_at(object, three.start, "address")
	address_type, has_type := debug_object.type_by_index(object, address.type)
	if !has_address || address.role != .Parameter || !has_type || address_type.name != "uintptr" || address_type.kind != .Unsigned_Integer || address_type.size != 8 {
		return fail("the parameter address of fault::three is not a parameter of the type uintptr of 8 bytes: found %v, %v %v", has_address, address, address_type)
	}
	parts, _ := debug_object.tables(object)
	foundation.test_passed_print("the debug object of fault names fault::three at %x to %x, its first instruction at %s:%d; %d procedures, %d files, %d rows; a changed object is refused", three.start, three.start + three.size, first.file, first.line, len(parts.procedures), len(parts.files) - 1, len(parts.lines))
	foundation.test_passed_print("the debug object of fault describes its module only, has the hash of " + FAULT_SOURCE_FILE + ", and gives the parameter address of fault::three as a uintptr, place %v, register %d, offset %d; %d types, %d globals, %d variables in %d ranges", address.location, address.register, address.offset, len(parts.types) - 1, len(parts.globals), len(parts.variables), len(parts.ranges))
	return true
}
