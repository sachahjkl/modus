package kernel_events

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of kernel_events (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. A line whose
// sentence differs by its case is one fact type for each case: the template
// has no condition. The Text fields are the last fields: the serial line of
// a fact stops at its last byte that is not zero. A status of the kernel is
// a field of the contract enum, which a reader writes by its name, as the
// line did; a stop cause and a stop outcome write the words of the line.
//
// Lines stay text: the lines with no value; the three lines that write an
// address in 16 hexadecimal digits with no "0x", which no field kind
// writes; the refused start of a child, with the free text of its load
// error; and the line of the cost of the rules, whose fields and template
// pass the bounds of one fact.

// The bytes of the Text field of the name of a child: the longest, "the
// child that faults", has 21 bytes.
CHILD_FIELD_BYTES :: 24
// The bytes of the Text field of the name of an operation: the longest
// name has 17 bytes, and "an unknown operation" 20.
OPERATION_FIELD_BYTES :: 24

// The shared page of a child cannot be made.
@(log_fact = "kernel_events: {child}: memory_create of the shared page failed: {status}")
Shared_Page_Not_Made :: struct {
	status: op.Status,
	child:  [28]u8,
}

// The shared page of a child cannot be mapped.
@(log_fact = "kernel_events: {child}: memory_map of the shared page failed: {status}")
Shared_Page_Not_Mapped :: struct {
	status: op.Status,
	child:  [28]u8,
}

// The budget of this process did not get back the whole budget of a child
// after its end, in the bound of a hang.
@(log_fact = "kernel_events: {child}: the budget of this process did not get back every page, thread and process of the child in {bound}")
Child_Budget_Not_Back :: struct {
	bound: value_kinds.Time_In_Milliseconds,
	child: [24]u8,
}

// The load child stopped itself before the end of a round.
@(log_fact = "kernel_events: the load child stopped: {cause}, {outcome}, before the end of the round {round}")
Load_Child_Stopped :: struct {
	round:   u32,
	cause:   op.Stop_Cause,
	outcome: op.Stop_Outcome,
}

// The load child stopped for another cause than itself before the end of
// a round.
@(log_fact = "kernel_events: the load child stopped: {cause}, before the end of the round {round}")
Load_Child_Stopped_Without_Outcome :: struct {
	round: u32,
	cause: op.Stop_Cause,
}

// The load child did not end a round in the bound of a hang.
@(log_fact = "kernel_events: the load child did not end the round {round} in {bound}")
Round_Not_Ended :: struct {
	round: u64,
	bound: value_kinds.Time_In_Milliseconds,
}

// The kernel refused an event table.
@(log_fact = "kernel_events: Events_Set with {rules} rules and {records} records gave {status}")
Events_Set_Refused :: struct {
	records: u64,
	rules:   u32,
	status:  op.Status,
}

// Case 1: a copy of the machine handle with no right gives no event table.
@(log_fact = "kernel_events: no grant: Events_Set with a copy of the machine handle with no right gave {status}: {verdict}")
No_Grant_Refused :: struct {
	status:  op.Status,
	verdict: [16]u8,
}

// Case 2: 16 rules are taken, and 17 refused.
@(log_fact = "kernel_events: a seventeenth rule: 16 rules {sixteen_rules}, 17 rules {seventeen_rules}: {verdict}")
Seventeenth_Rule_Refused :: struct {
	sixteen_rules:   op.Status,
	seventeen_rules: op.Status,
	verdict:         [16]u8,
}

// Case 3: one record for each operation of the load child.
@(log_fact = "kernel_events: 1000 operations Memory_Size of one process: {records} records, {lost} lost: {verdict}")
Operations_Counted :: struct {
	records: u64,
	lost:    u64,
	verdict: [16]u8,
}

// Case 4: a switch to a thread at the end of each of its sleeps.
@(log_fact = "kernel_events: a thread that sleeps 20 times: {switches} switches to it: {verdict}")
Sleeps_Counted :: struct {
	switches: u64,
	verdict:  [16]u8,
}

// Case 6: a rule that keeps one record in 10.
@(log_fact = "kernel_events: one in 10: {records} records of 1000 operations: {verdict}")
One_In_Ten_Counted :: struct {
	records: u64,
	verdict: [16]u8,
}

// Case 7: a full ring counts the records that it lost.
@(log_fact = "kernel_events: a full ring of 16 records: {written} written, {lost} lost, {total} of 1000: {verdict}")
Full_Ring_Counted :: struct {
	written: u64,
	lost:    u64,
	total:   u64,
	verdict: [16]u8,
}

// Case 8: the table taken away writes no record, and a second take is
// refused.
@(log_fact = "kernel_events: the table taken away: {records_after} records after it; a second take gave {second_take}: {verdict}")
Table_Taken_Away :: struct {
	records_after: u64,
	second_take:   op.Status,
	verdict:       [12]u8,
}

// Case 10: the gives and the ends of a table while the loaders run on
// every processor.
@(log_fact = "kernel_events: 1000 gives and ends under load: {ends} ends with {loaders} loaders, {records} records and {lost} lost in all, the pattern whole after each end: {verdict}")
Ends_Under_Load :: struct {
	ends:    u64,
	loaders: u64,
	records: u64,
	lost:    u64,
	verdict: [16]u8,
}

// Case 12: the revocation of the grant machine ends the table.
@(log_fact = "kernel_events: the right revoked: {records_before} records of {calls} before it; {records_after} records after it; Events_Set after it gave {status}: {verdict}")
Right_Revoked :: struct {
	records_before: u64,
	calls:          u64,
	records_after:  u64,
	status:         op.Status,
	verdict:        [12]u8,
}

// The thread that empties the rings during a measure did not start.
@(log_fact = "kernel_events: the thread that empties the rings did not start: {status}")
Drainer_Not_Started :: struct {
	status: op.Status,
}

// What every process did in 200 ms: shown, not checked.
@(log_fact = "kernel_events: in 200 ms while this process sleeps, every process: {operations} operations, the longest {operation} in {longest}; {lock_waits} waits for a lock (shown, not checked)")
Every_Process_Shown :: struct {
	operations: u64,
	longest:    value_kinds.Time_In_Nanoseconds,
	lock_waits: u64,
	operation:  [24]u8,
}

// The load child cannot make its memory object.
@(log_fact = "kernel_events: the load child could not make its memory object: {status}")
Load_Memory_Not_Made :: struct {
	status: op.Status,
}

// The load child read a word of the shared page that names no round.
@(log_fact = "kernel_events: the load child got the round {round_word}, which names no round: it stops")
Round_Word_Unknown :: struct {
	round_word: u64,
}

// A child came past the instruction that must fault.
@(log_fact = "kernel_events: the child of the role {role} came past its fault")
Child_Past_Its_Fault :: struct {
	role: u64,
}

// The context names no role of this module.
@(log_fact = "kernel_events: the context names the role {role}, which names no role")
Role_Word_Unknown :: struct {
	role: u64,
}

// The memory object of the rings cannot be made.
@(log_fact = "kernel_events: memory_create of the rings failed: {status}")
Rings_Not_Made :: struct {
	status: op.Status,
}

// The memory object of the rings cannot be mapped.
@(log_fact = "kernel_events: memory_map of the rings failed: {status}")
Rings_Not_Mapped :: struct {
	status: op.Status,
}

// Case 11: the child that faults keeps its first stop cause after a stop
// by this process.
@(log_fact = "kernel_events: the child that faults, stopped again by this process: its stop cause stays {cause}: as it must")
Fault_Cause_Kept :: struct {
	cause: op.Stop_Cause,
}

// Case 11 fails: the stop cause of the child that faults is not a fault.
@(log_fact = "kernel_events: the child that faults, stopped again by this process: its stop cause stays {cause}, not a fault: WRONG")
Fault_Cause_Changed :: struct {
	cause: op.Stop_Cause,
}

// Each case passed.
@(log_fact = "kernel_events: ok, {cases} cases: each count of the rings was exact, each refusal came, and each child gave back every page and every thread")
Cases_Passed :: struct {
	cases: u64,
}

// Some cases failed.
@(log_fact = "kernel_events: failed: {failed} cases of {cases}")
Cases_Failed :: struct {
	failed: u64,
	cases:  u64,
}

// Beside a status of 4 bytes, the name of a child takes 28 bytes, so that
// the record ends on 8 bytes with no padding.
#assert(size_of(Shared_Page_Not_Made) == 32 && size_of(Shared_Page_Not_Mapped) == 32)
#assert(size_of(Child_Budget_Not_Back) == 8 + CHILD_FIELD_BYTES)
#assert(size_of(Every_Process_Shown) == 24 + OPERATION_FIELD_BYTES)
#assert(size_of(Load_Child_Stopped) == 12 && size_of(Load_Child_Stopped_Without_Outcome) == 8)
#assert(size_of(Events_Set_Refused) == 16 && size_of(Table_Taken_Away) == 24 && size_of(Right_Revoked) == 40)

// verdict_field gives the Text field of the verdict of a case in the words
// of the line: "as it must" or "WRONG".
verdict_field :: proc "contextless" ($N: int, right: bool) -> [N]u8 {
	return value_kinds.text_field(right ? "as it must" : "WRONG", N)
}

// child_field gives the Text field of the name of a child.
child_field :: proc "contextless" ($N: int, name: string) -> [N]u8 {
	return value_kinds.text_field(name, N)
}
