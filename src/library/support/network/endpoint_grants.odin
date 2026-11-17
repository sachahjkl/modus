package network

import "modus:contract/datagram"
import "modus:contract/errors"

// The decisions of the network service on the grant word of a command of the
// control ring, as functions with no input or output, so that the host
// tests each refusal and that nothing changed (endpoint_grants_test.odin).
// The service acts on the result only: it makes or changes an endpoint
// when ok is true, and else completes the command with the refusal.

// The form of an endpoint, fixed at its creation: a new grant must keep it,
// because the local ports come from the creation only.
Endpoint_Form :: struct {
	tcp:        bool, // A segment endpoint.
	listen:     bool, // Made for a listen port.
	local_port: u16, // The local port; with a listen grant, the listen port.
}

// grant_word_refusal gives the values of the refusal of a grant word with a
// bit outside datagram.GRANT_KNOWN_BITS: Bad_Value of the argument, with
// the unknown bits as its value. The shift keeps the value positive for a
// word with bit 63, which a cast of the whole word to i64 makes negative.
@(private)
grant_word_refusal :: proc "contextless" (command: datagram.Control, argument: i64, word: u64) -> [7]u64 {
	return errors.ring_fail(u32(command), .Bad_Value, .None, argument, i64(word >> datagram.GRANT_KNOWN_BIT_COUNT), 0)
}

// endpoint_add_grant reads the grant word of Endpoint_Add (its argument 3).
// ok is false, the grant is zero and refusal holds the record of the
// completion, for a word with an unknown bit: the service then maps no
// region, opens no ring and makes no endpoint.
endpoint_add_grant :: proc "contextless" (word: u64) -> (grant: datagram.Grant, refusal: [7]u64, ok: bool) {
	unpacked, known := datagram.grant_unpack(word)
	if !known {
		return {}, grant_word_refusal(.Endpoint_Add, 3, word), false
	}
	return unpacked, {}, true
}

// endpoint_grant_change applies the grant word of Endpoint_Grant (its
// argument 2) to the grant of an endpoint of a form. The new grant is none
// (a revocation) or a grant of the same form and the same local ports.
// ok is false, refusal holds the record of the completion and `current`
// is unchanged, for a word with an unknown bit and for a grant of another
// form. The form is the one of the creation of the endpoint, not the one of
// its grant now: after a revocation, a client grant on an endpoint that was
// made for a listen port would send from that port.
endpoint_grant_change :: proc "contextless" (form: Endpoint_Form, current: ^datagram.Grant, word: u64) -> (refusal: [7]u64, ok: bool) {
	new_grant, known := datagram.grant_unpack(word)
	if !known {
		return grant_word_refusal(.Endpoint_Grant, 2, word), false
	}
	same_form := new_grant.tcp == form.tcp && new_grant.listen == form.listen && (!new_grant.listen || new_grant.port == form.local_port)
	if datagram.granted(new_grant) && !same_form {
		// A known word has no bit 63, so the cast keeps it positive.
		return errors.ring_fail(u32(datagram.Control.Endpoint_Grant), .Bad_Value, .None, 2, i64(word)), false
	}
	current^ = new_grant
	return {}, true
}
