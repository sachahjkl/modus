#+build !freestanding
#+build !modus
package network

import "core:testing"
import "modus:contract/datagram"
import "modus:contract/errors"

@(private = "file")
REMOTE_ADDRESS :: 0x0A00_0264 // 10.0.2.100

// The words that the service must refuse: the first and the last unknown
// bit alone, and each beside a whole grant that would be taken without it.
@(private = "file")
refused_words :: proc() -> [4]u64 {
	whole := datagram.grant_pack({address = REMOTE_ADDRESS, port = 80, tcp = true, inspect = true})
	first_unknown := u64(1) << datagram.GRANT_KNOWN_BIT_COUNT
	last_unknown := u64(1) << 63
	return {first_unknown, last_unknown, whole | first_unknown, whole | last_unknown}
}

@(private = "file")
expect_unknown_bits_refusal :: proc(t: ^testing.T, refusal: [7]u64, command: datagram.Control, argument: i64, word: u64, location := #caller_location) {
	record := errors.completion_record(refusal)
	testing.expect_value(t, record.kind, i64(errors.Kind.Bad_Value), loc = location)
	testing.expect_value(t, record.operation, i64(command), loc = location)
	testing.expect_value(t, record.argument, argument, loc = location)
	// The value is the unknown bits, never a negative number.
	testing.expect_value(t, record.value, i64(word >> datagram.GRANT_KNOWN_BIT_COUNT), loc = location)
	testing.expect(t, record.value > 0, "the value of the record is positive", loc = location)
	testing.expect_value(t, record.limit, 0, loc = location)
}

@(test)
endpoint_add_refuses_a_word_with_an_unknown_bit :: proc(t: ^testing.T) {
	for word in refused_words() {
		grant, refusal, ok := endpoint_add_grant(word)
		testing.expect(t, !ok, "a word with an unknown bit makes no endpoint")
		testing.expect_value(t, grant, datagram.Grant{})
		expect_unknown_bits_refusal(t, refusal, .Endpoint_Add, 3, word)
	}
	// Bit 63 alone: the value is the highest unknown bit, shifted down.
	_, refusal, _ := endpoint_add_grant(u64(1) << 63)
	testing.expect_value(t, errors.completion_record(refusal).value, i64(1) << (63 - datagram.GRANT_KNOWN_BIT_COUNT))
}

@(test)
endpoint_grant_refuses_a_word_with_an_unknown_bit :: proc(t: ^testing.T) {
	form := Endpoint_Form{tcp = true, listen = false, local_port = 49152}
	before := datagram.Grant{address = REMOTE_ADDRESS, port = 80, tcp = true}
	for word in refused_words() {
		current := before
		refusal, ok := endpoint_grant_change(form, &current, word)
		testing.expect(t, !ok, "a word with an unknown bit changes no grant")
		testing.expect_value(t, current, before)
		expect_unknown_bits_refusal(t, refusal, .Endpoint_Grant, 2, word)
	}
}

@(test)
endpoint_grant_refuses_another_form :: proc(t: ^testing.T) {
	form := Endpoint_Form{tcp = true, listen = true, local_port = 80}
	before := datagram.Grant{port = 80, tcp = true, listen = true}
	others := [?]datagram.Grant {
		{address = REMOTE_ADDRESS, port = 80, tcp = true}, // A client grant on a listen endpoint.
		{port = 80, listen = true}, // UDP on a TCP endpoint.
		{port = 81, tcp = true, listen = true}, // Another listen port.
	}
	for other in others {
		current := before
		word := datagram.grant_pack(other)
		refusal, ok := endpoint_grant_change(form, &current, word)
		testing.expect(t, !ok)
		testing.expect_value(t, current, before)
		record := errors.completion_record(refusal)
		testing.expect_value(t, record.kind, i64(errors.Kind.Bad_Value))
		testing.expect_value(t, record.argument, 2)
		testing.expect_value(t, record.value, i64(word))
	}
}

@(test)
the_grants_that_the_service_takes :: proc(t: ^testing.T) {
	// The zero word is a revocation, a known word.
	form := Endpoint_Form{tcp = true, listen = true, local_port = 80}
	current := datagram.Grant{port = 80, tcp = true, listen = true}
	_, revoked := endpoint_grant_change(form, &current, 0)
	testing.expect(t, revoked)
	testing.expect_value(t, current, datagram.Grant{})
	// The same form again, with the right Inspect.
	again := datagram.Grant{port = 80, tcp = true, listen = true, inspect = true}
	_, granted_again := endpoint_grant_change(form, &current, datagram.grant_pack(again))
	testing.expect(t, granted_again)
	testing.expect_value(t, current, again)
	// Endpoint_Add of the largest known word.
	grant, _, ok := endpoint_add_grant(datagram.GRANT_KNOWN_BITS)
	testing.expect(t, ok)
	testing.expect_value(t, grant, datagram.Grant{address = max(u32), port = max(u16), inspect = true, tcp = true, listen = true})
}
