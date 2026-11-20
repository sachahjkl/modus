package scheduler

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of scheduler (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero. A status of the kernel is a field of the contract
// enum, which a reader writes by its name, as the line did.
//
// Lines stay text:
// - the line of each strategy, the measured line of the measure record,
//   and the line of the written weights: they write shares in tenths of a
//   percent with one decimal, which no field kind writes;
// - the lines whose template passes the 256 bytes of a template: the
//   stress, the own schedule of a thread, the refused writes of a
//   schedule, the weight limit, the owing rounds, most cases of the
//   placement and of the share policy;
// - the line of a process that did not start, with the free text of its
//   load error; the line of the shares of the policy, which a loop writes;
// - the lines with no value.

// The bytes of the Text field of the name of a strategy: the longest,
// "round robin", has 11 bytes.
STRATEGY_FIELD_BYTES :: 16
// The bytes of the Text field of the first check that failed: the longest
// has 103 bytes.
PROBLEM_FIELD_BYTES :: 104

// The weights written through the machine handle ordered the shares under
// fair and EEVDF.
@(log_fact = "scheduler: the weights 1 2 4 written through the machine handle while 12 spinners ran: each write was read back, and the heavier weight got more under fair and EEVDF: {verdict}")
Written_Weights_Ordered :: struct {
	verdict: [16]u8,
}

// The time of one Strategy_Set with its kernel entry over the changes of
// the stress: the least, the middle and the worst.
@(log_fact = "scheduler: one Strategy_Set, with its kernel entry: {least} at least, {middle} in the middle, {worst} at worst")
Strategy_Set_Measured :: struct {
	least:  value_kinds.Time_In_Nanoseconds,
	middle: value_kinds.Time_In_Nanoseconds,
	worst:  value_kinds.Time_In_Nanoseconds,
}

// The writes of a schedule through the machine handle while the strategy
// changed: none refused, and each spinner kept the last one.
@(log_fact = "scheduler: writes of a schedule through the machine handle while the strategy changed 100 times: none was refused, each of the 8 spinners ran after them and has the schedule written last: {verdict}")
Schedule_Writes_During_Changes :: struct {
	verdict: [16]u8,
}

// A thread of the root service, found by its name and its serial: its
// schedule read and written through the machine handle.
@(log_fact = "scheduler: a thread of another process, the root service, found by its name and its serial: through the machine handle its schedule was read, written, read back and written back: {verdict}")
Other_Process_Schedule :: struct {
	verdict: [16]u8,
}

// The case of the lag of a held spinner does not run on a machine with as
// many processors as spinners.
@(log_fact = "scheduler: the lag of a held spinner is not checked on a machine with {processors} processors or more: each spinner can be alone in its queue")
Lag_Not_Checked :: struct {
	processors: u64,
}

// The lag that the kernel reported for the held spinner over the rounds.
@(log_fact = "scheduler: in {rounds} rounds the kernel reported the held spinner with a lag below 0 {owing} times and above 0 {owed} times; the lowest lag was minus {largest} weighted cycles (measures)")
Lag_Measured :: struct {
	rounds:  u64,
	owing:   u64,
	owed:    u64,
	largest: u64,
}

// The strategy of the machine changed.
@(log_fact = "scheduler: the strategy is now {strategy}, it was {previous_strategy}")
Strategy_Changed :: struct {
	strategy:          [16]u8,
	previous_strategy: [16]u8,
}

// How many times as often EEVDF woke the two threads as round robin.
@(log_fact = "scheduler: EEVDF woke {ratio} times as often as round robin (a measure)")
Eevdf_Wakes_Compared :: struct {
	ratio: u64,
}

// Each check of the strategies passed.
@(log_fact = "scheduler: ok, no spinner starved under 3 strategies, a wake ended {eevdf_turns} turns under EEVDF and 0 under round robin, the weights ordered the shares, each thread ran after {changes} changes, 0 wakes lost, a change needs the right Schedule")
Strategies_Passed :: struct {
	eevdf_turns: u64,
	changes:     u64,
}

// A check failed: the first one.
@(log_fact = "scheduler: wrong: {problem}")
Check_Failed :: struct {
	problem: [104]u8,
}

// The time of one draw of the window.
@(log_fact = "scheduler: the window took {drawing} to draw")
Window_Drawn :: struct {
	drawing: value_kinds.Time_In_Microseconds,
}

// The thread of the share policy did not start.
@(log_fact = "scheduler: the thread of the share policy did not start: {status}")
Share_Policy_Thread_Not_Started :: struct {
	status: op.Status,
}

// The case of the refused writes of a placement does not run on a machine
// with too few processors.
@(log_fact = "scheduler: the refused writes of a placement are not checked on a machine with {processors} processors: the case needs a processor that the thread does not have, and a processor that the machine does not have")
Refused_Placement_Not_Checked :: struct {
	processors: u64,
}

// The case of the limit of a placement does not run on a machine with too
// few processors.
@(log_fact = "scheduler: the limit of a placement is not checked on a machine with {processors} processors: the case needs a limit of two processors and a processor outside it")
Placement_Limit_Not_Checked :: struct {
	processors: u64,
}

// The case of a set without the home of a thread does not run on a
// machine with too few processors.
@(log_fact = "scheduler: a set without the home of a thread is not checked on a machine with {processors} processors: the case needs a second processor, and one spinner more than the processors")
Set_Without_Home_Not_Checked :: struct {
	processors: u64,
}

// The reports that the case of the two groups read.
@(log_fact = "scheduler: the two groups were read in {samples} reports (a measure)")
Groups_Read :: struct {
	samples: u64,
}

// A spinner of the list got the processor 1 too through the machine
// handle, and a report showed it there.
@(log_fact = "scheduler: two spinners and the first thread kept on the processor 0; the spinner of the list got the processor 1 too through the machine handle: a report showed it on the processor 1: {reached}: {verdict}")
Idle_Processor_Reached :: struct {
	reached: u64,
	verdict: [16]u8,
}

// The round in which the spinner was seen on the processor 1.
@(log_fact = "scheduler: the spinner was seen on the processor 1 in the round {round} (a measure)")
Idle_Processor_Round :: struct {
	round: u64,
}

// The writes of a placement through the machine handle while the strategy
// changed: none refused, and each spinner has each processor again.
@(log_fact = "scheduler: writes of a placement through the machine handle while the strategy changed {changes} times: none was refused, each of the {spinners} spinners ran after them and has each processor again: {verdict}")
Placement_Writes_During_Changes :: struct {
	changes:  u64,
	spinners: u64,
	verdict:  [16]u8,
}

// The writes of a placement during the changes of strategy, and those
// refused.
@(log_fact = "scheduler: {writes} writes of a placement during {changes} changes of strategy, {refused} refused (measures)")
Placement_Writes_Measured :: struct {
	writes:  u64,
	changes: u64,
	refused: u64,
}

// The share policy is on: the period of its rounds.
@(log_fact = "scheduler: the share policy is on: each process has its process weight, divided between its threads that count, one round each {period}")
Share_Policy_On :: struct {
	period: value_kinds.Time_In_Milliseconds,
}

// The process with 8 spinning threads got a smaller part under the share
// policy than without it.
@(log_fact = "scheduler: the process with 8 spinning threads against the process with 1, by the ticks of the kernel over one interval: its part is smaller under the share policy than without it: {verdict}")
Share_Policy_Orders_Parts :: struct {
	verdict: [16]u8,
}

// The time of one round of the share policy, and its writes.
@(log_fact = "scheduler: one round of the share policy, over {processes} processes and {threads} threads: {middle} in the middle of {rounds} rounds; {writes} writes of a schedule in all, {raises} of them raised a weight; the period of the rounds is {period} (measures)")
Share_Policy_Round_Measured :: struct {
	processes: u64,
	threads:   u64,
	middle:    value_kinds.Time_In_Nanoseconds,
	rounds:    u64,
	writes:    u64,
	raises:    u64,
	period:    value_kinds.Time_In_Milliseconds,
}

// The first thread of a process started under the share policy by a thread
// with a new-thread weight limit above the part of a thread.
@(log_fact = "scheduler: the first thread of a process started under the share policy, by a thread whose own new-thread weight limit is above {above}, has the weight, the weight limit and the new-thread weight limit {weight}, {limit} and {thread_limit}: {verdict}")
Started_Process_Weights :: struct {
	above:        u64,
	weight:       u64,
	limit:        u64,
	thread_limit: u64,
	verdict:      [16]u8,
}

// The part of the process of short threads against the process of one
// long thread, without and with the share policy.
@(log_fact = "scheduler: the process of short threads got {without_policy} % of the process of one long thread without the share policy, and {with_policy} % with it; each interval ended on its count of ticks: {without_ended} and {with_ended} (measures)")
Short_Threads_Parts :: struct {
	without_policy: u64,
	with_policy:    u64,
	without_ended:  u64,
	with_ended:     u64,
}

#assert(size_of(Check_Failed) == PROBLEM_FIELD_BYTES)
#assert(size_of(Strategy_Changed) == 2 * STRATEGY_FIELD_BYTES)

// verdict_field gives the Text field of the verdict of a case in the words
// of the line: "as it must" or "WRONG".
verdict_field :: proc "contextless" (right: bool) -> [16]u8 {
	return value_kinds.text_field(right ? "as it must" : "WRONG", 16)
}

// strategy_field gives the Text field of the name of a strategy.
strategy_field :: proc "contextless" (strategy: op.Strategy) -> [STRATEGY_FIELD_BYTES]u8 {
	return value_kinds.text_field(op.STRATEGY_NAMES[strategy], STRATEGY_FIELD_BYTES)
}
