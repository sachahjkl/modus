// The conditions of the console: the argument of `where` after its table,
// a field of the record of the table, an operator and a value, as
// `block = 12` or `level = Warning` (docs/CONSOLE.md, "Conditions").
//
// The package reads the field and the operator of a condition, checks the
// field against the description of the record, reads the member of a
// status, checks the kind and the range of a value, compares the values of
// fields, keeps the conditions of one line, and writes the sentence of each
// refusal. The console reads the value of a field that is no status with
// its own parser, and gives its kind here. The package has no state, calls
// no allocator and makes no kernel call: host tests give each input.
package console_condition

import module "modus:contract/module"
import "modus:contract/value_kinds"
import "modus:console_language"
import "modus:line_editor"
import "modus:sentence"

// The operators of a condition.
Comparison :: enum u8 {
	Equal            = 0, // =
	Not_Equal        = 1, // !=
	Less             = 2, // <
	Less_Or_Equal    = 3, // <=
	Greater          = 4, // >
	Greater_Or_Equal = 5, // >=
}

@(rodata)
COMPARISON_TEXTS := [Comparison]string {
	.Equal            = "=",
	.Not_Equal        = "!=",
	.Less             = "<",
	.Less_Or_Equal    = "<=",
	.Greater          = ">",
	.Greater_Or_Equal = ">=",
}

// A condition on one field of the rows of a table. The value is an
// Integer for an Integer or a Handle field, the word of a member for a
// status field, a Text for a Text field.
Condition :: struct {
	field:      string, // The name of the field, as the line has it.
	comparison: Comparison,
	compared:   i64, // An Integer, a handle, or the word of a member.
	text:       string, // A Text.
}

// Why a condition is refused. Each refusal is found before a row is read.
Refusal :: enum u8 {
	None                  = 0,
	No_Field              = 1, // No name of a field before the operator: `where(t, = 3)`.
	No_Operator           = 2, // A field with no operator after it: `where(t, level)`.
	Lone_Bang             = 3, // A "!" with no "=" after it.
	Double_Equal          = 4, // "==": the operator of equality is "=".
	No_Value              = 5, // Nothing after the operator: `where(t, number <` at the end of the line.
	Unknown_Field         = 6, // The record has no field of the name.
	Not_Comparable        = 7, // A Bytes field: a hash, the values of a fact. The console has no value of it.
	No_Order              = 8, // An order (<, <=, >, >=) on a Text or a status.
	Member_Is_A_Name      = 9, // A text or a number after the operator of a status: a member is a name.
	Unknown_Member        = 10, // A name that names no member of the enum of the status.
	Wrong_Kind            = 11, // A value of another kind than the field.
	Negative_For_Unsigned = 12, // A negative value for an unsigned field.
	Out_Of_Field          = 13, // A value that the field cannot hold.
	Too_Many              = 14, // The line holds more conditions than CONDITION_CAPACITY.
}

// ---- The field and the operator.

// What head_read reads: the field, the operator, and the place of the
// value after it.
Head :: struct {
	field:       string,
	comparison:  Comparison,
	value_start: int, // The byte after the operator.
}

// comparison_at reads the operator of a condition at the byte place of a
// text. end is the byte after it. refusal is No_Operator when no operator
// starts there, Lone_Bang for a "!" with no "=" after it, Double_Equal for
// "==".
comparison_at :: proc "contextless" (text: string, place: int) -> (comparison: Comparison, end: int, refusal: Refusal) {
	if place < 0 || place >= len(text) {
		return .Equal, place, .No_Operator
	}
	second := place + 1 < len(text) ? text[place + 1] : 0
	switch text[place] {
	case '=':
		if second == '=' {
			return .Equal, place, .Double_Equal
		}
		return .Equal, place + 1, .None
	case '!':
		if second == '=' {
			return .Not_Equal, place + 2, .None
		}
		return .Equal, place, .Lone_Bang
	case '<':
		if second == '=' {
			return .Less_Or_Equal, place + 2, .None
		}
		return .Less, place + 1, .None
	case '>':
		if second == '=' {
			return .Greater_Or_Equal, place + 2, .None
		}
		return .Greater, place + 1, .None
	}
	return .Equal, place, .No_Operator
}

// value_follows says if a value can start at a token: not the end of the
// line, and not the ")" or the "," that ends the argument.
@(private = "file")
value_follows :: proc "contextless" (text: string, token: console_language.Token) -> bool {
	if token.kind == .None {
		return false
	}
	return !(token.kind == .Operator && (text[token.start] == ')' || text[token.start] == ','))
}

// head_read reads the field and the operator of a condition at the byte
// place of a text, as the scanner of the console reads its tokens.
head_read :: proc "contextless" (text: string, place: int) -> (head: Head, refusal: Refusal) {
	field := console_language.token_next(text, place)
	if field.kind != .Name {
		return {}, .No_Field
	}
	head.field = text[field.start:field.end]
	operator := console_language.token_next(text, field.end)
	if operator.kind != .Operator {
		return head, .No_Operator
	}
	end: int
	head.comparison, end, refusal = comparison_at(text, operator.start)
	if refusal != .None {
		return head, refusal
	}
	head.value_start = end
	if !value_follows(text, console_language.token_next(text, end)) {
		return head, .No_Value
	}
	return head, .None
}

// ---- The field.

// field_find gives the field of a record with a name.
field_find :: proc "contextless" (file: []u8, record: module.Record, name: string) -> (item: module.Field, found: bool) {
	for number in 0 ..< record.field_count {
		item = module.field(file, record, number) or_continue
		if module.string_at(file, item.name_offset, item.name_count) == name {
			return item, true
		}
	}
	return {}, false
}

// field_check says if a field takes an operator: a Bytes field has no
// value that the console compares, and a Text or a status has no order.
field_check :: proc "contextless" (item: module.Field, comparison: Comparison) -> Refusal {
	type, type_ok := module.field_type(item)
	kind, kind_ok := module.field_kind(item)
	if !type_ok || !kind_ok {
		return .Not_Comparable
	}
	equality := comparison == .Equal || comparison == .Not_Equal
	switch type {
	case .Integer:
		if kind == .Status && !equality {
			return .No_Order
		}
		return .None
	case .Text:
		return equality ? .None : .No_Order
	case .Handle:
		return .None
	case .Bytes:
		// A text view is a text: compared whole, with no order.
		if kind == .Text_View {
			return equality ? .None : .No_Order
		}
	case .None, .Record, .Table, .Enum:
	}
	return .Not_Comparable
}

// field_is_status says if a field holds a member of a contract enum, and
// which enum.
field_is_status :: proc "contextless" (item: module.Field) -> (which: value_kinds.Contract_Enum, status: bool) {
	kind, kind_ok := module.field_kind(item)
	which_read, which_ok := module.field_contract_enum(item)
	if !kind_ok || !which_ok || kind != .Status || which_read == .None {
		return .None, false
	}
	return which_read, true
}

// ---- The value.

// member_read reads the member of a status after the operator: a name of
// the enum, which becomes its word at this one place. end is the byte
// after the name.
member_read :: proc "contextless" (text: string, place: int, which: value_kinds.Contract_Enum) -> (word: u64, member: string, end: int, refusal: Refusal) {
	token := console_language.token_next(text, place)
	if !value_follows(text, token) {
		return 0, "", place, .No_Value
	}
	member = text[token.start:token.end]
	if token.kind != .Name {
		return 0, member, token.end, .Member_Is_A_Name
	}
	named: bool
	if word, named = module.contract_enum_member_of_name(which, member); !named {
		return 0, member, token.end, .Unknown_Member
	}
	return word, member, token.end, .None
}

// value_check checks a value of a field that is no status: its kind, an
// Integer for an Integer or a Handle field and a Text for a Text field,
// and that the field can hold an Integer: no negative value for an
// unsigned field, and none past the bytes of the field.
value_check :: proc "contextless" (item: module.Field, kind: module.Type, value: i64) -> Refusal {
	type, type_ok := module.field_type(item)
	if !type_ok {
		return .Not_Comparable
	}
	switch type {
	case .Text:
		return kind == .Text ? .None : .Wrong_Kind
	case .Integer:
		if kind != .Integer {
			return .Wrong_Kind
		}
		if item.unsigned && value < 0 {
			return .Negative_For_Unsigned
		}
		return module.field_integer_fits(item, value) ? .None : .Out_Of_Field
	case .Handle:
		if kind != .Integer {
			return .Wrong_Kind
		}
		return value >= 0 && value <= i64(max(u32)) ? .None : .Out_Of_Field
	case .Bytes:
		if field_kind, field_kind_ok := module.field_kind(item); field_kind_ok && field_kind == .Text_View {
			return kind == .Text ? .None : .Wrong_Kind
		}
	case .None, .Record, .Table, .Enum:
	}
	return .Not_Comparable
}

// ---- The values of fields, and their order.

// The value of one field of a row: a Text, or an Integer with its sign.
Field_Value :: struct {
	is_text:  bool,
	text:     string,
	integer:  i64, // The bits of the field: an unsigned field of 8 bytes holds each value as its bits.
	unsigned: bool,
}

// field_value_of gives the value of one field of a row: an Integer or a
// handle with its sign, or a Text, a text view too, whose long text is in
// area, the out-of-line area of its fact. ok is false for a field with no
// value that the console compares, and for a view that
// value_kinds.text_view_read refuses.
field_value_of :: proc "contextless" (row: []u8, item: module.Field, area: []u8 = nil) -> (value: Field_Value, ok: bool) {
	type := module.field_type(item) or_return
	if kind, kind_ok := module.field_kind(item); kind_ok && kind == .Text_View && type == .Bytes {
		text := value_kinds.text_view_read(module.field_bytes(row, item), area) or_return
		return {is_text = true, text = string(text)}, true
	}
	switch type {
	case .Integer:
		return {integer = module.field_integer(row, item), unsigned = item.unsigned}, true
	case .Handle:
		if u64(item.offset) > u64(len(row)) || u64(len(row)) - u64(item.offset) < 4 {
			return {}, false
		}
		handle: u64
		for index in 0 ..< u32(4) {
			handle |= u64(row[item.offset + index]) << (8 * index)
		}
		return {integer = i64(handle), unsigned = true}, true
	case .Text:
		return {is_text = true, text = module.field_text(row, item)}, true
	case .Bytes, .None, .Record, .Table, .Enum:
	}
	return {}, false
}

// values_compare gives -1, 0 or 1: Texts byte by byte; two unsigned
// Integers as unsigned, so 2^63 and max(u64) are the largest; an unsigned
// Integer and a signed one by value, a negative one first.
values_compare :: proc "contextless" (a, b: Field_Value) -> int {
	order :: proc "contextless" (less, greater: bool) -> int {
		return less ? -1 : greater ? 1 : 0
	}
	if a.is_text || b.is_text {
		for index in 0 ..< min(len(a.text), len(b.text)) {
			if a.text[index] != b.text[index] {
				return a.text[index] < b.text[index] ? -1 : 1
			}
		}
		return order(len(a.text) < len(b.text), len(a.text) > len(b.text))
	}
	switch {
	case a.unsigned && !b.unsigned && b.integer < 0:
		return 1
	case b.unsigned && !a.unsigned && a.integer < 0:
		return -1
	case a.unsigned || b.unsigned:
		return order(u64(a.integer) < u64(b.integer), u64(a.integer) > u64(b.integer))
	}
	return order(a.integer < b.integer, a.integer > b.integer)
}

// condition_holds says if the value of a field passes a condition. The
// value of the condition has the sign of the field: value_check refused a
// negative value for an unsigned field.
condition_holds :: proc "contextless" (value: Field_Value, condition: Condition) -> bool {
	compared := Field_Value{is_text = value.is_text, text = condition.text, integer = condition.compared, unsigned = value.unsigned}
	order := values_compare(value, compared)
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
	}
	return false
}

// text_view_condition_holds says if a text view passes a condition of
// equality, from its 16 bytes first: another length or another prefix
// decides with no read of the out-of-line area, and a short text is
// decided whole. Only a long text with the length and the prefix of the
// condition reads area. read_area says that it did, so a reader counts
// the reads that the head did not spare (a measure, never a condition).
// decided is false for a view that needs its area when area is nil, and
// for a view that value_kinds.text_view_read refuses.
text_view_condition_holds :: proc "contextless" (row: []u8, item: module.Field, area: []u8, condition: Condition) -> (holds, read_area, decided: bool) {
	equal: bool
	switch value_kinds.text_view_compare_head(module.field_bytes(row, item), condition.text) {
	case .Different:
		equal = false
	case .Equal:
		equal = true
	case .Read_Area:
		if area == nil {
			return false, false, false
		}
		text, readable := value_kinds.text_view_read(module.field_bytes(row, item), area)
		if !readable {
			return false, true, false
		}
		equal, read_area = string(text) == condition.text, true
	}
	switch condition.comparison {
	case .Equal:
		return equal, read_area, true
	case .Not_Equal:
		return !equal, read_area, true
	case .Less, .Less_Or_Equal, .Greater, .Greater_Or_Equal:
		// field_check refuses an order on a text.
	}
	return false, read_area, false
}

// ---- The conditions of a line.

// The bytes of the shortest condition in a line: its own `where(` and
// `,a=1)` after the table, as in `where(where(t,a=1),b=1)`; with `|>` it
// takes one byte more (`|>where(a=1)`).
CONDITION_BYTES_LEAST :: len("where(") + len(",a=1)")

// The conditions that one line holds at most: a line of the history is the
// longest line that runs, so no line that runs holds more, and the limit
// is a defense that the host tests reach.
CONDITION_CAPACITY :: max(line_editor.LINE_CAPACITY, line_editor.HISTORY_LINE_CAPACITY) / CONDITION_BYTES_LEAST
#assert(CONDITION_CAPACITY * CONDITION_BYTES_LEAST <= max(line_editor.LINE_CAPACITY, line_editor.HISTORY_LINE_CAPACITY))

// The conditions of the line that runs. A value of the console names one
// by its address, so that a value stays small.
Condition_List :: struct {
	items: [CONDITION_CAPACITY]Condition,
	count: int,
}

// condition_keep keeps a condition for the line, and gives its address;
// nil and Too_Many when the line holds CONDITION_CAPACITY already.
condition_keep :: proc "contextless" (list: ^Condition_List, condition: Condition) -> (kept: ^Condition, refusal: Refusal) {
	if list.count >= CONDITION_CAPACITY {
		return nil, .Too_Many
	}
	list.items[list.count] = condition
	list.count += 1
	return &list.items[list.count - 1], .None
}

// ---- The sentence of a refusal.

// What the sentence of a refusal names: the command, the record and its
// file, the field, its description, the text of a member and the type of a
// value.
Refusal_Details :: struct {
	command:    string, // "where".
	file:       []u8, // The description of the record.
	record:     module.Record,
	field:      string, // The name that the line gives.
	item:       module.Field, // The field, when the record has it.
	comparison: Comparison,
	member:     string, // The text after the operator of a status.
	value_type: module.Type, // The type of the value that the line gives.
}

@(rodata)
TYPE_NAMES := [module.Type]string {
	.None    = "None",
	.Integer = "Integer",
	.Text    = "Text",
	.Record  = "Record",
	.Handle  = "Handle",
	.Table   = "Table",
	.Bytes   = "Bytes",
	.Enum    = "Enum",
}

// field_names_write writes the names of the fields of a record, separated
// by ", ".
field_names_write :: proc "contextless" (writer: ^sentence.Writer, file: []u8, record: module.Record) {
	for number in 0 ..< record.field_count {
		item := module.field(file, record, number) or_continue
		sentence.write_part(writer, number > 0 ? ", " : "")
		sentence.write_part(writer, module.string_at(file, item.name_offset, item.name_count))
	}
}

// members_write writes the names of the members of a contract enum,
// separated by ", ".
members_write :: proc "contextless" (writer: ^sentence.Writer, which: value_kinds.Contract_Enum) {
	written := 0
	for word in 0 ..< module.contract_enum_member_count(which) {
		if name, named := module.contract_enum_member_name(which, word); named {
			sentence.write_part(writer, written > 0 ? ", " : "")
			sentence.write_part(writer, name)
			written += 1
		}
	}
}

// type_word_name gives the name of the type of a field by its byte:
// "Integer", "Text", "Handle".
@(private = "file")
type_word_name :: proc "contextless" (item: module.Field) -> string {
	type, type_ok := module.field_type(item)
	return type_ok ? TYPE_NAMES[type] : "?"
}

// refusal_write writes the sentence of a refusal. The line fails with it.
refusal_write :: proc "contextless" (writer: ^sentence.Writer, refusal: Refusal, details: Refusal_Details) {
	command := details.command
	record_name := module.string_at(details.file, details.record.name_offset, details.record.name_count)
	which, _ := field_is_status(details.item)
	part :: sentence.write_part
	switch refusal {
	case .None:
	case .No_Field:
		part(writer, command)
		part(writer, " takes a condition: a field, an operator and a value, as ")
		part(writer, command)
		part(writer, "(t, block = 12); the fields are ")
		field_names_write(writer, details.file, details.record)
	case .No_Operator:
		part(writer, command)
		part(writer, ": after the field ")
		part(writer, details.field)
		part(writer, " comes an operator: =, !=, <, <=, > or >=")
	case .Lone_Bang:
		part(writer, command)
		part(writer, ": \"!\" alone is no operator: the operator of a difference is !=")
	case .Double_Equal:
		part(writer, command)
		part(writer, ": \"==\" is no operator: the operator of equality is =")
	case .No_Value:
		part(writer, command)
		part(writer, ": the condition on ")
		part(writer, details.field)
		part(writer, " has no value after its operator ")
		part(writer, COMPARISON_TEXTS[details.comparison])
	case .Unknown_Field:
		part(writer, command)
		part(writer, ": the records ")
		part(writer, record_name)
		part(writer, " have no field ")
		part(writer, details.field)
		part(writer, "; their fields are ")
		field_names_write(writer, details.file, details.record)
	case .Not_Comparable:
		part(writer, command)
		part(writer, ": the field ")
		part(writer, details.field)
		part(writer, " is ")
		sentence.write_field_type(writer, details.file, details.item)
		part(writer, "; ")
		part(writer, command)
		part(writer, " compares an Integer, a Text or a status")
	case .No_Order:
		part(writer, command)
		part(writer, ": the field ")
		part(writer, details.field)
		part(writer, " is ")
		sentence.write_field_type(writer, details.file, details.item)
		if which != .None {
			part(writer, ": it takes = and != only, because the order of the members is no order of weight")
		} else {
			part(writer, ": a Text takes = and != only")
		}
	case .Member_Is_A_Name:
		part(writer, command)
		part(writer, ": the field ")
		part(writer, details.field)
		part(writer, " holds a member of ")
		part(writer, value_kinds.CONTRACT_ENUM_TYPES[which].name)
		part(writer, ", and a member is a name, not a text or a number: ")
		part(writer, details.member)
		part(writer, " is none; the members are ")
		members_write(writer, which)
	case .Unknown_Member:
		part(writer, command)
		part(writer, ": the field ")
		part(writer, details.field)
		part(writer, " holds a member of ")
		part(writer, value_kinds.CONTRACT_ENUM_TYPES[which].name)
		part(writer, ": ")
		members_write(writer, which)
		part(writer, "; \"")
		part(writer, details.member)
		part(writer, "\" names none")
	case .Wrong_Kind:
		part(writer, command)
		part(writer, ": the field ")
		part(writer, details.field)
		part(writer, " is ")
		part(writer, type_word_name(details.item))
		part(writer, ", the value is ")
		part(writer, TYPE_NAMES[details.value_type])
	case .Negative_For_Unsigned:
		part(writer, command)
		part(writer, ": the field ")
		part(writer, details.field)
		part(writer, " is ")
		sentence.write_field_type(writer, details.file, details.item)
		part(writer, ", which holds no negative value")
	case .Out_Of_Field:
		part(writer, command)
		part(writer, ": the field ")
		part(writer, details.field)
		part(writer, " is ")
		sentence.write_field_type(writer, details.file, details.item)
		part(writer, ", which cannot hold the value")
	case .Too_Many:
		part(writer, "a line holds at most ")
		part(writer, u64(CONDITION_CAPACITY))
		part(writer, " conditions")
	}
}
