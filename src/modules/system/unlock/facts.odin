package unlock

import "modus:contract/tpm_service"
import "modus:contract/value_kinds"
import "modus:support/principals"

// The log facts of unlock (src/md/features/log_facts.md, "The migration"):
// the opens and the refusals of a passphrase and of a recovery key, the
// seals and the writes of the file of a principal and of the record of the
// machine key, and the answers of the root service, of the store and of
// the TPM service, as records of fields. Each fact template is the
// sentence that the line wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before. A line whose sentence
// differs by its case is one fact type for each case: the template has no
// condition. No field has the name of a column of the head of facts():
// number, time, process, level.
//
// A status that a line writes as its number is an Integer field: a Status
// field writes the name of its member, and the sentence holds the number.
// A sentence from a closed set (a problem of a file, the words of a step
// of the interface of the TPM, the request to the TPM) is a Text field, as
// the cause of a silent disk is. A Text field is the last field, and is
// [N]u8 with N written out, as the tool reads it.

// The bytes of the Text field of the name of a principal: a name has at
// most principals.NAME_LIMIT bytes, and a zero byte follows it.
PRINCIPAL_NAME_FIELD_BYTES :: 24
// The bytes of the Text field of the sentence of a problem of a file or a
// record: the longest has 141 bytes, and the field holds every value of a
// fact.
PROBLEM_FIELD_BYTES :: 144
// The bytes of the Text field of the name of an object of the store: an
// object name has at most 64 bytes.
OBJECT_FIELD_BYTES :: 72
// The bytes of the Text field of the request to the TPM service: "seal"
// or "unseal".
REQUEST_FIELD_BYTES :: 8
// The bytes of the Text field of the words of a step of the interface of
// the TPM: the longest, "the wait until the TPM is ready", has 31 bytes.
STEP_FIELD_BYTES :: 32
// The bytes of the Text field of how the keys are sealed after a change:
// the longest has 68 bytes.
HOW_FIELD_BYTES :: 72

// The store ended the versions of an object of the store of unlock.
@(log_fact = "unlock: the versions of the object \"{object}\" are erased: {versions} ended, {zeroed} blocks written with zeros, {kept} blocks kept that another state names, {damaged} damaged parts with no zeros")
Versions_Erased :: struct {
	versions: u64,
	zeroed:   u64,
	kept:     u64,
	damaged:  u64,
	object:   [72]u8,
}

// The root service did not take the record of the principal.
@(log_fact = "unlock: the root service did not take the record of the principal \"{principal_name}\": status {status_word}")
Record_Not_Taken :: struct {
	status_word:    u64,
	principal_name: [24]u8,
}

// Argon2id gave no key.
@(log_fact = "unlock: Argon2id refused the derivation: kind {error_kind}, argument {error_argument}")
Derivation_Refused :: struct {
	error_kind:     i64,
	error_argument: i64,
}

// The store did not keep the file of a new principal under its passphrase.
@(log_fact = "unlock: the store did not keep the file of the principal: status {status_word}")
Principal_File_Not_Kept :: struct {
	status_word: u64,
}

// A new principal under its passphrase alone.
@(log_fact = "unlock: principal {principal} \"{principal_name}\" is created: its keys are sealed in the store of unlock under a key of Argon2id, 19456 KiB and 2 passes, derived in {derivation}")
Principal_Created :: struct {
	principal:      u64,
	derivation:     value_kinds.Time_In_Milliseconds,
	principal_name: [24]u8,
}

// A wrong passphrase that the TPM refused and counted.
@(log_fact = "unlock: the passphrase of principal {principal} \"{principal_name}\" is wrong: the TPM refuses it and counts it, nothing is unlocked ({refusals} in all)")
Passphrase_Wrong_Counted_By_Tpm :: struct {
	principal:      u64,
	refusals:       u64,
	principal_name: [24]u8,
}

// A wrong passphrase: the seal does not open.
@(log_fact = "unlock: the passphrase of principal {principal} \"{principal_name}\" is wrong: the seal does not open, nothing is unlocked ({refusals} in all)")
Passphrase_Wrong :: struct {
	principal:      u64,
	refusals:       u64,
	principal_name: [24]u8,
}

// The TPM refuses each try of the passphrase for now, at an unlock.
@(log_fact = "unlock: the TPM refuses each try of the passphrase of principal {principal} \"{principal_name}\" for now: it counted too many wrong passphrases; the recovery key opens the keys")
Passphrase_Locked_Out :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The keys sealed by the TPM do not open under the secret that it released.
@(log_fact = "unlock: the keys of principal {principal} do not open under the secret that the TPM released: the file is not consistent, and the recovery key opens them")
Keys_Not_Consistent_With_Tpm_Secret :: struct {
	principal: u64,
}

// The keys under the passphrase alone do not give the public keys.
@(log_fact = "unlock: the sealed keys of principal {principal} do not match its public keys: nothing is unlocked")
Keys_Do_Not_Match_Public_Keys :: struct {
	principal: u64,
}

// The TPM released the keys of a principal to its passphrase.
@(log_fact = "unlock: the TPM releases the keys of principal {principal} \"{principal_name}\" to its passphrase: the system is the system of the seal; the root service receives the key of its disk grant table only, and the secret keys are erased")
Keys_Released_By_Tpm :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The passphrase opened the seal of the keys under it alone.
@(log_fact = "unlock: the passphrase of principal {principal} \"{principal_name}\" opens its seal; the root service receives the key of its disk grant table only, and the secret keys are erased")
Passphrase_Opened_Seal :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The root service did not take the key of the disk grant table of
// principal 0.
@(log_fact = "unlock: the root service did not take the key of the disk grant table of principal 0: status {status_word}")
Machine_Table_Key_Not_Taken :: struct {
	status_word: u64,
}

// The keys are sealed by the TPM, and no TPM service runs.
@(log_fact = "unlock: the keys of principal {principal} \"{principal_name}\" are sealed by the TPM, and no TPM service runs: the recovery key opens them")
Principal_Keys_Need_Tpm :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The window asks for the passphrase of a principal.
@(log_fact = "unlock: principal {principal} \"{principal_name}\" is locked: its passphrase opens its session")
Principal_Locked :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// No screen: the passphrase of a principal cannot be typed.
@(log_fact = "unlock: no screen: the passphrase of principal {principal} \"{principal_name}\" cannot be typed: its session stays locked")
No_Screen_For_Passphrase :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The keys of a principal wait for their recovery key.
@(log_fact = "unlock: the keys of principal {principal} \"{principal_name}\" wait for their recovery key: the TPM does not release them")
Principal_Recovery_Awaited :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// A wrong machine passphrase: the seal does not open.
@(log_fact = "unlock: the machine passphrase is wrong: the seal does not open, the disk grants of principal 0 stay absent ({refusals} in all)")
Machine_Passphrase_Wrong :: struct {
	refusals: u64,
}

// The store did not keep the record of a machine passphrase alone.
@(log_fact = "unlock: the store did not keep the record of the machine passphrase: status {status_word}")
Machine_Passphrase_Record_Not_Kept :: struct {
	status_word: u64,
}

// The machine passphrase alone seals the machine key.
@(log_fact = "unlock: the machine passphrase is set: the machine key is sealed in the store of unlock under a key of Argon2id, 19456 KiB and 2 passes, derived in {derivation}")
Machine_Passphrase_Set :: struct {
	derivation: value_kinds.Time_In_Milliseconds,
}

// The ring of the TPM service does not open.
@(log_fact = "unlock: the ring of the TPM service does not open: status {status_word}")
Tpm_Ring_Not_Opened :: struct {
	status_word: u64,
}

// The region of the TPM service does not map.
@(log_fact = "unlock: the region of the TPM service does not map: status {status_word}")
Tpm_Region_Not_Mapped :: struct {
	status_word: u64,
}

// The TPM service gave a status word that names no status.
@(log_fact = "unlock: the TPM service gave the status {status_word} to the command {command}, which names no status")
Tpm_Status_Unknown :: struct {
	status_word: u64,
	command:     u64,
}

// The TPM service gave no answer to a request.
@(log_fact = "unlock: the TPM service gave no answer to the {request}")
Tpm_No_Answer :: struct {
	request: [8]u8,
}

// PCR 7 and PCR 11 do not hold the values of the seal.
@(log_fact = "unlock: the TPM refuses the {request}: PCR 7 and PCR 11 do not hold the values of the seal: another system, another state of Secure Boot, or another machine")
Tpm_Policy_Fails :: struct {
	request: [8]u8,
}

// The interface of the TPM failed at a step.
@(log_fact = "unlock: the interface of the TPM failed at the {request}: {step}")
Tpm_Interface_Failed :: struct {
	request: [8]u8,
	step:    [32]u8,
}

// The interface of the TPM failed, with a word that names no step.
@(log_fact = "unlock: the interface of the TPM failed at the {request}: the step {step_word} names no step")
Tpm_Interface_Step_Unknown :: struct {
	step_word: u64,
	request:   [8]u8,
}

// This TPM did not make the sealed object of the record.
@(log_fact = "unlock: the TPM service refuses the {request}: this TPM did not make the sealed object of the record under the PCR values of its policy; the record was written by another system, and only its recovery key opens it")
Tpm_Not_Authentic :: struct {
	request: [8]u8,
}

// The command or a value of a request is out of its range.
@(log_fact = "unlock: the TPM service refuses the {request}: the command or a value is out of its range")
Tpm_Bad_Command :: struct {
	request: [8]u8,
}

// The TPM service gave the status of the measure of a start policy.
@(log_fact = "unlock: the TPM service gave the {request} the status of the measure of a start policy, which answers no request of unlock")
Tpm_Measure_Limit_Status :: struct {
	request: [8]u8,
}

// The TPM service gave a secret of another size.
@(log_fact = "unlock: the TPM service gave a secret of {secret_bytes} bytes")
Tpm_Secret_Size_Wrong :: struct {
	secret_bytes: u64,
}

// A new record of the machine key sealed by the TPM does not decode.
@(log_fact = "unlock: the record of the machine key sealed by the TPM does not decode: {problem}")
Machine_Tpm_Record_Not_Decoded :: struct {
	problem: [144]u8,
}

// The store did not keep the new seal of the machine key.
@(log_fact = "unlock: the store did not keep the new seal of the machine key: status {status_word}; the recovery key opens it at the next start too")
Machine_Reseal_Not_Kept :: struct {
	status_word: u64,
}

// A wrong recovery key of the machine key.
@(log_fact = "unlock: the recovery key is wrong: the copy of the machine key does not open, the disk grants of principal 0 stay absent ({refusals} in all)")
Machine_Recovery_Key_Wrong :: struct {
	refusals: u64,
}

// The TPM service did not seal the keys of a principal.
@(log_fact = "unlock: the TPM service did not seal the keys of principal \"{principal_name}\"")
Principal_Keys_Not_Sealed_By_Tpm :: struct {
	principal_name: [24]u8,
}

// A new record of the machine key sealed by the TPM with the machine
// passphrase does not decode.
@(log_fact = "unlock: the record of the machine key sealed by the TPM with the machine passphrase does not decode: {problem}")
Machine_Tpm_Passphrase_Record_Not_Decoded :: struct {
	problem: [144]u8,
}

// The TPM seals the machine key with the machine passphrase.
@(log_fact = "unlock: the machine key is sealed by the TPM to PCR 7 and PCR 11 and to the machine passphrase, under a key of Argon2id, 19456 KiB and 2 passes, derived in {derivation}")
Machine_Key_Sealed_With_Passphrase :: struct {
	derivation: value_kinds.Time_In_Milliseconds,
}

// A wrong machine passphrase that the TPM refused and counted.
@(log_fact = "unlock: the machine passphrase is wrong: the TPM refuses it and counts it, the disk grants of principal 0 stay absent ({refusals} in all)")
Machine_Passphrase_Wrong_Counted_By_Tpm :: struct {
	refusals: u64,
}

// A new file of a principal sealed by the TPM does not decode.
@(log_fact = "unlock: the file of the principal sealed by the TPM does not decode: {problem}")
Principal_Tpm_File_Not_Decoded :: struct {
	problem: [144]u8,
}

// The TPM seals the keys of a principal with its passphrase.
@(log_fact = "unlock: the keys of principal \"{principal_name}\" are sealed by the TPM to PCR 7 and PCR 11 and to its passphrase, under a key of Argon2id, 19456 KiB and 2 passes, derived in {derivation}")
Principal_Keys_Sealed_By_Tpm :: struct {
	derivation:     value_kinds.Time_In_Milliseconds,
	principal_name: [24]u8,
}

// The keys of a new principal are sealed by the TPM, and the window shows
// its recovery key.
@(log_fact = "unlock: the keys of the new principal \"{principal_name}\" are sealed by the TPM with its passphrase, with a copy under a recovery key; the window shows the recovery key one time, and the principal is created when it is written down")
New_Principal_Sealed_By_Tpm :: struct {
	principal_name: [24]u8,
}

// A new principal whose keys the TPM seals.
@(log_fact = "unlock: principal {principal} \"{principal_name}\" is created: its keys are sealed by the TPM with its passphrase, with a copy under a recovery key")
Principal_Created_Sealed_By_Tpm :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The session of a new principal did not start.
@(log_fact = "unlock: the session of principal {principal} did not start after its creation; the next start of unlock asks for its passphrase")
Session_Not_Started_After_Creation :: struct {
	principal: u64,
}

// A wrong current passphrase of a change that the TPM refused and counted.
@(log_fact = "unlock: the current passphrase of principal {principal} \"{principal_name}\" is wrong: the TPM refuses it and counts it, nothing changes ({refusals} in all)")
Current_Passphrase_Wrong_Counted_By_Tpm :: struct {
	principal:      u64,
	refusals:       u64,
	principal_name: [24]u8,
}

// A wrong current passphrase of a change: the seal does not open.
@(log_fact = "unlock: the current passphrase of principal {principal} \"{principal_name}\" is wrong: the seal does not open, nothing changes ({refusals} in all)")
Current_Passphrase_Wrong :: struct {
	principal:      u64,
	refusals:       u64,
	principal_name: [24]u8,
}

// The TPM refuses each try of the passphrase for now, in a change.
@(log_fact = "unlock: the TPM refuses each try of the passphrase of principal {principal} \"{principal_name}\" for now: it counted too many wrong passphrases; nothing changes")
Change_Locked_Out :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The TPM does not release the keys to the current passphrase.
@(log_fact = "unlock: the TPM does not release the keys of principal {principal} \"{principal_name}\" to its current passphrase: nothing changes")
Change_Tpm_Refused :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The keys do not open under the current passphrase of a change.
@(log_fact = "unlock: the keys of principal {principal} do not open under its current passphrase: the file is not consistent, nothing changes")
Change_Keys_Not_Consistent :: struct {
	principal: u64,
}

// The current passphrase of a change opened the keys.
@(log_fact = "unlock: the current passphrase of principal {principal} \"{principal_name}\" opens its keys")
Current_Passphrase_Opened :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// No new recovery key: the seed is too weak.
@(log_fact = "unlock: the seed of this process is too weak for a key: principal {principal} keeps its recovery key")
Recovery_Key_Kept_Seed_Too_Weak :: struct {
	principal: u64,
}

// No new recovery key: the seal of the copy failed.
@(log_fact = "unlock: the seal of the copy under the new recovery key failed: principal {principal} keeps its recovery key")
Recovery_Key_Kept_Seal_Failed :: struct {
	principal: u64,
}

// The file with a new recovery key does not decode.
@(log_fact = "unlock: the file of the principal with a new recovery key does not decode: {problem}")
Renewed_Recovery_File_Not_Decoded :: struct {
	problem: [144]u8,
}

// A new recovery key, which the window shows.
@(log_fact = "unlock: principal {principal} \"{principal_name}\" has a new recovery key, and the window shows it one time; the file is written when it is written down")
Recovery_Key_Renewed :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The store keeps the file with the new recovery key.
@(log_fact = "unlock: the new recovery key of principal {principal} \"{principal_name}\" is kept: a file written from now opens with it only")
Recovery_Key_Renewal_Kept :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The store did not keep the file with the new recovery key.
@(log_fact = "unlock: the store did not keep the new recovery key of principal {principal}: the recovery key before it stays the key of the file")
Recovery_Key_Renewal_Not_Kept :: struct {
	principal: u64,
}

// The store gave no answer on the file with the new recovery key.
@(log_fact = "unlock: the store gave no answer on the new recovery key of principal {principal}: the old or the new recovery key opens the keys")
Recovery_Key_Renewal_Unknown :: struct {
	principal: u64,
}

// The TPM did not seal the keys under the new passphrase.
@(log_fact = "unlock: the passphrase of principal {principal} does not change: the TPM did not seal the keys again, and the file stays as it was")
Passphrase_Not_Changed_Tpm_Seal_Failed :: struct {
	principal: u64,
}

// The keys are not sealed under the new passphrase.
@(log_fact = "unlock: the passphrase of principal {principal} does not change: the keys are not sealed again, and the file stays as it was")
Passphrase_Not_Changed_Seal_Failed :: struct {
	principal: u64,
}

// The file under the new passphrase does not decode.
@(log_fact = "unlock: the file of the principal under the new passphrase does not decode: {problem}")
Changed_File_Not_Decoded :: struct {
	problem: [144]u8,
}

// The new file does not open with the new passphrase.
@(log_fact = "unlock: the new file of principal {principal} does not open with the new passphrase: its versions are kept, and the old passphrase opens the version before it")
Changed_File_Does_Not_Open :: struct {
	principal: u64,
}

// The passphrase of a principal changed.
@(log_fact = "unlock: the passphrase of principal {principal} \"{principal_name}\" is changed: {how}")
Passphrase_Changed :: struct {
	principal:      u64,
	principal_name: [24]u8,
	how:            [72]u8,
}

// The store did not keep the file under the new passphrase.
@(log_fact = "unlock: the passphrase of principal {principal} does not change: the store did not keep the new file")
Passphrase_Not_Changed_Not_Kept :: struct {
	principal: u64,
}

// The store gave no answer on the file under the new passphrase.
@(log_fact = "unlock: the store gave no answer on the new file of principal {principal}: the old or the new passphrase opens the keys")
Passphrase_Change_Unknown :: struct {
	principal: u64,
}

// The root service did not take the end of a change.
@(log_fact = "unlock: the root service did not take the end of the change: status {status_word}")
Change_End_Not_Taken :: struct {
	status_word: u64,
}

// The store did not answer a write: the object is read back.
@(log_fact = "unlock: the store did not answer the write of the object \"{object}\": status {status_word}; the object is read back")
Object_Write_Not_Answered :: struct {
	status_word: u64,
	object:      [72]u8,
}

// A wrong recovery key of a principal.
@(log_fact = "unlock: the recovery key of principal {principal} \"{principal_name}\" is wrong: the copy of its keys does not open, nothing is unlocked ({refusals} in all)")
Principal_Recovery_Key_Wrong :: struct {
	principal:      u64,
	refusals:       u64,
	principal_name: [24]u8,
}

// The recovery key of a principal opened its keys.
@(log_fact = "unlock: the recovery key of principal {principal} \"{principal_name}\" opens its keys")
Principal_Recovery_Key_Opened :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// No TPM service: the keys are not sealed again after a recovery.
@(log_fact = "unlock: no TPM service: the keys of principal {principal} are not sealed again, and the recovery key opens them at the next start too")
Principal_Not_Resealed_Without_Tpm :: struct {
	principal: u64,
}

// Secure Boot is off: the keys are not sealed again after a recovery.
@(log_fact = "unlock: the firmware did not verify the boot program (Secure Boot is off): the keys of principal {principal} are not sealed again, as their seal would trust a boot program that nothing verified; the recovery key opens them at the next start too")
Principal_Not_Resealed_Without_Secure_Boot :: struct {
	principal: u64,
}

// After a recovery, the window asks for a passphrase that the TPM seals the
// keys again with.
@(log_fact = "unlock: principal {principal} \"{principal_name}\" types a passphrase: the TPM seals its keys again to it and to the system that runs")
Principal_Reseal_Awaited :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The keys are not sealed again after a recovery.
@(log_fact = "unlock: the keys of principal {principal} are not sealed again: the recovery key opens them at the next start too")
Principal_Not_Resealed :: struct {
	principal: u64,
}

// The store did not keep the new seal of the keys.
@(log_fact = "unlock: the store did not keep the new seal of the keys of principal {principal}: status {status_word}; the recovery key opens them at the next start too")
Principal_Reseal_Not_Kept :: struct {
	principal:   u64,
	status_word: u64,
}

// The keys are sealed again after a recovery.
@(log_fact = "unlock: the keys of principal {principal} \"{principal_name}\" are sealed again to PCR 7 and PCR 11 of the system that runs and to the new passphrase: its next unlock needs no recovery key")
Principal_Resealed :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The session did not start after a recovery.
@(log_fact = "unlock: the session of principal {principal} did not start after its recovery; the next start of unlock asks again")
Session_Not_Started_After_Recovery :: struct {
	principal: u64,
}

// The store did not give the record of the machine key.
@(log_fact = "unlock: the store did not give the record of the machine passphrase: status {status_word}")
Machine_Record_Not_Read :: struct {
	status_word: u64,
}

// The record of the machine passphrase alone is refused.
@(log_fact = "unlock: the record of the machine passphrase is refused: {problem}")
Machine_Record_Refused :: struct {
	problem: [144]u8,
}

// The record of the machine key sealed by the TPM is refused.
@(log_fact = "unlock: the record of the machine key sealed by the TPM is refused: {problem}")
Machine_Tpm_Record_Refused :: struct {
	problem: [144]u8,
}

// The record of the machine key sealed by the TPM with the machine
// passphrase is refused.
@(log_fact = "unlock: the record of the machine key sealed by the TPM with the machine passphrase is refused: {problem}")
Machine_Tpm_Passphrase_Record_Refused :: struct {
	problem: [144]u8,
}

// The root service did not start the session of a principal.
@(log_fact = "unlock: the root service did not start the session of principal {principal}: status {status_word}")
Session_Not_Started :: struct {
	principal:   u64,
	status_word: u64,
}

// The recovery key of a principal is not typed.
@(log_fact = "unlock: the recovery key of principal {principal} is not typed: the window asks for its passphrase again")
Principal_Recovery_Key_Not_Typed :: struct {
	principal: u64,
}

// The current passphrase of a change is not typed.
@(log_fact = "unlock: the current passphrase of principal {principal} is not typed: nothing changes")
Current_Passphrase_Not_Typed :: struct {
	principal: u64,
}

// The new passphrase of a change is not typed.
@(log_fact = "unlock: the new passphrase of principal {principal} is not typed: nothing changes")
New_Passphrase_Not_Typed :: struct {
	principal: u64,
}

// The store did not give the file of the principal.
@(log_fact = "unlock: the store did not give the file of the principal: status {status_word}")
Principal_File_Not_Read :: struct {
	status_word: u64,
}

// The file of the principal under its passphrase alone is refused.
@(log_fact = "unlock: the file of the principal is refused: {problem}")
Principal_File_Refused :: struct {
	problem: [144]u8,
}

// The file of the principal sealed by the TPM is refused.
@(log_fact = "unlock: the file of the principal sealed by the TPM is refused: {problem}")
Principal_Tpm_File_Refused :: struct {
	problem: [144]u8,
}

// The root service did not take the state of the machine passphrase.
@(log_fact = "unlock: the root service did not take the state of the machine passphrase: status {status_word}")
Machine_State_Not_Taken :: struct {
	status_word: u64,
}

// The root service gave a mode word that names no mode of unlock.
@(log_fact = "unlock: the root service gave the mode {mode_word}, which names no mode of unlock: nothing is done")
Mode_Unknown :: struct {
	mode_word: u64,
}

// A principal asks for a change.
@(log_fact = "unlock: principal {principal} \"{principal_name}\" asks for a change: its current passphrase comes first")
Change_Asked :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// No memory for the blocks of Argon2id.
@(log_fact = "unlock: no memory for the derivation of the key: status {status_word}")
Derivation_Memory_Refused :: struct {
	status_word: u64,
}

// Ctrl+R asks for the recovery key of a principal.
@(log_fact = "unlock: the recovery key of principal {principal} \"{principal_name}\" is asked in the window: the TPM counts no try of its passphrase")
Principal_Recovery_Asked :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
#assert(size_of(Principal_Keys_Not_Sealed_By_Tpm) == PRINCIPAL_NAME_FIELD_BYTES)
#assert(PRINCIPAL_NAME_FIELD_BYTES > principals.NAME_LIMIT)
#assert(size_of(Machine_Record_Refused) == PROBLEM_FIELD_BYTES)
#assert(size_of(Object_Write_Not_Answered) == 8 + OBJECT_FIELD_BYTES)
#assert(size_of(Tpm_No_Answer) == REQUEST_FIELD_BYTES)
#assert(size_of(Tpm_Interface_Failed) == REQUEST_FIELD_BYTES + STEP_FIELD_BYTES)
#assert(size_of(Passphrase_Changed) == 8 + PRINCIPAL_NAME_FIELD_BYTES + HOW_FIELD_BYTES)

// principal_name_field gives the Text field of the name of the principal
// of this run.
principal_name_field :: proc "contextless" () -> [PRINCIPAL_NAME_FIELD_BYTES]u8 {
	return value_kinds.text_field(the_name(), PRINCIPAL_NAME_FIELD_BYTES)
}

// problem_field gives the Text field of the sentence of a problem.
problem_field :: proc "contextless" (sentence: string) -> [PROBLEM_FIELD_BYTES]u8 {
	return value_kinds.text_field(sentence, PROBLEM_FIELD_BYTES)
}

// object_field gives the Text field of the name of an object of the store.
object_field :: proc "contextless" (object: string) -> [OBJECT_FIELD_BYTES]u8 {
	return value_kinds.text_field(object, OBJECT_FIELD_BYTES)
}

// request_field gives the Text field of the request to the TPM service.
request_field :: proc "contextless" (request: string) -> [REQUEST_FIELD_BYTES]u8 {
	return value_kinds.text_field(request, REQUEST_FIELD_BYTES)
}

// step_field gives the Text field of the words of a step of the interface
// of the TPM.
step_field :: proc "contextless" (step: tpm_service.Device_Step) -> [STEP_FIELD_BYTES]u8 {
	return value_kinds.text_field(tpm_service.device_step_words[step], STEP_FIELD_BYTES)
}

// how_field gives the Text field of how the keys are sealed after a change.
how_field :: proc "contextless" (how: string) -> [HOW_FIELD_BYTES]u8 {
	return value_kinds.text_field(how, HOW_FIELD_BYTES)
}

// derivation_field gives the milliseconds of a derivation of Argon2id as a
// field with its unit.
derivation_field :: proc "contextless" (milliseconds: u64) -> value_kinds.Time_In_Milliseconds {
	return value_kinds.Time_In_Milliseconds(milliseconds)
}
