package collector_service

import "modus:contract/wide_grants"

// Log facts emitted by the freestanding collector service. Field names avoid
// the reserved log table header names (number, time, process, level).

FAILURE_FIELD_BYTES :: 96

@(log_fact = "collector: ready for principal {principal_id}, act capacity {act_capacity}, store {store}")
Service_Ready :: struct {
	principal_id: u64,
	act_capacity: u64,
	store:        u64,
}

// The audit spaces that a start read back from the private store, each
// segment checked.
// The windows of the spaces that the budget of the collector held at its
// start: the most of its open spaces, while the budget still pays them.
@(log_fact = "collector: its budget pays {windows} windows of spaces")
Space_Windows_Paid :: struct {
	windows: u64,
}

// The wakes of the poll of rings that one wait cannot hold, at each power
// of two: until the wait room of the kernel, a reader of more rings than a
// wait holds reads them again on a period.
@(log_fact = "collector: {wakes} wakes of its loop and {read_wakes} of its reads to read rings that one wait cannot hold")
Poll_Wakes_Counted :: struct {
	wakes:      u64,
	read_wakes: u64,
}

// A pass removed closed audit spaces whose retention ended.
@(log_fact = "collector: removed {spaces} closed audit spaces whose retention ended")
Closed_Spaces_Removed :: struct {
	spaces: u64,
}

// A pass on the closed audit spaces was refused: it goes on at the next.
@(log_fact = "collector: the removal of closed audit spaces stopped: {refusal}; the next pass goes on")
Closed_Spaces_Pass_Refused :: struct {
	refusal: wide_grants.Space_Refusal,
}

@(log_fact = "collector: read {spaces} audit spaces with {records} records from its store, in {objects} objects")
Spaces_Loaded :: struct {
	spaces:  u64,
	records: u64,
	objects: u64, // A measure: the objects that the start read, a few for each space whatever its count of records.
}

// A start found a damaged object of its audit spaces: each step of a space
// is refused until the store is repaired, so no part of an audit is served
// as the whole. Space 0 is the index of the spaces.
@(log_fact = "collector: the audit spaces in its store are damaged at space {space}")
Spaces_Store_Damaged :: struct {
	space: u64,
}

@(log_fact = "collector: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

@(log_fact = "collector: refused wide grant action with refusal {refusal_code} on grant {grant_serial}")
Wide_Grant_Action_Refused :: struct {
	refusal_code: u64,
	grant_serial: u64,
}

// The start gave the collector no authority key: it refuses each wide
// grant, because it cannot check the proof of one.
@(log_fact = "collector: no authority key for principal {principal_id}, each wide grant is refused")
Wide_Grants_Refused_Without_Authority_Key :: struct {
	principal_id: u64,
}

@(log_fact = "collector: expired {expired_grants} wide grants")
Grants_Expired :: struct {
	expired_grants: u64,
}

// The first refusal of a full space or of a full forward queue: the writer
// of the space waits from now on, and the counts of the space show each
// later refusal.
@(log_fact = "collector: space {space} is full and holds its writer, refusal {refusal_code}")
Space_Refused_Record :: struct {
	space:        u64,
	refusal_code: u64,
}

// A source that a wiring gave the collector, with the space that keeps
// its records.
@(log_fact = "collector: wiring {wiring_number} keeps {source}.{output} in space {space}")
Source_Opened :: struct {
	space:         u64,
	wiring_number: u64,
	source:        [32]u8,
	output:        [32]u8,
}

#assert(size_of(Source_Opened) == 80)

// A source that the collector closed: its names or its terms were
// refused, or a record broke the terms of its space.
@(log_fact = "collector: closed the source of wiring {wiring_number}, refusal {refusal_code}")
Source_Refused :: struct {
	wiring_number: u64,
	refusal_code:  u64,
}

// The router of the act spaces refused the end of a grant: its state says
// why (a grant that ended already, another grant).
@(log_fact = "collector: the end of the act records of grant {grant_serial} was refused: refusal {refusal_code}")
Act_Wiring_End_Refused :: struct {
	refusal_code: u64,
	grant_serial: u64,
}

// The space of the root service had no room for the record of the end of
// a grant: the grant ended, with no record of its end.
@(log_fact = "collector: the grant {grant_serial} ended with no record of its end: the space of the root service is full")
Act_Wiring_End_Not_Recorded :: struct {
	grant_serial: u64,
}

// The collector closed a ring of act records: a record of no grant, of an
// ended grant, of another grant or of another producer, or one that broke
// the terms of its space.
@(log_fact = "collector: closed the act records of wiring {wiring_number}, act refusal {act_refusal_code}, space refusal {space_refusal_code}")
Act_Source_Refused :: struct {
	wiring_number:      u64,
	act_refusal_code:   u64,
	space_refusal_code: u64,
}

#assert(size_of(Source_Refused) == 16)

@(log_fact = "collector: act chain verification failed at index {failing_index} with refusal {refusal_code}")
Chain_Verification_Failed :: struct {
	failing_index: u64,
	refusal_code:  u64,
}
