package build

import op "modus:contract/operation"
import "core:fmt"
import "core:testing"
import "modustool:foundation"

// The log facts of scheduler that replaced its long lines
// (src/md/features/log_facts.md, "The facts of the demonstrations"),
// against the lines that they replaced, so that a wait on a sentence that
// did not change reads it as before. Three kinds of line changed their sentence: a
// share is in hundredths of a percent with two decimals, where the line
// wrote tenths; a line that passed the 512 bytes of a template is two
// facts; the shares of the written weights, which a loop wrote over the
// strategies, are one fact for each strategy. Each of those is compared
// with its new sentence. The helpers are in fact_test_helpers_test.odin.

@(private = "file")
SCHEDULER_SOURCES :: foundation.DEMONSTRATION_MODULE_SOURCES + "scheduler"
@(private = "file")
SCHEDULER_EDGE_COUNTS := [3]u64{0, 1, max(u64)}
@(private = "file")
SCHEDULER_EDGE_TIMES := [3]u64{0, 1, u64(max(i64))}
// The shares at their edges: none, one hundredth, the whole, and the
// largest that the signed field holds.
@(private = "file")
SCHEDULER_EDGE_SHARES := [4]u64{0, 1, 10_000, u64(max(i64))}
@(private = "file")
SCHEDULER_VERDICTS := [2]string{"as it must", "WRONG"}

// scheduler_share_text gives a share in hundredths of a percent with two
// decimals, as a field Hundredths writes it.
@(private = "file")
scheduler_share_text :: proc(hundredths: u64) -> string {
	return fmt.tprintf("%d.%02d", hundredths / 100, hundredths % 100)
}

@(private = "file")
scheduler_render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
	return fact_test_render(t, file, "scheduler", type_name, values)
}

// The facts with no value write the line of before.
@(test)
the_facts_of_scheduler_with_no_value_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, SCHEDULER_SOURCES)
	if !ok {
		return
	}
	Empty_Fact :: struct {
		type_name: string,
		line:      string,
	}
	facts := [?]Empty_Fact {
		{"Groups_Not_Checked", "scheduler: two groups of spinners with no common processor are not checked on a machine with one processor"},
		{"Idle_Set_Not_Checked", "scheduler: a set that gets an idle processor is not checked on a machine with one processor"},
		{"Share_Policy_Off", "scheduler: the share policy is off: each thread has the weight that its process asked and the full weight limit"},
		{"Share_Policy_Without_Image", "scheduler: the share policy is not checked: no boot image, or the process did not find its own threads"},
		{"Share_Policy_Without_Processes", "scheduler: the share policy is not checked: a process with spinning threads did not start, or its threads did not become ready"},
		{"Short_Threads_Without_Image", "scheduler: the share policy is not checked against short threads: no boot image, or the process did not find its own threads"},
		{"Short_Threads_Without_Processes", "scheduler: the share policy is not checked against short threads: a process did not start, or its threads did not become ready"},
		{"Full_Limits_Not_Given_Back", "scheduler: after the case of the short threads, a write that gives the full weight limits back was refused"},
	}
	for fact in facts {
		facts_expect_line(t, scheduler_render(t, file, fact.type_name, {}), fact.line)
	}
}

// The line of each strategy is two facts, and a share has two decimals.
@(test)
the_facts_of_a_strategy_write_two_lines_with_shares_in_hundredths :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, SCHEDULER_SOURCES)
	if !ok {
		return
	}
	strategies := [4]op.Strategy{.None, .Round_Robin, .Fair, .Eevdf}
	for strategy in strategies {
		name := op.STRATEGY_NAMES[strategy]
		for count in SCHEDULER_EDGE_COUNTS {
			other := max(u64) - count
			for time in SCHEDULER_EDGE_TIMES {
				later := u64(max(i64)) - time
				facts_expect_line(t, scheduler_render(t, file, "Strategy_Wakes_Measured", {{"wakes", count}, {"local_turns", other}, {"interrupt_turns", count}, {"pair_moves", other}, {"late_middle", time}, {"late_worst", later}, {"strategy", name}}), line_of_before("scheduler: ", name, ": two threads that wake each other, a spinner on each processor: ", count, " wakes in one second (", other, " turns ended on the processor of the waker, ", count, " by an interrupt, ", other, " moves); a thread that sleeps 2 ms among 8 spinners: late by ", time, " us in the middle, ", later, " us at worst"))
			}
			facts_expect_line(t, scheduler_render(t, file, "Strategy_Wakes_Checked", {{"turns", count}, {"local_turns", other}, {"interrupt_turns", count}, {"pair_moves", other}, {"strategy", name}}), line_of_before("scheduler: ", name, ": two threads that wake each other, a spinner on each processor: ", count, " turns of the first thread and more (", other, " turns ended on the processor of the waker, ", count, " by an interrupt, ", other, " moves)"))
		}
		for share in SCHEDULER_EDGE_SHARES {
			text := scheduler_share_text(share)
			for time in SCHEDULER_EDGE_TIMES {
				facts_expect_line(t, scheduler_render(t, file, "Strategy_Shares_Measured", {{"least_share", share}, {"most_share", share}, {"work", max(u64)}, {"weight_one_share", share}, {"weight_two_share", share}, {"weight_four_share", share}, {"wake_turns", u64(0)}, {"moves", max(u64)}, {"pick", time}, {"interrupt_preemption", time}, {"strategy", name}}), line_of_before("scheduler: ", name, ": 8 spinners of one weight: shares ", text, " % to ", text, " %, work ", max(u64), " million in one second; 12 spinners, weights 1 2 4: a spinner of each weight ", text, " %, ", text, " %, ", text, " %; ", u64(0), " turns ended by a wake, ", max(u64), " moves, one pick ", time, " ns, one preemption by an interrupt ", time, " ns in the kernel"))
				facts_expect_line(t, scheduler_render(t, file, "Strategy_Shares_Checked", {{"least_share", share}, {"most_share", share}, {"weight_one_share", share}, {"weight_two_share", share}, {"weight_four_share", share}, {"wake_turns", u64(1)}, {"moves", u64(0)}, {"pick", time}, {"interrupt_preemption", time}, {"strategy", name}}), line_of_before("scheduler: ", name, ": 8 spinners of one weight: shares ", text, " % to ", text, " %; 12 spinners, weights 1 2 4: a spinner of each weight ", text, " %, ", text, " %, ", text, " %; ", u64(1), " turns ended by a wake, ", u64(0), " moves, one pick ", time, " ns, one preemption by an interrupt ", time, " ns in the kernel"))
			}
			facts_expect_line(t, scheduler_render(t, file, "Written_Weights_Shares", {{"weight_one_share", share}, {"weight_two_share", share}, {"weight_four_share", share}, {"strategy", name}}), line_of_before("scheduler: 12 spinners that started with the full weight, the weights 1 2 4 written through the machine handle while they ran: a spinner of each weight ", text, " %, ", text, " %, ", text, " % under ", name))
		}
	}
	// A share of 12.05 % keeps its zero, and 12.5 % has two decimals.
	facts_expect_line(t, scheduler_render(t, file, "Written_Weights_Shares", {{"weight_one_share", u64(1205)}, {"weight_two_share", u64(1250)}, {"weight_four_share", u64(5)}, {"strategy", "EEVDF"}}), "scheduler: 12 spinners that started with the full weight, the weights 1 2 4 written through the machine handle while they ran: a spinner of each weight 12.05 %, 12.50 %, 0.05 % under EEVDF")
	for share in SCHEDULER_EDGE_SHARES {
		text := scheduler_share_text(share)
		for count in SCHEDULER_EDGE_COUNTS {
			facts_expect_line(t, scheduler_render(t, file, "Process_Shares_Measured", {{"without_one", share}, {"without_two", share}, {"without_four", share}, {"without_eight", share}, {"with_one", share}, {"with_two", share}, {"with_four", share}, {"with_eight", share}, {"without_ratio", count}, {"with_ratio", max(u64) - count}}), line_of_before("scheduler: shares of the processes with 1, 2, 4 and 8 spinning threads under EEVDF, by the ticks of the kernel: without the share policy ", text, " %, ", text, " %, ", text, " %, ", text, " %; with it ", text, " %, ", text, " %, ", text, " %, ", text, " %; the process with 8 threads got ", count, " % of the process with 1 thread without the policy, and ", max(u64) - count, " % with it (measures)"))
		}
	}
}

// Each fact of a schedule and of a weight limit writes the line of
// before: each status by its name, each verdict. The weight limit and its
// rounds were one line: they are two facts, each with its verdict.
@(test)
the_facts_of_a_schedule_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, SCHEDULER_SOURCES)
	if !ok {
		return
	}
	for status in op.Status {
		word := u64(status)
		name := op.STATUS_NAMES[status]
		for verdict in SCHEDULER_VERDICTS {
			for count in SCHEDULER_EDGE_COUNTS {
				other := max(u64) - count
				facts_expect_line(t, scheduler_render(t, file, "Own_Schedule_Read", {{"asked_weight", count}, {"asked_request", other}, {"read_weight", count}, {"read_request", other}, {"half_weight", count}, {"half_request", other}, {"weight_after", count}, {"request_after", other}, {"raised_weight", count}, {"raised_request", other}, {"weight_raise", word}, {"request_raise", word}, {"kept", count}, {"first_weight", other}, {"first_request", count}, {"verdict", verdict}}), line_of_before("scheduler: a thread created with the weight ", count, " and the request ", other, " us read its own schedule: weight ", count, ", request ", other, " us; after it lowered them to ", count, " and ", other, " us: weight ", count, ", request ", other, " us; its own writes of the weight ", count, " and of the request ", other, " us: ", name, " and ", name, ", and the schedule stayed: ", count, "; the first thread: weight ", other, ", request ", count, " us: ", verdict))
				facts_expect_line(t, scheduler_render(t, file, "Schedule_Writes_Refused", {{"too_heavy", word}, {"too_long", word}, {"kept", count}, {"no_schedule", word}, {"no_inspect", word}, {"blind_write", word}, {"no_control", word}, {"reads", other}, {"control", word}, {"ended", word}, {"verdict", verdict}}), line_of_before("scheduler: refused writes of a schedule: a weight above the full weight ", name, ", a request above the limit ", name, ", and the schedule stayed: ", count, "; the machine handle with no right Schedule ", name, "; a read and a write through the machine handle with Schedule and no Inspect ", name, " and ", name, "; a thread handle with Inspect and no Control ", name, ", and it reads: ", other, "; another command with the machine handle ", name, "; the machine number of a thread that ended ", name, ": ", verdict))
				facts_expect_line(t, scheduler_render(t, file, "Weight_Limit_Written", {{"limit", count}, {"weight", other}, {"raise", word}, {"record_right", count}, {"kept", other}, {"verdict", verdict}}), line_of_before("scheduler: the weight limit ", count, " written through the machine handle: the thread has the weight ", other, "; its own write of the full weight ", name, ", the error record has the weight of the thread: ", count, "; its own write of the full limit changed nothing: ", other, ": ", verdict))
				facts_expect_line(t, scheduler_render(t, file, "Under_Weight_Limit", {{"limit", count}, {"heavier_weight", other}, {"too_heavy", word}, {"child_weight", count}, {"child_limit", other}, {"child_raise", word}, {"restored_weight", count}, {"verdict", verdict}}), line_of_before("scheduler: under the weight limit ", count, ": a new thread with the weight ", other, " ", name, "; a new thread with the weight 0 has the weight ", count, " and the limit ", other, ", and its own write of the full weight ", name, "; after the machine handle wrote the full limit the first thread has the weight ", count, ": ", verdict))
				facts_expect_line(t, scheduler_render(t, file, "Own_New_Thread_Limit", {{"above", count}, {"first_open", other}, {"process_limit", count}, {"heavier_weight", other}, {"between_status", word}, {"error_limit", count}, {"child_weight", other}, {"child_limit", count}, {"child_new_thread_limit", other}, {"verdict", verdict}}), line_of_before("scheduler: under the share policy the first thread of this process got through the machine handle a new-thread weight limit of its own above ", count, ": ", other, ", and the process has the new-thread weight limit ", count, "; a new thread with the weight ", other, " ", name, ", and the error record names ", count, "; a new thread with the weight 0 has the weight, the weight limit and the new-thread weight limit ", other, ", ", count, " and ", other, ": ", verdict))
			}
		}
	}
	for verdict in SCHEDULER_VERDICTS {
		for count in SCHEDULER_EDGE_COUNTS {
			other := max(u64) - count
			facts_expect_line(t, scheduler_render(t, file, "Weight_Limit_Rounds", {{"limit", count}, {"rounds", other}, {"round_weight", count}, {"last_round_weight", other}, {"machine_weight", count}, {"accepted", other}, {"refused", count}, {"machine_raises", other}, {"above", count}, {"verdict", verdict}}), line_of_before("scheduler: under the weight limit ", count, ", ", other, " rounds of its own writes of the weights ", count, ", 1, 1024 and ", other, ", then the weight ", count, " through the machine handle: ", other, " of its own accepted, ", count, " refused, ", other, " raised by the machine handle, a wrong weight or limit ", count, " times: ", verdict))
			facts_expect_line(t, scheduler_render(t, file, "Stress_Done", {{"changes", count}, {"churned_threads", other}, {"wakes", count}, {"each_thread_ran", other}, {"thread_slots", count}, {"thread_slots_at_start", other}, {"schedule_writes", count}, {"refused_writes", other}}), line_of_before("scheduler: stress: ", count, " changes of strategy while ", other, " threads started and stopped, two threads woke each other ", count, " times and 8 spinners ran and moved; after the last change each thread ran: ", other, "; thread slots ", count, " of ", other, "; ", count, " writes of a schedule through the machine handle, ", other, " refused"))
		}
	}
	// The verdict of the owing rounds says why there is none: the longest
	// of its words fill most of its field.
	endings := [4]string{"as it must", "a round did not run: WRONG", "no round had a lag below 0, so nothing was checked: WRONG", "WRONG"}
	for ending in endings {
		for count in SCHEDULER_EDGE_COUNTS {
			other := max(u64) - count
			facts_expect_line(t, scheduler_render(t, file, "Owing_Rounds_Done", {{"rounds", count}, {"raised", other}, {"changed", count}, {"not_new", other}, {"verdict_words", ending}}), line_of_before("scheduler: at least ", count, " rounds on a held spinner under EEVDF, until one had a lag below 0: the spinner lowered to the weight 1 and ran a tick, a Stop, its own writes of the full weight and of the request 1 us, the full weight through the machine handle, a Resume: ", other, " of its raises were not refused, the reported lag changed after ", count, " of its writes, and was not 0 after ", other, " raises of the machine handle: ", ending))
		}
	}
}

// Each fact of a placement writes the line of before: each status by its
// name, each verdict.
@(test)
the_facts_of_a_placement_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, SCHEDULER_SOURCES)
	if !ok {
		return
	}
	for status in op.Status {
		word := u64(status)
		name := op.STATUS_NAMES[status]
		for verdict in SCHEDULER_VERDICTS {
			for count in SCHEDULER_EDGE_COUNTS {
				other := max(u64) - count
				facts_expect_line(t, scheduler_render(t, file, "Own_Placement_Read", {{"processors", count}, {"first_right", other}, {"processor", count}, {"write", word}, {"second_right", other}, {"samples", count}, {"outside", other}, {"verdict", verdict}}), line_of_before("scheduler: a thread read its own placement: each of the ", count, " processors in its set and in its limit: ", other, "; its own write of the processor ", count, " alone: ", name, ", and it then read that processor alone, with the same limit: ", other, "; in ", count, " samples of its thread report, each after one more tick of its run, its home or its processor was another one ", other, " times: ", verdict))
				facts_expect_line(t, scheduler_render(t, file, "Placement_Sets_Refused", {{"wider", word}, {"nowhere", word}, {"process_records", count}, {"no_limit", word}, {"outside_limit", word}, {"machine_records", other}, {"unchanged", count}, {"verdict", verdict}}), line_of_before("scheduler: refused sets of a placement, on a spinner that the machine handle keeps on the processor 0: through its thread handle a wider set ", name, " and a processor that the machine does not have ", name, ", with their error records: ", count, "; through the machine handle a limit of no processor of the machine ", name, " and a set outside its limit ", name, ", with their error records: ", other, "; the placement stayed: ", count, ": ", verdict))
				facts_expect_line(t, scheduler_render(t, file, "Placement_Rights", {{"no_schedule", word}, {"no_inspect", word}, {"blind_write", word}, {"no_control", word}, {"reads", count}, {"stayed", other}, {"ended_read", word}, {"ended_write", word}, {"verdict", verdict}}), line_of_before("scheduler: the rights of a placement: the machine handle with no right Schedule ", name, "; a read and a write through the machine handle with Schedule and no Inspect ", name, " and ", name, "; a thread handle with Inspect and no Control ", name, ", and it reads: ", count, "; the placement stayed: ", other, "; a read and a write by the machine number of a thread that ended ", name, " and ", name, ": ", verdict))
				facts_expect_line(t, scheduler_render(t, file, "Placement_Limit_Written", {{"last_processor", count}, {"limited", other}, {"widen", word}, {"record_right", count}, {"kept", other}, {"verdict", verdict}}), line_of_before("scheduler: the limit of the processors 0 to ", count, " written through the machine handle: the thread has that set: ", other, "; its own write of each processor ", name, ", the error record has the set of the thread: ", count, "; its own write of a wider limit changed nothing: ", other, ": ", verdict))
				facts_expect_line(t, scheduler_render(t, file, "Placement_Limit_Inherited", {{"inherited", count}, {"home_inside", other}, {"widen", word}, {"restored", count}, {"verdict", verdict}}), line_of_before("scheduler: under that limit: a new thread has the limit as its set and as its limit: ", count, ", its home is a processor of the limit: ", other, ", and its own write of each processor ", name, "; after the machine handle wrote the zero record the first thread has each processor in its set and in its limit: ", count, ": ", verdict))
			}
		}
	}
	for verdict in SCHEDULER_VERDICTS {
		for count in SCHEDULER_EDGE_COUNTS {
			other := max(u64) - count
			facts_expect_line(t, scheduler_render(t, file, "Placement_Limit_Rounds", {{"rounds", count}, {"accepted", other}, {"refused", count}, {"widened", other}, {"wrong", count}, {"verdict", verdict}}), line_of_before("scheduler: under that limit, ", count, " rounds of the own writes of the thread, of the processor 0, of the set of the limit and of each processor, then the limit again through the machine handle: ", other, " of its own accepted, ", count, " refused, ", other, " widened by the machine handle, a wrong set or limit ", count, " times: ", verdict))
			facts_expect_line(t, scheduler_render(t, file, "Set_Without_Home_Of_Thread", {{"waiting_moved", count}, {"waiting_settled", other}, {"waiting_outside", count}, {"held_moved", other}, {"held_settled", count}, {"held_outside", other}, {"verdict", verdict}}), line_of_before("scheduler: a set without the home of a thread, written through the machine handle: a thread that waits has a home of the set in the next report: ", count, ", and after its wake it ran inside the set: ", other, ", outside in ", count, " reports; a spinner that a Stop holds has a home of the set in the next report: ", other, ", and after the Resume it ran inside the set: ", count, ", outside in ", other, " reports: ", verdict))
			facts_expect_line(t, scheduler_render(t, file, "Set_Without_Home_Of_Spinner", {{"listed_settled", count}, {"listed_outside", other}, {"running_settled", count}, {"running_outside", other}, {"verdict", verdict}}), line_of_before("scheduler: a set without the home of a spinner, written through the machine handle: a spinner in a list ran inside the set: ", count, ", outside in ", other, " reports after the first one inside; a spinner on a processor ran inside the set: ", count, ", outside in ", other, " reports after the first one inside: ", verdict))
			facts_expect_line(t, scheduler_render(t, file, "Groups_Apart", {{"group", count}, {"first_group_last", other}, {"second_group_first", count}, {"second_group_last", other}, {"inherited", count}, {"processors", other}, {"each_seen", count}, {"samples", other}, {"outside", count}, {"verdict", verdict}}), line_of_before("scheduler: two groups of ", count, " spinners, each created under the limit of its group, the processors 0 to ", other, " and ", count, " to ", other, ": each spinner has that limit as its set and as its limit: ", count, "; each of the ", other, " processors ran a spinner of its group: ", count, "; in at least ", other, " reports of the threads a spinner had a home or a processor of the other group ", count, " times: ", verdict))
			facts_expect_line(t, scheduler_render(t, file, "Balance_Past_Budget_Queue", {{"blockers", count}, {"last_processor", other}, {"apart", count}, {"verdict", verdict}}), line_of_before("scheduler: ", count, " threads of a budget with no processor time, in the queue of the processor 0, make it the busiest, and each processor from 2 runs a spinner of its own; two spinners of the queue of the processor 1 got the processors 1 to ", other, ": a report showed the two on two processors at one time: ", count, ": ", verdict))
			facts_expect_line(t, scheduler_render(t, file, "Balance_Past_Spinner_Queue", {{"blockers", count}, {"last_processor", other}, {"apart", count}, {"verdict", verdict}}), line_of_before("scheduler: ", count, " spinners that only the processor 0 can run make its queue the busiest, and each processor from 2 runs a spinner of its own; two spinners of the queue of the processor 1 got the processors 1 to ", other, ": a report showed the two on two processors at one time: ", count, ": ", verdict))
		}
	}
	for count in SCHEDULER_EDGE_COUNTS {
		facts_expect_line(t, scheduler_render(t, file, "Balance_Not_Checked", {{"processors", count}, {"processors_most", max(u64) - count}}), line_of_before("scheduler: the balance past a queue of threads that a processor cannot take is not checked on a machine with ", count, " processors: the case needs two processors for the two queues, two more for the first thread, and a spinner for each processor from 2, at most ", max(u64) - count, " processors"))
	}
}

// Each fact of the share policy writes the line of before.
@(test)
the_facts_of_the_share_policy_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, SCHEDULER_SOURCES)
	if !ok {
		return
	}
	for verdict in SCHEDULER_VERDICTS {
		for count in SCHEDULER_EDGE_COUNTS {
			other := max(u64) - count
			facts_expect_line(t, scheduler_render(t, file, "Share_Policy_Rounds", {{"one_thread_weight", count}, {"two_threads_weight", other}, {"four_threads_weight", count}, {"eight_threads_weight", other}, {"new_thread_limit", count}, {"one_thread_sum", other}, {"two_threads_sum", count}, {"four_threads_sum", other}, {"eight_threads_sum", count}, {"steady", other}, {"verdict", verdict}}), line_of_before("scheduler: the share policy, three rounds: each thread of the processes with 1, 2, 4 and 8 spinning threads has the weight and the weight limit ", count, ", ", other, ", ", count, " and ", other, ", and the new-thread weight limit ", count, "; the weights of each process sum to ", other, ", ", count, ", ", other, " and ", count, "; the third round wrote none of their threads: ", other, ": ", verdict))
			facts_expect_line(t, scheduler_render(t, file, "Own_Threads_Weights", {{"asked_weight", count}, {"weight", other}, {"lowered_weight", count}, {"lowered_to", other}, {"more_threads", count}, {"threads", other}, {"least", count}, {"most", other}, {"sum", count}, {"verdict", verdict}}), line_of_before("scheduler: under the share policy, a thread of this process created with the weight ", count, " has the weight ", other, ", and the weight ", count, " after it lowered itself to ", other, "; after this process started ", count, " threads more, its ", other, " threads have the weights ", count, " to ", other, ", which sum to ", count, " of 1024: ", verdict))
			facts_expect_line(t, scheduler_render(t, file, "Share_Policy_Off_Weights", {{"lowered_weight", count}, {"none_refused", other}, {"verdict", verdict}}), line_of_before("scheduler: the share policy off: each thread of the 4 processes and the first thread of this process have the weight 1024 and the two full weight limits again, the thread that lowered itself has the weight ", count, " and the two full weight limits, and no write of the policy was refused: ", other, ": ", verdict))
			facts_expect_line(t, scheduler_render(t, file, "Short_Threads_Unseen", {{"alive", count}, {"checked", other}, {"new_part", count}, {"each_right", other}, {"sum_under", count}, {"verdict", verdict}}), line_of_before("scheduler: the share policy and a process that keeps ", count, " short threads alive, after one round: ", other, " of its threads that no round saw, read through the machine handle, each had the weight, the weight limit and the new-thread weight limit ", count, ": ", other, ", and those of one read summed to under 1024: ", count, ": ", verdict))
		}
	}
}
