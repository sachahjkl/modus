// What an isolated call gives besides its integer result: the status of a
// call of an export through the support library (`system.call_isolated`,
// `system.call_direct`). A process writes it in a log fact, which a reader
// of another process renders, so it is a contract: each reader compiles
// its names in (value_kinds.Contract_Enum).
package call_status

// What an isolated call gives besides its integer result. The values cross
// the log in a fact: each value is explicit.
Call_Status :: enum u32 {
	Ok           = 0, // The export ran and did not fail: the integer result is not negative.
	Lend_Failed  = 1, // A handle of the arguments could not be lent: `lend` says why.
	No_Room      = 2, // The arguments do not fit in the call region: isolated.room_missing says which table.
	Ring_Full    = 3, // The call ring had no room for the command.
	Stopped      = 4, // The other process stopped during the call.
	Refused      = 5, // The other process gave a status that is not Ok: Bad_Export, Bad_Arguments, Bad_Handle. The error record has its refusal.
	Wrong_Answer = 6, // The other process gave a count of a table that is smaller than the count on entry. The error record names the parameter.
	Failed       = 7, // The export failed: its integer result is negative, and the error record is filled.
	Not_Done     = 8, // call_direct does not do this description: a result that is not an Integer, a record of a table that is not valid. The error record says which.
	// The export failed, and the error record is its own; but its table of
	// error details came back wrong (a count smaller than on entry, or a
	// table outside the call region): the table of the caller keeps its
	// count from before the call. The reason of the failure stays in the
	// record; the status says that the details are missing.
	Failed_With_Wrong_Details = 9,
	// The deadline that the caller gave passed during the call, before the
	// answer: the export can still run, so the caller ends the other
	// process or waits again.
	Deadline_Passed = 10,
}

// The name of each member, as Call_Status names it.
@(rodata)
CALL_STATUS_NAMES := [Call_Status]string {
	.Ok                        = "Ok",
	.Lend_Failed               = "Lend_Failed",
	.No_Room                   = "No_Room",
	.Ring_Full                 = "Ring_Full",
	.Stopped                   = "Stopped",
	.Refused                   = "Refused",
	.Wrong_Answer              = "Wrong_Answer",
	.Failed                    = "Failed",
	.Not_Done                  = "Not_Done",
	.Failed_With_Wrong_Details = "Failed_With_Wrong_Details",
	.Deadline_Passed           = "Deadline_Passed",
}

// The word of a Call_Status in 8 bytes, for a record that holds it beside
// fields of 8 bytes with no padding (value_kinds.Contract_Enum_Type).
Call_Status_Word :: distinct u64
#assert(size_of(Call_Status_Word) >= size_of(Call_Status))
