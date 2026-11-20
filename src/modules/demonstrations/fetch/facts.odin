package fetch

import "modus:contract/errors"
import "modus:contract/value_kinds"

// The log facts of the demonstration fetch (src/md/features/log_facts.md,
// "The facts of the demonstrations"): its cases and the counts of its
// connection, as records of fields. Each fact template is the sentence that
// the line wrote before it was a fact, so a wait of a machine test on that
// sentence reads it as before. A Text field comes last, and holds its
// longest text and a zero byte.
//
// A case that did not hold ends with " (WRONG)": the field `wrong_mark`
// holds it, or nothing. A refusal of the network service is its error
// record as fields; a rate is in hundredths of a megabyte in one second.

// The cases with no value: each sentence is its fact type.

@(log_fact = "fetch: the handshake with 10.0.2.100 port 80: no answer (WRONG)")
Handshake_Not_Answered :: struct {}

@(log_fact = "fetch: the held commands passed their proven bound")
Held_Commands_Past_Bound :: struct {}

@(log_fact = "fetch: no random seed in the context")
No_Random_Seed :: struct {}

@(log_fact = "fetch: no endpoint: the process has no grant of the network")
No_Endpoint :: struct {}

@(log_fact = "fetch: no datagram region")
No_Datagram_Region :: struct {}

@(log_fact = "fetch: no memory for the buffers of the connections")
No_Connection_Memory :: struct {}

@(log_fact = "fetch: the secret of the initial sequence numbers from the generator of the process")
Sequence_Secret_Taken :: struct {}

@(log_fact = "fetch: the connection ended, its record is free")
Connection_Ended :: struct {}

// A SYN to a remote that the grant does not name: the error record of the
// refusal of the network service.
@(log_fact = "fetch: a SYN to 10.0.2.2 port 80: refused by the network service: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}{wrong_mark}")
Syn_To_Other_Remote_Refused :: struct {
	kind:       errors.Kind_Word,
	unit:       errors.Unit_Word,
	operation:  i64,
	argument:   i64,
	value:      i64,
	limit:      i64,
	found:      i64,
	wrong_mark: [16]u8,
}

// A SYN from a local port that is not in the block of the endpoint: the
// error record of the refusal, and the block.
@(log_fact = "fetch: a SYN from the local port 1234: refused: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found} (its ports are {first_local_port} to {last_local_port}){wrong_mark}")
Syn_From_Other_Port_Refused :: struct {
	kind:             errors.Kind_Word,
	unit:             errors.Unit_Word,
	operation:        i64,
	argument:         i64,
	value:            i64,
	limit:            i64,
	found:            i64,
	first_local_port: u64,
	last_local_port:  u64,
	wrong_mark:       [16]u8,
}

// The large page of 1 MiB: its bytes, its hash as system.Hex writes it,
// whether it is the hash of the pattern, and the rate.
@(log_fact = "fetch: GET /large: {received_bytes} bytes, fnv1a64 {received_hash} {hash_check}, {rate} MB/s{wrong_mark}")
Large_Page_Received :: struct {
	received_bytes: u64,
	received_hash:  value_kinds.Hexadecimal_Sixteen_Digits,
	rate:           value_kinds.Hundredths,
	wrong_mark:     [16]u8,
	hash_check:     [24]u8,
}

// A body of 1 MiB to the remote: whether the remote got the same hash, and
// the rate.
@(log_fact = "fetch: POST /sink, 1 MiB: {hash_answer}, {rate} MB/s{wrong_mark}")
Body_Sent :: struct {
	rate:        value_kinds.Hundredths,
	wrong_mark:  [16]u8,
	hash_answer: [40]u8,
}

// The grant of the endpoint: one remote, and a block of local ports.
@(log_fact = "fetch: the grant: TCP to {remote_address} port {remote_port} only, from the local ports {first_local_port} to {last_local_port}{wrong_mark}")
Grant_Read :: struct {
	remote_port:      u64,
	first_local_port: u64,
	last_local_port:  u64,
	remote_address:   [16]u8,
	wrong_mark:       [16]u8,
}

// The handshake with the remote: its time and the MSS of the connection.
@(log_fact = "fetch: the handshake with 10.0.2.100 port 80: established in {handshake_time} us, the MSS {segment_size_most}{wrong_mark}")
Handshake_Established :: struct {
	handshake_time:    u64,
	segment_size_most: u64,
	wrong_mark:        [16]u8,
}

// The answer to GET /hello: its status, its body and its time.
@(log_fact = "fetch: GET /hello: status {status_code}, \"{body}\" in {request_time} us{wrong_mark}")
Hello_Answered :: struct {
	status_code:  u64,
	request_time: u64,
	wrong_mark:   [16]u8,
	body:         [64]u8,
}

// The times of the exchange of GET /hello, from the start of the request.
@(log_fact = "fetch: GET /hello: the request went to the network service after {request_sent} us, the first segment came after {first_segment} us, the first segment with data after {first_data} us")
Hello_Timed :: struct {
	request_sent:  u64,
	first_segment: u64,
	first_data:    u64,
}

// The close from this side: the remote acknowledged the FIN, and how it
// ended its half.
@(log_fact = "fetch: the close from this side: the remote acknowledged the FIN, {close_end}{wrong_mark}")
Close_Acknowledged :: struct {
	wrong_mark: [16]u8,
	close_end:  [40]u8,
}

// The counts of the connection at its end.
@(log_fact = "fetch: the connection: {segments_sent} segments sent, {segments_received} received, {retransmissions} retransmissions, srtt {smoothed_round_trip} us, {bad_checksums} segments dropped for a wrong checksum")
Connection_Counted :: struct {
	segments_sent:       u64,
	segments_received:   u64,
	retransmissions:     u64,
	smoothed_round_trip: u64,
	bad_checksums:       u64,
}

// Each case held.
@(log_fact = "fetch: ok, {cases} cases")
Fetch_Held :: struct {
	cases: u64,
}

// Some cases did not hold.
@(log_fact = "fetch: WRONG: {wrong_cases} of {cases} cases")
Fetch_Wrong :: struct {
	wrong_cases: u64,
	cases:       u64,
}
