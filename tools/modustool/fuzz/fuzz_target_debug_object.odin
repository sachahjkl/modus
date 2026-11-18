package fuzz

import "base:intrinsics"
import "core:slice"
import debug_object "modus:contract/debug_object"

// The fuzz targets of the debug object (src/md/infrastructure/fuzzing.md,
// "The targets, in order of value"): it comes beside a disk process, from
// the network, and the debugger service reads it. An object that `check`
// accepts gives each reader with no fault, and `encode` of its tables
// gives its bytes back.

// The indexes of each table that the target reads.
FUZZ_DEBUG_OBJECT_INDEX_LIMIT :: 32

// fuzz_debug_object_readers runs check, then each reader on an object that
// it accepts.
fuzz_debug_object_readers :: proc(object: []u8) -> Fuzz_Verdict {
	fault := debug_object.check(object)
	if fault > max(debug_object.Fault) {
		return fuzz_broken(.Contract, "check gives a value out of its enumeration: %d", u32(fault))
	}
	if fault != .None {
		return FUZZ_PASSED
	}
	parts, tables_fault := debug_object.tables(object)
	if tables_fault != .None {
		return fuzz_broken(.Two_Readers, "check accepts an object that tables refuses: %v", tables_fault)
	}
	// The offsets where a reader looks: each start and each end of a
	// procedure and of a row, and the edges of the address range.
	offsets := make([dynamic]u64, context.temp_allocator)
	append(&offsets, 0, 1, u64(max(u32)), max(u64))
	for procedure in parts.procedures[:min(len(parts.procedures), FUZZ_DEBUG_OBJECT_INDEX_LIMIT)] {
		append(&offsets, u64(procedure.start), u64(procedure.start) + u64(procedure.size) - 1, u64(procedure.start) + u64(procedure.size))
	}
	for row in parts.lines[:min(len(parts.lines), FUZZ_DEBUG_OBJECT_INDEX_LIMIT)] {
		append(&offsets, u64(row.offset))
	}
	for offset in offsets {
		_ = debug_object.place_of(object, offset)
		_, _ = debug_object.source_line_of(object, offset)
		_, _ = debug_object.variable_range_of_offset(object, offset)
		_, _ = debug_object.variable_by_name_at(object, offset, "value")
		for index in 0 ..< u32(min(len(parts.variables) + 1, FUZZ_DEBUG_OBJECT_INDEX_LIMIT)) {
			_, _, _ = debug_object.variable_at(object, index, offset)
		}
	}
	for index in 0 ..< u32(min(len(parts.types) + 1, FUZZ_DEBUG_OBJECT_INDEX_LIMIT)) {
		_, _ = debug_object.type_by_index(object, index)
		for number in 0 ..< u32(4) {
			_, _ = debug_object.field_of_type(object, index, number)
			_, _, _ = debug_object.enumeration_value_of_type(object, index, number)
		}
		_, _ = debug_object.field_by_name(object, index, "value")
	}
	globals := debug_object.global_count(object)
	for index in 0 ..< min(globals + 1, FUZZ_DEBUG_OBJECT_INDEX_LIMIT) {
		_, _ = debug_object.global_by_index(object, index)
	}
	_, _ = debug_object.global_by_name(object, "value")
	for index in 0 ..< u32(min(len(parts.variables) + 1, FUZZ_DEBUG_OBJECT_INDEX_LIMIT)) {
		ranges := debug_object.variable_range_count(object, index)
		for number in 0 ..< min(ranges + 1, 4) {
			_, _ = debug_object.variable_range_by_index(object, index, number)
		}
	}
	hash, valid := debug_object.module_hash_of(object)
	if !valid || !debug_object.describes_module(object, hash) {
		return fuzz_broken(.Two_Readers, "the module hash of a checked object does not describe its module")
	}
	// The round trip: the tables that the reader gives encode to the same
	// bytes.
	encode_parts := debug_object.Encode_Parts {
		module_hash = parts.header.module_hash,
		procedures  = parts.procedures,
		files       = parts.files,
		lines       = parts.lines,
		types       = parts.types,
		fields      = parts.fields,
		values      = parts.values,
		globals     = parts.globals,
		variables   = parts.variables,
		ranges      = parts.ranges,
		strings     = parts.strings,
	}
	size := debug_object.encoded_size(encode_parts)
	if size != u64(len(object)) {
		return fuzz_broken(.Round_Trip, "the tables of an object encode to another size: %d, not %d", size, len(object))
	}
	encoded := make([]u8, size, context.temp_allocator)
	if !debug_object.encode(encode_parts, encoded) || !slice.equal(encoded, object) {
		return fuzz_broken(.Round_Trip, "the tables of an object do not encode to its bytes")
	}
	return FUZZ_PASSED
}

fuzz_debug_object_execute :: proc(input: []u8) -> Fuzz_Verdict {
	return fuzz_debug_object_readers(input)
}

// fuzz_debug_object_regions gives the header and the tables of procedures,
// files and rows, at the places that the counts of the header give.
fuzz_debug_object_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	if len(input) < size_of(debug_object.Header) {
		return
	}
	append(regions, Fuzz_Region{offset = 0, type = debug_object.Header, count = 1})
	header: debug_object.Header
	intrinsics.mem_copy_non_overlapping(&header, raw_data(input), size_of(debug_object.Header))
	at := size_of(debug_object.Header)
	fuzz_debug_object_region_add(regions, len(input), &at, debug_object.Procedure, size_of(debug_object.Procedure), header.procedure_count)
	fuzz_debug_object_region_add(regions, len(input), &at, debug_object.File, size_of(debug_object.File), header.file_count)
	fuzz_debug_object_region_add(regions, len(input), &at, debug_object.Line, size_of(debug_object.Line), header.line_count)
}

// fuzz_debug_object_region_add adds the records of one table that fit in
// the input, and moves the place to the next table.
fuzz_debug_object_region_add :: proc(list: ^[dynamic]Fuzz_Region, length: int, place: ^int, record_type: typeid, size: int, count: u32) {
	room := (length - place^) / size
	if room <= 0 {
		return
	}
	usable := min(int(count), room)
	if usable > 0 {
		append(list, Fuzz_Region{offset = place^, type = record_type, count = usable})
	}
	place^ += usable * size
}

// fuzz_debug_object_seeds gives objects that the generator builds with no
// broken field.
fuzz_debug_object_seeds :: proc(seeds: ^[dynamic][]u8) {
	for first in 0 ..< 8 {
		choices := [4]u8{u8(first), u8(3 * first), 1, u8(first)}
		object, _ := fuzz_debug_object_build(choices[:], allow_break = false, allocator = context.allocator)
		append(seeds, object)
	}
}

// fuzz_debug_object_build builds an object from choices by the rules of
// check: procedures in order with a name in the strings, the file 0 all
// zero and files with a path, rows in order with the last one on the file
// 0, the type 0 all zero. With allow_break, a rare choice writes one word
// of one record to a boundary value.
fuzz_debug_object_build :: proc(input: []u8, allow_break: bool, allocator := context.temp_allocator) -> (object: []u8, broke: bool) {
	choices := fuzz_choices_of(input)
	strings_bytes := make([dynamic]u8, context.temp_allocator)
	procedures := make([dynamic]debug_object.Procedure, context.temp_allocator)
	start: u32
	for _ in 0 ..< fuzz_choice_below(&choices, 6) {
		start += u32(fuzz_choice_below(&choices, 64))
		size := u32(1 + fuzz_choice_below(&choices, 256))
		procedure := debug_object.Procedure{start = start, size = size}
		if fuzz_choice_flag(&choices) {
			name_offset, name_count := fuzz_debug_object_text_add(&strings_bytes, "package::procedure")
			procedure.name_offset, procedure.name_count, procedure.package_count = name_offset, u16(name_count), 7
		} else {
			name_offset, name_count := fuzz_debug_object_text_add(&strings_bytes, "export")
			procedure.name_offset, procedure.name_count = name_offset, u16(name_count)
		}
		append(&procedures, procedure)
		start += size
	}
	files := make([dynamic]debug_object.File, context.temp_allocator)
	append(&files, debug_object.File{})
	for index in 0 ..< fuzz_choice_below(&choices, 4) {
		file: debug_object.File
		file.path_offset, file.path_count = fuzz_debug_object_text_add(&strings_bytes, index % 2 == 0 ? "src/a.odin" : "core/b.odin")
		fuzz_choice_fill(&choices, file.content_hash[:2])
		append(&files, file)
	}
	lines := make([dynamic]debug_object.Line, context.temp_allocator)
	offset: u32
	for _ in 0 ..< fuzz_choice_below(&choices, 8) {
		if len(files) < 2 {
			break
		}
		offset += u32(1 + fuzz_choice_below(&choices, 32))
		file := u32(1 + fuzz_choice_below(&choices, len(files) - 1))
		line := u32(1 + fuzz_choice_below(&choices, 1000))
		append(&lines, debug_object.Line{offset = offset, place = debug_object.row_place(file, line)})
	}
	if len(lines) > 0 {
		append(&lines, debug_object.Line{offset = offset + 1, place = debug_object.row_place(0, 0)})
	}
	types := [1]debug_object.Type{}
	parts := debug_object.Encode_Parts {
		procedures = procedures[:],
		files      = files[:],
		lines      = lines[:],
		types      = types[:],
		strings    = strings_bytes[:],
	}
	fuzz_choice_fill(&choices, parts.module_hash[:4])
	object = make([]u8, debug_object.encoded_size(parts), allocator)
	_ = debug_object.encode(parts, object)
	if allow_break && fuzz_choice_rare(&choices, 4) {
		// One word of 4 bytes after the magic and the version.
		words := (len(object) - 12) / 4
		if words > 0 {
			at := 12 + 4 * fuzz_choice_below(&choices, words)
			fuzz_word_write(object, at, 4, fuzz_boundary_value_of_choice(fuzz_choice_word(&choices, 8)), false)
			broke = true
		}
	}
	return object, broke
}

// fuzz_debug_object_text_add adds a text to the strings of an object.
fuzz_debug_object_text_add :: proc(table: ^[dynamic]u8, text: string) -> (offset, count: u32) {
	offset = u32(len(table^))
	append(table, ..transmute([]u8)text)
	return offset, u32(len(text))
}

// fuzz_debug_object_generated_execute: an object built by the rules must
// pass check, then each reader runs on it.
fuzz_debug_object_generated_execute :: proc(input: []u8) -> Fuzz_Verdict {
	object, broke := fuzz_debug_object_build(input, allow_break = true)
	if !broke {
		if fault := debug_object.check(object); fault != .None {
			return fuzz_broken(.Round_Trip, "check refuses an object that the generator built by its rules: %v", fault)
		}
	}
	return fuzz_debug_object_readers(object)
}
