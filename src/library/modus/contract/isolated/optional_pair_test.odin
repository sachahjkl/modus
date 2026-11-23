#+build !freestanding
package isolated

import "core:testing"
import "modus:contract/errors"
import "modus:contract/module"

// An optional parameter crosses the call region as a pair. Given, its
// Presence word and its value reach the words before and at its index in
// the call form, zero included; Absent, the value is 0 whatever the caller
// held; a Presence word past Given that a hostile caller writes is refused
// at decode, at its argument, and the export is not called.
@(test)
an_optional_pair_crosses_the_call_region :: proc(t: ^testing.T) {
	function: module.Function
	function.parameter_count = 2
	function.parameters[0] = u8(module.Type.Integer)
	function.parameters[1] = u8(module.Type.Integer)
	function.parameter_needs[0] = u8(module.Parameter_Need.Optional)
	function.result = u8(module.Type.Integer)
	size, described := record_size(function)
	testing.expect(t, described && size == 24)
	region: [256]u8
	arguments := [2]Argument{{presence = .Given, integer = 0}, {integer = 7}}
	offset, encoded_size, _, _, ok := encode(nil, function, arguments[:], region[:])
	testing.expect(t, ok && encoded_size == 24)
	call: Call
	testing.expect(t, decode(nil, function, offset, encoded_size, region[:], &call))
	testing.expect(t, call.arguments[0] == u64(module.Presence.Given) && call.arguments[1] == 0 && call.arguments[2] == 7)
	absent := [2]Argument{{presence = .Absent, integer = 99}, {integer = 7}}
	offset, encoded_size, _, _, ok = encode(nil, function, absent[:], region[:])
	testing.expect(t, ok)
	call = {}
	testing.expect(t, decode(nil, function, offset, encoded_size, region[:], &call))
	testing.expect(t, call.arguments[0] == 0 && call.arguments[1] == 0 && call.arguments[2] == 7)
	for word in ([?]u64{2, max(u64)}) {
		store(region[:], offset, word)
		store(region[:], offset + 8, u64(5))
		refusal: errors.Error_Record
		call = {}
		testing.expectf(t, !decode(nil, function, offset, encoded_size, region[:], &call, &refusal), "the presence word %d is taken", word)
		testing.expect_value(t, refusal.argument, 1)
	}
	// Eight optional parameters and an error record take 17 words: past the
	// call form; seven take 15.
	all: module.Function
	all.parameter_count = 7
	for index in 0 ..< 7 {
		all.parameters[index] = u8(module.Type.Integer)
		all.parameter_needs[index] = u8(module.Parameter_Need.Optional)
	}
	_, six_described := record_size(all)
	testing.expect(t, six_described)
	all.error_record = 1
	_, seven := record_size(all)
	testing.expect(t, seven)
	all.parameter_count = 8
	all.parameters[7] = u8(module.Type.Integer)
	all.parameter_needs[7] = u8(module.Parameter_Need.Optional)
	_, too_many := record_size(all)
	testing.expect(t, !too_many)
	// An optional Text is refused: an address has no value to leave out.
	text := function
	text.parameters[0] = u8(module.Type.Text)
	_, text_described := record_size(text)
	testing.expect(t, !text_described)
}
