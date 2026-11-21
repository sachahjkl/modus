package scheduler

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:support/system"

// The log facts of scheduler (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero. A status of the kernel is a field of the contract
// enum, which a reader writes by its name, as the line did; beside 8-byte
// fields it is the 8-byte word op.Status_Word, so the record has no padding.
//
// A share is in hundredths of a percent, written with two decimals: the
// lines wrote tenths, and no field kind writes one decimal of a number that
// is not a time. The line of the written weights, which a loop wrote over
// the strategies, is one fact for each strategy. A value that a line wrote
// twice is two fields, as a template names each field once.
//
// The line of a process of the share policy that did not start had its
// load error in the middle: it is a fact of the status and of the budgets,
// then, when the load failed, a fact of the stage of the load error, a
// distinct type of its shape in the contract module (log_facts.md, "The
// load error as facts").

// The bytes of the Text field of the name of a process of a case: the
// longest, "started_under_policy", has 20 bytes.
PROCESS_NAME_FIELD_BYTES :: 24

// A process of a case of the share policy did not start: the status, what
// this process can give, and what the process asks.
@(log_fact = "scheduler: the process {process_name} did not start: {status}; this process can give pages {given_pages}, processes {given_processes}, threads {given_threads}; the process asks pages {asked_pages}, threads {asked_threads}")
Share_Process_Not_Started :: struct {
	status:          op.Status_Word,
	given_pages:     u64,
	given_processes: u64,
	given_threads:   u64,
	asked_pages:     u64,
	asked_threads:   u64,
	process_name:    [24]u8,
}

// The load error of a process of a case that did not start, one fact type
// for each stage. Map and Unmap share their shape, and each has its
// template.
@(log_fact = "scheduler: the load of a process of the share policy: the load of {module_name} ({module_hash}) found no file of its import {imported_name} ({imported_hash})")
Share_Load_Find_Failed :: distinct module.Load_Find_Fields
@(log_fact = "scheduler: the load of a process of the share policy: the file of {subject_name} ({subject_hash}) does not have the hash that names it, or is not a valid module: {file_error}")
Share_Load_Read_Failed :: distinct module.Load_Read_Fields
@(log_fact = "scheduler: the load of a process of the share policy: an import cycle: {module_name} imports {imported_name}, and {replacement_name} still loads its imports")
Share_Load_Cycle_Failed :: distinct module.Load_Cycle_Fields
@(log_fact = "scheduler: the load of a process of the share policy: {module_name} imports {imported_name}, and its replacement fails the check: export {export}: {difference}, parameter {parameter}")
Share_Load_Check_Failed :: distinct module.Load_Check_Fields
@(log_fact = "scheduler: the load of a process of the share policy: import slot {import_slot} of {module_name} cannot be bound: export {export} of {imported_name}")
Share_Load_Bind_Failed :: distinct module.Load_Bind_Fields
@(log_fact = "scheduler: the load of a process of the share policy: the kernel refused to map {module_name} ({module_hash}): status {status}")
Share_Load_Map_Failed :: distinct module.Load_Memory_Fields
@(log_fact = "scheduler: the load of a process of the share policy: the kernel refused to remove {module_name} ({module_hash}): status {status}")
Share_Load_Unmap_Failed :: distinct module.Load_Memory_Fields
@(log_fact = "scheduler: the load of a process of the share policy: no room for {module_name} ({module_hash}): a process has 16 modules at most, a module 8 imports, a table of prepared modules 64 parts, and its modules fit below the fixed ranges of the system")
Share_Load_Room_Failed :: distinct module.Load_Room_Fields

// share_load_error_log writes the fact of the stage of a load error. A
// stage None writes nothing: the start failed after the load.
share_load_error_log :: proc "contextless" (error: ^module.Load_Error) {
	switch error.stage {
	case .None:
	case .Find:
		system.log_fact(.Info, Share_Load_Find_Failed(module.load_find_fact_fields(error)))
	case .Read:
		system.log_fact(.Info, Share_Load_Read_Failed(module.load_read_fact_fields(error)))
	case .Cycle:
		system.log_fact(.Info, Share_Load_Cycle_Failed(module.load_cycle_fact_fields(error)))
	case .Check:
		system.log_fact(.Info, Share_Load_Check_Failed(module.load_check_fact_fields(error)))
	case .Bind:
		system.log_fact(.Info, Share_Load_Bind_Failed(module.load_bind_fact_fields(error)))
	case .Map:
		system.log_fact(.Info, Share_Load_Map_Failed(module.load_memory_fact_fields(error)))
	case .Unmap:
		system.log_fact(.Info, Share_Load_Unmap_Failed(module.load_memory_fact_fields(error)))
	case .Room:
		system.log_fact(.Info, Share_Load_Room_Failed(module.load_room_fact_fields(error)))
	}
}

// The line of one strategy is two facts, as one template holds at most 512
// bytes: the two threads that wake each other, then the shares and the
// costs in the kernel.

// One strategy in a measure run: the wakes of two threads in one second
// and the late wakes. The measure record reads the wakes after "a spinner
// on each processor: ".
@(log_fact = "scheduler: {strategy}: two threads that wake each other, a spinner on each processor: {wakes} wakes in one second ({local_stints} stints ended on the processor of the waker, {interrupt_stints} by an interrupt, {pair_moves} moves); a thread that sleeps 2 ms among 8 spinners: late by {late_middle} in the middle, {late_worst} at worst")
Strategy_Wakes_Measured :: struct {
	wakes:            u64,
	local_stints:     u64,
	interrupt_stints: u64,
	pair_moves:       u64,
	late_middle:      value_kinds.Time_In_Microseconds,
	late_worst:       value_kinds.Time_In_Microseconds,
	strategy:         [16]u8,
}

// One strategy in the check of a test: the rounds of the check, with no
// rate.
@(log_fact = "scheduler: {strategy}: two threads that wake each other, a spinner on each processor: {rounds} rounds of the first thread and more ({local_stints} stints ended on the processor of the waker, {interrupt_stints} by an interrupt, {pair_moves} moves)")
Strategy_Wakes_Checked :: struct {
	rounds:           u64,
	local_stints:     u64,
	interrupt_stints: u64,
	pair_moves:       u64,
	strategy:         [16]u8,
}

// One strategy in a measure run: the shares, the work, and the costs in
// the kernel.
@(log_fact = "scheduler: {strategy}: 8 spinners of one weight: shares {least_share} % to {most_share} %, work {work} million in one second; 12 spinners, weights 1 2 4: a spinner of each weight {weight_one_share} %, {weight_two_share} %, {weight_four_share} %; {wake_stints} stints ended by a wake, {moves} moves, one pick {pick}, one preemption by an interrupt {interrupt_preemption} in the kernel")
Strategy_Shares_Measured :: struct {
	least_share:          value_kinds.Hundredths,
	most_share:           value_kinds.Hundredths,
	work:                 u64,
	weight_one_share:     value_kinds.Hundredths,
	weight_two_share:     value_kinds.Hundredths,
	weight_four_share:    value_kinds.Hundredths,
	wake_stints:          u64,
	moves:                u64,
	pick:                 value_kinds.Time_In_Nanoseconds,
	interrupt_preemption: value_kinds.Time_In_Nanoseconds,
	strategy:             [16]u8,
}

// One strategy in the check of a test: the shares and the costs in the
// kernel, with no work in one second.
@(log_fact = "scheduler: {strategy}: 8 spinners of one weight: shares {least_share} % to {most_share} %; 12 spinners, weights 1 2 4: a spinner of each weight {weight_one_share} %, {weight_two_share} %, {weight_four_share} %; {wake_stints} stints ended by a wake, {moves} moves, one pick {pick}, one preemption by an interrupt {interrupt_preemption} in the kernel")
Strategy_Shares_Checked :: struct {
	least_share:          value_kinds.Hundredths,
	most_share:           value_kinds.Hundredths,
	weight_one_share:     value_kinds.Hundredths,
	weight_two_share:     value_kinds.Hundredths,
	weight_four_share:    value_kinds.Hundredths,
	wake_stints:          u64,
	moves:                u64,
	pick:                 value_kinds.Time_In_Nanoseconds,
	interrupt_preemption: value_kinds.Time_In_Nanoseconds,
	strategy:             [16]u8,
}

// The shares of 12 spinners whose weights the machine handle wrote while
// they ran, under one strategy.
@(log_fact = "scheduler: 12 spinners that started with the full weight, the weights 1 2 4 written through the machine handle while they ran: a spinner of each weight {weight_one_share} %, {weight_two_share} %, {weight_four_share} % under {strategy}")
Written_Weights_Shares :: struct {
	weight_one_share:  value_kinds.Hundredths,
	weight_two_share:  value_kinds.Hundredths,
	weight_four_share: value_kinds.Hundredths,
	strategy:          [16]u8,
}

// The stress: changes of strategy while threads start, wake and move.
@(log_fact = "scheduler: stress: {changes} changes of strategy while {churned_threads} threads started and stopped, two threads woke each other {wakes} times and 8 spinners ran and moved; after the last change each thread ran: {each_thread_ran}; thread slots {thread_slots} of {thread_slots_at_start}; {schedule_writes} writes of a schedule through the machine handle, {refused_writes} refused")
Stress_Done :: struct {
	changes:               u64,
	churned_threads:       u64,
	wakes:                 u64,
	each_thread_ran:       u64,
	thread_slots:          u64,
	thread_slots_at_start: u64,
	schedule_writes:       u64,
	refused_writes:        u64,
}

// A thread reads, lowers and tries to raise its own schedule; the first
// thread reads the defaults.
// half_weight and half_request are the values that the thread wrote;
// weight_after and request_after the values that it then read.
@(log_fact = "scheduler: a thread created with the weight {asked_weight} and the request {asked_request} us read its own schedule: weight {read_weight}, request {read_request} us; after it lowered them to {half_weight} and {half_request} us: weight {weight_after}, request {request_after} us; its own writes of the weight {raised_weight} and of the request {raised_request} us: {weight_raise} and {request_raise}, and the schedule stayed: {kept}; the first thread: weight {first_weight}, request {first_request} us: {verdict}")
Own_Schedule_Read :: struct {
	asked_weight:   u64,
	asked_request:  u64,
	read_weight:    u64,
	read_request:   u64,
	half_weight:    u64,
	half_request:   u64,
	weight_after:   u64,
	request_after:  u64,
	raised_weight:  u64,
	raised_request: u64,
	weight_raise:   op.Status_Word,
	request_raise:  op.Status_Word,
	kept:           u64,
	first_weight:   u64,
	first_request:  u64,
	verdict:        [16]u8,
}

// The refused writes of a schedule, each with its status; control is the
// status of a Thread_Control through the machine handle.
@(log_fact = "scheduler: refused writes of a schedule: a weight above the full weight {too_heavy}, a request above the limit {too_long}, and the schedule stayed: {kept}; the machine handle with no right Schedule {no_schedule}; a read and a write through the machine handle with Schedule and no Inspect {no_inspect} and {blind_write}; a thread handle with Inspect and no Control {no_control}, and it reads: {reads}; another command with the machine handle {control}; the machine number of a thread that ended {ended}: {verdict}")
Schedule_Writes_Refused :: struct {
	too_heavy:   op.Status_Word,
	too_long:    op.Status_Word,
	kept:        u64,
	no_schedule: op.Status_Word,
	no_inspect:  op.Status_Word,
	blind_write: op.Status_Word,
	no_control:  op.Status_Word,
	reads:       u64,
	control:     op.Status_Word,
	ended:       op.Status_Word,
	verdict:     [16]u8,
}

// The weight limit that the machine handle wrote, and the first own writes
// of the thread under it. The line was one with the rounds below: two facts,
// as one template holds at most 512 bytes, each with its verdict.
@(log_fact = "scheduler: the weight limit {limit} written through the machine handle: the thread has the weight {weight}; its own write of the full weight {raise}, the error record has the weight of the thread: {record_right}; its own write of the full limit changed nothing: {kept}: {verdict}")
Weight_Limit_Written :: struct {
	limit:        u64,
	weight:       u64,
	raise:        op.Status_Word,
	record_right: u64,
	kept:         u64,
	verdict:      [16]u8,
}

// The rounds of the own writes of the thread under the weight limit.
@(log_fact = "scheduler: under the weight limit {limit}, {rounds} rounds of its own writes of the weights {round_weight}, 1, 1024 and {last_round_weight}, then the weight {machine_weight} through the machine handle: {accepted} of its own accepted, {refused} refused, {machine_raises} raised by the machine handle, a wrong weight or limit {above} times: {verdict}")
Weight_Limit_Rounds :: struct {
	limit:             u64,
	rounds:            u64,
	round_weight:      u64,
	last_round_weight: u64,
	machine_weight:    u64,
	accepted:          u64,
	refused:           u64,
	machine_raises:    u64,
	above:             u64,
	verdict:           [16]u8,
}

// A new thread under the weight limit, and the limit given back.
@(log_fact = "scheduler: under the weight limit {limit}: a new thread with the weight {heavier_weight} {too_heavy}; a new thread with the weight 0 has the weight {child_weight} and the limit {child_limit}, and its own write of the full weight {child_raise}; after the machine handle wrote the full limit the first thread has the weight {restored_weight}: {verdict}")
Under_Weight_Limit :: struct {
	limit:           u64,
	heavier_weight:  u64,
	too_heavy:       op.Status_Word,
	child_weight:    u64,
	child_limit:     u64,
	child_raise:     op.Status_Word,
	restored_weight: u64,
	verdict:         [16]u8,
}

// The rounds on a held spinner under EEVDF, until one had a lag below 0;
// verdict_words says the verdict or why there is none.
@(log_fact = "scheduler: at least {rounds} rounds on a held spinner under EEVDF, until one had a lag below 0: the spinner lowered to the weight 1 and ran a tick, a Stop, its own writes of the full weight and of the request 1 us, the full weight through the machine handle, a Resume: {raised} of its raises were not refused, the reported lag changed after {changed} of its writes, and was not 0 after {not_new} raises of the machine handle: {verdict_words}")
Owing_Rounds_Done :: struct {
	rounds:        u64,
	raised:        u64,
	changed:       u64,
	not_new:       u64,
	verdict_words: [64]u8,
}

// A thread reads and writes its own placement.
@(log_fact = "scheduler: a thread read its own placement: each of the {processors} processors in its set and in its limit: {first_right}; its own write of the processor {processor} alone: {write}, and it then read that processor alone, with the same limit: {second_right}; in {samples} samples of its thread report, each after one more tick of its run, its home or its processor was another one {outside} times: {verdict}")
Own_Placement_Read :: struct {
	processors:   u64,
	first_right:  u64,
	processor:    u64,
	write:        op.Status_Word,
	second_right: u64,
	samples:      u64,
	outside:      u64,
	verdict:      [16]u8,
}

// The refused sets of a placement.
@(log_fact = "scheduler: refused sets of a placement, on a spinner that the machine handle keeps on the processor 0: through its thread handle a wider set {wider} and a processor that the machine does not have {nowhere}, with their error records: {process_records}; through the machine handle a limit of no processor of the machine {no_limit} and a set outside its limit {outside_limit}, with their error records: {machine_records}; the placement stayed: {unchanged}: {verdict}")
Placement_Sets_Refused :: struct {
	wider:           op.Status_Word,
	nowhere:         op.Status_Word,
	process_records: u64,
	no_limit:        op.Status_Word,
	outside_limit:   op.Status_Word,
	machine_records: u64,
	unchanged:       u64,
	verdict:         [16]u8,
}

// The rights of a placement.
@(log_fact = "scheduler: the rights of a placement: the machine handle with no right Schedule {no_schedule}; a read and a write through the machine handle with Schedule and no Inspect {no_inspect} and {blind_write}; a thread handle with Inspect and no Control {no_control}, and it reads: {reads}; the placement stayed: {stayed}; a read and a write by the machine number of a thread that ended {ended_read} and {ended_write}: {verdict}")
Placement_Rights :: struct {
	no_schedule: op.Status_Word,
	no_inspect:  op.Status_Word,
	blind_write: op.Status_Word,
	no_control:  op.Status_Word,
	reads:       u64,
	stayed:      u64,
	ended_read:  op.Status_Word,
	ended_write: op.Status_Word,
	verdict:     [16]u8,
}

// The limit of a placement that the machine handle wrote.
@(log_fact = "scheduler: the limit of the processors 0 to {last_processor} written through the machine handle: the thread has that set: {limited}; its own write of each processor {widen}, the error record has the set of the thread: {record_right}; its own write of a wider limit changed nothing: {kept}: {verdict}")
Placement_Limit_Written :: struct {
	last_processor: u64,
	limited:        u64,
	widen:          op.Status_Word,
	record_right:   u64,
	kept:           u64,
	verdict:        [16]u8,
}

// The rounds of the own writes of a thread under the limit of a placement.
@(log_fact = "scheduler: under that limit, {rounds} rounds of the own writes of the thread, of the processor 0, of the set of the limit and of each processor, then the limit again through the machine handle: {accepted} of its own accepted, {refused} refused, {widened} widened by the machine handle, a wrong set or limit {wrong} times: {verdict}")
Placement_Limit_Rounds :: struct {
	rounds:   u64,
	accepted: u64,
	refused:  u64,
	widened:  u64,
	wrong:    u64,
	verdict:  [16]u8,
}

// A new thread under the limit of a placement, and the limit given back.
@(log_fact = "scheduler: under that limit: a new thread has the limit as its set and as its limit: {inherited}, its home is a processor of the limit: {home_inside}, and its own write of each processor {widen}; after the machine handle wrote the zero record the first thread has each processor in its set and in its limit: {restored}: {verdict}")
Placement_Limit_Inherited :: struct {
	inherited:   u64,
	home_inside: u64,
	widen:       op.Status_Word,
	restored:    u64,
	verdict:     [16]u8,
}

// A set without the home of a thread that waits and of a held spinner.
@(log_fact = "scheduler: a set without the home of a thread, written through the machine handle: a thread that waits has a home of the set in the next report: {waiting_moved}, and after its wake it ran inside the set: {waiting_settled}, outside in {waiting_outside} reports; a spinner that a Stop holds has a home of the set in the next report: {held_moved}, and after the Resume it ran inside the set: {held_settled}, outside in {held_outside} reports: {verdict}")
Set_Without_Home_Of_Thread :: struct {
	waiting_moved:   u64,
	waiting_settled: u64,
	waiting_outside: u64,
	held_moved:      u64,
	held_settled:    u64,
	held_outside:    u64,
	verdict:         [16]u8,
}

// A set without the home of a spinner in a list and of a running spinner.
@(log_fact = "scheduler: a set without the home of a spinner, written through the machine handle: a spinner in a list ran inside the set: {listed_settled}, outside in {listed_outside} reports after the first one inside; a spinner on a processor ran inside the set: {running_settled}, outside in {running_outside} reports after the first one inside: {verdict}")
Set_Without_Home_Of_Spinner :: struct {
	listed_settled:  u64,
	listed_outside:  u64,
	running_settled: u64,
	running_outside: u64,
	verdict:         [16]u8,
}

// The case of two groups does not run on a machine with one processor.
@(log_fact = "scheduler: two groups of spinners with no common processor are not checked on a machine with one processor")
Groups_Not_Checked :: struct {}

// Two groups of spinners, each under the limit of its half of the
// processors.
@(log_fact = "scheduler: two groups of {group} spinners, each created under the limit of its group, the processors 0 to {first_group_last} and {second_group_first} to {second_group_last}: each spinner has that limit as its set and as its limit: {inherited}; each of the {processors} processors ran a spinner of its group: {each_seen}; in at least {samples} reports of the threads a spinner had a home or a processor of the other group {outside} times: {verdict}")
Groups_Apart :: struct {
	group:              u64,
	first_group_last:   u64,
	second_group_first: u64,
	second_group_last:  u64,
	inherited:          u64,
	processors:         u64,
	each_seen:          u64,
	samples:            u64,
	outside:            u64,
	verdict:            [16]u8,
}

// The balance past a queue of threads of a budget with no processor time.
@(log_fact = "scheduler: {blockers} threads of a budget with no processor time, in the queue of the processor 0, make it the busiest, and each processor from 2 runs a spinner of its own; two spinners of the queue of the processor 1 got the processors 1 to {last_processor}: a report showed the two on two processors at one time: {apart}: {verdict}")
Balance_Past_Budget_Queue :: struct {
	blockers:       u64,
	last_processor: u64,
	apart:          u64,
	verdict:        [16]u8,
}

// The balance past a queue of spinners that only the processor 0 can run.
@(log_fact = "scheduler: {blockers} spinners that only the processor 0 can run make its queue the busiest, and each processor from 2 runs a spinner of its own; two spinners of the queue of the processor 1 got the processors 1 to {last_processor}: a report showed the two on two processors at one time: {apart}: {verdict}")
Balance_Past_Spinner_Queue :: struct {
	blockers:       u64,
	last_processor: u64,
	apart:          u64,
	verdict:        [16]u8,
}

// The case of the balance does not run on a machine with too few or too
// many processors.
@(log_fact = "scheduler: the balance past a queue of threads that a processor cannot take is not checked on a machine with {processors} processors: the case needs two processors for the two queues, two more for the first thread, and a spinner for each processor from 2, at most {processors_most} processors")
Balance_Not_Checked :: struct {
	processors:      u64,
	processors_most: u64,
}

// The case of a set that gets an idle processor does not run on a machine
// with one processor.
@(log_fact = "scheduler: a set that gets an idle processor is not checked on a machine with one processor")
Idle_Set_Not_Checked :: struct {}

// The share policy is off.
@(log_fact = "scheduler: the share policy is off: each thread has the weight that its process asked and the full weight limit")
Share_Policy_Off :: struct {}

// The share policy is not checked: no image or no own threads.
@(log_fact = "scheduler: the share policy is not checked: no boot image, or the process did not find its own threads")
Share_Policy_Without_Image :: struct {}

// The share policy is not checked: a process of spinning threads did not
// start.
@(log_fact = "scheduler: the share policy is not checked: a process with spinning threads did not start, or its threads did not become ready")
Share_Policy_Without_Processes :: struct {}

// The three rounds of the share policy over the processes of 1, 2, 4 and 8
// spinning threads.
@(log_fact = "scheduler: the share policy, three rounds: each thread of the processes with 1, 2, 4 and 8 spinning threads has the weight and the weight limit {one_thread_weight}, {two_threads_weight}, {four_threads_weight} and {eight_threads_weight}, and the new-thread weight limit {new_thread_limit}; the weights of each process sum to {one_thread_sum}, {two_threads_sum}, {four_threads_sum} and {eight_threads_sum}; the third round wrote none of their threads: {steady}: {verdict}")
Share_Policy_Rounds :: struct {
	one_thread_weight:    u64,
	two_threads_weight:   u64,
	four_threads_weight:  u64,
	eight_threads_weight: u64,
	new_thread_limit:     u64,
	one_thread_sum:       u64,
	two_threads_sum:      u64,
	four_threads_sum:     u64,
	eight_threads_sum:    u64,
	steady:               u64,
	verdict:              [16]u8,
}

// The weights of the own threads of this process under the share policy.
@(log_fact = "scheduler: under the share policy, a thread of this process created with the weight {asked_weight} has the weight {weight}, and the weight {lowered_weight} after it lowered itself to {lowered_to}; after this process started {more_threads} threads more, its {threads} threads have the weights {least} to {most}, which sum to {sum} of 1024: {verdict}")
Own_Threads_Weights :: struct {
	asked_weight:   u64,
	weight:         u64,
	lowered_weight: u64,
	lowered_to:     u64,
	more_threads:   u64,
	threads:        u64,
	least:          u64,
	most:           u64,
	sum:            u64,
	verdict:        [16]u8,
}

// The weights after the share policy went off.
@(log_fact = "scheduler: the share policy off: each thread of the 4 processes and the first thread of this process have the weight 1024 and the two full weight limits again, the thread that lowered itself has the weight {lowered_weight} and the two full weight limits, and no write of the policy was refused: {none_refused}: {verdict}")
Share_Policy_Off_Weights :: struct {
	lowered_weight: u64,
	none_refused:   u64,
	verdict:        [16]u8,
}

// The shares of the four processes, without and with the share policy.
@(log_fact = "scheduler: shares of the processes with 1, 2, 4 and 8 spinning threads under EEVDF, by the ticks of the kernel: without the share policy {without_one} %, {without_two} %, {without_four} %, {without_eight} %; with it {with_one} %, {with_two} %, {with_four} %, {with_eight} %; the process with 8 threads got {without_ratio} % of the process with 1 thread without the policy, and {with_ratio} % with it (measures)")
Process_Shares_Measured :: struct {
	without_one:   value_kinds.Hundredths,
	without_two:   value_kinds.Hundredths,
	without_four:  value_kinds.Hundredths,
	without_eight: value_kinds.Hundredths,
	with_one:      value_kinds.Hundredths,
	with_two:      value_kinds.Hundredths,
	with_four:     value_kinds.Hundredths,
	with_eight:    value_kinds.Hundredths,
	without_ratio: u64,
	with_ratio:    u64,
}

// The share policy is not checked against short threads: no image or no
// own threads.
@(log_fact = "scheduler: the share policy is not checked against short threads: no boot image, or the process did not find its own threads")
Short_Threads_Without_Image :: struct {}

// The share policy is not checked against short threads: a process did not
// start.
@(log_fact = "scheduler: the share policy is not checked against short threads: a process did not start, or its threads did not become ready")
Short_Threads_Without_Processes :: struct {}

// The threads of a process of short threads that no round saw.
@(log_fact = "scheduler: the share policy and a process that keeps {alive} short threads alive, after one round: {checked} of its threads that no round saw, read through the machine handle, each had the weight, the weight limit and the new-thread weight limit {new_part}: {each_right}, and those of one read summed to under 1024: {sum_under}: {verdict}")
Short_Threads_Unseen :: struct {
	alive:      u64,
	checked:    u64,
	new_part:   u64,
	each_right: u64,
	sum_under:  u64,
	verdict:    [16]u8,
}

// A new-thread weight limit of the first thread above the part of a
// thread, and the new threads under it.
@(log_fact = "scheduler: under the share policy the first thread of this process got through the machine handle a new-thread weight limit of its own above {above}: {first_open}, and the process has the new-thread weight limit {process_limit}; a new thread with the weight {heavier_weight} {between_status}, and the error record names {error_limit}; a new thread with the weight 0 has the weight, the weight limit and the new-thread weight limit {child_weight}, {child_limit} and {child_new_thread_limit}: {verdict}")
Own_New_Thread_Limit :: struct {
	above:                  u64,
	first_open:             u64,
	process_limit:          u64,
	heavier_weight:         u64,
	between_status:         op.Status_Word,
	error_limit:            u64,
	child_weight:           u64,
	child_limit:            u64,
	child_new_thread_limit: u64,
	verdict:                [16]u8,
}

// A write that gives the full weight limits back was refused after the case
// of the short threads.
@(log_fact = "scheduler: after the case of the short threads, a write that gives the full weight limits back was refused")
Full_Limits_Not_Given_Back :: struct {}

#assert(size_of(Strategy_Shares_Measured) == 96 && size_of(Own_Schedule_Read) == 136)

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
@(log_fact = "scheduler: ok, no spinner starved under 3 strategies, a wake ended {eevdf_stints} stints under EEVDF and 0 under round robin, the weights ordered the shares, each thread ran after {changes} changes, 0 wakes lost, a change needs the right Schedule")
Strategies_Passed :: struct {
	eevdf_stints: u64,
	changes:      u64,
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
