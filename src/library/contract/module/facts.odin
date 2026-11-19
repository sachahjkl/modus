package module

import op "modus:contract/operation"
import "modus:contract/text_encoding"

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
			if !fact_field_name_valid(name) {
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

// fact_field_name_valid says if a text is a name of a field as a record
// type of the source has it: a letter of ASCII or "_", then letters,
// digits and "_".
@(private = "file")
fact_field_name_valid :: proc "contextless" (name: string) -> bool {
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
