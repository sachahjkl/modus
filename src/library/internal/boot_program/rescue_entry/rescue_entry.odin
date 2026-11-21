// The boot entry "modus (rescue)" that the boot program writes in the
// variables of the firmware (src/md/features/start_policy.md, "The rescue
// boot entry"): its name, its bytes, the copy of the device path of the
// boot program, and the match of an entry that the firmware holds. It calls
// no firmware service, so the host tests run it.
//
// The form of a boot option (EFI_LOAD_OPTION of the UEFI specification):
// the attributes (4 bytes), the length of the device path (2 bytes), the
// description in UTF-16 with a zero unit after it, the device path, then
// the optional data, which is here the record of the load options of
// modus:contract/boot_info.
package rescue_entry

import "base:intrinsics"

// The description of the rescue entry in the boot menu of the firmware.
DESCRIPTION :: "modus (rescue)"
// The bytes of one boot option that the boot program reads or writes at
// most: its attributes, its description, its device path and its record.
OPTION_LIMIT :: 1024
// The bytes of the device path of the boot program at most.
DEVICE_PATH_LIMIT :: 512
// The bytes of the header of a node of a device path: a type, a subtype
// and the length of the node.
NODE_HEADER_SIZE :: 4
// The node that ends a whole device path.
END_TYPE :: 0x7F
END_ENTIRE_SUBTYPE :: 0xFF
// A boot option that the boot menu lists and starts.
OPTION_ACTIVE :: 0x1
// The place of the description in an option.
DESCRIPTION_OFFSET :: 6

// option_name gives the UTF-16 name of the variable Boot#### with four
// upper case hexadecimal digits, as the specification names it, and a zero
// unit after it.
//
// Example: `option_name(0x00AB)` is "Boot00AB".
option_name :: proc "contextless" (number: u16) -> (name: [9]u16) {
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

// device_path_copy copies the nodes of a device path that starts at path
// into output, up to its end node, which it copies only when keep_end is
// set. It reads a header only when its 4 bytes fit the room of output, so
// it never reads past the room. ok is false for a node shorter than its
// header, and for a path that does not end inside the room.
device_path_copy :: proc "contextless" (path: [^]u8, output: []u8, keep_end: bool) -> (written: int, ok: bool) {
	if path == nil {
		return 0, false
	}
	place := 0
	for {
		if written + NODE_HEADER_SIZE > len(output) {
			return 0, false
		}
		node := path[place:]
		length := int(node[2]) | int(node[3]) << 8
		if length < NODE_HEADER_SIZE {
			return 0, false
		}
		end := node[0] == END_TYPE && node[1] == END_ENTIRE_SUBTYPE
		if end && !keep_end {
			return written, true
		}
		if written + length > len(output) {
			return 0, false
		}
		intrinsics.mem_copy_non_overlapping(&output[written], node, length)
		written += length
		place += length
		if end {
			return written, true
		}
	}
}

// option_write writes the option of the rescue entry into output: active,
// its description, the device path, and the record. ok is false when it
// does not fit, or for a path past its limit.
option_write :: proc "contextless" (path: []u8, record: []u8, output: []u8) -> (size: int, ok: bool) {
	if len(path) > DEVICE_PATH_LIMIT {
		return 0, false
	}
	needed := DESCRIPTION_OFFSET + 2 * (len(DESCRIPTION) + 1) + len(path) + len(record)
	if needed > len(output) {
		return 0, false
	}
	attributes := u32(OPTION_ACTIVE)
	intrinsics.mem_copy_non_overlapping(&output[0], &attributes, 4)
	output[4], output[5] = u8(len(path)), u8(len(path) >> 8)
	place := DESCRIPTION_OFFSET
	description := DESCRIPTION
	for index in 0 ..= len(description) {
		unit := index < len(description) ? description[index] : 0
		output[place], output[place + 1] = unit, 0
		place += 2
	}
	if len(path) > 0 {
		intrinsics.mem_copy_non_overlapping(&output[place], raw_data(path), len(path))
	}
	place += len(path)
	if len(record) > 0 {
		intrinsics.mem_copy_non_overlapping(&output[place], raw_data(record), len(record))
	}
	place += len(record)
	return place, true
}

// option_is_the_rescue_entry says if the bytes of a boot option are an
// entry of this boot program: the description of the rescue entry, and
// the device path of this program. An entry with the description and
// another path is the entry of another boot volume.
option_is_the_rescue_entry :: proc "contextless" (option: []u8, path: []u8) -> bool {
	description := DESCRIPTION
	path_offset := DESCRIPTION_OFFSET + 2 * (len(description) + 1)
	if len(option) < path_offset {
		return false
	}
	for index in 0 ..= len(description) {
		unit := u16(option[DESCRIPTION_OFFSET + 2 * index]) | u16(option[DESCRIPTION_OFFSET + 1 + 2 * index]) << 8
		expected := index < len(description) ? u16(description[index]) : 0
		if unit != expected {
			return false
		}
	}
	path_length := int(option[4]) | int(option[5]) << 8
	if path_length != len(path) || len(option) < path_offset + path_length {
		return false
	}
	return string(option[path_offset:][:path_length]) == string(path)
}
