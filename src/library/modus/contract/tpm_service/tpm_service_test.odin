#+build !freestanding
#+build !modus
package tpm_service

import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/errors"

// The border of the service, as its main loop calls it. Each record that
// names no request gives a refusal and an empty request, and its values
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
		for source in Request_Source {
			values := item.values
			request, outcome, record := request_of_record(item.kind, values, source)
			testing.expectf(t, outcome != .Succeeded && call_outcome.effect_group_of(outcome) == .Nothing_Changed && record.kind != 0, "the kind %d with %v from %v is taken: %v", item.kind, item.values, source, outcome)
			testing.expect_value(t, request, Request{})
			testing.expect_value(t, values, item.values)
		}
	}
	// A command of the other ring: a client of the TPM ring never extends
	// PCR 12, and the measure ring neither seals nor unseals.
	_, outcome, _ := request_of_record(u32(Command.Measure_Start_Policy), {}, .Client_Ring)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Grant_Or_Right_Missing)
	_, outcome, _ = request_of_record(u32(Command.Seal), {}, .Measure_Ring)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Grant_Or_Right_Missing)
	_, outcome, _ = request_of_record(u32(Command.Unseal), {}, .Measure_Ring)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Grant_Or_Right_Missing)
	// A kind that names no command, and None.
	_, outcome, _ = request_of_record(max(u32), {}, .Client_Ring)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Operation_Unsupported)
	_, outcome, _ = request_of_record(u32(Command.None), {}, .Measure_Ring)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Operation_Unsupported)
	// An authorization that names none.
	_, outcome, _ = request_of_record(u32(Command.Seal), {0 = max(u64)}, .Client_Ring)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Argument_Refused)
	// Each command reads its own place: a word of no authorization in the
	// other place changes nothing.
	for authorization in Authorization {
		seal, seal_status, _ := request_of_record(u32(Command.Seal), {0 = u64(authorization), 4 = max(u64)}, .Client_Ring)
		testing.expect_value(t, seal_status, call_outcome.Call_Outcome.Succeeded)
		testing.expect_value(t, seal, Request{command = .Seal, authorization = authorization})
		unseal, unseal_status, _ := request_of_record(u32(Command.Unseal), {0 = max(u64), 4 = u64(authorization)}, .Client_Ring)
		testing.expect_value(t, unseal_status, call_outcome.Call_Outcome.Succeeded)
		testing.expect_value(t, unseal, Request{command = .Unseal, authorization = authorization})
	}
	// The measure reads no authorization: its values are the digest.
	measure, measure_status, _ := request_of_record(u32(Command.Measure_Start_Policy), {0 = max(u64), 4 = max(u64)}, .Measure_Ring)
	testing.expect_value(t, measure_status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, measure, Request{command = .Measure_Start_Policy, authorization = .None})
}

// The bound of the extends of PCR 12 in one start, edges first: a negative
// count, the bound, one past it, and the largest count are refused; then
// 0 and 1, the start policy and the rescue, pass.
@(test)
a_third_extend_of_pcr_12_is_refused :: proc(t: ^testing.T) {
	refused := [?]int{-1, min(int), MEASURE_LIMIT, MEASURE_LIMIT + 1, max(int)}
	for count in refused {
		testing.expectf(t, measure_refusal(count) == .Budget_Or_Capacity_Exhausted, "the extend after %d extends is taken", count)
	}
	testing.expect_value(t, MEASURE_LIMIT, 2)
	testing.expect_value(t, measure_refusal(0), call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, measure_refusal(1), call_outcome.Call_Outcome.Succeeded)
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
	for member in Device_Step {
		read, ok := device_step_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
		testing.expect(t, len(device_step_words[member]) > 0)
	}
}

// A wrong authorization value is the one refusal that unlock counts as a
// wrong passphrase. A sealed object that this TPM did not make has the same
// outcome and kind on each part, the border refuses an authorization word
// with Bad_Value on the same argument, and no other outcome is a wrong
// value: none of them is taken for one. The wrong value comes last.
@(test)
only_a_refused_authorization_value_is_a_wrong_authorization :: proc(t: ^testing.T) {
	for argument in ([?]i64{0, UNSEAL_PUBLIC_AREA_ARGUMENT, 2, UNSEAL_CREATION_DATA_ARGUMENT, UNSEAL_CREATION_TICKET_ARGUMENT, UNSEAL_AUTHORIZATION_ARGUMENT + 1, -1, max(i64)}) {
		record := errors.error_make(.Not_Authentic, .None, argument)
		testing.expectf(t, !unseal_authorization_wrong(.Argument_Refused, record), "the argument %d is taken for the authorization", argument)
	}
	_, outcome, record := request_of_record(u32(Command.Unseal), {4 = max(u64)}, .Client_Ring)
	testing.expect_value(t, record.argument, i64(UNSEAL_AUTHORIZATION_ARGUMENT))
	testing.expect(t, !unseal_authorization_wrong(outcome, record))
	wrong := errors.error_make(.Not_Authentic, .None, UNSEAL_AUTHORIZATION_ARGUMENT)
	for other in call_outcome.Call_Outcome {
		if other != .Argument_Refused {
			testing.expectf(t, !unseal_authorization_wrong(other, wrong), "the outcome %v is taken for a wrong authorization", other)
		}
	}
	testing.expect(t, unseal_authorization_wrong(.Argument_Refused, wrong))
}
