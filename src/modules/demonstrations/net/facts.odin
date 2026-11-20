package net

import "modus:contract/value_kinds"

// The log facts of net (src/md/features/log_facts.md): each fact template
// is the line that the process wrote before it was a fact, so a wait of a
// machine test on that sentence, and the measures that the tool reads from
// it, read it as before. A line whose sentence differs by its case is one
// fact type for each case: the template has no condition. The Text fields
// are the last fields: the serial line of a fact stops at its last byte
// that is not zero.
//
// Lines stay text: the line of each case and the line of the datagram after
// a key, whose answer is a sentence of an error record of up to 240 bytes,
// more than the values of one fact; the kernel entries for each datagram,
// which write hundredths, a number with a decimal that no field kind
// writes; and the lines with no value.

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
