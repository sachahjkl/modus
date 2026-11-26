#+build !freestanding
#+build !modus
package datagram

import "core:testing"

// The kind of a record of an endpoint ring and of the control ring comes
// from another process: None, one past the last member and the largest
// word are refused, and give None. Then each member but None comes back
// from its word.
@(test)
ring_words_refuse_a_word_that_names_no_member :: proc(t: ^testing.T) {
	commands_refused := [?]u32{u32(Command.None), u32(max(Command)) + 1, max(u32)}
	for word in commands_refused {
		read, ok := command_of_ring_word(word)
		testing.expectf(t, !ok, "the word %d names no command, and it is taken", word)
		testing.expect_value(t, read, Command.None)
	}
	controls_refused := [?]u32{u32(Control.None), u32(max(Control)) + 1, max(u32)}
	for word in controls_refused {
		read, ok := control_of_ring_word(word)
		testing.expectf(t, !ok, "the word %d names no control, and it is taken", word)
		testing.expect_value(t, read, Control.None)
	}
	for member in Command {
		if member == .None {
			continue
		}
		read, ok := command_of_ring_word(u32(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in Control {
		if member == .None {
			continue
		}
		read, ok := control_of_ring_word(u32(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
}

// expect_refused checks that grant_unpack refuses a word: known is false and
// the grant is zero, so that no right of the word reaches the caller.
@(private = "file")
expect_refused :: proc(t: ^testing.T, value: u64, location := #caller_location) {
	grant, known := grant_unpack(value)
	testing.expect(t, !known, "a word with a bit outside GRANT_KNOWN_BITS is refused", loc = location)
	testing.expect_value(t, grant, Grant{}, loc = location)
	testing.expect(t, !granted(grant), "a refused word names no remote", loc = location)
}

@(test)
a_word_with_the_first_unknown_bit_is_refused :: proc(t: ^testing.T) {
	first_unknown := GRANT_LISTEN << 1
	testing.expect_value(t, first_unknown & GRANT_KNOWN_BITS, 0)
	expect_refused(t, first_unknown)
}

@(test)
a_word_with_each_unknown_bit_is_refused :: proc(t: ^testing.T) {
	// Each bit above the flags, alone and beside a whole valid grant: a
	// valid part does not save the word.
	whole := grant_pack({address = 0x0A00_0264, port = 80, inspect = true, tcp = true, listen = true})
	for bit in uint(51) ..< 64 {
		unknown := u64(1) << bit
		expect_refused(t, unknown)
		expect_refused(t, whole | unknown)
	}
}

@(test)
the_largest_word_is_refused :: proc(t: ^testing.T) {
	expect_refused(t, max(u64))
	expect_refused(t, ~GRANT_KNOWN_BITS)
}

@(test)
the_known_bits_are_the_flags_and_the_remote :: proc(t: ^testing.T) {
	// The mask holds the three flags and the 48 bits of the address and the
	// port, and nothing above GRANT_LISTEN.
	testing.expect_value(t, GRANT_KNOWN_BITS & GRANT_INSPECT, GRANT_INSPECT)
	testing.expect_value(t, GRANT_KNOWN_BITS & GRANT_TCP, GRANT_TCP)
	testing.expect_value(t, GRANT_KNOWN_BITS & GRANT_LISTEN, GRANT_LISTEN)
	testing.expect_value(t, GRANT_KNOWN_BITS >> 51, 0)
	testing.expect_value(t, GRANT_KNOWN_BITS & ((u64(1) << 48) - 1), (u64(1) << 48) - 1)
}

@(test)
the_zero_word_is_no_grant :: proc(t: ^testing.T) {
	grant, known := grant_unpack(0)
	testing.expect(t, known, "0 is the word of no grant, a known word")
	testing.expect_value(t, grant, Grant{})
	testing.expect(t, !granted(grant), "the zero grant names no remote")
}

@(test)
each_flag_alone :: proc(t: ^testing.T) {
	inspect, inspect_known := grant_unpack(GRANT_INSPECT)
	testing.expect(t, inspect_known && inspect == Grant{inspect = true})
	tcp, tcp_known := grant_unpack(GRANT_TCP)
	testing.expect(t, tcp_known && tcp == Grant{tcp = true})
	listen, listen_known := grant_unpack(GRANT_LISTEN)
	testing.expect(t, listen_known && listen == Grant{listen = true})
	// A listen grant names a port, so it is a grant even with no address;
	// the flags Inspect and TCP alone name no remote.
	testing.expect(t, granted(listen) && !granted(inspect) && !granted(tcp))
}

@(test)
the_edges_of_the_address_and_the_port :: proc(t: ^testing.T) {
	edges := [?]Grant {
		{address = 1, port = 0},
		{address = 0, port = 1, listen = true},
		{address = max(u32), port = max(u16)},
		{address = max(u32), port = max(u16), inspect = true, tcp = true, listen = true},
	}
	for edge in edges {
		value := grant_pack(edge)
		testing.expect_value(t, value & ~GRANT_KNOWN_BITS, 0)
		unpacked, known := grant_unpack(value)
		testing.expect(t, known, "a word that grant_pack made is known")
		testing.expect_value(t, unpacked, edge)
	}
	// All the known bits set: the largest known word.
	largest, known := grant_unpack(GRANT_KNOWN_BITS)
	testing.expect(t, known)
	testing.expect_value(t, largest, Grant{address = max(u32), port = max(u16), inspect = true, tcp = true, listen = true})
}

@(test)
the_grants_of_the_processes_pass_through_the_word :: proc(t: ^testing.T) {
	grants := [?]Grant {
		{address = 0x0A00_0202, port = 7}, // A client grant of UDP.
		{address = 0x0A00_0264, port = 80, tcp = true}, // A client grant of TCP.
		{port = 80, tcp = true, listen = true}, // A listen grant of TCP.
		{address = 0x0A00_0202, port = 4433, listen = true, inspect = true}, // A listen grant of UDP for one address, with Inspect.
	}
	for grant in grants {
		unpacked, known := grant_unpack(grant_pack(grant))
		testing.expect(t, known)
		testing.expect_value(t, unpacked, grant)
		testing.expect(t, granted(unpacked))
	}
}
