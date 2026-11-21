package quic_echo

import "modus:contract/value_kinds"
import "modus:quic"

// The log facts of quic_echo (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence, and the key that a test reads
// in it, read it as before. A line whose sentence differs by its case is
// one fact type for each case: the template has no condition. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero. The fields of an idle end have the names of the
// fact of remote that says the same.

// The bytes of the Text field of the address of a host: the longest,
// "255.255.255.255 port 65535", has 26 bytes.
PEER_FIELD_BYTES :: 32
// The bytes of the Text field of the cause of a stop at the start: the
// longest, "the module cryptography refused to make the public key", has 54
// bytes.
CAUSE_FIELD_BYTES :: 64
// The bytes of the Text field of the public key: 64 hexadecimal digits.
PUBLIC_KEY_FIELD_BYTES :: 72

// The end of a connection writes its code and its frame type in 16
// hexadecimal digits, as system.Hex wrote them. Its fields fill the 144
// bytes of one fact: the Text fields have the bytes of their longest text
// and a zero byte, the address 26, the cause of the end 22, the reason of
// the client its 48 kept bytes (quic.CLOSE_REASON_KEPT), with 5 to spare.

// The random seed of the process is weak: it makes no key and listens on
// nothing.
@(log_fact = "quic_echo: the random seed of this process is weak: it makes no key of a server, and listens on nothing")
Seed_Weak :: struct {}

// A connection ended with a code of the application.
@(log_fact = "quic_echo: {peer} ended ({end_cause}, the code {code} of the application, the frame type {frame_type}, the reason of the client \"{client_reason}\"): in {bytes_in}, out {bytes_out}, srtt {round_trip}")
Connection_Ended_By_Application :: struct {
	code:          value_kinds.Hexadecimal_Sixteen_Digits,
	frame_type:    value_kinds.Hexadecimal_Sixteen_Digits,
	bytes_in:      value_kinds.Size_In_Bytes,
	bytes_out:     value_kinds.Size_In_Bytes,
	round_trip:    value_kinds.Time_In_Microseconds,
	peer:          [27]u8,
	end_cause:     [23]u8,
	client_reason: [54]u8,
}

// A connection ended with a code of the transport.
@(log_fact = "quic_echo: {peer} ended ({end_cause}, the code {code}, the frame type {frame_type}, the reason of the client \"{client_reason}\"): in {bytes_in}, out {bytes_out}, srtt {round_trip}")
Connection_Ended :: struct {
	code:          value_kinds.Hexadecimal_Sixteen_Digits,
	frame_type:    value_kinds.Hexadecimal_Sixteen_Digits,
	bytes_in:      value_kinds.Size_In_Bytes,
	bytes_out:     value_kinds.Size_In_Bytes,
	round_trip:    value_kinds.Time_In_Microseconds,
	peer:          [27]u8,
	end_cause:     [23]u8,
	client_reason: [54]u8,
}

// The counts of the server, written when one of them changed in a second:
// two facts, the connections and the Initials, then the budgets and the
// Sends, as one template holds at most 512 bytes.
@(log_fact = "quic_echo: accepted {accepted}, ended {ended}, Retries {retries}, tokens refused {tokens_refused}, not authentic {not_authentic}, too small {too_small}, Initials refused by a limit (each try of a client counts) {refused_by_limit}, Initials refused with a full table {refused_full}")
Server_Counts :: struct {
	accepted:         u64,
	ended:            u64,
	retries:          u64,
	tokens_refused:   u64,
	not_authentic:    u64,
	too_small:        u64,
	refused_by_limit: u64,
	refused_full:     u64,
}

// The counts of the budgets of the server and of its refused Sends.
@(log_fact = "quic_echo: over the budget {over_budget}, over the budget of an address {over_address_budget}, new addresses with no place in the table of address budgets {address_table_full}, tokens used again {tokens_used_again}, version negotiations {version_negotiations}, Sends refused by the network service {sends_refused} (the last status {last_send_status})")
Server_Budget_Counts :: struct {
	over_budget:          u64,
	over_address_budget:  u64,
	address_table_full:   u64,
	tokens_used_again:    u64,
	version_negotiations: u64,
	sends_refused:        u64,
	last_send_status:     u64,
}

#assert(size_of(Connection_Ended) == 144 && 54 > quic.CLOSE_REASON_KEPT)

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
