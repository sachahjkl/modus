package fetch

// The log facts of the demonstration fetch (src/md/features/log_facts.md,
// "The facts of the demonstrations"): its cases and the counts of its
// connection, as records of fields. Each fact template is the sentence that
// the line wrote before it was a fact, so a wait of a machine test on that
// sentence reads it as before. A Text field comes last, and holds its
// longest text and a zero byte.
//
// A case that did not hold ends with " (WRONG)": the field `wrong_mark`
// holds it, or nothing. The cases of a refusal, of GET /large and of
// POST /sink stay text: the sentence of an error record is longer than a
// fact holds, a hash is written as system.Hex writes it, and a rate has one
// decimal, which no field kind writes.

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
