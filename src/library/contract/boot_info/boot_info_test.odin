#+build !freestanding
package boot_info

import "core:testing"

// A word of the self test or of a floor state that names no member is
// refused: one past the last member, a word past 255 and the largest word.
// The records keep the size of their words. Each member then reads back
// from its word.
@(test)
a_word_of_the_boot_record_that_names_no_member :: proc(t: ^testing.T) {
	refused_tests := [?]u64{u64(max(Self_Test)) + 1, 0x100, max(u64)}
	for word in refused_tests {
		_, ok := self_test_of_word(word)
		testing.expectf(t, !ok, "the word %d names no self test, and it is taken", word)
	}
	refused_states := [?]u64{u64(max(Floor_State)) + 1, 0x100, max(u64)}
	for word in refused_states {
		_, ok := floor_state_of_word(word)
		testing.expectf(t, !ok, "the word %d names no floor state, and it is taken", word)
	}
	testing.expect_value(t, size_of(Boot_Info{}.self_test), 8)
	testing.expect_value(t, size_of(Boot_Trust{}.key_floor_state), 8)
	testing.expect_value(t, size_of(Boot_Trust{}.version_floor_state), 8)
	for member in Self_Test {
		test, ok := self_test_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, test, member)
	}
	// The values of Self_Test have no hole from 0 to the largest member:
	// the assert of the boot program against the largest member then
	// refuses each word of the build that names no test.
	for word in 0 ..= u64(max(Self_Test)) {
		_, ok := self_test_of_word(word)
		testing.expectf(t, ok, "the self test word %d is a hole: the boot program must assert each member", word)
	}
	for member in Floor_State {
		state, ok := floor_state_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, state, member)
	}
}

// The two words of the start request: a word past the last member of
// either, the largest word, and the pairs that disagree are refused with
// Chosen and None. The pairs that agree come last.
@(test)
a_start_request_that_names_no_member_is_refused :: proc(t: ^testing.T) {
	refused := [?][2]u64 {
		{u64(max(Start_Request)) + 1, u64(Start_Request_Source.Key)},
		{max(u64), u64(Start_Request_Source.Key)},
		{u64(Start_Request.Rescue), u64(max(Start_Request_Source)) + 1},
		{u64(Start_Request.Rescue), max(u64)},
		{u64(Start_Request.Rescue), u64(Start_Request_Source.None)},
		{u64(Start_Request.Chosen), u64(Start_Request_Source.Key)},
		{u64(Start_Request.Chosen), u64(Start_Request_Source.Boot_Entry)},
	}
	for words in refused {
		request, source, ok := start_request_of_words(words[0], words[1])
		testing.expectf(t, !ok, "the words %v are taken", words)
		testing.expect_value(t, request, Start_Request.Chosen)
		testing.expect_value(t, source, Start_Request_Source.None)
	}
	testing.expect_value(t, size_of(Boot_Info{}.start_request), 8)
	testing.expect_value(t, size_of(Boot_Info{}.start_request_source), 8)
	accepted := [?]struct {
		request: Start_Request,
		source:  Start_Request_Source,
	}{{.Chosen, .None}, {.Rescue, .Key}, {.Rescue, .Boot_Entry}}
	for pair in accepted {
		request, source, ok := start_request_of_words(u64(pair.request), u64(pair.source))
		testing.expect(t, ok)
		testing.expect_value(t, request, pair.request)
		testing.expect_value(t, source, pair.source)
	}
}

// The load options. Bytes with no tag are a normal start, whatever they
// hold: none, fewer than the tag, the tag with one byte changed, a
// description of UTF-16. Each tagged record that is not whole is refused:
// one byte short, one byte past, another version (0, one past, the
// largest), a word that names no request (one past the last, the
// largest). The records that this system writes read back last.
@(test)
the_load_options_refuse_a_tagged_record_that_is_wrong :: proc(t: ^testing.T) {
	untagged := [?][]u8{{}, {'M', 'O', 'D'}, {'M', 'O', 'D', 'U', 'S', 'O', 'P', 'X', 1, 0, 0, 0, 1, 0, 0, 0}, {'m', 0, 'o', 0, 'd', 0, 'u', 0, 's', 0, 0, 0}}
	for bytes in untagged {
		request, reading, _ := load_options_read(bytes)
		testing.expect_value(t, reading, Load_Options_Reading.Not_Tagged)
		testing.expect_value(t, request, Start_Request.Chosen)
	}
	whole := load_options_write(.Rescue)
	bytes := transmute([LOAD_OPTIONS_SIZE]u8)whole
	longer: [LOAD_OPTIONS_SIZE + 1]u8
	copy(longer[:], bytes[:])
	short_request, short_reading, _ := load_options_read(bytes[:LOAD_OPTIONS_SIZE - 1])
	testing.expect_value(t, short_reading, Load_Options_Reading.Wrong_Size)
	testing.expect_value(t, short_request, Start_Request.Chosen)
	long_request, long_reading, _ := load_options_read(longer[:])
	testing.expect_value(t, long_reading, Load_Options_Reading.Wrong_Size)
	testing.expect_value(t, long_request, Start_Request.Chosen)
	for version in ([?]u32{0, LOAD_OPTIONS_VERSION + 1, max(u32)}) {
		record := whole
		record.version = version
		changed := transmute([LOAD_OPTIONS_SIZE]u8)record
		request, reading, _ := load_options_read(changed[:])
		testing.expect_value(t, reading, Load_Options_Reading.Wrong_Version)
		testing.expect_value(t, request, Start_Request.Chosen)
	}
	for word in ([?]u32{u32(max(Start_Request)) + 1, max(u32)}) {
		record := whole
		record.request = word
		changed := transmute([LOAD_OPTIONS_SIZE]u8)record
		request, reading, read_word := load_options_read(changed[:])
		testing.expect_value(t, reading, Load_Options_Reading.Unknown_Word)
		testing.expect_value(t, request, Start_Request.Chosen)
		testing.expect_value(t, read_word, word)
	}
	for member in Start_Request {
		record := load_options_write(member)
		written := transmute([LOAD_OPTIONS_SIZE]u8)record
		request, reading, _ := load_options_read(written[:])
		testing.expect_value(t, reading, Load_Options_Reading.Read)
		testing.expect_value(t, request, member)
	}
}
