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
