#+build !freestanding
package projects_core

import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"

@(private = "file")
pin_test_hash :: proc(tag: u8) -> blake3.Hash {
	data := [4]u8{'p', 'i', 'n', tag}
	return blake3.hash(data[:])
}

@(private = "file")
Pin_Test_Resolver :: struct {
	tree: blake3.Hash,
}

@(private = "file")
pin_test_resolver :: proc "contextless" (request: ^pr.Source_Resolver_Request, user_data: rawptr) -> (pr.Source_Resolver_Response, bool) {
	data := (^Pin_Test_Resolver)(user_data)
	response := pr.Source_Resolver_Response {
		status_word         = u64(pr.Source_Resolver_Status.Ok),
		source_module_hash  = request.source_module_hash,
		resolved_tree_hash  = data.tree,
		resolved_ref_length = 2,
	}
	copy(response.resolved_ref_bytes[:], "v1")
	return response, true
}

@(private = "file")
pin_test_request :: proc(name: string) -> pr.Source_Resolver_Request {
	request := pr.Source_Resolver_Request {
		action_word        = u64(pr.Source_Resolver_Action.Resolve),
		source_module_hash = pin_test_hash(1),
	}
	copy(request.input_name_bytes[:], name)
	request.input_name_length = u8(len(name))
	address := "https://git.example.org/x"
	copy(request.address_bytes[:], address)
	request.address_length = u16(len(address))
	host := "git.example.org"
	copy(request.allowed_host_bytes[:], host)
	request.allowed_host_length = u16(len(host))
	return request
}

@(test)
test_projects_pin_count_keeps_the_last_good_pins :: proc(t: ^testing.T) {
	state := new(Projects_State)
	defer free(state)
	state_init(state)
	listed: [pr.MAX_PROJECT_PINS]pr.Pin_Entry

	testing.expect_value(t, state.counters.last_pin_count, u64(0))

	// Each damaged pins.lex is refused, and the count stays 0.
	too_long: [pr.MAX_PINS_LEX_BYTES + 1]u8
	for &item in too_long {
		item = ' '
	}
	too_long[0] = '{'
	too_long[len(too_long) - 1] = '}'
	damaged := [?]string{"{", "}", "{ x = ", "{ \x00 }", "[ ]", "{ gt = 1 }"}
	_, empty_refusal := list_inputs(state, nil, listed[:])
	testing.expect_value(t, empty_refusal, pr.Project_Refusal.Malformed_Syntax)
	_, long_refusal := list_inputs(state, too_long[:], listed[:])
	testing.expect_value(t, long_refusal, pr.Project_Refusal.Malformed_Syntax)
	for text in damaged {
		count, refusal := list_inputs(state, transmute([]u8)text, listed[:])
		testing.expect(t, refusal != .None, "a damaged pins.lex is refused")
		testing.expect_value(t, count, 0)
	}
	testing.expect_value(t, state.counters.last_pin_count, u64(0))
	testing.expect_value(t, state.counters.total_inputs_queries, u64(0))
	testing.expect_value(t, state.counters.total_refusals, u64(len(damaged) + 2))

	// A good pins.lex of two pins sets the count.
	requests := [2]pr.Source_Resolver_Request{pin_test_request("gt"), pin_test_request("tool")}
	resolver := Pin_Test_Resolver{tree = pin_test_hash(7)}
	update := update_pins(state, nil, requests[:], pin_test_resolver, &resolver)
	testing.expect_value(t, update.refusal, pr.Project_Refusal.None)
	good := update.pins_lex_bytes[:update.pins_lex_length]
	count, refusal := list_inputs(state, good, listed[:])
	testing.expect_value(t, refusal, pr.Project_Refusal.None)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, state.counters.last_pin_count, u64(2))

	// A good file cut in its middle is refused, and the count of the last good
	// file stays. Its last byte alone is a newline that the parser may skip.
	_, cut_refusal := list_inputs(state, good[:len(good) / 2], listed[:])
	testing.expect(t, cut_refusal != .None, "a pins.lex cut short is refused")
	flipped: [pr.MAX_PINS_LEX_BYTES]u8
	copy(flipped[:], good)
	flipped[0] = '('
	_, flipped_refusal := list_inputs(state, flipped[:len(good)], listed[:])
	testing.expect(t, flipped_refusal != .None, "a pins.lex with a wrong first byte is refused")
	testing.expect_value(t, state.counters.last_pin_count, u64(2))

	// An output too small for the pins is refused and keeps the count.
	one: [1]pr.Pin_Entry
	_, small_refusal := list_inputs(state, good, one[:])
	testing.expect(t, small_refusal != .None, "an output of one pin for two pins is refused")
	testing.expect_value(t, state.counters.last_pin_count, u64(2))
}
