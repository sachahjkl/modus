package unlock

import "modus:contract/call_outcome"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/tpm_service"
import "modus:contract/value_kinds"
import "modus:principals"
import "modus:system"

// The log facts of unlock (src/md/features/log_facts.md, "The migration"):
// each line of unlock, as a record of fields. Each fact template is the
// sentence that the line wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before. A line whose sentence
// differs by its case is one fact type for each case: the template has no
// condition. A line with no value is a fact type with no field, whose
// sentence is its template. No field has the name of a column of the head
// of facts(): number, time, process, level.
//
// A status of a kernel operation or of the root service is a field of
// op.Status_Word, which a reader writes by the name of its member: the
// sentence says "status No_Right" where the line said "status 7"
// (src/md/features/log_facts.md, "Field kinds"). A status of the client of
// the store (storage_status.Status) is an Integer field, and the sentence
// keeps its number. A sentence from a closed set (a problem of a file,
// the words of a step of the interface of the TPM, the request to the
// TPM) is a Text field, as the cause of a silent disk is. A Text field is
// the last field, and is [N]u8 with N written out, as the tool reads it.

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
// The bytes of the Text field of the words of a request to the TPM service
// (tpm_service.command_words): the longest, "the work of the service
// itself", has 30 bytes, and a zero byte.
TPM_REQUEST_FIELD_BYTES :: 32
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
@(log_fact = "unlock: the root service did not take the record of the principal \"{principal_name}\": outcome {outcome}")
Record_Not_Taken :: struct {
	outcome:        call_outcome.Call_Outcome_Word,
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
@(log_fact = "unlock: the root service did not take the key of the disk grant table of principal 0: outcome {outcome}")
Machine_Table_Key_Not_Taken :: struct {
	outcome: call_outcome.Call_Outcome_Word,
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
@(log_fact = "unlock: the ring of the TPM service does not open: status {status}")
Tpm_Ring_Not_Opened :: struct {
	status: op.Status_Word,
}

// The region of the TPM service does not map.
@(log_fact = "unlock: the region of the TPM service does not map: status {status}")
Tpm_Region_Not_Mapped :: struct {
	status: op.Status_Word,
}

// The TPM service gave a completion that this process cannot read: an
// outcome word that names no outcome, or a failure with no record.
@(log_fact = "unlock: the TPM service gave a completion that this process cannot read to the command {command}: the outcome word {outcome_word}")
Tpm_Status_Unknown :: struct {
	outcome_word: u64,
	command:      u64,
}

// The TPM service gave no answer to a request.
@(log_fact = "unlock: the TPM service gave no answer to the {request}")
Tpm_No_Answer :: struct {
	request: [8]u8,
}

// The wait report of the wait for the answer of the TPM service, which
// passed one more interval (src/md/features/tpm_sealed_machine_key.md, "A
// wait that is long"). The seconds are the count of the report times the
// interval: a fixed number, not the time of the clock at the check. The
// request is in the words of tpm_service.command_words, so the field has a
// name of its own: request holds the words "seal" and "unseal".
@(log_fact = "unlock: the wait for the TPM service passed {passed_seconds} s, for {tpm_request}; waited {waited_milliseconds} ms")
Tpm_Wait_Passed :: struct {
	passed_seconds:      u64,
	waited_milliseconds: u64,
	tpm_request:         [32]u8,
}

// The wait for the answer of the TPM service reached its bound.
@(log_fact = "unlock: the wait for the TPM service reached its bound after {waited_milliseconds} ms, for {tpm_request}")
Tpm_Wait_Bound_Reached :: struct {
	waited_milliseconds: u64,
	tpm_request:         [32]u8,
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
@(log_fact = "unlock: the root service did not take the end of the change: outcome {outcome}")
Change_End_Not_Taken :: struct {
	outcome: call_outcome.Call_Outcome_Word,
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
@(log_fact = "unlock: the root service did not start the session of principal {principal}: outcome {outcome}")
Session_Not_Started :: struct {
	principal: u64,
	outcome:   call_outcome.Call_Outcome_Word,
}

// The recovery key of a principal is not typed.
@(log_fact = "unlock: the recovery key of principal {principal} is not typed: the window asks for its passphrase again")
Principal_Recovery_Key_Not_Typed :: struct {
	principal: u64,
}

// The proof of a wide grant (src/md/features/wide_grants.md, "The path of
// a grant, end to end").
@(log_fact = "unlock: the passphrase of principal {principal} is asked for a wide grant")
Wide_Grant_Proof_Asked :: struct {
	principal: u64,
}

@(log_fact = "unlock: principal {principal} has no passphrase that proves a wide grant here, problem {problem_code}: no grant")
Wide_Grant_Proof_Not_Possible :: struct {
	principal:    u64,
	problem_code: u64,
}

@(log_fact = "unlock: the passphrase of principal {principal} proved a wide grant")
Wide_Grant_Proof_Given :: struct {
	principal: u64,
}

@(log_fact = "unlock: the root service did not take the end of the proof of a wide grant: {status}")
Wide_Grant_Proof_Not_Taken :: struct {
	status: op.Status_Word,
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
// The sentence of an older format says what to do: it is never cut.
#assert(len(principals.OLDER_FORMAT_SENTENCE) <= 144)

// The file of the principal sealed by the TPM is refused.
@(log_fact = "unlock: the file of the principal sealed by the TPM is refused: {problem}")
Principal_Tpm_File_Refused :: struct {
	problem: [144]u8,
}

// The root service did not take the state of the machine passphrase.
@(log_fact = "unlock: the root service did not take the state of the machine passphrase: outcome {outcome}")
Machine_State_Not_Taken :: struct {
	outcome: call_outcome.Call_Outcome_Word,
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
@(log_fact = "unlock: no memory for the derivation of the key: status {status}")
Derivation_Memory_Refused :: struct {
	status: op.Status_Word,
}

// Ctrl+R asks for the recovery key of a principal.
@(log_fact = "unlock: the recovery key of principal {principal} \"{principal_name}\" is asked in the window: the TPM counts no try of its passphrase")
Principal_Recovery_Asked :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The store failed the erase of the versions of an object, with its error
// record. The fields of the record come first, in the order of
// errors.Error_Record_Fact_Fields, and the name of the object last: a
// reader filters on both, so the record is not a distinct type of that
// shape, which holds no other field. The template ends with the words of
// each fact of an error record.
@(log_fact = "unlock: the store did not erase the versions of the object \"{object}\", and the next unlock tries again: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Versions_Erase_Failed :: struct {
	kind:      errors.Kind_Word,
	unit:      errors.Unit_Word,
	operation: i64,
	argument:  i64,
	value:     i64,
	limit:     i64,
	found:     i64,
	object:    [72]u8,
}

// The client of the store gave another status than a failure of the
// export to the erase of the versions of an object: no error record.
@(log_fact = "unlock: the store did not erase the versions of the object \"{object}\": status {status_word}; the next unlock tries again")
Versions_Not_Erased :: struct {
	status_word: u64,
	object:      [72]u8,
}

// The TPM refused a request with a response code.
@(log_fact = "unlock: the TPM refuses the {request}: response code {response_code} to the command {command_code}")
Tpm_Refused_With_Response_Code :: struct {
	response_code: value_kinds.Hexadecimal_Sixteen_Digits,
	command_code:  value_kinds.Hexadecimal_Sixteen_Digits,
	request:       [8]u8,
}

// A change refused: the keys are sealed under the passphrase alone, and
// that form has no copy under a recovery key.
@(log_fact = "unlock: principal {principal} \"{principal_name}\" is not changed: the keys are sealed under the passphrase alone, and a recovery key for that form is not built")
Change_Refused_No_Recovery_Copy :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// A change refused: the keys are sealed by the TPM, and no TPM service
// runs.
@(log_fact = "unlock: principal {principal} \"{principal_name}\" is not changed: the keys are sealed by the TPM, and no TPM service runs: the current passphrase opens nothing without it")
Change_Refused_No_Tpm_Service :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// A change refused: Secure Boot is off, and a new seal is not allowed.
@(log_fact = "unlock: principal {principal} \"{principal_name}\" is not changed: the firmware did not verify the boot program (Secure Boot is off): a new seal by the TPM would trust a boot program that nothing verified")
Change_Refused_Seal_Not_Allowed :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// A change refused: the file has neither form.
@(log_fact = "unlock: principal {principal} \"{principal_name}\" is not changed: the file of the principal has neither form")
Change_Refused_Unknown_Form :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// A change refused: the mode is not a change.
@(log_fact = "unlock: principal {principal} \"{principal_name}\" is not changed: the mode is not a change")
Change_Refused_Unknown_Change :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// A change refused: the file of the principal does not belong to the
// principal that asked for the change.
@(log_fact = "unlock: principal {principal} \"{principal_name}\" is not changed: the file of the principal does not belong to the principal that asked for the change")
Change_Refused_Wrong_Principal :: struct {
	principal:      u64,
	principal_name: [24]u8,
}

// The lines with no value: each is a fact type with no field, whose
// sentence is its template.

// Secure Boot is off: the keys of a new principal are sealed under its
// passphrase alone.
@(log_fact = "unlock: the firmware did not verify the boot program (Secure Boot is off): the keys of the new principal are sealed under its passphrase alone, as a seal by the TPM would trust a boot program that nothing verified")
New_Principal_Sealed_Without_Secure_Boot :: struct {}

// No TPM service: the keys of a new principal are sealed under its
// passphrase alone.
@(log_fact = "unlock: no TPM service: the keys of the new principal are sealed under its passphrase alone, with no recovery key")
New_Principal_Sealed_Without_Tpm :: struct {}

// The seed is too weak: no principal is created.
@(log_fact = "unlock: the seed of this process is too weak for a key: no principal is created")
Principal_Not_Created_Seed_Too_Weak :: struct {}

// The seed is too weak: the keys are not sealed under the passphrase.
@(log_fact = "unlock: the seed of this process is too weak for a key: the keys are not sealed")
Keys_Not_Sealed_Seed_Too_Weak :: struct {}

// No screen: the machine passphrase and its recovery key cannot be typed.
@(log_fact = "unlock: no screen: the machine passphrase and the recovery key of the machine key cannot be typed: the disk grants of principal 0 and its client keys of remote stay absent")
No_Screen_For_Machine_Passphrase :: struct {}

// No screen: the window cannot be shown.
@(log_fact = "unlock: no screen: the window of unlock cannot be shown: nothing is typed, and nothing changes")
No_Screen_For_Window :: struct {}

// The machine passphrase alone opened the machine key.
@(log_fact = "unlock: the machine passphrase opens the machine key; the root service receives the key of the disk grant table only")
Machine_Passphrase_Opened :: struct {}

// Secure Boot is off: the machine key is sealed under the machine
// passphrase alone.
@(log_fact = "unlock: the firmware did not verify the boot program (Secure Boot is off): the machine key is sealed under the machine passphrase alone, as a seal by the TPM would trust a boot program that nothing verified")
Machine_Passphrase_Set_Without_Secure_Boot :: struct {}

// No TPM service: the machine key is sealed under the machine passphrase
// alone.
@(log_fact = "unlock: no TPM service: the machine key is sealed under the machine passphrase alone, with no recovery key")
Machine_Passphrase_Set_Without_Tpm :: struct {}

// The seed is too weak: no machine passphrase is set.
@(log_fact = "unlock: the seed of this process is too weak for a key: no machine passphrase is set")
Machine_Passphrase_Not_Set_Seed_Too_Weak :: struct {}

// The root service did not take the key of a new machine passphrase.
@(log_fact = "unlock: the root service did not take the key of the new machine passphrase; the record stays, and its passphrase opens it at the next start")
Machine_Passphrase_Key_Not_Taken :: struct {}

// The TPM service stopped before this run asked it anything.
@(log_fact = "unlock: the TPM service stopped: the machine key sealed by the TPM opens with its recovery key only")
Tpm_Service_Stopped_At_Start :: struct {}

// The TPM service stopped during a request.
@(log_fact = "unlock: the TPM service stopped during a request")
Tpm_Service_Stopped_During_Request :: struct {}

// The TPM service gave parts of a sealed object that a record does not
// take.
@(log_fact = "unlock: the TPM service gave parts or PCRs that a record sealed by the TPM does not take")
Tpm_Seal_Parts_Refused :: struct {}

// The seed is too weak: no machine key is sealed by the TPM.
@(log_fact = "unlock: the seed of this process is too weak for a key: no machine key is sealed by the TPM")
Machine_Key_Not_Sealed_Seed_Too_Weak :: struct {}

// The TPM service did not seal a new machine key.
@(log_fact = "unlock: no machine key is sealed by the TPM: the TPM service did not seal it")
Machine_Key_Not_Sealed_By_Tpm :: struct {}

// The copy of a new machine key under its recovery key failed.
@(log_fact = "unlock: the seal of the copy under the recovery key failed: no machine key is sealed by the TPM")
Machine_Key_Recovery_Copy_Failed :: struct {}

// A new machine key sealed by the TPM, whose recovery key the window
// shows.
@(log_fact = "unlock: the machine key is sealed by the TPM to PCR 7 and PCR 11, with a copy under a recovery key; the window shows the recovery key one time, and the record is written when it is written down")
Machine_Key_Sealed_By_Tpm :: struct {}

// The store did not keep the record of a new machine key sealed by the
// TPM.
@(log_fact = "unlock: the store did not keep the record of the machine key; no machine key is sealed by the TPM")
Machine_Key_Record_Not_Kept :: struct {}

// The store gave no answer on the record of a new machine key sealed by
// the TPM, and its read back failed.
@(log_fact = "unlock: the store gave no answer on the record of the machine key sealed by the TPM, and its read back failed: the record may be on the disk; the window shows the recovery key until Enter again, and the root service receives no key")
Machine_Key_Record_Write_Unknown :: struct {}

// The store keeps the record of a new machine key sealed by the TPM.
@(log_fact = "unlock: the record of the machine key sealed by the TPM is in the store of unlock: its recovery key is written down")
Machine_Key_Record_Kept :: struct {}

// The root service did not take the key of a new machine key.
@(log_fact = "unlock: the root service did not take the key of the new machine key; the record stays, and the TPM opens it at the next start")
Machine_Key_Not_Taken :: struct {}

// The machine key is sealed by the TPM, and no TPM service runs.
@(log_fact = "unlock: the machine key is sealed by the TPM, and no TPM service runs: the recovery key opens it")
Machine_Key_Needs_Tpm :: struct {}

// The key that the TPM released fails the key check of the record.
@(log_fact = "unlock: the key that the TPM released does not have the key check of the record: it is erased, and the recovery key opens the record")
Machine_Key_Check_Failed :: struct {}

// The TPM released the machine key, and the root service did not take the
// key of its table.
@(log_fact = "unlock: the TPM released the machine key, and the root service did not take the key of its table: the disk grants of principal 0 stay absent until the next start")
Machine_Key_Released_Not_Taken :: struct {}

// The TPM released the machine key with no passphrase.
@(log_fact = "unlock: the TPM releases the machine key: the system is the system of the seal; the root service receives the key of the disk grant table only")
Machine_Key_Released_By_Tpm :: struct {}

// No TPM service: the machine key is not sealed again after a recovery.
@(log_fact = "unlock: no TPM service: the machine key is not sealed again, and the recovery key opens it at the next start too")
Machine_Key_Not_Resealed_Without_Tpm :: struct {}

// Secure Boot is off: the machine key is not sealed again after a
// recovery.
@(log_fact = "unlock: the firmware did not verify the boot program (Secure Boot is off): the machine key is not sealed again, as its seal would trust a boot program that nothing verified; the recovery key opens it at the next start too")
Machine_Key_Not_Resealed_Without_Secure_Boot :: struct {}

// The new seal of the machine key after a recovery failed.
@(log_fact = "unlock: the machine key is not sealed again: the recovery key opens it at the next start too")
Machine_Key_Not_Resealed :: struct {}

// The machine key is sealed again to the system that runs.
@(log_fact = "unlock: the machine key is sealed again to PCR 7 and PCR 11 of the system that runs: its next start needs no recovery key")
Machine_Key_Resealed :: struct {}

// The recovery key opened the machine key.
@(log_fact = "unlock: the recovery key opens the machine key; the root service receives the key of the disk grant table only")
Machine_Recovery_Key_Opened :: struct {}

// The machine key waits for its recovery key.
@(log_fact = "unlock: the machine key waits for its recovery key: the disk grants of principal 0 come when it is typed")
Machine_Recovery_Awaited :: struct {}

// The seed is too weak: the machine key is not sealed by the TPM with the
// machine passphrase.
@(log_fact = "unlock: the seed of this process is too weak for a key: the machine key is not sealed by the TPM")
Machine_Key_Not_Sealed_With_Passphrase_Seed_Too_Weak :: struct {}

// The seed is too weak: the keys of a principal are not sealed by the TPM.
@(log_fact = "unlock: the seed of this process is too weak for a key: the keys are not sealed by the TPM")
Keys_Not_Sealed_By_Tpm_Seed_Too_Weak :: struct {}

// The TPM service did not seal the machine key with the machine
// passphrase.
@(log_fact = "unlock: the TPM service did not seal the machine key with the machine passphrase")
Machine_Key_Not_Sealed_With_Passphrase :: struct {}

// The window shows the recovery key of a new machine passphrase.
@(log_fact = "unlock: the window shows the recovery key of the new machine passphrase one time; the record is written when it is written down")
Machine_Passphrase_Recovery_Key_Shown :: struct {}

// The store did not keep the record of a machine passphrase sealed by the
// TPM.
@(log_fact = "unlock: the store did not keep the record of the machine passphrase; no machine passphrase is set")
Machine_Passphrase_Tpm_Record_Not_Kept :: struct {}

// The store gave no answer on the record of a machine passphrase sealed by
// the TPM, and its read back failed.
@(log_fact = "unlock: the store gave no answer on the record of the machine passphrase, and its read back failed: the record may be on the disk; the window shows the recovery key until Enter again, and the root service receives no key")
Machine_Passphrase_Record_Write_Unknown :: struct {}

// The TPM seals the machine key with a new machine passphrase.
@(log_fact = "unlock: the machine passphrase is set: the TPM seals the machine key with it, with a copy under a recovery key, in the store of unlock")
Machine_Passphrase_Sealed_By_Tpm :: struct {}

// The TPM refuses each try of the machine passphrase for now.
@(log_fact = "unlock: the TPM refuses each try of the machine passphrase for now: it counted too many wrong passphrases; the recovery key opens the machine key")
Machine_Passphrase_Locked_Out :: struct {}

// The machine key does not open under the secret that the TPM released.
@(log_fact = "unlock: the machine key does not open under the secret that the TPM released: the record is not consistent, and the recovery key opens it")
Machine_Key_Not_Consistent_With_Tpm_Secret :: struct {}

// The TPM released the machine key to the machine passphrase.
@(log_fact = "unlock: the TPM releases the machine key to the machine passphrase: the system is the system of the seal; the root service receives the key of the disk grant table only")
Machine_Key_Released_To_Passphrase :: struct {}

// After a recovery, the window asks for a new machine passphrase.
@(log_fact = "unlock: the machine key waits for a new machine passphrase: the TPM seals it again to it and to the system that runs")
Machine_Passphrase_Reseal_Awaited :: struct {}

// The machine key is sealed again to the system that runs and to a new
// machine passphrase.
@(log_fact = "unlock: the machine key is sealed again to PCR 7 and PCR 11 of the system that runs and to the new machine passphrase: its next start needs no recovery key")
Machine_Key_Resealed_With_Passphrase :: struct {}

// The store did not keep the file of a new principal sealed by the TPM.
@(log_fact = "unlock: the store did not keep the file of the principal; no principal is created")
New_Principal_File_Not_Kept :: struct {}

// The store gave no answer on the file of a new principal, and its read
// back failed.
@(log_fact = "unlock: the store gave no answer on the file of the new principal, and its read back failed: the file may be on the disk; the window shows the recovery key until Enter again, and the root service receives no record")
New_Principal_File_Write_Unknown :: struct {}

// The root service did not take the record of a new principal sealed by
// the TPM.
@(log_fact = "unlock: the root service did not take the record of the new principal; its file stays, and its passphrase opens it at the next start")
New_Principal_Record_Not_Taken :: struct {}

// The record of the machine key has none of the three forms.
@(log_fact = "unlock: the record of the machine key is refused: it starts with none of MACHINEK, MACHINET and MACHINEP")
Machine_Record_Form_Unknown :: struct {}

// Enter with no machine passphrase.
@(log_fact = "unlock: the machine passphrase is not typed: the disk grants of principal 0 stay absent until unlock asks again")
Machine_Passphrase_Not_Typed :: struct {}

// Enter with no recovery key of the machine key: the window asks for the
// machine passphrase again.
@(log_fact = "unlock: the recovery key of the machine key is not typed: the window asks for the machine passphrase again")
Machine_Recovery_Key_Not_Typed_Passphrase_Asked :: struct {}

// Enter with no recovery key of the machine key.
@(log_fact = "unlock: the recovery key is not typed: the disk grants of principal 0 stay absent until unlock asks again")
Machine_Recovery_Key_Not_Typed :: struct {}

// Enter on a recovery key that the window shows: the write comes now.
@(log_fact = "unlock: Enter on the recovery key: it is written down, and the record or the file that holds its copy is written now")
Recovery_Key_Written_Down :: struct {}

// Enter with no new machine passphrase after a recovery.
@(log_fact = "unlock: no new machine passphrase is typed: the machine key is not sealed again, and the recovery key opens it at the next start too")
Machine_Reseal_Passphrase_Not_Typed :: struct {}

// The file of the principal has neither form.
@(log_fact = "unlock: the file of the principal is refused: it starts with neither PRINCIPL nor PRINCIPT")
Principal_File_Form_Unknown :: struct {}

// No record of the machine key, before the start policy.
@(log_fact = "unlock: no record of the machine key: the disk grants of principal 0 last until the machine stops, and the start policy of the boot image runs")
No_Machine_Record :: struct {}

// The record of the machine key cannot be read, before the start policy.
@(log_fact = "unlock: the record of the machine key cannot be read: the disk grants of principal 0 stay absent, and the start policy of the boot image runs")
Machine_Record_Unreadable_Before_Start_Policy :: struct {}

// The machine key opens with the machine passphrase, after the start
// policy.
@(log_fact = "unlock: the machine key opens with the machine passphrase: the window of unlock asks for it after the start policy starts")
Machine_Key_Opens_With_Passphrase :: struct {}

// The TPM did not release the machine key before the start policy.
@(log_fact = "unlock: the TPM did not release the machine key before the start policy: the window of unlock asks for its recovery key after the start policy starts")
Machine_Key_Not_Released_Before_Start_Policy :: struct {}

// The root service gave no random seed.
@(log_fact = "unlock: the root service gave no random seed")
No_Random_Seed :: struct {}

// No ring to the root service.
@(log_fact = "unlock: no ring to the root service")
No_Root_Ring :: struct {}

// No store.
@(log_fact = "unlock: no store: no named principal can be kept")
No_Store :: struct {}

// A seal of the machine key asked with no TPM service.
@(log_fact = "unlock: no TPM service: no machine key is sealed by the TPM")
Machine_Key_Seal_Without_Tpm :: struct {}

// A seal of the machine key asked with Secure Boot off.
@(log_fact = "unlock: the firmware did not verify the boot program (Secure Boot is off): no machine key is sealed by the TPM")
Machine_Key_Seal_Without_Secure_Boot :: struct {}

// A seal of the machine key asked when a record exists.
@(log_fact = "unlock: the machine has a record of its machine key already: a change is not built")
Machine_Key_Record_Exists :: struct {}

// A seal of the machine key asked when the record cannot be read.
@(log_fact = "unlock: the record of the machine key cannot be read: no new machine key replaces it")
Machine_Key_Record_Unreadable :: struct {}

// The name of a new principal is refused.
@(log_fact = "unlock: the name of the new principal is refused")
New_Principal_Name_Refused :: struct {}

// A machine passphrase asked when one exists.
@(log_fact = "unlock: the machine has a passphrase already: a change is not built")
Machine_Passphrase_Exists :: struct {}

// A machine passphrase asked when the record cannot be read.
@(log_fact = "unlock: the record of the machine passphrase cannot be read: no new passphrase replaces it")
Machine_Passphrase_Record_Unreadable :: struct {}

// A change asked with no named principal.
@(log_fact = "unlock: no named principal: there is no passphrase to change")
No_Principal_To_Change :: struct {}

// The machine key is sealed by the TPM with the machine passphrase, and no
// TPM service runs.
@(log_fact = "unlock: the machine key is sealed by the TPM with the machine passphrase, and no TPM service runs: the recovery key opens it")
Machine_Key_With_Passphrase_Needs_Tpm :: struct {}

// The record of the machine key cannot be read at an unlock.
@(log_fact = "unlock: the record of the machine passphrase cannot be read: the disk grants of principal 0 stay absent, and nothing replaces the record")
Machine_Record_Unreadable :: struct {}

// The window asks for the machine passphrase.
@(log_fact = "unlock: the machine has a passphrase: the disk grants of principal 0 come when it is typed")
Machine_Passphrase_Awaited :: struct {}

// No named principal and no record to ask for.
@(log_fact = "unlock: no named principal: the machine runs as principal 0, with no unlock")
No_Named_Principal :: struct {}

// Ctrl+R asks for the recovery key of the machine key.
@(log_fact = "unlock: the recovery key of the machine key is asked in the window: the TPM counts no try of the machine passphrase")
Machine_Recovery_Asked :: struct {}

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
#assert(size_of(Principal_Keys_Not_Sealed_By_Tpm) == PRINCIPAL_NAME_FIELD_BYTES)
#assert(PRINCIPAL_NAME_FIELD_BYTES > principals.NAME_LIMIT)
#assert(size_of(Machine_Record_Refused) == PROBLEM_FIELD_BYTES)
#assert(size_of(Object_Write_Not_Answered) == 8 + OBJECT_FIELD_BYTES)
#assert(size_of(Tpm_No_Answer) == REQUEST_FIELD_BYTES)
#assert(size_of(Tpm_Wait_Passed) == 16 + TPM_REQUEST_FIELD_BYTES)
#assert(size_of(Tpm_Wait_Bound_Reached) == 8 + TPM_REQUEST_FIELD_BYTES)
#assert(size_of(Tpm_Interface_Failed) == REQUEST_FIELD_BYTES + STEP_FIELD_BYTES)
#assert(size_of(Passphrase_Changed) == 8 + PRINCIPAL_NAME_FIELD_BYTES + HOW_FIELD_BYTES)
#assert(size_of(Versions_Erase_Failed) == size_of(errors.Error_Record_Fact_Fields) + OBJECT_FIELD_BYTES)

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

// tpm_request_field gives the Text field of the words of a request to
// the TPM service, for the wait reports of a long wait.
tpm_request_field :: proc "contextless" (command: tpm_service.Command) -> [TPM_REQUEST_FIELD_BYTES]u8 {
	return value_kinds.text_field(tpm_service.command_words[command], TPM_REQUEST_FIELD_BYTES)
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

// sixteen_digits_field gives a code of the TPM as a field that a reader
// writes in 16 hexadecimal digits, as system.Hex wrote it.
sixteen_digits_field :: proc "contextless" (code: u64) -> value_kinds.Hexadecimal_Sixteen_Digits {
	return value_kinds.Hexadecimal_Sixteen_Digits(code)
}

// status_field gives the word of a status of a kernel operation or of a
// completion of the root service as a field. The word is copied with no
// cast to the enum: a word that names no member stays its number, which
// the reader writes.
status_field :: proc "contextless" (word: u32) -> op.Status_Word {
	return op.Status_Word(word)
}

// outcome_field gives the outcome word of a completion of the root service
// as it came: a word that names no member keeps its number in the line.
outcome_field :: proc "contextless" (word: u32) -> call_outcome.Call_Outcome_Word {
	return call_outcome.Call_Outcome_Word(word)
}

// change_refusal_log writes why a change of the principal of this run is
// refused: one fact type for each problem, as a template has no condition
// and the longest sentence with the number and the name passes the bytes
// of the values of a fact.
change_refusal_log :: proc "contextless" (problem: principals.Change_Problem) {
	switch problem {
	case .None:
		// No problem: the change is made, and nothing is refused.
	case .No_Recovery_Copy:
		system.log_fact(.Info, Change_Refused_No_Recovery_Copy{principal = number, principal_name = principal_name_field()})
	case .No_Tpm_Service:
		system.log_fact(.Info, Change_Refused_No_Tpm_Service{principal = number, principal_name = principal_name_field()})
	case .Seal_Not_Allowed:
		system.log_fact(.Info, Change_Refused_Seal_Not_Allowed{principal = number, principal_name = principal_name_field()})
	case .Unknown_Form:
		system.log_fact(.Info, Change_Refused_Unknown_Form{principal = number, principal_name = principal_name_field()})
	case .Unknown_Change:
		system.log_fact(.Info, Change_Refused_Unknown_Change{principal = number, principal_name = principal_name_field()})
	case .Wrong_Principal:
		system.log_fact(.Info, Change_Refused_Wrong_Principal{principal = number, principal_name = principal_name_field()})
	}
}
