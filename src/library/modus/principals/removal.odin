package principals

import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Durable state machine for self-removal of a named principal
// (src/md/features/several_principals.md, "The rest").
//
// Before the first destructive step, `unlock` writes `REMOVAL_OBJECT` in its
// store with step `Marked`, then steps strictly through:
//   Marked -> Keys_Erased -> File_Deleted -> Stores_Marked -> Pin_Freed -> Complete.
// Erasing the versions of the principal file and recovery file cryptographically
// destroys the principal's key material so all encrypted stores of the principal
// are permanently unreadable; `Stores_Marked` asks the storage service (through
// the root service) to durably mark every store owned by `identifier` as
// `RECLAIMING_CELL_MARK` so storage reclaims all orphaned trees and blocks
// keylessly across crashes and reboots. A crash or power loss at any point
// leaves the durable record on disk; the next boot reads it and resumes from
// the recorded step idempotently.
//
// A slot freed by removal is retired for the remainder of the current run so
// no stale connection handle can ever alias a newly created principal; after
// reboot, creation advances the TPM pin from Free(g) to Active(B, g + 1).

REMOVAL_OBJECT :: "principal_removing"
REMOVAL_MAGIC :: "MODUSRMV"
REMOVAL_FORMAT :: u32(1)

REMOVAL_OFFSET_MAGIC :: 0 // 8 bytes
REMOVAL_OFFSET_FORMAT :: 8 // u32
REMOVAL_OFFSET_SLOT :: 12 // u32 (named principal slot >= 1)
REMOVAL_OFFSET_STEP :: 16 // u8 (Removal_Step)
REMOVAL_OFFSET_RESERVED :: 17 // 7 zero bytes
REMOVAL_OFFSET_GENERATION :: 24 // u64 (pin generation before freeing, or 0 without TPM)
REMOVAL_OFFSET_IDENTIFIER :: 32 // 32 bytes (Principal_Identifier)
REMOVAL_RECORD_SIZE :: 64
#assert(REMOVAL_RECORD_SIZE == REMOVAL_OFFSET_IDENTIFIER + PRINCIPAL_IDENTIFIER_SIZE)

// Durable step recorded on disk during principal removal.
Removal_Step :: enum u8 {
	Marked        = 1, // Removal authorized and durably recorded before first destructive step.
	Keys_Erased   = 2, // Principal key material and recovery file versions erased (cryptographic erasure of encrypted stores).
	File_Deleted  = 3, // The principal file object has been removed from unlock's store.
	Stores_Marked = 4, // Storage service durably marked all orphaned stores of the principal for keyless block reclamation.
	Pin_Freed     = 5, // The TPM NV pin holds "free, generation g" (or no TPM pin existed).
}

// Next idempotent action to execute for a durable removal record.
Removal_Action :: enum u8 {
	Erase_Keys   = 1,
	Delete_File  = 2,
	Mark_Stores  = 3,
	Free_Pin     = 4,
	Clear_Marker = 5,
}

// Durable removal record stored in `REMOVAL_OBJECT`.
Removal_Record :: struct {
	slot:           u32,
	step:           Removal_Step,
	pin_generation: u64,
	identifier:     Principal_Identifier,
}

// Why decoding or advancing a Removal_Record was refused.
Removal_Problem :: enum u8 {
	None            = 0,
	Wrong_Size      = 1,
	Wrong_Magic     = 2,
	Wrong_Format    = 3,
	Bad_Slot        = 4,
	Bad_Step        = 5,
	Reserved_Set    = 6,
	Zero_Identifier = 7,
	Bad_Transition  = 8,
}

// removal_record_encode serializes a validated Removal_Record into 64 bytes.
removal_record_encode :: proc "contextless" (record: Removal_Record, out: ^[REMOVAL_RECORD_SIZE]u8) -> Removal_Problem {
	if record.slot == MACHINE {
		return .Bad_Slot
	}
	if _, ok := enum_word.member_of_word(Removal_Step, u64(record.step)); !ok {
		return .Bad_Step
	}
	ident := record.identifier
	if identifier_is_zero(ident[:]) {
		return .Zero_Identifier
	}
	out^ = {}
	copy(out^[REMOVAL_OFFSET_MAGIC:][:8], REMOVAL_MAGIC)
	byte_order.write_u32_little_endian(out^[REMOVAL_OFFSET_FORMAT:], 0, REMOVAL_FORMAT)
	byte_order.write_u32_little_endian(out^[REMOVAL_OFFSET_SLOT:], 0, record.slot)
	out^[REMOVAL_OFFSET_STEP] = u8(record.step)
	byte_order.write_u64_little_endian(out^[REMOVAL_OFFSET_GENERATION:], 0, record.pin_generation)
	copy(out^[REMOVAL_OFFSET_IDENTIFIER:][:PRINCIPAL_IDENTIFIER_SIZE], ident[:])
	return .None
}

// removal_record_decode validates and parses 64 hostile bytes from disk.
removal_record_decode :: proc "contextless" (bytes: []u8) -> (record: Removal_Record, problem: Removal_Problem) {
	if len(bytes) != REMOVAL_RECORD_SIZE {
		return {}, .Wrong_Size
	}
	if string(bytes[REMOVAL_OFFSET_MAGIC:][:8]) != REMOVAL_MAGIC {
		return {}, .Wrong_Magic
	}
	if byte_order.read_u32_little_endian(bytes[REMOVAL_OFFSET_FORMAT:], 0) != REMOVAL_FORMAT {
		return {}, .Wrong_Format
	}
	slot := byte_order.read_u32_little_endian(bytes[REMOVAL_OFFSET_SLOT:], 0)
	if slot == MACHINE {
		return {}, .Bad_Slot
	}
	step, step_ok := enum_word.member_of_word(Removal_Step, u64(bytes[REMOVAL_OFFSET_STEP]))
	if !step_ok {
		return {}, .Bad_Step
	}
	for b in bytes[REMOVAL_OFFSET_RESERVED:REMOVAL_OFFSET_GENERATION] {
		if b != 0 {
			return {}, .Reserved_Set
		}
	}
	if identifier_is_zero(bytes[REMOVAL_OFFSET_IDENTIFIER:][:PRINCIPAL_IDENTIFIER_SIZE]) {
		return {}, .Zero_Identifier
	}
	record.slot = slot
	record.step = step
	record.pin_generation = byte_order.read_u64_little_endian(bytes[REMOVAL_OFFSET_GENERATION:], 0)
	copy(record.identifier[:], bytes[REMOVAL_OFFSET_IDENTIFIER:][:PRINCIPAL_IDENTIFIER_SIZE])
	return record, .None
}

// removal_step_advance advances a durable Removal_Record by strictly one
// forward step, refusing skipped steps, rollbacks, or mismatched identities.
removal_step_advance :: proc "contextless" (current: Removal_Record, next_step: Removal_Step) -> (updated: Removal_Record, problem: Removal_Problem) {
	if current.slot == MACHINE {
		return current, .Bad_Slot
	}
	ident := current.identifier
	if identifier_is_zero(ident[:]) {
		return current, .Zero_Identifier
	}
	valid := false
	switch current.step {
	case .Marked:
		valid = next_step == .Keys_Erased
	case .Keys_Erased:
		valid = next_step == .File_Deleted
	case .File_Deleted:
		valid = next_step == .Stores_Marked
	case .Stores_Marked:
		valid = next_step == .Pin_Freed
	case .Pin_Freed:
		valid = false
	}
	if !valid {
		return current, .Bad_Transition
	}
	updated = current
	updated.step = next_step
	return updated, .None
}

// removal_next_action returns the next idempotent action required to finish
// or resume a durable removal from `record.step`.
removal_next_action :: proc "contextless" (record: Removal_Record, has_tpm_pin: bool) -> Removal_Action {
	switch record.step {
	case .Marked:
		return .Erase_Keys
	case .Keys_Erased:
		return .Delete_File
	case .File_Deleted:
		return .Mark_Stores
	case .Stores_Marked:
		return has_tpm_pin ? .Free_Pin : .Clear_Marker
	case .Pin_Freed:
		return .Clear_Marker
	}
	return .Erase_Keys
}

// Tracks principal slots freed by removal during the current boot run so
// they are never reused before a reboot.
Retired_Slots :: struct {
	retired: [PRINCIPAL_CAPACITY]bool,
}

// slot_retire marks a named principal slot as unavailable for creation until
// the next boot.
slot_retire :: proc "contextless" (slots: ^Retired_Slots, slot: u64) -> bool {
	if slots == nil || slot == MACHINE || slot >= PRINCIPAL_CAPACITY {
		return false
	}
	slots.retired[slot] = true
	return true
}

// slot_creation_allowed reports whether `slot` may accept a new principal in
// this run.
slot_creation_allowed :: proc "contextless" (slots: ^Retired_Slots, slot: u64) -> bool {
	if slots == nil || slot == MACHINE || slot >= PRINCIPAL_CAPACITY {
		return false
	}
	return !slots.retired[slot]
}

// Why a grant-authorized removal of a named principal was refused.
Removal_By_Grant_Refusal :: enum u8 {
	None             = 0,
	Actor_Not_Named  = 1, // Principal 0 or out-of-range actor cannot invoke grant removal.
	Target_Not_Named = 2, // Principal 0 or out-of-range target cannot be removed.
	Missing_Grant    = 3, // Actor does not hold the Principals machine grant scope.
	Target_Absent    = 4, // Target slot has no recorded named principal.
	Last_System_Grant = 5, // Target is the sole System holder while another named principal remains.
}

// removal_by_grant_allowed decides whether `actor_slot` may remove
// `target_slot` without target's consent. Enforces named actor and target,
// active Principals machine grant on actor, target presence, and the invariant
// that the last System holder is never removed while another named principal
// remains.
removal_by_grant_allowed :: proc "contextless" (
	actor_slot: u64,
	target_slot: u64,
	actor_holds_principals: bool,
	target_exists: bool,
	target_holds_system: bool,
	system_holder_count: int,
	other_named_principals_exist: bool,
) -> Removal_By_Grant_Refusal {
	if actor_slot == MACHINE || actor_slot >= PRINCIPAL_CAPACITY {
		return .Actor_Not_Named
	}
	if target_slot == MACHINE || target_slot >= PRINCIPAL_CAPACITY {
		return .Target_Not_Named
	}
	if !actor_holds_principals {
		return .Missing_Grant
	}
	if !target_exists {
		return .Target_Absent
	}
	if other_named_principals_exist && target_holds_system && system_holder_count <= 1 {
		return .Last_System_Grant
	}
	return .None
}

// self_removal_allowed reports whether a named principal may remove itself
// via Principal_Change(.Remove). Enforces the same last-System-holder
// invariant as grant-authorized removal: the sole System holder cannot remove
// itself while another named principal remains on the machine.
self_removal_allowed :: proc "contextless" (
	holds_system: bool,
	system_holder_count: int,
	other_named_principals_exist: bool,
) -> bool {
	if other_named_principals_exist && holds_system && system_holder_count <= 1 {
		return false
	}
	return true
}

// first_principal_bootstrap_allowed reports whether a newly recorded named
// principal should receive the bootstrap Principals and System machine grants.
// Only true when the principal was created in this run (never during boot
// scan), principal 0's disk grant table is loaded (No_Passphrase or Kept),
// no machine grants exist yet, and this is the sole named principal.
first_principal_bootstrap_allowed :: proc "contextless" (
	created_in_this_run: bool,
	existing_machine_grant_count: int,
	named_principal_count: int,
	machine_table_loaded: bool,
) -> bool {
	return created_in_this_run &&
		machine_table_loaded &&
		existing_machine_grant_count == 0 &&
		named_principal_count == 1
}
