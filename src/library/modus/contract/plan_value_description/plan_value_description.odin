// The description of a value of a plan (src/md/features/module_settings.md,
// "Plan records"): an owner gives the type of each of its values in the
// parameters of its export "set", else of its export "plan_only", and the
// core gives the type of its own values (root_plan_values). Two borders
// type a value by it: the console, which reads a plan that a principal
// writes (internal:console/plan_reader), and the plans service, which takes a plan as
// rows (entries_check). One description, one check.
//
// This package allocates no memory and calls no kernel operation: the
// caller gives the boot image.
package plan_value_description

import "modus:contract/blake3"
import "modus:contract/chosen_values"
import module "modus:contract/module"
import pr "modus:contract/plans_recipes"
import "modus:contract/role_contract"
import "modus:contract/root_plan_values"
import "modus:contract/value_kinds"

// The boot image as the description reads it: the module file of a name,
// or of a hash; an empty file for none.
Image :: struct {
	user:           rawptr,
	module_of_name: proc "contextless" (user: rawptr, name: string) -> []u8,
	module_of_hash: proc "contextless" (user: rawptr, hash: blake3.Hash) -> []u8,
}

// The holder of each role that a plan names: the owner of the role is that
// module, else its default holder.
Role_Holders :: struct {
	hashes: [role_contract.Role]blake3.Hash,
	given:  [role_contract.Role]bool,
}

// The exports whose parameters describe the values of an owner: its setter,
// then the description of its plan-only values.
@(rodata)
DESCRIBING_EXPORTS := [2]string{"set", "plan_only"}

// The description of one value of an owner.
Described :: struct {
	file:         []u8, // The module whose description it is; empty for a field of the core.
	type:         module.Type,
	enum_type:    module.Enum_Type,
	integer_unit: value_kinds.Integer_Unit,
	has_range:    bool,
	least:        i64,
	most:         i64,
}

// Why a value is refused at the border of a plan.
Problem :: enum u8 {
	None              = 0,
	Owner_Unknown     = 1, // An owner that is no module of the image and no role with a holder.
	Owner_Is_A_Holder = 2, // A module that holds a role: the plan names its values by the role (role).
	Field_Unknown     = 3, // A field that its owner does not describe (file, root).
	Field_Type        = 4, // A parameter that is no Integer, Enum or Text: a plan gives it no value.
	Value_Kind        = 5, // A value of another kind than its parameter (expected).
	Member_Unknown    = 6, // A word that names no member of the enum of the parameter (file, enum_type).
	Out_Of_Range      = 7, // A number outside the range of its parameter (integer, least, most).
	Text_Past_Bound   = 8, // A text outside the bound of its parameter, or past PLAN_VALUE_TEXT_BYTES (integer: its bytes, least, most).
	Text_Not_Plain    = 9, // A text that is not UTF-8, or holds a control byte.
}

// A refusal of one value: its problem and what it names.
Refusal :: struct {
	problem:   Problem,
	integer:   i64,
	least:     i64,
	most:      i64,
	expected:  module.Type,
	file:      []u8,
	enum_type: module.Enum_Type,
	root:      bool, // With Field_Unknown: the owner is the core.
	role:      role_contract.Role, // With Owner_Is_A_Holder: the role that the module holds.
}

// owner_file gives the module file that describes an owner: the module that
// the plan gives its role, the default holder of its role, or the module
// of its name. Empty: no module.
owner_file :: proc "contextless" (image: Image, holders: ^Role_Holders, owner: string) -> []u8 {
	if role, is_role := role_contract.role_of_name(owner); is_role {
		return holder_file(image, holders, role)
	}
	return image.module_of_name(image.user, owner)
}

// holder_file gives the module file of the holder of a role.
@(private = "file")
holder_file :: proc "contextless" (image: Image, holders: ^Role_Holders, role: role_contract.Role) -> []u8 {
	if holders.given[role] {
		return image.module_of_hash(image.user, holders.hashes[role])
	}
	holder := role_contract.DEFAULT_HOLDER_NAMES[role]
	if holder == "" {
		return nil
	}
	return image.module_of_name(image.user, holder)
}

// role_of_owner_module gives the role that the module of an owner holds,
// when the owner names a module and not a role. The core gives the values
// of the role to its holder, so values named by the module of the holder
// would reach nobody.
role_of_owner_module :: proc "contextless" (image: Image, holders: ^Role_Holders, owner: string) -> (role: role_contract.Role, holds: bool) {
	if _, is_role := role_contract.role_of_name(owner); is_role {
		return .None, false
	}
	file := image.module_of_name(image.user, owner)
	if len(file) == 0 {
		return .None, false
	}
	for candidate in role_contract.Role {
		if candidate == .None {
			continue
		}
		held := holder_file(image, holders, candidate)
		if len(held) == len(file) && raw_data(held) == raw_data(file) {
			return candidate, true
		}
	}
	return .None, false
}

@(private = "file")
root_field_unit :: proc "contextless" (field: string) -> value_kinds.Integer_Unit {
	switch field {
	case root_plan_values.BUDGET_GROWTH_PERIOD_MS_FIELD:
		return value_kinds.time_in(.Milliseconds)
	case root_plan_values.DISK_PROCESSES_PAGES_FIELD,
	     root_plan_values.BUDGET_PAGES_FIELD,
	     root_plan_values.BUDGET_CEILING_PAGES_FIELD,
	     root_plan_values.BUDGET_GROWTH_RESERVE_PAGES_FIELD,
	     root_plan_values.BUDGET_SCREEN_PAGES_FIELD:
		return value_kinds.size_in(.Pages)
	case root_plan_values.DISK_PROCESSES_PROCESSOR_FIELD,
	     root_plan_values.BUDGET_PROCESSOR_FIELD:
		return value_kinds.time_in(.Microseconds)
	case root_plan_values.STORE_BLOCKS_FIELD:
		return value_kinds.size_in(.Blocks)
	}
	return {}
}

// describe gives the description of a value of an owner: a field of the
// core from its contract, the quota of the store of an owner that exists,
// else the parameter of that name of the setter of the owner, else of its
// export plan_only.
describe :: proc "contextless" (image: Image, holders: ^Role_Holders, owner, field: string) -> (described: Described, refusal: Refusal) {
	if owner == root_plan_values.OWNER {
		if range, found := root_plan_values.field_range_of(owner, field); found {
			return {type = .Integer, integer_unit = root_field_unit(field), has_range = true, least = i64(range.least), most = i64(range.most)}, {}
		}
		// The core has no store or per-module budget row.
		return {}, {problem = .Field_Unknown, root = true}
	}
	if role, holds := role_of_owner_module(image, holders, owner); holds {
		return {}, {problem = .Owner_Is_A_Holder, role = role}
	}
	file := owner_file(image, holders, owner)
	if len(file) == 0 {
		return {}, {problem = .Owner_Unknown}
	}
	// Plan-only fields that the core reads for each owner: store_blocks and
	// the budget policy fields of root_plan_values.OWNER_FIELDS.
	if range, found := root_plan_values.field_range_of(owner, field); found {
		return {type = .Integer, integer_unit = root_field_unit(field), has_range = true, least = i64(range.least), most = i64(range.most)}, {}
	}
	for export_name in DESCRIBING_EXPORTS {
		export_index, function, found := export_of_name(file, export_name)
		if !found {
			continue
		}
		for index in 0 ..< min(int(function.parameter_count), module.PARAMETER_CAPACITY) {
			if module.string_at(file, function.parameter_names[index], u32(function.parameter_name_counts[index])) != field {
				continue
			}
			type, _ := module.function_parameter_type(function, index)
			described.type, described.file = type, file
			if type == .Integer {
				if unit, unit_ok := value_kinds.integer_unit_of_detail(function.parameter_details[index]); unit_ok {
					described.integer_unit = unit
				}
			}
			if type == .Enum {
				enum_index, _ := module.enum_detail_of(function.parameter_details[index])
				enum_type, problem := module.enum_type(file, enum_index)
				if problem != .None {
					return {}, {problem = .Field_Type}
				}
				described.enum_type = enum_type
			}
			if setting, has_setting := module.parameter_setting(file, export_index, index); has_setting && module.parameter_setting_ranged(setting) {
				described.has_range, described.least, described.most = true, setting.least, setting.most
			}
			return described, {}
		}
	}
	return {}, {problem = .Field_Unknown, file = file}
}

// export_of_name gives the export of a name of a module file.
export_of_name :: proc "contextless" (file: []u8, name: string) -> (export_index: u32, function: module.Function, found: bool) {
	for index in u32(1) ..< module.count(file, .Exports) {
		item, ok := module.function(file, index)
		if ok && module.string_at(file, item.name_offset, item.name_count) == name {
			return index, item, true
		}
	}
	return 0, {}, false
}

// member_word_of_name gives the word of a member of the enum of a value, by
// its name as the line writes it.
member_word_of_name :: proc "contextless" (described: Described, name: string) -> (word: u64, found: bool) {
	for number in 0 ..< described.enum_type.member_count {
		member, ok := module.enum_member(described.file, described.enum_type, number)
		if ok && module.string_at(described.file, member.name_offset, member.name_count) == name {
			return u64(member.value), true
		}
	}
	return 0, false
}

// word_check checks a word of a value against its description: a number in
// its range, a member of its enum. A Text takes no word.
word_check :: proc "contextless" (described: Described, word: u64) -> (refusal: Refusal) {
	#partial switch described.type {
	case .Integer:
		integer := i64(word)
		if described.has_range && (integer < described.least || integer > described.most) {
			return {problem = .Out_Of_Range, integer = integer, least = described.least, most = described.most}
		}
		return {}
	case .Enum:
		for number in 0 ..< described.enum_type.member_count {
			member, ok := module.enum_member(described.file, described.enum_type, number)
			if ok && u64(member.value) == word {
				return {}
			}
		}
		return {problem = .Member_Unknown, file = described.file, enum_type = described.enum_type}
	case .Text:
		return {problem = .Value_Kind, expected = .Text}
	}
	return {problem = .Field_Type}
}

// text_check checks a text of a value against its description: its bound,
// at most PLAN_VALUE_TEXT_BYTES, and plain UTF-8. An Integer and an Enum
// take no text.
text_check :: proc "contextless" (described: Described, text: string) -> (refusal: Refusal) {
	#partial switch described.type {
	case .Text:
	case .Integer, .Enum:
		return {problem = .Value_Kind, expected = described.type}
	case:
		return {problem = .Field_Type}
	}
	least := described.has_range ? described.least : 0
	most := described.has_range ? min(described.most, pr.PLAN_VALUE_TEXT_BYTES) : pr.PLAN_VALUE_TEXT_BYTES
	if i64(len(text)) < least || i64(len(text)) > most {
		return {problem = .Text_Past_Bound, integer = i64(len(text)), least = least, most = most}
	}
	if !pr.plan_value_text_valid(text) {
		return {problem = .Text_Not_Plain}
	}
	return {}
}

// holders_of_plan gives the holder of each role that a plan names: of a
// chain of interposition, the outermost module, which the callers reach.
// A first pass records each role's entry count and last index in O(entries),
// so roles with a single holder need no inner scan; only roles with multiple
// entries (interposition chains) resolve their outermost holder.
holders_of_plan :: proc "contextless" (plan: ^pr.Plan_Spec) -> (holders: Role_Holders) {
	count := int(plan.entry_count)
	role_counts: [role_contract.Role]int
	role_last: [role_contract.Role]int
	has_multi := false
	for index in 0 ..< count {
		entry := &plan.entries[index]
		if entry.kind_word != u64(pr.Plan_Entry_Kind.Role_Holder) {
			continue
		}
		role, ok := role_contract.role_from_word(entry.role_word)
		if !ok || role == .None {
			continue
		}
		role_counts[role] += 1
		role_last[role] = index
		if role_counts[role] > 1 {
			has_multi = true
		}
	}
	for role in role_contract.Role {
		if role_counts[role] == 1 {
			holders.hashes[role], holders.given[role] = plan.entries[role_last[role]].module_hash, true
		}
	}
	if !has_multi {
		return holders
	}
	for index in 0 ..< count {
		entry := &plan.entries[index]
		if entry.kind_word != u64(pr.Plan_Entry_Kind.Role_Holder) {
			continue
		}
		role, ok := role_contract.role_from_word(entry.role_word)
		if !ok || role == .None || role_counts[role] <= 1 {
			continue
		}
		outermost := true
		for other_index in 0 ..< count {
			other := &plan.entries[other_index]
			if other_index != index && other.kind_word == entry.kind_word && other.role_word == entry.role_word && other.interposed_over_hash == entry.module_hash {
				outermost = false
				break
			}
		}
		if outermost {
			holders.hashes[role], holders.given[role] = entry.module_hash, true
		}
	}
	return holders
}

// entries_check types each value of a plan by the description of its
// owner, as the console types a value that a principal writes: a plan
// whose rows name a word that its owner refuses is refused whole, with the
// entry that it names. index is the entry, from 0.
entries_check :: proc "contextless" (image: Image, plan: ^pr.Plan_Spec) -> (refusal: Refusal, index: u32) {
	holders := holders_of_plan(plan)
	for entry_index in u32(0) ..< plan.entry_count {
		entry := &plan.entries[entry_index]
		if entry.kind_word != u64(pr.Plan_Entry_Kind.Value) {
			continue
		}
		owner, field, parts_ok := pr.plan_value_parts(entry)
		if !parts_ok {
			return {problem = .Field_Unknown}, entry_index
		}
		described, described_refusal := describe(image, &holders, owner, field)
		if described_refusal.problem != .None {
			return described_refusal, entry_index
		}
		switch entry.value_kind_word {
		case u64(chosen_values.Entry_Kind.Word):
			refusal = word_check(described, entry.value_word)
		case u64(chosen_values.Entry_Kind.Text):
			refusal = text_check(described, pr.plan_value_text(entry))
		case:
			refusal = {problem = .Value_Kind, expected = described.type}
		}
		if refusal.problem != .None {
			return refusal, entry_index
		}
	}
	return {}, 0
}
