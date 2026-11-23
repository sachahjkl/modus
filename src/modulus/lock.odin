package kernel

import "base:intrinsics"
import op "modus:contract/operation"
import "modulus:slot_set"

// The locks of the kernel (docs/ARCHITECTURE.md, "Locks of the kernel").
//
// A lock is a ticket lock: a processor takes the next ticket and waits until
// the lock serves it. So processors get a lock in the order that they asked
// for it, and none waits for ever while others take it again and again.
// Interrupts are off in the kernel: a processor never takes a lock again
// from an interrupt. While it waits, it answers processor_sync.
//
// The kind of a lock is its place in the lock order: a processor takes a
// lock only if it holds no lock of a later kind. Each processor counts its
// takes and its waits for each kind; System_Report gives the sums.

TEST_BUILD_CHECKS_LOCK_ORDER :: #config(TEST_BUILD_CHECKS_LOCK_ORDER, true)

// A wait for a lock longer than this is a hang, and the waiter drains the
// log of the kernel to the serial port while it waits.
LOCK_WAIT_BEFORE_DRAIN_MILLISECONDS :: 1000

Lock :: struct {
	next:    u32, // The next ticket.
	serving: u32, // The ticket that holds the lock.
}

// Before the first processor has its record, the kernel runs on one
// processor, with no gs register: a lock is not taken.
lock_ready: bool

// lock_take waits for the lock, then holds it.
lock_take :: proc "contextless" (lock: ^Lock, kind: op.Lock_Kind) {
	if !lock_ready {
		return
	}
	cpu := processor_self()
	when TEST_BUILD_CHECKS_LOCK_ORDER {
		lock_order_check(cpu, kind)
	}
	ticket := intrinsics.atomic_add(&lock.next, 1)
	count := &cpu.lock_counts[int(kind)]
	count.takes += 1
	if intrinsics.atomic_load(&lock.serving) != ticket {
		count.waits += 1
		// The event point of a wait for a lock (events.odin): only on the
		// path that waits, and with no read of the cycle counter when no
		// rule of this kind can accept it. The record is written after the
		// take: event_record takes no lock, so it can run with this one held.
		started: u64
		if event_observed(cpu, OBSERVED_LOCK_WAIT) {
			if process, _ := event_current(cpu); event_wanted(cpu, OBSERVED_LOCK_WAIT, .Lock_Wait, process) {
				started = cycles_now()
			}
		}
		// A wait past LOCK_WAIT_BEFORE_DRAIN_MILLISECONDS is a hang: the
		// waiter then drains the log at each turn, so the lines that explain
		// the hang reach the serial port even when the processors that
		// tick are the ones that hang. The drain takes no lock.
		drain_after := cycles_now() + cycle_frequency / 1000 * LOCK_WAIT_BEFORE_DRAIN_MILLISECONDS
		for intrinsics.atomic_load(&lock.serving) != ticket {
			sync_acknowledge(cpu)
			if cycle_frequency != 0 && cycles_now() >= drain_after {
				serial_drain_of_a_processor(cpu)
			}
			intrinsics.cpu_relax()
		}
		if started != 0 {
			process, thread_number := event_current(cpu)
			event_record(cpu, .Lock_Wait, process, thread_number, u64(kind), cycles_now() - started, 0)
		}
	}
	cpu.held[kind] += 1
}

// lock_free gives the lock to the next ticket.
lock_free :: proc "contextless" (lock: ^Lock, kind: op.Lock_Kind) {
	if !lock_ready {
		return
	}
	cpu := processor_self()
	cpu.held[kind] -= 1
	intrinsics.atomic_add(&lock.serving, 1)
}

// lock_held says if the processor that runs it holds a lock of this kind.
lock_held :: proc "contextless" (kind: op.Lock_Kind) -> bool {
	return processor_self().held[kind] != 0
}

// Two locks of one kind at one time: the order of ARCHITECTURE.md permits it
// for process locks under the control lock, and for run locks in the order
// of the processors (see queue_move).
@(private = "file")
lock_order_check :: proc "contextless" (cpu: ^Processor, kind: op.Lock_Kind) {
	for other in op.Lock_Kind {
		if other > kind && cpu.held[other] != 0 {
			lock_order_broken(kind, other)
		}
	}
	if cpu.held[kind] != 0 && kind != .Run && !(kind == .Process && cpu.held[.Control] != 0) {
		lock_order_broken(kind, kind)
	}
}

@(private = "file")
lock_order_broken :: proc "contextless" (taken, held: op.Lock_Kind) -> ! {
	fault_report_begin()
	log("kernel: the lock order is broken: a lock ", op.LOCK_KIND_NAMES[taken], " was taken while a lock ", op.LOCK_KIND_NAMES[held], " is held")
	machine_stop(.Invariant_Broken)
}

// lock_counts_sum gives the counts of all the processors.
lock_counts_sum :: proc "contextless" () -> (sum: [op.LOCK_KIND_CAPACITY]op.Lock_Count) {
	for cpu in processors[:processor_count] {
		for &count, kind in sum {
			count.takes += intrinsics.volatile_load(&cpu.lock_counts[kind].takes)
			count.waits += intrinsics.volatile_load(&cpu.lock_counts[kind].waits)
		}
	}
	return sum
}

// The control lock (docs/ARCHITECTURE.md, "Locks of the kernel"). A close
// under it can end the last handle to a process: the stop of that process
// waits in `stops_pending` until control_free, so that a stop never runs
// inside the process locks of the path that closed the handle.
control_lock: Lock
stops_pending: Process_Set // The processes that have no handle. Control lock.

control_take :: proc "contextless" () {
	lock_take(&control_lock, .Control)
}

control_free :: proc "contextless" () {
	for index in slot_set.take(&stops_pending) {
		process := &processes[index]
		if intrinsics.atomic_load(&process.references) != 0 {
			continue
		}
		if process.state == .Stopped {
			process_free(process) // Only after the cleanup; else the cleanup frees it.
		} else if process.state != .None {
			process_stop(index, .Handles_Closed, .None)
		}
	}
	lock_free(&control_lock, .Control)
}

// The lock of each process. It is out of the process record: a new process
// in a slot does not reset it.
process_locks: [PROCESS_CAPACITY]Lock

// process_lock takes the lock of a process, unless this processor holds it
// already. true: this call took it; give it to process_unlock.
process_lock :: proc "contextless" (index: u32) -> bool {
	cpu := processor_self()
	if slot_set.has(&cpu.processes_held, index) {
		return false
	}
	lock_take(&process_locks[index], .Process)
	slot_set.add(&cpu.processes_held, index)
	return true
}

process_unlock :: proc "contextless" (index: u32, taken: bool) {
	if taken {
		slot_set.remove(&processor_self().processes_held, index)
		lock_free(&process_locks[index], .Process)
	}
}
