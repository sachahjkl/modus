package build

import module "modus:contract/module"
import "modus:contract/tpm_service"
import "modus:support/principals"
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
		wrong_counts := [3]int{0, size - 1, size + 1}
		for count in wrong_counts {
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
		facts_expect_line(t, render(t, file, "Machine_Table_Key_Not_Taken", {{"status_word", number}}), line_of_before("unlock: the root service did not take the key of the disk grant table of principal 0: status ", number))
		facts_expect_line(t, render(t, file, "Machine_Passphrase_Wrong", {{"refusals", number}}), line_of_before("unlock: the machine passphrase is wrong: the seal does not open, the disk grants of principal 0 stay absent (", number, " in all)"))
		facts_expect_line(t, render(t, file, "Machine_Passphrase_Record_Not_Kept", {{"status_word", number}}), line_of_before("unlock: the store did not keep the record of the machine passphrase: status ", number))
		facts_expect_line(t, render(t, file, "Tpm_Ring_Not_Opened", {{"status_word", number}}), line_of_before("unlock: the ring of the TPM service does not open: status ", number))
		facts_expect_line(t, render(t, file, "Tpm_Region_Not_Mapped", {{"status_word", number}}), line_of_before("unlock: the region of the TPM service does not map: status ", number))
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
		facts_expect_line(t, render(t, file, "Change_End_Not_Taken", {{"status_word", number}}), line_of_before("unlock: the root service did not take the end of the change: status ", number))
		facts_expect_line(t, render(t, file, "Principal_Not_Resealed_Without_Tpm", {{"principal", number}}), line_of_before("unlock: no TPM service: the keys of principal ", number, " are not sealed again, and the recovery key opens them at the next start too"))
		facts_expect_line(t, render(t, file, "Principal_Not_Resealed_Without_Secure_Boot", {{"principal", number}}), line_of_before("unlock: the firmware did not verify the boot program (Secure Boot is off): the keys of principal ", number, " are not sealed again, as their seal would trust a boot program that nothing verified; the recovery key opens them at the next start too"))
		facts_expect_line(t, render(t, file, "Principal_Not_Resealed", {{"principal", number}}), line_of_before("unlock: the keys of principal ", number, " are not sealed again: the recovery key opens them at the next start too"))
		facts_expect_line(t, render(t, file, "Principal_Reseal_Not_Kept", {{"principal", number}, {"status_word", other}}), line_of_before("unlock: the store did not keep the new seal of the keys of principal ", number, ": status ", other, "; the recovery key opens them at the next start too"))
		facts_expect_line(t, render(t, file, "Session_Not_Started_After_Recovery", {{"principal", number}}), line_of_before("unlock: the session of principal ", number, " did not start after its recovery; the next start of unlock asks again"))
		facts_expect_line(t, render(t, file, "Machine_Record_Not_Read", {{"status_word", number}}), line_of_before("unlock: the store did not give the record of the machine passphrase: status ", number))
		facts_expect_line(t, render(t, file, "Session_Not_Started", {{"principal", number}, {"status_word", other}}), line_of_before("unlock: the root service did not start the session of principal ", number, ": status ", other))
		facts_expect_line(t, render(t, file, "Principal_Recovery_Key_Not_Typed", {{"principal", number}}), line_of_before("unlock: the recovery key of principal ", number, " is not typed: the window asks for its passphrase again"))
		facts_expect_line(t, render(t, file, "Current_Passphrase_Not_Typed", {{"principal", number}}), line_of_before("unlock: the current passphrase of principal ", number, " is not typed: nothing changes"))
		facts_expect_line(t, render(t, file, "New_Passphrase_Not_Typed", {{"principal", number}}), line_of_before("unlock: the new passphrase of principal ", number, " is not typed: nothing changes"))
		facts_expect_line(t, render(t, file, "Principal_File_Not_Read", {{"status_word", number}}), line_of_before("unlock: the store did not give the file of the principal: status ", number))
		facts_expect_line(t, render(t, file, "Machine_State_Not_Taken", {{"status_word", number}}), line_of_before("unlock: the root service did not take the state of the machine passphrase: status ", number))
		facts_expect_line(t, render(t, file, "Mode_Unknown", {{"mode_word", number}}), line_of_before("unlock: the root service gave the mode ", number, ", which names no mode of unlock: nothing is done"))
		facts_expect_line(t, render(t, file, "Derivation_Memory_Refused", {{"status_word", number}}), line_of_before("unlock: no memory for the derivation of the key: status ", number))
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
			facts_expect_line(t, render(t, file, "Record_Not_Taken", {{"status_word", number}, {"principal_name", principal_name}}), line_of_before("unlock: the root service did not take the record of the principal \"", principal_name, "\": status ", number))
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
