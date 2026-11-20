package output

import "modus:contract/module"

// The type check of a wiring (src/md/features/module_outputs.md, "The
// wiring and its rights"): the root service compares the record
// description of the record output, from the module file of the writer,
// with the record description of the record input, from the module file
// of the reader, and refuses a wiring whose descriptions differ. The
// description is the version of a record type: no prefix rule and no
// version number.

// What differs between two record descriptions, in the order of the
// check: the first difference is the one that the sentence names.
Description_Difference :: enum u8 {
	Equal         = 0, // The two descriptions are equal: the wiring passes the type check.
	Not_Described = 1, // module.record_stream_type refuses one of the two, or the index is 0: no comparison.
	Name          = 2, // The names of the two records differ.
	Size          = 3, // The sizes of the two records differ.
	Field_Count   = 4, // The counts of the fields differ.
	Field         = 5, // A field differs: part is its number, from 1.
}

// record_descriptions_compare compares the record index of file with the
// record other_index of other_file. It gives the first difference, and
// for Field the number of the first field that differs, from 1; else part
// is 0. Two fields are equal when their name, offset, type, sign, integer
// unit, detail, field kind and contract enum are equal: a reader checks a
// Status field against its enum, so the kind is part of the type. Each
// description passes module.record_stream_type first: a description that
// a reader cannot take is never compared, and refuses the wiring. It
// reads no state.
record_descriptions_compare :: proc "contextless" (file: []u8, index: u32, other_file: []u8, other_index: u32) -> (difference: Description_Difference, part: u32) {
	first, first_ok := module.record_stream_type(file, index)
	second, second_ok := module.record_stream_type(other_file, other_index)
	if !first_ok || !second_ok {
		return .Not_Described, 0
	}
	if module.string_at(file, first.name_offset, first.name_count) != module.string_at(other_file, second.name_offset, second.name_count) {
		return .Name, 0
	}
	if first.size != second.size {
		return .Size, 0
	}
	if first.field_count != second.field_count {
		return .Field_Count, 0
	}
	for number in 0 ..< first.field_count {
		a, a_ok := module.field(file, first, number)
		b, b_ok := module.field(other_file, second, number)
		if !a_ok || !b_ok {
			return .Not_Described, 0
		}
		same := a.offset == b.offset && a.type == b.type && a.unsigned == b.unsigned && a.integer_unit == b.integer_unit && a.detail == b.detail && a.kind == b.kind && a.contract_enum == b.contract_enum
		if !same || module.string_at(file, a.name_offset, a.name_count) != module.string_at(other_file, b.name_offset, b.name_count) {
			return .Field, number + 1
		}
	}
	return .Equal, 0
}
