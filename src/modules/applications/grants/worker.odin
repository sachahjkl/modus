// Off-thread root-ring worker for the desktop Grants window
// (src/md/features/grants_window.md). Every root-ring query and revocation
// runs inside interface.Background_Work so the window thread never blocks.
package grants_window

import "internal:grants/grants_model"
import "modus:contract/call_outcome"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/start_grant"
import "modus:disk_process"
import "modus:interface"
import "modus:system"

// Format property: bounded status line length shown in the window header.
STATUS_TEXT_CAPACITY :: 160

Worker_Job_Kind :: enum u8 {
	Refresh        = 0,
	Revoke_Process = 1,
	Revoke_Wide    = 2,
	Disallow_Disk  = 3,
}

Worker_Request :: struct {
	kind:            Worker_Job_Kind,
	process_name:    [len(system.Name) - 1]u8,
	process_length:  int,
	root_grant:      system.Root_Grant,
	wide_key:        [32]u8,
	nickname:        [disk_process.NAME_LIMIT]u8,
	nickname_length: int,
}

Worker_Result :: struct {
	snapshot:          grants_model.Snapshot,
	has_snapshot:      bool,
	status_text:       [STATUS_TEXT_CAPACITY]u8,
	status_length:     int,
	status_is_warning: bool,
}

worker_bg: interface.Background_Work
worker_root_handle: system.Handle
worker_root_ring: ring.Ring
worker_root_tag: u32
worker_has_root: bool

// Owned by the window thread when worker_bg is Idle, and by the worker thread
// while Asked or Running (interface.Background_Work handoff).
worker_request: Worker_Request
worker_result: Worker_Result

@(private = "file")
worker_status_set :: proc "contextless" (out: ^Worker_Result, is_warning: bool, parts: ..system.Part) {
	w := system.Writer{buffer = out.status_text[:]}
	for part in parts {
		system.write_part(&w, part)
	}
	out.status_length = w.count
	out.status_is_warning = is_warning
}

@(private = "file")
worker_fact_copy :: proc "contextless" (dst: []u8, src: string) {
	n := min(len(dst), len(src))
	if n > 0 {
		copy(dst[:n], src[:n])
	}
}

// worker_start opens GRANT_ROOT and starts the single Background_Work thread.
worker_start :: proc "contextless" (ctx: ^system.Context) -> bool {
	if ctx != nil && ctx.handles[system.GRANT_ROOT] != 0 {
		if opened, status := system.ring_open(ctx.handles[system.GRANT_ROOT]); status == .Succeeded {
			worker_root_handle = ctx.handles[system.GRANT_ROOT]
			worker_root_ring = opened
			worker_has_root = true
		}
	}
	if !worker_has_root {
		system.log_fact(.Warning, No_Root_Ring{})
	}
	return interface.background_work_start(&worker_bg) == .Succeeded
}

// worker_root_call sends one command on GRANT_ROOT and waits up to the answer
// hang bound (system.ANSWER_BOUND_MILLISECONDS). Called only on the worker
// thread.
@(private = "file")
worker_root_call :: proc "contextless" (kind: root_ring.Root_Command, values: [7]u64) -> (completion: ring.Record, answered: bool) {
	if !worker_has_root || worker_root_ring.head == nil {
		return {}, false
	}
	worker_root_tag += 1
	tag := worker_root_tag
	if !system.send(&worker_root_ring.commands, ring.Record{kind = u32(kind), tag = tag, values = values}) {
		return {}, false
	}
	deadline := system.answer_deadline(system.time())
	for {
		wait := system.wait_begin()
		if record, came, done := system.root_answer_step(&worker_root_ring, tag, system.time(), deadline); done {
			return record, came
		}
		system.wait_records(&wait, &worker_root_ring.completions)
		system.wait_end(&wait, deadline)
	}
}

@(private = "file")
worker_read_snapshot :: proc "contextless" (snap: ^grants_model.Snapshot) -> (ok: bool, cause: string) {
	snap^ = {}
	if !worker_has_root {
		snap.has_error = true
		return false, "this window holds no grant to read session grants."
	}

	// 1. Active wide grant.
	wide_rec, wide_answered := worker_root_call(.Grants_Read, {0 = u64(root_ring.Grants_Read_Kind.Wide_Grant)})
	if !wide_answered {
		snap.has_error = true
		return false, "the root service gave no answer."
	}
	if outcome, _ := call_outcome.completion_outcome(wide_rec.kind, wide_rec.values); outcome != .Succeeded {
		snap.has_error = true
		return false, "the root service refused to list grants."
	}
	_ = grants_model.snapshot_set_wide_grant_completion(snap, wide_rec.values)

	// 2. Running processes with revocable or revoked grants in this session.
	proc_rec, proc_answered := worker_root_call(.Grants_Read, {0 = u64(root_ring.Grants_Read_Kind.Process), 1 = 0})
	if !proc_answered {
		snap.has_error = true
		return false, "the root service gave no answer."
	}
	if outcome, _ := call_outcome.completion_outcome(proc_rec.kind, proc_rec.values); outcome != .Succeeded {
		snap.has_error = true
		return false, "the root service refused to list process grants."
	}
	proc_total, _ := grants_model.snapshot_add_process_completion(snap, proc_rec.values)
	proc_fetch := min(proc_total, u64(grants_model.PROCESS_ROW_CAPACITY))
	for idx in u64(1) ..< proc_fetch {
		rec, answered := worker_root_call(.Grants_Read, {0 = u64(root_ring.Grants_Read_Kind.Process), 1 = idx})
		if !answered {
			snap.has_error = true
			return false, "the root service gave no answer."
		}
		if outcome, _ := call_outcome.completion_outcome(rec.kind, rec.values); outcome != .Succeeded {
			snap.has_error = true
			return false, "the root service refused to list process grants."
		}
		_, _ = grants_model.snapshot_add_process_completion(snap, rec.values)
	}
	if proc_total > u64(grants_model.PROCESS_ROW_CAPACITY) {
		snap.processes_truncated = proc_total - u64(grants_model.PROCESS_ROW_CAPACITY)
	}

	// 3. Remembered disk grants in this principal's table.
	disk_rec, disk_answered := worker_root_call(.Grants_Read, {0 = u64(root_ring.Grants_Read_Kind.Disk_Grant), 1 = 0})
	if !disk_answered {
		snap.has_error = true
		return false, "the root service gave no answer."
	}
	if outcome, _ := call_outcome.completion_outcome(disk_rec.kind, disk_rec.values); outcome != .Succeeded {
		snap.has_error = true
		return false, "the root service refused to list disk grants."
	}
	disk_total, _ := grants_model.snapshot_add_disk_completion(snap, disk_rec.values)
	disk_fetch := min(disk_total, u64(grants_model.DISK_ROW_CAPACITY))
	for idx in u64(1) ..< disk_fetch {
		rec, answered := worker_root_call(.Grants_Read, {0 = u64(root_ring.Grants_Read_Kind.Disk_Grant), 1 = idx})
		if !answered {
			snap.has_error = true
			return false, "the root service gave no answer."
		}
		if outcome, _ := call_outcome.completion_outcome(rec.kind, rec.values); outcome != .Succeeded {
			snap.has_error = true
			return false, "the root service refused to list disk grants."
		}
		_, _ = grants_model.snapshot_add_disk_completion(snap, rec.values)
	}
	if disk_total > u64(grants_model.DISK_ROW_CAPACITY) {
		snap.disks_truncated = disk_total - u64(grants_model.DISK_ROW_CAPACITY)
	}

	snap.loaded = true
	return true, ""
}

@(private = "file")
worker_job_run :: proc "contextless" (_: rawptr) {
	req := &worker_request
	res := &worker_result
	res^ = {}

	switch req.kind {
	case .Refresh:
		ok, cause := worker_read_snapshot(&res.snapshot)
		res.has_snapshot = true
		if !ok {
			worker_status_set(res, true, "Cannot read grants: ", cause)
		}
	case .Revoke_Process:
		name := string(req.process_name[:req.process_length])
		grant_name := system.root_grant_names[req.root_grant]
		packed := system.name_pack(name)
		rec, answered := worker_root_call(.Revoke, {packed[0], packed[1], packed[2], packed[3], u64(req.root_grant), 0, 0})
		if !answered {
			worker_status_set(res, true, "Cannot revoke ", grant_name, " from ", name, ": the root service gave no answer.")
			fact: Revocation_Refused
			worker_fact_copy(fact.cause[:], "no answer from the root service")
			system.log_fact(.Warning, fact)
		} else if outcome, _ := call_outcome.completion_outcome(rec.kind, rec.values); outcome != .Succeeded {
			worker_status_set(res, true, "Cannot revoke ", grant_name, " from ", name, ": the root service refused the request.")
			fact: Revocation_Refused
			worker_fact_copy(fact.cause[:], call_outcome.CALL_OUTCOME_NAMES[outcome])
			system.log_fact(.Warning, fact)
		} else {
			worker_status_set(res, false, "Revoked ", grant_name, " from ", name, ".")
			fact: Process_Grant_Revoked
			worker_fact_copy(fact.process[:], name)
			worker_fact_copy(fact.grant[:], grant_name)
			system.log_fact(.Info, fact)
		}
		_, _ = worker_read_snapshot(&res.snapshot)
		res.has_snapshot = true
	case .Revoke_Wide:
		key_words := transmute([4]u64)req.wide_key
		rec, answered := worker_root_call(.Wide_Grant_End, {key_words[0], key_words[1], key_words[2], key_words[3], 0, 0, 0})
		if !answered {
			worker_status_set(res, true, "Cannot end the active wide grant: the root service gave no answer.")
			fact: Revocation_Refused
			worker_fact_copy(fact.cause[:], "no answer from the root service")
			system.log_fact(.Warning, fact)
		} else if outcome, _ := call_outcome.completion_outcome(rec.kind, rec.values); outcome != .Succeeded {
			worker_status_set(res, true, "Cannot end the active wide grant: the root service refused the request.")
			fact: Revocation_Refused
			worker_fact_copy(fact.cause[:], call_outcome.CALL_OUTCOME_NAMES[outcome])
			system.log_fact(.Warning, fact)
		} else {
			worker_status_set(res, false, "Ended the active wide grant.")
			system.log_fact(.Info, Wide_Grant_Ended{})
		}
		_, _ = worker_read_snapshot(&res.snapshot)
		res.has_snapshot = true
	case .Disallow_Disk:
		nickname := string(req.nickname[:req.nickname_length])
		packed := disk_process.name_pack(nickname)
		rec, answered := worker_root_call(.Disk_Grant, {
			0 = packed[0],
			1 = packed[1],
			2 = packed[2],
			4 = u64(root_ring.Disk_Grant_Action.Disallow),
			5 = u64(start_grant.Grant.Store),
		})
		if !answered {
			worker_status_set(res, true, "Cannot disallow store for ", nickname, ": the root service gave no answer.")
			fact: Revocation_Refused
			worker_fact_copy(fact.cause[:], "no answer from the root service")
			system.log_fact(.Warning, fact)
		} else if outcome, _ := call_outcome.completion_outcome(rec.kind, rec.values); outcome != .Succeeded {
			worker_status_set(res, true, "Cannot disallow store for ", nickname, ": the root service refused the request.")
			fact: Revocation_Refused
			worker_fact_copy(fact.cause[:], call_outcome.CALL_OUTCOME_NAMES[outcome])
			system.log_fact(.Warning, fact)
		} else {
			worker_status_set(res, false, "Disallowed store for ", nickname, ".")
			fact: Disk_Grant_Disallowed
			worker_fact_copy(fact.nickname[:], nickname)
			worker_fact_copy(fact.grant[:], "store")
			system.log_fact(.Info, fact)
		}
		_, _ = worker_read_snapshot(&res.snapshot)
		res.has_snapshot = true
	}
}

worker_ask_refresh :: proc "contextless" () -> bool {
	if interface.background_work_busy(&worker_bg) {
		return false
	}
	worker_request = {kind = .Refresh}
	return interface.background_work_ask(&worker_bg, worker_job_run, nil)
}

worker_ask_revoke_process :: proc "contextless" (name: string, grant: system.Root_Grant) -> bool {
	if interface.background_work_busy(&worker_bg) || len(name) == 0 {
		return false
	}
	worker_request = {kind = .Revoke_Process, root_grant = grant}
	worker_request.process_length = copy(worker_request.process_name[:], name)
	return interface.background_work_ask(&worker_bg, worker_job_run, nil)
}

worker_ask_revoke_wide :: proc "contextless" (key: [32]u8) -> bool {
	if interface.background_work_busy(&worker_bg) || key == {} {
		return false
	}
	worker_request = {kind = .Revoke_Wide, wide_key = key}
	return interface.background_work_ask(&worker_bg, worker_job_run, nil)
}

worker_ask_disallow_disk :: proc "contextless" (nickname: string) -> bool {
	if interface.background_work_busy(&worker_bg) || len(nickname) == 0 {
		return false
	}
	worker_request = {kind = .Disallow_Disk}
	worker_request.nickname_length = copy(worker_request.nickname[:], nickname)
	return interface.background_work_ask(&worker_bg, worker_job_run, nil)
}
