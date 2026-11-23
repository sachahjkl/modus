// The decision of the root service on a Replace: the refusals that the state
// gives, in the order of the tests of a callee (call_outcome.Callee_Test),
// as a pure part that the host tests and that the fuzz target of the root
// ring takes as its oracle (docs/MODULE_CONTRACT.md, "Who may replace a
// module").
package replacement_rules

import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/replacement_list"
import "modus:contract/root_ring"
import "internal:root/replacement_signature"

// The facts of a Replace, as the root service reads them before it changes
// the replacement table.
Replace_Facts :: struct {
	granted:         bool, // The sender holds the start grant Replace.
	by:              u64, // The entry of the boot image that replaces, from 1; 0 removes the record.
	entry_count:     u64, // The entries of the boot image.
	name_in_image:   bool, // A module of the boot image has the name.
	replaces_itself: bool, // The entry by is the module of the name.
	chained:         bool, // A record of the table replaces the entry by, or is replaced by the module of the name: a loader would follow two records.
	decision:        replacement_signature.Decision, // The decision on the signature of the pair. Read only when by is not 0.
	problem:         replacement_list.List_Problem, // With the decision List_Not_Valid: the problem of the list.
}

// replace_refusal decides a Replace by its facts, and gives the outcome and
// the error record of a refusal, or Succeeded. A removal (by 0) needs no
// row: it gives back the module that the importer names. In order:
// - a sender with no grant Replace: the refusal of the sender, before any
//   other test, so it learns nothing of the table;
// - an entry past the boot image, or a module that replaces itself:
//   Argument_Refused;
// - a name of no module, or a pair that no signed row names:
//   Nothing_Has_That_Name;
// - a chain, one replacement after another: Wrong_State;
// - a list that breaks its format, or a row whose signature does not
//   verify: Data_Damaged, as the list is data of the system that the
//   boot image holds. found holds the List_Problem, 0 for a signature.
// by_signature says that the decision on the signature refused it.
replace_refusal :: proc "contextless" (facts: Replace_Facts) -> (outcome: call_outcome.Call_Outcome, refusal: [7]u64, by_signature: bool) {
	kind := u32(root_ring.Root_Command.Replace)
	if !facts.granted {
		return .Grant_Or_Right_Missing, root_ring.sender_refusal(.Replace), false
	}
	if facts.by > facts.entry_count {
		return .Argument_Refused, errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(facts.by, 1 << 62)), i64(min(facts.entry_count, 1 << 62))), false
	}
	replacing := facts.by != 0
	if replacing && facts.replaces_itself {
		return .Argument_Refused, errors.ring_fail(kind, .Bad_Value, .None, 2, i64(facts.by)), false
	}
	if !facts.name_in_image {
		return .Nothing_Has_That_Name, errors.ring_fail(kind, .Absent, .Modules, 1), false
	}
	if !replacing {
		return .Succeeded, {}, false
	}
	switch facts.decision {
	case .Accepted, .Not_Authentic, .List_Not_Valid:
	case .No_Row, .No_List:
		return .Nothing_Has_That_Name, errors.ring_fail(kind, .Absent, .Records, 2, i64(facts.by)), true
	}
	if facts.chained {
		return .Wrong_State, errors.ring_fail(kind, .State, .Records, 2, i64(facts.by)), false
	}
	switch facts.decision {
	case .Accepted, .No_Row, .No_List:
	case .Not_Authentic:
		return .Data_Damaged, errors.ring_fail(kind, .Damaged, .Records, 2, i64(facts.by)), true
	case .List_Not_Valid:
		return .Data_Damaged, errors.ring_fail(kind, .Damaged, .Records, 2, i64(facts.by), 0, i64(facts.problem)), true
	}
	return .Succeeded, {}, false
}

// table_full_refusal is the refusal of a Replace whose pair the table has no
// room for: the replacement table of the machine is full until a holder of
// the grant Replace removes a record, so its room does not free by itself.
table_full_refusal :: proc "contextless" (capacity: i64) -> (outcome: call_outcome.Call_Outcome, refusal: [7]u64) {
	return .Budget_Or_Capacity_Exhausted, errors.ring_fail(u32(root_ring.Root_Command.Replace), .Full, .Records, 0, 0, capacity)
}
