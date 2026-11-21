// Derived migration planner, fail-closed record and object executor, and
// pre-flight rollback loss checker (src/md/features/data_evolution.md,
// "The kinds of change" and "A rollback").
//
// Given an older description, a newer description, optional declared renames
// and enum member maps, and a migration direction (Forward or Backward), the
// planner classifies every schema change strictly per the contract table:
//   - Add field: derived zero default forward (requiring 0 to be a valid member
//     for Enum fields); derived drop with stated-loss tracking backward.
//   - Remove field: derived drop with stated-loss tracking forward; derived
//     zero default backward.
//   - Rename field/type (declared) or move offset: derived copy both ways.
//   - Type name changed without a declared rename: requires declared migration.
//   - Widen integer or Text: derived widen forward; derived fit-checked narrow
//     backward (refuses records whose value does not fit; no clamp, no cut).
//   - Change display-only kind (Plain <-> Hexadecimal): derived both ways.
//   - Narrow forward, change sign, change unit (Timestamp_Ms / Size_Pages),
//     change field type, change Bytes/Enum size, split/merge fields or tables:
//     requires declared migration in both directions.
//   - Add enum member: derived forward; requires explicit map or refusal
//     backward (never silently defaults to member 0).
//   - Remove enum member: requires explicit map forward; derived backward.
//
// Execution is fail-closed: any refused record leaves destination buffers
// completely untouched.
package data_evolution

import "modus:contract/blake3"
import "modus:contract/byte_order"

// Fixed capacities for plans and stated-loss reports.
MAX_RENAMES_PER_PLAN :: MAX_FIELDS_PER_TYPE
MAX_STATED_LOSS_FIELDS :: 64

// Direction of a migration relative to (old_description, new_description).
Migration_Direction :: enum u8 {
	Forward  = 0, // Transform records from old_description to new_description.
	Backward = 1, // Roll records back from new_description to old_description.
}

// Result of classifying a schema evolution between two descriptions.
Migration_Classification :: enum u8 {
	Derived                     = 0, // Executable by migration_apply_record and migration_apply_object.
	Requires_Declared_Migration = 1, // Breaking change requiring an author-written migration or explicit map.
	Invalid_Description         = 2, // One of the two descriptions failed validation.
	Invalid_Declaration         = 3, // A declared rename or enum map is malformed, stale, or invalid.
}

// Specific reason why migration_plan_derive did not produce a Derived plan.
Migration_Refusal_Reason :: enum u8 {
	None                       = 0,
	Type_Name_Changed          = 1,
	Field_Type_Changed         = 2,
	Field_Sign_Changed         = 3,
	Field_Unit_Changed         = 4,
	Field_Narrowed             = 5,
	Enum_Size_Changed          = 6,
	Enum_Member_Removed        = 7,
	Enum_Member_Changed        = 8,
	Enum_Added_Without_Zero    = 9,
	Field_Split_Or_Merge       = 10,
	Invalid_Source_Description = 11,
	Invalid_Target_Description = 12,
	Stale_Or_Missing_Rename    = 13,
	Invalid_Enum_Map           = 14,
}

// Why executing a migration plan on a record or typed object was refused.
Migration_Apply_Error :: enum u8 {
	None                        = 0,
	Plan_Not_Executable         = 1,
	Invalid_Record_Length       = 2,
	Value_Does_Not_Fit          = 3,
	Refused_Enum_Member         = 4,
	Invalid_Source_Object       = 5,
	Unknown_Description_Hash    = 6,
	Table_Count_Mismatch        = 7,
	Requires_Declared_Migration = 8,
	Buffer_Too_Small            = 9,
	Invalid_Declaration         = 10,
}

// One declared rename of a field from old_description to new_description.
Field_Rename :: struct {
	old_name: string,
	new_name: string,
}

// One declared mapping (or explicit per-record refusal) for an enum member
// value that exists in the source description and not in the target.
// field_name is the field's name in the source description (old_description for
// Forward, new_description for Backward).
Enum_Member_Map :: struct {
	field_name:   string,
	source_value: u64,
	target_value: u64,
	refuse:       bool, // When true, records holding source_value are refused cleanly.
}

// Author-declared metadata supplied to migration_plan_derive.
Migration_Declarations :: struct {
	type_renamed:  bool, // True when old_description.name -> new_description.name is a rename, not a meaning change.
	field_renames: []Field_Rename,
	enum_maps:     []Enum_Member_Map,
}

// Per-target-field operation inside a derived Migration_Plan.
Field_Migration_Operation :: enum u8 {
	Copy                  = 0,
	Zero_Default          = 1,
	Widen_Unsigned        = 2,
	Widen_Signed          = 3,
	Widen_Text            = 4,
	Narrow_Unsigned_Check = 5,
	Narrow_Signed_Check   = 6,
	Narrow_Text_Check     = 7,
	Map_Enum              = 8,
}

// One field transformation step inside a Migration_Plan.
Field_Migration_Step :: struct {
	operation:      Field_Migration_Operation,
	source_offset:  u32,
	source_size:    u32,
	target_offset:  u32,
	target_size:    u32,
	first_enum_map: u16,
	enum_map_count: u16,
}

// One source field dropped by a Migration_Plan, tracked for Stated_Loss.
Dropped_Field_Step :: struct {
	source_offset: u32,
	source_size:   u32,
	name:          [MAX_NAME_LENGTH]u8,
	name_length:   u8,
}

// Compiled per-member rule inside a Migration_Plan for Map_Enum steps.
Planned_Enum_Mapping :: struct {
	source_value: u64,
	target_value: u64,
	refuse:       bool,
}

// Compiled, self-contained plan for migrating records of one table.
Migration_Plan :: struct {
	classification:     Migration_Classification,
	reason:             Migration_Refusal_Reason,
	direction:          Migration_Direction,
	source_hash:        blake3.Hash,
	target_hash:        blake3.Hash,
	source_record_size: u32,
	target_record_size: u32,
	step_count:         u16,
	dropped_count:      u16,
	enum_map_count:     u16,
	steps:              [MAX_FIELDS_PER_TYPE]Field_Migration_Step,
	dropped_fields:     [MAX_FIELDS_PER_TYPE]Dropped_Field_Step,
	enum_maps:          [MAX_ENUM_MEMBERS_PER_TYPE]Planned_Enum_Mapping,
}

// Stated loss aggregated for one dropped field in one table.
Stated_Loss_Field :: struct {
	table_index:      u32,
	field_name:       [MAX_NAME_LENGTH]u8,
	field_name_length: u8,
	non_zero_records: u64, // Count of records where this dropped field held a non-zero value.
}

// Complete stated-loss summary across an object migration or rollback check.
Stated_Loss_Report :: struct {
	total_non_zero_values: u64, // Total non-zero dropped field values across all records and tables.
	affected_records:      u64, // Total records with at least one non-zero dropped field.
	field_count:           u32,
	fields:                [MAX_STATED_LOSS_FIELDS]Stated_Loss_Field,
	overflowed_fields:     u32, // Distinct dropped fields beyond MAX_STATED_LOSS_FIELDS (never silently dropped).
}

// Migration specification for one table of a MODTYPE1 typed object.
Table_Migration_Spec :: struct {
	old_description: ^Stored_Type_Description,
	new_description: ^Stored_Type_Description,
	declarations:    Migration_Declarations,
}

// Detailed outcome of migration_check_rollback or migration_apply_object.
Object_Migration_Result :: struct {
	err:               Migration_Apply_Error,
	refusal_reason:    Migration_Refusal_Reason,
	object_validation: Object_Validation_Result,
	table_index:       u32,
	record_index:      u32,
	mismatched_hash:   blake3.Hash, // Populated when err == .Unknown_Description_Hash.
	bytes_written:     int,         // Populated by migration_apply_object on success.
	losses:            Stated_Loss_Report,
}

// stated_loss_field_name returns the field name slice inside loss_field.
stated_loss_field_name :: proc "contextless" (loss_field: ^Stated_Loss_Field) -> string {
	length := min(int(loss_field.field_name_length), MAX_NAME_LENGTH)
	return string(loss_field.field_name[:length])
}

// find_field_by_name returns the index of the field with name in description,
// or -1 if absent.
@(private)
find_field_by_name :: proc "contextless" (description: ^Stored_Type_Description, name: string) -> int {
	for index in 0 ..< int(description.field_count) {
		if stored_field_name(&description.fields[index]) == name {
			return index
		}
	}
	return -1
}

// enum_field_has_exact_member reports whether field in description declares a
// member with both the exact name and exact value.
@(private)
enum_field_has_exact_member :: proc "contextless" (
	description: ^Stored_Type_Description,
	field: ^Stored_Field_Description,
	name: string,
	value: u64,
) -> bool {
	start := int(field.first_enum_member)
	end := start + int(field.enum_member_count)
	for index in start ..< end {
		member := &description.enum_members[index]
		if member.value == value && stored_enum_member_name(member) == name {
			return true
		}
	}
	return false
}

// enum_field_has_member_name reports whether field in description declares any
// member with the given name.
@(private)
enum_field_has_member_name :: proc "contextless" (
	description: ^Stored_Type_Description,
	field: ^Stored_Field_Description,
	name: string,
) -> bool {
	start := int(field.first_enum_member)
	end := start + int(field.enum_member_count)
	for index in start ..< end {
		if stored_enum_member_name(&description.enum_members[index]) == name {
			return true
		}
	}
	return false
}

// field_bytes_any_non_zero reports whether any byte in slice is non-zero.
// Under zero-is-initialization, a valid field is zero iff all its bytes are zero.
@(private)
field_bytes_any_non_zero :: proc "contextless" (bytes: []u8) -> bool {
	for value in bytes {
		if value != 0 {
			return true
		}
	}
	return false
}

// migration_plan_derive computes a Migration_Plan between old_description and
// new_description in the requested direction, classifying every change strictly
// per src/md/features/data_evolution.md.
migration_plan_derive :: proc "contextless" (
	old_description: ^Stored_Type_Description,
	new_description: ^Stored_Type_Description,
	declarations: Migration_Declarations = {},
	direction: Migration_Direction = .Forward,
) -> (plan: Migration_Plan) {
	plan.direction = direction

	if old_description == nil {
		plan.classification = .Invalid_Description
		plan.reason = .Invalid_Source_Description
		return plan
	}
	if new_description == nil {
		plan.classification = .Invalid_Description
		plan.reason = .Invalid_Target_Description
		return plan
	}

	old_hash, old_err := description_hash(old_description)
	if old_err != .None {
		plan.classification = .Invalid_Description
		plan.reason = direction == .Forward ? .Invalid_Source_Description : .Invalid_Target_Description
		return plan
	}
	new_hash, new_err := description_hash(new_description)
	if new_err != .None {
		plan.classification = .Invalid_Description
		plan.reason = direction == .Forward ? .Invalid_Target_Description : .Invalid_Source_Description
		return plan
	}

	source_desc: ^Stored_Type_Description
	target_desc: ^Stored_Type_Description
	switch direction {
	case .Forward:
		source_desc = old_description
		target_desc = new_description
		plan.source_hash = old_hash
		plan.target_hash = new_hash
	case .Backward:
		source_desc = new_description
		target_desc = old_description
		plan.source_hash = new_hash
		plan.target_hash = old_hash
	}
	plan.source_record_size = source_desc.record_size
	plan.target_record_size = target_desc.record_size

	// Check type name change: an undeclared type rename signals a change of meaning.
	same_type_name := stored_type_name(old_description) == stored_type_name(new_description)
	if !same_type_name && !declarations.type_renamed {
		plan.classification = .Requires_Declared_Migration
		plan.reason = .Type_Name_Changed
		return plan
	}
	if same_type_name && declarations.type_renamed {
		plan.classification = .Invalid_Declaration
		plan.reason = .Stale_Or_Missing_Rename
		return plan
	}

	// Build bidirectional field pairing between old_description and new_description.
	old_to_new: [MAX_FIELDS_PER_TYPE]int
	new_to_old: [MAX_FIELDS_PER_TYPE]int
	for index in 0 ..< MAX_FIELDS_PER_TYPE {
		old_to_new[index] = -1
		new_to_old[index] = -1
	}

	if len(declarations.field_renames) > MAX_RENAMES_PER_PLAN {
		plan.classification = .Invalid_Declaration
		plan.reason = .Stale_Or_Missing_Rename
		return plan
	}
	for rename in declarations.field_renames {
		if len(rename.old_name) == 0 || len(rename.new_name) == 0 || rename.old_name == rename.new_name {
			plan.classification = .Invalid_Declaration
			plan.reason = .Stale_Or_Missing_Rename
			return plan
		}
		old_idx := find_field_by_name(old_description, rename.old_name)
		new_idx := find_field_by_name(new_description, rename.new_name)
		if old_idx < 0 || new_idx < 0 {
			plan.classification = .Invalid_Declaration
			plan.reason = .Stale_Or_Missing_Rename
			return plan
		}
		if old_to_new[old_idx] != -1 || new_to_old[new_idx] != -1 {
			plan.classification = .Requires_Declared_Migration
			plan.reason = .Field_Split_Or_Merge
			return plan
		}
		old_to_new[old_idx] = new_idx
		new_to_old[new_idx] = old_idx
	}

	// Pair remaining fields by identical name.
	for old_idx in 0 ..< int(old_description.field_count) {
		if old_to_new[old_idx] != -1 {
			continue
		}
		old_name := stored_field_name(&old_description.fields[old_idx])
		new_idx := find_field_by_name(new_description, old_name)
		if new_idx < 0 {
			continue
		}
		if new_to_old[new_idx] != -1 {
			// Another field was renamed onto this name, colliding with an existing field.
			plan.classification = .Requires_Declared_Migration
			plan.reason = .Field_Split_Or_Merge
			return plan
		}
		old_to_new[old_idx] = new_idx
		new_to_old[new_idx] = old_idx
	}

	// Validate all declared enum_maps up front so typos and invalid targets fail immediately.
	for entry, entry_index in declarations.enum_maps {
		src_idx := find_field_by_name(source_desc, entry.field_name)
		if src_idx < 0 {
			plan.classification = .Invalid_Declaration
			plan.reason = .Invalid_Enum_Map
			return plan
		}
		src_field := &source_desc.fields[src_idx]
		if src_field.field_type != .Enum || !enum_field_contains_value(source_desc, src_field, entry.source_value) {
			plan.classification = .Invalid_Declaration
			plan.reason = .Invalid_Enum_Map
			return plan
		}
		tgt_idx := direction == .Forward ? old_to_new[src_idx] : new_to_old[src_idx]
		if tgt_idx < 0 {
			plan.classification = .Invalid_Declaration
			plan.reason = .Invalid_Enum_Map
			return plan
		}
		tgt_field := &target_desc.fields[tgt_idx]
		if tgt_field.field_type != .Enum {
			plan.classification = .Invalid_Declaration
			plan.reason = .Invalid_Enum_Map
			return plan
		}
		if !entry.refuse && !enum_field_contains_value(target_desc, tgt_field, entry.target_value) {
			plan.classification = .Invalid_Declaration
			plan.reason = .Invalid_Enum_Map
			return plan
		}
		for earlier_index in 0 ..< entry_index {
			earlier := declarations.enum_maps[earlier_index]
			if earlier.field_name == entry.field_name && earlier.source_value == entry.source_value {
				plan.classification = .Invalid_Declaration
				plan.reason = .Invalid_Enum_Map
				return plan
			}
		}
	}

	// Build one migration step for every target field.
	for target_idx in 0 ..< int(target_desc.field_count) {
		target_field := &target_desc.fields[target_idx]
		source_idx := direction == .Forward ? new_to_old[target_idx] : old_to_new[target_idx]

		// Field absent in source: synthesize zero default.
		if source_idx < 0 {
			if target_field.field_type == .Enum && !enum_field_contains_value(target_desc, target_field, 0) {
				plan.classification = .Requires_Declared_Migration
				plan.reason = .Enum_Added_Without_Zero
				return plan
			}
			plan.steps[plan.step_count] = {
				operation     = .Zero_Default,
				target_offset = target_field.offset,
				target_size   = target_field.size,
			}
			plan.step_count += 1
			continue
		}

		source_field := &source_desc.fields[source_idx]
		old_field := direction == .Forward ? source_field : target_field
		new_field := direction == .Forward ? target_field : source_field

		// Check field type and sign compatibility.
		if old_field.field_type != new_field.field_type {
			plan.classification = .Requires_Declared_Migration
			if stored_field_is_integer(old_field.field_type) && stored_field_is_integer(new_field.field_type) {
				plan.reason = .Field_Sign_Changed
			} else {
				plan.reason = .Field_Type_Changed
			}
			return plan
		}

		// Check field kind: Plain <-> Hexadecimal is display-only (derived); any
		// change involving a semantic unit requires a declared migration.
		if old_field.field_kind != new_field.field_kind {
			if stored_field_kind_is_unit(old_field.field_kind) || stored_field_kind_is_unit(new_field.field_kind) {
				plan.classification = .Requires_Declared_Migration
				plan.reason = .Field_Unit_Changed
				return plan
			}
		}

		step := Field_Migration_Step {
			source_offset = source_field.offset,
			source_size   = source_field.size,
			target_offset = target_field.offset,
			target_size   = target_field.size,
		}

		switch old_field.field_type {
		case .None:
			plan.classification = .Invalid_Description
			plan.reason = .Invalid_Source_Description
			return plan

		case .Unsigned_Int:
			if old_field.size == new_field.size {
				step.operation = .Copy
			} else if old_field.size < new_field.size {
				step.operation = direction == .Forward ? .Widen_Unsigned : .Narrow_Unsigned_Check
			} else {
				plan.classification = .Requires_Declared_Migration
				plan.reason = .Field_Narrowed
				return plan
			}

		case .Signed_Int:
			if old_field.size == new_field.size {
				step.operation = .Copy
			} else if old_field.size < new_field.size {
				step.operation = direction == .Forward ? .Widen_Signed : .Narrow_Signed_Check
			} else {
				plan.classification = .Requires_Declared_Migration
				plan.reason = .Field_Narrowed
				return plan
			}

		case .Text:
			if old_field.size == new_field.size {
				step.operation = .Copy
			} else if old_field.size < new_field.size {
				step.operation = direction == .Forward ? .Widen_Text : .Narrow_Text_Check
			} else {
				plan.classification = .Requires_Declared_Migration
				plan.reason = .Field_Narrowed
				return plan
			}

		case .Bytes:
			if old_field.size != new_field.size {
				plan.classification = .Requires_Declared_Migration
				plan.reason = .Field_Narrowed
				return plan
			}
			step.operation = .Copy

		case .Hash:
			step.operation = .Copy

		case .Enum:
			if old_field.size != new_field.size {
				plan.classification = .Requires_Declared_Migration
				plan.reason = .Enum_Size_Changed
				return plan
			}

			source_field_name := stored_field_name(source_field)
			first_map := plan.enum_map_count
			map_count := u16(0)

			member_start := int(source_field.first_enum_member)
			member_end := member_start + int(source_field.enum_member_count)
			for member_index in member_start ..< member_end {
				member := &source_desc.enum_members[member_index]
				member_name := stored_enum_member_name(member)

				// Check for an explicit declared mapping for this source member first.
				found_map := false
				matched_map: Enum_Member_Map
				for entry in declarations.enum_maps {
					if entry.field_name == source_field_name && entry.source_value == member.value {
						found_map = true
						matched_map = entry
						break
					}
				}
				if found_map {
					if int(plan.enum_map_count) >= MAX_ENUM_MEMBERS_PER_TYPE {
						plan.classification = .Invalid_Declaration
						plan.reason = .Invalid_Enum_Map
						return plan
					}
					plan.enum_maps[plan.enum_map_count] = {
						source_value = member.value,
						target_value = matched_map.target_value,
						refuse       = matched_map.refuse,
					}
					plan.enum_map_count += 1
					map_count += 1
					continue
				}

				if enum_field_has_exact_member(target_desc, target_field, member_name, member.value) {
					continue
				}

				// Source member is missing or changed in target without a declared map.
				plan.classification = .Requires_Declared_Migration
				if enum_field_has_member_name(target_desc, target_field, member_name) || enum_field_contains_value(target_desc, target_field, member.value) {
					plan.reason = .Enum_Member_Changed
				} else {
					plan.reason = .Enum_Member_Removed
				}
				return plan
			}

			if map_count == 0 {
				step.operation = .Copy
			} else {
				step.operation = .Map_Enum
				step.first_enum_map = first_map
				step.enum_map_count = map_count
			}
		}

		plan.steps[plan.step_count] = step
		plan.step_count += 1
	}

	// Record every dropped source field for Stated_Loss accounting.
	for source_idx in 0 ..< int(source_desc.field_count) {
		target_idx := direction == .Forward ? old_to_new[source_idx] : new_to_old[source_idx]
		if target_idx >= 0 {
			continue
		}
		source_field := &source_desc.fields[source_idx]
		dropped := &plan.dropped_fields[plan.dropped_count]
		dropped^ = {
			source_offset = source_field.offset,
			source_size   = source_field.size,
			name          = source_field.name,
			name_length   = source_field.name_length,
		}
		plan.dropped_count += 1
	}

	plan.classification = .Derived
	plan.reason = .None
	return plan
}

// migration_apply_record executes a Derived Migration_Plan on one source record
// into destination_record. On any refusal, destination_record is untouched.
// Returns the count of dropped fields in this record that held a non-zero value.
migration_apply_record :: proc "contextless" (
	plan: ^Migration_Plan,
	source_record: []u8,
	destination_record: []u8,
) -> (err: Migration_Apply_Error, non_zero_dropped_fields: u32) {
	if plan.classification != .Derived {
		return .Plan_Not_Executable, 0
	}
	if len(source_record) != int(plan.source_record_size) || len(destination_record) != int(plan.target_record_size) {
		return .Invalid_Record_Length, 0
	}
	if plan.target_record_size > MAX_RECORD_SIZE {
		return .Invalid_Record_Length, 0
	}

	// Stage into a zeroed stack buffer so destination_record is never modified
	// if any step refuses the record, and every padding or Zero_Default byte is 0.
	staged: [MAX_RECORD_SIZE]u8

	for step_index in 0 ..< int(plan.step_count) {
		step := &plan.steps[step_index]
		switch step.operation {
		case .Copy:
			copy(staged[step.target_offset:][:step.target_size], source_record[step.source_offset:][:step.source_size])

		case .Zero_Default:
			// Already zeroed in staged.

		case .Widen_Unsigned:
			value := read_unsigned_little_endian(source_record, step.source_offset, step.source_size)
			write_unsigned_little_endian(staged[:], step.target_offset, step.target_size, value)

		case .Widen_Signed:
			value := read_signed_little_endian(source_record, step.source_offset, step.source_size)
			write_signed_little_endian(staged[:], step.target_offset, step.target_size, value)

		case .Widen_Text:
			copy(staged[step.target_offset:][:step.source_size], source_record[step.source_offset:][:step.source_size])

		case .Narrow_Unsigned_Check:
			value := read_unsigned_little_endian(source_record, step.source_offset, step.source_size)
			if !unsigned_fits_in_size(value, step.target_size) {
				return .Value_Does_Not_Fit, 0
			}
			write_unsigned_little_endian(staged[:], step.target_offset, step.target_size, value)

		case .Narrow_Signed_Check:
			value := read_signed_little_endian(source_record, step.source_offset, step.source_size)
			if !signed_fits_in_size(value, step.target_size) {
				return .Value_Does_Not_Fit, 0
			}
			write_signed_little_endian(staged[:], step.target_offset, step.target_size, value)

		case .Narrow_Text_Check:
			source_slice := source_record[step.source_offset:][:step.source_size]
			text_len := text_field_length(source_slice)
			if text_len > int(step.target_size) {
				return .Value_Does_Not_Fit, 0
			}
			copy(staged[step.target_offset:][:text_len], source_slice[:text_len])

		case .Map_Enum:
			value := read_unsigned_little_endian(source_record, step.source_offset, step.source_size)
			map_start := int(step.first_enum_map)
			map_end := map_start + int(step.enum_map_count)
			for map_index in map_start ..< map_end {
				mapping := &plan.enum_maps[map_index]
				if mapping.source_value == value {
					if mapping.refuse {
						return .Refused_Enum_Member, 0
					}
					value = mapping.target_value
					break
				}
			}
			write_unsigned_little_endian(staged[:], step.target_offset, step.target_size, value)
		}
	}

	// Count non-zero dropped fields in this record.
	dropped_non_zero := u32(0)
	for drop_index in 0 ..< int(plan.dropped_count) {
		dropped := &plan.dropped_fields[drop_index]
		if field_bytes_any_non_zero(source_record[dropped.source_offset:][:dropped.source_size]) {
			dropped_non_zero += 1
		}
	}

	copy(destination_record, staged[:plan.target_record_size])
	return .None, dropped_non_zero
}

// dry_run_record_check checks whether plan accepts source_record without writing
// to any output buffer, and updates per-dropped-field stated-loss counters.
@(private)
dry_run_record_check :: proc "contextless" (
	plan: ^Migration_Plan,
	source_record: []u8,
	table_index: u32,
	losses: ^Stated_Loss_Report,
	drop_slot_indices: ^[MAX_FIELDS_PER_TYPE]int,
) -> Migration_Apply_Error {
	for step_index in 0 ..< int(plan.step_count) {
		step := &plan.steps[step_index]
		switch step.operation {
		case .Copy, .Zero_Default, .Widen_Unsigned, .Widen_Signed, .Widen_Text:
			// Always succeeds on a validated record.
		case .Narrow_Unsigned_Check:
			value := read_unsigned_little_endian(source_record, step.source_offset, step.source_size)
			if !unsigned_fits_in_size(value, step.target_size) {
				return .Value_Does_Not_Fit
			}
		case .Narrow_Signed_Check:
			value := read_signed_little_endian(source_record, step.source_offset, step.source_size)
			if !signed_fits_in_size(value, step.target_size) {
				return .Value_Does_Not_Fit
			}
		case .Narrow_Text_Check:
			source_slice := source_record[step.source_offset:][:step.source_size]
			if text_field_length(source_slice) > int(step.target_size) {
				return .Value_Does_Not_Fit
			}
		case .Map_Enum:
			value := read_unsigned_little_endian(source_record, step.source_offset, step.source_size)
			map_start := int(step.first_enum_map)
			map_end := map_start + int(step.enum_map_count)
			for map_index in map_start ..< map_end {
				mapping := &plan.enum_maps[map_index]
				if mapping.source_value == value {
					if mapping.refuse {
						return .Refused_Enum_Member
					}
					break
				}
			}
		}
	}

	record_lost_any := false
	for drop_index in 0 ..< int(plan.dropped_count) {
		dropped := &plan.dropped_fields[drop_index]
		if !field_bytes_any_non_zero(source_record[dropped.source_offset:][:dropped.source_size]) {
			continue
		}
		record_lost_any = true
		losses.total_non_zero_values += 1

		slot := drop_slot_indices[drop_index]
		if slot < 0 {
			if int(losses.field_count) < MAX_STATED_LOSS_FIELDS {
				slot = int(losses.field_count)
				drop_slot_indices[drop_index] = slot
				losses.fields[slot] = {
					table_index       = table_index,
					field_name        = dropped.name,
					field_name_length = dropped.name_length,
					non_zero_records  = 1,
				}
				losses.field_count += 1
			} else {
				// Mark overflow once per distinct dropped field beyond capacity.
				drop_slot_indices[drop_index] = -2
				losses.overflowed_fields += 1
			}
		} else if slot >= 0 {
			losses.fields[slot].non_zero_records += 1
		}
	}
	if record_lost_any {
		losses.affected_records += 1
	}
	return .None
}

// preflight_object_migration validates source_object_bytes, verifies every table's
// computed description hash against its derived plan, dry-runs every record to
// check fit and collect exact Stated_Loss totals, and returns the required
// target MODTYPE1 byte size. Writes nothing to any output buffer.
@(private)
preflight_object_migration :: proc "contextless" (
	source_object_bytes: []u8,
	table_specs: []Table_Migration_Spec,
	direction: Migration_Direction,
) -> (view: Typed_Object_View, required_target_bytes: int, result: Object_Migration_Result) {
	val_result: Object_Validation_Result
	view, val_result = typed_object_validate(source_object_bytes)
	if val_result.err != .None {
		result.err = .Invalid_Source_Object
		result.object_validation = val_result
		result.table_index = val_result.table_index
		result.record_index = val_result.record_index
		return {}, 0, result
	}

	if int(view.table_count) != len(table_specs) {
		result.err = .Table_Count_Mismatch
		return {}, 0, result
	}

	// Ensure target table names remain distinct across the migrated object.
	target_names: [MAX_TABLES_PER_OBJECT][MAX_NAME_LENGTH]u8
	target_name_lengths: [MAX_TABLES_PER_OBJECT]u8

	total_bytes := u64(TYPED_OBJECT_HEADER_SIZE)
	plan: Migration_Plan

	for table_index in 0 ..< len(table_specs) {
		spec := table_specs[table_index]
		if spec.old_description == nil || spec.new_description == nil {
			result.err = .Invalid_Declaration
			result.table_index = u32(table_index)
			return {}, 0, result
		}

		plan = migration_plan_derive(spec.old_description, spec.new_description, spec.declarations, direction)
		switch plan.classification {
		case .Derived:
		case .Requires_Declared_Migration:
			result.err = .Requires_Declared_Migration
			result.refusal_reason = plan.reason
			result.table_index = u32(table_index)
			return {}, 0, result
		case .Invalid_Description, .Invalid_Declaration:
			result.err = .Invalid_Declaration
			result.refusal_reason = plan.reason
			result.table_index = u32(table_index)
			return {}, 0, result
		}

		table_view := &view.tables[table_index]
		if table_view.description_hash != plan.source_hash {
			result.err = .Unknown_Description_Hash
			result.table_index = u32(table_index)
			result.mismatched_hash = table_view.description_hash
			return {}, 0, result
		}

		target_desc := direction == .Forward ? spec.new_description : spec.old_description
		target_name := stored_type_name(target_desc)
		for earlier in 0 ..< table_index {
			if string(target_names[earlier][:target_name_lengths[earlier]]) == target_name {
				result.err = .Invalid_Declaration
				result.table_index = u32(table_index)
				return {}, 0, result
			}
		}
		copy(target_names[table_index][:], target_name)
		target_name_lengths[table_index] = u8(len(target_name))

		target_desc_size, _ := description_encoded_size(target_desc)
		target_rows_bytes := u64(table_view.record_count) * u64(plan.target_record_size)
		table_addition := u64(4) + u64(target_desc_size) + u64(4) + target_rows_bytes
		if total_bytes > u64(max(int)) - table_addition {
			result.err = .Buffer_Too_Small
			result.table_index = u32(table_index)
			return {}, 0, result
		}
		total_bytes += table_addition

		// Dry-run every record in this table to verify fit and count stated losses.
		drop_slot_indices: [MAX_FIELDS_PER_TYPE]int
		for index in 0 ..< MAX_FIELDS_PER_TYPE {
			drop_slot_indices[index] = -1
		}
		src_stride := int(table_view.record_size)
		rows_start := int(table_view.records_offset)
		for record_index in 0 ..< int(table_view.record_count) {
			row := source_object_bytes[rows_start + record_index * src_stride:][:src_stride]
			row_err := dry_run_record_check(&plan, row, u32(table_index), &result.losses, &drop_slot_indices)
			if row_err != .None {
				result.err = row_err
				result.table_index = u32(table_index)
				result.record_index = u32(record_index)
				return {}, 0, result
			}
		}
	}

	return view, int(total_bytes), result
}

// migration_check_rollback inspects a MODTYPE1 object before a rollback is
// confirmed: it validates the object, verifies that every table has a derived
// backward migration matching its computed description hash, checks that every
// record fits, and reports every Stated_Loss across all tables and records.
migration_check_rollback :: proc "contextless" (
	source_object_bytes: []u8,
	table_specs: []Table_Migration_Spec,
) -> (result: Object_Migration_Result) {
	_, _, result = preflight_object_migration(source_object_bytes, table_specs, .Backward)
	return result
}

// migration_apply_object migrates an entire MODTYPE1 typed object in direction
// (Forward or Backward) into out_buffer.
//
// Fail-closed: if source_object_bytes fails validation, any table hash mismatches,
// any table requires a declared migration, any record refuses to fit or hits a
// refused enum member, or out_buffer is too small, out_buffer is left untouched.
migration_apply_object :: proc "contextless" (
	source_object_bytes: []u8,
	table_specs: []Table_Migration_Spec,
	direction: Migration_Direction,
	out_buffer: []u8,
) -> (result: Object_Migration_Result) {
	view, required_bytes, preflight_result := preflight_object_migration(source_object_bytes, table_specs, direction)
	if preflight_result.err != .None {
		return preflight_result
	}
	if len(out_buffer) < required_bytes {
		preflight_result.err = .Buffer_Too_Small
		return preflight_result
	}

	// All validation, hash checks, record checks, and capacity checks passed.
	// Emit the target MODTYPE1 container.
	magic := TYPED_OBJECT_MAGIC
	copy(out_buffer[0:8], magic[:])
	byte_order.write_u32_little_endian(out_buffer, 8, TYPED_OBJECT_VERSION)
	byte_order.write_u32_little_endian(out_buffer, 12, view.table_count)
	cursor := TYPED_OBJECT_HEADER_SIZE

	// Descriptions section.
	for table_index in 0 ..< len(table_specs) {
		spec := table_specs[table_index]
		target_desc := direction == .Forward ? spec.new_description : spec.old_description
		desc_size, _ := description_encoded_size(target_desc)
		byte_order.write_u32_little_endian(out_buffer, cursor, u32(desc_size))
		cursor += 4
		written, _ := description_encode(target_desc, out_buffer[cursor:][:desc_size])
		cursor += written
	}

	// Records section.
	plan: Migration_Plan
	for table_index in 0 ..< len(table_specs) {
		spec := table_specs[table_index]
		plan = migration_plan_derive(spec.old_description, spec.new_description, spec.declarations, direction)
		table_view := &view.tables[table_index]

		byte_order.write_u32_little_endian(out_buffer, cursor, table_view.record_count)
		cursor += 4

		src_stride := int(table_view.record_size)
		dst_stride := int(plan.target_record_size)
		rows_start := int(table_view.records_offset)
		for record_index in 0 ..< int(table_view.record_count) {
			src_row := source_object_bytes[rows_start + record_index * src_stride:][:src_stride]
			dst_row := out_buffer[cursor:][:dst_stride]
			_, _ = migration_apply_record(&plan, src_row, dst_row)
			cursor += dst_stride
		}
	}

	preflight_result.bytes_written = cursor
	return preflight_result
}
