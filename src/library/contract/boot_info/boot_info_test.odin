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
