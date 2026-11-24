package fuzz

import "core:mem"
import "core:slice"
import "../foundation"
import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/replacement_list"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/start_grant"
import "internal:root/replacement_rules"
import "internal:root/replacement_signature"

// The fuzz target of the root ring (src/md/infrastructure/fuzzing.md, "The
// targets, in order of value"): the decision of the dispatch of the root
// service, which a hostile process feeds with each record of its root
// ring, and the pure borders and refusal records behind it. Each case of
// an input is one record with the start grant set of its sender: the target gives it
// to root_ring.dispatch_decide, to the border of each word of the
// commands and to the decision of a Replace, and checks each refusal with
// its call outcome, a model of the table of the senders and of the order of
// the refusals of a Replace, and that nothing changed.

// One case of an input: a record and its sender, as the fuzz input gives
// them.
Fuzz_Root_Ring_Case :: struct {
	record: ring.Record,
	start_grant_set:   u64, // Bit n: the start grant n. A bit past the grants names none.
	added:  u64, // Grants added to the start grant set: a command that runs still runs.
	flags:  u64, // FUZZ_ROOT_RING_SERVICE_LISTED and the facts of a Replace.
	entries: u64, // The entries of the boot image, for a Replace by values[4].
}

// The bits of Fuzz_Root_Ring_Case.flags: flags, not choices. The decision
// on the signature of a Replace is values[5], and the problem of its list
// values[6], each taken modulo its count of members: a choice of the
// harness, not a border of the system.
FUZZ_ROOT_RING_SERVICE_LISTED :: 1 // The list of the start grant set names the service of the record.
FUZZ_ROOT_RING_NAME_IN_IMAGE :: 2 // A Replace names a module of the image.
FUZZ_ROOT_RING_REPLACES_ITSELF :: 4 // The entry of a Replace is the module of its name.
FUZZ_ROOT_RING_CHAINED :: 8 // The table holds a record that a Replace would chain to.
FUZZ_ROOT_RING_TABLE_FULL :: 16 // The replacement table has no room; values[3] / 2 is its capacity.

FUZZ_ROOT_RING_CASE_LIMIT :: 16
FUZZ_ROOT_RING_INPUT_LIMIT :: FUZZ_ROOT_RING_CASE_LIMIT * size_of(Fuzz_Root_Ring_Case)

// The tables of the contract as they were at the start of the process: an
// execution must leave them as they are.
@(private = "file")
fuzz_root_ring_senders_before: [root_ring.Root_Command]root_ring.Root_Command_Sender

fuzz_root_ring_start :: proc() -> bool {
	fuzz_root_ring_senders_before = root_ring.ROOT_COMMAND_SENDERS
	return true
}

// fuzz_root_ring_execute reads the input as cases, and checks each one.
fuzz_root_ring_execute :: proc(input: []u8) -> Fuzz_Verdict {
	before := slice.clone(input, context.temp_allocator)
	count := min((len(input) + size_of(Fuzz_Root_Ring_Case) - 1) / size_of(Fuzz_Root_Ring_Case), FUZZ_ROOT_RING_CASE_LIMIT)
	for index in 0 ..< count {
		case_of: Fuzz_Root_Ring_Case
		copy(mem.ptr_to_bytes(&case_of), input[index * size_of(Fuzz_Root_Ring_Case):])
		verdict := fuzz_root_ring_case_check(case_of)
		if verdict.oracle != .None {
			return verdict
		}
	}
	if !slice.equal(before, input) {
		return fuzz_broken(.Contract, "the decision of the root ring changed the bytes of its input")
	}
	if root_ring.ROOT_COMMAND_SENDERS != fuzz_root_ring_senders_before {
		return fuzz_broken(.Contract, "the decision of the root ring changed a table of the contract")
	}
	return FUZZ_PASSED
}

// fuzz_root_ring_start_grant_set_of gives the start grants that the bits of a word
// name. It is the choice of the harness, not a border of the system: a bit
// that names no grant is dropped.
@(private = "file")
fuzz_root_ring_start_grant_set_of :: proc(word: u64) -> (start_grant_set: bit_set[start_grant.Grant]) {
	for grant in start_grant.Grant {
		if word >> u64(grant) & 1 != 0 {
			start_grant_set += {grant}
		}
	}
	return start_grant_set
}

// fuzz_root_ring_sender_model says who sends a command, written by hand
// from the guides and not from the table of the contract, so a wrong row
// of ROOT_COMMAND_SENDERS breaks the oracle:
// - a process receives a root ring only with Root_Ring, Connect,
//   Principals, Debugger, Start_Policy, Plans or Screen_Capture
//   (src/md/api/root_ring.md, "The chosen form");
// - `unlock`, with Principals, alone sends Principal_Record,
//   Principal_Unlock, Machine_Key and Principal_Change_End
//   (docs/PRINCIPALS.md, "7. The commands");
// - the debugger service, with Debugger, alone sends Debug and Debug_Store
//   (docs/TOOLS.md, "The debugger");
// - Connect comes from Root_Ring, or from Connect to a service of the list
//   of its start grant set; Disconnect from each ring, for a connection that it holds;
// - Ready from nobody: it travels on the ready ring of each process, never
//   on the root ring (src/md/features/module_budget_request.md, "The first
//   state of work");
// - the start policy, with Start_Policy, sends Start and Stop as the
//   console does, and alone sends Machine_Usable
//   (src/md/features/start_policy.md);
// - unlock, with Principals, alone sends Wide_Grant_Proof too
//   (src/md/features/wide_grants.md, "The path of a grant, end to end");
// - remote, with Remote_Clients and a ring, alone sends Wide_Grant_Agent_Ask
//   and Wide_Grant_Second_Connection (src/md/features/wide_grants.md, "The
//   ask of an agent");
// - the holder of the role Plans, with Plans, alone sends Plan_Roles
//   (src/md/features/declarations.md, "The apply as built");
// - the service of the remote display, with Screen_Capture, alone sends
//   Screen_Budget (src/md/features/screen_of_memory.md, "The growth of the
//   budgets");
// - each other command from Root_Ring, the console; None from nobody.
// The switch is whole: a new command does not compile until its sender is
// written here too.
@(private = "file")
fuzz_root_ring_sender_model :: proc(command: root_ring.Root_Command, start_grant_set: bit_set[start_grant.Grant], listed: bool) -> bool {
	if start_grant_set & {.Root_Ring, .Connect, .Principals, .Debugger, .Start_Policy, .Plans, .Screen_Capture, .Grants_Manage} == {} {
		return false
	}
	switch command {
	case .None, .Ready:
		return false
	case .Principal_Record, .Principal_Identifier, .Principal_Storage_Key, .Principal_Unlock, .Machine_Key, .Principal_Change_End, .Wide_Grant_Proof:
		return .Principals in start_grant_set
	case .Debug, .Debug_Store, .Debug_Start:
		return .Debugger in start_grant_set
	case .Connect:
		return .Root_Ring in start_grant_set || .Connect in start_grant_set && listed
	case .Disconnect, .Budget_Grow:
		return true
	case .Machine_Usable:
		return .Start_Policy in start_grant_set
	case .Plan_Roles, .Plan_Values:
		return .Plans in start_grant_set
	case .Screen_Budget:
		return .Screen_Capture in start_grant_set
	case .Wide_Grant_Agent_Ask, .Wide_Grant_Second_Connection:
		return .Remote_Clients in start_grant_set
	case .Start, .Stop, .Wire:
		return .Root_Ring in start_grant_set || .Start_Policy in start_grant_set
	case .Grants, .Revoke, .Disk_Grant, .Wide_Grant_End, .Grants_Read:
		return .Root_Ring in start_grant_set || .Grants_Manage in start_grant_set
	case .Replace, .Connect_History, .Principal_Create, .Principal_Lock, .Principals, .Palette_Provide, .Start_From_Disk, .Nickname_Move, .Machine_Passphrase, .Disk_Grant_Persistence, .Machine_Seal, .Principal_Change, .Remote_Client, .Start_Policy_Choice, .Start_Edit, .Wide_Grant_Ask:
		return .Root_Ring in start_grant_set
	}
	return false
}

@(private = "file")
fuzz_root_ring_case_check :: proc(case_of: Fuzz_Root_Ring_Case) -> Fuzz_Verdict {
	record := case_of.record
	start_grant_set := fuzz_root_ring_start_grant_set_of(case_of.start_grant_set)
	listed := case_of.flags & FUZZ_ROOT_RING_SERVICE_LISTED != 0
	decision := root_ring.dispatch_decide(record.kind, start_grant_set, listed)
	if again := root_ring.dispatch_decide(record.kind, start_grant_set, listed); again != decision {
		return fuzz_broken(.Contract, "two decisions of the kind %d with one start grant set differ", record.kind)
	}
	// The border.
	command, known := root_ring.command_of_word(record.kind)
	if !known {
		if decision.step != .Border || decision.command != .None || decision.outcome != .Operation_Unsupported || decision.refusal != root_ring.command_refusal(record.kind) {
			return fuzz_broken(.Contract, "the word %d names no command, and the decision is %v", record.kind, decision)
		}
		refusal := errors.completion_record(decision.refusal)
		if refusal.kind != i64(errors.Kind.Unsupported) || refusal.value != i64(record.kind) || refusal.operation != i64(record.kind) || !fuzz_error_record_named(refusal) {
			return fuzz_broken(.Contract, "the refusal of the word %d is %v", record.kind, refusal)
		}
		return fuzz_root_ring_round_trip(decision.refusal)
	}
	if decision.step == .Border || decision.command != command {
		return fuzz_broken(.Contract, "the word %d names %v, and the decision is %v", record.kind, command, decision)
	}
	// The sender, against the model of the table.
	allowed := fuzz_root_ring_sender_model(command, start_grant_set, listed)
	switch decision.step {
	case .Border:
	case .Sender:
		if allowed {
			return fuzz_broken(.Model, "the model sends %v from %v, and the dispatch refuses it", command, start_grant_set)
		}
		refusal := errors.completion_record(decision.refusal)
		unit := command == .Connect ? errors.Unit.Connection : errors.Unit.Root_Commands
		if decision.outcome != .Grant_Or_Right_Missing || refusal.kind != i64(errors.Kind.No_Grant) || refusal.unit != i64(unit) || refusal.operation != i64(command) || !fuzz_error_record_named(refusal) {
			return fuzz_broken(.Contract, "the refusal of the sender of %v is %v with %v", command, refusal, decision.outcome)
		}
		if verdict := fuzz_root_ring_round_trip(decision.refusal); verdict.oracle != .None {
			return verdict
		}
	case .Command:
		if !allowed {
			return fuzz_broken(.Model, "the model refuses %v from %v, and the dispatch runs it", command, start_grant_set)
		}
		if start_grant_set & root_ring.ROOT_RING_GRANTS == {} {
			return fuzz_broken(.Contract, "a start grant set with no root ring runs %v", command)
		}
		if decision.outcome != .Succeeded || decision.refusal != ([7]u64{}) {
			return fuzz_broken(.Contract, "the command %v runs with %v and a record", command, decision.outcome)
		}
		// More grants never refuse a command that runs.
		wider := root_ring.dispatch_decide(record.kind, start_grant_set + fuzz_root_ring_start_grant_set_of(case_of.added), listed)
		if wider.step != .Command {
			return fuzz_broken(.Contract, "%v runs from %v and not from more grants", command, start_grant_set)
		}
	}
	if verdict := fuzz_root_ring_replace_check(case_of, start_grant_set); verdict.oracle != .None {
		return verdict
	}
	return fuzz_root_ring_words_check(record)
}

// The record that the model waits for of a Replace, field by field.
@(private = "file")
Fuzz_Replace_Expected :: struct {
	outcome:  call_outcome.Call_Outcome,
	kind:     errors.Kind,
	unit:     errors.Unit,
	argument: i64,
	value:    i64,
	limit:    i64,
	found:    i64,
}

// fuzz_root_ring_replace_model gives the outcome and the record of a
// Replace, written by hand from docs/MODULE_CONTRACT.md, "Who may replace
// a module", from the fields that root_ring.Replace_Refusal names, and from
// the order of the tests of a callee (src/md/api/call_outcome.md): the
// grant; the arguments; the names; the state; the data of the system. A
// removal (by 0) reads no row and no chain. A Replace that the facts allow
// into a full table gives the record of the table.
@(private = "file")
fuzz_root_ring_replace_model :: proc(facts: replacement_rules.Replace_Facts, table_full: bool, capacity: i64) -> Fuzz_Replace_Expected {
	replacing := facts.by != 0
	no_row := facts.decision == .No_Row || facts.decision == .No_List
	by := i64(min(facts.by, 1 << 62))
	switch {
	case !facts.granted:
		return {.Grant_Or_Right_Missing, .No_Grant, .Root_Commands, 0, 0, 0, 0}
	case facts.by > facts.entry_count:
		return {.Argument_Refused, .Bad_Value, .None, 2, by, i64(min(facts.entry_count, 1 << 62)), 0}
	case replacing && facts.replaces_itself:
		return {.Argument_Refused, .Bad_Value, .Modules, 2, by, 0, 0}
	case !facts.name_in_image:
		return {.Nothing_Has_That_Name, .Absent, .Modules, 1, 0, 0, 0}
	case replacing && no_row:
		return {.Nothing_Has_That_Name, .Absent, .Records, 2, by, 0, 0}
	case replacing && facts.chained:
		return {.Wrong_State, .State, .Records, 2, by, 0, 0}
	case replacing && facts.decision == .Not_Authentic:
		return {.Data_Damaged, .Damaged, .Records, 2, by, 0, 0}
	case replacing && facts.decision == .List_Not_Valid:
		return {.Data_Damaged, .Damaged, .Records, 2, by, 0, i64(facts.problem)}
	case table_full:
		return {.Budget_Or_Capacity_Exhausted, .Full, .Records, 0, 0, capacity, 0}
	}
	return {outcome = .Succeeded}
}

// fuzz_root_ring_replace_check: the decision of a Replace from the facts of
// the case, and the refusal of a full table when the case names one, is
// the record of the model field by field, which names the command, whose
// kind explains the outcome, whose reason the reader of the contract reads
// back, and which is the same twice.
@(private = "file")
fuzz_root_ring_replace_check :: proc(case_of: Fuzz_Root_Ring_Case, start_grant_set: bit_set[start_grant.Grant]) -> Fuzz_Verdict {
	values := case_of.record.values
	facts := replacement_rules.Replace_Facts {
		granted         = .Replace in start_grant_set,
		by              = values[4],
		entry_count     = case_of.entries,
		name_in_image   = case_of.flags & FUZZ_ROOT_RING_NAME_IN_IMAGE != 0,
		replaces_itself = case_of.flags & FUZZ_ROOT_RING_REPLACES_ITSELF != 0,
		chained         = case_of.flags & FUZZ_ROOT_RING_CHAINED != 0,
		decision        = foundation.enum_member_at(replacement_signature.Decision, int(values[5] % u64(len(replacement_signature.Decision)))),
		problem         = foundation.enum_member_at(replacement_list.List_Problem, int(values[6] % u64(len(replacement_list.List_Problem)))),
	}
	table_full := case_of.flags & FUZZ_ROOT_RING_TABLE_FULL != 0
	capacity := i64(values[3] >> 1)
	outcome, refusal, _ := replacement_rules.replace_refusal(facts)
	again, refusal_again, _ := replacement_rules.replace_refusal(facts)
	if again != outcome || refusal_again != refusal {
		return fuzz_broken(.Contract, "two decisions of one Replace differ")
	}
	if outcome == .Succeeded && table_full {
		outcome, refusal = replacement_rules.table_full_refusal(capacity)
	}
	wanted := fuzz_root_ring_replace_model(facts, table_full, capacity)
	read := errors.completion_record(refusal)
	if outcome != wanted.outcome {
		return fuzz_broken(.Model, "the Replace of %v gives %v with %v, and the model %v", facts, outcome, read, wanted)
	}
	if outcome == .Succeeded {
		if refusal != ([7]u64{}) {
			return fuzz_broken(.Contract, "a Replace that runs writes the record %v", read)
		}
		return FUZZ_PASSED
	}
	if read.kind != i64(wanted.kind) || read.unit != i64(wanted.unit) || read.argument != wanted.argument || read.value != wanted.value || read.limit != wanted.limit || read.found != wanted.found {
		return fuzz_broken(.Model, "the record of the Replace of %v is %v, and the model %v", facts, read, wanted)
	}
	kind, kind_ok := errors.kind_of_word(read.kind)
	if read.operation != i64(root_ring.Root_Command.Replace) || !fuzz_error_record_named(read) || !kind_ok || kind not_in call_outcome.KINDS_OF[outcome] {
		return fuzz_broken(.Contract, "the record of a refused Replace is %v with %v", read, outcome)
	}
	if _, _, known := root_ring.replace_refusal_of_record(outcome, read); !known {
		return fuzz_broken(.Contract, "the reader of the contract reads no reason in the record %v of a Replace", read)
	}
	return fuzz_root_ring_round_trip(refusal)
}

// fuzz_root_ring_round_trip: an error record reads back to its words.
@(private = "file")
fuzz_root_ring_round_trip :: proc(values: [7]u64) -> Fuzz_Verdict {
	if errors.completion_values(errors.completion_record(values)) != values {
		return fuzz_broken(.Round_Trip, "completion_values of completion_record gives other words")
	}
	return FUZZ_PASSED
}

// fuzz_root_ring_word_check: a word of a command at its place is its
// member, or the refusal Bad_Value of its argument with the word and the
// largest member, and no member.
@(private = "file")
fuzz_root_ring_word_check :: proc($Enum: typeid, word: u64, command: root_ring.Root_Command, argument: i64) -> Fuzz_Verdict {
	member, status, refusal := root_ring.member_of_word(Enum, word, command, argument)
	expected, named := enum_word.member_of_word(Enum, word)
	if named {
		if status != .Succeeded || member != expected || u64(member) != word || refusal != ([7]u64{}) {
			return fuzz_broken(.Contract, "member_of_word gives %v and %v for the word %d", member, status, word)
		}
		return FUZZ_PASSED
	}
	zero: Enum
	read := errors.completion_record(refusal)
	if status != .Argument_Refused || member != zero || read.kind != i64(errors.Kind.Bad_Value) || read.operation != i64(command) || read.argument != argument || read.value != i64(min(word, 1 << 62)) || read.limit != i64(max(Enum)) || !fuzz_error_record_named(read) {
		return fuzz_broken(.Contract, "the refusal of the word %d of %v is %v with %v", word, command, read, status)
	}
	return fuzz_root_ring_round_trip(refusal)
}

// fuzz_root_ring_words_check gives each word of the record to the border
// of each enumeration that a command reads at that place, as the root
// service calls it.
@(private = "file")
fuzz_root_ring_words_check :: proc(record: ring.Record) -> Fuzz_Verdict {
	verdicts := [?]Fuzz_Verdict {
		fuzz_root_ring_word_check(root_ring.Remote_Client_Action, record.values[4], .Remote_Client, 2),
		fuzz_root_ring_word_check(root_ring.Disk_Grant_Action, record.values[4], .Disk_Grant, 0),
		fuzz_root_ring_word_check(root_ring.Principal_Change, record.values[4], .Principal_Change, 2),
		fuzz_root_ring_word_check(root_ring.Principal_Key_Origin, record.values[5], .Principal_Unlock, 0),
		fuzz_root_ring_word_check(root_ring.Machine_Key_Form, record.values[5], .Machine_Key, 2),
		fuzz_root_ring_word_check(root_ring.Remote_Client_State, record.values[6], .Remote_Client, 2),
	}
	for verdict in verdicts {
		if verdict.oracle != .None {
			return verdict
		}
	}
	report, report_status := root_ring.machine_key_report_of_values(record.values)
	if report_status == .Succeeded {
		if u64(report.state) != record.values[4] || report.state == .Awaited && u64(report.form) != record.values[5] {
			return fuzz_broken(.Contract, "machine_key_report_of_values gives a report that the words do not name")
		}
	} else if report_status != .Argument_Refused || report != (root_ring.Machine_Key_Report{}) {
		return fuzz_broken(.Contract, "machine_key_report_of_values refuses with %v and a report", report_status)
	}
	return FUZZ_PASSED
}

// fuzz_root_ring_seeds: each command from each single grant of a ring and
// from none, with the edges of each word: 0, 1, the largest member and one
// past it, 2^62 and one past it, the largest word; then the kinds that
// name no command.
fuzz_root_ring_seeds :: proc(seeds: ^[dynamic][]u8) {
	edges := [?]u64{0, 1, u64(max(root_ring.Remote_Client_Action)), u64(max(root_ring.Remote_Client_Action)) + 1, 1 << 62, 1 << 62 + 1, max(u64)}
	cases := make([dynamic]Fuzz_Root_Ring_Case, context.temp_allocator)
	start_grant_sets := make([dynamic]u64, context.temp_allocator)
	append(&start_grant_sets, 0, max(u64))
	for grant in root_ring.ROOT_RING_GRANTS {
		append(&start_grant_sets, u64(1) << u64(grant))
	}
	for command in root_ring.Root_Command {
		for start_grant_set, index in start_grant_sets {
			edge := edges[index % len(edges)]
			append(&cases, Fuzz_Root_Ring_Case{record = {kind = u32(command), values = {0, 0, 0, 0, edge, edge, edge}}, start_grant_set = start_grant_set, added = max(u64), flags = u64(index) & 1})
		}
	}
	// Each fact of a Replace alone, with each decision on its signature,
	// at the edges of its entry: 0, 1, the last, one past it.
	replace_grants := u64(1) << u64(start_grant.Grant.Root_Ring) | u64(1) << u64(start_grant.Grant.Replace)
	for flags in ([?]u64{FUZZ_ROOT_RING_NAME_IN_IMAGE, 0, FUZZ_ROOT_RING_NAME_IN_IMAGE | FUZZ_ROOT_RING_REPLACES_ITSELF, FUZZ_ROOT_RING_NAME_IN_IMAGE | FUZZ_ROOT_RING_CHAINED, FUZZ_ROOT_RING_NAME_IN_IMAGE | FUZZ_ROOT_RING_TABLE_FULL}) {
		for decision in replacement_signature.Decision {
			for by in ([?]u64{0, 1, 12, 13, max(u64)}) {
				append(&cases, Fuzz_Root_Ring_Case{record = {kind = u32(root_ring.Root_Command.Replace), values = {3 = 128, 4 = by, 5 = u64(decision), 6 = 2}}, start_grant_set = replace_grants, flags = flags, entries = 12})
			}
		}
	}
	// A full table of capacity 0 and of the largest capacity, and an image
	// of no entry.
	for capacity_word in ([?]u64{0, max(u64)}) {
		append(&cases, Fuzz_Root_Ring_Case{record = {kind = u32(root_ring.Root_Command.Replace), values = {3 = capacity_word, 4 = 1}}, start_grant_set = replace_grants, flags = FUZZ_ROOT_RING_NAME_IN_IMAGE | FUZZ_ROOT_RING_TABLE_FULL, entries = 12})
	}
	append(&cases, Fuzz_Root_Ring_Case{record = {kind = u32(root_ring.Root_Command.Replace), values = {4 = 1}}, start_grant_set = replace_grants, flags = FUZZ_ROOT_RING_NAME_IN_IMAGE, entries = 0})
	for kind in ([?]u32{u32(max(root_ring.Root_Command)) + 1, 1 << 16, max(u32)}) {
		append(&cases, Fuzz_Root_Ring_Case{record = {kind = kind, values = {max(u64), max(u64), max(u64), max(u64), max(u64), max(u64), max(u64)}}, start_grant_set = max(u64)})
	}
	for &item in cases {
		append(seeds, slice.clone(mem.ptr_to_bytes(&item)))
	}
	whole := make([dynamic]u8)
	for &item in cases[:min(len(cases), FUZZ_ROOT_RING_CASE_LIMIT)] {
		append(&whole, ..mem.ptr_to_bytes(&item))
	}
	append(seeds, whole[:])
}

// fuzz_root_ring_regions: each case of an input, for the field mutator.
fuzz_root_ring_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	count := min(len(input) / size_of(Fuzz_Root_Ring_Case), FUZZ_ROOT_RING_CASE_LIMIT)
	if count > 0 {
		append(regions, Fuzz_Region{offset = 0, type = Fuzz_Root_Ring_Case, count = count})
	}
}
