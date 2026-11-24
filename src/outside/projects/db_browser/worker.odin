// Dedicated worker thread for db_browser (src/md/features/db_browser.md).
// Owns storage.Client, the database Memory_Object, the zero-grant isolated
// sqlite.module child call host, and off-thread sorting/schema inspection.
// Never touches window surfaces or UI state directly; communicates only via
// bounded lock-protected queues and system.Event wakeups.
package db_browser

import "core"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:random"
import "modus:storage"
import "modus:system"

DATABASE_OBJECT_NAME :: "main.db"
SQLITE_MODULE_NAME :: "sqlite"
SQLITE_STORE_OBJECT_NAME :: "sqlite.module"
HOST_STORE_OBJECT_NAME :: "host.module"

// Plan value: 10 MiB child call host budget (4 MiB memsys5 heap + 2 MiB scratch
// + ~2 MiB sqlite code/data + rings and stack).
SQLITE_HOST_PAGES :: u64(2560)

// Plan value: 4 MiB memsys5 heap matching sqlite.module ceiling.
SQLITE_DEFAULT_HEAP_BYTES :: u32(4 * 1024 * 1024)

// Inline capacity: 256 KiB initial database memory object; grows in 2x steps
// up to the computed process budget ceiling.
DB_MEMORY_INITIAL_PAGES :: u64(64)

// Computed reserve: keep 1 MiB unallocated in the process budget so UI arenas
// and IPC allocations never starve when a database grows.
DB_MEMORY_RESERVE_HEADROOM_PAGES :: u64(256)

// Plan value: 15 s call deadline for untrusted/heavy SQL statements.
SQLITE_CALL_TIMEOUT_MS :: u64(15_000)

// Plan value: 96 KiB worker thread stack for isolated calls, ChaCha20 seeding,
// and storage RPCs.
WORKER_THREAD_STACK_PAGES :: u64(24)

// Double-buffered immutable snapshots shared between worker (producer) and UI
// (consumer). UI owns snapshots[active_snapshot]; worker writes only to
// snapshots[1 - active_snapshot] and waits for snapshot_acked_event before
// reusing the previous slot.
worker_lock: system.Lock
req_queue: core.Ring_Queue(core.Worker_Request)
res_queue: core.Ring_Queue(core.Worker_Result)
req_event: system.Event
res_event: system.Event
res_space_event: system.Event
snapshot_acked_event: system.Event
snapshot_in_flight: bool
active_snapshot: int
snapshots: [2]core.Result_Snapshot

// Worker-owned state (never touched by UI thread).
worker_ctx: ^system.Context
worker_rng: random.Generator
worker_rng_ready: bool
worker_store: storage.Client
worker_store_opened: bool
worker_store_read_only: bool
worker_store_place: storage.Place = storage.ROOT
worker_current_generation: i64

// Database Memory_Object lent per call to sqlite.module.
db_memory: system.Handle
db_bytes: []u8
db_size: u64
db_capacity_pages: u64

// Dedicated memory objects for large sqlite.module append tables (> 64 KiB call region).
cells_memory: system.Handle
cells_mapped: []core.Cell_Row
payload_memory: system.Handle
payload_mapped: []u8
worker_scratch: core.Worker_Scratch

// Boot image mapping kept read-only for starting the child call host.
boot_image_handle: system.Handle
boot_image_bytes: []u8

Sqlite_Host :: struct {
	conn:             system.Call_Connection,
	sqlite_file:      []u8,
	sqlite_file_mem:  system.Handle,
	exp_open:         u32,
	exp_execute:      u32,
	exp_dirty_ranges: u32,
	exp_mark_synced:  u32,
	exp_info:         u32,
	exp_last_diag:    u32,
	exp_close:        u32,
	started:          bool,
	session_open:     bool,
}

sqlite_host: Sqlite_Host

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

// Worker-thread snapshot slot acquisition.
@(private = "file")
worker_acquire_back_snapshot :: proc "contextless" () -> (index: int, snap: ^core.Result_Snapshot) {
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

// db_ensure_capacity grows db_memory in place (between sqlite calls) up to the
// computed process budget ceiling. Never leaves dangling pointers because sqlite
// unbinds main.db before every return.
@(private = "file")
db_ensure_capacity :: proc "contextless" (needed_bytes: u64) -> bool {
	if needed_bytes <= u64(len(db_bytes)) && db_memory != 0 {
		return true
	}
	needed_pages := max((needed_bytes + system.PAGE_SIZE - 1) / system.PAGE_SIZE, DB_MEMORY_INITIAL_PAGES)
	remaining, b_status := system.budget_read()
	if b_status != .Ok {
		return false
	}
	if remaining.pages <= DB_MEMORY_RESERVE_HEADROOM_PAGES {
		return false
	}
	max_additional := remaining.pages - DB_MEMORY_RESERVE_HEADROOM_PAGES
	// When replacing an existing buffer, the old buffer's pages stay accounted
	// until closed after copying, so new_pages must fit in max_additional.
	if needed_pages > max_additional {
		return false
	}
	target_pages := max(needed_pages, db_capacity_pages * 2)
	if target_pages > max_additional {
		target_pages = needed_pages
	}
	new_mem, m_status := system.memory_create(target_pages)
	if m_status != .Ok {
		return false
	}
	new_addr, map_status := system.memory_map(new_mem)
	if map_status != .Ok {
		system.close(new_mem)
		return false
	}
	new_slice := ([^]u8)(new_addr)[:target_pages * system.PAGE_SIZE]
	if db_size > 0 && len(db_bytes) > 0 {
		copy(new_slice[:db_size], db_bytes[:min(db_size, u64(len(db_bytes)))])
	}
	if db_memory != 0 {
		system.memory_unmap(raw_data(db_bytes))
		system.close(db_memory)
	}
	db_memory = new_mem
	db_bytes = new_slice
	db_capacity_pages = target_pages
	return true
}

// init_ipc_buffers allocates dedicated memory objects for cells and payload
// append tables so isolated calls never exceed the 64 KiB call region.
@(private = "file")
init_ipc_buffers :: proc "contextless" () -> bool {
	cells_bytes := u64(core.SNAPSHOT_MAX_CELLS * size_of(core.Cell_Row))
	cells_pages := (cells_bytes + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	cm, cs := system.memory_create(cells_pages)
	if cs != .Ok {
		return false
	}
	ca, c_map := system.memory_map(cm)
	if c_map != .Ok {
		system.close(cm)
		return false
	}
	cells_memory = cm
	cells_mapped = ([^]core.Cell_Row)(ca)[:core.SNAPSHOT_MAX_CELLS]

	pay_pages := (u64(core.SNAPSHOT_PAYLOAD_BYTES) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	pm, ps := system.memory_create(pay_pages)
	if ps != .Ok {
		return false
	}
	pa, p_map := system.memory_map(pm)
	if p_map != .Ok {
		system.close(pm)
		return false
	}
	payload_memory = pm
	payload_mapped = ([^]u8)(pa)[:core.SNAPSHOT_PAYLOAD_BYTES]
	return true
}

@(private = "file")
sqlite_host_stop :: proc "contextless" () {
	if sqlite_host.started {
		system.call_connection_end(&sqlite_host.conn)
	}
	if sqlite_host.sqlite_file_mem != 0 {
		system.memory_unmap(raw_data(sqlite_host.sqlite_file))
		system.close(sqlite_host.sqlite_file_mem)
	}
	sqlite_host = {}
}

// sqlite_host_start_from_memory launches the zero-grant child call host from
// a sqlite.module loaded into a private Memory_Object (e.g. from the store).
@(private = "file")
sqlite_host_start_from_memory :: proc "contextless" (host_module_bytes: []u8, sqlite_mem: system.Handle, sqlite_bytes: []u8) -> bool {
	files_mem, fm_status := system.memory_create(1)
	if fm_status != .Ok {
		return false
	}
	page_addr, map_status := system.memory_map(files_mem)
	if map_status != .Ok {
		system.close(files_mem)
		return false
	}
	page := ([^]u8)(page_addr)[:system.PAGE_SIZE]
	(^info.Image_Header)(page_addr)^ = {magic = info.IMAGE_MAGIC, count = 1}
	entry := (^info.Image_Entry)(raw_data(page[size_of(info.Image_Header):]))
	entry^ = {
		offset = system.PAGE_SIZE,
		size   = u64(len(sqlite_bytes)),
		hash   = blake3.hash(sqlite_bytes),
	}
	copy(entry.name[:], SQLITE_MODULE_NAME)
	system.memory_unmap(page_addr)

	ring_mem, calls, ring_status := system.ring_create()
	if ring_status != .Ok {
		system.close(files_mem)
		return false
	}
	region_mem, reg_status := system.memory_create(isolated.REGION_PAGES)
	if reg_status != .Ok {
		system.ring_close(&calls)
		system.close(ring_mem)
		system.close(files_mem)
		return false
	}
	reg_addr, reg_map := system.memory_map(region_mem)
	if reg_map != .Ok {
		system.close(region_mem)
		system.ring_close(&calls)
		system.close(ring_mem)
		system.close(files_mem)
		return false
	}
	region := ([^]u8)(reg_addr)[:isolated.REGION_PAGES * system.PAGE_SIZE]

	sqlite_pages := (u64(len(sqlite_bytes)) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	mappings := [2]system.Mapping{
		{memory = files_mem, address = isolated.FILE_ADDRESS},
		{memory = sqlite_mem, address = isolated.FILE_ADDRESS + system.PAGE_SIZE, first = 0, page_count = sqlite_pages},
	}
	// Zero grants except call ring and call region.
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[isolated.GRANT_RING] = {ring_mem, {.Read, .Write}}
	grants[isolated.GRANT_REGION] = {region_mem, {.Read, .Write}}

	values: [op.CONTEXT_VALUES]u64
	if worker_rng_ready {
		values = random.values_with_seed(&worker_rng, {})
	}
	values[isolated.VALUE_FILE_ADDRESS] = isolated.FILE_ADDRESS
	values[isolated.VALUE_FILE_SIZE] = system.PAGE_SIZE + sqlite_pages * system.PAGE_SIZE

	proc_handle, p_status := system.process_start(
		host_module_bytes,
		"sqlite_host",
		grants,
		values,
		{pages = SQLITE_HOST_PAGES, processes = 1, threads = 1, processor = 500_000, log_records = system.CALL_HOST_LOG_RECORDS},
		mappings[:],
	)
	if p_status != .Ok {
		system.memory_unmap(reg_addr)
		system.close(region_mem)
		system.ring_close(&calls)
		system.close(ring_mem)
		system.close(files_mem)
		return false
	}
	sqlite_host.conn = {
		process       = proc_handle,
		ring_memory   = ring_mem,
		region_memory = region_mem,
		files_memory  = files_mem,
		calls         = calls,
		region        = region,
	}
	if system.connection_ready_wait(&sqlite_host.conn.calls, sqlite_host.conn.process) != .Ready {
		system.call_connection_end(&sqlite_host.conn)
		return false
	}
	return true
}

// read_store_object_to_memory reads one named object from worker_store into a
// newly created and mapped memory object and validates it as a modus module.
@(private = "file")
read_store_object_to_memory :: proc "contextless" (name: string) -> (mem: system.Handle, addr: rawptr, buf: []u8, ok: bool) {
	sz, sz_status := storage.size(&worker_store, worker_store_place, name)
	if sz_status != .Ok || sz <= 0 {
		return 0, nil, nil, false
	}
	mod_pages := (u64(sz) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	mod_mem, m_st := system.memory_create(mod_pages)
	if m_st != .Ok {
		return 0, nil, nil, false
	}
	mod_addr, map_st := system.memory_map(mod_mem)
	if map_st != .Ok {
		system.close(mod_mem)
		return 0, nil, nil, false
	}
	mod_buf := ([^]u8)(mod_addr)[:u64(sz)]
	filled := u64(0)
	for filled < u64(sz) {
		part, r_st := storage.read_range(&worker_store, worker_store_place, name, filled, mod_buf[filled:])
		if r_st != .Ok || len(part) == 0 || u64(len(part)) > u64(sz) - filled {
			system.memory_unmap(mod_addr)
			system.close(mod_mem)
			return 0, nil, nil, false
		}
		filled += u64(len(part))
	}
	if module.validate(mod_buf) != .None {
		system.memory_unmap(mod_addr)
		system.close(mod_mem)
		return 0, nil, nil, false
	}
	return mod_mem, mod_addr, mod_buf, true
}

// sqlite_host_start starts a zero-grant child call host for sqlite.module,
// loading sqlite and host from the boot image if GRANT_IMAGE is present or
// from "sqlite.module" and "host.module" in the private store otherwise.
@(private = "file")
sqlite_host_start :: proc "contextless" (ctx: ^system.Context) -> bool {
	sqlite_host_stop()

	if boot_image_handle == 0 {
		img_h := ctx.handles[system.GRANT_IMAGE]
		img_sz := ctx.values[system.GRANT_VALUE_IMAGE_SIZE]
		if img_h != 0 && img_sz > 0 {
			if addr, st := system.memory_map(img_h, {}); st == .Ok {
				boot_image_handle = img_h
				boot_image_bytes = ([^]u8)(addr)[:img_sz]
			}
		}
	}

	// Path 1: sqlite is present in the boot image.
	img_sqlite := len(boot_image_bytes) > 0 ? system.image_find(boot_image_bytes, SQLITE_MODULE_NAME) : nil
	if len(img_sqlite) > 0 {
		values: [op.CONTEXT_VALUES]u64
		if worker_rng_ready {
			values = random.values_with_seed(&worker_rng, {})
		}
		load_err: module.Load_Error
		added := system.Call_Host_Context{pages = SQLITE_HOST_PAGES}
		conn, st := system.call_host_start(
			boot_image_bytes,
			boot_image_handle,
			img_sqlite,
			"sqlite_host",
			values,
			&load_err,
			added = &added,
		)
		if st != .Ok {
			return false
		}
		sqlite_host.conn = conn
		sqlite_host.sqlite_file = img_sqlite
	} else if worker_store_opened {
		// Path 2: sqlite.module resides in the store; load host from the boot
		// image when granted or from "host.module" in the store for disk processes.
		host_bytes := len(boot_image_bytes) > 0 ? system.image_find(boot_image_bytes, "host") : nil
		host_mem: system.Handle
		host_addr: rawptr
		defer if host_mem != 0 {
			system.memory_unmap(host_addr)
			system.close(host_mem)
		}
		if len(host_bytes) == 0 {
			host_ok: bool
			host_mem, host_addr, host_bytes, host_ok = read_store_object_to_memory(HOST_STORE_OBJECT_NAME)
			if !host_ok {
				return false
			}
		}
		mod_mem, mod_addr, mod_buf, mod_ok := read_store_object_to_memory(SQLITE_STORE_OBJECT_NAME)
		if !mod_ok {
			return false
		}
		if !sqlite_host_start_from_memory(host_bytes, mod_mem, mod_buf) {
			system.memory_unmap(mod_addr)
			system.close(mod_mem)
			return false
		}
		sqlite_host.sqlite_file_mem = mod_mem
		sqlite_host.sqlite_file = mod_buf
	} else {
		return false
	}

	f := sqlite_host.sqlite_file
	sqlite_host.exp_open = module.export_find(f, "session_open")
	sqlite_host.exp_execute = module.export_find(f, "session_execute")
	sqlite_host.exp_dirty_ranges = module.export_find(f, "session_dirty_ranges")
	sqlite_host.exp_mark_synced = module.export_find(f, "session_mark_synced")
	sqlite_host.exp_info = module.export_find(f, "session_info")
	sqlite_host.exp_last_diag = module.export_find(f, "session_last_diagnostic")
	sqlite_host.exp_close = module.export_find(f, "session_close")
	if sqlite_host.exp_open == 0 || sqlite_host.exp_execute == 0 || sqlite_host.exp_dirty_ranges == 0 || sqlite_host.exp_mark_synced == 0 || sqlite_host.exp_info == 0 || sqlite_host.exp_last_diag == 0 || sqlite_host.exp_close == 0 {
		sqlite_host_stop()
		return false
	}
	sqlite_host.started = true
	return true
}

// Isolated-call implementation of core.Sqlite_Bridge.
@(private = "file")
isolated_bridge :: proc "contextless" () -> core.Sqlite_Bridge {
	return {
		user_data = nil,
		open = proc "contextless" (_: rawptr, options: ^core.Open_Options, database: []u8, info_out: ^core.Session_Info, err: ^errors.Error_Record) -> call_outcome.Call_Outcome {
			if !sqlite_host.started {
				return .Callee_Unavailable
			}
			info_rows: [1]core.Session_Info
			args := [3]isolated.Argument{
				{record = ([^]u8)(options)[:size_of(core.Open_Options)]},
				{table = {records = database, count = u64(len(database)), memory_handle = u64(db_memory)}},
				{table = {records = ([^]u8)(&info_rows)[:size_of(core.Session_Info)], count = 0}},
			}
			_, outcome := system.call_isolated(&sqlite_host.conn, sqlite_host.sqlite_file, sqlite_host.exp_open, args[:], err, keep_memory_objects = true, deadline = system.time() + SQLITE_CALL_TIMEOUT_MS)
			if outcome == .Succeeded && args[2].table.count >= 1 {
				info_out^ = info_rows[0]
				sqlite_host.session_open = true
			}
			return outcome
		},
		execute = proc "contextless" (
			_: rawptr,
			sql: string,
			database: []u8,
			columns: []core.Column_Row,
			cells: []core.Cell_Row,
			payload: []u8,
			diagnostic: []u8,
			summary_out: ^core.Query_Summary,
			col_count: ^int,
			cell_count: ^int,
			pay_count: ^int,
			diag_count: ^int,
			err: ^errors.Error_Record,
		) -> call_outcome.Call_Outcome {
			if !sqlite_host.started {
				return .Callee_Unavailable
			}
			summary_rows: [1]core.Query_Summary
			args := [7]isolated.Argument{
				{text = transmute([]u8)sql},
				{table = {records = database, count = u64(len(database)), memory_handle = u64(db_memory)}},
				{table = {records = ([^]u8)(raw_data(columns))[:len(columns) * size_of(core.Column_Row)], count = 0}},
				{table = {records = ([^]u8)(raw_data(cells_mapped))[:len(cells_mapped) * size_of(core.Cell_Row)], count = 0, memory_handle = u64(cells_memory)}},
				{table = {records = payload_mapped, count = 0, memory_handle = u64(payload_memory)}},
				{table = {records = diagnostic, count = 0}},
				{table = {records = ([^]u8)(&summary_rows)[:size_of(core.Query_Summary)], count = 0}},
			}
			_, outcome := system.call_isolated(&sqlite_host.conn, sqlite_host.sqlite_file, sqlite_host.exp_execute, args[:], err, keep_memory_objects = true, deadline = system.time() + SQLITE_CALL_TIMEOUT_MS)
			col_count^ = int(min(args[2].table.count, u64(len(columns))))
			cc := int(min(args[3].table.count, u64(min(len(cells), len(cells_mapped)))))
			if cc > 0 {
				copy(cells[:cc], cells_mapped[:cc])
			}
			cell_count^ = cc
			pc := int(min(args[4].table.count, u64(min(len(payload), len(payload_mapped)))))
			if pc > 0 {
				copy(payload[:pc], payload_mapped[:pc])
			}
			pay_count^ = pc
			diag_count^ = int(min(args[5].table.count, u64(len(diagnostic))))
			if args[6].table.count >= 1 {
				summary_out^ = summary_rows[0]
			}
			return outcome
		},
		dirty_ranges = proc "contextless" (_: rawptr, ranges: []core.Dirty_Range_Row, total_count: ^int, err: ^errors.Error_Record) -> call_outcome.Call_Outcome {
			if !sqlite_host.started {
				return .Callee_Unavailable
			}
			args := [1]isolated.Argument{
				{table = {records = ([^]u8)(raw_data(ranges))[:len(ranges) * size_of(core.Dirty_Range_Row)], count = 0}},
			}
			res, outcome := system.call_isolated(&sqlite_host.conn, sqlite_host.sqlite_file, sqlite_host.exp_dirty_ranges, args[:], err, deadline = system.time() + SQLITE_CALL_TIMEOUT_MS)
			if outcome == .Succeeded {
				total_count^ = int(max(res, 0))
			}
			return outcome
		},
		mark_synced = proc "contextless" (_: rawptr, err: ^errors.Error_Record) -> call_outcome.Call_Outcome {
			if !sqlite_host.started {
				return .Callee_Unavailable
			}
			_, outcome := system.call_isolated(&sqlite_host.conn, sqlite_host.sqlite_file, sqlite_host.exp_mark_synced, nil, err, deadline = system.time() + SQLITE_CALL_TIMEOUT_MS)
			return outcome
		},
		info = proc "contextless" (_: rawptr, out_info: ^core.Session_Info, err: ^errors.Error_Record) -> call_outcome.Call_Outcome {
			if !sqlite_host.started {
				return .Callee_Unavailable
			}
			rows: [1]core.Session_Info
			args := [1]isolated.Argument{
				{table = {records = ([^]u8)(&rows)[:size_of(core.Session_Info)], count = 0}},
			}
			_, outcome := system.call_isolated(&sqlite_host.conn, sqlite_host.sqlite_file, sqlite_host.exp_info, args[:], err, deadline = system.time() + SQLITE_CALL_TIMEOUT_MS)
			if outcome == .Succeeded && args[0].table.count >= 1 {
				out_info^ = rows[0]
			}
			return outcome
		},
		last_diagnostic = proc "contextless" (_: rawptr, out_diag: []u8, out_count: ^int, err: ^errors.Error_Record) -> call_outcome.Call_Outcome {
			if !sqlite_host.started {
				return .Callee_Unavailable
			}
			args := [1]isolated.Argument{
				{table = {records = out_diag, count = 0}},
			}
			_, outcome := system.call_isolated(&sqlite_host.conn, sqlite_host.sqlite_file, sqlite_host.exp_last_diag, args[:], err, deadline = system.time() + SQLITE_CALL_TIMEOUT_MS)
			out_count^ = int(min(args[0].table.count, u64(len(out_diag))))
			return outcome
		},
		close = proc "contextless" (_: rawptr, database: []u8, err: ^errors.Error_Record) -> call_outcome.Call_Outcome {
			if !sqlite_host.started || !sqlite_host.session_open {
				return .Succeeded
			}
			args := [1]isolated.Argument{
				{table = {records = database, count = u64(len(database)), memory_handle = u64(db_memory)}},
			}
			_, outcome := system.call_isolated(&sqlite_host.conn, sqlite_host.sqlite_file, sqlite_host.exp_close, args[:], err, keep_memory_objects = true, deadline = system.time() + SQLITE_CALL_TIMEOUT_MS)
			sqlite_host.session_open = false
			return outcome
		},
	}
}

// Storage_Sync_Port implementation backed by worker_store.
@(private = "file")
storage_sync_port :: proc "contextless" () -> core.Storage_Sync_Port {
	return {
		user_data = nil,
		write_range = proc "contextless" (_: rawptr, offset: u64, data: []u8) -> bool {
			if !worker_store_opened || !storage.connected(&worker_store) {
				return false
			}
			// Chunk writes to fit the 64 KiB storage call region safely.
			CHUNK :: u64(48 * 1024)
			pos := u64(0)
			for pos < u64(len(data)) {
				end := min(pos + CHUNK, u64(len(data)))
				err: errors.Error_Record
				_, st := storage.write_range(&worker_store, worker_store_place, DATABASE_OBJECT_NAME, offset + pos, data[pos:end], &err)
				if st != .Ok {
					if st == .Gone {
						worker_store_opened = false
						worker_store_read_only = true
						system.log_fact(.Info, Store_Revoked{})
					} else {
						system.log_fact(.Info, Store_Call_Refused(errors.error_record_fact_fields(err)))
					}
					return false
				}
				pos = end
			}
			return true
		},
		set_size = proc "contextless" (_: rawptr, size: u64) -> bool {
			if !worker_store_opened || !storage.connected(&worker_store) {
				return false
			}
			err: errors.Error_Record
			st := storage.set_size(&worker_store, worker_store_place, DATABASE_OBJECT_NAME, size, &err)
			if st != .Ok {
				if st == .Gone {
					worker_store_opened = false
					worker_store_read_only = true
					system.log_fact(.Info, Store_Revoked{})
				} else {
					system.log_fact(.Info, Store_Call_Refused(errors.error_record_fact_fields(err)))
				}
				return false
			}
			return true
		},
		commit = proc "contextless" (_: rawptr, committed_bytes: u64) -> (i64, bool) {
			if !worker_store_opened || !storage.connected(&worker_store) {
				return 0, false
			}
			err: errors.Error_Record
			measure, st := storage.commit(&worker_store, worker_store_place, DATABASE_OBJECT_NAME, &err)
			if st != .Ok {
				if st == .Gone {
					worker_store_opened = false
					worker_store_read_only = true
					system.log_fact(.Info, Store_Revoked{})
				} else {
					system.log_fact(.Info, Store_Call_Refused(errors.error_record_fact_fields(err)))
				}
				return 0, false
			}
			worker_current_generation = measure.generation
			system.log_fact(.Info, Database_Committed{bytes = committed_bytes, generation = measure.generation})
			return measure.generation, true
		},
	}
}

@(private = "file")
open_sqlite_over_buffer :: proc "contextless" (fresh: bool, read_only: bool) -> (prob: core.Problem_Kind, diag_len: int) {
	bridge := isolated_bridge()
	if sqlite_host.session_open {
		close_err: errors.Error_Record
		_ = bridge.close(nil, db_bytes, &close_err)
	}
	seed := worker_rng_ready ? random.next_u64(&worker_rng) : u64(0x9E37_79B9_7F4A_7C15)
	if seed == 0 {
		seed = 1
	}
	opts := core.Open_Options{
		fresh          = fresh ? 1 : 0,
		read_only      = read_only ? 1 : 0,
		page_size      = core.SQLITE_PAGE_SIZE,
		random_seed    = seed,
		database_bytes = fresh ? 0 : db_size,
		heap_bytes     = SQLITE_DEFAULT_HEAP_BYTES,
	}
	info_out: core.Session_Info
	err: errors.Error_Record
	outcome := bridge.open(nil, &opts, db_bytes, &info_out, &err)
	if outcome != .Succeeded {
		diag_err: errors.Error_Record
		_ = bridge.last_diagnostic(nil, worker_scratch.diagnostic[:], &diag_len, &diag_err)
		return core.problem_of_sqlite_outcome(outcome), diag_len
	}
	db_size = info_out.database_bytes
	return .None, 0
}

// load_database_from_store reads main.db (or a specific CoW generation) into db_memory.
@(private = "file")
load_database_from_store :: proc "contextless" (generation: i64) -> (fresh: bool, prob: core.Problem_Kind) {
	if !worker_store_opened {
		db_size = 0
		return true, .None
	}
	if !storage.connected(&worker_store) {
		worker_store_opened = false
		worker_store_read_only = true
		system.log_fact(.Info, Store_Revoked{})
		return false, .Store_Revoked
	}
	if generation > 0 {
		// Find exact size from versions list or read incrementally up to capacity.
		vers: [core.VERSION_LIST_CAPACITY]storage.Version
		rows, _, v_st := storage.versions(&worker_store, worker_store_place, DATABASE_OBJECT_NAME, vers[:])
		if v_st != .Ok {
			return false, .Version_Unreadable
		}
		target_bytes := i64(0)
		found := false
		for row in rows {
			if row.generation == generation {
				target_bytes = row.bytes
				found = true
				break
			}
		}
		if !found || target_bytes < 0 {
			return false, .Version_Unreadable
		}
		if !db_ensure_capacity(max(u64(target_bytes) + 65536, DB_MEMORY_INITIAL_PAGES * system.PAGE_SIZE)) {
			return false, .Database_Too_Large
		}
		if target_bytes == 0 {
			db_size = 0
			return true, .None
		}
		read_bytes, st := storage.version(&worker_store, worker_store_place, DATABASE_OBJECT_NAME, generation, db_bytes[:u64(target_bytes)])
		if st != .Ok {
			return false, .Version_Unreadable
		}
		db_size = u64(len(read_bytes))
		return db_size == 0, .None
	}

	err: errors.Error_Record
	sz, st := storage.size(&worker_store, worker_store_place, DATABASE_OBJECT_NAME, &err)
	if st == .Absent {
		db_size = 0
		return true, .None
	}
	if st == .Damaged {
		return false, .Database_Damaged
	}
	if st == .Gone {
		worker_store_opened = false
		worker_store_read_only = true
		system.log_fact(.Info, Store_Revoked{})
		return false, .Store_Revoked
	}
	if st != .Ok || sz < 0 {
		return false, .Database_Damaged
	}
	// Reserve extra headroom for growth on writes.
	if !db_ensure_capacity(max(u64(sz) + 256 * 1024, DB_MEMORY_INITIAL_PAGES * system.PAGE_SIZE)) {
		return false, .Database_Too_Large
	}
	if sz == 0 {
		db_size = 0
		return true, .None
	}
	filled := u64(0)
	for filled < u64(sz) {
		part, r_st := storage.read_range(&worker_store, worker_store_place, DATABASE_OBJECT_NAME, filled, db_bytes[filled:u64(sz)], &err)
		if r_st == .Gone {
			worker_store_opened = false
			worker_store_read_only = true
			system.log_fact(.Info, Store_Revoked{})
			return false, .Store_Revoked
		}
		if r_st != .Ok || len(part) == 0 || u64(len(part)) > u64(sz) - filled {
			return false, .Database_Damaged
		}
		filled += u64(len(part))
	}
	db_size = filled
	return false, .None
}

// request_powerbox_store_pick asks the trusted display (powerbox_pick_store)
// to open a store picker when a root-ring display connection is granted.
// Receiving and switching to the newly granted store handle awaits root-service
// grant-request-ring wiring (src/md/features/db_browser.md, "State").
@(private = "file")
request_powerbox_store_pick :: proc "contextless" (ctx: ^system.Context) -> bool {
	root_mem := ctx.handles[system.GRANT_ROOT]
	if root_mem == 0 || len(boot_image_bytes) == 0 {
		return false
	}
	root_ring, r_st := system.ring_open(root_mem, receive_handles = true)
	if r_st != .Ok {
		return false
	}
	defer system.ring_close(&root_ring)

	disp_conn, conn_outcome := system.service_connection(&root_ring, 1, "display")
	if conn_outcome != .Succeeded {
		return false
	}
	defer system.call_connection_end(&disp_conn)

	entry := system.image_entry_of(boot_image_bytes, disp_conn.module_hash)
	if entry == nil {
		return false
	}
	disp_file := boot_image_bytes[entry.offset:][:entry.size]
	pick := module.export_find(disp_file, "powerbox_pick_store")
	if pick == 0 {
		return false
	}
	asker := "db_browser"
	mode := "read_write"
	args := [2]isolated.Argument{{text = transmute([]u8)asker}, {text = transmute([]u8)mode}}
	err: errors.Error_Record
	res, outcome := system.call_isolated(&disp_conn, disp_file, pick, args[:], &err)
	return outcome == .Succeeded && res > 0
}

@(private = "file")
worker_handle_request :: proc "contextless" (ctx: ^system.Context, req: ^core.Worker_Request) {
	res: core.Worker_Result
	res.serial = req.serial
	res.error_offset = -1
	res.store_connected = worker_store_opened && storage.connected(&worker_store)
	if worker_store_opened && !res.store_connected {
		worker_store_opened = false
		worker_store_read_only = true
		system.log_fact(.Info, Store_Revoked{})
	}
	res.read_only = worker_store_read_only
	res.engine_ready = sqlite_host.started

	switch req.kind {
	case .None:
		return

	case .Open_Initial:
		res.kind = .Opened
		if !init_ipc_buffers() || !db_ensure_capacity(DB_MEMORY_INITIAL_PAGES * system.PAGE_SIZE) {
			res.problem = .Database_Too_Large
			worker_publish_result(&res, false)
			return
		}
		worker_store, worker_store_opened = storage.open(ctx)
		if !worker_store_opened {
			system.log_fact(.Info, No_Store{})
			res.problem = .No_Store
		}
		res.store_connected = worker_store_opened
		if !sqlite_host_start(ctx) {
			system.log_fact(.Info, Engine_Unavailable{})
			res.problem = .Engine_Unavailable
			res.engine_ready = false
			worker_publish_result(&res, false)
			return
		}
		res.engine_ready = true

		fresh, load_prob := load_database_from_store(0)
		if load_prob != .None {
			res.problem = load_prob
			worker_publish_result(&res, false)
			return
		}
		open_prob, diag_len := open_sqlite_over_buffer(fresh, worker_store_read_only)
		if open_prob != .None {
			res.problem = open_prob
			res.detail_len = copy(res.detail[:], worker_scratch.diagnostic[:diag_len])
			worker_publish_result(&res, false)
			return
		}

		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		snap.database_bytes = db_size
		snap.generation = worker_current_generation
		bridge := isolated_bridge()
		_ = core.worker_refresh_schema(&bridge, db_bytes, snap, &worker_scratch)
		system.log_fact(.Info, Database_Opened{bytes = db_size, tables = u64(snap.table_count), generation = worker_current_generation})
		res.snapshot_index = back_idx
		res.generation = worker_current_generation
		worker_publish_result(&res, true)

	case .Execute_Sql, .Browse_Table:
		res.kind = .Query_Done
		if !sqlite_host.started {
			if !sqlite_host_start(ctx) {
				res.problem = .Engine_Unavailable
				worker_publish_result(&res, false)
				return
			}
			open_prob, _ := open_sqlite_over_buffer(db_size == 0, worker_store_read_only)
			if open_prob != .None {
				res.problem = open_prob
				worker_publish_result(&res, false)
				return
			}
		}
		res.engine_ready = true

		// Ensure headroom before executing statements that can grow the database.
		if !worker_store_read_only {
			_ = db_ensure_capacity(db_size + 256 * 1024)
		}

		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		if req.kind == .Browse_Table && req.table_index >= 0 && req.table_index < snap.table_count {
			snap.selected_table = req.table_index
		}

		sql := string(req.sql[:min(req.sql_len, len(req.sql))])
		bridge := isolated_bridge()
		sync := storage_sync_port()
		sync_ptr := worker_store_opened ? &sync : nil

		outcome, prob, err_off, diag_len, committed_gen := core.worker_execute_and_sync(
			&bridge,
			sync_ptr,
			sql,
			db_bytes,
			&db_size,
			worker_store_read_only,
			snap,
			&worker_scratch,
		)

		// If the child call host crashed or timed out, recycle it cleanly.
		if system.connection_to_renew(outcome) {
			sqlite_host_stop()
			res.engine_ready = false
		} else {
			// Refresh table/column sidebar after every successful or schema-changing statement.
			if outcome == .Succeeded {
				_ = core.worker_refresh_schema(&bridge, db_bytes, snap, &worker_scratch)
				system.log_fact(.Info, Query_Executed{rows = u64(snap.row_count), columns = u64(snap.column_count), changes = snap.changes})
			}
		}
		if committed_gen > 0 {
			worker_current_generation = committed_gen
			snap.generation = committed_gen
		}
		snap.database_bytes = db_size
		res.snapshot_index = back_idx
		res.problem = prob
		res.error_offset = err_off
		res.detail_len = copy(res.detail[:], worker_scratch.diagnostic[:diag_len])
		res.store_connected = worker_store_opened
		res.read_only = worker_store_read_only
		res.generation = worker_current_generation
		worker_publish_result(&res, true)

	case .Refresh_Schema:
		res.kind = .Schema_Updated
		if !sqlite_host.started {
			res.problem = .Engine_Unavailable
			worker_publish_result(&res, false)
			return
		}
		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		if req.table_index >= 0 && req.table_index < snap.table_count {
			snap.selected_table = req.table_index
		}
		bridge := isolated_bridge()
		_ = core.worker_refresh_schema(&bridge, db_bytes, snap, &worker_scratch)
		res.snapshot_index = back_idx
		worker_publish_result(&res, true)

	case .Sort_Results:
		res.kind = .Sorted
		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		_ = core.snapshot_sort_by_column(snap, req.sort_column, req.sort_direction)
		system.log_fact(.Info, Query_Sorted{column = u64(req.sort_column), direction = u64(req.sort_direction)})
		res.snapshot_index = back_idx
		worker_publish_result(&res, true)

	case .List_Versions:
		res.kind = .Versions_Listed
		if !worker_store_opened {
			res.problem = .No_Store
			worker_publish_result(&res, false)
			return
		}
		if !storage.connected(&worker_store) {
			worker_store_opened = false
			worker_store_read_only = true
			res.store_connected = false
			res.read_only = true
			res.problem = .Store_Revoked
			system.log_fact(.Info, Store_Revoked{})
			worker_publish_result(&res, false)
			return
		}
		raw_vers: [core.VERSION_LIST_CAPACITY]storage.Version
		rows, _, st := storage.versions(&worker_store, worker_store_place, DATABASE_OBJECT_NAME, raw_vers[:])
		if st != .Ok {
			res.problem = .Version_Unreadable
			worker_publish_result(&res, false)
			return
		}
		res.version_count = len(rows)
		for row, i in rows {
			res.versions[i] = {
				generation = row.generation,
				date       = row.date,
				bytes      = row.bytes,
				current    = row.current != 0,
			}
		}
		worker_publish_result(&res, false)

	case .Preview_Version:
		res.kind = .Version_Previewed
		if !sqlite_host.started {
			res.problem = .Engine_Unavailable
			worker_publish_result(&res, false)
			return
		}
		fresh, load_prob := load_database_from_store(req.generation)
		if load_prob != .None {
			res.problem = load_prob
			worker_publish_result(&res, false)
			return
		}
		// Previewing a historical generation opens strictly read-only.
		preview_ro := req.generation > 0 || worker_store_read_only
		open_prob, diag_len := open_sqlite_over_buffer(fresh, preview_ro)
		if open_prob != .None {
			res.problem = open_prob
			res.detail_len = copy(res.detail[:], worker_scratch.diagnostic[:diag_len])
			worker_publish_result(&res, false)
			return
		}
		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		snap.database_bytes = db_size
		snap.generation = req.generation > 0 ? req.generation : worker_current_generation
		bridge := isolated_bridge()
		_ = core.worker_refresh_schema(&bridge, db_bytes, snap, &worker_scratch)
		if req.generation > 0 {
			system.log_fact(.Info, Version_Previewed{generation = req.generation})
		}
		res.snapshot_index = back_idx
		res.generation = snap.generation
		worker_publish_result(&res, true)

	case .Restore_Version:
		res.kind = .Version_Restored
		if !worker_store_opened || worker_store_read_only {
			res.problem = .Read_Only
			worker_publish_result(&res, false)
			return
		}
		err: errors.Error_Record
		new_gen, st := storage.restore(&worker_store, worker_store_place, DATABASE_OBJECT_NAME, req.generation, &err)
		if st != .Ok || new_gen < 0 {
			res.problem = st == .Gone ? .Store_Revoked : .Version_Unreadable
			if st == .Gone {
				worker_store_opened = false
				worker_store_read_only = true
				system.log_fact(.Info, Store_Revoked{})
			}
			worker_publish_result(&res, false)
			return
		}
		worker_current_generation = new_gen
		system.log_fact(.Info, Version_Restored{from_generation = req.generation, to_generation = new_gen})

		fresh, load_prob := load_database_from_store(0)
		if load_prob != .None {
			res.problem = load_prob
			worker_publish_result(&res, false)
			return
		}
		open_prob, _ := open_sqlite_over_buffer(fresh, worker_store_read_only)
		if open_prob != .None {
			res.problem = open_prob
			worker_publish_result(&res, false)
			return
		}
		back_idx, snap := worker_acquire_back_snapshot()
		snap.serial = req.serial
		snap.database_bytes = db_size
		snap.generation = new_gen
		bridge := isolated_bridge()
		_ = core.worker_refresh_schema(&bridge, db_bytes, snap, &worker_scratch)
		res.snapshot_index = back_idx
		res.generation = new_gen
		worker_publish_result(&res, true)

	case .Pick_Store:
		res.kind = .Store_Picked
		if !request_powerbox_store_pick(ctx) {
			res.problem = .Store_Pick_Unavailable
		}
		worker_publish_result(&res, false)
	}
}

worker_thread_entry :: proc "c" (parameter: rawptr) -> ! {
	ctx := (^system.Context)(parameter)
	worker_ctx = ctx
	worker_rng_ready = random.generator_from_context(&worker_rng, ctx)

	req: core.Worker_Request
	for {
		seen := system.event_count(&req_event)
		system.lock(&worker_lock)
		taken := core.queue_pop(&req_queue, &req)
		system.unlock(&worker_lock)
		if !taken {
			system.event_wait(&req_event, seen)
			continue
		}
		worker_handle_request(ctx, &req)
	}
}
