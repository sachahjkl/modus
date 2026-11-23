// Language-neutral module manifest representation and strict parser
// (src/md/infrastructure/language_neutral_abi.md).
//
// Both this manifest parser (for C, Rust, Zig, assembly, or any freestanding
// toolchain) and Odin's AST extractor (describe_package) produce the same
// Module_Manifest intermediate structure, which feeds the shared ELF-to-module
// conversion pipeline.
package build

import "core:fmt"
import "core:strconv"
import "core:strings"
import module "modus:contract/module"
import "modus:contract/module_file_writer"
import op "modus:contract/operation"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"

// Module_Manifest is the language-neutral description of a module before ELF
// conversion: its identity, its library flag, its ordered import names, and
// its complete export, record, enum, and budget metadata.
Module_Manifest :: struct {
	name:        string,
	library:     bool,
	imports:     []string,
	description: Module_Description,
}

// manifest_from_odin_package builds a Module_Manifest from an Odin package
// folder through describe_package, using the exact same intermediate structure
// as manifest_parse.
manifest_from_odin_package :: proc(name: string, folder: string, imports: []string, library: bool) -> (manifest: Module_Manifest, ok: bool) {
	description := describe_package(folder) or_return
	return Module_Manifest {
		name        = name,
		library     = library,
		imports     = imports,
		description = description,
	}, true
}

@(private = "file")
Manifest_Block_Kind :: enum {
	Top,
	Enum,
	Record,
	Export,
}

@(private = "file")
Manifest_Top_Key :: enum {
	Module,
	About,
	Library,
	Imports,
	Budget,
}

@(private = "file")
MANIFEST_TOP_KEY_NAMES := [Manifest_Top_Key]string {
	.Module  = "module",
	.About   = "about",
	.Library = "library",
	.Imports = "imports",
	.Budget  = "budget",
}

@(private = "file")
Manifest_Budget_Part :: enum {
	Working_Memory_Pages,
	Processes,
	Threads,
	Window_Width,
	Window_Height,
	Wiring_Pages,
}

@(private = "file")
MANIFEST_BUDGET_PART_NAMES := [Manifest_Budget_Part]string {
	.Working_Memory_Pages = "working_memory_pages",
	.Processes            = "processes",
	.Threads              = "threads",
	.Window_Width         = "window_width",
	.Window_Height        = "window_height",
	.Wiring_Pages         = "wiring_pages",
}

@(private = "file")
MANIFEST_RIGHT_NAMES := [op.Right]string {
	.Give     = "give",
	.Read     = "read",
	.Write    = "write",
	.Execute  = "execute",
	.Control  = "control",
	.Inspect  = "inspect",
	.Devices  = "devices",
	.Stop     = "stop",
	.Spend    = "spend",
	.Physical = "physical",
	.Schedule = "schedule",
	.Commit   = "commit",
	.Events   = "events",
	.Debug    = "debug",
	.Counters = "counters",
}

@(private = "file")
Manifest_Direction_Name :: struct {
	name:      string,
	direction: module.Direction,
}

@(private = "file")
MANIFEST_DIRECTIONS := [?]Manifest_Direction_Name {
	{"read", .Read},
	{"change", .Change},
	{"append", .Append},
}

@(private = "file")
Manifest_Integer_Unit_Name :: struct {
	name:         string,
	integer_unit: value_kinds.Integer_Unit,
}

@(private = "file")
MANIFEST_INTEGER_UNITS := [?]Manifest_Integer_Unit_Name {
	{"size_bytes", value_kinds.size_in(.Bytes)},
	{"size_kib", value_kinds.size_in(.Kibibytes)},
	{"size_mib", value_kinds.size_in(.Mebibytes)},
	{"size_pages", value_kinds.size_in(.Pages)},
	{"size_blocks", value_kinds.size_in(.Blocks)},
	{"time_ns", value_kinds.time_in(.Nanoseconds)},
	{"time_us", value_kinds.time_in(.Microseconds)},
	{"time_ms", value_kinds.time_in(.Milliseconds)},
	{"time_s", value_kinds.time_in(.Seconds)},
}

@(private = "file")
Manifest_Enum_Builder :: struct {
	name:     string,
	size:     u8,
	unsigned: bool,
	line:     int,
	members:  [dynamic]Member_Description,
}

@(private = "file")
Manifest_Record_Builder :: struct {
	name:   string,
	size:   u32,
	line:   int,
	fields: [dynamic]Field_Description,
}

@(private = "file")
Manifest_Export_Builder :: struct {
	name:                string,
	about:               string,
	line:                int,
	has_about:           bool,
	has_result:          bool,
	has_error_record:    bool,
	parameters:          [dynamic]module.Type,
	parameter_names:     [dynamic]string,
	parameter_details:   [dynamic]u32,
	parameter_directions: [dynamic]module.Direction,
	optional_parameters: u16,
	getter_names:        [dynamic]string,
	result:              module.Type,
	result_detail:       u32,
	error_record:        u32,
}

// manifest_parse parses a strict plain-text language-neutral module manifest.
// problem is "" when the manifest is valid. Slices inside the returned
// Module_Manifest are allocated on context.temp_allocator.
manifest_parse :: proc(text: string) -> (manifest: Module_Manifest, problem: string) {
	top_seen: [Manifest_Top_Key]bool
	block := Manifest_Block_Kind.Top

	enum_builders := make([dynamic]Manifest_Enum_Builder, context.temp_allocator)
	record_builders := make([dynamic]Manifest_Record_Builder, context.temp_allocator)
	export_builders := make([dynamic]Manifest_Export_Builder, context.temp_allocator)

	rest := text
	line_number := 0
	for whole_line in strings.split_lines_iterator(&rest) {
		line_number += 1
		line := strings.trim_space(whole_line)
		if line == "" || strings.has_prefix(line, "#") {
			continue
		}

		// Block headers always start at the top level and switch the current block.
		if strings.has_prefix(line, "enum ") {
			builder, parse_problem := manifest_parse_enum_header(line_number, line, enum_builders[:])
			if parse_problem != "" {
				return {}, parse_problem
			}
			append(&enum_builders, builder)
			block = .Enum
			continue
		}
		if strings.has_prefix(line, "record ") {
			builder, parse_problem := manifest_parse_record_header(line_number, line, record_builders[:])
			if parse_problem != "" {
				return {}, parse_problem
			}
			append(&record_builders, builder)
			block = .Record
			continue
		}
		if strings.has_prefix(line, "export ") {
			builder, parse_problem := manifest_parse_export_header(line_number, line, export_builders[:])
			if parse_problem != "" {
				return {}, parse_problem
			}
			append(&export_builders, builder)
			block = .Export
			continue
		}

		switch block {
		case .Top:
			parse_problem := manifest_parse_top_line(line_number, line, &manifest, &top_seen)
			if parse_problem != "" {
				return {}, parse_problem
			}
		case .Enum:
			if !strings.has_prefix(line, "member ") {
				return {}, fmt.tprintf("line %d: expected `member <name> = <value>` inside enum %s", line_number, enum_builders[len(enum_builders) - 1].name)
			}
			parse_problem := manifest_parse_enum_member(line_number, line, &enum_builders[len(enum_builders) - 1])
			if parse_problem != "" {
				return {}, parse_problem
			}
		case .Record:
			if !strings.has_prefix(line, "field ") {
				return {}, fmt.tprintf("line %d: expected `field <name> offset=<N> type=<type>` inside record %s", line_number, record_builders[len(record_builders) - 1].name)
			}
			parse_problem := manifest_parse_record_field(line_number, line, &record_builders[len(record_builders) - 1])
			if parse_problem != "" {
				return {}, parse_problem
			}
		case .Export:
			parse_problem := manifest_parse_export_line(line_number, line, &export_builders[len(export_builders) - 1], record_builders[:], enum_builders[:])
			if parse_problem != "" {
				return {}, parse_problem
			}
		}
	}

	if !top_seen[.Module] {
		return {}, "the required key `module` is absent"
	}
	if !top_seen[.About] {
		return {}, "the required key `about` is absent"
	}

	// Finalize enums.
	enums := make([]Enum_Description, len(enum_builders), context.temp_allocator)
	for builder, index in enum_builders {
		if len(builder.members) == 0 {
			return {}, fmt.tprintf("line %d: enum %s has 0 members; an enum must have 1 to %d members", builder.line, builder.name, module.ENUM_MEMBER_CAPACITY)
		}
		enums[index] = Enum_Description {
			name     = builder.name,
			size     = builder.size,
			unsigned = builder.unsigned,
			members  = builder.members[:],
		}
	}

	// Finalize records.
	records := make([]Record_Description, len(record_builders), context.temp_allocator)
	for builder, index in record_builders {
		records[index] = Record_Description {
			name   = builder.name,
			size   = builder.size,
			fields = builder.fields[:],
		}
	}

	// Finalize exports and resolve enum getters.
	exports := make([]Export_Description, len(export_builders), context.temp_allocator)
	for builder, index in export_builders {
		if builder.name == ENTRY_NAME {
			if len(builder.parameters) != 0 || builder.result != .None || builder.error_record != 0 {
				return {}, fmt.tprintf("line %d: export %s takes no described parameter, result, or error record", builder.line, ENTRY_NAME)
			}
		} else if !builder.has_about {
			return {}, fmt.tprintf("line %d: export %s has no `about:` line", builder.line, builder.name)
		}
		// An export with an error record can fail: it gives the call outcome
		// in rax and its value in rdx, so its value is an integer, a count of
		// text or of rows, or nothing (src/md/api/call_outcome.md).
		if builder.error_record != 0 && builder.result == .Enum {
			return {}, fmt.tprintf("line %d: export %s has an error_record, so it can fail: the value of its pair is an integer, and its result cannot be an enum", builder.line, builder.name)
		}
		arguments := module.call_argument_count(len(builder.parameters), u8(builder.result), builder.error_record != 0)
		if arguments > module.PARAMETER_CAPACITY {
			return {}, fmt.tprintf("line %d: export %s takes %d call arguments; at most %d are allowed", builder.line, builder.name, arguments, module.PARAMETER_CAPACITY)
		}
		exports[index] = Export_Description {
			name                = builder.name,
			parameters          = builder.parameters[:],
			names               = builder.parameter_names[:],
			result              = builder.result,
			about               = builder.about,
			text                = builder.about,
			markdown            = builder.about,
			details             = builder.parameter_details[:],
			directions          = builder.parameter_directions[:],
			optional_parameters = builder.optional_parameters,
			getter_names        = builder.getter_names[:],
			result_detail       = builder.result_detail,
			error_record        = builder.error_record,
			line                = builder.line,
		}
	}

	// Resolve getter export indexes for enum parameters.
	for &export_item in exports {
		for getter_name, parameter_index in export_item.getter_names {
			if getter_name == "" {
				continue
			}
			getter_index := u32(0)
			for candidate, candidate_index in exports {
				if candidate.name == getter_name {
					getter_index = u32(candidate_index + 1)
					break
				}
			}
			if getter_index == 0 {
				return {}, fmt.tprintf("line %d: export %s: getter %s of parameter %s names no export", export_item.line, export_item.name, getter_name, export_item.names[parameter_index])
			}
			getter := exports[getter_index - 1]
			enum_index, _ := module.enum_detail_of(export_item.details[parameter_index])
			if len(getter.parameters) != 0 || getter.error_record != 0 || getter.result != .Enum {
				return {}, fmt.tprintf("line %d: export %s: getter %s must take no parameter, give no error record, and return an enum", export_item.line, export_item.name, getter_name)
			}
			if getter.result_detail != enum_index {
				return {}, fmt.tprintf("line %d: export %s: getter %s returns another enum than parameter %s takes", export_item.line, export_item.name, getter_name, export_item.names[parameter_index])
			}
			packed, packed_ok := module.enum_detail_make(enum_index, getter_index)
			if !packed_ok {
				return {}, fmt.tprintf("line %d: export %s: enum getter index overflows detail field", export_item.line, export_item.name)
			}
			export_item.details[parameter_index] = packed
		}
	}

	manifest.description.exports = exports
	manifest.description.records = records
	manifest.description.enums = enums
	manifest.description.text = manifest.description.about
	manifest.description.markdown = manifest.description.about
	return manifest, ""
}

@(private = "file")
manifest_parse_top_line :: proc(line_number: int, line: string, manifest: ^Module_Manifest, seen: ^[Manifest_Top_Key]bool) -> string {
	colon := strings.index_byte(line, ':')
	if colon <= 0 {
		return fmt.tprintf("line %d: expected `key: value`, `enum`, `record`, or `export`", line_number)
	}
	written_key := strings.trim_space(line[:colon])
	value := strings.trim_space(line[colon + 1:])
	key: Manifest_Top_Key
	known := false
	for candidate_name, candidate in MANIFEST_TOP_KEY_NAMES {
		if candidate_name == written_key {
			key, known = candidate, true
			break
		}
	}
	if !known {
		return fmt.tprintf("line %d: unknown top-level key `%s`", line_number, written_key)
	}
	if seen[key] {
		return fmt.tprintf("line %d: key `%s` is written twice", line_number, written_key)
	}
	seen[key] = true

	switch key {
	case .Module:
		if !module_name_is_valid(value) {
			return fmt.tprintf("line %d: `%s` is not a valid module name (lowercase ASCII letters, digits, `_`, 1 to %d bytes)", line_number, value, MODULE_NAME_BYTES_MOST)
		}
		manifest.name = value
	case .About:
		if value == "" || !text_encoding.text_valid(transmute([]u8)value) {
			return fmt.tprintf("line %d: `about` must be non-empty UTF-8 without control characters", line_number)
		}
		manifest.description.about = value
	case .Library:
		switch value {
		case "yes":
			manifest.library = true
		case "no":
			manifest.library = false
		case:
			return fmt.tprintf("line %d: `library` must be `yes` or `no`, not `%s`", line_number, value)
		}
	case .Imports:
		items := strings.fields(value, context.temp_allocator)
		for item, index in items {
			if !module_name_is_valid(item) {
				return fmt.tprintf("line %d: import `%s` is not a valid module name", line_number, item)
			}
			for earlier in items[:index] {
				if earlier == item {
					return fmt.tprintf("line %d: import `%s` is listed twice", line_number, item)
				}
			}
		}
		manifest.imports = items
	case .Budget:
		return manifest_parse_budget(line_number, value, &manifest.description.budget)
	}
	return ""
}

@(private = "file")
manifest_parse_budget :: proc(line_number: int, value: string, budget: ^Budget_Description) -> string {
	tokens := strings.fields(value, context.temp_allocator)
	if len(tokens) == 0 {
		return fmt.tprintf("line %d: `budget` requires at least one `part=<positive integer>` entry", line_number)
	}
	seen: [Manifest_Budget_Part]bool
	for token in tokens {
		equal := strings.index_byte(token, '=')
		if equal <= 0 || equal == len(token) - 1 {
			return fmt.tprintf("line %d: budget entry `%s` must have the form `part=<positive integer>`", line_number, token)
		}
		part_name := token[:equal]
		number_text := token[equal + 1:]
		part: Manifest_Budget_Part
		known := false
		for candidate_name, candidate in MANIFEST_BUDGET_PART_NAMES {
			if candidate_name == part_name {
				part, known = candidate, true
				break
			}
		}
		if !known {
			return fmt.tprintf("line %d: unknown budget part `%s`", line_number, part_name)
		}
		if seen[part] {
			return fmt.tprintf("line %d: budget part `%s` is written twice", line_number, part_name)
		}
		seen[part] = true
		parsed, parsed_ok := strconv.parse_u64(number_text)
		if !parsed_ok || parsed == 0 {
			return fmt.tprintf("line %d: budget part `%s` must be a positive integer, not `%s`", line_number, part_name, number_text)
		}
		switch part {
		case .Working_Memory_Pages:
			budget.parts.working_memory_pages = parsed
		case .Processes:
			budget.parts.processes = parsed
		case .Threads:
			budget.parts.threads = parsed
		case .Wiring_Pages:
			budget.parts.wiring_pages = parsed
		case .Window_Width:
			if parsed > BUDGET_WINDOW_PART_LIMIT {
				return fmt.tprintf("line %d: window_width %d exceeds the limit %d", line_number, parsed, BUDGET_WINDOW_PART_LIMIT)
			}
			budget.parts.window_width = parsed
		case .Window_Height:
			if parsed > BUDGET_WINDOW_PART_LIMIT {
				return fmt.tprintf("line %d: window_height %d exceeds the limit %d", line_number, parsed, BUDGET_WINDOW_PART_LIMIT)
			}
			budget.parts.window_height = parsed
		}
	}
	if seen[.Window_Width] != seen[.Window_Height] {
		return fmt.tprintf("line %d: window_width and window_height must be given together", line_number)
	}
	budget.stated = true
	budget.line = line_number
	return ""
}

@(private = "file")
manifest_parse_enum_header :: proc(line_number: int, line: string, existing: []Manifest_Enum_Builder) -> (builder: Manifest_Enum_Builder, problem: string) {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) != 3 {
		return {}, fmt.tprintf("line %d: expected `enum <Name> <u8|i8|u16|i16|u32|i32|u64|i64>`", line_number)
	}
	name := fields[1]
	if !module_file_writer.is_name(name) {
		return {}, fmt.tprintf("line %d: `%s` is not a valid enum name", line_number, name)
	}
	for other in existing {
		if other.name == name {
			return {}, fmt.tprintf("line %d: enum `%s` is declared twice", line_number, name)
		}
	}
	size, unsigned, backing_ok := manifest_parse_integer_backing(fields[2])
	if !backing_ok {
		return {}, fmt.tprintf("line %d: enum `%s` has unknown backing type `%s`", line_number, name, fields[2])
	}
	return Manifest_Enum_Builder {
		name     = name,
		size     = size,
		unsigned = unsigned,
		line     = line_number,
		members  = make([dynamic]Member_Description, context.temp_allocator),
	}, ""
}

@(private = "file")
manifest_parse_enum_member :: proc(line_number: int, line: string, builder: ^Manifest_Enum_Builder) -> string {
	if len(builder.members) >= module.ENUM_MEMBER_CAPACITY {
		return fmt.tprintf("line %d: enum %s exceeds the limit of %d members", line_number, builder.name, module.ENUM_MEMBER_CAPACITY)
	}
	body := strings.trim_space(line[len("member "):])
	equal := strings.index_byte(body, '=')
	if equal <= 0 || equal == len(body) - 1 {
		return fmt.tprintf("line %d: expected `member <name> = <integer>`", line_number)
	}
	member_name := strings.trim_space(body[:equal])
	value_text := strings.trim_space(body[equal + 1:])
	if !module.enum_member_name_valid(member_name) {
		return fmt.tprintf("line %d: enum %s: `%s` is not a valid lowercase member name", line_number, builder.name, member_name)
	}
	value: i64
	if builder.unsigned && builder.size == 8 {
		parsed, parsed_ok := strconv.parse_u64(value_text)
		if !parsed_ok {
			return fmt.tprintf("line %d: enum %s: `%s` is not a valid u64 member value", line_number, builder.name, value_text)
		}
		value = i64(parsed)
	} else {
		parsed, parsed_ok := strconv.parse_i64(value_text)
		if !parsed_ok {
			return fmt.tprintf("line %d: enum %s: `%s` is not a valid integer member value", line_number, builder.name, value_text)
		}
		value = parsed
	}
	if !module.enum_value_fits(builder.size, builder.unsigned, value) {
		return fmt.tprintf("line %d: enum %s: value %s does not fit backing size %d", line_number, builder.name, value_text, builder.size)
	}
	absent := module.enum_absent_word({size = builder.size, unsigned = builder.unsigned})
	if value == absent {
		return fmt.tprintf("line %d: enum %s: value %s is reserved as the absent word for optional parameters", line_number, builder.name, value_text)
	}
	for other in builder.members {
		if other.name == member_name {
			return fmt.tprintf("line %d: enum %s: member `%s` is declared twice", line_number, builder.name, member_name)
		}
		if other.value == value {
			return fmt.tprintf("line %d: enum %s: member value %s is used twice", line_number, builder.name, value_text)
		}
	}
	append(&builder.members, Member_Description{name = member_name, value = value})
	return ""
}

@(private = "file")
manifest_parse_record_header :: proc(line_number: int, line: string, existing: []Manifest_Record_Builder) -> (builder: Manifest_Record_Builder, problem: string) {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) != 3 || !strings.has_prefix(fields[2], "size=") {
		return {}, fmt.tprintf("line %d: expected `record <Name> size=<bytes>`", line_number)
	}
	name := fields[1]
	if !module_file_writer.is_name(name) {
		return {}, fmt.tprintf("line %d: `%s` is not a valid record name", line_number, name)
	}
	for other in existing {
		if other.name == name {
			return {}, fmt.tprintf("line %d: record `%s` is declared twice", line_number, name)
		}
	}
	size, size_ok := strconv.parse_u64(fields[2][len("size="):])
	if !size_ok || size > module.RECORD_SIZE_LIMIT {
		return {}, fmt.tprintf("line %d: record `%s` size must be 0 to %d bytes", line_number, name, module.RECORD_SIZE_LIMIT)
	}
	return Manifest_Record_Builder {
		name   = name,
		size   = u32(size),
		line   = line_number,
		fields = make([dynamic]Field_Description, context.temp_allocator),
	}, ""
}

@(private = "file")
manifest_parse_record_field :: proc(line_number: int, line: string, builder: ^Manifest_Record_Builder) -> string {
	parts := strings.fields(line, context.temp_allocator)
	if len(parts) != 4 || !strings.has_prefix(parts[2], "offset=") || !strings.has_prefix(parts[3], "type=") {
		return fmt.tprintf("line %d: expected `field <name> offset=<bytes> type=<type>`", line_number)
	}
	field_name := parts[1]
	if !module_file_writer.is_name(field_name) {
		return fmt.tprintf("line %d: record %s: `%s` is not a valid field name", line_number, builder.name, field_name)
	}
	for other in builder.fields {
		if other.name == field_name {
			return fmt.tprintf("line %d: record %s: field `%s` is declared twice", line_number, builder.name, field_name)
		}
	}
	offset, offset_ok := strconv.parse_u64(parts[2][len("offset="):])
	if !offset_ok || offset > u64(builder.size) {
		return fmt.tprintf("line %d: record %s: field `%s` offset is outside record size %d", line_number, builder.name, field_name, builder.size)
	}
	type_spec := parts[3][len("type="):]
	field, field_size, field_align, type_problem := manifest_parse_field_type(line_number, field_name, u32(offset), type_spec)
	if type_problem != "" {
		return type_problem
	}
	if field_align > 1 && offset % u64(field_align) != 0 {
		return fmt.tprintf("line %d: record %s: field `%s` at offset %d is not aligned to %d bytes", line_number, builder.name, field_name, offset, field_align)
	}
	if u64(field_size) > u64(builder.size) - offset {
		return fmt.tprintf("line %d: record %s: field `%s` (%d bytes at offset %d) exceeds record size %d", line_number, builder.name, field_name, field_size, offset, builder.size)
	}
	append(&builder.fields, field)
	return ""
}

@(private = "file")
manifest_parse_field_type :: proc(line_number: int, field_name: string, offset: u32, spec: string) -> (field: Field_Description, byte_size: u32, alignment: u32, problem: string) {
	field = Field_Description{name = field_name, offset = offset}

	if size, unsigned, is_int := manifest_parse_integer_backing(spec); is_int {
		field.type = .Integer
		field.unsigned = unsigned
		field.detail = size == 8 ? 0 : u32(size)
		return field, u32(size), u32(size), ""
	}
	switch spec {
	case "hex8":
		field.type, field.unsigned, field.detail, field.kind = .Integer, true, 1, .Hexadecimal
		return field, 1, 1, ""
	case "hex16":
		field.type, field.unsigned, field.detail, field.kind = .Integer, true, 2, .Hexadecimal
		return field, 2, 2, ""
	case "hex32":
		field.type, field.unsigned, field.detail, field.kind = .Integer, true, 4, .Hexadecimal
		return field, 4, 4, ""
	case "hex64":
		field.type, field.unsigned, field.detail, field.kind = .Integer, true, 0, .Hexadecimal
		return field, 8, 8, ""
	case "module_name":
		field.type, field.detail, field.kind = .Text, value_kinds.MODULE_NAME_FIELD_BYTES, .Module_Name
		return field, value_kinds.MODULE_NAME_FIELD_BYTES, 1, ""
	case "hash":
		field.type, field.detail, field.kind = .Bytes, value_kinds.HASH_FIELD_BYTES, .Hash
		return field, value_kinds.HASH_FIELD_BYTES, 1, ""
	}
	if unit, is_unit := manifest_parse_integer_unit(spec); is_unit {
		field.type = .Integer
		field.integer_unit = unit
		return field, 8, 8, ""
	}
	if inner, is_text := manifest_unwrap_call(spec, "text"); is_text {
		count, count_ok := strconv.parse_u64(inner)
		if !count_ok || count < 1 || count > module.RECORD_SIZE_LIMIT {
			return {}, 0, 0, fmt.tprintf("line %d: field `%s`: text size must be 1 to %d bytes", line_number, field_name, module.RECORD_SIZE_LIMIT)
		}
		field.type = .Text
		field.detail = u32(count)
		return field, u32(count), 1, ""
	}
	if inner, is_handle := manifest_unwrap_call(spec, "handle"); is_handle {
		rights, rights_problem := manifest_parse_rights(line_number, inner)
		if rights_problem != "" {
			return {}, 0, 0, rights_problem
		}
		field.type = .Handle
		field.detail = transmute(u32)rights
		return field, 4, 4, ""
	}
	return {}, 0, 0, fmt.tprintf("line %d: field `%s` has unknown type `%s`", line_number, field_name, spec)
}

@(private = "file")
manifest_parse_export_header :: proc(line_number: int, line: string, existing: []Manifest_Export_Builder) -> (builder: Manifest_Export_Builder, problem: string) {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) != 2 {
		return {}, fmt.tprintf("line %d: expected `export <name>`", line_number)
	}
	name := fields[1]
	if !module_file_writer.is_name(name) {
		return {}, fmt.tprintf("line %d: `%s` is not a valid export name", line_number, name)
	}
	for other in existing {
		if other.name == name {
			return {}, fmt.tprintf("line %d: export `%s` is declared twice", line_number, name)
		}
	}
	return Manifest_Export_Builder {
		name                 = name,
		line                 = line_number,
		parameters           = make([dynamic]module.Type, context.temp_allocator),
		parameter_names      = make([dynamic]string, context.temp_allocator),
		parameter_details    = make([dynamic]u32, context.temp_allocator),
		parameter_directions = make([dynamic]module.Direction, context.temp_allocator),
		getter_names         = make([dynamic]string, context.temp_allocator),
	}, ""
}

@(private = "file")
manifest_parse_export_line :: proc(line_number: int, line: string, builder: ^Manifest_Export_Builder, records: []Manifest_Record_Builder, enums: []Manifest_Enum_Builder) -> string {
	if strings.has_prefix(line, "about:") {
		if builder.has_about {
			return fmt.tprintf("line %d: export %s has two `about:` lines", line_number, builder.name)
		}
		value := strings.trim_space(line[len("about:"):])
		if value == "" || !text_encoding.text_valid(transmute([]u8)value) {
			return fmt.tprintf("line %d: export %s: `about` must be non-empty UTF-8 without control characters", line_number, builder.name)
		}
		builder.about = value
		builder.has_about = true
		return ""
	}
	if strings.has_prefix(line, "param ") {
		return manifest_parse_export_parameter(line_number, line, builder, records, enums)
	}
	if strings.has_prefix(line, "result:") {
		if builder.has_result {
			return fmt.tprintf("line %d: export %s has two `result:` lines", line_number, builder.name)
		}
		builder.has_result = true
		spec := strings.trim_space(line[len("result:"):])
		return manifest_parse_export_result(line_number, spec, builder, records, enums)
	}
	if strings.has_prefix(line, "error_record:") {
		if builder.has_error_record {
			return fmt.tprintf("line %d: export %s has two `error_record:` lines", line_number, builder.name)
		}
		builder.has_error_record = true
		record_name := strings.trim_space(line[len("error_record:"):])
		record_index, record_found := manifest_find_record(records, record_name)
		if !record_found {
			return fmt.tprintf("line %d: export %s: error_record `%s` names no declared record", line_number, builder.name, record_name)
		}
		if len(records[record_index - 1].fields) == 0 {
			return fmt.tprintf("line %d: export %s: error_record `%s` must have at least one field", line_number, builder.name, record_name)
		}
		builder.error_record = record_index
		return ""
	}
	return fmt.tprintf("line %d: unknown directive inside export %s: `%s`", line_number, builder.name, line)
}

@(private = "file")
manifest_parse_export_parameter :: proc(line_number: int, line: string, builder: ^Manifest_Export_Builder, records: []Manifest_Record_Builder, enums: []Manifest_Enum_Builder) -> string {
	body := strings.trim_space(line[len("param "):])
	colon := strings.index_byte(body, ':')
	if colon <= 0 || colon == len(body) - 1 {
		return fmt.tprintf("line %d: expected `param <name>: <type>`", line_number)
	}
	param_name := strings.trim_space(body[:colon])
	if !module_file_writer.is_name(param_name) {
		return fmt.tprintf("line %d: export %s: `%s` is not a valid parameter name", line_number, builder.name, param_name)
	}
	for other in builder.parameter_names {
		if other == param_name {
			return fmt.tprintf("line %d: export %s: parameter `%s` is declared twice", line_number, builder.name, param_name)
		}
	}
	if len(builder.parameters) >= module.PARAMETER_CAPACITY {
		return fmt.tprintf("line %d: export %s has more than %d parameters", line_number, builder.name, module.PARAMETER_CAPACITY)
	}

	// Split type expression (which may contain parenthesized arguments with spaces,
	// such as `table(Item, read)`) from trailing modifiers (`optional`, `getter=<name>`).
	rhs := strings.trim_space(body[colon + 1:])
	type_spec, modifiers_text := manifest_split_type_and_modifiers(rhs)

	param_type: module.Type
	param_detail: u32
	param_direction: module.Direction

	switch {
	case type_spec == "integer":
		param_type = .Integer
	case type_spec == "text":
		param_type = .Text
	case strings.has_prefix(type_spec, "integer("):
		inner, ok := manifest_unwrap_call(type_spec, "integer")
		if !ok {
			return fmt.tprintf("line %d: export %s: malformed integer unit type `%s`", line_number, builder.name, type_spec)
		}
		unit, unit_ok := manifest_parse_integer_unit(inner)
		if !unit_ok {
			return fmt.tprintf("line %d: export %s: unknown integer unit `%s`", line_number, builder.name, inner)
		}
		param_type = .Integer
		param_detail = value_kinds.integer_unit_detail(unit)
	case strings.has_prefix(type_spec, "record("):
		inner, ok := manifest_unwrap_call(type_spec, "record")
		if !ok {
			return fmt.tprintf("line %d: export %s: malformed record parameter type `%s`", line_number, builder.name, type_spec)
		}
		record_index, found := manifest_find_record(records, inner)
		if !found {
			return fmt.tprintf("line %d: export %s: parameter `%s` names undeclared record `%s`", line_number, builder.name, param_name, inner)
		}
		if len(records[record_index - 1].fields) == 0 {
			return fmt.tprintf("line %d: export %s: record `%s` must have at least one field", line_number, builder.name, inner)
		}
		param_type = .Record
		param_detail = record_index
	case strings.has_prefix(type_spec, "handle("):
		inner, ok := manifest_unwrap_call(type_spec, "handle")
		if !ok {
			return fmt.tprintf("line %d: export %s: malformed handle parameter type `%s`", line_number, builder.name, type_spec)
		}
		rights, rights_problem := manifest_parse_rights(line_number, inner)
		if rights_problem != "" {
			return rights_problem
		}
		param_type = .Handle
		param_detail = transmute(u32)rights
	case strings.has_prefix(type_spec, "table("):
		inner, ok := manifest_unwrap_call(type_spec, "table")
		if !ok {
			return fmt.tprintf("line %d: export %s: malformed table parameter type `%s`", line_number, builder.name, type_spec)
		}
		comma := strings.index_byte(inner, ',')
		if comma <= 0 || comma == len(inner) - 1 {
			return fmt.tprintf("line %d: export %s: expected `table(<Record>, read|change|append)`", line_number, builder.name)
		}
		record_name := strings.trim_space(inner[:comma])
		dir_name := strings.trim_space(inner[comma + 1:])
		record_index, found := manifest_find_record(records, record_name)
		if !found {
			return fmt.tprintf("line %d: export %s: table parameter `%s` names undeclared record `%s`", line_number, builder.name, param_name, record_name)
		}
		if len(records[record_index - 1].fields) == 0 {
			return fmt.tprintf("line %d: export %s: record `%s` must have at least one field", line_number, builder.name, record_name)
		}
		if manifest_record_has_handle(records[record_index - 1]) {
			return fmt.tprintf("line %d: export %s: table record `%s` cannot contain a handle field", line_number, builder.name, record_name)
		}
		direction, dir_ok := manifest_parse_direction(dir_name)
		if !dir_ok {
			return fmt.tprintf("line %d: export %s: unknown table direction `%s` (use read, change, or append)", line_number, builder.name, dir_name)
		}
		param_type = .Table
		param_detail = record_index
		param_direction = direction
	case strings.has_prefix(type_spec, "bytes("):
		inner, ok := manifest_unwrap_call(type_spec, "bytes")
		if !ok {
			return fmt.tprintf("line %d: export %s: malformed bytes parameter type `%s`", line_number, builder.name, type_spec)
		}
		direction, dir_ok := manifest_parse_direction(strings.trim_space(inner))
		if !dir_ok {
			return fmt.tprintf("line %d: export %s: unknown bytes direction `%s` (use read, change, or append)", line_number, builder.name, inner)
		}
		param_type = .Bytes
		param_direction = direction
	case strings.has_prefix(type_spec, "enum("):
		inner, ok := manifest_unwrap_call(type_spec, "enum")
		if !ok {
			return fmt.tprintf("line %d: export %s: malformed enum parameter type `%s`", line_number, builder.name, type_spec)
		}
		enum_index, found := manifest_find_enum(enums, inner)
		if !found {
			return fmt.tprintf("line %d: export %s: parameter `%s` names undeclared enum `%s`", line_number, builder.name, param_name, inner)
		}
		param_type = .Enum
		param_detail = enum_index
	case:
		return fmt.tprintf("line %d: export %s: unknown parameter type `%s`", line_number, builder.name, type_spec)
	}

	is_optional := false
	getter_name := ""
	for modifier in strings.fields(modifiers_text, context.temp_allocator) {
		switch {
		case modifier == "optional":
			if param_type != .Enum {
				return fmt.tprintf("line %d: export %s: `optional` is allowed on enum parameters only", line_number, builder.name)
			}
			if is_optional {
				return fmt.tprintf("line %d: export %s: `optional` is written twice on parameter `%s`", line_number, builder.name, param_name)
			}
			is_optional = true
		case strings.has_prefix(modifier, "getter="):
			if param_type != .Enum {
				return fmt.tprintf("line %d: export %s: `getter=` is allowed on enum parameters only", line_number, builder.name)
			}
			if getter_name != "" {
				return fmt.tprintf("line %d: export %s: `getter=` is written twice on parameter `%s`", line_number, builder.name, param_name)
			}
			getter_name = modifier[len("getter="):]
			if !module_file_writer.is_name(getter_name) {
				return fmt.tprintf("line %d: export %s: getter `%s` is not a valid export name", line_number, builder.name, getter_name)
			}
		case:
			return fmt.tprintf("line %d: export %s: unknown parameter modifier `%s`", line_number, builder.name, modifier)
		}
	}

	param_index := len(builder.parameters)
	append(&builder.parameters, param_type)
	append(&builder.parameter_names, param_name)
	append(&builder.parameter_details, param_detail)
	append(&builder.parameter_directions, param_direction)
	append(&builder.getter_names, getter_name)
	if is_optional {
		builder.optional_parameters |= u16(1) << uint(param_index)
	}
	return ""
}

@(private = "file")
manifest_parse_export_result :: proc(line_number: int, spec: string, builder: ^Manifest_Export_Builder, records: []Manifest_Record_Builder, enums: []Manifest_Enum_Builder) -> string {
	switch {
	case spec == "none":
		builder.result = .None
		return ""
	case spec == "integer":
		builder.result = .Integer
		return ""
	case spec == "text":
		builder.result = .Text
		return ""
	case strings.has_prefix(spec, "record("):
		inner, ok := manifest_unwrap_call(spec, "record")
		if !ok {
			return fmt.tprintf("line %d: export %s: malformed record result type `%s`", line_number, builder.name, spec)
		}
		record_index, found := manifest_find_record(records, inner)
		if !found {
			return fmt.tprintf("line %d: export %s: result names undeclared record `%s`", line_number, builder.name, inner)
		}
		if len(records[record_index - 1].fields) == 0 {
			return fmt.tprintf("line %d: export %s: result record `%s` must have at least one field", line_number, builder.name, inner)
		}
		if manifest_record_has_handle(records[record_index - 1]) {
			return fmt.tprintf("line %d: export %s: result record `%s` cannot contain a handle field", line_number, builder.name, inner)
		}
		builder.result = .Record
		builder.result_detail = record_index
		return ""
	case strings.has_prefix(spec, "table("):
		inner, ok := manifest_unwrap_call(spec, "table")
		if !ok {
			return fmt.tprintf("line %d: export %s: malformed table result type `%s`", line_number, builder.name, spec)
		}
		record_index, found := manifest_find_record(records, inner)
		if !found {
			return fmt.tprintf("line %d: export %s: table result names undeclared record `%s`", line_number, builder.name, inner)
		}
		if len(records[record_index - 1].fields) == 0 {
			return fmt.tprintf("line %d: export %s: table result record `%s` must have at least one field", line_number, builder.name, inner)
		}
		if manifest_record_has_handle(records[record_index - 1]) {
			return fmt.tprintf("line %d: export %s: table result record `%s` cannot contain a handle field", line_number, builder.name, inner)
		}
		builder.result = .Table
		builder.result_detail = record_index
		return ""
	case strings.has_prefix(spec, "enum("):
		inner, ok := manifest_unwrap_call(spec, "enum")
		if !ok {
			return fmt.tprintf("line %d: export %s: malformed enum result type `%s`", line_number, builder.name, spec)
		}
		enum_index, found := manifest_find_enum(enums, inner)
		if !found {
			return fmt.tprintf("line %d: export %s: result names undeclared enum `%s`", line_number, builder.name, inner)
		}
		builder.result = .Enum
		builder.result_detail = enum_index
		return ""
	}
	return fmt.tprintf("line %d: export %s: unknown result type `%s`", line_number, builder.name, spec)
}

@(private = "file")
manifest_split_type_and_modifiers :: proc(text: string) -> (type_spec: string, modifiers: string) {
	depth := 0
	for index in 0 ..< len(text) {
		switch text[index] {
		case '(':
			depth += 1
		case ')':
			if depth > 0 {
				depth -= 1
			}
		case ' ', '\t':
			if depth == 0 {
				return text[:index], strings.trim_space(text[index + 1:])
			}
		}
	}
	return text, ""
}

@(private = "file")
manifest_unwrap_call :: proc(text: string, prefix: string) -> (inner: string, ok: bool) {
	if !strings.has_prefix(text, prefix) || len(text) <= len(prefix) + 1 {
		return "", false
	}
	if text[len(prefix)] != '(' || text[len(text) - 1] != ')' {
		return "", false
	}
	return strings.trim_space(text[len(prefix) + 1:len(text) - 1]), true
}

@(private = "file")
manifest_parse_integer_backing :: proc(name: string) -> (size: u8, unsigned: bool, ok: bool) {
	switch name {
	case "i8":
		return 1, false, true
	case "u8":
		return 1, true, true
	case "i16":
		return 2, false, true
	case "u16":
		return 2, true, true
	case "i32":
		return 4, false, true
	case "u32":
		return 4, true, true
	case "i64":
		return 8, false, true
	case "u64":
		return 8, true, true
	}
	return 0, false, false
}

@(private = "file")
manifest_parse_integer_unit :: proc(name: string) -> (unit: value_kinds.Integer_Unit, ok: bool) {
	for item in MANIFEST_INTEGER_UNITS {
		if item.name == name {
			return item.integer_unit, true
		}
	}
	return {}, false
}

@(private = "file")
manifest_parse_direction :: proc(name: string) -> (direction: module.Direction, ok: bool) {
	for item in MANIFEST_DIRECTIONS {
		if item.name == name {
			return item.direction, true
		}
	}
	return {}, false
}

@(private = "file")
manifest_parse_rights :: proc(line_number: int, text: string) -> (rights: op.Rights, problem: string) {
	if text == "" || text == "none" {
		return {}, ""
	}
	rest := text
	for raw_item in strings.split_iterator(&rest, ",") {
		item := strings.trim_space(raw_item)
		matched := false
		for right_name, right in MANIFEST_RIGHT_NAMES {
			if right_name == item {
				if right in rights {
					return {}, fmt.tprintf("line %d: handle right `%s` is listed twice", line_number, item)
				}
				rights += {right}
				matched = true
				break
			}
		}
		if !matched {
			return {}, fmt.tprintf("line %d: unknown handle right `%s`", line_number, item)
		}
	}
	return rights, ""
}

@(private = "file")
manifest_find_record :: proc(records: []Manifest_Record_Builder, name: string) -> (index: u32, found: bool) {
	for item, position in records {
		if item.name == name {
			return u32(position + 1), true
		}
	}
	return 0, false
}

@(private = "file")
manifest_find_enum :: proc(enums: []Manifest_Enum_Builder, name: string) -> (index: u32, found: bool) {
	for item, position in enums {
		if item.name == name {
			return u32(position + 1), true
		}
	}
	return 0, false
}

@(private = "file")
manifest_record_has_handle :: proc(record: Manifest_Record_Builder) -> bool {
	for field in record.fields {
		if field.type == .Handle {
			return true
		}
	}
	return false
}
