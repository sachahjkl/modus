// The result of a call of a client of the storage service, beside the
// result of its export, which the support package storage gives. A
// process writes it in a log fact, which a reader of another process
// renders, so it is a contract: each reader compiles its names in
// (value_kinds.Contract_Enum).
package storage_status

// The result of a call of a client of the storage service. The values
// cross the log in a fact: each value is explicit.
Status :: enum u8 {
	Ok        = 0, // The export ran and answered a number that is not negative.
	Gone      = 1, // The connection ended: the grant was revoked, or the storage service stopped.
	Refused   = 2, // The storage service refused the call: see isolated.Status.
	Damaged   = 3, // The storage service has the object and cannot give its bytes: a block has a wrong check, or the disk gave an error.
	Failed    = 4, // The export answered a negative number: the error record says why.
	Too_Small = 5, // The bytes do not fit in the buffer of the caller: the count of the bytes is the result.
	No_Answer = 6, // The storage service gave no answer before ANSWER_BOUND_MILLISECONDS: the connection ends, and each later call gives Gone.
}

// The bound of the wait for the answer of one call of the storage service.
// A commit of the largest pending changes of a connection hashes and
// writes a few MiB, which a working disk does in well under a second: the
// bound only ends a hang of the service, so that its client gives a status
// and goes on instead of waiting for ever.
ANSWER_BOUND_MILLISECONDS :: 60_000

// The name of each member, as Status names it.
@(rodata)
STATUS_NAMES := [Status]string {
	.Ok        = "Ok",
	.Gone      = "Gone",
	.Refused   = "Refused",
	.Damaged   = "Damaged",
	.Failed    = "Failed",
	.Too_Small = "Too_Small",
	.No_Answer = "No_Answer",
}

// The word of a Status in 8 bytes, for a record that holds it beside
// fields of 8 bytes with no padding (value_kinds.Contract_Enum_Type).
Status_Word :: distinct u64
#assert(size_of(Status_Word) >= size_of(Status))
