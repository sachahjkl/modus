// The result of a call of a client of the storage service, beside the
// result of its export, which the support package storage gives. A
// process writes it in a log fact, which a reader of another process
// renders, so it is a contract: each reader compiles its names in
// (value_kinds.Contract_Enum).
package storage_status

import "modus:contract/call_outcome"

// The result of a call of a client of the storage service. The values
// cross the log in a fact: each value is explicit.
Status :: enum u8 {
	Ok        = 0, // The export ran and gave the call outcome Succeeded.
	Gone      = 1, // The connection ended: the grant was revoked, or the storage service stopped.
	Refused   = 2, // The client sent no call, or could not read the result that the export wrote: no name, no room, a full ring, a damaged result.
	Damaged   = 3, // The storage service has the object and cannot give its bytes: a block has a wrong check, or the disk gave an error.
	Failed    = 4, // The export gave a call outcome that is not Succeeded: the error record says why.
	Too_Small = 5, // The bytes do not fit in the buffer of the caller: the count of the bytes is the result.
	Absent    = 6, // The export gave the call outcome Nothing_Has_That_Name: the tree has no entry with this name.
}

// The name of each member, as Status names it.
@(rodata)
STATUS_NAMES := [Status]string {
	.Ok        = "Ok",
	.Gone      = "Gone",
	.Refused   = "Refused",
	.Damaged   = "Damaged",
	.Failed    = "Failed",
	.Too_Small = "Too_Small",
	.Absent    = "Absent",
}

// The word of a Status in 8 bytes, for a record that holds it beside
// fields of 8 bytes with no padding (value_kinds.Contract_Enum_Type).
Status_Word :: distinct u64
#assert(size_of(Status_Word) >= size_of(Status))

// commit_refusal_drops_pending says whether a refused commit of the storage
// service drops the pending changes of the connection. A race lost drops
// them: they start from a state that is no longer the last one, and the
// connection sees the last commit at its next read. Each other refusal, a
// damaged state before too, changes nothing, as its outcome says: the
// pending changes stay.
commit_refusal_drops_pending :: proc "contextless" (outcome: call_outcome.Call_Outcome) -> bool {
	return outcome == .Another_Change_Came_First
}
