package build

import "modus:contract/errors"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/tpm_attestation"
import "modus:contract/tpm_service"
import "modus:principals"
import "modus:sentence"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The log facts of unlock against the lines that they replaced
// (src/md/features/log_facts.md, "The migration"). The fact types come
// from the extraction of the tool on the sources of the module: a host
// test does not depend on a build. Each sentence is compared with the
// parts of the old line written by sentence.format, at the edges of each
// field, and each sentence of a closed set is written whole.

// The longest object name that the store keeps (store.ENTRY_NAME_CAPACITY).
@(private = "file")
UNLOCK_OBJECT_NAME_BYTES_MOST :: 64
// The two ways a change seals the keys, as passphrase_change_seal gives
// them.
@(private = "file")
UNLOCK_HOW_SENTENCES := [2]string{"the TPM seals its keys to PCR 7 and PCR 11 and to the new passphrase", "its keys are sealed under the new passphrase alone"}
// The two requests to the TPM service.
@(private = "file")
UNLOCK_REQUESTS := [2]string{"seal", "unseal"}

// The longest sentence of each table of problems that a fact of unlock
// writes.
@(private = "file")
unlock_problem_bytes_most :: proc() -> int {
	most := 0
	for member in principals.File_Problem {
		most = max(most, len(principals.file_problem_sentences[member]), len(principals.machine_file_problem_sentences[member]), len(principals.machine_tpm_file_problem_sentences[member]), len(principals.machine_tpm_passphrase_file_problem_sentences[member]), len(principals.principal_tpm_file_problem_sentences[member]))
	}
	return most
}

// pin_refusal_words_most gives the bytes of the longest words of a refusal
// of a pin, which the facts of unlock and of the TPM service write.
pin_refusal_words_most :: proc() -> int {
	most := 0
	for refusal in tpm_attestation.Pin_Refusal {
		most = max(most, len(tpm_attestation.pin_refusal_words[refusal]))
	}
	return most
}

// The most bytes of the text of each Text field of unlock, which its field
// holds with a zero byte after it.
@(private = "file")
unlock_text_bytes_most :: proc() -> map[string]u32 {
	most := make(map[string]u32, context.temp_allocator)
	most["principal_name"] = principals.NAME_LIMIT
	most["problem"] = u32(unlock_problem_bytes_most())
	most["object"] = UNLOCK_OBJECT_NAME_BYTES_MOST
	step_most := 0
	for step in tpm_service.Device_Step {
		step_most = max(step_most, len(tpm_service.device_step_words[step]))
	}
	most["step"] = u32(step_most)
	most["request"] = u32(max(len(UNLOCK_REQUESTS[0]), len(UNLOCK_REQUESTS[1])))
	most["how"] = u32(max(len(UNLOCK_HOW_SENTENCES[0]), len(UNLOCK_HOW_SENTENCES[1])))
	most["pin_refusal"] = u32(pin_refusal_words_most())
	return most
}

// name_and_number gives the sentence of a fact type of unlock whose fields
// are the number and the name of a principal.
@(private = "file")
name_and_number :: proc(t: ^testing.T, file: []u8, type_name: string, number: u64, principal_name: string) -> string {
	return fact_test_render(t, file, "unlock", type_name, {{"principal", number}, {"principal_name", principal_name}})
}

// with_refusals gives the sentence of a fact type of unlock whose fields
// are the number of a principal, a count of refusals and its name.
@(private = "file")
with_refusals :: proc(t: ^testing.T, file: []u8, type_name: string, number, refusals: u64, principal_name: string) -> string {
	return fact_test_render(t, file, "unlock", type_name, {{"principal", number}, {"refusals", refusals}, {"principal_name", principal_name}})
}

// Each fact type of unlock with a Text field ends with its Text fields, and
// each Text field holds the longest text of its writer and a zero byte.
@(test)
the_texts_of_the_unlock_facts_come_last_and_whole :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "unlock")
	if ok {
		facts_expect_text_fields_last(t, file, unlock_text_bytes_most())
	}
}

// A byte that no sentence of unlock holds: a buffer full of it after a
// refusal shows that the refusal wrote nothing.
@(private = "file")
UNLOCK_UNTOUCHED_BYTE :: 0xFF

// unlock_refusal_expect writes a fact into a buffer full of
// UNLOCK_UNTOUCHED_BYTE, and checks the refusal, the count 0, and that no
// byte of the buffer changed.
@(private = "file")
unlock_refusal_expect :: proc(t: ^testing.T, file: []u8, key: u64, values: []u8, buffer: []u8, expected: module.Fact_Render_Refusal, loc := #caller_location) {
	for &item in buffer {
		item = UNLOCK_UNTOUCHED_BYTE
	}
	count, _, refusal := module.fact_sentence_write(file, key, values, buffer, nil)
	testing.expectf(t, refusal == expected && count == 0, "a fact of %d value bytes in a buffer of %d gave %v and %d bytes, not %v", len(values), len(buffer), refusal, count, expected, loc = loc)
	for item in buffer {
		if !testing.expectf(t, item == UNLOCK_UNTOUCHED_BYTE, "the refusal %v changed the buffer", expected, loc = loc) {
			return
		}
	}
}

// A reader refuses each fact of unlock whose value bytes are not the size
// of its record: none, one byte less, one byte more. It refuses a key that
// no fact type of unlock has, and a sentence one byte longer than its
// buffer. Each refusal writes nothing.
@(test)
a_reader_refuses_a_fact_of_unlock_that_does_not_fit_its_record :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "unlock")
	if !ok {
		return
	}
	buffer: [module.FACT_SENTENCE_BYTES_MOST]u8
	values: [module.RECORD_SIZE_LIMIT + 1]u8
	rows := module.count(file, .Facts)
	testing.expect(t, rows > 1)
	for row_index in 1 ..< rows {
		row, description, row_ok := module.fact(file, row_index)
		if !testing.expect(t, row_ok) {
			continue
		}
		size := int(description.size)
		// A fact type with no field takes 0 value bytes: one past it is its one
		// wrong count, and no count lies below it.
		wrong_counts := [3]int{0, size - 1, size + 1}
		for count in wrong_counts {
			if count < 0 || count == size {
				continue
			}
			unlock_refusal_expect(t, file, row.key, values[:count], buffer[:], .Value_Count)
		}
		written, _, whole := module.fact_sentence_write(file, row.key, values[:size], buffer[:], nil)
		if !testing.expectf(t, whole == .None && written > 0, "a fact of its own size gave %v", whole) {
			continue
		}
		unlock_refusal_expect(t, file, row.key, values[:size], buffer[:written - 1], .Too_Long)
	}
	unlock_refusal_expect(t, file, fact_key("unlock", "No_Such_Fact"), values[:8], buffer[:], .No_Fact_Type)
}

// Each fact type of unlock writes the line of before, byte for byte, at
// the edges of its fields: the principals 0, 1 and max(u64); a name of 1
// byte and of principals.NAME_LIMIT bytes; the counts and the status words
// 0, 1 and max(u64); a time of 0 and of max(i64), the largest that its
// field holds; each sentence of each closed set.
@(test)
the_facts_of_unlock_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "unlock")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "unlock", type_name, values)
	}
	numbers := [3]u64{0, 1, max(u64)}
	names := [2]string{"a", strings.repeat("n", principals.NAME_LIMIT, context.temp_allocator)}
	times := [2]u64{0, u64(max(i64))}
	objects := [3]string{principals.FILE_OBJECT, principals.MACHINE_OBJECT, strings.repeat("o", UNLOCK_OBJECT_NAME_BYTES_MOST, context.temp_allocator)}

	// The lines with a count, a status word or a number of a principal.
	for number in numbers {
		other := max(u64) - number
		facts_expect_line(t, render(t, file, "Principal_File_Not_Kept", {{"status_word", number}}), line_of_before("unlock: the store did not keep the file of the principal: status ", number))
		facts_expect_line(t, render(t, file, "Keys_Not_Consistent_With_Tpm_Secret", {{"principal", number}}), line_of_before("unlock: the keys of principal ", number, " do not open under the secret that the TPM released: the file is not consistent, and the recovery key opens them"))
		facts_expect_line(t, render(t, file, "Keys_Do_Not_Match_Public_Keys", {{"principal", number}}), line_of_before("unlock: the sealed keys of principal ", number, " do not match its public keys: nothing is unlocked"))
		facts_expect_line(t, render(t, file, "Machine_Passphrase_Wrong", {{"refusals", number}}), line_of_before("unlock: the machine passphrase is wrong: the seal does not open, the disk grants of principal 0 stay absent (", number, " in all)"))
		facts_expect_line(t, render(t, file, "Machine_Passphrase_Record_Not_Kept", {{"status_word", number}}), line_of_before("unlock: the store did not keep the record of the machine passphrase: status ", number))
		facts_expect_line(t, render(t, file, "Tpm_Status_Unknown", {{"status_word", number}, {"command", other}}), line_of_before("unlock: the TPM service gave the status ", number, " to the command ", other, ", which names no status"))
		facts_expect_line(t, render(t, file, "Tpm_Secret_Size_Wrong", {{"secret_bytes", number}}), line_of_before("unlock: the TPM service gave a secret of ", number, " bytes"))
		facts_expect_line(t, render(t, file, "Machine_Reseal_Not_Kept", {{"status_word", number}}), line_of_before("unlock: the store did not keep the new seal of the machine key: status ", number, "; the recovery key opens it at the next start too"))
		facts_expect_line(t, render(t, file, "Machine_Recovery_Key_Wrong", {{"refusals", number}}), line_of_before("unlock: the recovery key is wrong: the copy of the machine key does not open, the disk grants of principal 0 stay absent (", number, " in all)"))
		facts_expect_line(t, render(t, file, "Machine_Passphrase_Wrong_Counted_By_Tpm", {{"refusals", number}}), line_of_before("unlock: the machine passphrase is wrong: the TPM refuses it and counts it, the disk grants of principal 0 stay absent (", number, " in all)"))
		facts_expect_line(t, render(t, file, "Session_Not_Started_After_Creation", {{"principal", number}}), line_of_before("unlock: the session of principal ", number, " did not start after its creation; the next start of unlock asks for its passphrase"))
		facts_expect_line(t, render(t, file, "Change_Keys_Not_Consistent", {{"principal", number}}), line_of_before("unlock: the keys of principal ", number, " do not open under its current passphrase: the file is not consistent, nothing changes"))
		facts_expect_line(t, render(t, file, "Recovery_Key_Kept_Seed_Too_Weak", {{"principal", number}}), line_of_before("unlock: the seed of this process is too weak for a key: principal ", number, " keeps its recovery key"))
		facts_expect_line(t, render(t, file, "Recovery_Key_Kept_Seal_Failed", {{"principal", number}}), line_of_before("unlock: the seal of the copy under the new recovery key failed: principal ", number, " keeps its recovery key"))
		facts_expect_line(t, render(t, file, "Recovery_Key_Renewal_Not_Kept", {{"principal", number}}), line_of_before("unlock: the store did not keep the new recovery key of principal ", number, ": the recovery key before it stays the key of the file"))
		facts_expect_line(t, render(t, file, "Recovery_Key_Renewal_Unknown", {{"principal", number}}), line_of_before("unlock: the store gave no answer on the new recovery key of principal ", number, ": the old or the new recovery key opens the keys"))
		facts_expect_line(t, render(t, file, "Passphrase_Not_Changed_Tpm_Seal_Failed", {{"principal", number}}), line_of_before("unlock: the passphrase of principal ", number, " does not change: the TPM did not seal the keys again, and the file stays as it was"))
		facts_expect_line(t, render(t, file, "Passphrase_Not_Changed_Seal_Failed", {{"principal", number}}), line_of_before("unlock: the passphrase of principal ", number, " does not change: the keys are not sealed again, and the file stays as it was"))
		facts_expect_line(t, render(t, file, "Changed_File_Does_Not_Open", {{"principal", number}}), line_of_before("unlock: the new file of principal ", number, " does not open with the new passphrase: its versions are kept, and the old passphrase opens the version before it"))
		facts_expect_line(t, render(t, file, "Passphrase_Not_Changed_Not_Kept", {{"principal", number}}), line_of_before("unlock: the passphrase of principal ", number, " does not change: the store did not keep the new file"))
		facts_expect_line(t, render(t, file, "Passphrase_Change_Unknown", {{"principal", number}}), line_of_before("unlock: the store gave no answer on the new file of principal ", number, ": the old or the new passphrase opens the keys"))
		facts_expect_line(t, render(t, file, "Principal_Not_Resealed_Without_Tpm", {{"principal", number}}), line_of_before("unlock: no TPM service: the keys of principal ", number, " are not sealed again, and the recovery key opens them at the next start too"))
		facts_expect_line(t, render(t, file, "Principal_Not_Resealed_Without_Secure_Boot", {{"principal", number}}), line_of_before("unlock: the firmware did not verify the boot program (Secure Boot is off): the keys of principal ", number, " are not sealed again, as their seal would trust a boot program that nothing verified; the recovery key opens them at the next start too"))
		facts_expect_line(t, render(t, file, "Principal_Not_Resealed", {{"principal", number}}), line_of_before("unlock: the keys of principal ", number, " are not sealed again: the recovery key opens them at the next start too"))
		facts_expect_line(t, render(t, file, "Principal_Reseal_Not_Kept", {{"principal", number}, {"status_word", other}}), line_of_before("unlock: the store did not keep the new seal of the keys of principal ", number, ": status ", other, "; the recovery key opens them at the next start too"))
		facts_expect_line(t, render(t, file, "Session_Not_Started_After_Recovery", {{"principal", number}}), line_of_before("unlock: the session of principal ", number, " did not start after its recovery; the next start of unlock asks again"))
		facts_expect_line(t, render(t, file, "Machine_Record_Not_Read", {{"status_word", number}}), line_of_before("unlock: the store did not give the record of the machine passphrase: status ", number))
		facts_expect_line(t, render(t, file, "Principal_Recovery_Key_Not_Typed", {{"principal", number}}), line_of_before("unlock: the recovery key of principal ", number, " is not typed: the window asks for its passphrase again"))
		facts_expect_line(t, render(t, file, "Current_Passphrase_Not_Typed", {{"principal", number}}), line_of_before("unlock: the current passphrase of principal ", number, " is not typed: nothing changes"))
		facts_expect_line(t, render(t, file, "New_Passphrase_Not_Typed", {{"principal", number}}), line_of_before("unlock: the new passphrase of principal ", number, " is not typed: nothing changes"))
		facts_expect_line(t, render(t, file, "Principal_File_Not_Read", {{"status_word", number}}), line_of_before("unlock: the store did not give the file of the principal: status ", number))
		facts_expect_line(t, render(t, file, "Mode_Unknown", {{"mode_word", number}}), line_of_before("unlock: the root service gave the mode ", number, ", which names no mode of unlock: nothing is done"))
		for object in objects {
			facts_expect_line(t, render(t, file, "Versions_Erased", {{"versions", number}, {"zeroed", other}, {"kept", number}, {"damaged", other}, {"object", object}}), line_of_before("unlock: the versions of the object \"", object, "\" are erased: ", number, " ended, ", other, " blocks written with zeros, ", number, " blocks kept that another state names, ", other, " damaged parts with no zeros"))
			facts_expect_line(t, render(t, file, "Object_Write_Not_Answered", {{"status_word", number}, {"object", object}}), line_of_before("unlock: the store did not answer the write of the object \"", object, "\": status ", number, "; the object is read back"))
		}
	}

	// The lines with the name of a principal.
	for principal_name in names {
		for number in numbers {
			refusals := max(u64) - number
			facts_expect_line(t, with_refusals(t, file, "Passphrase_Wrong_Counted_By_Tpm", number, refusals, principal_name), line_of_before("unlock: the passphrase of principal ", number, " \"", principal_name, "\" is wrong: the TPM refuses it and counts it, nothing is unlocked (", refusals, " in all)"))
			facts_expect_line(t, with_refusals(t, file, "Passphrase_Wrong", number, refusals, principal_name), line_of_before("unlock: the passphrase of principal ", number, " \"", principal_name, "\" is wrong: the seal does not open, nothing is unlocked (", refusals, " in all)"))
			facts_expect_line(t, with_refusals(t, file, "Current_Passphrase_Wrong_Counted_By_Tpm", number, refusals, principal_name), line_of_before("unlock: the current passphrase of principal ", number, " \"", principal_name, "\" is wrong: the TPM refuses it and counts it, nothing changes (", refusals, " in all)"))
			facts_expect_line(t, with_refusals(t, file, "Current_Passphrase_Wrong", number, refusals, principal_name), line_of_before("unlock: the current passphrase of principal ", number, " \"", principal_name, "\" is wrong: the seal does not open, nothing changes (", refusals, " in all)"))
			facts_expect_line(t, with_refusals(t, file, "Principal_Recovery_Key_Wrong", number, refusals, principal_name), line_of_before("unlock: the recovery key of principal ", number, " \"", principal_name, "\" is wrong: the copy of its keys does not open, nothing is unlocked (", refusals, " in all)"))
			facts_expect_line(t, name_and_number(t, file, "Passphrase_Locked_Out", number, principal_name), line_of_before("unlock: the TPM refuses each try of the passphrase of principal ", number, " \"", principal_name, "\" for now: it counted too many wrong passphrases; the recovery key opens the keys"))
			facts_expect_line(t, name_and_number(t, file, "Keys_Released_By_Tpm", number, principal_name), line_of_before("unlock: the TPM releases the keys of principal ", number, " \"", principal_name, "\" to its passphrase: the system is the system of the seal; the root service receives the key of its disk grant table only, and the secret keys are erased"))
			facts_expect_line(t, name_and_number(t, file, "Passphrase_Opened_Seal", number, principal_name), line_of_before("unlock: the passphrase of principal ", number, " \"", principal_name, "\" opens its seal; the root service receives the key of its disk grant table only, and the secret keys are erased"))
			facts_expect_line(t, name_and_number(t, file, "Principal_Keys_Need_Tpm", number, principal_name), line_of_before("unlock: the keys of principal ", number, " \"", principal_name, "\" are sealed by the TPM, and no TPM service runs: the recovery key opens them"))
			facts_expect_line(t, name_and_number(t, file, "Principal_Locked", number, principal_name), line_of_before("unlock: principal ", number, " \"", principal_name, "\" is locked: its passphrase opens its session"))
			facts_expect_line(t, name_and_number(t, file, "No_Screen_For_Passphrase", number, principal_name), line_of_before("unlock: no screen: the passphrase of principal ", number, " \"", principal_name, "\" cannot be typed: its session stays locked"))
			facts_expect_line(t, name_and_number(t, file, "Principal_Recovery_Awaited", number, principal_name), line_of_before("unlock: the keys of principal ", number, " \"", principal_name, "\" wait for their recovery key: the TPM does not release them"))
			facts_expect_line(t, name_and_number(t, file, "Principal_Created_Sealed_By_Tpm", number, principal_name), line_of_before("unlock: principal ", number, " \"", principal_name, "\" is created: its keys are sealed by the TPM with its passphrase, with a copy under a recovery key"))
			facts_expect_line(t, name_and_number(t, file, "Change_Locked_Out", number, principal_name), line_of_before("unlock: the TPM refuses each try of the passphrase of principal ", number, " \"", principal_name, "\" for now: it counted too many wrong passphrases; nothing changes"))
			facts_expect_line(t, name_and_number(t, file, "Change_Tpm_Refused", number, principal_name), line_of_before("unlock: the TPM does not release the keys of principal ", number, " \"", principal_name, "\" to its current passphrase: nothing changes"))
			facts_expect_line(t, name_and_number(t, file, "Current_Passphrase_Opened", number, principal_name), line_of_before("unlock: the current passphrase of principal ", number, " \"", principal_name, "\" opens its keys"))
			facts_expect_line(t, name_and_number(t, file, "Recovery_Key_Renewed", number, principal_name), line_of_before("unlock: principal ", number, " \"", principal_name, "\" has a new recovery key, and the window shows it one time; the file is written when it is written down"))
			facts_expect_line(t, name_and_number(t, file, "Recovery_Key_Renewal_Kept", number, principal_name), line_of_before("unlock: the new recovery key of principal ", number, " \"", principal_name, "\" is kept: a file written from now opens with it only"))
			facts_expect_line(t, name_and_number(t, file, "Principal_Recovery_Key_Opened", number, principal_name), line_of_before("unlock: the recovery key of principal ", number, " \"", principal_name, "\" opens its keys"))
			facts_expect_line(t, name_and_number(t, file, "Principal_Reseal_Awaited", number, principal_name), line_of_before("unlock: principal ", number, " \"", principal_name, "\" types a passphrase: the TPM seals its keys again to it and to the system that runs"))
			facts_expect_line(t, name_and_number(t, file, "Principal_Resealed", number, principal_name), line_of_before("unlock: the keys of principal ", number, " \"", principal_name, "\" are sealed again to PCR 7 and PCR 11 of the system that runs and to the new passphrase: its next unlock needs no recovery key"))
			facts_expect_line(t, name_and_number(t, file, "Change_Asked", number, principal_name), line_of_before("unlock: principal ", number, " \"", principal_name, "\" asks for a change: its current passphrase comes first"))
			facts_expect_line(t, name_and_number(t, file, "Principal_Recovery_Asked", number, principal_name), line_of_before("unlock: the recovery key of principal ", number, " \"", principal_name, "\" is asked in the window: the TPM counts no try of its passphrase"))
			for how in UNLOCK_HOW_SENTENCES {
				facts_expect_line(t, render(t, file, "Passphrase_Changed", {{"principal", number}, {"principal_name", principal_name}, {"how", how}}), line_of_before("unlock: the passphrase of principal ", number, " \"", principal_name, "\" is changed: ", how))
			}
		}
		facts_expect_line(t, render(t, file, "Principal_Keys_Not_Sealed_By_Tpm", {{"principal_name", principal_name}}), line_of_before("unlock: the TPM service did not seal the keys of principal \"", principal_name, "\""))
		facts_expect_line(t, render(t, file, "New_Principal_Sealed_By_Tpm", {{"principal_name", principal_name}}), line_of_before("unlock: the keys of the new principal \"", principal_name, "\" are sealed by the TPM with its passphrase, with a copy under a recovery key; the window shows the recovery key one time, and the principal is created when it is written down"))
	}

	// The lines with the time of a derivation of Argon2id.
	for time in times {
		for principal_name in names {
			facts_expect_line(t, render(t, file, "Principal_Created", {{"principal", max(u64) - time}, {"derivation", time}, {"principal_name", principal_name}}), line_of_before("unlock: principal ", max(u64) - time, " \"", principal_name, "\" is created: its keys are sealed in the store of unlock under a key of Argon2id, 19456 KiB and 2 passes, derived in ", time, " ms"))
			facts_expect_line(t, render(t, file, "Principal_Keys_Sealed_By_Tpm", {{"derivation", time}, {"principal_name", principal_name}}), line_of_before("unlock: the keys of principal \"", principal_name, "\" are sealed by the TPM to PCR 7 and PCR 11 and to its passphrase, under a key of Argon2id, 19456 KiB and 2 passes, derived in ", time, " ms"))
		}
		facts_expect_line(t, render(t, file, "Machine_Passphrase_Set", {{"derivation", time}}), line_of_before("unlock: the machine passphrase is set: the machine key is sealed in the store of unlock under a key of Argon2id, 19456 KiB and 2 passes, derived in ", time, " ms"))
		facts_expect_line(t, render(t, file, "Machine_Key_Sealed_With_Passphrase", {{"derivation", time}}), line_of_before("unlock: the machine key is sealed by the TPM to PCR 7 and PCR 11 and to the machine passphrase, under a key of Argon2id, 19456 KiB and 2 passes, derived in ", time, " ms"))
	}

	// The refusal of Argon2id: the signed edges of an error record.
	signed_values := [4]i64{min(i64), -1, 0, max(i64)}
	for kind in signed_values {
		argument := -1 - kind
		facts_expect_line(t, render(t, file, "Derivation_Refused", {{"error_kind", signed_bits(kind)}, {"error_argument", signed_bits(argument)}}), line_of_before("unlock: Argon2id refused the derivation: kind ", kind, ", argument ", argument))
	}

	// The requests to the TPM service, each step and each word of a step.
	for request in UNLOCK_REQUESTS {
		facts_expect_line(t, render(t, file, "Tpm_No_Answer", {{"request", request}}), line_of_before("unlock: the TPM service gave no answer to the ", request))
		facts_expect_line(t, render(t, file, "Tpm_Policy_Fails", {{"request", request}}), line_of_before("unlock: the TPM refuses the ", request, ": PCR 7 and PCR 11 do not hold the values of the seal: another system, another state of Secure Boot, or another machine"))
		facts_expect_line(t, render(t, file, "Tpm_Not_Authentic", {{"request", request}}), line_of_before("unlock: the TPM service refuses the ", request, ": this TPM did not make the sealed object of the record under the PCR values of its policy; the record was written by another system, and only its recovery key opens it"))
		facts_expect_line(t, render(t, file, "Tpm_Bad_Command", {{"request", request}}), line_of_before("unlock: the TPM service refuses the ", request, ": the command or a value is out of its range"))
		facts_expect_line(t, render(t, file, "Tpm_Measure_Limit_Status", {{"request", request}}), line_of_before("unlock: the TPM service gave the ", request, " the status of the measure of a start policy, which answers no request of unlock"))
		for step in tpm_service.Device_Step {
			words := tpm_service.device_step_words[step]
			facts_expect_line(t, render(t, file, "Tpm_Interface_Failed", {{"request", request}, {"step", words}}), line_of_before("unlock: the interface of the TPM failed at the ", request, ": ", words))
		}
		for word in numbers {
			facts_expect_line(t, render(t, file, "Tpm_Interface_Step_Unknown", {{"step_word", word}, {"request", request}}), line_of_before("unlock: the interface of the TPM failed at the ", request, ": the step ", word, " names no step"))
		}
	}

	// Each problem of each file and each record, whole.
	for member in principals.File_Problem {
		facts_expect_line(t, render(t, file, "Machine_Tpm_Record_Not_Decoded", {{"problem", principals.machine_tpm_file_problem_sentences[member]}}), line_of_before("unlock: the record of the machine key sealed by the TPM does not decode: ", principals.machine_tpm_file_problem_sentences[member]))
		facts_expect_line(t, render(t, file, "Machine_Tpm_Passphrase_Record_Not_Decoded", {{"problem", principals.machine_tpm_passphrase_file_problem_sentences[member]}}), line_of_before("unlock: the record of the machine key sealed by the TPM with the machine passphrase does not decode: ", principals.machine_tpm_passphrase_file_problem_sentences[member]))
		facts_expect_line(t, render(t, file, "Principal_Tpm_File_Not_Decoded", {{"problem", principals.principal_tpm_file_problem_sentences[member]}}), line_of_before("unlock: the file of the principal sealed by the TPM does not decode: ", principals.principal_tpm_file_problem_sentences[member]))
		facts_expect_line(t, render(t, file, "Renewed_Recovery_File_Not_Decoded", {{"problem", principals.principal_tpm_file_problem_sentences[member]}}), line_of_before("unlock: the file of the principal with a new recovery key does not decode: ", principals.principal_tpm_file_problem_sentences[member]))
		facts_expect_line(t, render(t, file, "Changed_File_Not_Decoded", {{"problem", principals.file_problem_sentences[member]}}), line_of_before("unlock: the file of the principal under the new passphrase does not decode: ", principals.file_problem_sentences[member]))
		facts_expect_line(t, render(t, file, "Machine_Record_Refused", {{"problem", principals.machine_file_problem_sentences[member]}}), line_of_before("unlock: the record of the machine passphrase is refused: ", principals.machine_file_problem_sentences[member]))
		facts_expect_line(t, render(t, file, "Machine_Tpm_Record_Refused", {{"problem", principals.machine_tpm_file_problem_sentences[member]}}), line_of_before("unlock: the record of the machine key sealed by the TPM is refused: ", principals.machine_tpm_file_problem_sentences[member]))
		facts_expect_line(t, render(t, file, "Machine_Tpm_Passphrase_Record_Refused", {{"problem", principals.machine_tpm_passphrase_file_problem_sentences[member]}}), line_of_before("unlock: the record of the machine key sealed by the TPM with the machine passphrase is refused: ", principals.machine_tpm_passphrase_file_problem_sentences[member]))
		facts_expect_line(t, render(t, file, "Principal_File_Refused", {{"problem", principals.file_problem_sentences[member]}}), line_of_before("unlock: the file of the principal is refused: ", principals.file_problem_sentences[member]))
		facts_expect_line(t, render(t, file, "Principal_Tpm_File_Refused", {{"problem", principals.principal_tpm_file_problem_sentences[member]}}), line_of_before("unlock: the file of the principal sealed by the TPM is refused: ", principals.principal_tpm_file_problem_sentences[member]))
	}
}

// Each fact type of unlock with no field, and the line that unlock wrote
// before it, as the source of unlock held it.
@(private = "file")
UNLOCK_NO_FIELD_LINES := [?][2]string {
	{"New_Principal_Sealed_Without_Secure_Boot", "unlock: the firmware did not verify the boot program (Secure Boot is off): the keys of the new principal are sealed under its passphrase alone, as a seal by the TPM would trust a boot program that nothing verified"},
	{"New_Principal_Sealed_Without_Tpm", "unlock: no TPM service: the keys of the new principal are sealed under its passphrase alone, with no recovery key"},
	{"Principal_Not_Created_Seed_Too_Weak", "unlock: the seed of this process is too weak for a key: no principal is created"},
	{"Keys_Not_Sealed_Seed_Too_Weak", "unlock: the seed of this process is too weak for a key: the keys are not sealed"},
	{"No_Screen_For_Machine_Passphrase", "unlock: no screen: the machine passphrase and the recovery key of the machine key cannot be typed: the disk grants of principal 0 and its client keys of remote stay absent"},
	{"No_Screen_For_Window", "unlock: no screen: the window of unlock cannot be shown: nothing is typed, and nothing changes"},
	{"Machine_Passphrase_Opened", "unlock: the machine passphrase opens the machine key; the root service receives the key of the disk grant table only"},
	{"Machine_Passphrase_Set_Without_Secure_Boot", "unlock: the firmware did not verify the boot program (Secure Boot is off): the machine key is sealed under the machine passphrase alone, as a seal by the TPM would trust a boot program that nothing verified"},
	{"Machine_Passphrase_Set_Without_Tpm", "unlock: no TPM service: the machine key is sealed under the machine passphrase alone, with no recovery key"},
	{"Machine_Passphrase_Not_Set_Seed_Too_Weak", "unlock: the seed of this process is too weak for a key: no machine passphrase is set"},
	{"Machine_Passphrase_Key_Not_Taken", "unlock: the root service did not take the key of the new machine passphrase; the record stays, and its passphrase opens it at the next start"},
	{"Tpm_Service_Stopped_At_Start", "unlock: the TPM service stopped: the machine key sealed by the TPM opens with its recovery key only"},
	{"Tpm_Service_Stopped_During_Request", "unlock: the TPM service stopped during a request"},
	{"Tpm_Seal_Parts_Refused", "unlock: the TPM service gave parts or PCRs that a record sealed by the TPM does not take"},
	{"Machine_Key_Not_Sealed_Seed_Too_Weak", "unlock: the seed of this process is too weak for a key: no machine key is sealed by the TPM"},
	{"Machine_Key_Not_Sealed_By_Tpm", "unlock: no machine key is sealed by the TPM: the TPM service did not seal it"},
	{"Machine_Key_Recovery_Copy_Failed", "unlock: the seal of the copy under the recovery key failed: no machine key is sealed by the TPM"},
	{"Machine_Key_Sealed_By_Tpm", "unlock: the machine key is sealed by the TPM to PCR 7 and PCR 11, with a copy under a recovery key; the window shows the recovery key one time, and the record is written when it is written down"},
	{"Machine_Key_Record_Not_Kept", "unlock: the store did not keep the record of the machine key; no machine key is sealed by the TPM"},
	{"Machine_Key_Record_Write_Unknown", "unlock: the store gave no answer on the record of the machine key sealed by the TPM, and its read back failed: the record may be on the disk; the window shows the recovery key until Enter again, and the root service receives no key"},
	{"Machine_Key_Record_Kept", "unlock: the record of the machine key sealed by the TPM is in the store of unlock: its recovery key is written down"},
	{"Machine_Key_Not_Taken", "unlock: the root service did not take the key of the new machine key; the record stays, and the TPM opens it at the next start"},
	{"Machine_Key_Needs_Tpm", "unlock: the machine key is sealed by the TPM, and no TPM service runs: the recovery key opens it"},
	{"Machine_Key_Check_Failed", "unlock: the key that the TPM released does not have the key check of the record: it is erased, and the recovery key opens the record"},
	{"Machine_Key_Released_Not_Taken", "unlock: the TPM released the machine key, and the root service did not take the key of its table: the disk grants of principal 0 stay absent until the next start"},
	{"Machine_Key_Released_By_Tpm", "unlock: the TPM releases the machine key: the system is the system of the seal; the root service receives the key of the disk grant table only"},
	{"Machine_Key_Not_Resealed_Without_Tpm", "unlock: no TPM service: the machine key is not sealed again, and the recovery key opens it at the next start too"},
	{"Machine_Key_Not_Resealed_Without_Secure_Boot", "unlock: the firmware did not verify the boot program (Secure Boot is off): the machine key is not sealed again, as its seal would trust a boot program that nothing verified; the recovery key opens it at the next start too"},
	{"Machine_Key_Not_Resealed", "unlock: the machine key is not sealed again: the recovery key opens it at the next start too"},
	{"Machine_Key_Resealed", "unlock: the machine key is sealed again to PCR 7 and PCR 11 of the system that runs: its next start needs no recovery key"},
	{"Machine_Recovery_Key_Opened", "unlock: the recovery key opens the machine key; the root service receives the key of the disk grant table only"},
	{"Machine_Recovery_Awaited", "unlock: the machine key waits for its recovery key: the disk grants of principal 0 come when it is typed"},
	{"Machine_Key_Not_Sealed_With_Passphrase_Seed_Too_Weak", "unlock: the seed of this process is too weak for a key: the machine key is not sealed by the TPM"},
	{"Keys_Not_Sealed_By_Tpm_Seed_Too_Weak", "unlock: the seed of this process is too weak for a key: the keys are not sealed by the TPM"},
	{"Machine_Key_Not_Sealed_With_Passphrase", "unlock: the TPM service did not seal the machine key with the machine passphrase"},
	{"Machine_Passphrase_Recovery_Key_Shown", "unlock: the window shows the recovery key of the new machine passphrase one time; the record is written when it is written down"},
	{"Machine_Passphrase_Tpm_Record_Not_Kept", "unlock: the store did not keep the record of the machine passphrase; no machine passphrase is set"},
	{"Machine_Passphrase_Record_Write_Unknown", "unlock: the store gave no answer on the record of the machine passphrase, and its read back failed: the record may be on the disk; the window shows the recovery key until Enter again, and the root service receives no key"},
	{"Machine_Passphrase_Sealed_By_Tpm", "unlock: the machine passphrase is set: the TPM seals the machine key with it, with a copy under a recovery key, in the store of unlock"},
	{"Machine_Passphrase_Locked_Out", "unlock: the TPM refuses each try of the machine passphrase for now: it counted too many wrong passphrases; the recovery key opens the machine key"},
	{"Machine_Key_Not_Consistent_With_Tpm_Secret", "unlock: the machine key does not open under the secret that the TPM released: the record is not consistent, and the recovery key opens it"},
	{"Machine_Key_Released_To_Passphrase", "unlock: the TPM releases the machine key to the machine passphrase: the system is the system of the seal; the root service receives the key of the disk grant table only"},
	{"Machine_Passphrase_Reseal_Awaited", "unlock: the machine key waits for a new machine passphrase: the TPM seals it again to it and to the system that runs"},
	{"Machine_Key_Resealed_With_Passphrase", "unlock: the machine key is sealed again to PCR 7 and PCR 11 of the system that runs and to the new machine passphrase: its next start needs no recovery key"},
	{"New_Principal_File_Not_Kept", "unlock: the store did not keep the file of the principal; no principal is created"},
	{"New_Principal_File_Write_Unknown", "unlock: the store gave no answer on the file of the new principal, and its read back failed: the file may be on the disk; the window shows the recovery key until Enter again, and the root service receives no record"},
	{"New_Principal_Record_Not_Taken", "unlock: the root service did not take the record of the new principal; its file stays, and its passphrase opens it at the next start"},
	{"Machine_Record_Form_Unknown", "unlock: the record of the machine key is refused: it starts with none of MACHINEK, MACHINET and MACHINEP"},
	{"Machine_Passphrase_Not_Typed", "unlock: the machine passphrase is not typed: the disk grants of principal 0 stay absent until unlock asks again"},
	{"Machine_Recovery_Key_Not_Typed_Passphrase_Asked", "unlock: the recovery key of the machine key is not typed: the window asks for the machine passphrase again"},
	{"Machine_Recovery_Key_Not_Typed", "unlock: the recovery key is not typed: the disk grants of principal 0 stay absent until unlock asks again"},
	{"Recovery_Key_Written_Down", "unlock: Enter on the recovery key: it is written down, and the record or the file that holds its copy is written now"},
	{"Machine_Reseal_Passphrase_Not_Typed", "unlock: no new machine passphrase is typed: the machine key is not sealed again, and the recovery key opens it at the next start too"},
	{"Principal_File_Form_Unknown", "unlock: the file of the principal is refused: it starts with neither PRINCIPL nor PRINCIPT"},
	{"No_Machine_Record", "unlock: no record of the machine key: the disk grants of principal 0 last until the machine stops, and the start policy of the boot image runs"},
	{"Machine_Record_Unreadable_Before_Start_Policy", "unlock: the record of the machine key cannot be read: the disk grants of principal 0 stay absent, and the start policy of the boot image runs"},
	{"Machine_Key_Opens_With_Passphrase", "unlock: the machine key opens with the machine passphrase: the window of unlock asks for it after the start policy starts"},
	{"Machine_Key_Not_Released_Before_Start_Policy", "unlock: the TPM did not release the machine key before the start policy: the window of unlock asks for its recovery key after the start policy starts"},
	{"No_Random_Seed", "unlock: the root service gave no random seed"},
	{"No_Root_Ring", "unlock: no ring to the root service"},
	{"No_Store", "unlock: no store: no named principal can be kept"},
	{"Machine_Key_Seal_Without_Tpm", "unlock: no TPM service: no machine key is sealed by the TPM"},
	{"Machine_Key_Seal_Without_Secure_Boot", "unlock: the firmware did not verify the boot program (Secure Boot is off): no machine key is sealed by the TPM"},
	{"Machine_Key_Record_Exists", "unlock: the machine has a record of its machine key already: a change is not built"},
	{"Machine_Key_Record_Unreadable", "unlock: the record of the machine key cannot be read: no new machine key replaces it"},
	{"New_Principal_Name_Refused", "unlock: the name of the new principal is refused"},
	{"Machine_Passphrase_Exists", "unlock: the machine has a passphrase already: a change is not built"},
	{"Machine_Passphrase_Record_Unreadable", "unlock: the record of the machine passphrase cannot be read: no new passphrase replaces it"},
	{"No_Principal_To_Change", "unlock: no named principal: there is no passphrase to change"},
	{"Machine_Key_With_Passphrase_Needs_Tpm", "unlock: the machine key is sealed by the TPM with the machine passphrase, and no TPM service runs: the recovery key opens it"},
	{"Machine_Record_Unreadable", "unlock: the record of the machine passphrase cannot be read: the disk grants of principal 0 stay absent, and nothing replaces the record"},
	{"Machine_Passphrase_Awaited", "unlock: the machine has a passphrase: the disk grants of principal 0 come when it is typed"},
	{"No_Named_Principal", "unlock: no named principal: the machine runs as principal 0, with no unlock"},
	{"Machine_Recovery_Asked", "unlock: the recovery key of the machine key is asked in the window: the TPM counts no try of the machine passphrase"},
}

// Each fact type of unlock with no field writes the line of before, and
// the table above names each such fact type of the module: a line with no
// value that this test does not hold fails it.
@(test)
the_facts_of_unlock_with_no_field_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "unlock")
	if !ok {
		return
	}
	for row in UNLOCK_NO_FIELD_LINES {
		facts_expect_line(t, fact_test_render(t, file, "unlock", row[0], {}), row[1])
	}
	no_field_types := 0
	rows := module.count(file, .Facts)
	for row_index in 1 ..< rows {
		_, description, row_ok := module.fact(file, row_index)
		if testing.expect(t, row_ok) && description.field_count == 0 {
			testing.expectf(t, description.size == 0, "a fact type of unlock with no field has %d bytes", description.size)
			no_field_types += 1
		}
	}
	testing.expectf(t, no_field_types == len(UNLOCK_NO_FIELD_LINES), "unlock has %d fact types with no field, and this test holds %d", no_field_types, len(UNLOCK_NO_FIELD_LINES))
}

// A status word of these tests, and how a reader writes it: the name of
// its member, or its number for a word that names no member.
@(private = "file")
Unlock_Status_Case :: struct {
	word:    u64,
	written: sentence.Part,
}

// Each fact type of unlock with a status of a kernel operation or of the
// root service writes the name of the member where the line wrote its
// number: each member of op.Status, the first word past the last member,
// and max(u64), which name no member and stay their numbers.
@(test)
the_facts_of_unlock_write_a_status_by_its_name :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "unlock")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "unlock", type_name, values)
	}
	cases := make([dynamic]Unlock_Status_Case, context.temp_allocator)
	for member in op.Status {
		append(&cases, Unlock_Status_Case{word = u64(member), written = op.STATUS_NAMES[member]})
	}
	past_the_last := u64(max(op.Status)) + 1
	append(&cases, Unlock_Status_Case{word = past_the_last, written = past_the_last})
	append(&cases, Unlock_Status_Case{word = max(u64), written = max(u64)})
	names := [2]string{"a", strings.repeat("n", principals.NAME_LIMIT, context.temp_allocator)}
	for item in cases {
		facts_expect_line(t, render(t, file, "Machine_Table_Key_Not_Taken", {{"status", item.word}}), line_of_before("unlock: the root service did not take the key of the disk grant table of principal 0: status ", item.written))
		facts_expect_line(t, render(t, file, "Tpm_Ring_Not_Opened", {{"status", item.word}}), line_of_before("unlock: the ring of the TPM service does not open: status ", item.written))
		facts_expect_line(t, render(t, file, "Tpm_Region_Not_Mapped", {{"status", item.word}}), line_of_before("unlock: the region of the TPM service does not map: status ", item.written))
		facts_expect_line(t, render(t, file, "Change_End_Not_Taken", {{"status", item.word}}), line_of_before("unlock: the root service did not take the end of the change: status ", item.written))
		facts_expect_line(t, render(t, file, "Session_Not_Started", {{"principal", max(u64)}, {"status", item.word}}), line_of_before("unlock: the root service did not start the session of principal ", max(u64), ": status ", item.written))
		facts_expect_line(t, render(t, file, "Machine_State_Not_Taken", {{"status", item.word}}), line_of_before("unlock: the root service did not take the state of the machine passphrase: status ", item.written))
		facts_expect_line(t, render(t, file, "Derivation_Memory_Refused", {{"status", item.word}}), line_of_before("unlock: no memory for the derivation of the key: status ", item.written))
		for principal_name in names {
			facts_expect_line(t, render(t, file, "Record_Not_Taken", {{"status", item.word}, {"principal_name", principal_name}}), line_of_before("unlock: the root service did not take the record of the principal \"", principal_name, "\": status ", item.written))
		}
	}
}

// The fact types of unlock that the field kinds of the contract made
// possible: the erase that the store refused, with its error record or
// with a status of the client of the store; the response code of the TPM
// in 16 hexadecimal digits, as system.Hex wrote it; and the refusal of a
// change, one fact type for each problem.
@(test)
the_facts_of_unlock_write_an_error_record_a_code_and_a_change_refused :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "unlock")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "unlock", type_name, values)
	}
	objects := [3]string{principals.FILE_OBJECT, principals.MACHINE_OBJECT, strings.repeat("o", UNLOCK_OBJECT_NAME_BYTES_MOST, context.temp_allocator)}
	signed_values := [4]i64{min(i64), -1, 0, max(i64)}
	erase_start :: "unlock: the store did not erase the versions of the object \""
	erase_end :: "\", and the next unlock tries again: kind "

	// Each kind with each unit's edge, the signed edges of the other values,
	// and a kind and a unit that name no member, which stay their numbers.
	for object in objects {
		for kind in errors.Kind {
			for value in signed_values {
				other := -1 - value
				fields := []Fact_Test_Field{{"kind", u64(kind)}, {"unit", u64(errors.Unit.Bytes)}, {"operation", signed_bits(value)}, {"argument", signed_bits(other)}, {"value", signed_bits(value)}, {"limit", signed_bits(other)}, {"found", signed_bits(value)}, {"object", object}}
				facts_expect_line(t, render(t, file, "Versions_Erase_Failed", fields), line_of_before(erase_start, object, erase_end, errors.KIND_NAMES[kind], ", unit ", errors.UNIT_MEMBER_NAMES[errors.Unit.Bytes], ", operation ", value, ", argument ", other, ", value ", value, ", limit ", other, ", found ", value))
			}
		}
		for unit in errors.Unit {
			fields := []Fact_Test_Field{{"kind", u64(errors.Kind.Too_Long)}, {"unit", u64(unit)}, {"object", object}}
			facts_expect_line(t, render(t, file, "Versions_Erase_Failed", fields), line_of_before(erase_start, object, erase_end, errors.KIND_NAMES[errors.Kind.Too_Long], ", unit ", errors.UNIT_MEMBER_NAMES[unit], ", operation ", i64(0), ", argument ", i64(0), ", value ", i64(0), ", limit ", i64(0), ", found ", i64(0)))
		}
		unknown := []Fact_Test_Field{{"kind", max(u64)}, {"unit", max(u64)}, {"object", object}}
		facts_expect_line(t, render(t, file, "Versions_Erase_Failed", unknown), line_of_before(erase_start, object, erase_end, max(u64), ", unit ", max(u64), ", operation ", i64(0), ", argument ", i64(0), ", value ", i64(0), ", limit ", i64(0), ", found ", i64(0)))
		words := [3]u64{0, 1, max(u64)}
		for word in words {
			facts_expect_line(t, render(t, file, "Versions_Not_Erased", {{"status_word", word}, {"object", object}}), line_of_before(erase_start, object, "\": status ", word, "; the next unlock tries again"))
		}
	}

	// The response code and the command code at their edges, for each
	// request.
	codes := [3]u64{0, 0x922, max(u64)}
	for request in UNLOCK_REQUESTS {
		for code in codes {
			command := max(u64) - code
			facts_expect_line(t, render(t, file, "Tpm_Refused_With_Response_Code", {{"response_code", code}, {"command_code", command}, {"request", request}}), line_of_before("unlock: the TPM refuses the ", request, ": response code ", sentence.Hex(code), " to the command ", sentence.Hex(command)))
		}
	}

	// Each problem of a change, by its fact type, with the sentence of the
	// problem whole.
	change_types := [principals.Change_Problem]string {
		.None             = "",
		.No_Recovery_Copy = "Change_Refused_No_Recovery_Copy",
		.No_Tpm_Service   = "Change_Refused_No_Tpm_Service",
		.Seal_Not_Allowed = "Change_Refused_Seal_Not_Allowed",
		.Unknown_Form     = "Change_Refused_Unknown_Form",
		.Unknown_Change   = "Change_Refused_Unknown_Change",
		.Wrong_Principal  = "Change_Refused_Wrong_Principal",
	}
	numbers := [3]u64{0, 1, max(u64)}
	names := [2]string{"a", strings.repeat("n", principals.NAME_LIMIT, context.temp_allocator)}
	for problem in principals.Change_Problem {
		if problem == .None {
			continue
		}
		for number in numbers {
			for principal_name in names {
				facts_expect_line(t, name_and_number(t, file, change_types[problem], number, principal_name), line_of_before("unlock: principal ", number, " \"", principal_name, "\" is not changed: ", principals.change_problem_sentences[problem]))
			}
		}
	}
}
