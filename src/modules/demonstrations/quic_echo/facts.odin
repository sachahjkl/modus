package quic_echo

import "modus:contract/value_kinds"
import "modus:support/quic"

// The log facts of quic_echo (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence, and the key that a test reads
// in it, read it as before. A line whose sentence differs by its case is
// one fact type for each case: the template has no condition. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero. The fields of an idle end have the names of the
// fact of remote that says the same.
//
// Lines stay text: the end of a connection, which writes its codes in 16
// hexadecimal digits with no "0x", which no field kind writes; the counts
// of the server, whose template passes the bound of one fact; and the line
// with no value.

// The bytes of the Text field of the address of a host: the longest,
// "255.255.255.255 port 65535", has 26 bytes.
PEER_FIELD_BYTES :: 32
// The bytes of the Text field of the cause of a stop at the start: the
// longest, "the module cryptography refused to make the public key", has 54
// bytes.
CAUSE_FIELD_BYTES :: 64
// The bytes of the Text field of the public key: 64 hexadecimal digits.
PUBLIC_KEY_FIELD_BYTES :: 72

// The process stops at its start, for a cause that it names.
@(log_fact = "quic_echo: {cause}")
Start_Failed :: struct {
	cause: [64]u8,
}

// A connection ended by its idle timeout after a silence of at least that
// timeout.
@(log_fact = "quic_echo: {peer}: the idle end held its bound: {silence} with no packet of the client, the idle timeout {idle_timeout}, the bound {bound}, {after_bound} after the bound")
Idle_End_Held :: struct {
	silence:      value_kinds.Time_In_Milliseconds,
	idle_timeout: value_kinds.Time_In_Milliseconds,
	bound:        value_kinds.Time_In_Milliseconds,
	after_bound:  value_kinds.Time_In_Milliseconds,
	peer:         [32]u8,
}

// A connection ended by its idle timeout before a silence of that timeout.
@(log_fact = "quic_echo: {peer}: the idle end did NOT hold its bound: {silence} with no packet of the client, the idle timeout {idle_timeout}, the bound {bound}, {after_bound} after the bound")
Idle_End_Not_Held :: struct {
	silence:      value_kinds.Time_In_Milliseconds,
	idle_timeout: value_kinds.Time_In_Milliseconds,
	bound:        value_kinds.Time_In_Milliseconds,
	after_bound:  value_kinds.Time_In_Milliseconds,
	peer:         [32]u8,
}

// A client opened a connection.
@(log_fact = "quic_echo: a connection from {peer}")
Connection_Arrived :: struct {
	peer: [32]u8,
}

// The public key of the server, which a client checks.
@(log_fact = "quic_echo: the public key of this server: {public_key}")
Public_Key_Made :: struct {
	public_key: [72]u8,
}

// The server listens: its port, and the memory of its table.
@(log_fact = "quic_echo: listening on the UDP port {listen_port}, a table of {capacity} connections of {connection_size}, each with {streams} streams of {stream_size}, the key of this server from the generator of the process")
Listening :: struct {
	listen_port:     u64,
	capacity:        u64,
	connection_size: value_kinds.Size_In_Kibibytes,
	streams:         u64,
	stream_size:     value_kinds.Size_In_Kibibytes,
}

#assert(size_of(Idle_End_Held) == 32 + PEER_FIELD_BYTES)
#assert(size_of(Start_Failed) == CAUSE_FIELD_BYTES && size_of(Public_Key_Made) == PUBLIC_KEY_FIELD_BYTES)

// peer_field gives the Text field of the address of a host.
peer_field :: proc "contextless" (remote: quic.Remote) -> [PEER_FIELD_BYTES]u8 {
	text: [PEER_FIELD_BYTES]u8
	return value_kinds.text_field(address_text(text[:], remote), PEER_FIELD_BYTES)
}
