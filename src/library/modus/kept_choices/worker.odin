package kept_choices

// The keeper with its store, on a worker thread: the loop of the owner
// asks, waits on the end of a job with its other waits, and takes it.

import "modus:contract/chosen_values"
import "modus:contract/errors"
import "modus:contract/storage_status"
import "modus:interface"
import "modus:storage"
import "modus:system"

// A keeper lives as long as its process: its worker holds its address, so
// it is a global variable of the owner.
Kept :: struct {
	keeper:      Keeper,
	object_name: string, // The name of the object of the record, at the root of the store.
	store:       storage.Client,
	work:        interface.Background_Work,
	// The result of the job, which the worker writes.
	found:       bool,
	status:      storage_status.Status,
	error:       errors.Error_Record,
}

// The end of one step of the loop.
Step :: struct {
	changed: bool, // The record in force changed: the owner computes its values again.
	fault:   Fault,
	error:   errors.Error_Record, // With Not_Read and Not_Kept.
	problem: chosen_values.Record_Problem, // With Unreadable.
}

// kept_open starts the keeper of an object of a store, and its worker.
// false: the owner has no store, or no worker; the values of this run hold
// for this run only.
kept_open :: proc "contextless" (kept: ^Kept, store: storage.Client, store_open: bool, object_name: string) -> bool {
	opened := store_open && interface.background_work_start(&kept.work) == .Ok
	keeper_start(&kept.keeper, opened)
	kept.object_name, kept.store = object_name, store
	return opened
}

// kept_load asks for the read of the record, once: after the first frame.
kept_load :: proc "contextless" (kept: ^Kept) {
	kept.keeper.read_wanted = true
	kept_ask(kept)
}

// kept_wait adds the end of a job to the wait of the loop. true: a job
// ended already, and the loop must not sleep.
kept_wait :: proc "contextless" (kept: ^Kept, wait: ^system.Wait) -> bool {
	if kept.keeper.job == .None {
		return false
	}
	return interface.background_work_wait(wait, &kept.work)
}

// kept_step takes the end of a job, then asks for the next one. The loop
// calls it at each turn.
kept_step :: proc "contextless" (kept: ^Kept) -> (step: Step) {
	if kept.keeper.job == .None || !interface.background_work_take(&kept.work) {
		return {}
	}
	stored := kept.status == .Ok
	switch kept.keeper.job {
	case .None:
	case .Read:
		step.fault = keeper_read_ended(&kept.keeper, kept.keeper.job_length, kept.found, stored)
		step.changed = true
		step.problem = kept.keeper.problem
	case .Write:
		step.fault = keeper_write_ended(&kept.keeper, stored)
	}
	step.error = kept.error
	kept_ask(kept)
	return step
}

// kept_change makes checked changes hold and asks for their write.
kept_change :: proc "contextless" (kept: ^Kept, changes: []chosen_values.Change) -> Change_Result {
	result := keeper_change(&kept.keeper, changes)
	kept_ask(kept)
	return result
}

// kept_change_for_this_run makes checked changes hold, with a store or not.
kept_change_for_this_run :: proc "contextless" (kept: ^Kept, changes: []chosen_values.Change) -> Change_Result {
	result := keeper_change_for_this_run(&kept.keeper, changes)
	kept_ask(kept)
	return result
}

// kept_record gives the record in force.
kept_record :: proc "contextless" (kept: ^Kept) -> chosen_values.Record {
	return keeper_record(&kept.keeper)
}

@(private = "file")
kept_ask :: proc "contextless" (kept: ^Kept) {
	if keeper_next_job(&kept.keeper) == .None {
		return
	}
	if !interface.background_work_ask(&kept.work, kept_job, kept) {
		keeper_job_refused(&kept.keeper)
	}
}

// kept_job runs on the worker: one call of the store.
@(private = "file")
kept_job :: proc "contextless" (parameter: rawptr) {
	kept := (^Kept)(parameter)
	kept.error = {}
	switch kept.keeper.job {
	case .Read:
		bytes, found, status := storage.read(&kept.store, storage.ROOT, kept.object_name, kept.keeper.job_bytes[:], &kept.error)
		kept.keeper.job_length, kept.found, kept.status = len(bytes), found, status
	case .Write:
		_, status := storage.write(&kept.store, storage.ROOT, kept.object_name, kept.keeper.job_bytes[:kept.keeper.job_length], &kept.error)
		kept.found, kept.status = false, status
	case .None:
	}
}
