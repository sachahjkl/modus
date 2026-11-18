package boot

// The two ways to ask for the rescue start policy at one start, with no
// change on the disk (src/md/features/start_policy.md, "The rescue key"
// and "The rescue boot entry"): the key R held while the machine starts,
// and the boot entry "modus (rescue)", whose load options hold a tagged
// record. Both give the same Rescue in the boot record.

import info "modus:contract/boot_info"
import "modus:support/bootscreen"
import "base:intrinsics"

// The keys that one read takes from the buffer of the firmware at most: a
// firmware that always gives a key must not hold the boot program.
KEY_READ_LIMIT :: 64

// rescue_key_read says if the key R waits in the buffer of the firmware.
// It takes the keys that wait and never waits for one: a held key repeats,
// so it waits there at each of the two reads. The firmware reads the
// keyboard, so a USB keyboard works before the system has its own driver.
rescue_key_read :: proc "contextless" () -> (held: bool) {
	input := (^Efi_Simple_Text_Input)(system.console_in)
	if input == nil || input.read_key_stroke == nil {
		return false
	}
	for _ in 0 ..< KEY_READ_LIMIT {
		key: Efi_Input_Key
		if input.read_key_stroke(input, &key) != 0 {
			break
		}
		held ||= key.unicode_char == 'r' || key.unicode_char == 'R'
	}
	return held
}

// The bytes of the load options that the boot program copies: a record of
// this system has LOAD_OPTIONS_SIZE, so a longer copy is enough to see that
// a tagged record is not one.
LOAD_OPTIONS_COPY_SIZE :: 64

// load_options_request copies the load options of this program once, then
// reads the copy. Load options with no tag are a normal start. A tagged
// record that is wrong stops the boot program, with its cause on the boot
// display, as a refusal of trust does.
load_options_request :: proc "contextless" () -> info.Start_Request {
	loaded: rawptr
	guid := EFI_LOADED_IMAGE_GUID
	if system.boot_services.handle_protocol(image_handle, &guid, &loaded) != 0 || loaded == nil {
		return .Chosen
	}
	image := (^Efi_Loaded_Image)(loaded)
	size := int(image.load_options_size)
	copied: [LOAD_OPTIONS_COPY_SIZE]u8
	count := image.load_options == nil ? 0 : min(size, LOAD_OPTIONS_COPY_SIZE)
	if count > 0 {
		intrinsics.mem_copy_non_overlapping(&copied[0], image.load_options, count)
	}
	request, reading, word := info.load_options_read(copied[:count])
	text: bootscreen.Text
	switch reading {
	case .Not_Tagged:
		return .Chosen
	case .Read:
		if request == .Rescue {
			print("boot program: the load options of the boot entry ask for the rescue start policy\r\n")
		}
		return request
	case .Wrong_Size:
		bootscreen.put(&text, "the load options hold the tag ")
		bootscreen.put(&text, info.LOAD_OPTIONS_TAG)
		bootscreen.put(&text, " in ")
		bootscreen.put_number(&text, u64(size))
		bootscreen.put(&text, " bytes, not in one record of 16")
	case .Wrong_Version:
		bootscreen.put(&text, "the load options hold the tag ")
		bootscreen.put(&text, info.LOAD_OPTIONS_TAG)
		bootscreen.put(&text, " with a version that is not 1")
	case .Unknown_Word:
		bootscreen.put(&text, "the load options hold the tag ")
		bootscreen.put(&text, info.LOAD_OPTIONS_TAG)
		bootscreen.put(&text, " with the word ")
		bootscreen.put_number(&text, u64(word))
		bootscreen.put(&text, ", which names no start request")
	}
	stop(string(text.bytes[:text.count]))
}

// The description of the rescue boot entry in the boot menu of the
// firmware.
RESCUE_ENTRY_DESCRIPTION :: "modus (rescue)"
// The numbers of the boot options that the boot program reads at most, in
// BootOrder and in its search of a free number.
BOOT_OPTION_LIMIT :: 128
// The bytes of one boot option that the boot program reads or writes at
// most: its attributes, its description, its device path and its record.
LOAD_OPTION_LIMIT :: 1024
// The bytes of the device path of the boot program at most.
DEVICE_PATH_LIMIT :: 512

// boot_option_name writes the UTF-16 name of the variable Boot#### with
// four upper case hexadecimal digits, as the specification names it.
boot_option_name :: proc "contextless" (number: u16) -> (name: [9]u16) {
	digits := "0123456789ABCDEF"
	prefix := "Boot"
	for index in 0 ..< len(prefix) {
		name[index] = u16(prefix[index])
	}
	for index in 0 ..< 4 {
		name[4 + index] = u16(digits[number >> (uint(3 - index) * 4) & 15])
	}
	return name
}

// option_is_the_rescue_entry says if the bytes of a boot option have the
// description of the rescue entry: the description starts after the
// attributes (4 bytes) and the length of the path (2 bytes).
option_is_the_rescue_entry :: proc "contextless" (option: []u8) -> bool {
	description := RESCUE_ENTRY_DESCRIPTION
	if len(option) < 6 + 2 * (len(description) + 1) {
		return false
	}
	for index in 0 ..= len(description) {
		unit := u16(option[6 + 2 * index]) | u16(option[7 + 2 * index]) << 8
		expected := index < len(description) ? u16(description[index]) : 0
		if unit != expected {
			return false
		}
	}
	return true
}

// device_path_copy copies the nodes of a device path into output, up to
// its end node, which it copies only when keep_end is set. It gives the
// bytes written; ok is false for a node shorter than its header, or for a
// path that does not end inside the room.
device_path_copy :: proc "contextless" (path: ^Efi_Device_Path_Node, output: []u8, keep_end: bool) -> (written: int, ok: bool) {
	node := path
	for node != nil {
		length := int(node.length[0]) | int(node.length[1]) << 8
		if length < size_of(Efi_Device_Path_Node) {
			return 0, false
		}
		end := node.type == DEVICE_PATH_END_TYPE && node.subtype == DEVICE_PATH_END_ENTIRE_SUBTYPE
		if end && !keep_end {
			return written, true
		}
		if written + length > len(output) {
			return 0, false
		}
		intrinsics.mem_copy_non_overlapping(&output[written], node, length)
		written += length
		if end {
			return written, true
		}
		node = (^Efi_Device_Path_Node)(uintptr(node) + uintptr(length))
	}
	return 0, false
}

// rescue_entry_write writes the boot entry "modus (rescue)" when it is
// absent, and puts its number at the end of BootOrder, so that the
// firmware lists it in its boot menu and starts it only when the entries
// before it fail. The system has no installer, and an image cannot hold a
// variable of the firmware, so the boot program is the one writer of the
// entry. A refusal of the firmware is one line: the start goes on.
rescue_entry_write :: proc "contextless" () {
	variables := system.runtime_services
	global := EFI_GLOBAL_VARIABLE_GUID
	attributes :: EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS
	order_name := [?]u16{'B', 'o', 'o', 't', 'O', 'r', 'd', 'e', 'r', 0}
	order: [BOOT_OPTION_LIMIT + 1]u16
	order_size := uint(BOOT_OPTION_LIMIT * size_of(u16))
	order_count := 0
	switch status := variables.get_variable(raw_data(order_name[:]), &global, nil, &order_size, &order[0]); status {
	case 0:
		order_count = int(order_size) / size_of(u16)
	case EFI_NOT_FOUND:
	case:
		rescue_entry_refused("the firmware does not give BootOrder", status)
		return
	}
	// The entry and the first free number, among the first numbers.
	found, free_found := false, false
	entry_number, free_number: u16
	for number in 0 ..< u16(BOOT_OPTION_LIMIT) {
		name := boot_option_name(number)
		option: [LOAD_OPTION_LIMIT]u8
		size := uint(LOAD_OPTION_LIMIT)
		status := variables.get_variable(raw_data(name[:]), &global, nil, &size, &option[0])
		if status == EFI_NOT_FOUND && !free_found {
			free_number, free_found = number, true
		}
		if status == 0 && option_is_the_rescue_entry(option[:min(int(size), LOAD_OPTION_LIMIT)]) {
			entry_number, found = number, true
			break
		}
	}
	if found {
		for index in 0 ..< order_count {
			if order[index] == entry_number {
				return
			}
		}
	} else {
		if !free_found {
			rescue_entry_refused("no number of a boot option is free", 0)
			return
		}
		entry_number = free_number
		if !rescue_option_write(entry_number) {
			return
		}
	}
	if order_count >= BOOT_OPTION_LIMIT {
		rescue_entry_refused("BootOrder is full", 0)
		return
	}
	order[order_count] = entry_number
	if status := variables.set_variable(raw_data(order_name[:]), &global, attributes, uint(order_count + 1) * size_of(u16), &order[0]); status != 0 {
		rescue_entry_refused("the firmware refused the write of BootOrder", status)
		return
	}
	text: bootscreen.Text
	bootscreen.put(&text, "boot program: the boot entry ")
	bootscreen.put(&text, RESCUE_ENTRY_DESCRIPTION)
	bootscreen.put(&text, " is written as Boot")
	bootscreen.put_hex(&text, u64(entry_number), 4)
	bootscreen.put(&text, "\r\n")
	print(string(text.bytes[:text.count]))
}

// rescue_option_write writes the variable of the rescue entry: active, its
// description, the device path of this program (the path of its device,
// then the path of its file), and the record that asks for the rescue.
rescue_option_write :: proc "contextless" (number: u16) -> bool {
	loaded: rawptr
	device_path: rawptr
	loaded_guid := EFI_LOADED_IMAGE_GUID
	path_guid := EFI_DEVICE_PATH_GUID
	if system.boot_services.handle_protocol(image_handle, &loaded_guid, &loaded) != 0 || loaded == nil {
		rescue_entry_refused("the firmware gives no loaded image of the boot program", 0)
		return false
	}
	image := (^Efi_Loaded_Image)(loaded)
	if system.boot_services.handle_protocol(image.device_handle, &path_guid, &device_path) != 0 || device_path == nil || image.file_path == nil {
		rescue_entry_refused("the firmware gives no device path of the boot program", 0)
		return false
	}
	path: [DEVICE_PATH_LIMIT]u8
	device_bytes, device_ok := device_path_copy((^Efi_Device_Path_Node)(device_path), path[:], false)
	file_bytes, file_ok := device_path_copy(image.file_path, path[device_bytes:], true)
	if !device_ok || !file_ok {
		rescue_entry_refused("the device path of the boot program does not fit its room", 0)
		return false
	}
	path_size := device_bytes + file_bytes
	option: [LOAD_OPTION_LIMIT]u8
	attributes := u32(LOAD_OPTION_ACTIVE)
	intrinsics.mem_copy_non_overlapping(&option[0], &attributes, 4)
	option[4], option[5] = u8(path_size), u8(path_size >> 8)
	place := 6
	description := RESCUE_ENTRY_DESCRIPTION
	for index in 0 ..= len(description) {
		unit := index < len(description) ? description[index] : 0
		option[place], option[place + 1] = unit, 0
		place += 2
	}
	record := info.load_options_write(.Rescue)
	if place + path_size + size_of(record) > LOAD_OPTION_LIMIT {
		rescue_entry_refused("the boot entry does not fit its room", 0)
		return false
	}
	intrinsics.mem_copy_non_overlapping(&option[place], &path[0], path_size)
	place += path_size
	intrinsics.mem_copy_non_overlapping(&option[place], &record, size_of(record))
	place += size_of(record)
	name := boot_option_name(number)
	global := EFI_GLOBAL_VARIABLE_GUID
	variable_attributes :: EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS
	if status := system.runtime_services.set_variable(raw_data(name[:]), &global, variable_attributes, uint(place), &option[0]); status != 0 {
		rescue_entry_refused("the firmware refused the write of the boot entry", status)
		return false
	}
	return true
}

// rescue_entry_refused writes the line of a boot entry that is not
// written. It is not a stop: the key R still asks for the rescue.
rescue_entry_refused :: proc "contextless" (cause: string, status: Efi_Status) {
	print("boot program: the boot entry ")
	print(RESCUE_ENTRY_DESCRIPTION)
	print(" is not written: ")
	print(cause)
	if status != 0 {
		text: bootscreen.Text
		bootscreen.put(&text, ", status ")
		bootscreen.put_hex(&text, u64(status), 16)
		print(string(text.bytes[:text.count]))
	}
	print("\r\n")
}
