// The reader of a plan that a principal writes in the console
// (src/md/features/declarations.md, "A plan written in the console"): it
// forces the record of `plan { … }` field by field and gives the rows of
// plans_recipes.Plan_Entry_Row that plans.apply takes. Each value takes its
// type from the description of its owner, at the border of the plan: a
// member from the enum of its parameter, a number in its range, a text in
// its bound. A refusal names what is wrong, in one sentence
// (refusal_write).
//
// This package allocates no memory and calls no kernel operation: the
// caller gives the evaluation, the boot image and the rows.
package plan_reader

import "modus:contract/chosen_values"
import module "modus:contract/module"
import description "modus:contract/plan_value_description"
import pr "modus:contract/plans_recipes"
import "modus:contract/role_contract"
import "modus:contract/root_plan_values"
import "modus:lex_evaluator"
import "modus:lex_parser"
import "modus:sentence"

// The boot image as the reader reads it: the module file of a name, or of
// a hash; an empty file for none.
Image :: description.Image

// The fields of a plan.
ROLES_FIELD :: "roles"
STORES_FIELD :: "stores"
VALUES_FIELD :: "values"
LOCKS_FIELD :: "locks"
@(rodata)
PLAN_FIELDS := [4]string{ROLES_FIELD, STORES_FIELD, VALUES_FIELD, LOCKS_FIELD}

// The members of the rights of a store.
READ_RIGHT :: "read"
WRITE_RIGHT :: "write"

// Why the reader refuses a plan. Each refusal reads nothing more.
Problem :: enum u8 {
	None                = 0,
	Not_A_Plan          = 1, // The value is no plan.
	Not_Read            = 2, // The evaluation refused a field of the plan: its refusal says why (name: the field).
	Plan_Field_Unknown  = 3, // A field of the plan other than roles, stores, values and locks (name).
	Not_A_Record        = 4, // roles, values, locks, or an owner, is no record literal (name).
	Role_Unknown        = 5, // A role that the role contract does not have (name).
	Role_Not_A_Module   = 6, // A role given something other than module(blake3:…) (name).
	Stores_Not_A_List   = 7,
	Store_Not_A_Store   = 8, // An item of stores that is no store(name, rights…).
	Store_Right_Unknown = 9, // A right other than .read and .write (name: the store, member: the right).
	Store_Right_Missing = 10, // No .read, or a right twice (name: the store).
	Owner_Unknown       = 11, // An owner that is no module of the image and no role with a holder (name).
	Field_Unknown       = 12, // A field that its owner does not describe (name, field).
	Value_Kind          = 13, // A value of another kind than its parameter (name, field, expected).
	Member_Unknown      = 14, // A member that the enum of the parameter does not have (name, field, member).
	Out_Of_Range        = 15, // A number outside the range of its parameter (name, field, integer, least, most).
	Text_Past_Bound     = 16, // A text outside the bound of its parameter, or past PLAN_VALUE_TEXT_BYTES (name, field, integer: its bytes, least, most).
	Text_Not_Plain      = 17, // A text that is not UTF-8, or holds a control byte (name, field).
	Default_And_Lock    = 18, // A field in values and in locks, or twice (name, field).
	Too_Many_Rows       = 19, // More rows than the rows given, which the region of one call bounds (integer: the rows given).
	Name_Not_Valid      = 20, // A name of an owner, a field or a store that a plan cannot hold (name, field).
	Field_Type          = 21, // A parameter that is no Integer, Enum or Text: a plan gives it no value (name, field).
	Owner_Is_A_Holder   = 22, // A module that holds a role: its values are named by the role (name, role).
}

// A refusal: its problem and what it names.
Refusal :: struct {
	problem:   Problem,
	name:      string, // The field of the plan, the role, the store or the owner.
	field:     string, // The field of the owner.
	member:    string, // A member or a right that is refused.
	integer:   i64,
	least:     i64,
	most:      i64,
	expected:  module.Type, // With Value_Kind: the type of the parameter.
	// With Field_Unknown and Member_Unknown: the description that names what
	// the owner has.
	file:      []u8,
	enum_type: module.Enum_Type,
	root:      bool, // With Field_Unknown: the owner is the core.
	role:      role_contract.Role, // With Owner_Is_A_Holder: the role that the module holds.
}

// The description of one value of an owner.
Described :: description.Described

// The state of one read.
@(private = "file")
Reader :: struct {
	evaluation:  ^lex_evaluator.Evaluation,
	image:       Image,
	rows:        []pr.Plan_Entry_Row,
	count:       int, // The rows written.
	entries:     int, // The entries written: the rows of a text are one entry.
	// The module of each role that the plan names: the owner of the role is
	// that module, else its default holder.
	holders:     description.Role_Holders,
}

// read gives the rows of a plan value. count is the rows written; on a
// refusal, the rows hold nothing that the caller may use.
read :: proc "contextless" (evaluation: ^lex_evaluator.Evaluation, plan_host: lex_evaluator.Host_Value, image: Image, rows: []pr.Plan_Entry_Row) -> (count: int, refusal: Refusal) {
	plan := plan_host.vm_value
	if plan.kind != .Plan_Value {
		return 0, {problem = .Not_A_Plan}
	}
	reader := Reader{evaluation = evaluation, image = image, rows = rows}
	names: [lex_evaluator.DECLARATION_RECORD_FIELDS_LIMIT]string
	name_count, names_ok := lex_evaluator.record_field_names(evaluation, plan, names[:])
	if !names_ok {
		return 0, {problem = .Not_A_Plan}
	}
	for name in names[:name_count] {
		if !has_field(PLAN_FIELDS[:], name) {
			return 0, {problem = .Plan_Field_Unknown, name = name}
		}
	}
	// The roles first: the owner of a role is the module that this plan
	// gives it, whatever the order of the fields.
	if has_field(names[:name_count], ROLES_FIELD) {
		if refusal = roles_read(&reader, plan); refusal.problem != .None {
			return 0, refusal
		}
	}
	if has_field(names[:name_count], STORES_FIELD) {
		if refusal = stores_read(&reader, plan); refusal.problem != .None {
			return 0, refusal
		}
	}
	Layer_Field :: struct {
		field: string,
		layer: chosen_values.Layer,
	}
	for item in ([2]Layer_Field{{VALUES_FIELD, .Plan_Default}, {LOCKS_FIELD, .Locked}}) {
		if !has_field(names[:name_count], item.field) {
			continue
		}
		if refusal = values_read(&reader, plan, item.field, item.layer); refusal.problem != .None {
			return 0, refusal
		}
	}
	return reader.count, {}
}

@(private = "file")
has_field :: proc "contextless" (names: []string, field: string) -> bool {
	for name in names {
		if name == field {
			return true
		}
	}
	return false
}

// field_of forces one field of a record of the plan.
@(private = "file")
field_of :: proc "contextless" (reader: ^Reader, record: lex_evaluator.Value, name: string) -> (value: lex_evaluator.Value, ok: bool) {
	return lex_evaluator.field_force(reader.evaluation, record, name, 0, lex_parser.NO_NODE)
}

// record_names gives the fields of a record literal of the plan.
@(private = "file")
record_names :: proc "contextless" (reader: ^Reader, record: lex_evaluator.Value, names: ^[lex_evaluator.DECLARATION_RECORD_FIELDS_LIMIT]string) -> (count: int, ok: bool) {
	if record.kind != .Record_Literal && record.kind != .Record_With {
		return 0, false
	}
	return lex_evaluator.record_field_names(reader.evaluation, record, names[:])
}

// row_add writes the rows of an entry: one, or one for each part of a
// text (pr.plan_rows_of_entry). The bound of a plan is its entries.
@(private = "file")
row_add :: proc "contextless" (reader: ^Reader, entry: ^pr.Plan_Entry) -> (refusal: Refusal) {
	room := len(reader.rows) - reader.count
	written := room > 0 ? pr.plan_rows_of_entry(entry, reader.rows[reader.count:][:room]) : 0
	if written == 0 {
		return {problem = .Too_Many_Rows, integer = i64(len(reader.rows))}
	}
	reader.count += written
	reader.entries += 1
	return {}
}

@(private = "file")
roles_read :: proc "contextless" (reader: ^Reader, plan: lex_evaluator.Value) -> (refusal: Refusal) {
	roles, ok := field_of(reader, plan, ROLES_FIELD)
	if !ok {
		return {problem = .Not_Read, name = ROLES_FIELD}
	}
	names: [lex_evaluator.DECLARATION_RECORD_FIELDS_LIMIT]string
	count, names_ok := record_names(reader, roles, &names)
	if !names_ok {
		return {problem = .Not_A_Record, name = ROLES_FIELD}
	}
	for name in names[:count] {
		role, known := role_contract.role_of_name(name)
		if !known {
			return {problem = .Role_Unknown, name = name}
		}
		holder, holder_ok := field_of(reader, roles, name)
		if !holder_ok {
			return {problem = .Not_Read, name = name}
		}
		if holder.kind != .Module_Ref {
			return {problem = .Role_Not_A_Module, name = name}
		}
		hash, hash_ok := lex_evaluator.hash_of(reader.evaluation, holder)
		if !hash_ok {
			return {problem = .Role_Not_A_Module, name = name}
		}
		entry, made := pr.plan_entry_make_role(name, role, hash)
		if !made {
			return {problem = .Name_Not_Valid, name = name}
		}
		reader.holders.hashes[role], reader.holders.given[role] = hash, true
		if refusal = row_add(reader, &entry); refusal.problem != .None {
			return refusal
		}
	}
	return {}
}

@(private = "file")
stores_read :: proc "contextless" (reader: ^Reader, plan: lex_evaluator.Value) -> (refusal: Refusal) {
	stores, ok := field_of(reader, plan, STORES_FIELD)
	if !ok {
		return {problem = .Not_Read, name = STORES_FIELD}
	}
	if stores.kind != .List {
		return {problem = .Stores_Not_A_List, name = STORES_FIELD}
	}
	for item in lex_evaluator.list_items_of(reader.evaluation, stores) {
		if item.kind != .Store_Ref {
			return {problem = .Store_Not_A_Store, name = STORES_FIELD}
		}
		store_name := lex_evaluator.value_store_name(reader.evaluation, item)
		read, write := false, false
		for right in lex_evaluator.list_items_of(reader.evaluation, item) {
			name := lex_evaluator.member_name_of(reader.evaluation, right)
			switch {
			case name == READ_RIGHT && !read:
				read = true
			case name == WRITE_RIGHT && !write:
				write = true
			case name == READ_RIGHT || name == WRITE_RIGHT:
				return {problem = .Store_Right_Missing, name = store_name}
			case:
				return {problem = .Store_Right_Unknown, name = store_name, member = name}
			}
		}
		if !read {
			return {problem = .Store_Right_Missing, name = store_name}
		}
		entry, made := pr.plan_entry_make_store(store_name, write ? .Read_Write : .Read_Only)
		if !made {
			return {problem = .Name_Not_Valid, name = store_name}
		}
		if refusal = row_add(reader, &entry); refusal.problem != .None {
			return refusal
		}
	}
	return {}
}

@(private = "file")
values_read :: proc "contextless" (reader: ^Reader, plan: lex_evaluator.Value, field: string, layer: chosen_values.Layer) -> (refusal: Refusal) {
	owners, ok := field_of(reader, plan, field)
	if !ok {
		return {problem = .Not_Read, name = field}
	}
	owner_names: [lex_evaluator.DECLARATION_RECORD_FIELDS_LIMIT]string
	owner_count, owners_ok := record_names(reader, owners, &owner_names)
	if !owners_ok {
		return {problem = .Not_A_Record, name = field}
	}
	for owner in owner_names[:owner_count] {
		values, values_ok := field_of(reader, owners, owner)
		if !values_ok {
			return {problem = .Not_Read, name = owner}
		}
		names: [lex_evaluator.DECLARATION_RECORD_FIELDS_LIMIT]string
		count, names_ok := record_names(reader, values, &names)
		if !names_ok {
			return {problem = .Not_A_Record, name = owner}
		}
		for name in names[:count] {
			value, value_ok := field_of(reader, values, name)
			if !value_ok {
				return {problem = .Not_Read, name = owner, field = name}
			}
			entry: pr.Plan_Entry
			if entry, refusal = value_entry(reader, owner, name, value, layer); refusal.problem != .None {
				return refusal
			}
			// A field once: in values or in locks, never both.
			for &earlier in reader.rows[:reader.count] {
				if earlier.kind_word == i64(pr.Plan_Entry_Kind.Value) && string(earlier.name[:entry.name_length]) == string(entry.name_bytes[:entry.name_length]) && (int(entry.name_length) == len(earlier.name) || earlier.name[entry.name_length] == 0) {
					return {problem = .Default_And_Lock, name = owner, field = name}
				}
			}
			if refusal = row_add(reader, &entry); refusal.problem != .None {
				return refusal
			}
		}
	}
	return {}
}

// value_entry types one value by the description of its owner and gives
// its entry (modus:contract/plan_value_description: the plans service
// checks the rows with the same description).
@(private = "file")
value_entry :: proc "contextless" (reader: ^Reader, owner, field: string, value: lex_evaluator.Value, layer: chosen_values.Layer) -> (entry: pr.Plan_Entry, refusal: Refusal) {
	if !chosen_values.name_valid(owner) || !chosen_values.name_valid(field) {
		return {}, {problem = .Name_Not_Valid, name = owner, field = field}
	}
	described, described_refusal := description.describe(reader.image, &reader.holders, owner, field)
	if described_refusal.problem != .None {
		return {}, refusal_of_description(described_refusal, owner, field)
	}
	at := Refusal{name = owner, field = field}
	made: bool
	#partial switch described.type {
	case .Integer:
		if value.kind != .Integer {
			at.problem, at.expected = .Value_Kind, .Integer
			return {}, at
		}
		iv := lex_evaluator.value_integer(value)
		if checked := description.word_check(described, u64(iv)); checked.problem != .None {
			return {}, refusal_of_description(checked, owner, field)
		}
		entry, made = pr.plan_entry_make_value(owner, field, u64(iv), layer)
	case .Enum:
		if value.kind != .Member {
			at.problem, at.expected = .Value_Kind, .Enum
			return {}, at
		}
		name := lex_evaluator.member_name_of(reader.evaluation, value)
		word, found := description.member_word_of_name(described, name)
		if !found {
			at.problem, at.member, at.enum_type, at.file = .Member_Unknown, name, described.enum_type, described.file
			return {}, at
		}
		entry, made = pr.plan_entry_make_value(owner, field, word, layer)
	case .Text:
		if value.kind != .Text {
			at.problem, at.expected = .Value_Kind, .Text
			return {}, at
		}
		txt := lex_evaluator.value_text(reader.evaluation, value)
		if checked := description.text_check(described, txt); checked.problem != .None {
			return {}, refusal_of_description(checked, owner, field)
		}
		entry, made = pr.plan_entry_make_text_value(owner, field, txt, layer)
	case:
		at.problem = .Field_Type
		return {}, at
	}
	if !made {
		return {}, {problem = .Name_Not_Valid, name = owner, field = field}
	}
	return entry, {}
}

// refusal_of_description gives the refusal of the reader of a refusal of
// the description of a value.
refusal_of_description :: proc "contextless" (from: description.Refusal, owner, field: string) -> (refusal: Refusal) {
	refusal = {name = owner, field = field, integer = from.integer, least = from.least, most = from.most, expected = from.expected, file = from.file, enum_type = from.enum_type, root = from.root, role = from.role}
	switch from.problem {
	case .None:
		refusal.problem = .None
	case .Owner_Unknown:
		refusal.problem = .Owner_Unknown
	case .Owner_Is_A_Holder:
		refusal.problem = .Owner_Is_A_Holder
	case .Field_Unknown:
		refusal.problem = .Field_Unknown
	case .Field_Type:
		refusal.problem = .Field_Type
	case .Value_Kind:
		refusal.problem = .Value_Kind
	case .Member_Unknown:
		refusal.problem = .Member_Unknown
	case .Out_Of_Range:
		refusal.problem = .Out_Of_Range
	case .Text_Past_Bound:
		refusal.problem = .Text_Past_Bound
	case .Text_Not_Plain:
		refusal.problem = .Text_Not_Plain
	}
	return refusal
}

// refusal_write writes the sentence of a refusal: what is wrong, and what
// the plan may name in its place.
refusal_write :: proc "contextless" (writer: ^sentence.Writer, refusal: Refusal) {
	part :: sentence.write_part
	owner_field :: proc "contextless" (writer: ^sentence.Writer, refusal: Refusal) {
		sentence.write_part(writer, refusal.name)
		sentence.write_part(writer, ".")
		sentence.write_part(writer, refusal.field)
	}
	switch refusal.problem {
	case .None:
	case .Not_A_Plan:
		part(writer, "the value is no plan: write plan { roles = …, stores = […], values = …, locks = … }")
	case .Not_Read:
		part(writer, "the plan did not give its field ")
		part(writer, refusal.name)
		if refusal.field != "" {
			part(writer, ".")
			part(writer, refusal.field)
		}
	case .Plan_Field_Unknown:
		part(writer, "the plan has no field ")
		part(writer, refusal.name)
		part(writer, ": its fields are roles, stores, values and locks")
	case .Not_A_Record:
		part(writer, refusal.name)
		part(writer, " is no record: write ")
		part(writer, refusal.name)
		part(writer, " = { name = value }")
	case .Role_Unknown:
		part(writer, "the plan names the role ")
		part(writer, refusal.name)
		part(writer, ", which no role contract has")
	case .Role_Not_A_Module:
		part(writer, "the role ")
		part(writer, refusal.name)
		part(writer, " is given no module: write ")
		part(writer, refusal.name)
		part(writer, " = module(blake3:…)")
	case .Stores_Not_A_List:
		part(writer, "stores is no list: write stores = [store(\"name\", .read)]")
	case .Store_Not_A_Store:
		part(writer, "an item of stores is no store: write store(\"name\", .read) or store(\"name\", .read, .write)")
	case .Store_Right_Unknown:
		part(writer, "the store ")
		part(writer, refusal.name)
		part(writer, " takes .read, or .read and .write, not .")
		part(writer, refusal.member)
	case .Store_Right_Missing:
		part(writer, "the store ")
		part(writer, refusal.name)
		part(writer, " takes .read, or .read and .write, each once")
	case .Owner_Unknown:
		part(writer, "the plan names the owner ")
		part(writer, refusal.name)
		part(writer, ", which is no module of the image and no role with a holder")
	case .Owner_Is_A_Holder:
		part(writer, "the module ")
		part(writer, refusal.name)
		part(writer, " holds the role ")
		part(writer, role_contract.role_properties(refusal.role).name)
		part(writer, ": name its values by the role, ")
		part(writer, role_contract.role_properties(refusal.role).name)
		part(writer, " = { … }")
	case .Field_Unknown:
		part(writer, "the owner ")
		part(writer, refusal.name)
		part(writer, " has no value ")
		part(writer, refusal.field)
		names_write(writer, refusal)
	case .Value_Kind:
		owner_field(writer, refusal)
		#partial switch refusal.expected {
		case .Enum:
			part(writer, " takes a member, as .name")
		case .Text:
			part(writer, " takes a text, in quotes")
		case:
			part(writer, " takes a number")
		}
	case .Member_Unknown:
		owner_field(writer, refusal)
		part(writer, " has no member .")
		part(writer, refusal.member)
		part(writer, ": its members are")
		for number in 0 ..< refusal.enum_type.member_count {
			member, ok := module.enum_member(refusal.file, refusal.enum_type, number)
			if !ok {
				continue
			}
			part(writer, number == 0 ? " ." : ", .")
			part(writer, module.string_at(refusal.file, member.name_offset, member.name_count))
		}
	case .Out_Of_Range:
		owner_field(writer, refusal)
		part(writer, " is ")
		part(writer, refusal.integer)
		part(writer, ", outside its range ")
		part(writer, refusal.least)
		part(writer, " to ")
		part(writer, refusal.most)
	case .Text_Past_Bound:
		owner_field(writer, refusal)
		part(writer, " has ")
		part(writer, refusal.integer)
		part(writer, " bytes, outside its bound of ")
		part(writer, refusal.least)
		part(writer, " to ")
		part(writer, refusal.most)
		part(writer, " bytes")
	case .Text_Not_Plain:
		owner_field(writer, refusal)
		part(writer, " is no text that a plan holds: it is not UTF-8, or it holds a control byte")
	case .Default_And_Lock:
		owner_field(writer, refusal)
		part(writer, " is in the plan twice: a value is a default in values, or a lock in locks, once")
	case .Too_Many_Rows:
		part(writer, "the plan has more than ")
		part(writer, refusal.integer)
		part(writer, " entries")
	case .Name_Not_Valid:
		part(writer, "the plan names ")
		part(writer, refusal.name)
		if refusal.field != "" {
			part(writer, ".")
			part(writer, refusal.field)
		}
		part(writer, ", which is no name that a plan holds: small letters, digits and _, at most 31 bytes")
	case .Field_Type:
		owner_field(writer, refusal)
		part(writer, " is no number, member or text: a plan gives it no value")
	}
}

// names_write writes the values that an owner has, after a field that it
// does not have.
@(private = "file")
names_write :: proc "contextless" (writer: ^sentence.Writer, refusal: Refusal) {
	sentence.write_part(writer, ": its values are")
	first := true
	put :: proc "contextless" (writer: ^sentence.Writer, first: ^bool, name: string) {
		sentence.write_part(writer, first^ ? " " : ", ")
		sentence.write_part(writer, name)
		first^ = false
	}
	if refusal.root {
		for item in root_plan_values.ROOT_FIELDS {
			put(writer, &first, item.name)
		}
		return
	}
	for export_name in description.DESCRIBING_EXPORTS {
		_, function, found := description.export_of_name(refusal.file, export_name)
		if !found {
			continue
		}
		for index in 0 ..< min(int(function.parameter_count), module.PARAMETER_CAPACITY) {
			put(writer, &first, module.string_at(refusal.file, function.parameter_names[index], u32(function.parameter_name_counts[index])))
		}
	}
	for item in root_plan_values.OWNER_FIELDS {
		put(writer, &first, item.name)
	}
}

// The fields of Plan_Entry_Row, as the description of an export must hold
// them for a plan to become its rows.
Row_Field :: struct {
	name:   string,
	offset: u32,
}

@(rodata)
ROW_FIELDS := [?]Row_Field {
	{"kind_word", u32(offset_of(pr.Plan_Entry_Row, kind_word))},
	{"role_word", u32(offset_of(pr.Plan_Entry_Row, role_word))},
	{"start_grants_mask", u32(offset_of(pr.Plan_Entry_Row, start_grants_mask))},
	{"store_rights_word", u32(offset_of(pr.Plan_Entry_Row, store_rights_word))},
	{"module_hash", u32(offset_of(pr.Plan_Entry_Row, module_hash))},
	{"interposed_over_hash", u32(offset_of(pr.Plan_Entry_Row, interposed_over_hash))},
	{"recipe_hash", u32(offset_of(pr.Plan_Entry_Row, recipe_hash))},
	{"name", u32(offset_of(pr.Plan_Entry_Row, name))},
	{"value_word", u32(offset_of(pr.Plan_Entry_Row, value_word))},
	{"value_layer_word", u32(offset_of(pr.Plan_Entry_Row, value_layer_word))},
	{"value_kind_word", u32(offset_of(pr.Plan_Entry_Row, value_kind_word))},
	{"value_text", u32(offset_of(pr.Plan_Entry_Row, value_text))},
}

// rows_layout_matches says if a record of a module file is Plan_Entry_Row:
// its size, and the name and the offset of each field, in order. The
// console converts a plan only for a table of such records.
rows_layout_matches :: proc "contextless" (file: []u8, record_index: u32) -> bool {
	described, ok := module.record_type(file, record_index)
	if !ok || described.size != size_of(pr.Plan_Entry_Row) || described.field_count != len(ROW_FIELDS) {
		return false
	}
	for expected, number in ROW_FIELDS {
		field, field_ok := module.field(file, described, u32(number))
		if !field_ok || field.offset != expected.offset || module.string_at(file, field.name_offset, field.name_count) != expected.name {
			return false
		}
	}
	return true
}
