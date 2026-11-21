// A share of the processors for each process: the share policy
// (docs/SCHEDULING.md, "A share for each process").
//
// A round reads the thread report of each process and writes the weight
// and the weight limit of each thread through the machine handle: the
// process weight divided by the count of the threads of the process that
// count. So a process with many threads has the weight of a process with
// one. It also writes the new-thread weight limit of each thread: the
// process weight divided by the most threads of a process, so the threads
// that a process creates between two rounds sum to under one process
// weight. This file holds the round, the two exports that the principal
// calls, the processes of the cases, and the cases with their measure.
package scheduler

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:random"
import "modus:system"

// The process slots that a round reads: the slot 0 holds no process.
PROCESS_SLOT_LIMIT :: 64
// The places of the thread table of the kernel: the low half of a machine
// number is the place of its thread.
THREAD_PLACE_LIMIT :: 256
// Milliseconds between two rounds. A round is a slow path by its design:
// the kernel applies the weights at each tick, and the round only follows
// the threads that start, end and block.
POLICY_PERIOD :: 100
// The least process weight. A process has at most this many threads, so the
// weight of one thread, the process weight divided by a count of threads,
// is 1 or more, and the weights of the threads that count never sum to more
// than the process weight.
PROCESS_WEIGHT_LEAST :: op.THREAD_REPORT_CAPACITY
// The process weight is divided by this count for the new-thread weight
// limit: a process has at most this many threads, so the threads that no
// round saw never sum to a whole process weight, whatever the moments of
// their creation.
PROCESS_THREADS_MOST :: op.THREAD_CAPACITY
#assert(PROCESS_THREADS_MOST <= PROCESS_WEIGHT_LEAST)
PROCESS_NAME_LIMIT :: 31 // The bytes of a process name: the name of a process report has 32, with a zero byte.
SETTING_CAPACITY :: 16

// What the policy knows of one thread, by its place in the thread table of
// the kernel.
Tracked_Thread :: struct {
	machine_number: u64, // 0: the place holds no thread that a round saw.
	virtual:        u64, // Its virtual time at the last round.
	run_time:       u64, // Its run time at the last round.
	written:        u32, // The weight that the policy wrote last. 0: the policy never wrote this thread.
	limit:          u32, // The weight limit that the policy wrote last.
	new_thread_limit: u32, // The new-thread weight limit that the policy wrote last.
	asked:          u32, // The most that the policy gives the thread: the weight that its process asked.
}

// new_thread_part gives the new-thread weight limit of each thread of a
// process with this process weight: 1 or more, because the least process
// weight is the most threads of a process.
new_thread_part :: proc "contextless" (process_weight: u32) -> u32 {
	return max(process_weight / PROCESS_THREADS_MOST, 1)
}

// One process of a round: a row of the window.
Process_Row :: struct {
	name:                [32]u8,
	threads:             u32, // Its threads that live.
	counted:             u32, // Its threads that count.
	weight:              u32, // The process weight.
	thread_weight_least: u32, // The least and the most weight of its threads, as the round left them.
	thread_weight_most:  u32,
	ran:                 u64, // Milliseconds of processor time since the round before.
	writes:              u64, // The writes of a schedule of this round for its threads.
}

// What one round saw and did.
Policy_Round :: struct {
	rows:       [PROCESS_SLOT_LIMIT]Process_Row, // The processes with the most processor time first.
	count:      int,
	number:     u64, // The rounds since the start of the process.
	on:         bool, // The round wrote weights.
	elapsed:    u64, // Milliseconds since the round before.
	threads:    u64, // The threads of all the processes.
	writes:     u64, // The writes of a schedule of this round.
	duration:   u64, // Nanoseconds of this round.
}

// The process weight that the principal gave to the processes with a name.
Process_Setting :: struct {
	name:   [32]u8,
	length: int, // 0: the place is free.
	weight: u32,
}

// The lock of what the thread of the rounds and the first thread share:
// the settings and the round that the window shows.
policy_lock: system.Lock
settings: [SETTING_CAPACITY]Process_Setting
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
settings_of_round: [SETTING_CAPACITY]Process_Setting
Slot_Before :: struct {
	serial:   u64,
	run_time: u64,
}
slots_before: [PROCESS_SLOT_LIMIT]Slot_Before
round_time_before: u64
// The sums since the start, for the line of the cost.
ROUND_DURATIONS :: 64
round_durations: [ROUND_DURATIONS]u64
rounds_done: u64
policy_writes, policy_raises, policy_refused: u64

process_lives :: proc "contextless" (state: op.Process_State) -> bool {
	return state == .Ready || state == .Waiting
}

// policy_threads_of reads the thread report of a process slot into
// policy_table, and gives the count of its records. 0: no report, or the
// report is of another process than the one with this serial.
policy_threads_of :: proc "contextless" (slot, serial: u64) -> int {
	_, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Threads), slot, u64(uintptr(&policy_table)), size_of(policy_table))
	if status != .Ok || policy_table.process_serial != serial {
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

// asked_of gives the weight that the process of a thread asked, from a
// schedule that the policy never wrote: a weight under its limit is a
// weight that the process chose. A weight at its limit is the most that
// the thread can have, which is what a thread created with the weight 0
// gets: it asked for no smaller part.
asked_of :: proc "contextless" (schedule: op.Thread_Schedule) -> u32 {
	return schedule.weight < schedule.weight_limit ? schedule.weight : op.WEIGHT_FULL
}

// setting_weight gives the process weight of a name in a table of settings.
setting_weight :: proc "contextless" (table: ^[SETTING_CAPACITY]Process_Setting, name: string) -> u32 {
	for &setting in table {
		if setting.length != 0 && string(setting.name[:setting.length]) == name {
			return setting.weight
		}
	}
	return op.WEIGHT_FULL
}

// thread_weight_write gives a thread the weight and the weight limit of
// its part, never above what its process asked, and the new-thread weight
// limit of its process. It reads the schedule first: a write through the
// machine handle gives the four values, and the request must stay. It
// writes only a value that changes: a write that raises starts the thread
// again as a new thread.
thread_weight_write :: proc "contextless" (thread: ^Tracked_Thread, part, new_thread_limit: u32) -> (weight: u32) {
	schedule, read_status := system.thread_schedule_read(machine, thread.machine_number)
	if read_status != .Ok {
		// The thread ended since the report.
		return 0
	}
	if thread.written == 0 {
		thread.asked = asked_of(schedule)
	} else if schedule.weight < thread.written {
		// The process lowered the weight after the last write: it keeps it.
		thread.asked = schedule.weight
	}
	wanted := min(part, thread.asked)
	// The kernel keeps the new-thread weight limit at or under the weight
	// limit, so the record that the round compares holds the same value.
	new_limit := min(new_thread_limit, part)
	if schedule.weight != wanted || schedule.weight_limit != part || schedule.new_thread_weight_limit != new_limit {
		status := system.thread_schedule_write(machine, thread.machine_number, {weight = wanted, request = schedule.request, weight_limit = part, new_thread_weight_limit = new_limit})
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
	thread.written, thread.limit, thread.new_thread_limit = wanted, part, new_limit
	return wanted
}

// policy_round reads each process and its threads, and, when on, writes
// the weight of each thread. It then gives the round to the window.
//
// A thread counts when the round sees it for the first time, when it is
// ready, or when its run time or its virtual time changed since the last
// round. The run time counts ticks, so a thread that runs only between two
// ticks never changes it; its virtual time changes at each charge. A
// thread that counts gets the process weight divided by the threads that
// count; another thread gets the process weight divided by all the threads
// of the process. A thread that wakes after a long wait so adds less than
// one process weight, for one period at most, and the period after it the
// process has less than its weight by the same amount. Each process, and
// each of its threads, gets the new-thread weight limit of the process,
// the value of the process before the report is read: a thread that the
// process creates before the next round has that weight, which the kernel
// fixes at the creation, so the moments of the creations give the process
// nothing.
policy_round :: proc "contextless" (on: bool) {
	start := system.nanoseconds()
	now := system.time()
	system.lock(&policy_lock)
	settings_of_round = settings
	system.unlock(&policy_lock)
	rounds_done += 1
	round_now = {number = rounds_done, on = on, elapsed = max(now - round_time_before, 1)}
	round_time_before = now
	for slot in u64(1) ..< PROCESS_SLOT_LIMIT {
		report, status := process_report(slot)
		if status != .Ok || !process_lives(report.state) {
			slots_before[slot] = {}
			continue
		}
		process_weight := setting_weight(&settings_of_round, system.name_of(report.name[:]))
		// The value of the process first, then the report: a thread that
		// the process creates after this write has the small value, and a
		// thread that it created before is in the report. So no thread of
		// the process escapes the round, also one that a thread creates
		// just before the policy writes that thread.
		if on {
			process_limit_write(slot, report.process_serial, new_thread_part(process_weight))
		}
		count := policy_threads_of(slot, report.process_serial)
		counted_now: [op.THREAD_REPORT_CAPACITY]bool
		records: [op.THREAD_REPORT_CAPACITY]^Tracked_Thread
		row := Process_Row{name = report.name, weight = process_weight}
		for index in 0 ..< count {
			item := &policy_table.threads[index]
			if !process_lives(item.state) {
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
			// A weight under the weight that the policy wrote: the process
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
		part_new := new_thread_part(row.weight)
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
				if thread.written == 0 || weight != min(part, thread.asked) || thread.limit != part || thread.new_thread_limit != min(part_new, part) {
					if written := thread_weight_write(thread, part, part_new); written != 0 {
						weight = written
					}
				}
			}
			row.thread_weight_least = min(row.thread_weight_least, weight)
			row.thread_weight_most = max(row.thread_weight_most, weight)
		}
		row.writes = round_now.writes - writes_before
		if slots_before[slot].serial == report.process_serial {
			row.ran = report.run_time - slots_before[slot].run_time
		}
		slots_before[slot] = {serial = report.process_serial, run_time = report.run_time}
		round_now.threads += u64(row.threads)
		// The processes with the most processor time first: the window shows
		// the first rows when it has less room than processes.
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

// The new-thread weight limit that the policy wrote last for the process
// of each slot, with the serial of that process.
Process_Limit_Written :: struct {
	serial: u64,
	limit:  u32, // 0: the policy never wrote this process.
}
process_limits_written: [PROCESS_SLOT_LIMIT]Process_Limit_Written

// process_limit_write gives a process its new-thread weight limit, through
// the machine handle. It writes only a value that changes: the kernel keeps
// the value of a process until the next write. Only the policy writes the
// value of a process, as only the policy writes a limit of a thread: the
// root service gives the right Schedule to this process only. Another
// holder of that right that wrote the value would not be corrected until
// the next give-back; the order "write before the report" stays, because
// the value is in the kernel.
process_limit_write :: proc "contextless" (slot, serial: u64, limit: u32) {
	written := &process_limits_written[slot]
	if written.serial == serial && written.limit == limit {
		return
	}
	status := system.process_schedule_write(machine, slot, serial, {new_thread_weight_limit = limit})
	switch {
	case status == .Ok:
		written^ = {serial = serial, limit = limit}
		round_now.writes += 1
		policy_writes += 1
	case status == .Bad_State:
	// The process ended since its report.
	case:
		policy_refused += 1
	}
}

// policy_weights_give_back gives each process the full new-thread weight
// limit, and each thread of the machine that is under a weight limit or a
// new-thread weight limit the weight that its process asked, and the two
// full limits. Only the policy writes a limit, so a
// limit under the full weight is a limit of the policy: of this process,
// or of a process `scheduler` that ran before it and was stopped with the
// policy on. A thread that a process creates during the pass gets the
// new-thread weight limit of its creator, so the passes go on until one
// writes nothing. false: a write was refused, or a thread was still under
// a limit after the last pass.
POLICY_GIVE_BACK_PASSES :: 4

policy_weights_give_back :: proc "contextless" () -> bool {
	for _ in 0 ..< POLICY_GIVE_BACK_PASSES {
		written, refused: u64
		for slot in u64(1) ..< PROCESS_SLOT_LIMIT {
			report, status := process_report(slot)
			if status != .Ok || !process_lives(report.state) {
				continue
			}
			// The value of the process first: a thread that the process
			// creates after it has the full value of its process.
			if process_schedule, process_status := system.process_schedule_read(machine, slot, report.process_serial); process_status == .Ok && process_schedule.new_thread_weight_limit != op.WEIGHT_FULL {
				switch system.process_schedule_write(machine, slot, report.process_serial, {}) {
				case .Ok:
					written += 1
				case .Bad_State:
				// The process ended.
				case .Bad_Operation, .Bad_Handle, .Bad_Address, .No_Memory, .No_Slot, .No_Right, .No_Budget:
					refused += 1
				}
			}
			count := policy_threads_of(slot, report.process_serial)
			for index in 0 ..< count {
				item := &policy_table.threads[index]
				if !process_lives(item.state) {
					continue
				}
				schedule, read_status := system.thread_schedule_read(machine, item.machine_number)
				if read_status != .Ok || (schedule.weight_limit == op.WEIGHT_FULL && schedule.new_thread_weight_limit == op.WEIGHT_FULL) {
					continue
				}
				asked := asked_of(schedule)
				if thread, first_sight := tracked_of(item.machine_number); thread != nil && !first_sight && thread.written != 0 {
					asked = schedule.weight < thread.written ? schedule.weight : thread.asked
				}
				switch system.thread_schedule_write(machine, item.machine_number, {weight = asked, request = schedule.request, weight_limit = op.WEIGHT_FULL, new_thread_weight_limit = op.WEIGHT_FULL}) {
				case .Ok:
					written += 1
				case .Bad_State:
				// The thread ended.
				case .Bad_Operation, .Bad_Handle, .Bad_Address, .No_Memory, .No_Slot, .No_Right, .No_Budget:
					refused += 1
				}
			}
		}
		if refused != 0 {
			return false
		}
		if written == 0 {
			tracked = {}
			process_limits_written = {}
			return true
		}
	}
	tracked = {}
	process_limits_written = {}
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
			system.log_fact(.Info, Share_Policy_Off{})
		}
		if on && !was_on {
			system.log_fact(.Info, Share_Policy_On{period = value_kinds.Time_In_Milliseconds(POLICY_PERIOD)})
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
// change the part of each process of the machine, so a process that only
// has a connection must not call them.
@(private = "file")
acts_for_principal :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller == nil || caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
}

// share sets the process weight of the processes with a name: the part of
// the processors that the share policy gives them, against the other
// processes.
//
// The policy divides the process weight between the threads of the process
// that count, so a process with 8 threads and a process with 1 thread of
// the same process weight have the same weight in all. The setting holds
// for each process with that name, also one that starts later, until the
// process `scheduler` stops. It has an effect while the policy is on
// ([policy](scheduler.policy)), under the fair strategy and EEVDF: the
// round robin reads no weight.
//
// - **name**: the name of the processes, 31 bytes at most.
// - **weight**: the process weight, from 32 to 1024. 1024 is the weight of
//   a process with no setting. A process has at most 32 threads, so 32 is
//   the least weight that gives each thread a weight of 1 or more.
//
// The result is the process weight that the name had. It fails with -1 and
// an error record, and no setting changes:
//
// - `No_Grant`: the caller does not act for the principal;
// - `Empty`: the name has no byte;
// - `Too_Long`: the name has more than 31 bytes;
// - `Too_Small`: the weight is under 32;
// - `Bad_Value`: the weight is above 1024;
// - `Full`: 16 names have a setting.
//
// Example: `scheduler.share("paint", 256)` gives the process `paint` a
// quarter of the weight of another process.
@(export, link_name = "share")
share :: proc "c" (name: ^string, weight: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, -1, .No_Grant, .Acts_For_Principal)
	}
	if len(name) == 0 {
		return errors.fail(error, -1, .Empty, .Bytes, 1, 0, PROCESS_NAME_LIMIT)
	}
	if len(name) > PROCESS_NAME_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Bytes, 1, i64(len(name)), PROCESS_NAME_LIMIT)
	}
	if weight < PROCESS_WEIGHT_LEAST {
		return errors.fail(error, -1, .Too_Small, .None, 2, weight, PROCESS_WEIGHT_LEAST)
	}
	if weight > op.WEIGHT_FULL {
		return errors.fail(error, -1, .Bad_Value, .None, 2, weight, op.WEIGHT_FULL)
	}
	system.lock(&policy_lock)
	defer system.unlock(&policy_lock)
	found, free: ^Process_Setting
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
		// The weight of a process with no setting: the place is free again.
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
// With the policy on, the process `scheduler` reads the threads of each
// process each 100 ms, and writes the weight of each thread: the process
// weight ([share](scheduler.share)) divided by the count of the threads of
// the process that are ready or that ran since the last round. It never
// gives a thread more than its process asked. With the policy off, each
// thread gets back the weight that its process asked and the full weight
// limit. The policy is off when the process starts.
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

// The processes of the case: four processes of the file of this process,
// with 1, 2, 4 and 8 threads that compute with no end. The value of the
// context that gives the role has a tag in its high half, so that a value
// of another starter is not a role, and the count of the threads in its
// low half.
SHARE_PROCESS_COUNT :: 4
SHARE_VALUE_ROLE :: 5
SHARE_ROLE_TAG :: u64(0x5348_4152_0000_0000) // "SHAR"

@(rodata)
share_thread_counts := [SHARE_PROCESS_COUNT]u64{1, 2, 4, 8}
@(rodata)
share_process_names := [SHARE_PROCESS_COUNT]string{"spinner_1", "spinner_2", "spinner_4", "spinner_8"}

// share_role_threads gives the count of the threads of a process of the
// case from the value of its context. 0: the process is not one of them.
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

// share_process_run is the whole of a process of the case: threads that
// compute until the process that started it stops it.
share_process_run :: proc "contextless" (threads: u64) -> ! {
	for index in 1 ..< threads {
		// A thread that does not start is one spinner less: the case reads
		// the count of the ready threads, and says so.
		_, _ = system.thread_start(share_spin, &share_spin_count[index])
	}
	share_spin(&share_spin_count[0])
}

// The process of short threads of the second case: its role is one value
// with its own tag, so that no count of threads of the first case is it.
SHORT_THREADS_ROLE :: u64(0x5348_4F52_0000_0001) // "SHOR"
// The short threads that the process keeps alive, and the iterations of
// the loop of each one before it ends. The count of iterations makes a
// thread short against the period of the rounds on a fast host and on a
// slow one; the checks do not depend on it: a thread that a round sees is
// not one that the case checks.
SHORT_THREADS_ALIVE :: 6
SHORT_THREAD_ITERATIONS :: 200_000

short_thread_run :: proc "c" (parameter: rawptr) -> ! {
	spinner := (^Spinner)(parameter)
	for _ in 0 ..< SHORT_THREAD_ITERATIONS {
		intrinsics.volatile_store(&spinner.count, intrinsics.volatile_load(&spinner.count) + 1)
	}
	system.thread_stop()
}

// short_threads_run is the whole of the process of short threads: its
// first thread waits for the end of each short thread in turn and creates
// the next one in its place, until the process that started it stops it.
// A creation that fails, for a slot of a thread that its budget has not
// got back yet, is tried again at the next turn of the loop.
short_threads_run :: proc "contextless" () -> ! {
	threads: [SHORT_THREADS_ALIVE]system.Thread
	for {
		for &thread, index in threads {
			if thread.handle != 0 {
				system.thread_wait(thread)
			}
			status: system.Status
			thread, status = system.thread_start(short_thread_run, &share_spin_count[index])
			if status != .Ok {
				thread = {}
			}
		}
	}
}

// What a process of the case asks of the budget of this process. pages:
// its copy of the data of the module and of the module that it imports,
// its stack, its context and its page tables, with room; then a stack of
// 16 pages and a thread area of 3 for each thread more. processor: one
// processor for each thread, and no more than the machine has: its threads
// cannot run on more, so its budget never stops it, and the four processes
// ask together for no more than this process holds. It has no handle of
// this process and writes no log record.
share_process_amounts :: proc "contextless" (threads: u64) -> system.Budget_Amounts {
	processors := min(threads, u64(system.thread_record().processors))
	return {pages = 512 + threads * (system.THREAD_STACK_PAGES + 3), processes = 1, threads = threads, processor = processors * 1_000_000, log_records = 0}
}

process_generator: random.Generator
image: []u8 // The boot image: the file of this process is in it.

Share_Process :: struct {
	process: system.Handle,
	slot:    u64,
	serial:  u64,
}

share_processes: [SHARE_PROCESS_COUNT]Share_Process

// One process of a case, as the case starts it: its name, the value of its
// role, what it asks of the budget of this process, and the count of its
// ready threads that says that it runs.
Case_Process :: struct {
	name:        string,
	role:        u64,
	amounts:     system.Budget_Amounts,
	ready_least: u64,
}

// case_processes_start starts the processes of a case and finds the slot of
// each one by its name. It then waits until the thread report of each one
// shows at least its count of ready threads: a state of the kernel, and the
// time only ends a hang. false: a process did not start, or its threads did
// not become ready.
case_processes_start :: proc "contextless" (processes: []Share_Process, described: []Case_Process) -> bool {
	file := system.image_find(image, "scheduler")
	for &started, index in processes {
		grants: [op.CONTEXT_HANDLES]system.Grant
		values: [op.CONTEXT_VALUES]u64
		values[SHARE_VALUE_ROLE] = described[index].role
		amounts := described[index].amounts
		error: module.Load_Error
		status: system.Status
		started.process, status = system.process_start(file, described[index].name, grants, random.values_with_seed(&process_generator, values), amounts, nil, nil, {image = image}, &error)
		if status != .Ok {
			own, _ := system.budget_read()
			system.log_fact(.Info, Share_Process_Not_Started{status = op.Status_Word(status), given_pages = own.pages, given_processes = own.processes, given_threads = own.threads, asked_pages = amounts.pages, asked_threads = amounts.threads, process_name = value_kinds.text_field(described[index].name, PROCESS_NAME_FIELD_BYTES)})
			share_load_error_log(&error)
			return false
		}
	}
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for &started, index in processes {
		for started.slot == 0 && system.time() < deadline {
			for slot in u64(1) ..< PROCESS_SLOT_LIMIT {
				report, status := process_report(slot)
				if status == .Ok && process_lives(report.state) && system.name_of(report.name[:]) == described[index].name {
					started.slot, started.serial = slot, report.process_serial
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
			ready = ready_count >= described[index].ready_least
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

// share_processes_start starts the four processes of spinning threads. Each
// one runs when each of its threads is ready.
share_processes_start :: proc "contextless" () -> bool {
	described: [SHARE_PROCESS_COUNT]Case_Process
	for &process, index in described {
		threads := share_thread_counts[index]
		process = {name = share_process_names[index], role = SHARE_ROLE_TAG | threads, amounts = share_process_amounts(threads), ready_least = threads}
	}
	return case_processes_start(share_processes[:], described[:])
}

case_processes_stop :: proc "contextless" (processes: []Share_Process) {
	for &started in processes {
		if started.process != 0 {
			system.process_stop(started.process)
			system.close(started.process)
		}
		started = {}
	}
}

// What the schedules of the threads of one process are, read through the
// machine handle.
Process_Weights :: struct {
	threads:    u64, // The threads that live.
	sum:        u64, // The sum of their weights.
	least:      u32,
	most:       u32,
	limit_least: u32, // The least and the most of their weight limits.
	limit_most:  u32,
	new_thread_limit_least: u32, // The least and the most of their new-thread weight limits.
	new_thread_limit_most:  u32,
}

process_weights :: proc "contextless" (slot, serial: u64) -> (weights: Process_Weights) {
	weights.least, weights.limit_least, weights.new_thread_limit_least = op.WEIGHT_FULL, op.WEIGHT_FULL, op.WEIGHT_FULL
	count := policy_threads_of(slot, serial)
	for index in 0 ..< count {
		item := &policy_table.threads[index]
		if !process_lives(item.state) {
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
		weights.new_thread_limit_least = min(weights.new_thread_limit_least, schedule.new_thread_weight_limit)
		weights.new_thread_limit_most = max(weights.new_thread_limit_most, schedule.new_thread_weight_limit)
	}
	return weights
}

// The milliseconds of the interval of a measure run: long against the lag
// bound of a thread, which is two requests of 3 ms.
SHARE_PROCESSES_TIME :: 1000

// case_processes_interval gives the ticks of processor time of each process
// of a case over one interval, from the process reports. In the check the
// interval ends when each process ran SHARE_TICKS_CHECKED ticks: a count of
// the kernel, so a slow host makes the interval longer and leaves the
// counts. A measure run has an interval of SHARE_PROCESSES_TIME. The rounds
// of the policy go on during the interval, one each period. false: the
// hang bound ended the interval, or a report was not of the process.
case_processes_interval :: proc "contextless" (processes: []Share_Process, on: bool) -> (parts: [SHARE_PROCESS_COUNT]u64, each_ran: bool) {
	base: [SHARE_PROCESS_COUNT]u64
	for &started, index in processes {
		report, status := process_report(started.slot)
		if status != .Ok || report.process_serial != started.serial {
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
		for &started, index in processes {
			report, status := process_report(started.slot)
			if status != .Ok || report.process_serial != started.serial {
				return parts, false
			}
			parts[index] = report.run_time - base[index]
			each_ran &&= parts[index] >= SHARE_TICKS_CHECKED
		}
		if measured {
			each_ran &&= system.time() - start >= SHARE_PROCESSES_TIME
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

// The weight that a thread of this process asks at its creation, and the
// weight that it lowers itself to, in the case. Under the policy the first
// thread has the new-thread weight limit of a process of the full weight,
// and the kernel refuses a weight above it at a creation.
SHARE_WEIGHT_ASKED :: op.WEIGHT_FULL / PROCESS_THREADS_MOST - 2
SHARE_WEIGHT_LOWERED :: SHARE_WEIGHT_ASKED / 2
// The threads that this process then starts: with its first thread and the
// thread that lowered itself, it has 9 threads that count.
SHARE_THREADS_MORE :: 7

// shares_of gives the share of each process of its part of the ticks, in
// hundredths of a percent.
shares_of :: proc "contextless" (parts: [SHARE_PROCESS_COUNT]u64) -> (shares: [SHARE_PROCESS_COUNT]value_kinds.Hundredths) {
	total: u64
	for part in parts {
		total += part
	}
	for part, index in parts {
		shares[index] = value_kinds.Hundredths(share_hundredths(part, total))
	}
	return shares
}

// share_case checks the share policy on four processes with 1, 2, 4 and 8
// spinning threads, under EEVDF, and prints the shares.
//
// The conditions are values that the kernel gives back, with no time: the
// weight, the weight limit and the new-thread weight limit of each thread
// after a round; their sum for each process; the weight of a thread of
// this process that asked 30 and then lowered itself to 15; the weights of
// this process after it started 7 threads more; the weights and the limits
// after the policy went off. One condition is
// an order of counts of ticks: the part of the process with 8 threads
// against the process with 1 is smaller with the policy than without it.
// The shares themselves are measures: the balance between the queues
// counts threads and not weights, so no bound of a share follows from the
// weights.
share_case :: proc "contextless" () -> bool {
	if image == nil || self_slot == 0 {
		system.log_fact(.Info, Share_Policy_Without_Image{})
		return false
	}
	before, set_status := system.strategy_set(machine, .Eevdf)
	if set_status != .Ok {
		return false
	}
	defer system.strategy_set(machine, before)
	defer case_processes_stop(share_processes[:])
	if !share_processes_start() {
		system.log_fact(.Info, Share_Policy_Without_Processes{})
		return false
	}

	// Without the policy: the rounds only read.
	policy_round(false)
	without, without_ran := case_processes_interval(share_processes[:], false)

	// With the policy. Two rounds: the second one finds each weight as the
	// first one left it.
	policy_round(true)
	policy_round(true)
	policy_round(true)
	// The third round wrote no thread of the four processes: their threads
	// did not start, end or block, so no weight changed. The other processes
	// of the machine can change between two rounds.
	steady := true
	for &row in round_now.rows[:round_now.count] {
		for name in share_process_names {
			if system.name_of(row.name[:]) == name {
				steady &&= row.writes == 0
			}
		}
	}
	weights: [SHARE_PROCESS_COUNT]Process_Weights
	weights_right := true
	new_part := new_thread_part(op.WEIGHT_FULL)
	for &started, index in share_processes {
		weights[index] = process_weights(started.slot, started.serial)
		part := u32(op.WEIGHT_FULL / share_thread_counts[index])
		weights_right &&= weights[index].threads == share_thread_counts[index] && weights[index].least == part && weights[index].most == part
		weights_right &&= weights[index].limit_least == part && weights[index].limit_most == part && weights[index].sum <= op.WEIGHT_FULL
		weights_right &&= weights[index].new_thread_limit_least == new_part && weights[index].new_thread_limit_most == new_part
	}
	system.log_fact(.Info, Share_Policy_Rounds{one_thread_weight = u64(weights[0].most), two_threads_weight = u64(weights[1].most), four_threads_weight = u64(weights[2].most), eight_threads_weight = u64(weights[3].most), new_thread_limit = u64(weights[3].new_thread_limit_most), one_thread_sum = weights[0].sum, two_threads_sum = weights[1].sum, four_threads_sum = weights[2].sum, eight_threads_sum = weights[3].sum, steady = u64(steady), verdict = verdict_field(weights_right && steady)})
	with, with_ran := case_processes_interval(share_processes[:], true)

	// A process that asks less keeps it, and a process that starts threads
	// gets no more: this process is the example.
	numbers: [SPINNER_LIMIT]u64
	kept_right := spinners_start(0, 1, weight_of_lowered) && spinner_machine_numbers(0, 1, &numbers)
	asked, lowered: op.Thread_Schedule
	own: Process_Weights
	if kept_right {
		policy_round(true)
		asked, _ = system.thread_schedule_read(machine, numbers[0])
		lower_status := system.thread_schedule_write(spinner_threads[0].handle, 0, {weight = SHARE_WEIGHT_LOWERED})
		policy_round(true)
		lowered, _ = system.thread_schedule_read(machine, numbers[0])
		kept_right = lower_status == .Ok && asked.weight == SHARE_WEIGHT_ASKED && lowered.weight == SHARE_WEIGHT_LOWERED
		kept_right &&= spinners_start(1, SHARE_THREADS_MORE, full_weight) && spinner_machine_numbers(1, SHARE_THREADS_MORE, &numbers)
		policy_round(true)
		own = process_weights(self_slot, self_serial)
		part := u32(op.WEIGHT_FULL / (SHARE_THREADS_MORE + 2))
		kept_right &&= own.threads == SHARE_THREADS_MORE + 2 && own.least == SHARE_WEIGHT_LOWERED && own.most == part
		kept_right &&= own.sum == u64(part) * (SHARE_THREADS_MORE + 1) + SHARE_WEIGHT_LOWERED && own.sum <= op.WEIGHT_FULL
	}
	system.log_fact(.Info, Own_Threads_Weights{asked_weight = u64(SHARE_WEIGHT_ASKED), weight = u64(asked.weight), lowered_weight = u64(lowered.weight), lowered_to = u64(SHARE_WEIGHT_LOWERED), more_threads = u64(SHARE_THREADS_MORE), threads = own.threads, least = u64(own.least), most = u64(own.most), sum = own.sum, verdict = verdict_field(kept_right)})

	// The policy goes off: each thread has the weight that its process
	// asked, and the full weight limit.
	given_back := policy_weights_give_back()
	lowered_after, _ := system.thread_schedule_read(machine, numbers[0])
	first_after, _ := system.thread_schedule_read(machine, self_machine_number)
	back_right := given_back && policy_refused == 0
	back_right &&= lowered_after.weight == SHARE_WEIGHT_LOWERED && lowered_after.weight_limit == op.WEIGHT_FULL && lowered_after.new_thread_weight_limit == op.WEIGHT_FULL
	back_right &&= first_after.weight == op.WEIGHT_FULL && first_after.weight_limit == op.WEIGHT_FULL && first_after.new_thread_weight_limit == op.WEIGHT_FULL
	for &started, index in share_processes {
		after := process_weights(started.slot, started.serial)
		back_right &&= after.threads == share_thread_counts[index] && after.least == op.WEIGHT_FULL && after.limit_least == op.WEIGHT_FULL && after.new_thread_limit_least == op.WEIGHT_FULL
	}
	spinners_stop(0, SHARE_THREADS_MORE + 1)
	system.log_fact(.Info, Share_Policy_Off_Weights{lowered_weight = u64(lowered_after.weight), none_refused = u64(policy_refused == 0), verdict = verdict_field(back_right)})

	// The order: the part of the process with 8 threads against the process
	// with 1, with the policy and without it. Each part is a count of
	// ticks of the kernel over one interval.
	last :: SHARE_PROCESS_COUNT - 1
	order_right := without_ran && with_ran && with[last] * without[0] < without[last] * with[0]
	system.log_fact(.Info, Share_Policy_Orders_Parts{verdict = verdict_field(order_right)})

	without_shares := shares_of(without)
	with_shares := shares_of(with)
	system.log_fact(.Info, Process_Shares_Measured{without_one = without_shares[0], without_two = without_shares[1], without_four = without_shares[2], without_eight = without_shares[3], with_one = with_shares[0], with_two = with_shares[1], with_four = with_shares[2], with_eight = with_shares[3], without_ratio = without[last] * 100 / max(without[0], 1), with_ratio = with[last] * 100 / max(with[0], 1)})

	sorted := round_durations
	rounds := int(min(rounds_done, ROUND_DURATIONS))
	for at in 1 ..< rounds {
		for back := at; back > 0 && sorted[back - 1] > sorted[back]; back -= 1 {
			sorted[back - 1], sorted[back] = sorted[back], sorted[back - 1]
		}
	}
	system.log_fact(.Info, Share_Policy_Round_Measured{processes = u64(round_now.count), threads = round_now.threads, middle = value_kinds.Time_In_Nanoseconds(sorted[rounds / 2]), rounds = u64(rounds), writes = policy_writes, raises = policy_raises, period = value_kinds.Time_In_Milliseconds(POLICY_PERIOD)})
	return weights_right && steady && kept_right && back_right && order_right
}

// The processes of the case of the short threads: the process of short
// threads first, then a process with one thread that computes with no end.
SHORT_CASE_PROCESS_COUNT :: 2
short_case_processes: [SHORT_CASE_PROCESS_COUNT]Share_Process
// A process that the case starts under the policy, to read its first thread.
started_under_policy: [1]Share_Process
// The distinct threads that no round saw which the case reads: enough that
// the process created them at many moments between two rounds.
SHORT_THREADS_CHECKED :: 24

// What the case read of the threads that no round saw.
Unseen_Threads :: struct {
	checked:   u64, // The distinct threads read.
	wrong:     u64, // The reads of a schedule that was not the new-thread weight limit of the process in each value.
	sum_most:  u64, // The most that the weights of the threads of one read summed to.
}

// unseen_threads_check reads, through the machine handle, the schedules of
// the threads of a process that no round saw, until it has read
// SHORT_THREADS_CHECKED distinct threads; the time only ends a hang. Only
// this thread runs rounds during the case, so the records of the policy
// say exactly which threads a round saw: a thread whose place holds
// another machine number was created after the last round read the
// report.
unseen_threads_check :: proc "contextless" (process: Share_Process, new_part: u32) -> (unseen: Unseen_Threads) {
	// The machine number last read in each place: a place that a new thread
	// takes has a new serial, so it counts again.
	read_before: [THREAD_PLACE_LIMIT]u64
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for unseen.checked < SHORT_THREADS_CHECKED && system.time() < deadline {
		count := policy_threads_of(process.slot, process.serial)
		sum: u64
		for index in 0 ..< count {
			item := &policy_table.threads[index]
			place := item.machine_number & 0xFFFF_FFFF
			if !process_lives(item.state) || place >= THREAD_PLACE_LIMIT || tracked[place].machine_number == item.machine_number {
				continue
			}
			schedule, status := system.thread_schedule_read(machine, item.machine_number)
			if status != .Ok {
				// It ended since the report.
				continue
			}
			if read_before[place] != item.machine_number {
				read_before[place] = item.machine_number
				unseen.checked += 1
			}
			sum += u64(schedule.weight)
			if schedule.weight != new_part || schedule.weight_limit != new_part || schedule.new_thread_weight_limit != new_part {
				unseen.wrong += 1
			}
		}
		unseen.sum_most = max(unseen.sum_most, sum)
		if unseen.checked < SHORT_THREADS_CHECKED {
			system.sleep(system.time() + SHARE_POLL_TIME)
		}
	}
	return unseen
}

// short_threads_case checks the share policy against a process that keeps
// short threads alive, under EEVDF: each of its threads ends after a count
// of iterations and the process creates the next one, so most of its
// threads start and end between two rounds.
//
// The condition that the old form fails is a state, with no time: each
// thread that no round saw has the new-thread weight limit of its process
// as its weight, its weight limit and its new-thread weight limit, and the
// weights of those threads of one read sum to under the process weight.
// When a new thread got the weight limit of its creator, these threads
// had the part of the creator, which is above that value; the per-thread
// value is the condition that breaks that form, the sum is evidence only.
// The case runs one round only before it reads: the round writes the
// value of the process before it reads the report, so a thread that the
// round did not see was created after that write. The conditions that
// break a kernel that ignores the value of the process are states after
// the machine handle gave the first thread of this process a new-thread
// weight limit of its own above the value: a weight above the value is
// refused with the value in the error record, a thread with the weight 0
// gets the value, and the first thread of a process that this thread
// starts gets the value. The parts of the two processes over two intervals
// are printed as a measure: they depend on where the balance places the
// threads.
short_threads_case :: proc "contextless" () -> bool {
	if image == nil || self_slot == 0 {
		system.log_fact(.Info, Short_Threads_Without_Image{})
		return false
	}
	described := [SHORT_CASE_PROCESS_COUNT]Case_Process {
		// The slot of each short thread comes back to the budget a little
		// after its end: the budget has room for a second set.
		{name = "short_threads", role = SHORT_THREADS_ROLE, amounts = share_process_amounts(1 + 2 * SHORT_THREADS_ALIVE), ready_least = 1},
		{name = "long_thread", role = SHARE_ROLE_TAG | 1, amounts = share_process_amounts(1), ready_least = 1},
	}
	// The processes of the case before it gave their budgets back: the wait
	// is for that state, and the time only ends a hang.
	started_described := [1]Case_Process{{name = "started_under_policy", role = SHARE_ROLE_TAG | 1, amounts = share_process_amounts(1), ready_least = 1}}
	needed := started_described[0].amounts
	for &process in described {
		needed.pages += process.amounts.pages
		needed.threads += process.amounts.threads
		needed.processor += process.amounts.processor
	}
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		own, _ := system.budget_read()
		if own.pages >= needed.pages && own.threads >= needed.threads && own.processor >= needed.processor {
			break
		}
		system.sleep(system.time() + 1)
	}
	before, set_status := system.strategy_set(machine, .Eevdf)
	if set_status != .Ok {
		return false
	}
	defer system.strategy_set(machine, before)
	defer case_processes_stop(short_case_processes[:])
	defer case_processes_stop(started_under_policy[:])
	if !case_processes_start(short_case_processes[:], described[:]) {
		system.log_fact(.Info, Short_Threads_Without_Processes{})
		return false
	}

	// Without the policy: the rounds only read.
	policy_round(false)
	without, without_ran := case_processes_interval(short_case_processes[:], false)

	// One round: the gap of the first round is closed by the write of the
	// value of the process before the report.
	policy_round(true)
	new_part := new_thread_part(op.WEIGHT_FULL)
	unseen := unseen_threads_check(short_case_processes[0], new_part)
	unseen_right := unseen.checked >= SHORT_THREADS_CHECKED && unseen.wrong == 0 && unseen.sum_most < op.WEIGHT_FULL
	system.log_fact(.Info, Short_Threads_Unseen{alive = u64(SHORT_THREADS_ALIVE), checked = min(unseen.checked, SHORT_THREADS_CHECKED), new_part = u64(new_part), each_right = u64(unseen.wrong == 0), sum_under = u64(unseen.sum_most < op.WEIGHT_FULL), verdict = verdict_field(unseen_right)})

	// The value of the process alone. The round gave the first thread of
	// this process the small value too, so a creation by it holds by the
	// value of the thread alone. The machine handle now gives that thread
	// the full new-thread weight limit, which the kernel lowers to its
	// weight limit, its part: above the small value. Its weight, request
	// and weight limit stay, so nothing is raised. From here each check
	// holds only when a creation takes the value of the process.
	opened_status := system.Status.Bad_State
	if before_open, before_open_status := system.thread_schedule_read(machine, self_machine_number); before_open_status == .Ok {
		opened := before_open
		opened.new_thread_weight_limit = op.WEIGHT_FULL
		opened_status = system.thread_schedule_write(machine, self_machine_number, opened)
	}
	first, first_status := system.thread_schedule_read(machine, self_machine_number)
	first_open := opened_status == .Ok && first_status == .Ok && first.new_thread_weight_limit > new_part + 1
	own_process, own_process_status := system.process_schedule_read(machine, self_slot, self_serial)
	// A weight between the value of the process and the value of the
	// thread is refused, and the error record names the value of the
	// process.
	error: errors.Error_Record
	_, between_status := system.thread_start(brief, nil, weight = u64(new_part) + 1, error = &error)
	// A thread with the weight 0 gets the value of the process as its
	// weight and as its two limits.
	limited_child = {read = .Bad_State, raise = .Ok}
	child, child_status := system.thread_start(limited_child_run, nil)
	if child_status == .Ok {
		system.thread_wait(child)
	}
	child_schedule := limited_child.schedule
	child_right := child_status == .Ok && limited_child.read == .Ok && child_schedule.weight == new_part && child_schedule.weight_limit == new_part && child_schedule.new_thread_weight_limit == new_part
	refused_right := first_open && own_process_status == .Ok && own_process.new_thread_weight_limit == new_part
	refused_right &&= between_status == .Bad_Operation && error.limit == i64(new_part) && child_right
	system.log_fact(.Info, Own_New_Thread_Limit{above = u64(new_part) + 1, first_open = u64(first_open), process_limit = u64(own_process.new_thread_weight_limit), heavier_weight = u64(new_part) + 1, between_status = op.Status_Word(between_status), error_limit = u64(error.limit), child_weight = u64(child_schedule.weight), child_limit = u64(child_schedule.weight_limit), child_new_thread_limit = u64(child_schedule.new_thread_weight_limit), verdict = verdict_field(refused_right)})

	// A process that this process starts under the policy, from the first
	// thread whose own value is above the small value: its first thread
	// has the value of the process of its starter, before any round wrote
	// it.
	started_right := case_processes_start(started_under_policy[:], started_described[:])
	started_weights: Process_Weights
	if started_right {
		started_weights = process_weights(started_under_policy[0].slot, started_under_policy[0].serial)
		started_right = started_weights.threads == 1 && started_weights.most == new_part && started_weights.limit_most == new_part && started_weights.new_thread_limit_most == new_part
	}
	case_processes_stop(started_under_policy[:])
	system.log_fact(.Info, Started_Process_Weights{above = u64(new_part) + 1, weight = u64(started_weights.most), limit = u64(started_weights.limit_most), thread_limit = u64(started_weights.new_thread_limit_most), verdict = verdict_field(started_right && first_open)})
	with, with_ran := case_processes_interval(short_case_processes[:], true)
	if !policy_weights_give_back() {
		system.log_fact(.Info, Full_Limits_Not_Given_Back{})
		return false
	}

	// The parts of the two processes are a measure, not a condition: a
	// weight orders the share only between threads of one queue, and the
	// balance places the threads, so no order of the two intervals follows
	// from the weights.
	system.log_fact(.Info, Short_Threads_Parts{without_policy = without[0] * 100 / max(without[1], 1), with_policy = with[0] * 100 / max(with[1], 1), without_ended = u64(without_ran), with_ended = u64(with_ran)})
	return unseen_right && refused_right && started_right && first_open
}
