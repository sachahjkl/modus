package server

import "modus:contract/value_kinds"
import "modus:system"

// The access records of server as a record output
// (src/md/features/module_outputs.md, "The migration"). A reader wires
// `server.requests` and receives each request that this server answered
// from its joined record on, in order, each checked against its record
// description. The log keeps no access record: a fact has one place, and
// the log loses records by design.
//
// The server writes with no wait: it serves the network, and a reader of
// its choice must not hold it. A full ring of the pace Writer_Chooses
// refuses the record with Full, and the writer counts it; a ring of the
// pace Never_Holds_Writer refuses it for its reader alone, which reads a
// gap record with the count; a ring of the pace Always_Holds_Writer holds
// the server until it has room, as an audit asks.

// One request answered: its status, the bytes of its answer, its time from
// the first byte of its head to the last byte of its answer in the send
// buffer, its method, its target, and its host. Each byte is a field: the
// record has no padding, and each Text field ends with zero bytes.
Access_Record :: struct {
	status:      u64,
	answer_size: value_kinds.Size_In_Bytes,
	answer_time: value_kinds.Time_In_Microseconds,
	method:      [8]u8,
	target:      [56]u8,
	peer:        [32]u8,
}
#assert(size_of(Access_Record) == 24 + METHOD_FIELD_BYTES + TARGET_FIELD_BYTES + PEER_FIELD_BYTES)

// One request that the server answered.
requests: system.Record_Output(Access_Record)

// requests_write writes the access record of one request into each ring of
// requests, with no wait. The library counts each outcome in the state of
// requests (written, discarded with no reader, refused with Full, held),
// and publishes the counts in the head page of each ring, where
// stream_counts reads them: the server has nothing more to do with it.
requests_write :: proc "contextless" (record: Access_Record) {
	system.output_write(&requests, record, wait = false)
}
