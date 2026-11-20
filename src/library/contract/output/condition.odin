package output

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/module"
import "modus:contract/ring"
import "modus:contract/text_encoding"

// The condition of a wiring (src/md/features/module_outputs.md, "The
// condition of a wiring"): one field of the record of the record output,
// one operator and one value. The asker writes the terms in its list; the
// root service takes them through writer_condition_of_terms against the
// record description of the writer and gives the writer the resolved
// condition; the writer takes it through writer_condition_check and writes
// into that ring only the records for which writer_condition_holds.
//
// And the counts of a record output (src/md/features/module_outputs.md,
// "The counts of a record output"), which the writer publishes in the head
// page of each of its output rings.

// The bytes of the Text value of a condition, at most.
CONDITION_TEXT_BYTES_MOST :: 64

// The operator of a condition. 0 names nothing. The values cross the
// border of the root ring.
Condition_Comparison :: enum u32 {
	None             = 0, // Refused.
	Equal            = 1, // =
	Not_Equal        = 2, // !=
	Less             = 3, // <
	Less_Or_Equal    = 4, // <=
	Greater          = 5, // >
	Greater_Or_Equal = 6, // >=
}

// The kind of the value of a condition. The values cross the border of the
// root ring.
Condition_Value_Kind :: enum u32 {
	None    = 0, // Refused.
	Integer = 1, // For an Integer field, a status field among them: the word of the member.
	Text    = 2, // For a Text field.
}

// The terms of a condition, as the asker writes them after the lent
// handles of its list, or as the wiring terms of `filter`. Each word is the
// word of its member or a number. The tool describes it for the record
// input of `filter`, so its text has a written count and each reserved
// word is a field of its own: the tool takes no other array.
Condition_Terms :: struct {
	field:           u32, // The number of the field from 1, in the record description of the record output.
	comparison:      u32, // A Condition_Comparison.
	value_kind:      u32, // A Condition_Value_Kind.
	text_count:      u32, // A Text: its bytes, at most CONDITION_TEXT_BYTES_MOST. An Integer: 0.
	integer:         i64, // An Integer: the value. A Text: 0.
	text:            [64]u8, // A Text: its bytes, then zero bytes. An Integer: zero bytes.
	reserved_first:  u32, // 0.
	reserved_second: u32, // 0.
}
#assert(size_of(Condition_Terms) == 96)
#assert(size_of(Condition_Terms{}.text) == CONDITION_TEXT_BYTES_MOST)

// The number of each field of Condition_Terms, from 1, as the error record
// of a refusal names it in its argument; 0 for the terms as a whole.
Condition_Terms_Field :: enum i64 {
	Whole           = 0,
	Field           = 1,
	Comparison      = 2,
	Value_Kind      = 3,
	Text_Count      = 4,
	Integer         = 5,
	Text            = 6,
	Reserved_First  = 7,
	Reserved_Second = 8,
}

// How the writer reads the field of a condition. 0 names nothing.
Condition_Field_Type :: enum u32 {
	None     = 0, // Refused.
	Signed   = 1, // An Integer of 1, 2, 4 or 8 bytes with a sign.
	Unsigned = 2, // An Integer of 1, 2, 4 or 8 bytes with no sign, a status among them.
	Text     = 3, // The bytes of a Text field up to its first zero byte.
}

// The condition that the root service gives the writer, in a page with
// Read only: the place of the field in the record, not its number, as the
// writer has no copy of its module file.
Writer_Condition :: struct {
	offset:     u32, // The first byte of the field in the record.
	size:       u32, // The bytes of the field.
	field_type: u32, // A Condition_Field_Type.
	comparison: u32, // A Condition_Comparison.
	integer:    i64, // An Integer field: the value, with the sign of the field.
	text_count: u32, // A Text field: the bytes of the value.
	reserved_0: u32, // 0.
	text:       [CONDITION_TEXT_BYTES_MOST]u8, // A Text field: the value, then zero bytes.
	reserved:   [8]u32, // 0.
}
#assert(size_of(Writer_Condition) == 128)

// The pages of the page of a Writer_Condition.
WRITER_CONDITION_PAGES :: 1
#assert(size_of(Writer_Condition) <= WRITER_CONDITION_PAGES * ring.PAGE_SIZE)

// A condition after the border of the writer: each word is its member.
Checked_Condition :: struct {
	offset:     u32,
	size:       u32,
	field_type: Condition_Field_Type,
	comparison: Condition_Comparison,
	integer:    i64,
	text_count: u32,
	text:       [CONDITION_TEXT_BYTES_MOST]u8,
}

// terms_refusal is the error record of terms that the root service
// refuses: Bad_Value of the unit Wiring_Terms. The root service writes the
// row in found.
@(private = "file")
terms_refusal :: proc "contextless" (field: Condition_Terms_Field, word: i64, largest: i64) -> errors.Error_Record {
	return errors.error_make(.Bad_Value, .Wiring_Terms, i64(field), word, largest)
}

// order_comparison says if an operator orders: an order has no meaning on a
// Text or a status, whose members have no order of weight.
@(private = "file")
order_comparison :: proc "contextless" (comparison: Condition_Comparison) -> bool {
	switch comparison {
	case .Less, .Less_Or_Equal, .Greater, .Greater_Or_Equal:
		return true
	case .None, .Equal, .Not_Equal:
	}
	return false
}

// writer_condition_of_terms is the border of the root service for the terms
// of a condition: the copy of the bytes that the asker lent, against the
// record description of the record output, from the module file of the
// writer. It refuses, in the order of the fields:
//
// - bytes of another size than Condition_Terms;
// - a reserved word that is not 0;
// - a field of 0 or past the fields of the record, and a field of a type
//   that it does not filter: a Handle, Bytes, or a kind that the contract
//   does not take on its type;
// - an operator word that names no member, or None;
// - a value kind that names no member, None, or another kind than the
//   field: an Integer for an Integer field, a Text for a Text field;
// - an order (<, <=, >, >=) on a Text or a status: an operator that it does
//   not filter;
// - for an Integer: a text count or a text byte that is not 0, a negative
//   value for an unsigned field of less than 8 bytes, a value past the
//   bytes of the field (an unsigned field of 8 bytes takes each value as
//   its bits);
// - for a Text: an Integer that is not 0, a count past
//   CONDITION_TEXT_BYTES_MOST or past the field, a byte after the count
//   that is not 0, and a text that is not UTF-8 with no control character.
//
// The error record is Bad_Value of the unit Wiring_Terms, with the field
// of the terms as its argument (Condition_Terms_Field), the word as its
// value and the largest word that the border takes there as its limit. It
// reads no state, and a refusal gives no condition.
writer_condition_of_terms :: proc "contextless" (bytes: []u8, file: []u8, description: module.Record) -> (condition: Writer_Condition, refusal: errors.Error_Record, ok: bool) {
	if len(bytes) != size_of(Condition_Terms) {
		return {}, terms_refusal(.Whole, i64(len(bytes)), size_of(Condition_Terms)), false
	}
	terms: Condition_Terms
	intrinsics.mem_copy_non_overlapping(&terms, raw_data(bytes), size_of(terms))
	if terms.reserved_first != 0 {
		return {}, terms_refusal(.Reserved_First, i64(terms.reserved_first), 0), false
	}
	if terms.reserved_second != 0 {
		return {}, terms_refusal(.Reserved_Second, i64(terms.reserved_second), 0), false
	}
	if terms.field == 0 || terms.field > description.field_count {
		return {}, terms_refusal(.Field, i64(terms.field), i64(description.field_count)), false
	}
	item, item_ok := module.field(file, description, terms.field - 1)
	type, type_ok := module.field_type(item)
	kind, kind_ok := module.field_kind(item)
	if !item_ok || !type_ok || !kind_ok {
		return {}, terms_refusal(.Field, i64(terms.field), i64(description.field_count)), false
	}
	size := module.field_size(item)
	field_type := Condition_Field_Type.None
	status := false
	switch type {
	case .Integer:
		switch kind {
		case .Plain, .Hexadecimal, .Hexadecimal_Sixteen_Digits, .Hundredths, .Nanoseconds_As_Microseconds, .Tenths, .Hexadecimal_No_Leading_Zero, .Time_Of_Day:
			// A kind writes the integer in another form: the condition
			// compares the integer that the record holds.
			field_type = item.unsigned ? .Unsigned : .Signed
		case .Status:
			field_type, status = .Unsigned, true
		case .Module_Name, .Hash, .Fact_Values, .Hash_Head, .Text_View, .Log_Body:
			// module.field_kind_valid takes no such kind on an Integer.
		}
	case .Text:
		switch kind {
		case .Plain, .Module_Name:
			field_type = .Text
		case .Hexadecimal, .Status, .Hash, .Fact_Values, .Hexadecimal_Sixteen_Digits, .Hash_Head, .Hundredths, .Nanoseconds_As_Microseconds, .Tenths, .Hexadecimal_No_Leading_Zero, .Time_Of_Day, .Text_View, .Log_Body:
		}
	case .Handle, .Bytes, .None, .Record, .Table:
		// A handle names nothing for the writer, and Bytes have no value
		// that a condition compares.
	}
	if field_type == .None || size == 0 {
		return {}, terms_refusal(.Field, i64(terms.field), i64(description.field_count)), false
	}
	comparison, comparison_known := enum_word.member_of_word(Condition_Comparison, u64(terms.comparison))
	if !comparison_known || comparison == .None {
		return {}, terms_refusal(.Comparison, i64(terms.comparison), i64(max(Condition_Comparison))), false
	}
	value_kind, value_known := enum_word.member_of_word(Condition_Value_Kind, u64(terms.value_kind))
	if !value_known || value_kind == .None {
		return {}, terms_refusal(.Value_Kind, i64(terms.value_kind), i64(max(Condition_Value_Kind))), false
	}
	wanted := field_type == .Text ? Condition_Value_Kind.Text : Condition_Value_Kind.Integer
	if value_kind != wanted {
		return {}, terms_refusal(.Value_Kind, i64(terms.value_kind), i64(wanted)), false
	}
	if (field_type == .Text || status) && order_comparison(comparison) {
		return {}, terms_refusal(.Comparison, i64(terms.comparison), i64(Condition_Comparison.Not_Equal)), false
	}
	condition = {offset = item.offset, size = size, field_type = u32(field_type), comparison = u32(comparison)}
	switch value_kind {
	case .Integer:
		if terms.text_count != 0 {
			return {}, terms_refusal(.Text_Count, i64(terms.text_count), 0), false
		}
		for value, index in terms.text {
			if value != 0 {
				return {}, terms_refusal(.Text, i64(index), 0), false
			}
		}
		// An unsigned field of 8 bytes holds each value as its bits: the
		// test of the writer compares it so, and a value of 2^63 or more is
		// a negative Integer of 64 bits. A smaller unsigned field holds no
		// negative value.
		if item.unsigned && size < 8 && terms.integer < 0 {
			return {}, terms_refusal(.Integer, terms.integer, 0), false
		}
		if !module.field_integer_fits(item, terms.integer) {
			return {}, terms_refusal(.Integer, terms.integer, integer_most(size, item.unsigned)), false
		}
		condition.integer = terms.integer
	case .Text:
		if terms.integer != 0 {
			return {}, terms_refusal(.Integer, terms.integer, 0), false
		}
		text_most := min(u32(CONDITION_TEXT_BYTES_MOST), size)
		if terms.text_count > text_most {
			return {}, terms_refusal(.Text_Count, i64(terms.text_count), i64(text_most)), false
		}
		for index in terms.text_count ..< CONDITION_TEXT_BYTES_MOST {
			if terms.text[index] != 0 {
				return {}, terms_refusal(.Text, i64(index), i64(terms.text_count)), false
			}
		}
		if at, found := text_encoding.invalid_sequence_find(terms.text[:terms.text_count]); found {
			return {}, terms_refusal(.Text, i64(at), i64(terms.text_count)), false
		}
		// A zero byte inside the count ends the text of a field: no field
		// holds a text with one.
		for index in 0 ..< terms.text_count {
			if terms.text[index] == 0 {
				return {}, terms_refusal(.Text, i64(index), i64(terms.text_count)), false
			}
		}
		condition.text_count = terms.text_count
		condition.text = terms.text
	case .None:
		// Refused above: the case keeps the switch whole.
		return {}, terms_refusal(.Value_Kind, 0, i64(max(Condition_Value_Kind))), false
	}
	return condition, {}, true
}

// integer_most gives the largest value of an Integer field of a size, for
// the limit of a refusal.
@(private = "file")
integer_most :: proc "contextless" (size: u32, unsigned: bool) -> i64 {
	if size >= 8 {
		return max(i64)
	}
	bits := 8 * u64(size)
	if unsigned {
		return i64(u64(1) << bits - 1)
	}
	return i64(u64(1) << (bits - 1) - 1)
}

// writer_condition_check is the border of the writer for the page of its
// condition: the first bytes of the page that it mapped with Read only,
// against the size of its own record. It refuses a page smaller than the
// condition, a reserved word that is not 0, a field type or an operator
// that names no member or None, an Integer field of another size than 1,
// 2, 4 or 8, a field past the record, a text count past the field or past
// CONDITION_TEXT_BYTES_MOST, and a text byte after the count that is not 0.
// The writer copies the page once when it takes its end, and reads the
// copy through this border once, when the end opens at its first write:
// only then does it know the size of its record.
writer_condition_check :: proc "contextless" (bytes: []u8, record_size: u32) -> (checked: Checked_Condition, ok: bool) {
	if len(bytes) < size_of(Writer_Condition) {
		return {}, false
	}
	condition: Writer_Condition
	intrinsics.mem_copy_non_overlapping(&condition, raw_data(bytes), size_of(condition))
	if condition.reserved_0 != 0 {
		return {}, false
	}
	for word in condition.reserved {
		if word != 0 {
			return {}, false
		}
	}
	field_type, type_known := enum_word.member_of_word(Condition_Field_Type, u64(condition.field_type))
	comparison, comparison_known := enum_word.member_of_word(Condition_Comparison, u64(condition.comparison))
	if !type_known || field_type == .None || !comparison_known || comparison == .None {
		return {}, false
	}
	if condition.size == 0 || u64(condition.offset) + u64(condition.size) > u64(record_size) {
		return {}, false
	}
	switch field_type {
	case .Signed, .Unsigned:
		switch condition.size {
		case 1, 2, 4, 8:
		case:
			return {}, false
		}
		if condition.text_count != 0 {
			return {}, false
		}
	case .Text:
		if condition.text_count > min(condition.size, CONDITION_TEXT_BYTES_MOST) {
			return {}, false
		}
	case .None:
		return {}, false
	}
	for index in condition.text_count ..< CONDITION_TEXT_BYTES_MOST {
		if condition.text[index] != 0 {
			return {}, false
		}
	}
	return {offset = condition.offset, size = condition.size, field_type = field_type, comparison = comparison, integer = condition.integer, text_count = condition.text_count, text = condition.text}, true
}

// writer_condition_holds says if a record passes a condition: the one test
// of a condition of a wiring, in the writer and in each reader. A record
// that does not hold the field passes nothing.
writer_condition_holds :: proc "contextless" (condition: Checked_Condition, record: []u8) -> bool {
	if u64(condition.offset) + u64(condition.size) > u64(len(record)) {
		return false
	}
	field := record[condition.offset:][:condition.size]
	order: int
	switch condition.field_type {
	case .Signed, .Unsigned:
		bits: u64
		for index in 0 ..< len(field) {
			bits |= u64(field[index]) << (8 * uint(index))
		}
		if condition.field_type == .Signed {
			if len(field) < 8 && bits >> (8 * uint(len(field)) - 1) & 1 != 0 {
				bits |= ~u64(0) << (8 * uint(len(field)))
			}
			value := i64(bits)
			order = value < condition.integer ? -1 : value > condition.integer ? 1 : 0
		} else {
			compared := u64(condition.integer)
			order = bits < compared ? -1 : bits > compared ? 1 : 0
		}
	case .Text:
		count := 0
		for count < len(field) && field[count] != 0 {
			count += 1
		}
		// A copy: a parameter array is not sliced.
		text := condition.text
		order = bytes_order(field[:count], text[:condition.text_count])
	case .None:
		return false
	}
	switch condition.comparison {
	case .Equal:
		return order == 0
	case .Not_Equal:
		return order != 0
	case .Less:
		return order < 0
	case .Less_Or_Equal:
		return order <= 0
	case .Greater:
		return order > 0
	case .Greater_Or_Equal:
		return order >= 0
	case .None:
	}
	return false
}

// bytes_order gives -1, 0 or 1: the bytes in order, then the shorter one first.
@(private = "file")
bytes_order :: proc "contextless" (a, b: []u8) -> int {
	for index in 0 ..< min(len(a), len(b)) {
		if a[index] != b[index] {
			return a[index] < b[index] ? -1 : 1
		}
	}
	return len(a) < len(b) ? -1 : len(a) > len(b) ? 1 : 0
}

// condition_terms_of_field gives the terms of a condition on a field of a
// record description, for an asker that names the field by its name: the
// console. ok is false for a name that the record lacks.
condition_terms_of_field :: proc "contextless" (file: []u8, description: module.Record, name: string, comparison: Condition_Comparison, integer: i64, text: string, is_text: bool) -> (terms: Condition_Terms, ok: bool) {
	for number in 0 ..< description.field_count {
		item := module.field(file, description, number) or_continue
		if module.string_at(file, item.name_offset, item.name_count) != name {
			continue
		}
		terms = {field = number + 1, comparison = u32(comparison)}
		if is_text {
			terms.value_kind = u32(Condition_Value_Kind.Text)
			terms.text_count = u32(copy(terms.text[:], text))
		} else {
			terms.value_kind = u32(Condition_Value_Kind.Integer)
			terms.integer = integer
		}
		return terms, true
	}
	return {}, false
}

// ---- The counts of a record output.

// Where the writer publishes its counts in the head page of each of its
// output rings: in the half of the commands, past their counters, in a
// line of its own.
WRITER_COUNTS_OFFSET :: 1024

// The counts of a record output, as its writer claims them. A reader reads
// them and checks nothing against them: they change no decision.
Writer_Counts :: struct {
	written:   u64, // The records that one ring or more took.
	discarded: u64, // The records that no ring took: no reader, the condition of each ring, or each ring full for its reader alone.
	refused:   u64, // The writes refused with Full.
	// The writes that waited for room in a full ring that holds the writer:
	// the proof by count that a slow reader of the pace Always_Holds_Writer,
	// or a full ring of a writer that waits, set the speed of the writer.
	held:      u64,
	// The rings that the writer closed as their gap reached its largest
	// count (gap_after_refused_record): their readers read Side_Closed.
	rings_past_gap: u64,
	reserved:  [3]u64, // 0.
}
#assert(size_of(Writer_Counts) == 64)
#assert(WRITER_COUNTS_OFFSET >= size_of(ring.Counters) && WRITER_COUNTS_OFFSET + size_of(Writer_Counts) <= ring.PAGE_SIZE / 2)

// writer_counts_write writes the counts in the head page of a ring, one
// word at a time; the push that follows publishes them.
writer_counts_write :: proc "contextless" (head: rawptr, counts: Writer_Counts) {
	words := (^[8]u64)(rawptr(uintptr(head) + WRITER_COUNTS_OFFSET))
	intrinsics.atomic_store_explicit(&words[0], counts.written, .Relaxed)
	intrinsics.atomic_store_explicit(&words[1], counts.discarded, .Relaxed)
	intrinsics.atomic_store_explicit(&words[2], counts.refused, .Relaxed)
	intrinsics.atomic_store_explicit(&words[3], counts.held, .Relaxed)
	intrinsics.atomic_store_explicit(&words[4], counts.rings_past_gap, .Relaxed)
}

// writer_counts_read reads the counts of the head page of a ring, one word
// at a time: the claim of the writer as of the last compartment that the
// reader took.
writer_counts_read :: proc "contextless" (head: rawptr) -> (counts: Writer_Counts) {
	words := (^[8]u64)(rawptr(uintptr(head) + WRITER_COUNTS_OFFSET))
	counts.written = intrinsics.atomic_load_explicit(&words[0], .Relaxed)
	counts.discarded = intrinsics.atomic_load_explicit(&words[1], .Relaxed)
	counts.refused = intrinsics.atomic_load_explicit(&words[2], .Relaxed)
	counts.held = intrinsics.atomic_load_explicit(&words[3], .Relaxed)
	counts.rings_past_gap = intrinsics.atomic_load_explicit(&words[4], .Relaxed)
	return counts
}

// condition_comparison_text gives the sign of an operator.
@(rodata)
condition_comparison_texts := [Condition_Comparison]string {
	.None             = "",
	.Equal            = "=",
	.Not_Equal        = "!=",
	.Less             = "<",
	.Less_Or_Equal    = "<=",
	.Greater          = ">",
	.Greater_Or_Equal = ">=",
}
