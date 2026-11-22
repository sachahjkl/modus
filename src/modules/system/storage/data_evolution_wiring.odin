// The border of a typed object and its derived migrations, bound into the
// storage service as internal helpers (src/md/features/data_evolution.md,
// "Where the migration runs").
//
// No export calls them: the design keeps the storage service a store of
// bytes that knows no record description, and a migration runs in the
// process that owns the store (src/md/features/data_evolution.md, "The
// refused forms"). They bind the contract package to the one copy of the
// object that the border checks, so that the owner reads and migrates only
// bytes that no other party can change after the check.
package storage_service

import "modus:contract/blake3"
import "modus:contract/data_evolution"

// The largest typed object that the border copies. An object past it is
// refused whole, never read in part.
TYPED_OBJECT_COPY_BYTES :: 64 * 1024

// Why a helper of this file refused a typed object. The record of the
// contract package says the detail.
Typed_Object_Refusal :: enum u8 {
	None                     = 0,
	Object_Too_Large         = 1, // More bytes than TYPED_OBJECT_COPY_BYTES.
	Invalid_Object           = 2, // The border refused the object: Typed_Object_Check.object_validation.
	Unknown_Description_Hash = 3, // A table has a description hash that the caller does not expect.
	Migration_Refused        = 4, // The migration refused: Typed_Object_Migration.migration.
}

// The outcome of storage_typed_object_validate.
Typed_Object_Check :: struct {
	refusal:           Typed_Object_Refusal,
	object_validation: data_evolution.Object_Validation_Result,
	table_index:       u32, // The table whose hash is unknown, for Unknown_Description_Hash.
	view:              data_evolution.Typed_Object_View, // Offsets into the checked copy.
	checked_copy:      []u8, // The checked copy; it holds until the next call of a helper of this file.
}

// The outcome of a migration helper. On a refusal, the helper wrote no byte
// of the output.
Typed_Object_Migration :: struct {
	refusal:   Typed_Object_Refusal,
	migration: data_evolution.Object_Migration_Result,
}

// The copy that the border checks. The service runs one thread
// (MODULE_BUDGET), so one copy serves each call, and the space is counted
// with the module, not taken from a stack.
@(private = "file")
typed_object_copy: [TYPED_OBJECT_COPY_BYTES]u8

// copy_typed_object copies bytes into typed_object_copy: the caller can
// change its region after a check of it, the copy it cannot.
@(private = "file")
copy_typed_object :: proc "contextless" (bytes: []u8) -> (copied: []u8, ok: bool) {
	if len(bytes) > TYPED_OBJECT_COPY_BYTES {
		return nil, false
	}
	count := copy(typed_object_copy[:], bytes)
	return typed_object_copy[:count], true
}

// storage_typed_object_validate copies a typed object and checks it at the
// border: its head, the canonical description of each table, each record,
// then the description hash of each table against expected_hashes, in the
// order of the tables. A table whose hash the caller does not expect is a
// refusal: the owner never writes over an object that it refused.
storage_typed_object_validate :: proc "contextless" (bytes: []u8, expected_hashes: []blake3.Hash) -> (check: Typed_Object_Check) {
	copied, copied_ok := copy_typed_object(bytes)
	if !copied_ok {
		check.refusal = .Object_Too_Large
		return check
	}
	view, validation := data_evolution.typed_object_validate(copied)
	if validation.err != .None {
		check.refusal = .Invalid_Object
		check.object_validation = validation
		check.table_index = validation.table_index
		return check
	}
	known, mismatched_table := data_evolution.typed_object_check_expected_hashes(&view, expected_hashes)
	if !known {
		check.refusal = .Unknown_Description_Hash
		check.table_index = mismatched_table
		return check
	}
	check.view = view
	check.checked_copy = copied
	return check
}

// storage_typed_object_migrate_forward runs the derived forward migration of
// each table of old_bytes into out_bytes. A description hash that is not the
// old description of its table, a plan that needs a declared migration, a
// refused record or an output too small refuses the whole object, and no
// byte of out_bytes changes.
storage_typed_object_migrate_forward :: proc "contextless" (
	old_bytes: []u8,
	table_specs: []data_evolution.Table_Migration_Spec,
	out_bytes: []u8,
) -> Typed_Object_Migration {
	return migrate_typed_object(old_bytes, table_specs, .Forward, out_bytes)
}

// storage_typed_object_migrate_backward runs the derived backward migration
// of each table of new_bytes into out_bytes, for a rollback of a plan. A
// value that does not fit its older field refuses the whole object: no
// clamp, no cut text, and no byte of out_bytes changes. The result names
// each stated loss for the principal to accept.
storage_typed_object_migrate_backward :: proc "contextless" (
	new_bytes: []u8,
	table_specs: []data_evolution.Table_Migration_Spec,
	out_bytes: []u8,
) -> Typed_Object_Migration {
	return migrate_typed_object(new_bytes, table_specs, .Backward, out_bytes)
}

@(private = "file")
migrate_typed_object :: proc "contextless" (
	source_bytes: []u8,
	table_specs: []data_evolution.Table_Migration_Spec,
	direction: data_evolution.Migration_Direction,
	out_bytes: []u8,
) -> (outcome: Typed_Object_Migration) {
	copied, copied_ok := copy_typed_object(source_bytes)
	if !copied_ok {
		outcome.refusal = .Object_Too_Large
		return outcome
	}
	outcome.migration = data_evolution.migration_apply_object(copied, table_specs, direction, out_bytes)
	switch outcome.migration.err {
	case .None:
		outcome.refusal = .None
	case .Invalid_Source_Object:
		outcome.refusal = .Invalid_Object
	case .Unknown_Description_Hash:
		outcome.refusal = .Unknown_Description_Hash
	case .Plan_Not_Executable, .Invalid_Record_Length, .Value_Does_Not_Fit, .Refused_Enum_Member, .Table_Count_Mismatch, .Requires_Declared_Migration, .Buffer_Too_Small, .Invalid_Declaration:
		outcome.refusal = .Migration_Refused
	}
	return outcome
}
