#+build !freestanding
package tpm_service

import "core:testing"

// Each word of the ring that names no member is refused first: one past
// the largest member, a word past 32 bits where the word has 64, and the
// largest word. Then each member comes back from its own word.
@(test)
a_word_of_the_ring_that_names_no_member_is_refused :: proc(t: ^testing.T) {
	commands := [?]u32{u32(max(Command)) + 1, max(u32)}
	for word in commands {
		_, ok := command_of_word(word)
		testing.expectf(t, !ok, "the command %d names no member, and it is taken", word)
	}
	authorizations := [?]u64{u64(max(Authorization)) + 1, 1 << 32, max(u64)}
	for word in authorizations {
		_, ok := authorization_of_word(word)
		testing.expectf(t, !ok, "the authorization %d names no member, and it is taken", word)
	}
	statuses := [?]u32{u32(max(Status)) + 1, max(u32)}
	for word in statuses {
		_, ok := status_of_word(word)
		testing.expectf(t, !ok, "the status %d names no member, and it is taken", word)
	}
	steps := [?]u64{u64(max(Device_Step)) + 1, max(u64)}
	for word in steps {
		_, ok := device_step_of_word(word)
		testing.expectf(t, !ok, "the step %d names no member, and it is taken", word)
	}
	for member in Command {
		read, ok := command_of_word(u32(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in Authorization {
		read, ok := authorization_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in Status {
		read, ok := status_of_word(u32(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in Device_Step {
		read, ok := device_step_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
		testing.expect(t, len(device_step_words[member]) > 0)
	}
}
