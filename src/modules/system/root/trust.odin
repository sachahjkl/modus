package root

import "modus:contract/blake3"
import info "modus:contract/boot_info"
import op "modus:contract/operation"
import "modus:contract/system_description"
import "modus:contract/value_kinds"
import "modus:system"

// The check of the root service (docs/TRUSTED_BOOT.md, "Layer 1: the signed system description").
//
// The trust record of the boot record says who checks the files of the
// boot image (info.File_Check). This service takes the system description
// of the boot image only when its hash is the one of the record, then:
//
// - Boot_Program: the boot program verified the description signature and
//   every hash before the kernel. This service checks every module and
//   resource again, once, before it starts the first process.
// - Root_Service_At_Load (a browser machine): nothing checked the files;
//   this service checks the table of the image against the description,
//   and its own module, then hashes each other file at its first load or
//   give, and refuses one whose hash differs before any read of it.
//
// A file is hashed once: image_checks keeps each entry whose bytes agree.
// The rule holds while no process and no device writes the pages of the
// image: the kernel gives them to this service with Read and no Write, and
// a device reaches them only on a machine with no IOMMU. The kernel itself
// is not in the boot image: only the boot program checks it.

// The boot record, read once: about 2.5 KiB, kept out of the stack.
trust_boot_report: op.Boot_Report
// The entries of the boot image whose bytes have the hash of their entry:
// every entry after the check at the start, or each one at its first use.
// The loads of this service (load_source) and resource_mapping read it.
image_checks: system.Image_Checks

// image_entry_give says whether the pages of an entry of the boot image
// may go to a process, or its offset and size to a service: its bytes have
// the hash of the entry (image_checks hashes it at its first use, once).
// Each give of pages of the image goes through it. A refusal names the file
// on the log.
image_entry_give :: proc "contextless" (entry: ^info.Image_Entry) -> bool {
	if system.image_entry_check(image, &image_checks, entry) {
		return true
	}
	system.log_fact(.Error, Image_File_Hash_Wrong{file = module_name_field(system.name_of(entry.name[:]))})
	return false
}

// image_entry_mapping gives the read-only mapping of the pages of an entry
// at an address of a process, after image_entry_give; ok false: the entry
// is refused, and no mapping is made.
image_entry_mapping :: proc "contextless" (entry: ^info.Image_Entry, address: u64) -> (mapping: system.Mapping, ok: bool) {
	if !image_entry_give(entry) {
		return {}, false
	}
	// No flag: the mapping has the right Read only.
	return {memory = image_memory, address = address, first = entry.offset / system.PAGE_SIZE, page_count = (entry.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE}, true
}

// own_module_check hashes the module of this service, by its name in the
// boot image, and keeps it as checked. A failure is the check of the file
// that failed.
own_module_check :: proc "contextless" () -> (result: system_description.Check) {
	for &entry in system.image_entries(image) {
		if system.name_of(entry.name[:]) != "root" {
			continue
		}
		if !system.image_entry_check(image, &image_checks, &entry) {
			result.fault = .Hash_Differs
			result.name = entry.name
			result.expected_hash = entry.hash
		}
		return result
	}
	result.fault = .Image_Not_Valid // A boot image with no module of this service.
	return result
}

// image_file_checked gives the bytes of a module of the boot image, by its
// name, after their hash agrees with the entry (image_checks), or nil: no
// module of that name, or bytes whose hash differs, which the log names.
image_file_checked :: proc "contextless" (name: string) -> []u8 {
	for &entry in system.image_entries(image) {
		if system.name_of(entry.name[:]) != name {
			continue
		}
		if !image_entry_give(&entry) {
			return nil
		}
		return image[entry.offset:][:entry.size]
	}
	return nil
}

trust_check :: proc "contextless" () {
	report := &trust_boot_report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Boot), 0, u64(uintptr(report)), size_of(op.Boot_Report))
	trust := &report.trust
	// The record says what happened: a boot program that hashed the files
	// verified the description, and a record whose files nothing hashed
	// names no verifier (info.trust_decision, with its host tests).
	file_check, verifier, decision := info.trust_decision(trust^)
	if decision != .Accepted {
		fail(info.trust_decision_sentences[decision], .Bad_State)
	}
	description, _, found := system_description.trust_resources(image)
	if !found {
		fail("the boot image has no system description", .Bad_State)
	}
	if blake3.hash(description) != trust.description_hash {
		fail(verifier == .None ? "the system description is not the one whose hash the boot record gives" : "the system description is not the one that the boot program verified", .Bad_State)
	}
	start := system.nanoseconds()
	result := file_check == .Root_Service_At_Load ? system_description.image_check_without_bytes(description, image) : system_description.image_check(description, image)
	if result.fault == .None && file_check == .Root_Service_At_Load {
		// This service runs from its own entry: it is the first file that
		// the check at the first use hashes.
		result = own_module_check()
	}
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
	// The count of the entries that this check read, not the count of the
	// trust record: a record that the boot program did not write has none.
	list, _ := system_description.entries(description)
	checked_entries := u64(max(len(list), 1) - 1)
	check_time := value_kinds.Time_In_Microseconds(spent / 1000)
	switch file_check {
	case .Boot_Program:
		// The entries that image_check hashed: each module and each resource
		// but the two last, the description, which it hashed apart, and its
		// signature, which it does not read.
		listed := len(system.image_entries(image)) + max(len(system.image_resources(image)) - 2, 0)
		for place in 0 ..< min(listed, system.IMAGE_CHECK_CAPACITY) {
			image_checks.checked[place] = true
		}
	case .Root_Service_At_Load:
		// Each file at its first use.
	case .None:
		fail(info.trust_decision_sentences[.No_File_Check], .Bad_State)
	}
	switch file_check {
	case .Boot_Program:
		system.log_fact(.Info, Boot_Image_Agrees{checked_entries = checked_entries, check_time = check_time})
		if report.cycle_frequency != 0 {
			system.log_fact(.Info, Boot_Program_Check_Time{check_time = value_kinds.Time_In_Microseconds(trust.check_cycles * 1_000_000 / report.cycle_frequency)})
		}
		key_kind, key_kind_ok := info.signing_key_kind_of_word(trust.key_kind)
		if !key_kind_ok || key_kind == .None {
			fail("the boot record names no signing key kind", .Bad_State)
		}
		if key_kind == .Test {
			system.log_fact(.Warning, Description_Signed_By_Test_Key{})
		}
		if verifier == .Boot_Program {
			system.log_fact(.Info, Verified_By_Boot_Program{})
		} else {
			system.log_fact(.Info, Verified_By_Firmware{})
		}
	case .Root_Service_At_Load:
		system.log_fact(.Warning, Image_Checked_At_Load{checked_entries = checked_entries, check_time = check_time})
	case .None:
		fail(info.trust_decision_sentences[.No_File_Check], .Bad_State)
	}
	measure, measure_ok := info.measure_state_of_word(trust.measure)
	if !measure_ok {
		system.log_fact(.Warning, Measure_Not_Tried{})
	} else {
		switch measure {
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
