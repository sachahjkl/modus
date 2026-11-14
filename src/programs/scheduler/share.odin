// A share of the processors for each program: the share policy
// (docs/SCHEDULING.md, "A share for each program").
//
// A round reads the thread report of each program and writes the weight
// and the weight limit of each thread through the machine handle: the
// program weight divided by the count of the threads of the program that
// count. So a program with many threads has the weight of a program with
// one. This file holds the round, the two exports that the principal
// calls, the programs with 1, 2, 4 and 8 spinning threads of the case, and
// the case with its measure.
package scheduler

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:support/random"
import "modus:support/system"

// The program slots that a round reads: the slot 0 holds no program.
PROGRAM_SLOT_LIMIT :: 64
// The places of the thread table of the kernel: the low half of a machine
// number is the place of its thread.
THREAD_PLACE_LIMIT :: 256
// Milliseconds between two rounds. A round is a slow path by its design:
// the kernel applies the weights at each tick, and the round only follows
// the threads that start, end and block.
POLICY_PERIOD :: 100
// The least program weight. A program has at most this many threads, so the
// weight of one thread, the program weight divided by a count of threads,
// is 1 or more, and the weights of the threads that count never sum to more
// than the program weight.
PROGRAM_WEIGHT_LEAST :: op.THREAD_REPORT_CAPACITY
PROGRAM_NAME_LIMIT :: 31 // The bytes of a program name: the name of a program report has 32, with a zero byte.
SETTING_CAPACITY :: 16

// What the policy knows of one thread, by its place in the thread table of
// the kernel.
Tracked_Thread :: struct {
	machine_number: u64, // 0: the place holds no thread that a round saw.
	virtual:        u64, // Its virtual time at the last round.
	run_time:       u64, // Its run time at the last round.
	written:        u32, // The weight that the policy wrote last. 0: the policy never wrote this thread.
	limit:          u32, // The weight limit that the policy wrote last.
	asked:          u32, // The most that the policy gives the thread: the weight that its program asked.
}

// One program of a round: a row of the window.
Program_Row :: struct {
	name:                [32]u8,
	threads:             u32, // Its threads that live.
	counted:             u32, // Its threads that count.
	weight:              u32, // The program weight.
	thread_weight_least: u32, // The least and the most weight of its threads, as the round left them.
	thread_weight_most:  u32,
	ran:                 u64, // Milliseconds of processor time since the round before.
	writes:              u64, // The writes of a schedule of this round for its threads.
}

// What one round saw and did.
Policy_Round :: struct {
	rows:       [PROGRAM_SLOT_LIMIT]Program_Row, // The programs with the most processor time first.
	count:      int,
	number:     u64, // The rounds since the start of the program.
	on:         bool, // The round wrote weights.
	elapsed:    u64, // Milliseconds since the round before.
	threads:    u64, // The threads of all the programs.
	writes:     u64, // The writes of a schedule of this round.
	duration:   u64, // Nanoseconds of this round.
}

// The program weight that the principal gave to the programs with a name.
Program_Setting :: struct {
	name:   [32]u8,
	length: int, // 0: the place is free.
	weight: u32,
}

// The lock of what the thread of the rounds and the first thread share:
// the settings and the round that the window shows.
policy_lock: system.Lock
settings: [SETTING_CAPACITY]Program_Setting
round_shown: Policy_Round
// 1: the principal wants the policy on. The thread of the rounds waits on
// this word, so a command takes effect at once.
policy_wanted: u32

// The data of the thread that runs the rounds: only one thread runs a
// round at a time (the first thread during the case, then the thread of
// the rounds).
tracked: [THREAD_PLACE_LIMIT]Tracked_Thread
policy_table: op.Thread_Table_Report
round_now: Policy_Round
settings_of_round: [SETTING_CAPACITY]Program_Setting
Slot_Before :: struct {
	serial:   u64,
	run_time: u64,
}
slots_before: [PROGRAM_SLOT_LIMIT]Slot_Before
round_time_before: u64
// The sums since the start, for the line of the cost.
ROUND_DURATIONS :: 64
round_durations: [ROUND_DURATIONS]u64
rounds_done: u64
policy_writes, policy_raises, policy_refused: u64

program_lives :: proc "contextless" (state: op.Program_State) -> bool {
	return state == .Ready || state == .Waiting
}

// policy_threads_of reads the thread report of a program slot into
// policy_table, and gives the count of its records. 0: no report, or the
// report is of another program than the one with this serial.
policy_threads_of :: proc "contextless" (slot, serial: u64) -> int {
	_, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Threads), slot, u64(uintptr(&policy_table)), size_of(policy_table))
	if status != .Ok || policy_table.program_serial != serial {
		return 0
	}
	return int(min(policy_table.count, op.THREAD_REPORT_CAPACITY))
}

// tracked_of gives the record of the policy for a thread of a report, and
// says if the round sees the thread for the first time. nil: the machine
// number names no place of the thread table.
tracked_of :: proc "contextless" (machine_number: u64) -> (thread: ^Tracked_Thread, first_sight: bool) {
	place := machine_number & 0xFFFF_FFFF
	if place >= THREAD_PLACE_LIMIT {
		return nil, false
	}
	thread = &tracked[place]
	if thread.machine_number != machine_number {
		thread^ = {machine_number = machine_number}
		return thread, true
	}
	return thread, false
}

// asked_of gives the weight that the program of a thread asked, from a
// schedule that the policy never wrote: a weight under its limit is a
// weight that the program chose. A weight at its limit is the most that
// the thread can have, which is what a thread created with the weight 0
// gets: it asked for no smaller part.
asked_of :: proc "contextless" (schedule: op.Thread_Schedule) -> u32 {
	return schedule.weight < schedule.weight_limit ? schedule.weight : op.WEIGHT_FULL
}

// setting_weight gives the program weight of a name in a table of settings.
setting_weight :: proc "contextless" (table: ^[SETTING_CAPACITY]Program_Setting, name: string) -> u32 {
	for &setting in table {
		if setting.length != 0 && string(setting.name[:setting.length]) == name {
			return setting.weight
		}
	}
	return op.WEIGHT_FULL
}

// thread_weight_write gives a thread the weight and the weight limit of
// its part, never above what its program asked. It reads the schedule
// first: a write through the machine handle gives the three values, and
// the request must stay. It writes only a value that changes: a write that
// raises starts the thread again as a new thread.
thread_weight_write :: proc "contextless" (thread: ^Tracked_Thread, part: u32) -> (weight: u32) {
	schedule, read_status := system.thread_schedule_read(machine, thread.machine_number)
	if read_status != .Ok {
		// The thread ended since the report.
		return 0
	}
	if thread.written == 0 {
		thread.asked = asked_of(schedule)
	} else if schedule.weight < thread.written {
		// The program lowered the weight after the last write: it keeps it.
		thread.asked = schedule.weight
	}
	wanted := min(part, thread.asked)
	if schedule.weight != wanted || schedule.weight_limit != part {
		status := system.thread_schedule_write(machine, thread.machine_number, {weight = wanted, request = schedule.request, weight_limit = part})
		switch {
		case status == .Ok:
			round_now.writes += 1
			policy_writes += 1
			policy_raises += u64(wanted > schedule.weight)
		case status == .Bad_State:
			return 0 // It ended between the read and the write.
		case:
			policy_refused += 1
			return schedule.weight
		}
	}
	thread.written, thread.limit = wanted, part
	return wanted
}

// policy_round reads each program and its threads, and, when on, writes
// the weight of each thread. It then gives the round to the window.
//
// A thread counts when the round sees it for the first time, when it is
// ready, or when its run time or its virtual time changed since the last
// round. The run time counts ticks, so a thread that runs only between two
// ticks never changes it; its virtual time changes at each charge. A
// thread that counts gets the program weight divided by the threads that
// count; another thread gets the program weight divided by all the threads
// of the program. A thread that wakes after a long wait so adds less than
// one program weight, for one period at most, and the period after it the
// program has less than its weight by the same amount.
policy_round :: proc "contextless" (on: bool) {
	start := system.nanoseconds()
	now := system.time()
	system.lock(&policy_lock)
	settings_of_round = settings
	system.unlock(&policy_lock)
	rounds_done += 1
	round_now = {number = rounds_done, on = on, elapsed = max(now - round_time_before, 1)}
	round_time_before = now
	for slot in u64(1) ..< PROGRAM_SLOT_LIMIT {
		report, status := program_report(slot)
		if status != .Ok || !program_lives(report.state) {
			slots_before[slot] = {}
			continue
		}
		count := policy_threads_of(slot, report.program_serial)
		counted_now: [op.THREAD_REPORT_CAPACITY]bool
		records: [op.THREAD_REPORT_CAPACITY]^Tracked_Thread
		row := Program_Row{name = report.name, weight = setting_weight(&settings_of_round, system.name_of(report.name[:]))}
		for index in 0 ..< count {
			item := &policy_table.threads[index]
			if !program_lives(item.state) {
				continue
			}
			row.threads += 1
			thread, first_sight := tracked_of(item.machine_number)
			if thread == nil {
				continue
			}
			records[index] = thread
			counted_now[index] = first_sight || item.state == .Ready || item.processor != 0 || item.queued != 0 || item.run_time != thread.run_time || item.virtual != thread.virtual
			thread.run_time, thread.virtual = item.run_time, item.virtual
			row.counted += u32(counted_now[index])
			// A weight under the weight that the policy wrote: the program
			// lowered it.
			if thread.written != 0 && item.weight < thread.written {
				thread.asked = item.weight
			}
		}
		if row.threads == 0 {
			slots_before[slot] = {}
			continue
		}
		part_counted := max(row.weight / max(row.counted, 1), 1)
		part_other := max(row.weight / row.threads, 1)
		row.thread_weight_least = op.WEIGHT_FULL
		writes_before := round_now.writes
		for index in 0 ..< count {
			thread := records[index]
			if thread == nil {
				continue
			}
			weight := policy_table.threads[index].weight
			if on {
				part := counted_now[index] ? part_counted : part_other
				// The report gives the weight; only the policy writes a
				// limit, so its own record gives the limit.
				if thread.written == 0 || weight != min(part, thread.asked) || thread.limit != part {
					if written := thread_weight_write(thread, part); written != 0 {
						weight = written
					}
				}
			}
			row.thread_weight_least = min(row.thread_weight_least, weight)
			row.thread_weight_most = max(row.thread_weight_most, weight)
		}
		row.writes = round_now.writes - writes_before
		if slots_before[slot].serial == report.program_serial {
			row.ran = report.run_time - slots_before[slot].run_time
		}
		slots_before[slot] = {serial = report.program_serial, run_time = report.run_time}
		round_now.threads += u64(row.threads)
		// The programs with the most processor time first: the window shows
		// the first rows when it has less room than programs.
		at := round_now.count
		for at > 0 && round_now.rows[at - 1].ran < row.ran {
			round_now.rows[at] = round_now.rows[at - 1]
			at -= 1
		}
		round_now.rows[at] = row
		round_now.count += 1
	}
	round_now.duration = system.nanoseconds() - start
	round_durations[(rounds_done - 1) % ROUND_DURATIONS] = round_now.duration
	system.lock(&policy_lock)
	round_shown = round_now
	system.unlock(&policy_lock)
}

// policy_weights_give_back gives each thread of the machine that is under a
// weight limit the weight that its program asked, and the full weight
// limit. Only the policy writes a limit, so a limit under the full weight
// is a limit of the policy: of this program, or of a program `scheduler`
// that ran before it and was stopped with the policy on. A thread that a
// program creates during the pass gets the limit of its creator, so the
// passes go on until one writes nothing. false: a write was refused, or a
// thread was still under a limit after the last pass.
POLICY_GIVE_BACK_PASSES :: 4

policy_weights_give_back :: proc "contextless" () -> bool {
	for _ in 0 ..< POLICY_GIVE_BACK_PASSES {
		written, refused: u64
		for slot in u64(1) ..< PROGRAM_SLOT_LIMIT {
			report, status := program_report(slot)
			if status != .Ok || !program_lives(report.state) {
				continue
			}
			count := policy_threads_of(slot, report.program_serial)
			for index in 0 ..< count {
				item := &policy_table.threads[index]
				if !program_lives(item.state) {
					continue
				}
				schedule, read_status := system.thread_schedule_read(machine, item.machine_number)
				if read_status != .Ok || schedule.weight_limit == op.WEIGHT_FULL {
					continue
				}
				asked := asked_of(schedule)
				if thread, first_sight := tracked_of(item.machine_number); thread != nil && !first_sight && thread.written != 0 {
					asked = schedule.weight < thread.written ? schedule.weight : thread.asked
				}
				switch system.thread_schedule_write(machine, item.machine_number, {weight = asked, request = schedule.request, weight_limit = op.WEIGHT_FULL}) {
				case .Ok:
					written += 1
				case .Bad_State:
				// The thread ended.
				case:
					refused += 1
				}
			}
		}
		if refused != 0 {
			return false
		}
		if written == 0 {
			tracked = {}
			return true
		}
	}
	tracked = {}
	return false
}

// policy_run is the thread of the rounds: one round each period, by the
// clock of the system. It waits on the word of the command, so a command
// of the principal starts a round at once. When the policy goes off, each
// thread gets its weight back before the next round.
policy_run :: proc "c" (parameter: rawptr) -> ! {
	was_on := false
	for {
		on := intrinsics.atomic_load(&policy_wanted) != 0
		if was_on && !on {
			policy_weights_give_back()
			system.log("scheduler: the share policy is off: each thread has the weight that its program asked and the full weight limit")
		}
		if on && !was_on {
			system.log("scheduler: the share policy is on: each program has its program weight, divided between its threads that count, one round each ", u64(POLICY_PERIOD), " ms")
		}
		policy_round(on)
		was_on = on
		system.word_wait(&policy_wanted, u32(on), system.time() + POLICY_PERIOD)
	}
}

// policy_set turns the policy on or off for the thread of the rounds, and
// gives what it was.
policy_set :: proc "contextless" (on: bool) -> (before: bool) {
	before = intrinsics.atomic_exchange(&policy_wanted, u32(on)) != 0
	system.word_wake(&policy_wanted)
	return before
}

// acts_for_principal says if the caller of the export that runs acts for
// the principal of its session: the root service wrote that in the grant
// of its connection, and the caller cannot choose it. The two exports
// change the part of each program of the machine, so a program that only
// has a connection must not call them.
@(private = "file")
acts_for_principal :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller == nil || caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
}

// share sets the program weight of the programs with a name: the part of
// the processors that the share policy gives them, against the other
// programs.
//
// The policy divides the program weight between the threads of the program
// that count, so a program with 8 threads and a program with 1 thread of
// the same program weight have the same weight in all. The setting holds
// for each program with that name, also one that starts later, until the
// program `scheduler` stops. It has an effect while the policy is on
// ([policy](scheduler.policy)), under the fair strategy and EEVDF: the
// round robin reads no weight.
//
// - **name**: the name of the programs, 31 bytes at most.
// - **weight**: the program weight, from 32 to 1024. 1024 is the weight of
//   a program with no setting. A program has at most 32 threads, so 32 is
//   the least weight that gives each thread a weight of 1 or more.
//
// The result is the program weight that the name had. It fails with -1 and
// an error record, and no setting changes:
//
// - `No_Grant`: the caller does not act for the principal;
// - `Empty`: the name has no byte;
// - `Too_Long`: the name has more than 31 bytes;
// - `Too_Small`: the weight is under 32;
// - `Bad_Value`: the weight is above 1024;
// - `Full`: 16 names have a setting.
//
// Example: `scheduler.share("paint", 256)` gives the program `paint` a
// quarter of the weight of another program.
@(export, link_name = "share")
share :: proc "c" (name: ^string, weight: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, -1, .No_Grant, .Acts_For_Principal)
	}
	if len(name) == 0 {
		return errors.fail(error, -1, .Empty, .Bytes, 1, 0, PROGRAM_NAME_LIMIT)
	}
	if len(name) > PROGRAM_NAME_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Bytes, 1, i64(len(name)), PROGRAM_NAME_LIMIT)
	}
	if weight < PROGRAM_WEIGHT_LEAST {
		return errors.fail(error, -1, .Too_Small, .None, 2, weight, PROGRAM_WEIGHT_LEAST)
	}
	if weight > op.WEIGHT_FULL {
		return errors.fail(error, -1, .Bad_Value, .None, 2, weight, op.WEIGHT_FULL)
	}
	system.lock(&policy_lock)
	defer system.unlock(&policy_lock)
	found, free: ^Program_Setting
	for &setting in settings {
		switch {
		case setting.length == 0:
			if free == nil {
				free = &setting
			}
		case string(setting.name[:setting.length]) == name^:
			found = &setting
		}
	}
	before := i64(op.WEIGHT_FULL)
	if found != nil {
		before = i64(found.weight)
	}
	switch {
	case weight == op.WEIGHT_FULL:
		// The weight of a program with no setting: the place is free again.
		if found != nil {
			found^ = {}
		}
	case found != nil:
		found.weight = u32(weight)
	case free != nil:
		free.length = len(name)
		for index in 0 ..< len(name) {
			free.name[index] = name[index]
		}
		free.weight = u32(weight)
	case:
		return errors.fail(error, -1, .Full, .None, 1, 0, SETTING_CAPACITY)
	}
	return before
}

// policy turns the share policy on or off.
//
// With the policy on, the program `scheduler` reads the threads of each
// program each 100 ms, and writes the weight of each thread: the program
// weight ([share](scheduler.share)) divided by the count of the threads of
// the program that are ready or that ran since the last round. It never
// gives a thread more than its program asked. With the policy off, each
// thread gets back the weight that its program asked and the full weight
// limit. The policy is off when the program starts.
//
// - **on**: 1 turns the policy on, 0 turns it off.
//
// The result is 1 when the policy was on before the call, else 0. It fails
// with -1 and an error record:
//
// - `No_Grant`: the caller does not act for the principal;
// - `Bad_Value`: on is not 0 or 1.
//
// Example: `scheduler.policy(1)`.
@(export, link_name = "policy")
policy :: proc "c" (on: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, -1, .No_Grant, .Acts_For_Principal)
	}
	if on != 0 && on != 1 {
		return errors.fail(error, -1, .Bad_Value, .None, 1, on, 1)
	}
	return i64(policy_set(on == 1))
}

// The programs of the case: four programs of the file of this program,
// with 1, 2, 4 and 8 threads that compute with no end. The value of the
// context that gives the role has a tag in its high half, so that a value
// of another starter is not a role, and the count of the threads in its
// low half.
SHARE_PROGRAM_COUNT :: 4
SHARE_VALUE_ROLE :: 5
SHARE_ROLE_TAG :: u64(0x5348_4152_0000_0000) // "SHAR"

@(rodata)
share_thread_counts := [SHARE_PROGRAM_COUNT]u64{1, 2, 4, 8}
@(rodata)
share_program_names := [SHARE_PROGRAM_COUNT]string{"spinner_1", "spinner_2", "spinner_4", "spinner_8"}

// share_role_threads gives the count of the threads of a program of the
// case from the value of its context. 0: the program is not one of them.
share_role_threads :: proc "contextless" (value: u64) -> u64 {
	count := value & 0xFFFF_FFFF
	if value & 0xFFFF_FFFF_0000_0000 != SHARE_ROLE_TAG || count == 0 || count > op.THREAD_REPORT_CAPACITY {
		return 0
	}
	return count
}

share_spin_count: [op.THREAD_REPORT_CAPACITY]Spinner

share_spin :: proc "c" (parameter: rawptr) -> ! {
	spinner := (^Spinner)(parameter)
	for {
		intrinsics.volatile_store(&spinner.count, intrinsics.volatile_load(&spinner.count) + 1)
	}
}

// share_program_run is the whole of a program of the case: threads that
// compute until the program that started it stops it.
share_program_run :: proc "contextless" (threads: u64) -> ! {
	for index in 1 ..< threads {
		// A thread that does not start is one spinner less: the case reads
		// the count of the ready threads, and says so.
		_, _ = system.thread_start(share_spin, &share_spin_count[index])
	}
	share_spin(&share_spin_count[0])
}

// What a program of the case asks of the budget of this program. pages:
// its copy of the data of the module and of the module that it imports,
// its stack, its context and its page tables, with room; then a stack of
// 16 pages and a thread area of 3 for each thread more. processor: one
// processor for each thread, so that its budget never stops it. It has no
// handle of this program and writes no log record.
share_program_amounts :: proc "contextless" (threads: u64) -> system.Budget_Amounts {
	return {pages = 512 + threads * (system.THREAD_STACK_PAGES + 3), programs = 1, threads = threads, processor = threads * 1_000_000, log_records = 0}
}

program_generator: random.Generator
image: []u8 // The boot image: the file of this program is in it.

Share_Program :: struct {
	program: system.Handle,
	slot:    u64,
	serial:  u64,
}

share_programs: [SHARE_PROGRAM_COUNT]Share_Program

// share_programs_start starts the four programs and finds the slot of
// each one by its name. It then waits until the thread report of each one
// shows each of its threads ready: a state of the kernel, and the time
// only ends a hang. false: a program did not start, or its threads did not
// all become ready.
share_programs_start :: proc "contextless" () -> bool {
	file := system.image_find(image, "scheduler")
	for &started, index in share_programs {
		grants: [op.CONTEXT_HANDLES]system.Grant
		values: [op.CONTEXT_VALUES]u64
		values[SHARE_VALUE_ROLE] = SHARE_ROLE_TAG | share_thread_counts[index]
		amounts := share_program_amounts(share_thread_counts[index])
		error: module.Load_Error
		status: system.Status
		started.program, status = system.program_start(file, share_program_names[index], grants, random.values_with_seed(&program_generator, values), amounts, nil, nil, {image = image}, &error)
		if status != .Ok {
			buffer: [384]u8
			lines := system.Writer{buffer = buffer[:]}
			system.load_error_text(&lines, &error)
			own, _ := system.budget_read()
			system.log("scheduler: the program ", share_program_names[index], " did not start: ", op.STATUS_NAMES[status], "; the load: ", system.written(&lines), "; this program can give pages ", own.pages, ", programs ", own.programs, ", threads ", own.threads, "; the program asks pages ", amounts.pages, ", threads ", amounts.threads)
			return false
		}
	}
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for &started, index in share_programs {
		for started.slot == 0 && system.time() < deadline {
			for slot in u64(1) ..< PROGRAM_SLOT_LIMIT {
				report, status := program_report(slot)
				if status == .Ok && program_lives(report.state) && system.name_of(report.name[:]) == share_program_names[index] {
					started.slot, started.serial = slot, report.program_serial
				}
			}
			if started.slot == 0 {
				system.sleep(system.time() + 1)
			}
		}
		ready := false
		for started.slot != 0 && !ready && system.time() < deadline {
			count := policy_threads_of(started.slot, started.serial)
			ready_count: u64
			for &item in policy_table.threads[:count] {
				ready_count += u64(item.state == .Ready)
			}
			ready = ready_count == share_thread_counts[index]
			if !ready {
				system.sleep(system.time() + 1)
			}
		}
		if !ready {
			return false
		}
	}
	return true
}

share_programs_stop :: proc "contextless" () {
	for &started in share_programs {
		if started.program != 0 {
			system.call(.Program_Stop, u64(started.program), 0)
			system.close(started.program)
		}
		started = {}
	}
}

// What the schedules of the threads of one program are, read through the
// machine handle.
Program_Weights :: struct {
	threads:    u64, // The threads that live.
	sum:        u64, // The sum of their weights.
	least:      u32,
	most:       u32,
	limit_least: u32, // The least and the most of their weight limits.
	limit_most:  u32,
}

program_weights :: proc "contextless" (slot, serial: u64) -> (weights: Program_Weights) {
	weights.least, weights.limit_least = op.WEIGHT_FULL, op.WEIGHT_FULL
	count := policy_threads_of(slot, serial)
	for index in 0 ..< count {
		item := &policy_table.threads[index]
		if !program_lives(item.state) {
			continue
		}
		schedule, status := system.thread_schedule_read(machine, item.machine_number)
		if status != .Ok {
			continue
		}
		weights.threads += 1
		weights.sum += u64(schedule.weight)
		weights.least, weights.most = min(weights.least, schedule.weight), max(weights.most, schedule.weight)
		weights.limit_least, weights.limit_most = min(weights.limit_least, schedule.weight_limit), max(weights.limit_most, schedule.weight_limit)
	}
	return weights
}

// The milliseconds of the interval of a measure run: long against the lag
// bound of a thread, which is two requests of 3 ms.
SHARE_PROGRAMS_TIME :: 1000

// share_programs_interval gives the ticks of processor time of each of the
// four programs over one interval, from the program reports. In the check
// the interval ends when each program ran SHARE_TICKS_CHECKED ticks: a
// count of the kernel, so a slow host makes the interval longer and leaves
// the counts. A measure run has an interval of SHARE_PROGRAMS_TIME. The
// rounds of the policy go on during the interval, one each period. false:
// the hang bound ended the interval, or a report was not of the program.
share_programs_interval :: proc "contextless" (on: bool) -> (parts: [SHARE_PROGRAM_COUNT]u64, each_ran: bool) {
	base: [SHARE_PROGRAM_COUNT]u64
	for &started, index in share_programs {
		report, status := program_report(started.slot)
		if status != .Ok || report.program_serial != started.serial {
			return parts, false
		}
		base[index] = report.run_time
	}
	start := system.time()
	next_round := start + POLICY_PERIOD
	measured := system.measure_run()
	for deadline := start + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		system.sleep(system.time() + SHARE_POLL_TIME)
		if system.time() >= next_round {
			policy_round(on)
			next_round = system.time() + POLICY_PERIOD
		}
		each_ran = true
		for &started, index in share_programs {
			report, status := program_report(started.slot)
			if status != .Ok || report.program_serial != started.serial {
				return parts, false
			}
			parts[index] = report.run_time - base[index]
			each_ran &&= parts[index] >= SHARE_TICKS_CHECKED
		}
		if measured {
			each_ran &&= system.time() - start >= SHARE_PROGRAMS_TIME
		}
		if each_ran {
			break
		}
	}
	return parts, each_ran
}

weight_of_lowered :: proc "contextless" (index: int) -> u64 {
	return SHARE_WEIGHT_ASKED
}

// The weight that a thread of this program asks at its creation, and the
// weight that it lowers itself to, in the case.
SHARE_WEIGHT_ASKED :: 100
SHARE_WEIGHT_LOWERED :: 50
// The threads that this program then starts: with its first thread and the
// thread that lowered itself, it has 9 threads that count.
SHARE_THREADS_MORE :: 7

shares_part :: proc "contextless" (writer: ^system.Writer, parts: [SHARE_PROGRAM_COUNT]u64) {
	total: u64
	for part in parts {
		total += part
	}
	for part, index in parts {
		system.write_part(writer, index == 0 ? " " : ", ")
		tenths_part(writer, share_tenths(part, total))
	}
}

// share_case checks the share policy on four programs with 1, 2, 4 and 8
// spinning threads, under EEVDF, and prints the shares.
//
// The conditions are values that the kernel gives back, with no time: the
// weight and the weight limit of each thread after a round; their sum for
// each program; the weight of a thread of this program that asked 100 and
// then lowered itself to 50; the weights of this program after it started
// 7 threads more; the weights after the policy went off. One condition is
// an order of counts of ticks: the part of the program with 8 threads
// against the program with 1 is smaller with the policy than without it.
// The shares themselves are measures: the balance between the queues
// counts threads and not weights, so no bound of a share follows from the
// weights.
share_case :: proc "contextless" () -> bool {
	if image == nil || self_slot == 0 {
		system.log("scheduler: the share policy is not checked: no boot image, or the program did not find its own threads")
		return false
	}
	before, set_status := system.strategy_set(machine, .Eevdf)
	if set_status != .Ok {
		return false
	}
	defer system.strategy_set(machine, before)
	defer share_programs_stop()
	if !share_programs_start() {
		system.log("scheduler: the share policy is not checked: a program with spinning threads did not start, or its threads did not become ready")
		return false
	}

	// Without the policy: the rounds only read.
	policy_round(false)
	without, without_ran := share_programs_interval(false)

	// With the policy. Two rounds: the second one finds each weight as the
	// first one left it.
	policy_round(true)
	policy_round(true)
	policy_round(true)
	// The third round wrote no thread of the four programs: their threads
	// did not start, end or block, so no weight changed. The other programs
	// of the machine can change between two rounds.
	steady := true
	for &row in round_now.rows[:round_now.count] {
		for name in share_program_names {
			if system.name_of(row.name[:]) == name {
				steady &&= row.writes == 0
			}
		}
	}
	weights: [SHARE_PROGRAM_COUNT]Program_Weights
	weights_right := true
	for &started, index in share_programs {
		weights[index] = program_weights(started.slot, started.serial)
		part := u32(op.WEIGHT_FULL / share_thread_counts[index])
		weights_right &&= weights[index].threads == share_thread_counts[index] && weights[index].least == part && weights[index].most == part
		weights_right &&= weights[index].limit_least == part && weights[index].limit_most == part && weights[index].sum <= op.WEIGHT_FULL
	}
	system.log("scheduler: the share policy, three rounds: each thread of the programs with 1, 2, 4 and 8 spinning threads has the weight and the weight limit ", u64(weights[0].most), ", ", u64(weights[1].most), ", ", u64(weights[2].most), " and ", u64(weights[3].most), "; the weights of each program sum to ", weights[0].sum, ", ", weights[1].sum, ", ", weights[2].sum, " and ", weights[3].sum, "; the third round wrote none of their threads: ", u64(steady), weights_right && steady ? string(": as it must") : string(": WRONG"))
	with, with_ran := share_programs_interval(true)

	// A program that asks less keeps it, and a program that starts threads
	// gets no more: this program is the example.
	numbers: [SPINNER_LIMIT]u64
	kept_right := spinners_start(0, 1, weight_of_lowered) && spinner_machine_numbers(0, 1, &numbers)
	asked, lowered: op.Thread_Schedule
	own: Program_Weights
	if kept_right {
		policy_round(true)
		asked, _ = system.thread_schedule_read(machine, numbers[0])
		lower_status := system.thread_schedule_write(spinner_threads[0].handle, 0, {weight = SHARE_WEIGHT_LOWERED})
		policy_round(true)
		lowered, _ = system.thread_schedule_read(machine, numbers[0])
		kept_right = lower_status == .Ok && asked.weight == SHARE_WEIGHT_ASKED && lowered.weight == SHARE_WEIGHT_LOWERED
		kept_right &&= spinners_start(1, SHARE_THREADS_MORE, full_weight) && spinner_machine_numbers(1, SHARE_THREADS_MORE, &numbers)
		policy_round(true)
		own = program_weights(self_slot, self_serial)
		part := u32(op.WEIGHT_FULL / (SHARE_THREADS_MORE + 2))
		kept_right &&= own.threads == SHARE_THREADS_MORE + 2 && own.least == SHARE_WEIGHT_LOWERED && own.most == part
		kept_right &&= own.sum == u64(part) * (SHARE_THREADS_MORE + 1) + SHARE_WEIGHT_LOWERED && own.sum <= op.WEIGHT_FULL
	}
	system.log("scheduler: under the share policy, a thread of this program created with the weight ", u64(SHARE_WEIGHT_ASKED), " has the weight ", u64(asked.weight), ", and the weight ", u64(lowered.weight), " after it lowered itself to ", u64(SHARE_WEIGHT_LOWERED), "; after this program started ", u64(SHARE_THREADS_MORE), " threads more, its ", own.threads, " threads have the weights ", u64(own.least), " to ", u64(own.most), ", which sum to ", own.sum, " of 1024", kept_right ? string(": as it must") : string(": WRONG"))

	// The policy goes off: each thread has the weight that its program
	// asked, and the full weight limit.
	given_back := policy_weights_give_back()
	lowered_after, _ := system.thread_schedule_read(machine, numbers[0])
	first_after, _ := system.thread_schedule_read(machine, self_machine_number)
	back_right := given_back && policy_refused == 0
	back_right &&= lowered_after.weight == SHARE_WEIGHT_LOWERED && lowered_after.weight_limit == op.WEIGHT_FULL
	back_right &&= first_after.weight == op.WEIGHT_FULL && first_after.weight_limit == op.WEIGHT_FULL
	for &started, index in share_programs {
		after := program_weights(started.slot, started.serial)
		back_right &&= after.threads == share_thread_counts[index] && after.least == op.WEIGHT_FULL && after.limit_least == op.WEIGHT_FULL
	}
	spinners_stop(0, SHARE_THREADS_MORE + 1)
	system.log("scheduler: the share policy off: each thread of the 4 programs and the first thread of this program have the weight 1024 and the full weight limit again, the thread that lowered itself has the weight ", u64(lowered_after.weight), " and the full weight limit, and no write of the policy was refused: ", u64(policy_refused == 0), back_right ? string(": as it must") : string(": WRONG"))

	// The order: the part of the program with 8 threads against the program
	// with 1, with the policy and without it. Each part is a count of
	// ticks of the kernel over one interval.
	last :: SHARE_PROGRAM_COUNT - 1
	order_right := without_ran && with_ran && with[last] * without[0] < without[last] * with[0]
	system.log("scheduler: the program with 8 spinning threads against the program with 1, by the ticks of the kernel over one interval: its part is smaller under the share policy than without it", order_right ? string(": as it must") : string(": WRONG"))

	buffer: [800]u8
	writer := system.Writer{buffer = buffer[:]}
	system.write_part(&writer, "scheduler: shares of the programs with 1, 2, 4 and 8 spinning threads under EEVDF, by the ticks of the kernel: without the share policy")
	shares_part(&writer, without)
	system.write_part(&writer, "; with it")
	shares_part(&writer, with)
	system.write_part(&writer, "; the program with 8 threads got ")
	system.write_unsigned(&writer, without[last] * 100 / max(without[0], 1))
	system.write_part(&writer, " % of the program with 1 thread without the policy, and ")
	system.write_unsigned(&writer, with[last] * 100 / max(with[0], 1))
	system.write_part(&writer, " % with it (measures)")
	log_whole(system.written(&writer))

	sorted := round_durations
	rounds := int(min(rounds_done, ROUND_DURATIONS))
	for at in 1 ..< rounds {
		for back := at; back > 0 && sorted[back - 1] > sorted[back]; back -= 1 {
			sorted[back - 1], sorted[back] = sorted[back], sorted[back - 1]
		}
	}
	system.log("scheduler: one round of the share policy, over ", u64(round_now.count), " programs and ", round_now.threads, " threads: ", sorted[rounds / 2], " ns in the middle of ", u64(rounds), " rounds; ", policy_writes, " writes of a schedule in all, ", policy_raises, " of them raised a weight; the period of the rounds is ", u64(POLICY_PERIOD), " ms (measures)")
	return weights_right && steady && kept_right && back_right && order_right
}
