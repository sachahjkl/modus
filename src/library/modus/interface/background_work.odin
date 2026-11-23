package interface

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:system"

// The background work of a window: one worker thread that runs one job at a
// time, so that a call that waits for another process never runs on the
// thread of the window (src/md/features/background_work.md).
//
// The window asks for a job, draws on, wakes when the job is done, and
// takes its result:
//
//   interface.background_work_start(&work)
//   interface.background_work_ask(&work, save_job, nil)
//   ...
//   wait: system.Wait
//   ready := interface.background_work_wait(&wait, &work)
//   system.wait_end(&wait, ready ? system.time() : deadline)
//   if interface.background_work_take(&work) { ... read the result ... }

// The state of the work. The word is written with an atomic store by the
// side that owns the next step.
Background_State :: enum u32 {
	Idle    = 0, // No job: the window can ask.
	Asked   = 1, // A job waits for the worker.
	Running = 2, // The worker runs the job.
	Done    = 3, // The result is ready: the window takes it.
}

// The stack of the worker: the calls of a job copy their arguments on it.
BACKGROUND_STACK_PAGES :: 64

// A work lives as long as its process: its thread holds the address of the
// record and never stops, so the record is a global variable, never a
// local of a call that ends (src/md/features/background_work.md).
Background_Work :: struct {
	state:     u32, // The word of a Background_State.
	asked:     system.Event, // The window wakes the worker.
	done:      system.Event, // The worker wakes the window.
	job:       proc "contextless" (parameter: rawptr),
	parameter: rawptr,
	thread:    system.Thread,
	started:   bool,
	// The jobs that the worker ran: a measure, and a check of a test. The
	// worker writes it before the store of Done; the window reads it only
	// after a take, which the state word orders after that write.
	jobs_done: u64,
}

// background_state gives the state of the work. The word is written only
// with members, so a word that names no member is a fault of this file.
background_state :: proc "contextless" (work: ^Background_Work) -> Background_State {
	word := intrinsics.atomic_load_explicit(&work.state, .Acquire)
	state, known := enum_word.member_of_word(Background_State, u64(word))
	if !known {
		system.log(.Error, "interface: the state word of a background work is ", u64(word), ", which names no member")
		system.stop(.Failed)
	}
	return state
}

@(private = "file")
background_state_set :: proc "contextless" (work: ^Background_Work, state: Background_State) {
	intrinsics.atomic_store_explicit(&work.state, u32(state), .Release)
}

// background_work_busy says if a job is asked, runs, or is done and not
// taken: the window shows that it waits, and asks for no second job.
background_work_busy :: proc "contextless" (work: ^Background_Work) -> bool {
	return background_state(work) != .Idle
}

// background_work_ask gives the worker a job. false: a job is not taken
// yet, and nothing changes. The job owns the memory that it reads and
// writes until background_work_take gives true.
background_work_ask :: proc "contextless" (work: ^Background_Work, job: proc "contextless" (parameter: rawptr), parameter: rawptr) -> bool {
	if job == nil || background_state(work) != .Idle {
		return false
	}
	work.job, work.parameter = job, parameter
	background_state_set(work, .Asked)
	system.event_wake(&work.asked)
	return true
}

// background_work_step runs the job that is asked, on the worker: true
// when it ran one. The thread runs it in a loop; a host test calls it in
// place of the thread.
background_work_step :: proc "contextless" (work: ^Background_Work) -> bool {
	if background_state(work) != .Asked {
		return false
	}
	background_state_set(work, .Running)
	work.job(work.parameter)
	work.jobs_done += 1
	background_state_set(work, .Done)
	system.event_wake(&work.done)
	return true
}

// background_work_take gives true once for each job that is done: the
// window then reads its result, and can ask again.
background_work_take :: proc "contextless" (work: ^Background_Work) -> bool {
	if background_state(work) != .Done {
		return false
	}
	work.job, work.parameter = nil, nil
	background_state_set(work, .Idle)
	return true
}

// background_work_wait adds the end of a job to a wait list. ready: a job
// is done already, and the loop must not sleep: the count of the event is
// read before the state, so an end after the read wakes the wait.
background_work_wait :: proc "contextless" (wait: ^system.Wait, work: ^Background_Work) -> (ready: bool) {
	seen := system.event_count(&work.done)
	if background_state(work) == .Done {
		return true
	}
	system.wait_event(wait, &work.done, seen)
	return false
}

@(private = "file")
background_worker :: proc "c" (parameter: rawptr) -> ! {
	work := (^Background_Work)(parameter)
	for {
		seen := system.event_count(&work.asked)
		if !background_work_step(work) {
			system.event_wait(&work.asked, seen)
		}
	}
}

// background_work_start starts the worker thread once. A second call
// changes nothing.
background_work_start :: proc "contextless" (work: ^Background_Work) -> system.Status {
	if work.started {
		return .Ok
	}
	thread, status := system.thread_start(background_worker, work, BACKGROUND_STACK_PAGES)
	if status != .Ok {
		return status
	}
	work.thread, work.started = thread, true
	return .Ok
}
