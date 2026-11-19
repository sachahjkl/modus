package fuzz

import "base:intrinsics"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modustool:foundation"

// The fuzz targets of the module file (src/md/infrastructure/fuzzing.md,
// "The targets, in order of value"): a module comes from the network into
// the store `module_files`, and its package had no host test of its own. The
// invariant is the core of the flat tables: a file that `validate` accepts
// gives no read out of bounds through any reader, for any index.

// The indexes of each table that the target reads: the first ones and the
// one past the end.
FUZZ_MODULE_INDEX_LIMIT :: 64
// The largest memory of a module that the target copies, rebases and
// binds: a file of a few kilobytes can state any memory size.
FUZZ_MODULE_MEMORY_LIMIT :: 1 << 20
FUZZ_MODULE_BASE :: uintptr(0x4000_0000) // An address where the target says that the module runs.
FUZZ_MODULE_IMPORT_BASE :: uintptr(0x5000_0000) // The same for each module that it imports.

// fuzz_module_readers runs `validate`, then, on a file that it accepts,
// each reader of the package over each table.
fuzz_module_readers :: proc(file: []u8) -> Fuzz_Verdict {
	error := module.validate(file)
	if error > max(module.Error) {
		return fuzz_broken(.Contract, "validate gives a value out of its enumeration: %d", u32(error))
	}
	head, head_error := module.header(file)
	if head_error != .None && head_error != error {
		return fuzz_broken(.Two_Readers, "header and validate refuse the file for two reasons: %v and %v", head_error, error)
	}
	if error != .None {
		return FUZZ_PASSED
	}
	for kind in module.Table_Kind {
		count := min(module.count(file, kind), FUZZ_MODULE_INDEX_LIMIT)
		for index in 0 ..= count {
			switch kind {
			case .None, .Strings:
			case .Segments:
				_, _ = module.record(file, kind, index, module.Segment)
			case .Imports:
				_, _ = module.record(file, kind, index, module.Import)
			case .Slots:
				_, _ = module.record(file, kind, index, module.Slot)
			case .Exports:
				_, _ = module.record(file, kind, index, module.Export)
			case .Rebases:
				_, _ = module.record(file, kind, index, u64)
			case .Functions:
				_, _ = module.record(file, kind, index, module.Function)
			case .Documentation:
				_, _ = module.record(file, kind, index, module.Documentation)
			case .Records:
				_, _ = module.record(file, kind, index, module.Record)
			case .Fields:
				_, _ = module.record(file, kind, index, module.Field)
			case .Budget:
				_, _ = module.record(file, kind, index, module.Budget_Request)
			case .Facts:
				_, _ = module.record(file, kind, index, module.Fact)
			case .Own_Hash:
				_, _ = module.record(file, kind, index, module.Own_Hash_Place)
			}
		}
	}
	// The reader of the facts: a fact that it accepts names a record that
	// record_type accepts, with values that fit in one log record.
	facts := min(module.count(file, .Facts), FUZZ_MODULE_INDEX_LIMIT)
	for index in 0 ..= facts {
		fact, record, valid := module.fact(file, index)
		if !valid {
			continue
		}
		if fact.key == 0 || record.size > op.LOG_FACT_VALUE_CAPACITY {
			return fuzz_broken(.Contract, "fact accepts a fact with the key 0 or with values past the capacity: fact %d", index)
		}
		if _, found, _, found_ok := module.fact_find(file, fact.key); found_ok && found.key != fact.key {
			return fuzz_broken(.Contract, "fact_find gives a fact of another key: fact %d", index)
		}
		if fault := module.fact_template_valid(file, fact, record); fault > max(module.Fact_Template_Fault) {
			return fuzz_broken(.Contract, "fact_template_valid gives a value out of its enumeration: %d", u8(fault))
		}
	}
	exports := min(module.count(file, .Exports), FUZZ_MODULE_INDEX_LIMIT)
	for index in 0 ..= exports {
		_, _ = module.export_address(file, FUZZ_MODULE_BASE, index)
		function, has_function := module.function(file, index)
		if !has_function {
			continue
		}
		_, _ = module.error_details_parameter(file, function)
		_, _, _, _ = module.functions_compare(file, index, file, index)
		for parameter in 0 ..< min(int(function.parameter_count), module.PARAMETER_CAPACITY) {
			_ = module.string_at(file, function.parameter_names[parameter], u32(function.parameter_name_counts[parameter]))
		}
		name := module.string_at(file, function.name_offset, function.name_count)
		if len(name) == 0 {
			continue
		}
		found := module.export_find(file, name)
		other, other_found := module.function(file, found)
		if found == 0 || !other_found || module.string_at(file, other.name_offset, other.name_count) != name {
			return fuzz_broken(.Contract, "export_find does not find the name of an export: export %d, found %d", index, found)
		}
	}
	records := min(module.count(file, .Records), FUZZ_MODULE_INDEX_LIMIT)
	for index in 0 ..= records {
		record, valid := module.record_type(file, index)
		if !valid {
			continue
		}
		_ = module.record_has_handle(file, record)
		_ = module.record_alignment(file, record)
		if !module.records_equal(file, index, file, index) {
			return fuzz_broken(.Contract, "a record that record_type accepts does not equal itself: record %d", index)
		}
		bytes := make([]u8, record.size, context.temp_allocator)
		for number in 0 ..< record.field_count {
			item, has_field := module.field(file, record, number)
			if !has_field {
				return fuzz_broken(.Two_Readers, "record_type accepts a record whose field field does not read: record %d, field %d", index, number)
			}
			_ = module.field_integer(bytes, item)
			_ = module.field_text(bytes, item)
			// record_type took the kind of the field, so its border takes
			// it too, and the bytes of a hash stay inside the record.
			if _, kind_ok := module.field_kind(item); !kind_ok || !module.field_kind_valid(item) {
				return fuzz_broken(.Two_Readers, "record_type accepts a field whose kind its border refuses: record %d, field %d", index, number)
			}
			if hash := module.field_bytes(bytes, item); item.type == u8(module.Type.Bytes) && len(hash) != int(item.detail) {
				return fuzz_broken(.Contract, "the bytes of a hash field are not its size: record %d, field %d", index, number)
			}
			_ = module.field_integer_fits(item, -1)
			module.field_integer_set(bytes, item, -1)
		}
	}
	_, _ = module.documentation(file)
	_, _ = module.budget_request(file)
	if head.memory_size <= FUZZ_MODULE_MEMORY_LIMIT {
		memory := make([]u8, head.memory_size, context.temp_allocator)
		module.copy_segments(file, memory)
		if rebased := module.rebase(file, memory, FUZZ_MODULE_BASE); rebased > max(module.Error) {
			return fuzz_broken(.Contract, "rebase gives a value out of its enumeration: %d", u32(rebased))
		}
		imports := module.count(file, .Imports)
		bound := make([]module.Bound_Import, max(int(imports) - 1, 0), context.temp_allocator)
		for &item in bound {
			item = {file = file, base = FUZZ_MODULE_IMPORT_BASE}
		}
		load_error: module.Load_Error
		_ = module.bind(file, memory, bound, &load_error)
		// validate accepted the own-hash place: the write stays inside the
		// memory of the module.
		if !module.own_hash_write(file, memory, {}) {
			return fuzz_broken(.Two_Readers, "validate accepts an own-hash place that own_hash_write refuses")
		}
	}
	return FUZZ_PASSED
}

fuzz_module_file_execute :: proc(input: []u8) -> Fuzz_Verdict {
	return fuzz_module_readers(input)
}

// fuzz_module_record_type gives the type of the records of a table, or nil
// for a table of bytes.
fuzz_module_record_type :: proc(kind: module.Table_Kind) -> (type: typeid, size: int) {
	switch kind {
	case .None, .Strings:
		return nil, 0
	case .Segments:
		return module.Segment, size_of(module.Segment)
	case .Imports:
		return module.Import, size_of(module.Import)
	case .Slots:
		return module.Slot, size_of(module.Slot)
	case .Exports:
		return module.Export, size_of(module.Export)
	case .Rebases:
		return u64, size_of(u64)
	case .Functions:
		return module.Function, size_of(module.Function)
	case .Documentation:
		return module.Documentation, size_of(module.Documentation)
	case .Records:
		return module.Record, size_of(module.Record)
	case .Fields:
		return module.Field, size_of(module.Field)
	case .Budget:
		return module.Budget_Request, size_of(module.Budget_Request)
	case .Facts:
		return module.Fact, size_of(module.Fact)
	case .Own_Hash:
		return module.Own_Hash_Place, size_of(module.Own_Hash_Place)
	}
	return nil, 0
}

// fuzz_module_regions gives the header, the table directory and each table
// whose records have the size of their type, read from the bytes as they
// are: a broken header still gives the regions that its fields name.
fuzz_module_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	if len(input) < size_of(module.Header) {
		return
	}
	append(regions, Fuzz_Region{offset = 0, type = module.Header, count = 1})
	head: module.Header
	intrinsics.mem_copy_non_overlapping(&head, raw_data(input), size_of(module.Header))
	directory := int(min(u64(head.header_size), u64(len(input))))
	entries := min(int(head.table_count), module.TABLE_COUNT, (len(input) - directory) / size_of(module.Table_Entry))
	if entries <= 0 {
		return
	}
	append(regions, Fuzz_Region{offset = directory, type = module.Table_Entry, count = entries})
	for index in 0 ..< entries {
		entry: module.Table_Entry
		intrinsics.mem_copy_non_overlapping(&entry, &input[directory + index * size_of(module.Table_Entry)], size_of(module.Table_Entry))
		type, size := fuzz_module_record_type(foundation.enum_member_at(module.Table_Kind, index))
		if type == nil || int(entry.record_size) != size || entry.offset >= u64(len(input)) {
			continue
		}
		count := min(int(entry.count), (len(input) - int(entry.offset)) / size)
		if count > 0 {
			append(regions, Fuzz_Region{offset = int(entry.offset), type = type, count = count})
		}
	}
}

// fuzz_module_seeds gives modules that the generator builds with no broken
// field: a file that validate accepts, to start the raw target past its
// first checks.
fuzz_module_seeds :: proc(seeds: ^[dynamic][]u8) {
	for first in 0 ..< 8 {
		choices := [4]u8{u8(first), u8(first * 37), u8(first * 11), 0}
		file, _ := fuzz_module_build(choices[:], allow_break = false, allocator = context.allocator)
		append(seeds, file)
	}
}

// The writer of the generated target: tables in the order of their kinds,
// each record aligned on 8 bytes, then each segment on a page of the file.
Fuzz_Module_Writer :: struct {
	bytes: [dynamic]u8,
}

fuzz_module_append :: proc(writer: ^Fuzz_Module_Writer, value: ^$T) -> int {
	for len(writer.bytes) % 8 != 0 {
		append(&writer.bytes, 0)
	}
	at := len(writer.bytes)
	append(&writer.bytes, ..([^]u8)(value)[:size_of(T)])
	return at
}

// fuzz_module_build builds a module from choices by the rules of the
// format: one to three segments (code, data, read-only data), exports with
// their functions and names, one record with its fields, imports with
// their slots, rebase words, a documentation and a budget. With
// allow_break, a rare choice writes one field of one table to a boundary
// value: broke says so.
fuzz_module_build :: proc(input: []u8, allow_break: bool, allocator := context.temp_allocator) -> (file: []u8, broke: bool) {
	choices := fuzz_choices_of(input)
	segment_count := 1 + fuzz_choice_below(&choices, 3)
	export_count := fuzz_choice_below(&choices, 4)
	import_count := fuzz_choice_below(&choices, 3)
	rebase_count := fuzz_choice_below(&choices, 4)

	// The string table: byte 0 is zero, then the names.
	strings_bytes := make([dynamic]u8, context.temp_allocator)
	append(&strings_bytes, 0)

	segments := make([dynamic]module.Segment, context.temp_allocator)
	append(&segments, module.Segment{}) // Record 0: the empty record.
	memory_offset: u64
	data_segment := -1
	for index in 0 ..< segment_count {
		pages := u64(1 + fuzz_choice_below(&choices, 2))
		segment := module.Segment{memory_offset = memory_offset, memory_size = pages * module.PAGE_SIZE}
		switch index {
		case 0:
			segment.flags = {.Read, .Execute}
		case 1:
			segment.flags = {.Read, .Write}
			data_segment = len(segments)
		case:
			segment.flags = {.Read, .Read_Only_After_Load}
		}
		segment.file_size = u64(fuzz_choice_below(&choices, 64))
		append(&segments, segment)
		memory_offset += segment.memory_size
	}
	memory_size := memory_offset

	functions := make([dynamic]module.Function, context.temp_allocator)
	exports := make([dynamic]module.Export, context.temp_allocator)
	append(&functions, module.Function{})
	append(&exports, module.Export{})
	for _ in 0 ..< export_count {
		function: module.Function
		function.name_offset, function.name_count = fuzz_module_name_add(&strings_bytes, &choices, 'e')
		function.parameter_count = u8(fuzz_choice_below(&choices, 4))
		function.result = u8(module.Type.Integer)
		for parameter in 0 ..< int(function.parameter_count) {
			function.parameters[parameter] = u8(module.Type.Integer)
			name_offset, name_count := fuzz_module_name_add(&strings_bytes, &choices, 'p')
			function.parameter_names[parameter] = name_offset
			function.parameter_name_counts[parameter] = u8(name_count)
		}
		append(&functions, function)
		append(&exports, module.Export{code_offset = u64(fuzz_choice_below(&choices, module.PAGE_SIZE)), function = u32(len(functions) - 1)})
	}

	records := make([dynamic]module.Record, context.temp_allocator)
	fields := make([dynamic]module.Field, context.temp_allocator)
	append(&records, module.Record{})
	append(&fields, module.Field{})
	field_count := fuzz_choice_below(&choices, 4)
	record := module.Record{first_field = 1, field_count = u32(field_count), size = u32(8 * field_count)}
	record.name_offset, record.name_count = fuzz_module_name_add(&strings_bytes, &choices, 'R')
	for number in 0 ..< field_count {
		item := module.Field{offset = u32(8 * number), type = u8(module.Type.Integer), unsigned = fuzz_choice_flag(&choices)}
		item.name_offset, item.name_count = fuzz_module_name_add(&strings_bytes, &choices, 'f')
		append(&fields, item)
	}
	append(&records, record)

	imports := make([dynamic]module.Import, context.temp_allocator)
	slots := make([dynamic]module.Slot, context.temp_allocator)
	append(&imports, module.Import{})
	append(&slots, module.Slot{})
	rebases := make([dynamic]u64, context.temp_allocator)
	if data_segment >= 0 {
		data := segments[data_segment]
		for index in 0 ..< import_count {
			import_item: module.Import
			fuzz_choice_fill(&choices, import_item.hash[:4])
			append(&imports, import_item)
			// The imported module is the module itself in the target: its
			// export 1, when it has one.
			if export_count > 0 {
				append(&slots, module.Slot{memory_offset = data.memory_offset + 8 * u64(index), import_index = u32(len(imports) - 1), export_index = 1})
			}
		}
		for index in 0 ..< rebase_count {
			append(&rebases, data.memory_offset + 64 + 8 * u64(index))
		}
	}

	documentation := [2]module.Documentation{}
	documentation[1].about_offset, documentation[1].about_count = fuzz_module_name_add(&strings_bytes, &choices, 'd')
	budget := [2]module.Budget_Request{{}, {pages = u64(fuzz_choice_below(&choices, 64)), processes = 1, threads = 1}}

	// A rare broken field, chosen by the choices.
	broken_kind := module.Table_Kind.None
	broken_value: u64
	broken_field := 0
	if allow_break && fuzz_choice_rare(&choices, 4) {
		broken_kind = foundation.enum_member_at(module.Table_Kind, 1 + fuzz_choice_below(&choices, module.TABLE_COUNT - 1))
		broken_field = fuzz_choice_below(&choices, 8)
		broken_value = fuzz_choice_word(&choices, 8)
		broke = true
	}

	writer := Fuzz_Module_Writer{bytes = make([dynamic]u8, context.temp_allocator)}
	head := module.Header{magic = module.MAGIC, version = module.VERSION, machine = .X86_64, table_count = module.TABLE_COUNT, memory_size = memory_size, entry_export = export_count > 0 ? 1 : 0}
	head.header_size = size_of(module.Header)
	fuzz_module_append(&writer, &head)
	directory: [module.TABLE_COUNT]module.Table_Entry
	directory_at := fuzz_module_append(&writer, &directory)
	fuzz_module_table_write(&writer, &directory, .Segments, segments[:])
	fuzz_module_table_write(&writer, &directory, .Imports, imports[:])
	fuzz_module_table_write(&writer, &directory, .Slots, slots[:])
	fuzz_module_table_write(&writer, &directory, .Exports, exports[:])
	if len(rebases) > 0 {
		fuzz_module_table_write(&writer, &directory, .Rebases, rebases[:])
		// The rebase table has no record 0: each word is a location.
	}
	fuzz_module_table_write(&writer, &directory, .Functions, functions[:])
	fuzz_module_table_write(&writer, &directory, .Documentation, documentation[:])
	fuzz_module_table_write(&writer, &directory, .Records, records[:])
	fuzz_module_table_write(&writer, &directory, .Fields, fields[:])
	fuzz_module_table_write(&writer, &directory, .Budget, budget[:])
	strings_at := len(writer.bytes)
	append(&writer.bytes, ..strings_bytes[:])
	directory[int(module.Table_Kind.Strings)] = {offset = u64(strings_at), count = u32(len(strings_bytes)), record_size = 1}
	// The bytes of each segment, on a page of the file.
	for index in 1 ..< len(segments) {
		for len(writer.bytes) % module.PAGE_SIZE != 0 {
			append(&writer.bytes, 0)
		}
		segments[index].file_offset = u64(len(writer.bytes))
		for _ in 0 ..< segments[index].file_size {
			append(&writer.bytes, fuzz_choice_byte(&choices))
		}
		// The segment table already holds the record: write its file offset there.
		at := int(directory[int(module.Table_Kind.Segments)].offset) + index * size_of(module.Segment)
		intrinsics.mem_copy_non_overlapping(&writer.bytes[at], &segments[index], size_of(module.Segment))
	}
	intrinsics.mem_copy_non_overlapping(&writer.bytes[directory_at], &directory, size_of(directory))
	if broke {
		entry := directory[int(broken_kind)]
		if entry.count > 0 && entry.record_size >= 8 {
			// One word of 8 bytes of one record of the table.
			record_index := int(broken_value % u64(entry.count))
			at := int(entry.offset) + record_index * int(entry.record_size) + 8 * (broken_field % int(entry.record_size / 8))
			fuzz_word_write(writer.bytes[:], at, 8, fuzz_boundary_value_of_choice(broken_value), false)
		} else {
			// The table has words of one byte or no record: break its entry.
			fuzz_word_write(writer.bytes[:], directory_at + int(broken_kind) * size_of(module.Table_Entry) + 8 * (broken_field % 2), 8, fuzz_boundary_value_of_choice(broken_value), false)
		}
	}
	file = make([]u8, len(writer.bytes), allocator)
	copy(file, writer.bytes[:])
	return file, broke
}

// fuzz_module_name_add adds a name to the string table: a prefix, then up
// to five lowercase letters of the choices.
fuzz_module_name_add :: proc(table: ^[dynamic]u8, source: ^Fuzz_Choices, prefix: u8) -> (offset, count: u32) {
	offset = u32(len(table^))
	append(table, prefix)
	length := fuzz_choice_below(source, 6)
	for _ in 0 ..< length {
		append(table, 'a' + u8(fuzz_choice_below(source, 26)))
	}
	return offset, u32(len(table^)) - offset
}

// fuzz_module_table_write appends the records of one table, each aligned,
// and writes its entry of the directory.
fuzz_module_table_write :: proc(out: ^Fuzz_Module_Writer, entries: ^[module.TABLE_COUNT]module.Table_Entry, kind: module.Table_Kind, records: []$T) {
	if len(records) == 0 {
		return
	}
	first := -1
	for &item in records {
		at := fuzz_module_append(out, &item)
		if first < 0 {
			first = at
		}
	}
	entries[int(kind)] = {offset = u64(first), count = u32(len(records)), record_size = size_of(T)}
}

// fuzz_boundary_value_of_choice turns a choice into a value at an edge of
// a word: its low byte picks the kind of the edge, the rest the size.
fuzz_boundary_value_of_choice :: proc(choice: u64) -> u64 {
	random := Fuzz_Random{state = choice}
	return fuzz_boundary_value(&random, 1 << uint(choice % 4))
}

// fuzz_module_generated_execute builds a module from the choices: a module
// with no broken field must pass validate (the writer and the reader agree
// on the rules), then each reader runs on it.
fuzz_module_generated_execute :: proc(input: []u8) -> Fuzz_Verdict {
	file, broke := fuzz_module_build(input, allow_break = true)
	if !broke {
		if error := module.validate(file); error != .None {
			return fuzz_broken(.Round_Trip, "validate refuses a module that the generator built by the rules: %v", error)
		}
	}
	return fuzz_module_readers(file)
}
