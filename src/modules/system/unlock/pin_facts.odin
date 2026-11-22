package unlock

import "modus:contract/tpm_attestation"
import "modus:contract/value_kinds"

// The log facts of the pins of the record of the machine key and of the
// file of the named principal (src/md/features/tpm_sealed_machine_key.md,
// "The pin of the record"). A refusal of a pin is a Text field: the words
// of its member, from tpm_attestation.pin_refusal_words.

// The bytes of the Text field of the words of a refusal of a pin: the
// longest, "a form with the TPM becomes the passphrase alone", has 48
// bytes, and a zero byte.
PIN_REFUSAL_FIELD_BYTES :: 56

// The record of the machine key is not the one that the TPM pins.
@(log_fact = "unlock: the record of the machine key is not the record that the TPM pins: {pin_refusal}; it is refused, and no older or other record opens in its place")
Record_Pin_Mismatch :: struct {
	pin_refusal: [56]u8,
}

// The file of a named principal is not the one that the TPM pins.
@(log_fact = "unlock: the file of principal {principal} is not the file that the TPM pins: {pin_refusal}; it is refused, and no older file opens in its place")
Principal_File_Pin_Mismatch :: struct {
	principal:   u64,
	pin_refusal: [56]u8,
}

// The TPM service refused a new payload of a pin.
@(log_fact = "unlock: the TPM service refuses the new pin: {pin_refusal}")
Pin_Refused_By_Tpm_Service :: struct {
	pin_refusal: [56]u8,
}

// The rules of the pin refuse the change that a write would make.
@(log_fact = "unlock: the pin refuses the change: {pin_refusal}; the record or the file is not written")
Pin_Change_Refused :: struct {
	pin_refusal: [56]u8,
}

// The TPM service gave a refusal of a pin that names no refusal.
@(log_fact = "unlock: the TPM service refuses the new pin with the word {refusal_word}, which names no refusal")
Pin_Refusal_Unknown :: struct {
	refusal_word: u64,
}

// The TPM service gave a state of a pin that names no state.
@(log_fact = "unlock: the TPM service gave the state word {state_word} of a pin, which names no state")
Pin_State_Unknown :: struct {
	state_word: u64,
}

// The TPM service gave a payload of a pin of another size than its kind.
@(log_fact = "unlock: the TPM service gave a pin of {payload_bytes} bytes, not the size of its kind and its state")
Pin_Payload_Size_Wrong :: struct {
	payload_bytes: u64,
}

// The pin of the record of the machine key could not be read, on a
// machine where the root service gave the TPM.
@(log_fact = "unlock: the pin of the record of the machine key was not read: the record is refused, and no record is written, as an unread pin must not let a swapped record pass")
Machine_Pin_Not_Read :: struct {}

// The pin of the file of a named principal could not be read, on a
// machine where the root service gave the TPM.
@(log_fact = "unlock: the pin of the file of principal {principal} was not read: the file is refused, and no file is written, as an unread pin must not let an older file pass")
Principal_Pin_Not_Read :: struct {
	principal: u64,
}

// A pinned record or file would be written with Secure Boot off.
@(log_fact = "unlock: Secure Boot is off, so no pin is written, and a pinned record or file is not written either: the next start would refuse it")
Pinned_Write_Without_Secure_Boot :: struct {}

// The announce of a new record or file was not written in the TPM.
@(log_fact = "unlock: the TPM service did not write the announce of the new record or file: it is not written")
Pin_Announce_Not_Written :: struct {}

// The pin after a write was not written in the TPM.
@(log_fact = "unlock: the TPM service did not write the pin after the write: the next start takes the record or the file that the pin announced, and pins it")
Pin_Settle_Not_Written :: struct {}

// A creation of a principal while a pin names the file of a removed one.
@(log_fact = "unlock: a pin of the TPM names the file of a principal that the disk no longer holds: no new principal takes its place, until a clear of the TPM")
Principal_Creation_Refused_By_Pin :: struct {}

// The TPM pins the record of the machine key.
@(log_fact = "unlock: the TPM pins the record of the machine key, at the epoch {epoch}")
Machine_Record_Pinned :: struct {
	epoch: u64,
}

// The TPM pins the file of a named principal.
@(log_fact = "unlock: the TPM pins the file of principal {principal}, at the generation {generation}")
Principal_File_Pinned :: struct {
	principal:  u64,
	generation: u64,
}

// The tool reads the length of a Text field as a literal: the constant
// names the same bytes.
#assert(size_of(Record_Pin_Mismatch) == PIN_REFUSAL_FIELD_BYTES)

// pin_refusal_field gives the Text field of the words of a refusal of a
// pin.
pin_refusal_field :: proc "contextless" (refusal: tpm_attestation.Pin_Refusal) -> [PIN_REFUSAL_FIELD_BYTES]u8 {
	return value_kinds.text_field(tpm_attestation.pin_refusal_words[refusal], PIN_REFUSAL_FIELD_BYTES)
}
