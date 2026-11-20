package block_service

import "modus:contract/value_kinds"

// The log facts of the block service (src/md/features/log_facts.md, "The
// facts of the storage service and of the disk"): the stop of the service
// when the device fails, as records of fields. Each fact template is the
// sentence that the line wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before. No field has the name
// of a column of the head of facts(): number, time, process, level.

// The device did not answer a request by the bound of a wait: each request
// in flight fails, and the service stops.
@(log_fact = "block: the device did not answer a request in {bound}: {in_flight} requests in flight fail, and the service stops")
Device_Silent :: struct {
	bound:     value_kinds.Time_In_Milliseconds,
	in_flight: u64,
}

// The device says that it needs a reset: each request in flight fails, and
// the service stops.
@(log_fact = "block: the device needs a reset: {in_flight} requests in flight fail, and the service stops")
Device_Needs_Reset :: struct {
	in_flight: u64,
}

// The bytes of the Text field of the failure that stops the service: the
// longest of the failures of the services of the devices and of the
// network has 91 bytes, and a zero byte.
FAILURE_FIELD_BYTES :: 96

// The service stops on a failure: the words of the failure come from a
// closed set of sentences of this module.
@(log_fact = "block: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

// The device is ready, and it takes a Flush. The template names the size
// of a block by its words: it is a constant of the contract.
@(log_fact = "block: ok, {disk_size} of 4096 bytes, a queue of {queue_size}, {requests_in_flight} requests in flight at most, flush: yes")
Ready_With_Flush :: struct {
	disk_size:          value_kinds.Size_In_Blocks,
	queue_size:         u64,
	requests_in_flight: u64,
}

// The device is ready, and it takes no Flush.
@(log_fact = "block: ok, {disk_size} of 4096 bytes, a queue of {queue_size}, {requests_in_flight} requests in flight at most, flush: no")
Ready_Without_Flush :: struct {
	disk_size:          value_kinds.Size_In_Blocks,
	queue_size:         u64,
	requests_in_flight: u64,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)
