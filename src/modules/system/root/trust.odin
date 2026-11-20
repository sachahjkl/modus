package root

import "modus:contract/blake3"
import info "modus:contract/boot_info"
import op "modus:contract/operation"
import "modus:contract/system_description"
import "modus:contract/value_kinds"
import "modus:support/system"

// The check of the root service (docs/TRUSTED_BOOT.md, "Layer 1: the signed system description").
//
// The boot program verified the description signature and every hash
// before the kernel started, and wrote what it verified in the trust
// record. This service reads the record in the boot record of the kernel,
// takes the system description of the boot image only when its hash is the
// one that the boot program verified, and checks every module and resource
// of the boot image against it once, before it starts the first process.
//
// Once is enough: the kernel gives this service the pages of the boot image
// with the right Read and no Write, so no process can change a module
// between this check and its start. The kernel itself is not in the boot
// image: only the boot program checks it. The kernel does not read the
// description.

// The boot record, read once: about 2.5 KiB, kept out of the stack.
trust_boot_report: op.Boot_Report

trust_check :: proc "contextless" () {
	report := &trust_boot_report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Boot), 0, u64(uintptr(report)), size_of(op.Boot_Report))
	trust := &report.trust
	if trust.verifier == .None {
		fail("the boot program did not verify the system description", .Bad_State)
	}
	description, _, found := system_description.trust_resources(image)
	if !found {
		fail("the boot image has no system description", .Bad_State)
	}
	if blake3.hash(description) != trust.description_hash {
		fail("the system description is not the one that the boot program verified", .Bad_State)
	}
	start := system.nanoseconds()
	result := system_description.image_check(description, image)
	spent := system.nanoseconds() - start
	if result.fault != .None {
		buffer: [256]u8
		text := system.format(buffer[:], system_description.name_of(&result.name), ": ", system_description.fault_sentences[result.fault])
		expected := value_kinds.Hash_Field(result.expected_hash)
		found_hash := value_kinds.Hash_Field(result.found_hash)
		entry := module_name_field(system_description.name_of(&result.name))
		switch result.fault {
		case .None:
			// The check passed: this branch never sees it.
		case .Not_Valid:
			system.log_fact(.Error, Image_Check_Failed_Not_Valid{expected_hash = expected, found_hash = found_hash, checked_entry = entry})
		case .Image_Not_Valid:
			system.log_fact(.Error, Image_Check_Failed_Image_Not_Valid{expected_hash = expected, found_hash = found_hash, checked_entry = entry})
		case .Count_Differs:
			system.log_fact(.Error, Image_Check_Failed_Count_Differs{expected_hash = expected, found_hash = found_hash, checked_entry = entry})
		case .Name_Differs:
			system.log_fact(.Error, Image_Check_Failed_Name_Differs{expected_hash = expected, found_hash = found_hash, checked_entry = entry})
		case .Kind_Differs:
			system.log_fact(.Error, Image_Check_Failed_Kind_Differs{expected_hash = expected, found_hash = found_hash, checked_entry = entry})
		case .Size_Differs:
			system.log_fact(.Error, Image_Check_Failed_Size_Differs{expected_hash = expected, found_hash = found_hash, checked_entry = entry})
		case .Hash_Differs:
			system.log_fact(.Error, Image_Check_Failed_Hash_Differs{expected_hash = expected, found_hash = found_hash, checked_entry = entry})
		case .Stated_Hash_Differs:
			system.log_fact(.Error, Image_Check_Failed_Stated_Hash_Differs{expected_hash = expected, found_hash = found_hash, checked_entry = entry})
		case .Outside_Image:
			system.log_fact(.Error, Image_Check_Failed_Outside_Image{expected_hash = expected, found_hash = found_hash, checked_entry = entry})
		}
		switch result.fault {
		case .Name_Differs, .Kind_Differs, .Outside_Image, .Size_Differs, .Hash_Differs, .Stated_Hash_Differs:
			screen_data.failed_name = system_description.name_of(&result.name)
		case .None, .Not_Valid, .Image_Not_Valid, .Count_Differs:
			// No one file of the boot image is at fault.
		}
		fail(text, .Bad_State)
	}
	system.log_fact(.Info, Boot_Image_Agrees{checked_entries = trust.entry_count - 1, check_time = value_kinds.Time_In_Microseconds(spent / 1000)})
	if report.cycle_frequency != 0 {
		system.log_fact(.Info, Boot_Program_Check_Time{check_time = value_kinds.Time_In_Microseconds(trust.check_cycles * 1_000_000 / report.cycle_frequency)})
	}
	if trust.key_kind == .Test {
		system.log_fact(.Warning, Description_Signed_By_Test_Key{})
	}
	if trust.verifier == .Boot_Program {
		system.log_fact(.Info, Verified_By_Boot_Program{})
	} else {
		system.log_fact(.Info, Verified_By_Firmware{})
	}
	switch trust.measure {
	case .Measured:
		system.log_fact(.Info, System_Description_Measured{measure_register = trust.measure_register, measure_tries = trust.measure_tries, measure_value = value_kinds.Hash_Field(trust.measure_value)})
	case .No_Tpm:
		system.log_fact(.Info, Description_Unmeasured_No_Tpm{})
	case .Refused:
		system.log_fact(.Warning, Description_Measure_Refused{measure_status = value_kinds.Hexadecimal_Sixteen_Digits(trust.measure_status), measure_tries = trust.measure_tries, measure_register = trust.measure_register})
	case .Not_Read:
		system.log_fact(.Warning, Description_Register_Unread{measure_register = trust.measure_register, measure_status = value_kinds.Hexadecimal_Sixteen_Digits(trust.measure_status)})
	case .None:
		system.log_fact(.Warning, Measure_Not_Tried{})
	}
	// The TPM floors that the boot program compared
	// (src/md/features/rollback_floors.md).
	system.log_fact(.Info, Tpm_Floors{key_floor = trust.key_floor, key_number = trust.key_number, version_floor = trust.version_floor, security_version = trust.security_version})
	for word in ([2]u64{trust.key_floor_state, trust.version_floor_state}) {
		// The trust record comes through the boot report of the kernel: a
		// word that names no state is said, never read as a state.
		state, state_known := info.floor_state_of_word(word)
		if !state_known {
			system.log_fact(.Warning, Floor_State_Unknown{floor_state = word})
			continue
		}
		switch state {
		case .None, .Absent, .Held:
			// A floor that the boot program read or wrote: the line above says it.
		case .Foreign, .Never_Written, .Read_Refused:
			system.log_fact(.Warning, Tpm_Floor_Foreign{})
		case .Not_Read:
			system.log_fact(.Warning, Tpm_Floor_Unread{floor_status = value_kinds.Hexadecimal_Sixteen_Digits(trust.floor_status)})
		}
	}
}
