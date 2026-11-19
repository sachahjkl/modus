package module

import op "modus:contract/operation"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"

// The log facts of a module, and its own-hash place
// (src/md/features/log_facts.md, "The fact table of the module file").
//
// A log fact is a record of the source whose values a log record carries
// with no text: the module file describes its record type in the table
// Records, and gives its fact template, the sentence that a reader writes
// with the values. A fact record of the log names its module by hash, and a
// module file cannot hold its own hash, so a loader writes it at the
// own-hash place of the module, in its writable data. A file is hostile
// input: each reader below checks what it reads.

// One row of the table Facts: one fact type that the module writes. The
// rows are sorted by key, and no two rows have one key.
//
// Example: the fact type `storage.Bad_Block` is the key 18017458693634389201,
// the record "Bad_Block", the template "storage: the block {block} has a
// wrong check {check}, expected {expected}" and the package name "storage".
Fact :: struct {
	key:             u64, // The fact key: the typeid of the record type, SipHash-2-4 of "<package>::<type>". Never 0.
	record:          u32, // The index of the description of the record type in the table Records, from 1.
	template_offset: u32, // The fact template, in the string table.
	template_count:  u32, // Its bytes: 1 to FACT_TEMPLATE_BYTES_MOST.
	package_offset:  u32, // The name of the package that declares the record type, in the string table.
	package_count:   u32, // Its bytes: at least 1.
	reserved:        u32, // 0.
}
#assert(size_of(Fact) == 32)

// The bytes of a fact template, at most.
FACT_TEMPLATE_BYTES_MOST :: 256

// The fields of the record of a fact, at most: record_type refuses a record
// with more fields, so the check of a template holds one mark for each.
FACT_FIELD_CAPACITY :: RECORD_SIZE_LIMIT / 4

// Record 1 of the table Own_Hash: the place of HASH_SIZE bytes in the
// writable data of the module where each loader writes the hash of the
// module file. A file with no such record has no place: it writes no fact.
Own_Hash_Place :: struct {
	memory_offset: u64, // From the base of the module: HASH_SIZE bytes inside one segment with Write and no Execute.
}
#assert(size_of(Own_Hash_Place) == 8)

// The name of the symbol of the own-hash place in the linked file: the
// build finds the place by it, and the support package `system` declares
// its variable with it.
OWN_HASH_PLACE_SYMBOL :: "modus_own_hash"

// own_hash_place gives the memory offset of the own-hash place. present is
// false for a file with no place. validate checks the place.
own_hash_place :: proc "contextless" (file: []u8) -> (memory_offset: u64, present: bool) {
	place := record(file, .Own_Hash, 1, Own_Hash_Place) or_return
	return place.memory_offset, true
}

// own_hash_write writes hash at the own-hash place of a module, in the
// memory of a module that a loader prepares, when the place is between the
// offsets first and end: a loader that writes one segment at a time calls
// it for each one, as it rebases and binds. A file with no place gives
// true and writes nothing. false: the place is not in writable data, or is
// outside memory; the module must not run. Call validate first.
own_hash_write :: proc "contextless" (file: []u8, memory: []u8, hash: [HASH_SIZE]u8, first: u64 = 0, end: u64 = max(u64)) -> bool {
	place, present := own_hash_place(file)
	if !present {
		return true
	}
	if !writable_range(file, place, HASH_SIZE) {
		return false
	}
	if place < first || place >= end {
		return true
	}
	if !range_holds(0, u64(len(memory)), place, HASH_SIZE) {
		return false
	}
	own := hash
	copy(memory[place:][:HASH_SIZE], own[:])
	return true
}

// fact gives row index of the table Facts, and the description of its
// record, after it checked them: the key is not 0, the record is valid and
// its values fit in one log record (op.LOG_FACT_VALUE_CAPACITY), the
// template and the package name are inside the string table, the template
// has at most FACT_TEMPLATE_BYTES_MOST bytes. It does not check the
// language of the template: fact_template_valid does.
fact :: proc "contextless" (file: []u8, index: u32) -> (value: Fact, description: Record, ok: bool) {
	if index == 0 {
		return {}, {}, false
	}
	value = record(file, .Facts, index, Fact) or_return
	if value.key == 0 || value.reserved != 0 {
		return {}, {}, false
	}
	description = record_type(file, value.record) or_return
	if description.size > op.LOG_FACT_VALUE_CAPACITY {
		return {}, {}, false
	}
	strings_entry := table(file, .Strings)
	inside :: proc "contextless" (strings_count, offset, count: u32) -> bool {
		return offset <= strings_count && count <= strings_count - offset
	}
	if value.template_count == 0 || value.template_count > FACT_TEMPLATE_BYTES_MOST || !inside(strings_entry.count, value.template_offset, value.template_count) {
		return {}, {}, false
	}
	if value.package_count == 0 || !inside(strings_entry.count, value.package_offset, value.package_count) {
		return {}, {}, false
	}
	return value, description, true
}

// fact_find gives the row of the table Facts with a key, by a search in
// the sorted table, checked as `fact` checks it. ok is false for a key that
// no valid row has: the key 0 too. A table that is not sorted gives no row
// for some keys, never a row of another key.
fact_find :: proc "contextless" (file: []u8, key: u64) -> (index: u32, value: Fact, description: Record, ok: bool) {
	if key == 0 {
		return 0, {}, {}, false
	}
	low, high := u32(1), count(file, .Facts)
	for low < high {
		middle := low + (high - low) / 2
		row, row_read := record(file, .Facts, middle, Fact)
		if !row_read {
			return 0, {}, {}, false
		}
		switch {
		case row.key < key:
			low = middle + 1
		case row.key > key:
			high = middle
		case:
			value, description = fact(file, middle) or_return
			return middle, value, description, true
		}
	}
	return 0, {}, {}, false
}

// record_is_fact says if a row of the table Records is the record type of
// a row of the table Facts. A fact type is read through the readers of the
// log, never made by hand, so a reader of the records of a module that
// offers a way to make one (the console) leaves it out. The table Facts is
// sorted by key, not by record: the search reads each of its rows, which
// a module holds a few dozen of. The record 0, and a record past the table,
// is no fact.
record_is_fact :: proc "contextless" (file: []u8, record_index: u32) -> bool {
	if record_index == 0 || record_index >= count(file, .Records) {
		return false
	}
	for index in 1 ..< count(file, .Facts) {
		row, row_read := record(file, .Facts, index, Fact)
		if row_read && row.record == record_index {
			return true
		}
	}
	return false
}

// Why a fact template breaks the rules of its language
// (src/md/features/log_facts.md, "The fact template").
Fact_Template_Fault :: enum u8 {
	None               = 0, // The template keeps each rule.
	Too_Long           = 1, // It has more than FACT_TEMPLATE_BYTES_MOST bytes.
	Not_Text           = 2, // It is not UTF-8 with no control character.
	Unclosed_Brace     = 3, // A "{" has no "}" after it.
	Lone_Closing_Brace = 4, // A "}" is not "}}" and closes no "{".
	Not_A_Field_Name   = 5, // The text in braces is not a name of a field: a letter or "_", then letters, digits and "_". A format, a width or an expression is not one.
	Unknown_Field      = 6, // The name in braces names no field of the record.
	Field_Twice        = 7, // The template names one field two times.
	Field_Not_Named    = 8, // A field of the record has no name in braces.
	Too_Many_Fields    = 9, // The record has more than FACT_FIELD_CAPACITY fields.
}

// fact_template_check checks a fact template against the names of the
// fields of its record, in their order: the fault, and the place of the
// fault, a byte of the template, or the index of the field for
// Field_Not_Named. "{name}" writes the field `name`; "{{" and "}}" write
// one brace.
//
// Example: with the fields "block" and "check", "the block {block} has the
// check {check}" is None; "the block {block}" is Field_Not_Named at 1;
// "{block:08}" is Not_A_Field_Name at 1.
fact_template_check :: proc "contextless" (template: string, names: []string) -> (fault: Fact_Template_Fault, place: int) {
	if len(template) > FACT_TEMPLATE_BYTES_MOST {
		return .Too_Long, FACT_TEMPLATE_BYTES_MOST
	}
	if at, found := text_encoding.invalid_sequence_find(transmute([]u8)template); found {
		return .Not_Text, at
	}
	if len(names) > FACT_FIELD_CAPACITY {
		return .Too_Many_Fields, FACT_FIELD_CAPACITY
	}
	named: [FACT_FIELD_CAPACITY]bool
	at := 0
	for at < len(template) {
		switch template[at] {
		case '}':
			if at + 1 < len(template) && template[at + 1] == '}' {
				at += 2
				continue
			}
			return .Lone_Closing_Brace, at
		case '{':
			if at + 1 < len(template) && template[at + 1] == '{' {
				at += 2
				continue
			}
			start := at + 1
			closing := start
			for closing < len(template) && template[closing] != '}' {
				closing += 1
			}
			if closing == len(template) {
				return .Unclosed_Brace, at
			}
			name := template[start:closing]
			if !source_name_valid(name) {
				return .Not_A_Field_Name, start
			}
			found := -1
			for candidate, index in names {
				if candidate == name {
					found = index
					break
				}
			}
			if found < 0 {
				return .Unknown_Field, start
			}
			if named[found] {
				return .Field_Twice, start
			}
			named[found] = true
			at = closing + 1
		case:
			at += 1
		}
	}
	for index in 0 ..< len(names) {
		if !named[index] {
			return .Field_Not_Named, index
		}
	}
	return .None, 0
}

// source_name_valid says if a text is a name as the source has it, the
// name of a field of a record type or of a package variable: a letter of
// ASCII or "_", then letters, digits and "_".
@(private)
source_name_valid :: proc "contextless" (name: string) -> bool {
	if len(name) == 0 {
		return false
	}
	for index in 0 ..< len(name) {
		character := name[index]
		letter := character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character == '_'
		digit := character >= '0' && character <= '9'
		if !letter && !(digit && index > 0) {
			return false
		}
	}
	return true
}

// fact_template_valid checks the template of a row of the table Facts
// against the fields of its record, as `fact` gave them. A reader that
// writes the sentence of a fact calls it first: a template that breaks a
// rule gives the raw form, not a fault.
fact_template_valid :: proc "contextless" (file: []u8, value: Fact, description: Record) -> Fact_Template_Fault {
	if description.field_count > FACT_FIELD_CAPACITY {
		return .Too_Many_Fields
	}
	names: [FACT_FIELD_CAPACITY]string
	for number in 0 ..< description.field_count {
		item, item_ok := field(file, description, number)
		if !item_ok {
			return .Unknown_Field
		}
		names[number] = string_at(file, item.name_offset, item.name_count)
	}
	fault, _ := fact_template_check(string_at(file, value.template_offset, value.template_count), names[:description.field_count])
	return fault
}

// A field of fact values holds the values of one whole fact: the contract
// of the log and the kind of a field name one size.
#assert(value_kinds.FACT_VALUES_FIELD_BYTES == op.LOG_FACT_VALUE_CAPACITY)

// The bytes of the buffer in which a reader writes the sentence of one
// fact. A sentence that does not fit is refused, and the reader shows the
// raw form: a template of 256 bytes with values of 144 bytes fits in most
// cases, and a cut sentence would say another thing.
FACT_SENTENCE_BYTES_MOST :: 1024

// The value runs of the sentence of one fact that a reader keeps: one for
// each field, at most.
FACT_SENTENCE_RUNS_MOST :: FACT_FIELD_CAPACITY

// Why a reader writes the raw form of a fact in place of its sentence
// (src/md/features/log_facts.md, "The reader path").
Fact_Render_Refusal :: enum u8 {
	None         = 0, // The sentence is written.
	No_Fact_Type = 1, // The file has no valid row of the table Facts with the key.
	Value_Count  = 2, // The count of the value bytes is not the size of the record of the fact type.
	Template     = 3, // The fact template breaks a rule of its language (fact_template_valid).
	Too_Long     = 4, // The sentence does not fit in the buffer of the reader.
}

// sentence_byte writes one byte of a sentence at the place `written`, and
// counts it also when the buffer has no room for it: a count past the
// buffer says that the sentence does not fit.
@(private = "file")
sentence_byte :: proc "contextless" (sentence: []u8, written: ^int, character: u8) {
	if written^ < len(sentence) {
		sentence[written^] = character
	}
	written^ += 1
}

@(private = "file")
sentence_text :: proc "contextless" (sentence: []u8, written: ^int, text: string) {
	for index in 0 ..< len(text) {
		sentence_byte(sentence, written, text[index])
	}
}

@(private = "file")
sentence_unsigned :: proc "contextless" (sentence: []u8, written: ^int, value: u64) {
	digits: [20]u8
	count := 0
	rest := value
	for {
		digits[count] = '0' + u8(rest % 10)
		count += 1
		rest /= 10
		if rest == 0 {
			break
		}
	}
	for count > 0 {
		count -= 1
		sentence_byte(sentence, written, digits[count])
	}
}

@(private = "file")
sentence_signed :: proc "contextless" (sentence: []u8, written: ^int, value: i64) {
	if value >= 0 {
		sentence_unsigned(sentence, written, u64(value))
		return
	}
	// The opposite of the least i64 does not fit in an i64: the bits do.
	sentence_byte(sentence, written, '-')
	sentence_unsigned(sentence, written, ~u64(value) + 1)
}

@(private = "file")
sentence_hexadecimal_byte :: proc "contextless" (sentence: []u8, written: ^int, value: u8) {
	digit :: proc "contextless" (nibble: u8) -> u8 {
		return nibble < 10 ? '0' + nibble : 'a' + nibble - 10
	}
	sentence_byte(sentence, written, digit(value >> 4))
	sentence_byte(sentence, written, digit(value & 0xF))
}

// fact_value_write writes the value of one field of a fact by its type and
// its field kind, as log_facts.md says ("The fact template"), and gives its
// value kind: None for a plain Text, which has no color of its own. values
// is a copy of the reader: a Text field in it is made valid in place.
@(private = "file")
fact_value_write :: proc "contextless" (sentence: []u8, written: ^int, values: []u8, item: Field) -> value_kinds.Value_Kind {
	type, type_ok := field_type(item)
	kind, kind_ok := field_kind(item)
	if !type_ok || !kind_ok {
		// record_type refused such a field: a description that reaches
		// here has none.
		sentence_byte(sentence, written, '?')
		return .None
	}
	switch type {
	case .Integer:
		value := field_integer(values, item)
		switch kind {
		case .Hexadecimal:
			sentence_text(sentence, written, "0x")
			for index := int(field_size(item)) - 1; index >= 0; index -= 1 {
				sentence_hexadecimal_byte(sentence, written, u8(u64(value) >> (8 * u64(index))))
			}
			return .Number
		case .Status:
			// The words of the member in a sentence: the name, or the
			// words that a line of a stop wrote before the facts.
			which, which_ok := field_contract_enum(item)
			if words, named := op.contract_enum_member_words(which, u64(value)); which_ok && named {
				sentence_text(sentence, written, words)
				return .Status
			}
			// A word that names no member: its number, never the name of
			// another member.
			sentence_unsigned(sentence, written, u64(value))
			return .Number
		case .Plain, .Module_Name, .Hash, .Fact_Values:
			// field_kind_valid refuses the three last on an Integer.
		}
		if item.unsigned && field_size(item) == 8 {
			sentence_unsigned(sentence, written, u64(value))
		} else {
			sentence_signed(sentence, written, value)
		}
		if !value_kinds.integer_unit_valid(item.integer_unit) {
			return .Number
		}
		sentence_text(sentence, written, value_kinds.integer_unit_text(item.integer_unit))
		switch item.integer_unit.kind {
		case .Size:
			return .Size
		case .Time:
			return .Time
		case .None, .Number, .Handle, .Value, .Grant, .Status, .Type, .Operation, .Command, .Module, .File, .Guide, .Term, .Version, .Yes, .No, .Procedure, .Constant, .Variable:
			// integer_unit_valid takes no unit of another kind.
		}
		return .Number
	case .Text:
		// A Text value is bytes of the writer that nobody checked: the
		// kernel filters no byte of a fact. Up to its first zero byte, it
		// takes the rule of the filter of the kernel, so a fact cannot put
		// a line end or an escape sequence in a line of a reader.
		if u64(item.offset) > u64(len(values)) || u64(item.detail) > u64(len(values)) - u64(item.offset) {
			return .None
		}
		bytes := values[item.offset:][:item.detail]
		end := 0
		for end < len(bytes) && bytes[end] != 0 {
			end += 1
		}
		text_encoding.invalid_sequences_replace(bytes[:end])
		sentence_text(sentence, written, string(bytes[:end]))
		return kind == .Module_Name ? .Module : .None
	case .Bytes:
		bytes := field_bytes(values, item)
		last := len(bytes)
		if kind == .Fact_Values {
			// As the raw form: the zeros after the last byte that is not
			// zero say nothing.
			for last > 0 && bytes[last - 1] == 0 {
				last -= 1
			}
		}
		for value in bytes[:last] {
			sentence_hexadecimal_byte(sentence, written, value)
		}
		return kind == .Hash ? .Version : .Number
	case .Handle:
		// The tool refuses a Handle field in a fact type; a description of
		// another party can still hold one, which means nothing here.
		sentence_byte(sentence, written, '?')
		return .None
	case .None, .Record, .Table:
		// A record holds no field of these types.
	}
	return .None
}

// fact_sentence_write writes the sentence of a log fact: the fact template
// of the row of the table Facts with the key, with the value of each field
// written by its kind. It gives the bytes written in sentence, and one
// value run for each value that has a value kind, in runs: a run past
// len(runs) is not kept, and its value stays in the sentence. values are
// the value bytes of the fact, which must have the size of its record; the
// procedure reads a copy and changes none of them. The readers of the
// system and the tool call it, so they never write two sentences for one
// fact. A refusal gives 0 bytes and leaves sentence and runs as they were:
// the reader shows the raw form. A sentence of more than
// FACT_SENTENCE_BYTES_MOST bytes is refused, whatever the buffer.
//
// Example: the template "storage: the block {block} has a wrong check
// {check}, expected {expected}" with the values of block = 12, check =
// 0x231a and expected = 0x2b1a gives "storage: the block 12 has a wrong
// check 0x0000231a, expected 0x00002b1a" and three runs of the kind Number.
fact_sentence_write :: proc "contextless" (file: []u8, key: u64, values: []u8, sentence: []u8, runs: []value_kinds.Value_Run_In_Call) -> (count: int, run_count: int, refusal: Fact_Render_Refusal) {
	_, row, description, found := fact_find(file, key)
	if !found {
		return 0, 0, .No_Fact_Type
	}
	if len(values) != int(description.size) {
		return 0, 0, .Value_Count
	}
	if fact_template_valid(file, row, description) != .None {
		return 0, 0, .Template
	}
	copied: [op.LOG_FACT_VALUE_CAPACITY]u8
	own := copied[:copy(copied[:], values)]
	// The sentence and its runs go to memory of this procedure first: a
	// refusal leaves the buffer and the runs of the caller as they were.
	local_sentence: [FACT_SENTENCE_BYTES_MOST]u8
	local_runs: [FACT_SENTENCE_RUNS_MOST]value_kinds.Value_Run_In_Call
	kept_sentence := local_sentence[:min(len(sentence), FACT_SENTENCE_BYTES_MOST)]
	kept_runs := local_runs[:min(len(runs), FACT_SENTENCE_RUNS_MOST)]
	written := 0
	runs_written := 0
	template := string_at(file, row.template_offset, row.template_count)
	// fact_template_valid took the template: each brace is "{{", "}}" or
	// a name of a field between two braces.
	for at := 0; at < len(template); {
		switch template[at] {
		case '{':
			if template[at + 1] == '{' {
				sentence_byte(kept_sentence, &written, '{')
				at += 2
				continue
			}
			closing := at + 1
			for template[closing] != '}' {
				closing += 1
			}
			name := template[at + 1:closing]
			for number in 0 ..< description.field_count {
				item, _ := field(file, description, number)
				if string_at(file, item.name_offset, item.name_count) != name {
					continue
				}
				start := written
				kind := fact_value_write(kept_sentence, &written, own, item)
				value_kinds.value_run_add(kept_runs, &runs_written, start, written, kind)
				break
			}
			at = closing + 1
		case '}':
			sentence_byte(kept_sentence, &written, '}')
			at += 2
		case:
			sentence_byte(kept_sentence, &written, template[at])
			at += 1
		}
	}
	if written > len(kept_sentence) {
		return 0, 0, .Too_Long
	}
	copy(sentence, kept_sentence[:written])
	copy(runs, kept_runs[:runs_written])
	return written, runs_written, .None
}
