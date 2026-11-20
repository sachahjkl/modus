package net

import "modus:contract/errors"
import "modus:contract/value_kinds"

// The log facts of net (src/md/features/log_facts.md): each fact template
// is the line that the process wrote before it was a fact, so a wait of a
// machine test on that sentence, and the measures that the tool reads from
// it, read it as before. A line whose sentence differs by its case is one
// fact type for each case: the template has no condition. The Text fields
// are the last fields: the serial line of a fact stops at its last byte
// that is not zero.
//
// Each case has its own fact type: the answer of a case is its fields, and
// the field wrong_mark holds "" or " (WRONG)" after it, as the line did. A
// case whose answer was the sentence of an error record writes the fields
// of the record; its template ends with them, so a wrong answer of such a
// case is a fact type of its own, with "WRONG" before the record.

// The bytes of the Text field of the mark of a wrong answer: "" or
// " (WRONG)".
WRONG_MARK_FIELD_BYTES :: 16
// The bytes of the Text field of an IPv4 address: the longest,
// "255.255.255.255", has 15 bytes.
ADDRESS_FIELD_BYTES :: 16
// The bytes of the Text field of a hardware address: 17 bytes.
HARDWARE_FIELD_BYTES :: 24
// The bytes of the Text field of the state of the link: "up" or "down".
LINK_FIELD_BYTES :: 8

// Case 1: the address of the endpoint, its link and its hardware address.
@(log_fact = "net: the link and the address: {address}/24, the link is {link}, {hardware}{wrong_mark}")
Link_And_Address :: struct {
	address:    [16]u8,
	link:       [8]u8,
	hardware:   [24]u8,
	wrong_mark: [16]u8,
}

// Case 2: the hardware address of the gateway, by ARP.
@(log_fact = "net: ARP: who has 10.0.2.2: the gateway answered {hardware} in {took}{wrong_mark}")
Gateway_Resolved :: struct {
	took:       value_kinds.Time_In_Microseconds,
	hardware:   [24]u8,
	wrong_mark: [16]u8,
}

// Case 3: an echo of the gateway.
@(log_fact = "net: ICMP echo to 10.0.2.2, 56 bytes: the echo reply came in {took}, time to live {time_to_live}{wrong_mark}")
Gateway_Echoed :: struct {
	took:         value_kinds.Time_In_Microseconds,
	time_to_live: u64,
	wrong_mark:   [16]u8,
}

// Case 4: a datagram to the echo server and its answer.
@(log_fact = "net: UDP to 10.0.2.2 port 7, 41 bytes: the same 41 bytes came back from {remote} port {remote_port} in {took}{wrong_mark}")
Echo_Server_Answered :: struct {
	remote_port: u64,
	took:        value_kinds.Time_In_Microseconds,
	remote:      [16]u8,
	wrong_mark:  [16]u8,
}

// Case 5: a datagram to a port that the grant does not give, refused.
@(log_fact = "net: UDP to 10.0.2.2 port 9: refused: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Other_Port_Refused :: distinct errors.Error_Record_Fact_Fields

// Case 5 fails.
@(log_fact = "net: UDP to 10.0.2.2 port 9: WRONG: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Other_Port_Refused_Wrong :: distinct errors.Error_Record_Fact_Fields

// Case 6: an echo of another address, refused.
@(log_fact = "net: ICMP echo to 10.0.2.3: refused: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Other_Address_Echo_Refused :: distinct errors.Error_Record_Fact_Fields

// Case 6 fails.
@(log_fact = "net: ICMP echo to 10.0.2.3: WRONG: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Other_Address_Echo_Refused_Wrong :: distinct errors.Error_Record_Fact_Fields

// Case 7: a datagram larger than one frame, refused: no fragment.
@(log_fact = "net: UDP of 2000 bytes: refused, no fragment: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Large_Datagram_Refused :: distinct errors.Error_Record_Fact_Fields

// Case 7 fails.
@(log_fact = "net: UDP of 2000 bytes: WRONG: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Large_Datagram_Refused_Wrong :: distinct errors.Error_Record_Fact_Fields

// Case 8: a datagram with a forged source port, refused.
@(log_fact = "net: UDP from the source port 1234: refused: the source port {found_port} of the header is not the local port of this endpoint, {local_port}{wrong_mark}")
Source_Port_Refused :: struct {
	found_port: u64,
	local_port: u64,
	wrong_mark: [16]u8,
}

// A datagram whose length field is not its count of bytes, refused.
@(log_fact = "net: UDP with a wrong length field: refused: the length field of the header says {field_bytes} bytes, the Send has {send_bytes}{wrong_mark}")
Length_Field_Refused :: struct {
	field_bytes: u64,
	send_bytes:  u64,
	wrong_mark:  [16]u8,
}

// A datagram shorter than the UDP header, refused.
@(log_fact = "net: UDP of 7 bytes: refused: the Send has {send_bytes} bytes, a datagram has {least_bytes} bytes at least, its header{wrong_mark}")
Short_Datagram_Refused :: struct {
	send_bytes:  u64,
	least_bytes: u64,
	wrong_mark:  [16]u8,
}

// Case 9: the datagram of the peer with a wrong checksum, which this
// process dropped: one datagram.
@(log_fact = "net: UDP from 10.0.2.2 port 7 with a wrong checksum: dropped by this process: {datagrams} datagram; the network service gave it to the endpoint of its port{wrong_mark}")
Wrong_Checksum_Dropped :: struct {
	datagrams:  u64,
	wrong_mark: [16]u8,
}

// Case 9 with another count of datagrams than one.
@(log_fact = "net: UDP from 10.0.2.2 port 7 with a wrong checksum: dropped by this process: {datagrams} datagrams; the network service gave it to the endpoint of its port{wrong_mark}")
Wrong_Checksums_Dropped :: struct {
	datagrams:  u64,
	wrong_mark: [16]u8,
}

// Case 10: the problem row of this endpoint.
@(log_fact = "net: UDP from 10.0.2.2 port 9 to this endpoint: refused: from port {from_port}; a row of this endpoint{wrong_mark}")
Endpoint_Row_Found :: struct {
	from_port:  u64,
	wrong_mark: [16]u8,
}

// Case 11: the problem rows of the machine, with the right Inspect.
@(log_fact = "net: malformed frames from the wire: {refused} refused in {kinds} kinds, {found} of {expected} expected; no fault{wrong_mark}")
Machine_Rows_Found :: struct {
	refused:    u64,
	kinds:      u64,
	found:      u64,
	expected:   u64,
	wrong_mark: [16]u8,
}

// Case 11 with no right Inspect: no row of the machine.
@(log_fact = "net: malformed frames from the wire: not shown: the grant has no right Inspect{wrong_mark}")
Machine_Rows_Not_Shown :: struct {
	wrong_mark: [16]u8,
}

// Case 12: the echo requests of the gateway that the network service
// answered: one.
@(log_fact = "net: ICMP echo from 10.0.2.2 to this machine: the network service answered {requests} request{wrong_mark}")
Echo_Request_Answered :: struct {
	requests:   u64,
	wrong_mark: [16]u8,
}

// Case 12 with another count of requests than one.
@(log_fact = "net: ICMP echo from 10.0.2.2 to this machine: the network service answered {requests} requests{wrong_mark}")
Echo_Requests_Answered :: struct {
	requests:   u64,
	wrong_mark: [16]u8,
}

// Case 12 with no right Inspect.
@(log_fact = "net: ICMP echo from 10.0.2.2 to this machine: not shown: the grant has no right Inspect{wrong_mark}")
Echo_Requests_Not_Shown :: struct {
	wrong_mark: [16]u8,
}

// The datagram after a key got no answer.
@(log_fact = "net: a datagram to 10.0.2.2 port 7 after a key: no answer of the network service")
Key_Datagram_Unanswered :: struct {}

// The datagram after a key is refused: the revocation ended the grant.
@(log_fact = "net: a datagram to 10.0.2.2 port 7 after a key: refused, the endpoint has no grant now: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Key_Datagram_Refused :: distinct errors.Error_Record_Fact_Fields

// The datagram after a key is refused for another cause.
@(log_fact = "net: a datagram to 10.0.2.2 port 7 after a key: refused: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Key_Datagram_Refused_Otherwise :: distinct errors.Error_Record_Fact_Fields

// The datagram after a key is sent, and the echo answered.
@(log_fact = "net: a datagram to 10.0.2.2 port 7 after a key: sent, and answer")
Key_Datagram_Answered :: struct {}

// The datagram after a key is sent, and no echo came.
@(log_fact = "net: a datagram to 10.0.2.2 port 7 after a key: sent, and no answer")
Key_Datagram_Sent_Without_Answer :: struct {}

// The kernel entries of each datagram of the burst, in hundredths: of this
// process, of the network service, of the frame service.
@(log_fact = "net: kernel entries for each datagram: {this_process} of this process, {network_service} of the network service, {frame_service} of the frame service")
Burst_Entries_Measured :: struct {
	this_process:    value_kinds.Hundredths,
	network_service: value_kinds.Hundredths,
	frame_service:   value_kinds.Hundredths,
}

// The endpoint has no grant of the network.
@(log_fact = "net: no endpoint: the process has no grant of the network")
No_Endpoint :: struct {}

// The process has no datagram region.
@(log_fact = "net: no datagram region")
No_Datagram_Region :: struct {}

// The measures are done.
@(log_fact = "net: the measures are done")
Measures_Done :: struct {}

// wrong_mark_field gives the mark of a wrong answer after the answer of a
// case.
wrong_mark_field :: proc "contextless" (right: bool) -> [WRONG_MARK_FIELD_BYTES]u8 {
	return value_kinds.text_field(right ? "" : " (WRONG)", WRONG_MARK_FIELD_BYTES)
}

// The bytes of the Text field of a problem row of the network service: the
// text of network.problem_write in a buffer of 128 bytes, and a zero byte.
PROBLEM_FIELD_BYTES :: 136

// A problem row of this endpoint: the count of the frames that the network
// service refused for it, and the last problem.
@(log_fact = "net: refused for this endpoint: {count} x {problem}")
Refused_For_Endpoint :: struct {
	count:   u64,
	problem: [136]u8,
}

// A problem row of the machine: the count of the frames that the network
// service refused before any endpoint, and the last problem.
@(log_fact = "net: refused for the machine: {count} x {problem}")
Refused_For_Machine :: struct {
	count:   u64,
	problem: [136]u8,
}

// A command word that names no command is refused at the border of the
// network service, and the next command is served.
@(log_fact = "net: the command word {word} of the datagram ring: refused with Bad_Command and the record Unsupported of the word, and the next Info is served: as it must")
Command_Word_Refused :: struct {
	word: u64,
}

// The network service answered a command word that names no command with
// another completion than the refusal.
@(log_fact = "net: the command word {word} of the datagram ring: WRONG: the status {status}, the error kind {error_kind}, the operation {operation}; the next Info: the status {next_status}")
Command_Word_Wrong :: struct {
	word:        u64,
	status:      u64,
	error_kind:  u64,
	operation:   u64,
	next_status: u64,
}

// The network service gave no answer to a command word that names no
// command.
@(log_fact = "net: the command word {word} of the datagram ring: WRONG: no answer, the status {status}, the error kind {error_kind}, the operation {operation}; the next Info: the status {next_status}")
Command_Word_Unanswered :: struct {
	word:        u64,
	status:      u64,
	error_kind:  u64,
	operation:   u64,
	next_status: u64,
}

// The round trip of one datagram to the peer and back: the least and the
// middle of the trips.
@(log_fact = "net: the round trip of one datagram of {datagram_size}: {least} at least, {middle} in the middle, over {trips}")
Round_Trip_Measured :: struct {
	datagram_size: value_kinds.Size_In_Bytes,
	least:         value_kinds.Time_In_Microseconds,
	middle:        value_kinds.Time_In_Microseconds,
	trips:         u64,
}

// A request that the network service refuses, from the command to its
// completion.
@(log_fact = "net: a refused request of the datagram ring (Send of 2000 bytes, Too_Large), from the command to its completion: {request}, {refused} of {requests} refused")
Refusal_Measured :: struct {
	request:  value_kinds.Time_In_Nanoseconds,
	refused:  u64,
	requests: u64,
}

// The UDP header and the checksum of one datagram, written by this
// process.
@(log_fact = "net: the header and the checksum of a datagram of {datagram_size}: {header_and_checksum}, in this process (no offload)")
Checksum_Measured :: struct {
	datagram_size:       value_kinds.Size_In_Bytes,
	header_and_checksum: value_kinds.Time_In_Nanoseconds,
}

// The datagrams answered in one second with a count of them in flight.
@(log_fact = "net: a burst with {in_flight} datagrams in flight: {rate} datagrams in one second, sent and answered, {lost} lost")
Burst_Measured :: struct {
	in_flight: u64,
	rate:      u64,
	lost:      u64,
}

// Each case gave its answer.
@(log_fact = "net: ok, {cases} cases")
Cases_Passed :: struct {
	cases: u64,
}

// Some cases gave a wrong answer.
@(log_fact = "net: WRONG: {wrong} of {cases} cases")
Cases_Wrong :: struct {
	wrong: u64,
	cases: u64,
}

#assert(size_of(Refused_For_Endpoint) == 8 + PROBLEM_FIELD_BYTES)
