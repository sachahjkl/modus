package boot

// The trusted boot of the boot program (docs/TRUSTED_BOOT.md): before the
// kernel starts, it verifies the description signature with the public key
// that it holds, then the hash of the kernel and of each module and
// resource of the boot image against the system description; then it asks
// the firmware to measure the description into the TPM. A failed check
// stops the boot with the failure on the boot display.
//
// Between the checks and the measure, it reads the TPM floors through the
// firmware, refuses a boot program whose key number, or a system
// description whose security version, is below its floor, and with Secure
// Boot on raises the floors to its own numbers
// (src/md/features/rollback_floors.md).
//
// What this proves depends on what verified the boot program itself. With
// Secure Boot off, nothing did: whoever can write the boot volume can
// replace the boot program, its public key and its checks. The checks then
// find a damaged or swapped file, not an attacker.

import "base:intrinsics"
import "base:runtime"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/byte_order"
import "modus:contract/system_description"
import "modus:support/bootscreen"
import "modus:support/cryptography/ed25519"
import "modus:support/tpm2"

// The key of the system, 40 bytes: the public key of the signing key, then
// its key number as a little-endian u64. The tool writes it before it
// builds the boot program (tools/modustool/build/system_description.odin).
system_key := #load(#config(SYSTEM_KEY, "../../build/system_key.bin"))
SYSTEM_KEY_SIZE :: system_description.PUBLIC_KEY_SIZE + 8

// trust_check verifies the system description of the boot image and gives
// its bytes. It fills the trust record. It does not return when a check
// fails.
trust_check :: proc "contextless" (boot: ^info.Boot_Info, image: []u8) -> (description: []u8) {
	trust := &boot.trust
	start := u64(intrinsics.read_cycle_counter())
	if len(system_key) != SYSTEM_KEY_SIZE {
		trust_fail(boot, .Boot_Image, "the boot program holds no public key of 32 bytes with its key number")
	}
	copy(trust.public_key[:], system_key[:system_description.PUBLIC_KEY_SIZE])
	for index in 0 ..< 8 {
		trust.key_number |= u64(system_key[system_description.PUBLIC_KEY_SIZE + index]) << (8 * u64(index))
	}
	if trust.key_number == 0 || trust.key_number > info.FLOOR_LIMIT {
		trust_fail(boot, .Boot_Image, "the key number of the boot program is not 1 to 64")
	}
	trust.key_kind = trust.public_key == system_description.TEST_PUBLIC_KEY ? info.Signing_Key_Kind.Test : info.Signing_Key_Kind.Person
	signature: []u8
	found: bool
	description, signature, found = system_description.trust_resources(image)
	if !found {
		trust_fail(boot, .Boot_Image, "the boot image has no system description and description signature as its two last resources")
	}
	list, valid := system_description.entries(description)
	if !valid {
		trust_fail(boot, .Boot_Image, "the system description does not follow its format")
	}
	message := system_description.signed_message(description)
	if !signature_verifies(trust.public_key[:], message[:], signature) {
		trust_fail(boot, .Boot_Image, "the signature of the system description is wrong")
	}
	if kernel_result := system_description.kernel_check(description, kernel_file); kernel_result.fault != .None {
		check_fail(boot, .Kernel_Module, &kernel_result)
	}
	if image_result := system_description.image_check(description, image); image_result.fault != .None {
		check_fail(boot, .Boot_Image, &image_result)
	}
	trust.verifier = secure_boot_on() ? info.Verifier.Firmware_And_Boot_Program : info.Verifier.Boot_Program
	trust.description_hash = blake3.hash(description)
	trust.entry_count = u64(len(list))
	trust.check_cycles = u64(intrinsics.read_cycle_counter()) - start

	text: bootscreen.Text
	bootscreen.put(&text, "boot program: the system description has ")
	bootscreen.put_number(&text, trust.entry_count)
	bootscreen.put(&text, " entries, BLAKE3 ")
	print(string(text.bytes[:text.count]))
	hash_digits := system_description.hexadecimal(trust.description_hash)
	print(string(hash_digits[:]))
	print("\r\n")
	if trust.key_kind == .Test {
		print("boot program: the signature is from the test signing key, whose private key is published: this system is not trusted\r\n")
	} else {
		key_digits := system_description.hexadecimal(trust.public_key)
		print("boot program: the signature is from the key ")
		print(string(key_digits[:]))
		print("\r\n")
	}
	if trust.verifier == .Firmware_And_Boot_Program {
		print("boot program: verified by the firmware (Secure Boot), then by the boot program\r\n")
	} else {
		print("boot program: verified by the boot program, which the firmware did not verify\r\n")
	}
	print("boot program: the kernel and each module and resource have the hash of the system description\r\n")
	return
}

// signature_verifies checks an Ed25519 signature with the code that the
// module cryptography also runs (docs/CRYPTOGRAPHY.md). A public key that is
// not a point, or a point of small order, fails.
signature_verifies :: #force_no_inline proc "contextless" (public_key, message, signature: []u8) -> bool {
	// The code of the origin needs a context; a zero one, as in the module
	// cryptography: it allocates nothing here.
	context = runtime.Context{}
	key: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&key, public_key) {
		return false
	}
	return ed25519.verify(&key, message, signature)
}

// secure_boot_on reads the variable SecureBoot of the firmware: 1 when the
// firmware starts only a boot program that a key of its db signed.
secure_boot_on :: proc "contextless" () -> bool {
	name := [?]u16{'S', 'e', 'c', 'u', 'r', 'e', 'B', 'o', 'o', 't', 0}
	guid := EFI_GLOBAL_VARIABLE_GUID
	value: u8
	size := uint(1)
	if system.runtime_services.get_variable(raw_data(name[:]), &guid, nil, &size, &value) != 0 {
		return false
	}
	return size == 1 && value == 1
}

// check_fail writes the failure of a check of the hashes, with the expected
// and the found value, then stops.
check_fail :: proc "contextless" (boot: ^info.Boot_Info, step: bootscreen.Step, result: ^system_description.Check) -> ! {
	name := system_description.name_of(&result.name)
	sentence := system_description.fault_sentences[result.fault]
	shown: bootscreen.Text
	numbers: bootscreen.Text
	print("boot program: ")
	switch result.fault {
	case .None, .Not_Valid, .Image_Not_Valid:
		print(sentence)
		bootscreen.put(&shown, sentence)
	case .Count_Differs:
		print(sentence)
		bootscreen.put(&numbers, ": expected ")
		bootscreen.put_number(&numbers, result.expected_size)
		bootscreen.put(&numbers, ", found ")
		bootscreen.put_number(&numbers, result.found_size)
		print(string(numbers.bytes[:numbers.count]))
		bootscreen.put(&shown, "the boot image has another count of entries")
		bootscreen.put(&shown, string(numbers.bytes[:numbers.count]))
	case .Name_Differs, .Kind_Differs, .Outside_Image:
		print(name)
		print(": ")
		print(sentence)
		bootscreen.put(&shown, name)
		bootscreen.put(&shown, ": ")
		bootscreen.put(&shown, sentence)
	case .Size_Differs:
		print(name)
		print(" ")
		print(sentence)
		bootscreen.put(&numbers, ": expected ")
		bootscreen.put_number(&numbers, result.expected_size)
		bootscreen.put(&numbers, " bytes, found ")
		bootscreen.put_number(&numbers, result.found_size)
		bootscreen.put(&numbers, " bytes")
		print(string(numbers.bytes[:numbers.count]))
		bootscreen.put(&shown, name)
		bootscreen.put(&shown, ": wrong size")
		bootscreen.put(&shown, string(numbers.bytes[:numbers.count]))
	case .Hash_Differs, .Stated_Hash_Differs:
		expected := system_description.hexadecimal(result.expected_hash)
		found := system_description.hexadecimal(result.found_hash)
		print(name)
		print(" ")
		print(sentence)
		print(": expected ")
		print(string(expected[:]))
		print(", found ")
		print(string(found[:]))
		bootscreen.put(&shown, name)
		bootscreen.put(&shown, result.fault == .Hash_Differs ? ": wrong hash: expected " : ": wrong stated hash: expected ")
		bootscreen.put(&shown, string(expected[:16]))
		bootscreen.put(&shown, ", found ")
		bootscreen.put(&shown, string(found[:16]))
	}
	print("\r\n")
	// The card of the boot image names the file whole, also when the head
	// has no room for its whole sentence.
	switch result.fault {
	case .Name_Differs, .Kind_Differs, .Outside_Image, .Size_Differs, .Hash_Differs, .Stated_Hash_Differs:
		display_data.failed_name = name
	case .None, .Not_Valid, .Image_Not_Valid, .Count_Differs:
		// No one file of the boot image is at fault.
	}
	boot_stop(boot, step, string(shown.bytes[:shown.count]))
}

// trust_fail writes one failure on the log and on the boot display, then
// stops.
trust_fail :: proc "contextless" (boot: ^info.Boot_Info, step: bootscreen.Step, text: string) -> ! {
	print("boot program: ")
	print(text)
	print("\r\n")
	boot_stop(boot, step, text)
}

// The commands of the TPM that the boot program sends (TPM 2.0 Library,
// Part 3): the read of one register in the SHA-256 bank.
TPM_ST_NO_SESSIONS :: 0x8001
TPM_CC_PCR_READ :: 0x0000_017E
TPM_ALG_SHA256 :: 0x000B
// TPM2_PCR_Read: tag, size, command code, one selection of 3 bytes.
TPM_PCR_READ_COMMAND_SIZE :: 2 + 4 + 4 + 4 + 2 + 1 + 3
// The registers that a selection of 3 bytes names: PCR 0 to 23.
TPM_SELECTION_SIZE :: 3

// The tries of the measure. A command of the TPM that the interface of the
// firmware does not finish in its time is reported as a device error; a
// slow interface can finish the next one. 4 tries, 0.5 s apart, add 1.5 s
// at most to a boot whose TPM refuses for good.
MEASURE_TRY_COUNT :: 4
MEASURE_TRY_WAIT_MICROSECONDS :: 500_000

// measure asks the firmware to extend the measure register with the
// SHA-256 hash of the system description, then reads the register back.
//
// The rule when it fails (docs/TRUSTED_BOOT.md, "The measure"): the boot
// continues, and the trust record, the boot display and the log say which
// state holds: no TPM, measured, refused, or measured with no read. No key
// is sealed to the measure yet, so a stop would protect nothing: a missing
// measure is visible to a party that reads PCR 11.
measure :: proc "contextless" (boot: ^info.Boot_Info, description: []u8) {
	trust := &boot.trust
	trust.measure_register = info.MEASURE_REGISTER
	guid := EFI_TCG2_GUID
	tpm: ^Efi_Tcg2_Protocol
	if system.boot_services.locate_protocol(&guid, nil, (^rawptr)(&tpm)) != 0 || tpm == nil {
		trust.measure = .No_Tpm
		print("boot program: the firmware has no TPM protocol: the system description is not measured\r\n")
		return
	}
	// The event data is the signed message: the event log names the
	// description by its BLAKE3 hash, the identity of the system.
	message := system_description.signed_message(description)
	event: [EFI_TCG2_EVENT_DATA_OFFSET + system_description.SIGNED_MESSAGE_SIZE]u8
	byte_order.write_u32_little_endian(event[0:], 0, u32(len(event)))
	byte_order.write_u32_little_endian(event[4:], 0, EFI_TCG2_EVENT_HEADER_SIZE)
	event[8] = EFI_TCG2_EVENT_HEADER_VERSION
	byte_order.write_u32_little_endian(event[10:], 0, u32(info.MEASURE_REGISTER))
	byte_order.write_u32_little_endian(event[14:], 0, TCG_EVENT_IPL)
	copy(event[EFI_TCG2_EVENT_DATA_OFFSET:], message[:])
	text: bootscreen.Text
	status: Efi_Status
	for attempt in 1 ..= MEASURE_TRY_COUNT {
		trust.measure_tries = u64(attempt)
		status = tpm.hash_log_extend_event(tpm, 0, u64(uintptr(raw_data(description))), u64(len(description)), raw_data(event[:]))
		if status == 0 {
			break
		}
		text.count = 0
		bootscreen.put(&text, "boot program: try ")
		bootscreen.put_number(&text, u64(attempt))
		bootscreen.put(&text, " of the measure: the firmware answered status ")
		bootscreen.put_hex(&text, u64(status), 16)
		print(string(text.bytes[:text.count]))
		print("\r\n")
		if attempt < MEASURE_TRY_COUNT {
			system.boot_services.stall(MEASURE_TRY_WAIT_MICROSECONDS)
		}
	}
	text.count = 0
	if status != 0 {
		trust.measure = .Refused
		trust.measure_status = u64(status)
		bootscreen.put(&text, "boot program: the TPM refused the measure of the system description: status ")
		bootscreen.put_hex(&text, u64(status), 16)
		print(string(text.bytes[:text.count]))
		print("\r\n")
		// Which part refuses: when a read through the same protocol fails
		// too, with no command at the TPM, the firmware has marked its TPM
		// as absent after an earlier error of its own.
		_, probe_status, probe_read := register_read(tpm, info.MEASURE_REGISTER)
		text.count = 0
		bootscreen.put(&text, "boot program: a read of PCR 11 through the same firmware: ")
		if probe_read {
			bootscreen.put(&text, "it works")
		} else {
			bootscreen.put(&text, "status ")
			bootscreen.put_hex(&text, probe_status, 16)
		}
		print(string(text.bytes[:text.count]))
		print("\r\n")
		return
	}
	if trust.measure_tries > 1 {
		bootscreen.put(&text, "boot program: the measure succeeded at try ")
		bootscreen.put_number(&text, trust.measure_tries)
		print(string(text.bytes[:text.count]))
		print("\r\n")
		text.count = 0
	}
	value, read_status, read := register_read(tpm, info.MEASURE_REGISTER)
	if !read {
		trust.measure = .Not_Read
		trust.measure_status = read_status
		bootscreen.put(&text, "boot program: the system description is measured, but the read of the register failed: ")
		bootscreen.put_hex(&text, read_status, 16)
		print(string(text.bytes[:text.count]))
		print("\r\n")
		return
	}
	trust.measure = .Measured
	trust.measure_value = value
	digits := system_description.hexadecimal(value)
	bootscreen.put(&text, "boot program: PCR ")
	bootscreen.put_number(&text, info.MEASURE_REGISTER)
	bootscreen.put(&text, " = ")
	print(string(text.bytes[:text.count]))
	print(string(digits[:]))
	print("\r\n")
}

// register_read reads one register of the SHA-256 bank with TPM2_PCR_Read,
// through the firmware. status is the status of the firmware or the
// response code of the TPM when read is false.
register_read :: proc "contextless" (tpm: ^Efi_Tcg2_Protocol, register: u64) -> (value: [32]u8, status: u64, read: bool) {
	command: [TPM_PCR_READ_COMMAND_SIZE]u8
	byte_order.write_u16_big_endian(command[0:], 0, TPM_ST_NO_SESSIONS)
	byte_order.write_u32_big_endian(command[2:], 0, TPM_PCR_READ_COMMAND_SIZE)
	byte_order.write_u32_big_endian(command[6:], 0, TPM_CC_PCR_READ)
	byte_order.write_u32_big_endian(command[10:], 0, 1) // One selection.
	byte_order.write_u16_big_endian(command[14:], 0, TPM_ALG_SHA256)
	command[16] = TPM_SELECTION_SIZE
	command[17 + register / 8] = u8(1) << (register % 8)
	response: [256]u8
	firmware_status := tpm.submit_command(tpm, u32(len(command)), raw_data(command[:]), u32(len(response)), raw_data(response[:]))
	if firmware_status != 0 {
		return {}, u64(firmware_status), false
	}
	// The response: tag (2 bytes), size (4), response code (4), the update
	// counter (4), the selections that the TPM read, then the digests.
	size := int(byte_order.read_u32_big_endian(response[2:], 0))
	code := byte_order.read_u32_big_endian(response[6:], 0)
	if code != 0 {
		return {}, u64(code), false
	}
	if size > len(response) {
		return {}, 0, false
	}
	at := 14
	if at + 4 + 3 + TPM_SELECTION_SIZE + 4 + 2 + 32 > size || byte_order.read_u32_big_endian(response[at:], 0) != 1 {
		return {}, 0, false
	}
	at += 4
	algorithm := byte_order.read_u16_big_endian(response[at:], 0)
	selection_size := int(response[at + 2])
	at += 3
	// A TPM with no SHA-256 bank, or that did not read the register, gives
	// an empty selection.
	if algorithm != TPM_ALG_SHA256 || selection_size != TPM_SELECTION_SIZE || response[at + int(register / 8)] & (u8(1) << (register % 8)) == 0 {
		return {}, 0, false
	}
	at += selection_size
	if byte_order.read_u32_big_endian(response[at:], 0) != 1 || byte_order.read_u16_big_endian(response[at + 4:], 0) != 32 {
		return {}, 0, false
	}
	at += 6
	copy(value[:], response[at:][:32])
	return value, 0, true
}

// The register of the policy of the TPM floors: the state of Secure Boot,
// with the certificate that verified the boot program. The policy also
// names PCR 11 with the value that it has before the measure.
FLOOR_POLICY_REGISTER :: 7
// The bytes of a command of the floors, and of the response buffer that the
// firmware fills: the largest command is the definition of an index, 77
// bytes; the largest answer is the public area of an index with its name,
// about 100 bytes.
FLOOR_COMMAND_LIMIT :: 128
FLOOR_RESPONSE_LIMIT :: 512

// floors_check reads the TPM floors through the firmware, before the
// measure: the key floor, and the version floor of the key number of this
// boot program. It stops the start when the key number is below the key
// floor, or the security version of the description below the version
// floor. Then, with Secure Boot on, it raises both floors to its own
// numbers (src/md/features/rollback_floors.md). It fills the trust record.
//
// The check is the work of this boot program, the code of the volume that
// starts: a refused system runs no kernel and no process. A floor that
// cannot be read is 0, and the start goes on: a TPM that the firmware
// stopped using would else stop each start, and such a machine opens no key
// sealed by the TPM either.
//
// The raise is here, before the measure, because the policy of a floor
// names PCR 11 before the measure: after it, no kernel and no process, not
// even one of a system that a stolen key signed, can raise a floor.
floors_check :: proc "contextless" (boot: ^info.Boot_Info, description: []u8) {
	trust := &boot.trust
	trust.security_version, _ = system_description.security_version_of(description)
	guid := EFI_TCG2_GUID
	tpm: ^Efi_Tcg2_Protocol
	if system.boot_services.locate_protocol(&guid, nil, (^rawptr)(&tpm)) != 0 || tpm == nil {
		print("boot program: the firmware has no TPM protocol: no TPM floor is read, and no older system is refused\r\n")
		return
	}
	version_index := info.version_floor_index(trust.key_number)
	// The policy of a floor of this system names PCR 7 as it is now: an
	// index whose policy names another PCR 7 is foreign.
	pcr_7, pcr_status, pcr_read := register_read(tpm, FLOOR_POLICY_REGISTER)
	policy: [32]u8
	// The boot program keeps each state as its member, and writes its word
	// in the trust record, which the kernel and the root service read.
	key_floor_state, version_floor_state: info.Floor_State
	if !pcr_read {
		version_floor_state = .Not_Read
		key_floor_state = .Not_Read
		trust.floor_status = pcr_status
	} else {
		policy = tpm2.floor_policy_digest(&pcr_7)
		trust.key_floor, key_floor_state = floor_read(tpm, info.KEY_FLOOR_INDEX, &policy, &trust.floor_status)
		trust.version_floor, version_floor_state = floor_read(tpm, version_index, &policy, &trust.floor_status)
	}
	trust.key_floor_state = u64(key_floor_state)
	trust.version_floor_state = u64(version_floor_state)

	// The line is longer than one text of the boot display: it goes out in
	// parts.
	print("boot program: the TPM floors: the key floor ")
	print_number(trust.key_floor)
	print(floor_state_words(key_floor_state))
	print(", the version floor of the key number ")
	print_number(trust.key_number)
	print(" ")
	print_number(trust.version_floor)
	print(floor_state_words(version_floor_state))
	print("\r\n")
	text: bootscreen.Text
	if trust.floor_status != 0 {
		bootscreen.put(&text, "boot program: a read of the TPM floors failed: status ")
		bootscreen.put_hex(&text, trust.floor_status, 16)
		print(string(text.bytes[:text.count]))
		print("\r\n")
	}
	print("boot program: this boot program has the key number ")
	print_number(trust.key_number)
	print(", and the system description the security version ")
	print_number(trust.security_version)
	print("\r\n")

	// The key first: a description that a revoked key signed proves
	// nothing, its security version included. Each refusal fits one text of
	// the boot display, which shows it.
	refusal: bootscreen.Text
	if trust.key_number < trust.key_floor {
		bootscreen.put(&refusal, "the key number ")
		bootscreen.put_number(&refusal, trust.key_number)
		bootscreen.put(&refusal, " of this boot program is below the key floor ")
		bootscreen.put_number(&refusal, trust.key_floor)
		bootscreen.put(&refusal, " of the TPM: its key is revoked")
		trust_fail(boot, .Boot_Image, string(refusal.bytes[:refusal.count]))
	}
	if trust.security_version < trust.version_floor {
		bootscreen.put(&refusal, "the security version ")
		bootscreen.put_number(&refusal, trust.security_version)
		bootscreen.put(&refusal, " of the system description is below the version floor ")
		bootscreen.put_number(&refusal, trust.version_floor)
		bootscreen.put(&refusal, " of the TPM: an older system")
		trust_fail(boot, .Boot_Image, string(refusal.bytes[:refusal.count]))
	}

	if !pcr_read {
		return
	}
	// With Secure Boot off, PCR 7 says "off": a floor defined now would
	// have a policy that any boot program satisfies.
	if trust.verifier != .Firmware_And_Boot_Program {
		print("boot program: the TPM floors stay as they are: the firmware did not verify this boot program\r\n")
		return
	}
	key_name: bootscreen.Text
	bootscreen.put(&key_name, "the key floor")
	floor_raise(tpm, info.KEY_FLOOR_INDEX, string(key_name.bytes[:key_name.count]), key_floor_state, trust.key_floor, trust.key_number, &policy)
	version_name: bootscreen.Text
	bootscreen.put(&version_name, "the version floor of the key number ")
	bootscreen.put_number(&version_name, trust.key_number)
	floor_raise(tpm, version_index, string(version_name.bytes[:version_name.count]), version_floor_state, trust.version_floor, trust.security_version, &policy)
}

// floor_raise raises one floor to number, which the checks put at or above
// it, with the step that package tpm2 gives for its state: it removes an
// index that is not a floor that this boot program can read (planted by
// another system, or of another PCR 7), defines an absent one, then sets
// the bit of number in a policy session of PCR 7 and PCR 11. A step that
// fails writes one line, and the floor stays: a floor that does not rise
// refuses less, and stops no start.
floor_raise :: proc "contextless" (tpm: ^Efi_Tcg2_Protocol, index: u32, name: string, state: info.Floor_State, floor: u64, number: u64, policy: ^[32]u8) {
	command: [FLOOR_COMMAND_LIMIT]u8
	response: [FLOOR_RESPONSE_LIMIT]u8
	step := tpm2.floor_step_of(state)
	if step == .Nothing {
		return
	}
	if step == .Raise && number <= floor {
		print("boot program: ")
		print(name)
		print(" is ")
		print_number(floor)
		print(": this boot program, with the number ")
		print_number(number)
		print(", leaves it\r\n")
		return
	}
	if step == .Remove_Then_Define_Then_Raise {
		count := tpm2.nv_undefine_command(command[:], index)
		if !floor_command_run(tpm, command[:count], response[:], name, "TPM2_NV_UndefineSpace") {
			return
		}
		print("boot program: ")
		print(name)
		switch state {
		case .Never_Written:
			print(": removed an index that was never written: another system planted it\r\n")
		case .Read_Refused:
			print(": removed an index whose read the TPM refuses: another system planted it with an authorization value\r\n")
		case .Foreign:
			print(": removed a foreign index: another system defined it, or PCR 7 changed\r\n")
		case .None, .Absent, .Held, .Not_Read:
			// floor_step_of removes the index of no such state.
			print(": removed an index\r\n")
		}
	}
	if step != .Raise {
		count := tpm2.floor_define_command(command[:], index, policy)
		if !floor_command_run(tpm, command[:count], response[:], name, "TPM2_NV_DefineSpace") {
			return
		}
		print("boot program: ")
		print(name)
		print(": defined its index\r\n")
	}
	// A policy session: TPM2_PolicyPCR of PCR 7 and PCR 11 now, which the
	// policy of the index names.
	count := tpm2.start_session_command(command[:], .Policy)
	answer, firmware_status, answered := firmware_submit(tpm, command[:count], response[:])
	if !answered {
		floor_step_failed(name, "TPM2_StartAuthSession", firmware_status)
		return
	}
	session, code, problem := tpm2.handle_answer(answer)
	if problem != .None {
		floor_step_failed(name, "TPM2_StartAuthSession", u64(code))
		return
	}
	defer {
		flush_count := tpm2.flush_command(command[:], session)
		_, _, _ = firmware_submit(tpm, command[:flush_count], response[:])
	}
	count = tpm2.policy_pcr_command(command[:], session)
	if !floor_command_run(tpm, command[:count], response[:], name, "TPM2_PolicyPCR") {
		return
	}
	count = tpm2.floor_set_bits_command(command[:], index, session, tpm2.floor_bit(number))
	if !floor_command_run(tpm, command[:count], response[:], name, "TPM2_NV_SetBits") {
		return
	}
	print("boot program: ")
	print(name)
	print(" rose from ")
	print_number(step == .Raise ? floor : 0)
	print(" to ")
	print_number(number)
	print("\r\n")
}

// floor_command_run sends one command of a raise and reads an answer with
// no field that the raise needs. A failure writes one line.
floor_command_run :: proc "contextless" (tpm: ^Efi_Tcg2_Protocol, command: []u8, response: []u8, name: string, command_name: string) -> bool {
	answer, firmware_status, answered := firmware_submit(tpm, command, response)
	if !answered {
		floor_step_failed(name, command_name, firmware_status)
		return false
	}
	code, problem := tpm2.status_answer(answer)
	if problem != .None {
		floor_step_failed(name, command_name, u64(code))
		return false
	}
	return true
}

// floor_step_failed writes the failure of one command of a raise: the
// status of the firmware, or the response code of the TPM (0: an answer
// that does not have its form).
floor_step_failed :: proc "contextless" (name: string, command_name: string, status: u64) {
	text: bootscreen.Text
	bootscreen.put_hex(&text, status, 16)
	print("boot program: ")
	print(name)
	print(": the TPM refused ")
	print(command_name)
	print(" (status ")
	print(string(text.bytes[:text.count]))
	print("): the floor stays\r\n")
}

// print_number writes a number in decimal digits on the log.
print_number :: proc "contextless" (value: u64) {
	text: bootscreen.Text
	bootscreen.put_number(&text, value)
	print(string(text.bytes[:text.count]))
}

// floor_state_words gives the words of the state of a floor that follow its
// number on the log.
floor_state_words :: proc "contextless" (state: info.Floor_State) -> string {
	switch state {
	case .None:
		return " (not read: no TPM)"
	case .Absent:
		return " (no index: no system defined it)"
	case .Held:
		return " (held)"
	case .Foreign:
		return " (a foreign index, taken as 0: another system defined it, or PCR 7 changed)"
	case .Not_Read:
		return " (not read, taken as 0)"
	case .Never_Written:
		return " (an index never written, taken as 0)"
	case .Read_Refused:
		return " (an index whose read the TPM refuses, taken as 0)"
	}
	return ""
}

// floor_read reads one floor: the public area of its index, then, for the
// area of a floor of this system that was written, its 8 bytes. Each answer
// comes from the TPM through the firmware; package tpm2 reads it and
// decides the state. status keeps the code of the first read that failed.
floor_read :: proc "contextless" (tpm: ^Efi_Tcg2_Protocol, index: u32, policy: ^[32]u8, status: ^u64) -> (floor: u64, state: info.Floor_State) {
	command: [FLOOR_COMMAND_LIMIT]u8
	response: [FLOOR_RESPONSE_LIMIT]u8
	count := tpm2.nv_read_public_command(command[:], index)
	answer, firmware_status, answered := firmware_submit(tpm, command[:count], response[:])
	if !answered {
		floor_status_keep(status, firmware_status)
		return 0, .Not_Read
	}
	public, code, problem := tpm2.nv_public_answer(answer)
	state = tpm2.floor_state_of_public(problem, code, &public, index, policy)
	if state == .Not_Read {
		floor_status_keep(status, u64(code))
	}
	if state != .Held {
		return 0, state
	}
	count = tpm2.nv_read_command(command[:], index)
	answer, firmware_status, answered = firmware_submit(tpm, command[:count], response[:])
	if !answered {
		floor_status_keep(status, firmware_status)
		return 0, .Not_Read
	}
	bits: u64
	bits, code, problem = tpm2.nv_read_answer(answer)
	state, floor = tpm2.floor_state_of_read(problem, code, bits)
	if state != .Held {
		floor_status_keep(status, u64(code))
	}
	return floor, state
}

floor_status_keep :: proc "contextless" (status: ^u64, code: u64) {
	if status^ == 0 {
		status^ = code
	}
}

// firmware_submit sends one command to the TPM through SubmitCommand of the
// firmware and gives the answer: the bytes that the size of its header
// names, within the response buffer. status is the status of the firmware
// when answered is false, or 0 when the answer does not fit its buffer.
firmware_submit :: proc "contextless" (tpm: ^Efi_Tcg2_Protocol, command: []u8, response: []u8) -> (answer: []u8, status: u64, answered: bool) {
	if len(command) == 0 || len(response) < 10 {
		return nil, 0, false
	}
	firmware_status := tpm.submit_command(tpm, u32(len(command)), raw_data(command), u32(len(response)), raw_data(response))
	if firmware_status != 0 {
		return nil, u64(firmware_status), false
	}
	size := int(byte_order.read_u32_big_endian(response[2:], 0))
	if size < 10 || size > len(response) {
		return nil, 0, false
	}
	return response[:size], 0, true
}

// The first serial port of a PC: the log of the machine tests reads it.
SERIAL_PORT :: 0x3F8
SERIAL_PORT_LINE_STATUS :: SERIAL_PORT + 5
SERIAL_PORT_CAN_TAKE_A_BYTE :: 0x20
// A port that never becomes ready (no serial port on this machine) must not
// hold the boot: after this count of reads the byte is dropped.
SERIAL_PORT_WAIT_LIMIT :: 100_000

serial_port_write_in_registers :: asm(port: u16, value: u8) -> (port_after: u16, value_after: u8) [
	port -> port_after   = %dx,
	value -> value_after = %al,
	#volatile,
	#clobber memory,
] {
	out
}

serial_port_read_in_registers :: asm(port: u16, before: u8) -> (port_after: u16, value: u8) [
	port -> port_after = %dx,
	before -> value    = %al,
	#volatile,
	#clobber memory,
] {
	in
}

// serial_port_print writes ASCII text on the serial port with the
// instructions of the processor, not through the console of the firmware:
// the text does not reach the screen.
serial_port_print :: proc "contextless" (text: string) {
	for index in 0 ..< len(text) {
		for _ in 0 ..< SERIAL_PORT_WAIT_LIMIT {
			_, status := serial_port_read_in_registers(SERIAL_PORT_LINE_STATUS, 0)
			if status & SERIAL_PORT_CAN_TAKE_A_BYTE != 0 {
				break
			}
		}
		_, _ = serial_port_write_in_registers(SERIAL_PORT, text[index])
	}
}
