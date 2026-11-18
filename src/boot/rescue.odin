package boot

// The two ways to ask for the rescue start policy at one start, with no
// change on the disk (src/md/features/start_policy.md, "The rescue key";
// src/md/features/start_policy.md, "The rescue boot entry"): the key R held
// while the machine starts,
// and the boot entry "modus (rescue)", whose load options hold a tagged
// record. Both give the same Rescue in the boot record.

import info "modus:contract/boot_info"
import "modus:private/boot_program/rescue_entry"
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

// The entries of BootOrder that the boot program reads at most: a larger
// order is refused with its own line, never cut.
BOOT_ORDER_LIMIT :: 512

// The attributes of each boot variable that the boot program writes.
BOOT_VARIABLE_ATTRIBUTES :: EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS

// rescue_entry_write writes the boot entry "modus (rescue)" when it is
// absent, and puts its number at the end of BootOrder, so that the
// firmware lists it in its boot menu and starts it only when the entries
// before it fail. The system has no installer, and an image cannot hold a
// variable of the firmware, so the boot program is the one writer of the
// entry. An entry is this entry by its description and by the device path
// of this program: the entry of another boot volume is not it. A firmware
// with no BootOrder gets the entry and no BootOrder: the boot program does
// not make the order of the boot menu. A refusal of the firmware is one
// line: the start goes on.
rescue_entry_write :: proc "contextless" () {
	path: [rescue_entry.DEVICE_PATH_LIMIT]u8
	path_size, path_ok := boot_program_path(path[:])
	if !path_ok {
		return
	}
	variables := system.runtime_services
	global := EFI_GLOBAL_VARIABLE_GUID
	order_name := [?]u16{'B', 'o', 'o', 't', 'O', 'r', 'd', 'e', 'r', 0}
	order: [BOOT_ORDER_LIMIT + 1]u16
	order_size := uint(BOOT_ORDER_LIMIT * size_of(u16))
	order_count := 0
	switch status := variables.get_variable(raw_data(order_name[:]), &global, nil, &order_size, &order[0]); status {
	case 0:
		order_count = int(order_size) / size_of(u16)
	case EFI_NOT_FOUND:
	case EFI_BUFFER_TOO_SMALL:
		rescue_entry_refused("BootOrder holds more than the 512 entries that the boot program reads", 0)
		return
	case:
		rescue_entry_refused("the firmware does not give BootOrder", status)
		return
	}
	// The entry, among each entry that BootOrder names.
	for index in 0 ..< order_count {
		if rescue_entry_is_at(order[index], path[:path_size]) {
			return
		}
	}
	// The first free number. With no order, the entry of an earlier start
	// took the first free number of its time: it is before the first free
	// number of now.
	number: u16
	free := false
	for candidate in 0 ..= u32(max(u16)) {
		name := rescue_entry.option_name(u16(candidate))
		probe_size: uint
		status := variables.get_variable(raw_data(name[:]), &global, nil, &probe_size, nil)
		if status == EFI_NOT_FOUND {
			number, free = u16(candidate), true
			break
		}
		if order_count == 0 && rescue_entry_is_at(u16(candidate), path[:path_size]) {
			return
		}
	}
	if !free {
		rescue_entry_refused("no number of a boot option is free", 0)
		return
	}
	if !rescue_option_write(number, path[:path_size]) {
		return
	}
	text: bootscreen.Text
	bootscreen.put(&text, "boot program: the boot entry ")
	bootscreen.put(&text, rescue_entry.DESCRIPTION)
	bootscreen.put(&text, " is written as Boot")
	bootscreen.put_hex(&text, u64(number), 4)
	if order_count == 0 {
		bootscreen.put(&text, "; the firmware has no BootOrder")
		bootscreen.put(&text, "\r\n")
		print(string(text.bytes[:text.count]))
		return
	}
	if order_count >= BOOT_ORDER_LIMIT {
		rescue_entry_refused("BootOrder is full", 0)
		return
	}
	order[order_count] = number
	if status := variables.set_variable(raw_data(order_name[:]), &global, BOOT_VARIABLE_ATTRIBUTES, uint(order_count + 1) * size_of(u16), &order[0]); status != 0 {
		rescue_entry_refused("the firmware refused the write of BootOrder", status)
		return
	}
	bootscreen.put(&text, "\r\n")
	print(string(text.bytes[:text.count]))
}

// rescue_entry_is_at says if the boot option with a number is the entry of
// this program. An option that does not fit the room of a read is not it.
rescue_entry_is_at :: proc "contextless" (number: u16, path: []u8) -> bool {
	name := rescue_entry.option_name(number)
	global := EFI_GLOBAL_VARIABLE_GUID
	option: [rescue_entry.OPTION_LIMIT]u8
	size := uint(rescue_entry.OPTION_LIMIT)
	if system.runtime_services.get_variable(raw_data(name[:]), &global, nil, &size, &option[0]) != 0 {
		return false
	}
	return rescue_entry.option_is_the_rescue_entry(option[:min(int(size), rescue_entry.OPTION_LIMIT)], path)
}

// boot_program_path copies the device path of this program into output:
// the path of its device, then the path of its file. A firmware that gives
// no path, or a path past the room, is one line.
boot_program_path :: proc "contextless" (output: []u8) -> (size: int, ok: bool) {
	loaded: rawptr
	device_path: rawptr
	loaded_guid := EFI_LOADED_IMAGE_GUID
	path_guid := EFI_DEVICE_PATH_GUID
	if system.boot_services.handle_protocol(image_handle, &loaded_guid, &loaded) != 0 || loaded == nil {
		rescue_entry_refused("the firmware gives no loaded image of the boot program", 0)
		return 0, false
	}
	image := (^Efi_Loaded_Image)(loaded)
	if system.boot_services.handle_protocol(image.device_handle, &path_guid, &device_path) != 0 || device_path == nil || image.file_path == nil {
		rescue_entry_refused("the firmware gives no device path of the boot program", 0)
		return 0, false
	}
	device_bytes, device_ok := rescue_entry.device_path_copy(([^]u8)(device_path), output, false)
	if !device_ok {
		rescue_entry_refused("the device path of the boot program does not fit its room", 0)
		return 0, false
	}
	file_bytes, file_ok := rescue_entry.device_path_copy(([^]u8)(image.file_path), output[device_bytes:], true)
	if !file_ok {
		rescue_entry_refused("the device path of the boot program does not fit its room", 0)
		return 0, false
	}
	return device_bytes + file_bytes, true
}

// rescue_option_write writes the variable of the rescue entry: active, its
// description, the device path of this program, and the record that asks
// for the rescue.
rescue_option_write :: proc "contextless" (number: u16, path: []u8) -> bool {
	record := info.load_options_write(.Rescue)
	record_bytes := transmute([info.LOAD_OPTIONS_SIZE]u8)record
	option: [rescue_entry.OPTION_LIMIT]u8
	size, fits := rescue_entry.option_write(path, record_bytes[:], option[:])
	if !fits {
		rescue_entry_refused("the boot entry does not fit its room", 0)
		return false
	}
	name := rescue_entry.option_name(number)
	global := EFI_GLOBAL_VARIABLE_GUID
	if status := system.runtime_services.set_variable(raw_data(name[:]), &global, BOOT_VARIABLE_ATTRIBUTES, uint(size), &option[0]); status != 0 {
		rescue_entry_refused("the firmware refused the write of the boot entry", status)
		return false
	}
	return true
}

// rescue_entry_refused writes the line of a boot entry that is not
// written. It is not a stop: the key R still asks for the rescue.
rescue_entry_refused :: proc "contextless" (cause: string, status: Efi_Status) {
	print("boot program: the boot entry ")
	print(rescue_entry.DESCRIPTION)
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
