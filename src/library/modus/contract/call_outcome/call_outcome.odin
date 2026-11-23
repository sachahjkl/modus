// The outcome of a call: how a call of the system ended
// (src/md/api/call_outcome.md).
//
// A call that ends gives three facts:
//
// - The call outcome: one word, a member of Call_Outcome. The code that
//   fails decides it, at the moment of the failure. It says what the caller
//   can do next.
// - The effect group of the outcome: effect_group_of, a total function of
//   the member. It says what the call did to the state. No word carries it.
// - The error record, on a failure only (errors.Error_Record). It says why.
//
// A direct call of an export that can fail gives the outcome first, then
// the value: in `rax` and `rdx` on x86-64. In Odin the export is
// `-> (outcome: call_outcome.Call_Outcome, value: i64)`; in C it returns
// `struct modus_answer { uint64_t outcome; int64_t value; }` by value. The
// value of a call that did not succeed is not read.
//
// A reader that takes the word from another process reads it through
// outcome_of_word, the one border: a word that names no member gives
// Answer_Unreadable, never a member that the word does not name.
//
// See [call outcome](term:call-outcome) and [effect group](term:effect-group).
package call_outcome

import "modus:contract/errors"

// How a call ended. The values are the contract and never move: they cross
// each border of the system in a register or in the kind of a completion.
// A callee runs the tests of Callee_Test in their order and gives the first
// member whose test holds; a border runs the tests of Path_Test.
//
// A new member joins the effect group Nothing_Changed only, and names its
// parent in PARENT_OF (the rule of growth).
Call_Outcome :: enum u64 {
	Succeeded                        = 0, // The call did all its work: use the value and the results.
	Argument_Refused                 = 1, // An argument breaks a rule that the call states for it: fix the argument.
	Nothing_Has_That_Name            = 2, // A name or a number of the call names nothing that exists: create the thing, or name another one.
	Name_Already_Taken               = 3, // The call makes a thing, and its name names a thing that exists: use the thing, or another name.
	Grant_Or_Right_Missing           = 4, // The grant of the caller, or a right of its handle, does not allow the call: get a grant or a handle with the right.
	Callee_Busy                      = 5, // A capacity that the callee shares with other callers is full now, and frees with no act of this caller: call again later.
	Budget_Or_Capacity_Exhausted     = 6, // A budget, a limit or a capacity cannot pay for the call, and frees only when something ends: free something, or ask for more.
	Wrong_State                      = 7, // The object that the call names is in a state where the call does not apply: change the state first.
	Another_Change_Came_First        = 8, // Another change of the object came after the state that the caller read: read again, and do the sequence again.
	Operation_Unsupported            = 9, // The receiver does not have this export, command or operation: use another receiver.
	Data_Damaged                     = 10, // Data that the callee holds failed its check: take an earlier version.
	Callee_Unavailable               = 11, // The call did not run, because a party that it needs failed or did not answer: call again later.
	Stopped_After_A_Partial_Change   = 12, // The callee changed state that the caller can see, then stopped: the documentation of the export states what holds.
	Callee_Stopped_During_The_Call   = 13, // The process that ran the call stopped after it read the command and before it answered.
	Connection_Ended_During_The_Call = 14, // The connection or the link ended after the command left and before the answer came.
	Deadline_Passed_During_The_Call  = 15, // The deadline passed after the command left and before the answer came; the callee can still run the call.
	Answer_Unreadable                = 16, // An answer came, and the reader cannot read it by the contract that it knows: trust nothing of it.
}

// The word of a call outcome as another party wrote it: a writer of a log
// fact copies it with no cast, so a word that names no member is carried as
// it came, and the reader of the fact writes its number.
Call_Outcome_Word :: distinct u64

// What a call did to the state. The four groups never change: no member is
// added, and no outcome moves to another group. A relay, a test, a replay
// and a library that calls again switch on the group, never on the
// outcomes.
Effect_Group :: enum u8 {
	Whole_Work_Done       = 0, // The call did all its work. Its value and its results are valid.
	Nothing_Changed       = 1, // The call changed nothing that the caller can see.
	Partial_Change_Stated = 2, // The call did a part of its work and stopped; the documentation of the export states what holds.
	Change_In_Doubt       = 3, // The call ran in whole, in part or not at all, and nobody can tell the caller which.
}

// The effect group of each outcome. The compiler checks that the table is
// whole.
@(rodata)
EFFECT_GROUP_OF := [Call_Outcome]Effect_Group {
	.Succeeded                        = .Whole_Work_Done,
	.Argument_Refused                 = .Nothing_Changed,
	.Nothing_Has_That_Name            = .Nothing_Changed,
	.Name_Already_Taken               = .Nothing_Changed,
	.Grant_Or_Right_Missing           = .Nothing_Changed,
	.Callee_Busy                      = .Nothing_Changed,
	.Budget_Or_Capacity_Exhausted     = .Nothing_Changed,
	.Wrong_State                      = .Nothing_Changed,
	.Another_Change_Came_First        = .Nothing_Changed,
	.Operation_Unsupported            = .Nothing_Changed,
	.Data_Damaged                     = .Nothing_Changed,
	.Callee_Unavailable               = .Nothing_Changed,
	.Stopped_After_A_Partial_Change   = .Partial_Change_Stated,
	.Callee_Stopped_During_The_Call   = .Change_In_Doubt,
	.Connection_Ended_During_The_Call = .Change_In_Doubt,
	.Deadline_Passed_During_The_Call  = .Change_In_Doubt,
	.Answer_Unreadable                = .Change_In_Doubt,
}

// The member that each member refines (the rule of growth). A border that
// knows that its reader is older gives the parent. A member of the first
// version of the contract is its own parent.
@(rodata)
PARENT_OF := [Call_Outcome]Call_Outcome {
	.Succeeded                        = .Succeeded,
	.Argument_Refused                 = .Argument_Refused,
	.Nothing_Has_That_Name            = .Nothing_Has_That_Name,
	.Name_Already_Taken               = .Name_Already_Taken,
	.Grant_Or_Right_Missing           = .Grant_Or_Right_Missing,
	.Callee_Busy                      = .Callee_Busy,
	.Budget_Or_Capacity_Exhausted     = .Budget_Or_Capacity_Exhausted,
	.Wrong_State                      = .Wrong_State,
	.Another_Change_Came_First        = .Another_Change_Came_First,
	.Operation_Unsupported            = .Operation_Unsupported,
	.Data_Damaged                     = .Data_Damaged,
	.Callee_Unavailable               = .Callee_Unavailable,
	.Stopped_After_A_Partial_Change   = .Stopped_After_A_Partial_Change,
	.Callee_Stopped_During_The_Call   = .Callee_Stopped_During_The_Call,
	.Connection_Ended_During_The_Call = .Connection_Ended_During_The_Call,
	.Deadline_Passed_During_The_Call  = .Deadline_Passed_During_The_Call,
	.Answer_Unreadable                = .Answer_Unreadable,
}

// The members of the first version of the contract. A member that a later
// version adds is not in this set, and its parent is.
FIRST_VERSION_MEMBERS :: bit_set[Call_Outcome; u64]{
	.Succeeded,
	.Argument_Refused,
	.Nothing_Has_That_Name,
	.Name_Already_Taken,
	.Grant_Or_Right_Missing,
	.Callee_Busy,
	.Budget_Or_Capacity_Exhausted,
	.Wrong_State,
	.Another_Change_Came_First,
	.Operation_Unsupported,
	.Data_Damaged,
	.Callee_Unavailable,
	.Stopped_After_A_Partial_Change,
	.Callee_Stopped_During_The_Call,
	.Connection_Ended_During_The_Call,
	.Deadline_Passed_During_The_Call,
	.Answer_Unreadable,
}

// The kinds of the error record that explain each outcome. The kind
// Refused explains each outcome but Succeeded: it is the last resort of a
// callee that has no better kind. A sentence reads the kind; a decision
// reads the outcome.
@(rodata)
KINDS_OF := [Call_Outcome]bit_set[errors.Kind; u64] {
	.Succeeded                        = {.None},
	.Argument_Refused                 = {.Empty, .Too_Long, .Too_Small, .Bad_Value, .Bad_Flags, .Bad_Byte, .Bad_Address, .Handle_Absent, .Handle_Ended, .Handle_Kind, .Malformed, .Overlap, .Out_Of_Range, .Not_Payer, .Whole_Only, .Not_Multiple, .Not_Authentic, .Absent, .Refused},
	.Nothing_Has_That_Name            = {.Absent, .Refused},
	.Name_Already_Taken               = {.Exists, .Refused},
	.Grant_Or_Right_Missing           = {.No_Grant, .Handle_Rights, .Reserved, .Starter_Module, .Refused},
	.Callee_Busy                      = {.Busy, .Full, .Refused},
	.Budget_Or_Capacity_Exhausted     = {.Budget, .Budget_Hidden, .Over_Limit, .Full, .Refused},
	.Wrong_State                      = {.State, .Object_Shared, .Object_Marked, .No_Target, .Seed_Too_Weak, .Refused},
	.Another_Change_Came_First        = {.Absent, .State, .Refused},
	.Operation_Unsupported            = {.Unsupported, .Unknown_Operation, .Refused},
	.Data_Damaged                     = {.Damaged, .Refused},
	.Callee_Unavailable               = {.Device, .Link_Down, .No_Answer, .Callee_Stopped, .Connection_Ended, .Refused},
	.Stopped_After_A_Partial_Change   = {.Empty, .Too_Long, .Too_Small, .Bad_Value, .Bad_Byte, .Absent, .Exists, .Full, .Budget, .Over_Limit, .Damaged, .Device, .No_Answer, .State, .Busy, .Refused},
	.Callee_Stopped_During_The_Call   = {.Callee_Stopped, .Refused},
	.Connection_Ended_During_The_Call = {.Connection_Ended, .Refused},
	.Deadline_Passed_During_The_Call  = {.No_Answer, .Refused},
	.Answer_Unreadable                = {.Bad_Value, .Too_Small, .Out_Of_Range, .Malformed, .Refused},
}

// The tests of a callee, in their order (src/md/api/call_outcome.md, "The
// members"). A callee gives the outcome of the first test that holds:
// first_outcome.
Callee_Test :: enum u8 {
	Changed_State_Then_Stopped = 0, // The callee changed state that the caller can see, then stopped its work. First: a change is never hidden behind a refusal.
	Operation_Absent           = 1, // The receiver does not have this export, command or operation.
	Argument_Breaks_A_Rule     = 2, // An argument breaks a rule that the call states for it.
	Grant_Or_Right_Absent      = 3, // The grant or a right of a handle does not allow the call. Before the names: a caller with no grant learns nothing of a name.
	Name_Names_Nothing         = 4, // A name or a number names nothing that exists.
	Name_Taken                 = 5, // The call makes a thing whose name names a thing that exists.
	Change_Came_First          = 6, // Another change came after the state that the caller read.
	State_Does_Not_Apply       = 7, // The object is in a state where the call does not apply.
	Shared_Capacity_Full       = 8, // A capacity shared with other callers is full now, and frees by itself.
	Own_Capacity_Exhausted     = 9, // A budget, a limit or a capacity of the caller cannot pay for the call.
	Held_Data_Damaged          = 10, // Data that the callee holds failed its check.
	Needed_Party_Failed        = 11, // A party that the call needs failed or did not answer, and the call did not run.
}

// The outcome of each test of a callee.
@(rodata)
OUTCOME_OF_CALLEE_TEST := [Callee_Test]Call_Outcome {
	.Changed_State_Then_Stopped = .Stopped_After_A_Partial_Change,
	.Operation_Absent           = .Operation_Unsupported,
	.Argument_Breaks_A_Rule     = .Argument_Refused,
	.Grant_Or_Right_Absent      = .Grant_Or_Right_Missing,
	.Name_Names_Nothing         = .Nothing_Has_That_Name,
	.Name_Taken                 = .Name_Already_Taken,
	.Change_Came_First          = .Another_Change_Came_First,
	.State_Does_Not_Apply       = .Wrong_State,
	.Shared_Capacity_Full       = .Callee_Busy,
	.Own_Capacity_Exhausted     = .Budget_Or_Capacity_Exhausted,
	.Held_Data_Damaged          = .Data_Damaged,
	.Needed_Party_Failed        = .Callee_Unavailable,
}

// The tests of a border on the path of a call, in their order
// (src/md/api/call_outcome.md, "The failures of the path").
Path_Test :: enum u8 {
	Callee_Stopped_After_It_Read    = 0, // The process that ran the call stopped after it read the command.
	Callee_Stopped_Before_It_Read   = 1, // The process that ran the call stopped before it read the command.
	Connection_Ended_After_It_Left  = 2, // The connection ended after the command left.
	Connection_Ended_Before_It_Left = 3, // The connection ended before the command left.
	Deadline_Passed_After_It_Left   = 4, // The deadline passed after the command left.
	Answer_Not_Readable             = 5, // An answer came that the reader cannot read.
}

// The outcome of each test of a border.
@(rodata)
OUTCOME_OF_PATH_TEST := [Path_Test]Call_Outcome {
	.Callee_Stopped_After_It_Read    = .Callee_Stopped_During_The_Call,
	.Callee_Stopped_Before_It_Read   = .Callee_Unavailable,
	.Connection_Ended_After_It_Left  = .Connection_Ended_During_The_Call,
	.Connection_Ended_Before_It_Left = .Callee_Unavailable,
	.Deadline_Passed_After_It_Left   = .Deadline_Passed_During_The_Call,
	.Answer_Not_Readable             = .Answer_Unreadable,
}

// effect_group_of gives what a call of this outcome did to the state.
effect_group_of :: proc "contextless" (outcome: Call_Outcome) -> Effect_Group {
	return EFFECT_GROUP_OF[outcome]
}

// first_outcome gives the outcome of the first test of a callee that holds,
// in the order of Callee_Test; Succeeded when none holds.
//
// Example: a call with a wrong argument and no grant gives
// Argument_Refused: `first_outcome({.Grant_Or_Right_Absent,
// .Argument_Breaks_A_Rule})`.
first_outcome :: proc "contextless" (holding: bit_set[Callee_Test; u16]) -> Call_Outcome {
	for test in Callee_Test {
		if test in holding {
			return OUTCOME_OF_CALLEE_TEST[test]
		}
	}
	return .Succeeded
}

// first_path_outcome gives the outcome of the first test of a border that
// holds, in the order of Path_Test; ok is false when none holds.
first_path_outcome :: proc "contextless" (holding: bit_set[Path_Test; u8]) -> (outcome: Call_Outcome, ok: bool) {
	for test in Path_Test {
		if test in holding {
			return OUTCOME_OF_PATH_TEST[test], true
		}
	}
	return .Succeeded, false
}

// outcome_passed_on gives the outcome that code gives its own caller after
// a call to its callee ended with `received` (the rule of weakening): it
// never promises more than it received or caused. When the code changed
// state that its caller can see before the call, a refusal becomes
// Stopped_After_A_Partial_Change: the record of the callee then goes in the
// table of error details. A call in doubt stays in doubt.
//
// Example: an export that wrote its own state, then called the storage
// service, which gave Budget_Or_Capacity_Exhausted, gives
// `outcome_passed_on(.Budget_Or_Capacity_Exhausted, changed_before = true)`:
// Stopped_After_A_Partial_Change.
outcome_passed_on :: proc "contextless" (received: Call_Outcome, changed_before: bool) -> Call_Outcome {
	switch effect_group_of(received) {
	case .Whole_Work_Done, .Partial_Change_Stated, .Change_In_Doubt:
		return received
	case .Nothing_Changed:
		return changed_before ? .Stopped_After_A_Partial_Change : received
	}
	return received
}

// outcome_of_word is the one border of an outcome word that a reader takes
// from another party: a completion, an answer, a register of a module that
// the reader did not build with. A word that names a member gives it, and a
// zero record. A word that names no member gives Answer_Unreadable and the
// record Bad_Value with the word as `value` and the last member that this
// reader knows as `limit`: never a member that the word does not name. The
// record says that the answer names an outcome that this reader does not
// know; it does not say that the callee broke its contract.
//
// Example: `outcome_of_word(2)` is `.Nothing_Has_That_Name, {}`;
// `outcome_of_word(17)` is `.Answer_Unreadable, {kind = Bad_Value, value =
// 17, limit = 16}`.
outcome_of_word :: proc "contextless" (word: u64) -> (outcome: Call_Outcome, record: errors.Error_Record) {
	for member in Call_Outcome {
		if u64(member) == word {
			return member, {}
		}
	}
	return .Answer_Unreadable, errors.error_make(.Bad_Value, .None, 0, cast(i64)word, i64(max(Call_Outcome)))
}

// fail writes the error record of a call that failed, and gives the pair of
// an export that can fail: the outcome, and the value 0. error can be nil:
// the caller asked for no record. It is the last line of each failing path
// of an export:
//
// ```odin
// if len(name) == 0 {
// 	return call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, 1, 0, NAME_LIMIT)
// }
// ```
fail :: proc "contextless" (error: ^errors.Error_Record, outcome: Call_Outcome, kind: errors.Kind, unit: errors.Unit = .None, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> (Call_Outcome, i64) {
	if error != nil {
		error^ = errors.error_make(kind, unit, argument, value, limit, found)
	}
	return outcome, 0
}

// fail_with_value_first writes the error record as fail does, and gives
// the order of a procedure of a package that is not an export: the value 0
// first, then the outcome, so that `or_return` passes the outcome on
// (src/md/api/call_outcome.md, "Where the outcome is", "Odin inside a
// module"). `or_return` is sound only before a change: code that changed
// state gives outcome_passed_on(outcome, changed_before = true).
fail_with_value_first :: proc "contextless" (error: ^errors.Error_Record, outcome: Call_Outcome, kind: errors.Kind, unit: errors.Unit = .None, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> (i64, Call_Outcome) {
	if error != nil {
		error^ = errors.error_make(kind, unit, argument, value, limit, found)
	}
	return 0, outcome
}

// The name of each member, as a line of the console and a sentence write
// it.
@(rodata)
CALL_OUTCOME_NAMES := [Call_Outcome]string {
	.Succeeded                        = "Succeeded",
	.Argument_Refused                 = "Argument_Refused",
	.Nothing_Has_That_Name            = "Nothing_Has_That_Name",
	.Name_Already_Taken               = "Name_Already_Taken",
	.Grant_Or_Right_Missing           = "Grant_Or_Right_Missing",
	.Callee_Busy                      = "Callee_Busy",
	.Budget_Or_Capacity_Exhausted     = "Budget_Or_Capacity_Exhausted",
	.Wrong_State                      = "Wrong_State",
	.Another_Change_Came_First        = "Another_Change_Came_First",
	.Operation_Unsupported            = "Operation_Unsupported",
	.Data_Damaged                     = "Data_Damaged",
	.Callee_Unavailable               = "Callee_Unavailable",
	.Stopped_After_A_Partial_Change   = "Stopped_After_A_Partial_Change",
	.Callee_Stopped_During_The_Call   = "Callee_Stopped_During_The_Call",
	.Connection_Ended_During_The_Call = "Connection_Ended_During_The_Call",
	.Deadline_Passed_During_The_Call  = "Deadline_Passed_During_The_Call",
	.Answer_Unreadable                = "Answer_Unreadable",
}

// The name of each effect group.
@(rodata)
EFFECT_GROUP_NAMES := [Effect_Group]string {
	.Whole_Work_Done       = "Whole_Work_Done",
	.Nothing_Changed       = "Nothing_Changed",
	.Partial_Change_Stated = "Partial_Change_Stated",
	.Change_In_Doubt       = "Change_In_Doubt",
}
