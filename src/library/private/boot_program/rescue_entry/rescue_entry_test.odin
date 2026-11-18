#+build !freestanding
package rescue_entry

import "core:testing"

// A node of a device path of a length, with its type and subtype.
@(private = "file")
node_put :: proc(bytes: []u8, place: int, type, subtype: u8, length: int) -> int {
	bytes[place], bytes[place + 1] = type, subtype
	bytes[place + 2], bytes[place + 3] = u8(length), u8(length >> 8)
	return place + length
}

// The copy of a device path. The refusals first: a node of 0 and of 3
// bytes, shorter than its header; a path with no end node that passes its
// room, by its headers and by the bytes of a node. Then a path that fills
// the room exactly with its end node, which keep_end copies and which a
// copy without it leaves out, and the copy of each node before it.
@(test)
a_device_path_that_does_not_end_in_its_room_is_refused :: proc(t: ^testing.T) {
	source: [2 * DEVICE_PATH_LIMIT]u8
	output: [DEVICE_PATH_LIMIT]u8
	for short in ([?]int{0, NODE_HEADER_SIZE - 1}) {
		source = {}
		node_put(source[:], 0, 1, 1, short)
		_, ok := device_path_copy(&source[0], output[:], true)
		testing.expectf(t, !ok, "a node of %d bytes is taken", short)
	}
	// Nodes of 8 bytes with no end, past the room.
	source = {}
	for place := 0; place + 8 <= len(source); place += 8 {
		node_put(source[:], place, 1, 1, 8)
	}
	_, endless := device_path_copy(&source[0], output[:], true)
	testing.expect(t, !endless, "a path with no end node is taken")
	_, endless_without := device_path_copy(&source[0], output[:], false)
	testing.expect(t, !endless_without, "a path with no end node is taken with no end")
	// One node larger than the room.
	source = {}
	node_put(source[:], 0, 1, 1, DEVICE_PATH_LIMIT + 4)
	_, large := device_path_copy(&source[0], output[:], true)
	testing.expect(t, !large, "a node past the room is taken")
	_, nothing := device_path_copy(nil, output[:], true)
	testing.expect(t, !nothing, "no path is taken")
	// A path that fills the room exactly: nodes, then its end node of 4.
	source = {}
	place := node_put(source[:], 0, 2, 1, DEVICE_PATH_LIMIT - NODE_HEADER_SIZE - 100)
	place = node_put(source[:], place, 4, 4, 100)
	end := node_put(source[:], place, END_TYPE, END_ENTIRE_SUBTYPE, NODE_HEADER_SIZE)
	testing.expect_value(t, end, DEVICE_PATH_LIMIT)
	written, whole := device_path_copy(&source[0], output[:], true)
	testing.expect(t, whole)
	testing.expect_value(t, written, DEVICE_PATH_LIMIT)
	testing.expect_value(t, string(output[:written]), string(source[:DEVICE_PATH_LIMIT]))
	without_end, without_ok := device_path_copy(&source[0], output[:], false)
	testing.expect(t, without_ok)
	testing.expect_value(t, without_end, DEVICE_PATH_LIMIT - NODE_HEADER_SIZE)
	// The same path in a room one byte short ends past it.
	_, short_room := device_path_copy(&source[0], output[:DEVICE_PATH_LIMIT - 1], true)
	testing.expect(t, !short_room, "a path one byte past its room is taken")
}

// The match of an entry: an option shorter than its description, a
// description with one unit changed, one unit more, a path of another
// length, and a path with one byte changed are not the entry. The option
// that option_write gives is the entry, last.
@(test)
an_option_that_is_not_this_entry_is_not_taken :: proc(t: ^testing.T) {
	path := [?]u8{2, 1, 8, 0, 9, 9, 9, 9, END_TYPE, END_ENTIRE_SUBTYPE, 4, 0}
	record := [?]u8{'M', 'O', 'D', 'U', 'S', 'O', 'P', 'T', 1, 0, 0, 0, 1, 0, 0, 0}
	option: [OPTION_LIMIT]u8
	size, written := option_write(path[:], record[:], option[:])
	testing.expect(t, written)
	description_end := DESCRIPTION_OFFSET + 2 * (len(DESCRIPTION) + 1)
	testing.expect(t, !option_is_the_rescue_entry(option[:description_end - 1], path[:]), "an option shorter than its description is taken")
	changed := option
	changed[DESCRIPTION_OFFSET + 2] = 'X'
	testing.expect(t, !option_is_the_rescue_entry(changed[:size], path[:]), "another description is taken")
	high := option
	high[DESCRIPTION_OFFSET + 1] = 1
	testing.expect(t, !option_is_the_rescue_entry(high[:size], path[:]), "a unit past ASCII is taken")
	longer := option
	longer[description_end - 2] = 'x'
	testing.expect(t, !option_is_the_rescue_entry(longer[:size], path[:]), "a description with one unit more is taken")
	testing.expect(t, !option_is_the_rescue_entry(option[:size], path[:len(path) - 1]), "a path of another length is taken")
	other_path := path
	other_path[5] = 7
	testing.expect(t, !option_is_the_rescue_entry(option[:size], other_path[:]), "another device path is taken")
	testing.expect(t, !option_is_the_rescue_entry(option[:description_end + 2], path[:]), "an option cut in its path is taken")
	testing.expect(t, option_is_the_rescue_entry(option[:size], path[:]))
	testing.expect_value(t, size, description_end + len(path) + len(record))
	// An option that does not fit its room, and a path past its limit.
	_, small := option_write(path[:], record[:], option[:size - 1])
	testing.expect(t, !small)
	large_path: [DEVICE_PATH_LIMIT + 1]u8
	_, large := option_write(large_path[:], record[:], option[:])
	testing.expect(t, !large)
}

// The names of the variables: the first, the last and one in the middle,
// with upper case digits and a zero unit after them.
@(test)
the_name_of_a_boot_option_has_four_upper_case_digits :: proc(t: ^testing.T) {
	expect :: proc(t: ^testing.T, number: u16, text: string, loc := #caller_location) {
		name := option_name(number)
		for index in 0 ..< len(text) {
			testing.expect_value(t, name[index], u16(text[index]), loc = loc)
		}
		testing.expect_value(t, name[8], 0, loc = loc)
	}
	expect(t, 0, "Boot0000")
	expect(t, 0xFFFF, "BootFFFF")
	expect(t, 0x00AB, "Boot00AB")
}
