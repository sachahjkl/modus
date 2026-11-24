package principals

import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Durable state machine for self-removal of a named principal
// (src/md/features/several_principals.md, "The rest").
//
// Before the first destructive step, `unlock` writes `REMOVAL_OBJECT` in its
// store with step `Marked`, then steps strictly through:
//   Marked -> Stores_Erased -> File_Deleted -> Pin_Freed -> Complete.
// A crash or power loss at any point leaves the durable record on disk; the
// next boot reads it and resumes from the recorded step idempotently.
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
	Stores_Erased = 2, // Every encrypted store of the principal has been erased.
	File_Deleted  = 3, // The principal file object has been removed from unlock's store.
	Pin_Freed     = 4, // The TPM NV pin holds "free, generation g" (or no TPM pin existed).
}

// Next idempotent action to execute for a durable removal record.
Removal_Action :: enum u8 {
	Erase_Stores = 1,
	Delete_File  = 2,
	Free_Pin     = 3,
	Clear_Marker = 4,
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
		valid = next_step == .Stores_Erased
	case .Stores_Erased:
		valid = next_step == .File_Deleted
	case .File_Deleted:
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
		return .Erase_Stores
	case .Stores_Erased:
		return .Delete_File
	case .File_Deleted:
		return has_tpm_pin ? .Free_Pin : .Clear_Marker
	case .Pin_Freed:
		return .Clear_Marker
	}
	return .Erase_Stores
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
