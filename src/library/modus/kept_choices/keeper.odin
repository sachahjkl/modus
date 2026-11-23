package kept_choices

// The keeper of the chosen values of one owner (src/md/features/
// module_settings.md, "Module settings"): the kept record of the owner, the
// changes that come before its read ends, and the next job of the store.
// This file is pure: it decides each job and takes each end, and never
// calls the store. worker.odin runs the jobs on a worker thread, so the
// loop of an owner with a window never waits for the store.

import "modus:contract/chosen_values"

// The room of the kept record: one page holds about a hundred names. A
// record past it is read as one that this release cannot read, and stays
// as it is.
KEPT_RECORD_BYTES :: 4096

// The changes that wait for the end of the read: one for each name, the
// last one of a name in place of the one before. An owner has fewer
// settings than this.
PENDING_CAPACITY :: 32

// The job of the store that the keeper asks for now.
Job :: enum u8 {
	None  = 0,
	Read  = 1, // Read the kept record, once.
	Write = 2, // Write the kept record of this run.
}

// What went wrong at the end of a job: the owner writes its own line of
// the log for it.
Fault :: enum u8 {
	None       = 0,
	Not_Read   = 1, // The store did not give the record: the changes of this run hold for this run only, and the record stays as it is.
	Unreadable = 2, // The record is not one that this release reads: the defaults hold, and the record stays until the principal changes a value.
	Not_Kept   = 3, // The store did not keep a write: the change holds for this run only.
}

// The result of a change.
Change_Result :: enum u8 {
	Taken    = 0, // The change holds, and the keeper keeps it.
	No_Room  = 1, // The record or the changes before the read have no room for it: nothing changed.
	No_Store = 2, // The owner has no store: nothing changed.
}

Keeper :: struct {
	store_open:      bool,
	read_wanted:     bool, // The owner asked for the read: after its first frame.
	read:            bool, // The read ended.
	dirty:           bool, // The kept record holds a change that the store does not hold yet.
	job:             Job, // The job that runs, or None.
	// The bytes of the job: the record that the store gave, or the one that
	// it writes. The owner touches them only while no job runs.
	job_bytes:       [KEPT_RECORD_BYTES]u8,
	job_length:      int,
	// The record in force: what the store gave, with the changes of this
	// run. Always a record of chosen values.
	kept_bytes:      [KEPT_RECORD_BYTES]u8,
	kept_length:     int,
	scratch_bytes:   [KEPT_RECORD_BYTES]u8,
	pending:         [PENDING_CAPACITY]chosen_values.Change,
	pending_count:   int,
	problem:         chosen_values.Record_Problem, // With Unreadable.
}

// keeper_start makes the record empty, and says if the owner has a store.
keeper_start :: proc "contextless" (keeper: ^Keeper, store_open: bool) {
	keeper^ = {}
	keeper.store_open = store_open
	keeper.kept_length, _ = chosen_values.write_record({}, {}, keeper.kept_bytes[:])
}

// keeper_record gives the record in force. It holds bytes of the keeper:
// read it before the next change.
keeper_record :: proc "contextless" (keeper: ^Keeper) -> chosen_values.Record {
	record, _ := chosen_values.read_record(keeper.kept_bytes[:keeper.kept_length])
	return record
}

// keeper_next_job gives the job to ask for when none runs: the read once
// the owner wants it, then a write of each record that the store does not
// hold. None: nothing to ask.
keeper_next_job :: proc "contextless" (keeper: ^Keeper) -> Job {
	if !keeper.store_open || keeper.job != .None {
		return .None
	}
	if !keeper.read {
		if !keeper.read_wanted {
			return .None
		}
		keeper.job = .Read
		return .Read
	}
	if !keeper.dirty {
		return .None
	}
	keeper.dirty = false
	copy(keeper.job_bytes[:], keeper.kept_bytes[:keeper.kept_length])
	keeper.job_length = keeper.kept_length
	keeper.job = .Write
	return .Write
}

// keeper_job_refused takes back a job that the worker did not take: it is
// asked again at the next step.
keeper_job_refused :: proc "contextless" (keeper: ^Keeper) {
	if keeper.job == .Write {
		keeper.dirty = true
	}
	keeper.job = .None
}

// keeper_read_ended takes the end of the read: length bytes of job_bytes,
// found when the store holds the object, stored when the store answered.
// The changes that came before go on the record that the store gave.
keeper_read_ended :: proc "contextless" (keeper: ^Keeper, length: int, found: bool, stored: bool) -> (fault: Fault) {
	keeper.job = .None
	keeper.read = true
	defer keeper.pending_count = 0
	if !stored {
		// A record that the store did not give is never written over in this
		// run: the next start reads it again.
		keeper.store_open = false
		return .Not_Read
	}
	base: chosen_values.Record
	if found {
		if length < 0 || length > KEPT_RECORD_BYTES {
			keeper.problem = .No_Room
			fault = .Unreadable
		} else if record, problem := chosen_values.read_record(keeper.job_bytes[:length]); problem != .None {
			keeper.problem = problem
			fault = .Unreadable
		} else {
			base = record
		}
	}
	if fault == .Unreadable && keeper.pending_count == 0 {
		// Nothing of this run goes over a record that this release cannot
		// read: the defaults hold, and no write is asked.
		keeper.kept_length, _ = chosen_values.write_record({}, {}, keeper.kept_bytes[:])
		return fault
	}
	// A change of the principal starts a new record over one that this
	// release cannot read: the principal acted.
	written, problem := chosen_values.write_record(base, keeper.pending[:keeper.pending_count], keeper.scratch_bytes[:])
	if problem != .None {
		// The record of the store has no room for the changes of before: it
		// holds, and those changes are lost.
		written, _ = chosen_values.write_record(base, {}, keeper.scratch_bytes[:])
	}
	copy(keeper.kept_bytes[:], keeper.scratch_bytes[:written])
	keeper.kept_length = written
	keeper.dirty = keeper.pending_count > 0 && problem == .None
	return fault
}

// keeper_write_ended takes the end of a write.
keeper_write_ended :: proc "contextless" (keeper: ^Keeper, stored: bool) -> Fault {
	keeper.job = .None
	return stored ? .None : .Not_Kept
}

// keeper_change makes changes hold at once, and has the keeper keep them.
// The owner checked each word at its border. Before the read ends, the
// changes wait to go on the record that the store gives.
keeper_change :: proc "contextless" (keeper: ^Keeper, changes: []chosen_values.Change) -> Change_Result {
	if !keeper.store_open {
		return .No_Store
	}
	return keeper_change_for_this_run(keeper, changes)
}

// keeper_change_for_this_run makes changes hold, with a store or not: a
// press of the principal on the desktop holds for this run even when
// nothing keeps it.
keeper_change_for_this_run :: proc "contextless" (keeper: ^Keeper, changes: []chosen_values.Change) -> Change_Result {
	written, problem := chosen_values.write_record(keeper_record(keeper), changes, keeper.scratch_bytes[:])
	if problem != .None {
		return .No_Room
	}
	if keeper.store_open && !keeper.read {
		pending := keeper.pending
		count := keeper.pending_count
		for change in changes {
			place := count
			for index in 0 ..< count {
				if pending[index].name == change.name {
					place = index
				}
			}
			if place == PENDING_CAPACITY {
				return .No_Room
			}
			pending[place] = change
			count = max(count, place + 1)
		}
		keeper.pending, keeper.pending_count = pending, count
	}
	copy(keeper.kept_bytes[:], keeper.scratch_bytes[:written])
	keeper.kept_length = written
	keeper.dirty = keeper.store_open && keeper.read
	return .Taken
}
