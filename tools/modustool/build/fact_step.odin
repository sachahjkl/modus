package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:private/console/console_condition"
import "modus:support/sentence"
import "core:fmt"
import "core:strconv"
import "core:strings"

// The step of a machine test that waits for a log fact by its fact type,
// its process and a condition on one of its fields, not by its sentence
// (src/md/features/log_facts.md, "The machine tests"). The tool checks
// each such step against the fact tables of the module files of the build
// before the machine starts, so a renamed fact type or field fails at once
// with its cause, not at the end of a bound. The condition has the form of
// the condition of `where` in the console, and the same package reads and
// checks it (modus:private/console/console_condition): one form, one set
// of refusals, one sentence for each.

// Why a step of a fact is refused before the run.
Fact_Step_Fault :: enum u8 {
	None,
	No_Process,           // The step names no process: each process that compiles a package in writes its fact types.
	Not_A_Fact_Name,      // The fact is not a package name, a dot and a record name.
	Unknown_Fact_Type,    // No module of the build writes a fact type of the name.
	Condition_Refused,    // The condition names no field of the fact type, an operator that the field does not take, or a value of another kind or out of its range: the refusal of console_condition says which.
	Unreadable_Value,     // The value is neither an Integer nor a Text in quotes.
	Text_After_The_Value, // Text after the value: a step has one condition.
}

// One fact type of the build: a row of the table Facts of one module file.
Fact_Catalog_Type :: struct {
	module_tag:  [FACT_LINE_MODULE_TAG_BYTES]u8,
	file:        []u8,
	key:         u64,
	description: module.Record,
	name:        string, // "package.Type", in the temporary memory.
}

// One fact type that a step names, in one module, with the field of its
// condition.
Fact_Step_Type :: struct {
	module_tag:  [FACT_LINE_MODULE_TAG_BYTES]u8,
	key:         u64,
	file:        []u8,
	description: module.Record,
	field:       module.Field, // The field of the condition; zero for a step with no condition.
}

// A step of a fact, checked against the fact tables: the line of a fact
// matches it when its process is the process of the step, its module and
// its key are one of the types, and its values pass the condition.
Fact_Step :: struct {
	fact:          string,
	process:       string,
	types:         []Fact_Step_Type, // In the temporary memory. A fact type of a support package is in each module that compiles it in.
	has_condition: bool,
	condition:     console_condition.Condition,
}

// fact_catalog_types gives each fact type of each module file of a
// catalog that the checks of the module format take. It reads each module
// file of the catalog that it did not read yet.
fact_catalog_types :: proc(catalog: ^Fact_Catalog) -> []Fact_Catalog_Type {
	types := make([dynamic]Fact_Catalog_Type, context.temp_allocator)
	for index in 0 ..< len(catalog.modules) {
		prefix := module_tag_of(catalog.modules[index].hash)
		file := fact_catalog_file(catalog, prefix)
		if file == nil || module.count(file, .Facts) <= 1 {
			continue
		}
		for row_index in 1 ..< module.count(file, .Facts) {
			row, description, row_ok := module.fact(file, row_index)
			if !row_ok {
				continue
			}
			package_name := module.string_at(file, row.package_offset, row.package_count)
			type_name := module.string_at(file, description.name_offset, description.name_count)
			name := strings.concatenate({package_name, ".", type_name}, context.temp_allocator)
			append(&types, Fact_Catalog_Type{module_tag = prefix, file = file, key = row.key, description = description, name = name})
		}
	}
	return types[:]
}

// fact_types_of_name gives the fact type of a name ("interface.Element_Placed")
// in each module of the catalog that writes it, in the temporary memory: a
// fact type of a support package is in each module that compiles it in and
// reaches its call.
fact_types_of_name :: proc(known: []Fact_Catalog_Type, name: string) -> []Fact_Step_Type {
	types := make([dynamic]Fact_Step_Type, context.temp_allocator)
	for item in known {
		if item.name == name {
			append(&types, Fact_Step_Type{module_tag = item.module_tag, key = item.key, file = item.file, description = item.description})
		}
	}
	return types[:]
}

// fact_line_of_types gives the type of a line of a fact among types, and
// the bytes of its record: the values of the line, whose bytes after
// value_count are zero (op.log_fact_line). ok is false for a line of
// another fact type, and for a line with more value bytes than its record.
// values holds a copy, so a reader keeps a Text field after the line. The
// line names the key by its tag, which one fact type of a module has
// (facts_merge).
fact_line_of_types :: proc(types: []Fact_Step_Type, line: Fact_Line) -> (type: Fact_Step_Type, values: []u8, ok: bool) {
	for entry in types {
		if entry.module_tag != line.module_tag || op.log_fact_key_tag(entry.key) != line.key_tag {
			continue
		}
		size := int(entry.description.size)
		if line.value_count > size || size > op.LOG_FACT_VALUE_CAPACITY {
			return {}, nil, false
		}
		// A parameter cannot be sliced: its bytes are copied first.
		line_values := line.values
		values = make([]u8, size, context.temp_allocator)
		copy(values, line_values[:size])
		return entry, values, true
	}
	return {}, nil, false
}

// fact_field_value gives the value of the field of a name of a record of a
// fact type: a Text or an Integer. ok is false for a name that the record
// does not have, and for a field with no such value.
fact_field_value :: proc(type: Fact_Step_Type, values: []u8, name: string) -> (value: console_condition.Field_Value, ok: bool) {
	item := console_condition.field_find(type.file, type.description, name) or_return
	return console_condition.field_value_of(values, item)
}

// fact_name_parts gives the package name and the record name of a fact
// name: the parts before and after its one dot, neither empty.
fact_name_parts :: proc(name: string) -> (package_name, type_name: string, ok: bool) {
	dot := strings.index_byte(name, '.')
	if dot <= 0 || dot == len(name) - 1 || strings.index_byte(name[dot + 1:], '.') >= 0 {
		return "", "", false
	}
	return name[:dot], name[dot + 1:], true
}

// fact_step_check checks a step of a fact against the fact tables of a
// catalog, and gives what the step matches. fault is None, or the cause of
// the refusal, with the refusal of the condition for Condition_Refused and
// the sentence of each fault in problem.
fact_step_check :: proc(catalog: ^Fact_Catalog, fact_name, process, condition_text: string) -> (step: Fact_Step, fault: Fact_Step_Fault, refusal: console_condition.Refusal, problem: string) {
	step.fact, step.process = fact_name, process
	if process == "" {
		return step, .No_Process, .None, fmt.tprintf("the step of the fact %s names no process: each process that compiles its package in writes it", fact_name)
	}
	package_name, _, named := fact_name_parts(fact_name)
	if !named {
		return step, .Not_A_Fact_Name, .None, fmt.tprintf("\"%s\" is not the name of a fact type: a package name, a dot and a record name, as storage.Bad_Block", fact_name)
	}
	known := fact_catalog_types(catalog)
	types := fact_types_of_name(known, fact_name)
	if len(types) == 0 {
		return step, .Unknown_Fact_Type, .None, fact_name_unknown_sentence(known, fact_name, package_name)
	}
	step.types = types
	if condition_text == "" {
		return step, .None, .None, ""
	}
	head, head_refusal := console_condition.head_read(condition_text, 0)
	details := console_condition.Refusal_Details {
		command    = "where",
		file       = types[0].file,
		record     = types[0].description,
		field      = head.field,
		comparison = head.comparison,
	}
	if head_refusal != .None {
		return step, .Condition_Refused, head_refusal, fact_step_refusal_sentence(head_refusal, details)
	}
	step.has_condition = true
	step.condition = {field = head.field, comparison = head.comparison}
	// Each module that writes the fact type has its own description: the
	// condition holds for each, so no line of one of them is read with the
	// field of another.
	for &entry in step.types {
		item, found := console_condition.field_find(entry.file, entry.description, head.field)
		details.file, details.record, details.item = entry.file, entry.description, item
		if !found {
			return step, .Condition_Refused, .Unknown_Field, fact_step_refusal_sentence(.Unknown_Field, details)
		}
		if field_refusal := console_condition.field_check(item, head.comparison); field_refusal != .None {
			return step, .Condition_Refused, field_refusal, fact_step_refusal_sentence(field_refusal, details)
		}
		entry.field = item
		value_end: int
		if which, status := console_condition.field_is_status(item); status {
			word, member, member_end, member_refusal := console_condition.member_read(condition_text, head.value_start, which)
			details.member = member
			if member_refusal != .None {
				return step, .Condition_Refused, member_refusal, fact_step_refusal_sentence(member_refusal, details)
			}
			step.condition.compared = i64(word)
			value_end = member_end
		} else {
			kind, integer, quoted, read_end, readable := fact_step_value_read(condition_text, head.value_start)
			if !readable {
				return step, .Unreadable_Value, .None, fmt.tprintf("the value of the condition \"%s\" is neither an Integer nor a Text in quotes", condition_text)
			}
			details.value_type = kind
			if value_refusal := console_condition.value_check(item, kind, integer); value_refusal != .None {
				return step, .Condition_Refused, value_refusal, fact_step_refusal_sentence(value_refusal, details)
			}
			step.condition.compared, step.condition.text = integer, quoted
			value_end = read_end
		}
		if strings.trim_space(condition_text[value_end:]) != "" {
			return step, .Text_After_The_Value, .None, fmt.tprintf("the condition \"%s\" has text after its value: a step of a fact has one condition", condition_text)
		}
	}
	return step, .None, .None, ""
}

// fact_step_value_read reads the value of a condition on a field that is
// no status, at a byte place: an Integer, with its sign and a prefix of
// base (0x), or a Text in quotes. end is the byte after it.
fact_step_value_read :: proc(text: string, place: int) -> (kind: module.Type, integer: i64, quoted: string, end: int, readable: bool) {
	start := clamp(place, 0, len(text))
	for start < len(text) && text[start] == ' ' {
		start += 1
	}
	rest := text[start:]
	if len(rest) == 0 {
		return .None, 0, "", start, false
	}
	if rest[0] == '"' {
		closing := strings.index_byte(rest[1:], '"')
		if closing < 0 {
			return .None, 0, "", start, false
		}
		return .Text, 0, rest[1:][:closing], start + 2 + closing, true
	}
	length := strings.index_byte(rest, ' ')
	if length < 0 {
		length = len(rest)
	}
	parsed, parsed_ok := strconv.parse_i64(rest[:length])
	if !parsed_ok {
		return .None, 0, "", start, false
	}
	return .Integer, parsed, "", start + length, true
}

// fact_step_refusal_sentence gives the sentence of a refusal of a
// condition, the sentence of the console for the same condition.
fact_step_refusal_sentence :: proc(refusal: console_condition.Refusal, details: console_condition.Refusal_Details) -> string {
	buffer := make([]u8, 512, context.temp_allocator)
	writer := sentence.Writer {
		buffer = buffer,
	}
	console_condition.refusal_write(&writer, refusal, details)
	return sentence.written(&writer)
}

// fact_name_unknown_sentence gives the sentence of a fact name that no
// fact table holds, with the close names: those of the same package, or
// each name when the package has none.
fact_name_unknown_sentence :: proc(known: []Fact_Catalog_Type, name, package_name: string) -> string {
	add_once :: proc(names: ^[dynamic]string, name: string) {
		for existing in names {
			if existing == name {
				return
			}
		}
		append(names, name)
	}
	same_package := make([dynamic]string, context.temp_allocator)
	every := make([dynamic]string, context.temp_allocator)
	for item in known {
		add_once(&every, item.name)
		known_package, _, _ := fact_name_parts(item.name)
		if known_package == package_name {
			add_once(&same_package, item.name)
		}
	}
	switch {
	case len(every) == 0:
		return fmt.tprintf("no module of the build writes a fact type: %s names nothing", name)
	case len(same_package) > 0:
		return fmt.tprintf("no fact type has the name %s; the fact types of %s are %s", name, package_name, strings.join(same_package[:], ", ", context.temp_allocator))
	}
	return fmt.tprintf("no fact type has the name %s; the fact types are %s", name, strings.join(every[:], ", ", context.temp_allocator))
}

// fact_step_matches says if the line of a fact matches a checked step: its
// process, a module and a key tag of the fact type, no more value bytes than
// its record, and values that pass the condition. The bytes after the
// values of the line are zero (op.log_fact_line).
fact_step_matches :: proc(step: Fact_Step, place: Fact_Line_Place) -> bool {
	if place.process != step.process {
		return false
	}
	for entry in step.types {
		if entry.module_tag != place.line.module_tag || op.log_fact_key_tag(entry.key) != place.line.key_tag {
			continue
		}
		size := int(entry.description.size)
		if place.line.value_count > size {
			return false
		}
		if !step.has_condition {
			return true
		}
		values := place.line.values
		value, has_value := console_condition.field_value_of(values[:size], entry.field)
		return has_value && console_condition.condition_holds(value, step.condition)
	}
	return false
}
