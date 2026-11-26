// Dedicated storage and root-ring worker thread for files
// (src/md/features/store_explorer.md).
// Owns storage.Client, open subtree storage.Place stack, off-thread filtering,
// chunked BLAKE3 hashing, copy-on-write version preview/compare/restore, and
// Root_Command.Start_Edit launches over GRANT_ROOT.
package files

import "base:intrinsics"
import core "internal:files/files_core"
import "modus:ast_codebase"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/storage_status"
import "modus:storage"
import "modus:system"

// Plan value: 128 KiB worker stack for storage RPCs, root-ring waits, MODAST1 cycle validation, and BLAKE3 streaming.
WORKER_THREAD_STACK_PAGES :: u64(32)

// Inline capacity: storage.list page rows and names buffer per RPC.
LIST_PAGE_ROWS :: 64
LIST_NAMES_BYTES :: LIST_PAGE_ROWS * core.ENTRY_NAME_MAX_BYTES

// Inline capacity: chunk buffer for streaming object reads and BLAKE3 hashing.
READ_CHUNK_BYTES :: 32768

// Shared UI <-> worker queues and double-buffered immutable snapshots.
worker_lock: system.Lock
req_queue: core.Ring_Queue(core.Worker_Request)
res_queue: core.Ring_Queue(core.Worker_Result)
req_event: system.Event
res_event: system.Event
res_space_event: system.Event
snapshot_acked_event: system.Event
snapshot_in_flight: bool
active_snapshot: int
snapshots: [2]core.Explorer_Snapshot

// Worker-owned storage and root-ring state (never accessed by UI thread).
worker_store: storage.Client
worker_store_opened: bool
worker_store_read_only: bool

worker_root_handle: system.Handle
worker_root_ring: ring.Ring
worker_root_tag: u32
worker_has_root: bool

// Open tree handle stack: place_stack[0] is the root of the active store
// (storage.ROOT for private store, or opened store handle from open_store).
place_stack: [core.MAX_PATH_DEPTH + 1]storage.Place
place_depth: int
active_store_custom_root: bool

// Worker scratch buffers (module BSS, never on thread stack).
list_rows_buf: [LIST_PAGE_ROWS]storage.Listed
list_names_buf: [LIST_NAMES_BYTES]u8
read_chunk_buf: [READ_CHUNK_BYTES]u8
worker_ast_scratch: ast_codebase.Codebase
worker_ast_text_buf: [core.PREVIEW_MAX_BYTES]u8

// UI-thread queue helpers.
worker_push_request :: proc "contextless" (req: ^core.Worker_Request) -> bool {
	system.lock(&worker_lock)
	ok := core.queue_push(&req_queue, req)
	system.unlock(&worker_lock)
	if ok {
		system.event_wake(&req_event)
	}
	return ok
}

worker_pop_result :: proc "contextless" (out: ^core.Worker_Result) -> bool {
	system.lock(&worker_lock)
	ok := core.queue_pop(&res_queue, out)
	system.unlock(&worker_lock)
	if ok {
		system.event_wake(&res_space_event)
	}
	return ok
}

worker_ack_snapshot :: proc "contextless" (new_index: int) {
	system.lock(&worker_lock)
	active_snapshot = new_index
	snapshot_in_flight = false
	system.unlock(&worker_lock)
	system.event_wake(&snapshot_acked_event)
}

@(private = "file")
worker_acquire_back_snapshot :: proc "contextless" () -> (index: int, snap: ^core.Explorer_Snapshot) {
	for {
		seen := system.event_count(&snapshot_acked_event)
		system.lock(&worker_lock)
		in_flight := snapshot_in_flight
		cur := active_snapshot
		system.unlock(&worker_lock)
		if !in_flight {
			back := 1 - cur
			snapshots[back] = snapshots[cur]
			return back, &snapshots[back]
		}
		system.event_wait(&snapshot_acked_event, seen)
	}
}

@(private = "file")
worker_publish_result :: proc "contextless" (res: ^core.Worker_Result, owns_snapshot: bool) {
	res.has_snapshot = owns_snapshot
	for {
		seen := system.event_count(&res_space_event)
		system.lock(&worker_lock)
		pushed := core.queue_push(&res_queue, res)
		if pushed && owns_snapshot {
			snapshot_in_flight = true
		}
		system.unlock(&worker_lock)
		if pushed {
			system.event_wake(&res_event)
			return
		}
		system.event_wait(&res_space_event, seen)
	}
}

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
current_place :: proc "contextless" () -> storage.Place {
	return place_stack[clamp(place_depth, 0, core.MAX_PATH_DEPTH)]
}

@(private = "file")
close_places_above :: proc "contextless" (target_depth: int) {
	for place_depth > target_depth {
		if worker_store_opened && place_stack[place_depth] != storage.ROOT {
			_ = storage.close_tree(&worker_store, place_stack[place_depth])
		}
		place_stack[place_depth] = storage.ROOT
		place_depth -= 1
	}
}

@(private = "file")
close_all_places :: proc "contextless" () {
	close_places_above(0)
	if active_store_custom_root && worker_store_opened && place_stack[0] != storage.ROOT {
		_ = storage.close_tree(&worker_store, place_stack[0])
	}
	place_stack[0] = storage.ROOT
	active_store_custom_root = false
}

@(private = "file")
check_store_connected :: proc "contextless" () -> bool {
	if !worker_store_opened {
		return false
	}
	if !storage.connected(&worker_store) {
		worker_store_opened = false
		worker_store_read_only = true
		system.log_fact(.Info, Store_Revoked{})
		return false
	}
	return true
}

@(private = "file")
load_usage :: proc "contextless" (snap: ^core.Explorer_Snapshot) {
	snap.usage = {}
	if !worker_store_opened {
		return
	}
	counts, st := storage.usage(&worker_store)
	if st == .Ok {
		snap.usage = {
			objects   = counts.objects,
			trees     = counts.trees,
			versions  = counts.versions,
			blocks    = counts.blocks,
			limit     = counts.limit,
			has_usage = true,
		}
	}
}

// load_accessible_stores always places this process's private store ("private",
// matching place_stack[0] == storage.ROOT) at index 0, then appends any other
// principal stores returned by the storage service `stores` export.
@(private = "file")
load_accessible_stores :: proc "contextless" (snap: ^core.Explorer_Snapshot) {
	snap.store_count = 0
	snap.active_store = 0
	if !worker_store_opened {
		return
	}
	priv := &snap.stores[0]
	priv^ = {}
	copy(priv.name[:], "private")
	priv.name_len = 7
	snap.store_count = 1

	_, text, st, _ := storage.call(&worker_store, "stores", nil)
	if st == .Ok && len(text) > 0 && core.MAX_STORES > 1 {
		extra := core.parse_stores_listing(text, snap.stores[1:])
		snap.store_count = 1 + extra
	}
}

@(private = "file")
clear_version_state :: proc "contextless" (snap: ^core.Explorer_Snapshot) {
	snap.version_count = 0
	snap.versions_truncated = false
	snap.version_chosen = 0
	snap.preview_generation = 0
	snap.diff_count = 0
}

@(private = "file")
load_tree_entries :: proc "contextless" (snap: ^core.Explorer_Snapshot, keep_filter: bool) -> core.Problem_Kind {
	snap.entry_count = 0
	snap.entries_truncated = false
	clear_version_state(snap)
	if !check_store_connected() {
		return .Store_Revoked
	}
	place := current_place()
	after_buf: [core.ENTRY_NAME_MAX_BYTES]u8
	after := ""
	for {
		err: errors.Error_Record
		page, st := storage.list(&worker_store, place, after, list_rows_buf[:], list_names_buf[:], &err)
		if st == .Gone {
			worker_store_opened = false
			worker_store_read_only = true
			system.log_fact(.Info, Store_Revoked{})
			return .Store_Revoked
		}
		if st != .Ok {
			system.log_fact(.Info, Store_Call_Refused(errors.error_record_fact_fields(err)))
			return .Tree_Read_Refused
		}
		if len(page) == 0 {
			break
		}
		advanced := false
		for row in page {
			kind, known := storage.entry_kind_of_word(row.kind)
			start, count := int(row.name_offset), int(row.name_count)
			if start < 0 || count <= 0 || count > core.ENTRY_NAME_MAX_BYTES || start > len(list_names_buf) || count > len(list_names_buf) - start {
				continue
			}
			name := string(list_names_buf[start:][:count])
			after = string(after_buf[:copy(after_buf[:], name)])
			advanced = true
			if !known {
				continue
			}
			if snap.entry_count >= core.MAX_TREE_ENTRIES {
				snap.entries_truncated = true
				break
			}
			e := &snap.entries[snap.entry_count]
			e^ = {
				name_len   = u16(count),
				kind       = kind == .Tree ? .Tree : .Object,
				size       = row.size,
				generation = row.generation,
			}
			copy(e.name[:count], name)
			snap.entry_count += 1
		}
		if !advanced || snap.entries_truncated {
			break
		}
	}
	filter_q := keep_filter ? string(snap.filter_text[:snap.filter_len]) : ""
	core.filter_entries_off_thread(snap, filter_q)
	load_usage(snap)
	return .None
}

// Storage read callbacks for core.inspect_object_stream.
Object_Read_Ctx :: struct {
	place:      storage.Place,
	name:       string,
	generation: i64, // 0 reads current state; >0 reads historical CoW version.
}

@(private = "file")
read_object_chunk :: proc "contextless" (ud: rawptr, offset: u64, dst: []u8) -> ([]u8, core.Problem_Kind) {
	rc := (^Object_Read_Ctx)(ud)
	err: errors.Error_Record
	part: []u8
	st: storage_status.Status
	if rc.generation > 0 {
		part, st = storage.version_range(&worker_store, rc.place, rc.name, rc.generation, offset, dst, &err)
	} else {
		part, st = storage.read_range(&worker_store, rc.place, rc.name, offset, dst, &err)
	}
	switch st {
	case .Ok:
		return part, .None
	case .Damaged:
		return nil, .Object_Damaged
	case .Gone:
		worker_store_opened = false
		worker_store_read_only = true
		system.log_fact(.Info, Store_Revoked{})
		return nil, .Store_Revoked
	case .Absent, .Refused, .Failed, .No_Answer, .Too_Small:
		return nil, rc.generation > 0 ? .Version_Unreadable : .Object_Unreadable
	}
	return nil, .Object_Unreadable
}

@(private = "file")
inspect_selected_object :: proc "contextless" (snap: ^core.Explorer_Snapshot, generation: i64 = 0) -> core.Problem_Kind {
	entry, ok := core.snapshot_filtered_entry(snap, snap.selected_entry)
	if !ok || entry.kind != .Object {
		snap.has_object = false
		snap.preview_len = 0
		snap.preview_line_count = 0
		snap.preview_language = .Plain
		snap.has_hash = false
		return .None
	}
	if !check_store_connected() {
		return .Store_Revoked
	}
	name := string(entry.name[:entry.name_len])
	target_size := entry.size
	if generation > 0 {
		for i in 0 ..< snap.version_count {
			if snap.versions[i].generation == generation {
				target_size = snap.versions[i].bytes
				break
			}
		}
	}
	rc := Object_Read_Ctx{place = current_place(), name = name, generation = generation}
	return core.inspect_object_stream(snap, name, target_size, generation > 0 ? generation : entry.generation, read_object_chunk, &rc, read_chunk_buf[:], &worker_ast_scratch, worker_ast_text_buf[:])
}

@(private = "file")
worker_open_in_editor :: proc "contextless" (snap: ^core.Explorer_Snapshot) -> core.Problem_Kind {
	if !worker_has_root || worker_root_ring.head == nil {
		system.log_fact(.Info, Edit_Open_Refused{})
		return .Edit_Open_Refused
	}
	store_buf: [core.STORE_NAME_MAX_BYTES]u8
	store_name := core.resolve_edit_store_name(snap, store_buf[:])
	if store_refusal, _ := root_ring.edit_store_validate(store_name); store_refusal != .None {
		system.log_fact(.Info, Edit_Open_Refused{})
		return .Edit_Open_Refused
	}
	path_buf: [root_ring.EDIT_TARGET_PATH_LIMIT]u8
	object_path, path_ok := core.build_edit_object_path(snap, path_buf[:])
	if !path_ok {
		system.log_fact(.Info, Edit_Open_Refused{})
		return .Edit_Open_Refused
	}
	path_memory, create_status := system.memory_create(1)
	if create_status != .Succeeded {
		system.log_fact(.Info, Edit_Open_Refused{})
		return .Edit_Open_Refused
	}
	mapped, map_status := system.memory_map(path_memory)
	if map_status != .Succeeded {
		system.close(path_memory)
		system.log_fact(.Info, Edit_Open_Refused{})
		return .Edit_Open_Refused
	}
	intrinsics.mem_copy_non_overlapping(mapped, raw_data(object_path), len(object_path))
	system.memory_unmap(mapped)
	given_path, give_status := system.give(worker_root_handle, path_memory, {.Read})
	system.close(path_memory)
	if give_status != .Succeeded {
		system.log_fact(.Info, Edit_Open_Refused{})
		return .Edit_Open_Refused
	}
	packed := system.name_pack(store_name)
	completion, answered := worker_root_call(
		.Start_Edit,
		{0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3], 4 = u64(given_path), 5 = u64(len(object_path)), 6 = 0},
	)
	if !answered {
		system.log_fact(.Info, Edit_Open_Refused{})
		return .Edit_Open_Refused
	}
	if outcome, _ := call_outcome.completion_outcome(completion.kind, completion.values); outcome != .Succeeded {
		system.log_fact(.Info, Edit_Open_Refused{})
		return .Edit_Open_Refused
	}
	system.log_fact(.Info, Editor_Opened{})
	return .None
}

@(private = "file")
worker_handle_request :: proc "contextless" (ctx: ^system.Context, req: ^core.Worker_Request) {
	res: core.Worker_Result
	res.serial = req.serial
	res.store_connected = worker_store_opened
	res.read_only = worker_store_read_only

	switch req.kind {
	case .None:
		return

	case .Open_Initial:
		res.kind = .Opened
		if ctx != nil && ctx.handles[system.GRANT_ROOT] != 0 {
			if opened_ring, ring_status := system.ring_open(ctx.handles[system.GRANT_ROOT]); ring_status == .Succeeded {
				worker_root_handle = ctx.handles[system.GRANT_ROOT]
				worker_root_ring = opened_ring
				worker_has_root = true
			}
		}
		worker_store, worker_store_opened = storage.open(ctx)
		res.store_connected = worker_store_opened
		if !worker_store_opened {
			worker_store_read_only = true
			res.read_only = true
			res.problem = .No_Store
			system.log_fact(.Info, No_Store{})
			worker_publish_result(&res, false)
			return
		}
		place_stack[0] = storage.ROOT
		place_depth = 0
		active_store_custom_root = false

		back_idx, snap := worker_acquire_back_snapshot()
		snap^ = {}
		snap.serial = req.serial
		snap.selected_entry = -1
		load_accessible_stores(snap)
		res.problem = load_tree_entries(snap, false)
		if res.problem == .None && snap.filtered_count > 0 {
			res.problem = inspect_selected_object(snap, 0)
		}
		system.log_fact(.Info, Store_Opened{entries = u64(snap.entry_count), stores = u64(snap.store_count)})
		res.snapshot_index = back_idx
		res.store_connected = worker_store_opened
		res.read_only = worker_store_read_only
		worker_publish_result(&res, true)

	case .Select_Store:
		res.kind = .Tree_Loaded
		if !check_store_connected() {
			res.store_connected = false
			res.read_only = true
			res.problem = .Store_Revoked
			worker_publish_result(&res, false)
			return
		}
		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		if req.index < 0 || req.index >= snap.store_count {
			res.snapshot_index = back_idx
			worker_publish_result(&res, true)
			return
		}
		// Index 0 is always this process's private store (storage.ROOT).
		if req.index == 0 {
			close_all_places()
			place_stack[0] = storage.ROOT
			active_store_custom_root = false
		} else {
			// Open the target store BEFORE mutating place_stack or snap so a refusal
			// leaves the previously open store and its entries intact.
			store_name := core.snapshot_store_name(snap, req.index)
			err: errors.Error_Record
			opened, st := storage.open_store(&worker_store, store_name, &err)
			if st != .Ok {
				res.problem = st == .Gone ? .Store_Revoked : .Store_Open_Refused
				if st == .Gone {
					worker_store_opened = false
					worker_store_read_only = true
					system.log_fact(.Info, Store_Revoked{})
				} else {
					system.log_fact(.Info, Store_Call_Refused(errors.error_record_fact_fields(err)))
				}
				res.snapshot_index = back_idx
				res.store_connected = worker_store_opened
				res.read_only = worker_store_read_only
				worker_publish_result(&res, true)
				return
			}
			close_all_places()
			place_stack[0] = opened
			active_store_custom_root = true
		}
		snap.path_depth = 0
		snap.active_store = req.index
		res.problem = load_tree_entries(snap, false)
		if res.problem == .None {
			res.problem = inspect_selected_object(snap, 0)
		}
		res.snapshot_index = back_idx
		res.store_connected = worker_store_opened
		res.read_only = worker_store_read_only
		worker_publish_result(&res, true)

	case .Enter_Tree:
		res.kind = .Tree_Loaded
		if !check_store_connected() {
			res.store_connected = false
			res.read_only = true
			res.problem = .Store_Revoked
			worker_publish_result(&res, false)
			return
		}
		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		entry, ok := core.snapshot_filtered_entry(snap, req.index)
		if !ok || entry.kind != .Tree {
			res.snapshot_index = back_idx
			worker_publish_result(&res, true)
			return
		}
		if place_depth >= core.MAX_PATH_DEPTH {
			res.problem = .Path_Too_Deep
			res.snapshot_index = back_idx
			worker_publish_result(&res, true)
			return
		}
		tree_name := string(entry.name[:entry.name_len])
		err: errors.Error_Record
		opened, st := storage.open_tree(&worker_store, current_place(), tree_name, &err)
		if st != .Ok {
			res.problem = st == .Gone ? .Store_Revoked : .Tree_Read_Refused
			if st == .Gone {
				worker_store_opened = false
				worker_store_read_only = true
				system.log_fact(.Info, Store_Revoked{})
			}
			res.snapshot_index = back_idx
			res.store_connected = worker_store_opened
			res.read_only = worker_store_read_only
			worker_publish_result(&res, true)
			return
		}
		seg := &snap.path[place_depth]
		seg^ = {name_len = entry.name_len}
		copy(seg.name[:entry.name_len], entry.name[:entry.name_len])
		place_depth += 1
		place_stack[place_depth] = opened
		snap.path_depth = place_depth
		snap.selected_entry = 0
		res.problem = load_tree_entries(snap, false)
		if res.problem == .None {
			res.problem = inspect_selected_object(snap, 0)
		}
		res.snapshot_index = back_idx
		res.store_connected = worker_store_opened
		res.read_only = worker_store_read_only
		worker_publish_result(&res, true)

	case .Navigate_Up, .Navigate_Depth:
		res.kind = .Tree_Loaded
		if !check_store_connected() {
			res.store_connected = false
			res.read_only = true
			res.problem = .Store_Revoked
			worker_publish_result(&res, false)
			return
		}
		target := req.kind == .Navigate_Up ? max(place_depth - 1, 0) : clamp(req.index, 0, place_depth)
		close_places_above(target)
		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		snap.path_depth = place_depth
		snap.selected_entry = 0
		res.problem = load_tree_entries(snap, false)
		if res.problem == .None {
			res.problem = inspect_selected_object(snap, 0)
		}
		res.snapshot_index = back_idx
		res.store_connected = worker_store_opened
		res.read_only = worker_store_read_only
		worker_publish_result(&res, true)

	case .Select_Entry:
		res.kind = .Object_Inspected
		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		if req.index >= 0 && req.index < snap.filtered_count {
			snap.selected_entry = req.index
			clear_version_state(snap)
			res.problem = inspect_selected_object(snap, 0)
		}
		res.snapshot_index = back_idx
		res.store_connected = worker_store_opened
		res.read_only = worker_store_read_only
		worker_publish_result(&res, true)

	case .Apply_Filter:
		res.kind = .Filtered
		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		q := string(req.text[:min(req.text_len, core.FILTER_MAX_BYTES)])
		core.filter_entries_off_thread(snap, q)
		clear_version_state(snap)
		res.problem = inspect_selected_object(snap, 0)
		res.snapshot_index = back_idx
		res.store_connected = worker_store_opened
		res.read_only = worker_store_read_only
		worker_publish_result(&res, true)

	case .Refresh:
		res.kind = .Tree_Loaded
		if !check_store_connected() {
			res.store_connected = false
			res.read_only = true
			res.problem = .Store_Revoked
			worker_publish_result(&res, false)
			return
		}
		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		res.problem = load_tree_entries(snap, true)
		if res.problem == .None {
			res.problem = inspect_selected_object(snap, 0)
		}
		res.snapshot_index = back_idx
		res.store_connected = worker_store_opened
		res.read_only = worker_store_read_only
		worker_publish_result(&res, true)

	case .Create_Object, .Create_Tree:
		res.kind = .Entry_Changed
		if worker_store_read_only || !check_store_connected() {
			res.store_connected = worker_store_opened
			res.read_only = true
			res.problem = worker_store_opened ? .Read_Only : .Store_Revoked
			worker_publish_result(&res, false)
			return
		}
		name := string(req.text[:min(req.text_len, core.ENTRY_NAME_MAX_BYTES)])
		if !core.validate_entry_name(name) {
			res.problem = .Name_Refused
			worker_publish_result(&res, false)
			return
		}
		kind_word := req.kind == .Create_Tree ? i64(storage.Entry_Kind.Tree) : i64(storage.Entry_Kind.Object)
		rows := [1]storage.Add_Row{{name_offset = 0, name_count = i64(len(name)), kind = kind_word}}
		err: errors.Error_Record
		gen, st := storage.add(&worker_store, current_place(), rows[:], transmute([]u8)name, &err)
		if st != .Ok {
			if st == .Gone {
				worker_store_opened = false
				worker_store_read_only = true
				res.store_connected = false
				res.read_only = true
				res.problem = .Store_Revoked
				system.log_fact(.Info, Store_Revoked{})
			} else {
				res.problem = err.kind == i64(errors.Kind.Exists) ? .Entry_Exists : .Write_Refused
				system.log_fact(.Info, Store_Call_Refused(errors.error_record_fact_fields(err)))
			}
			worker_publish_result(&res, false)
			return
		}
		system.log_fact(.Info, Entry_Created{generation = gen})
		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		res.problem = load_tree_entries(snap, true)
		if res.problem == .None {
			res.problem = inspect_selected_object(snap, 0)
		}
		res.snapshot_index = back_idx
		res.store_connected = worker_store_opened
		res.read_only = worker_store_read_only
		worker_publish_result(&res, true)

	case .Remove_Entry:
		res.kind = .Entry_Changed
		if worker_store_read_only || !check_store_connected() {
			res.store_connected = worker_store_opened
			res.read_only = true
			res.problem = worker_store_opened ? .Read_Only : .Store_Revoked
			worker_publish_result(&res, false)
			return
		}
		name := string(req.text[:min(req.text_len, core.ENTRY_NAME_MAX_BYTES)])
		err: errors.Error_Record
		gen, st := storage.remove(&worker_store, current_place(), name, &err)
		if st != .Ok {
			if st == .Gone {
				worker_store_opened = false
				worker_store_read_only = true
				res.store_connected = false
				res.read_only = true
				res.problem = .Store_Revoked
				system.log_fact(.Info, Store_Revoked{})
			} else {
				res.problem = .Remove_Refused
				system.log_fact(.Info, Store_Call_Refused(errors.error_record_fact_fields(err)))
			}
			worker_publish_result(&res, false)
			return
		}
		system.log_fact(.Info, Entry_Removed{generation = gen})
		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		res.problem = load_tree_entries(snap, true)
		if res.problem == .None {
			res.problem = inspect_selected_object(snap, 0)
		}
		res.snapshot_index = back_idx
		res.store_connected = worker_store_opened
		res.read_only = worker_store_read_only
		worker_publish_result(&res, true)

	case .List_Versions:
		res.kind = .Versions_Listed
		if !check_store_connected() {
			res.store_connected = false
			res.read_only = true
			res.problem = .Store_Revoked
			worker_publish_result(&res, false)
			return
		}
		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		entry, ok := core.snapshot_filtered_entry(snap, snap.selected_entry)
		if !ok || entry.kind != .Object {
			res.problem = .Version_Unreadable
			res.snapshot_index = back_idx
			worker_publish_result(&res, true)
			return
		}
		raw_vers: [core.MAX_VERSION_ROWS]storage.Version
		err: errors.Error_Record
		rows, total, st := storage.versions(&worker_store, current_place(), string(entry.name[:entry.name_len]), raw_vers[:], &err)
		if st != .Ok || len(rows) == 0 {
			res.problem = st == .Gone ? .Store_Revoked : .Version_Unreadable
			if st == .Gone {
				worker_store_opened = false
				worker_store_read_only = true
				system.log_fact(.Info, Store_Revoked{})
			}
			res.snapshot_index = back_idx
			res.store_connected = worker_store_opened
			res.read_only = worker_store_read_only
			worker_publish_result(&res, true)
			return
		}
		snap.version_count = len(rows)
		snap.versions_truncated = total > i64(len(rows))
		for row, i in rows {
			snap.versions[i] = {
				generation = row.generation,
				date       = row.date,
				bytes      = row.bytes,
				own_blocks = row.own_blocks,
				current    = row.current != 0,
			}
		}
		snap.version_chosen = snap.version_count - 1
		snap.preview_generation = snap.versions[snap.version_chosen].generation
		snap.diff_count = 0
		res.snapshot_index = back_idx
		res.store_connected = worker_store_opened
		res.read_only = worker_store_read_only
		worker_publish_result(&res, true)

	case .Preview_Version:
		res.kind = .Version_Previewed
		if !check_store_connected() {
			res.store_connected = false
			res.read_only = true
			res.problem = .Store_Revoked
			worker_publish_result(&res, false)
			return
		}
		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		if req.generation <= 0 {
			snap.preview_generation = 0
			snap.diff_count = 0
			res.problem = inspect_selected_object(snap, 0)
			res.snapshot_index = back_idx
			worker_publish_result(&res, true)
			return
		}
		if req.index >= 0 && req.index < snap.version_count {
			snap.version_chosen = req.index
		}
		snap.preview_generation = req.generation
		res.problem = inspect_selected_object(snap, req.generation)

		// Compare previewed version against the true current version (from the
		// current == true row, falling back to entry.generation when versions are truncated).
		snap.diff_count = 0
		entry, ok := core.snapshot_filtered_entry(snap, snap.selected_entry)
		if ok && entry.kind == .Object {
			current_gen := entry.generation
			for i in 0 ..< snap.version_count {
				if snap.versions[i].current {
					current_gen = snap.versions[i].generation
					break
				}
			}
			if current_gen > 0 && current_gen != req.generation {
				raw_diff: [core.MAX_DIFF_RANGES]storage.Byte_Range
				diff_rows, diff_st := storage.compare(&worker_store, current_place(), string(entry.name[:entry.name_len]), req.generation, current_gen, raw_diff[:])
				if diff_st == .Ok {
					snap.diff_count = len(diff_rows)
					for d, i in diff_rows {
						snap.diff_ranges[i] = {first = d.first, count = d.count}
					}
				}
			}
		}
		res.snapshot_index = back_idx
		res.store_connected = worker_store_opened
		res.read_only = worker_store_read_only
		worker_publish_result(&res, true)

	case .Restore_Version:
		res.kind = .Version_Restored
		if worker_store_read_only || !check_store_connected() {
			res.store_connected = worker_store_opened
			res.read_only = true
			res.problem = worker_store_opened ? .Read_Only : .Store_Revoked
			worker_publish_result(&res, false)
			return
		}
		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		entry, ok := core.snapshot_filtered_entry(snap, snap.selected_entry)
		if !ok || entry.kind != .Object {
			res.problem = .Restore_Refused
			res.snapshot_index = back_idx
			worker_publish_result(&res, true)
			return
		}
		err: errors.Error_Record
		new_gen, st := storage.restore(&worker_store, current_place(), string(entry.name[:entry.name_len]), req.generation, &err)
		if st != .Ok || new_gen < 0 {
			res.problem = st == .Gone ? .Store_Revoked : .Restore_Refused
			if st == .Gone {
				worker_store_opened = false
				worker_store_read_only = true
				system.log_fact(.Info, Store_Revoked{})
			}
			res.snapshot_index = back_idx
			res.store_connected = worker_store_opened
			res.read_only = worker_store_read_only
			worker_publish_result(&res, true)
			return
		}
		system.log_fact(.Info, Version_Restored{from_generation = req.generation, to_generation = new_gen})
		res.problem = load_tree_entries(snap, true)
		if res.problem == .None {
			res.problem = inspect_selected_object(snap, 0)
		}
		res.snapshot_index = back_idx
		res.store_connected = worker_store_opened
		res.read_only = worker_store_read_only
		worker_publish_result(&res, true)

	case .Open_In_Editor:
		res.kind = .Editor_Opened
		// Ensure any prior snapshot publish is settled before reading active_snapshot.
		for {
			seen := system.event_count(&snapshot_acked_event)
			system.lock(&worker_lock)
			in_flight := snapshot_in_flight
			cur := active_snapshot
			system.unlock(&worker_lock)
			if !in_flight {
				res.problem = worker_open_in_editor(&snapshots[cur])
				break
			}
			system.event_wait(&snapshot_acked_event, seen)
		}
		res.store_connected = worker_store_opened
		res.read_only = worker_store_read_only
		worker_publish_result(&res, false)
	}
}

worker_thread_entry :: proc "c" (parameter: rawptr) -> ! {
	ctx := (^system.Context)(parameter)
	req: core.Worker_Request
	for {
		seen := system.event_count(&req_event)
		system.lock(&worker_lock)
		taken := core.queue_pop(&req_queue, &req)
		system.unlock(&worker_lock)
		if taken {
			worker_handle_request(ctx, &req)
			continue
		}
		system.event_wait(&req_event, seen)
	}
}
