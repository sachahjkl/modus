#+build !freestanding
package tpm_service

import "core:testing"

// The border of the service, as its main loop calls it. Each record that
// names no request gives Bad_Command and an empty request, and its values
// do not change: a kind past the last command, the largest kind, the kind
// of None, and an authorization past the last one or the largest word in
// the place that the command reads. The authorization in the other place
// is not read. The requests that the service takes come last.
@(test)
a_record_that_names_no_request_is_refused :: proc(t: ^testing.T) {
	Refused :: struct {
		kind:   u32,
		values: [7]u64,
	}
	refused := [?]Refused {
		{u32(max(Command)) + 1, {}},
		{max(u32), {}},
		{u32(Command.None), {}},
		{u32(Command.Seal), {0 = u64(max(Authorization)) + 1}},
		{u32(Command.Seal), {0 = max(u64)}},
		{u32(Command.Unseal), {4 = u64(max(Authorization)) + 1}},
		{u32(Command.Unseal), {4 = max(u64)}},
	}
	for item in refused {
		values := item.values
		request, status := request_of_record(item.kind, values)
		testing.expectf(t, status == .Bad_Command, "the kind %d with %v is taken: %v", item.kind, item.values, status)
		testing.expect_value(t, request, Request{})
		testing.expect_value(t, values, item.values)
	}
	// Each command reads its own place: a word of no authorization in the
	// other place changes nothing.
	for authorization in Authorization {
		seal, seal_status := request_of_record(u32(Command.Seal), {0 = u64(authorization), 4 = max(u64)})
		testing.expect_value(t, seal_status, Status.Ok)
		testing.expect_value(t, seal, Request{command = .Seal, authorization = authorization})
		unseal, unseal_status := request_of_record(u32(Command.Unseal), {0 = max(u64), 4 = u64(authorization)})
		testing.expect_value(t, unseal_status, Status.Ok)
		testing.expect_value(t, unseal, Request{command = .Unseal, authorization = authorization})
	}
}

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
