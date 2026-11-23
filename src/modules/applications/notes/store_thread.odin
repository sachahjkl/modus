package notes

import "modus:contract/errors"
import "modus:contract/storage_status"
import "internal:notes/note_list"
import "internal:notes/store_work"
import "modus:storage"
import "modus:system"
import "modus:text_model"

// The store thread: the one thread of notes that calls the storage
// service. The window thread never waits for the store: it puts a request
// in the queue of the requests and goes on drawing; the store thread does
// the calls, puts the result in the queue of the results and wakes the
// window thread (src/md/features/notes.md, "The store thread").

// The two queues and their lock. The lock is held only for a copy of one
// record, never during a call of the storage service.
store_lock: system.Lock
requests: store_work.Queue(store_work.Request)
results: store_work.Queue(store_work.Result)
requests_event: system.Event // A request was put.
results_event: system.Event // A result was put.
results_taken_event: system.Event // The window thread took results: a full queue of results has room.

// The memory of the store thread alone.
store_client: storage.Client
store_opened: bool
store_request: store_work.Request
store_result: store_work.Result
// The list that the request List makes. The store thread writes it before
// the result of that request, and only for that request, which the window
// thread asks once; the window thread copies it after the result.
store_listed: note_list.Note_List
// The entries that one call of list gives, and the bytes of their names.
LIST_PAGE_ROWS :: 64
list_rows: [LIST_PAGE_ROWS]storage.Listed
list_names: [LIST_PAGE_ROWS * note_list.NAME_BYTES]u8
version_rows_read: [VERSION_ROWS_CAPACITY]storage.Version
#assert(size_of(version_rows_read) <= store_work.RESULT_BYTES)

// store_thread_entry runs the requests one after the other, in the order
// in which the window thread put them.
store_thread_entry :: proc "c" (parameter: rawptr) -> ! {
	ctx := (^system.Context)(parameter)
	for {
		seen := system.event_count(&requests_event)
		system.lock(&store_lock)
		taken := store_work.queue_pop(&requests, &store_request)
		system.unlock(&store_lock)
		if !taken {
			system.event_wait(&requests_event, seen)
			continue
		}
		store_request_run(ctx)
		for {
			room_seen := system.event_count(&results_taken_event)
			system.lock(&store_lock)
			put := store_work.queue_push(&results, &store_result)
			system.unlock(&store_lock)
			if put {
				break
			}
			system.event_wait(&results_taken_event, room_seen)
		}
		system.event_wake(&results_event)
	}
}

// store_failed writes the fact of a call of the storage service that
// failed, and gives the status of the result. Only a connection that ended
// is no answer, which ends the keeping, and so is a service that gave no
// answer in its bound. A refusal, a damaged object or a buffer that is too
// small is the answer of one call.
store_failed :: proc "contextless" (kind: store_work.Request_Kind, status: storage_status.Status, error: ^errors.Error_Record) -> store_work.Result_Status {
	switch status {
	case .Gone, .No_Answer:
		system.log_fact(.Info, Storage_Unanswered{})
		return .Unanswered
	case .Damaged:
		return .Damaged
	case .Too_Small:
		return .Too_Long
	case .Refused:
		system.log_fact(.Info, Call_Refused{})
		return .Refused
	case .Ok:
		// No failed call gives Ok: the window takes it as a refusal.
		system.log_fact(.Info, Call_Refused{})
		return .Refused
	case .Failed, .Absent:
		// A name that names nothing is the answer of one call, with its
		// record, as each other failure of the export.
	}
	fields := errors.error_record_fact_fields(error^)
	switch kind {
	case .Write:
		system.log_fact(.Info, Note_Write_Refused(fields))
	case .Load, .Version:
		system.log_fact(.Info, Note_Read_Refused(fields))
	case .List, .Versions:
		system.log_fact(.Info, List_Refused(fields))
	case .Remove:
		system.log_fact(.Info, Note_Remove_Refused(fields))
	case .Restore:
		system.log_fact(.Info, Version_Restore_Refused(fields))
	}
	return .Refused
}

// store_request_run does one request and writes its result.
store_request_run :: proc "contextless" (ctx: ^system.Context) {
	request := &store_request
	result := &store_result
	result.kind, result.serial, result.status = request.kind, request.serial, .Done
	result.name, result.name_count = request.name, request.name_count
	result.generation, result.byte_count = 0, 0
	name := string(request.name[:request.name_count])
	if request.kind != .List && !store_opened {
		result.status = .No_Store
		return
	}
	error: errors.Error_Record
	switch request.kind {
	case .List:
		store_list(ctx)
	case .Load:
		bytes, found, status := storage.read(&store_client, storage.ROOT, name, result.bytes[:], &error)
		switch {
		case status == .Damaged:
			result.status = .Damaged
		case status != .Ok:
			result.status = store_failed(.Load, status, &error)
		case !found:
			result.status = .Absent
		case len(bytes) > text_model.TEXT_CAPACITY:
			result.status = .Too_Long
			result.byte_count = len(bytes)
		case:
			result.byte_count = len(bytes)
		}
	case .Write:
		generation, status := storage.write(&store_client, storage.ROOT, name, request.bytes[:request.byte_count], &error)
		if status != .Ok || generation < 0 {
			result.status = store_failed(.Write, status, &error)
			return
		}
		result.generation = generation
		// The fact of the commit, with the title of the text that it holds.
		title, title_count := note_list.title_of(request.bytes[:min(request.byte_count, note_list.TITLE_BYTES + 4)])
		system.log_fact(.Info, Note_Kept{generation = generation, bytes = u64(request.byte_count), title = title_field(string(title[:title_count]))})
	case .Versions:
		rows, total, status := storage.versions(&store_client, storage.ROOT, name, version_rows_read[:], &error)
		if status != .Ok {
			result.status = store_failed(.Versions, status, &error)
			return
		}
		if total > i64(len(rows)) {
			system.log_fact(.Info, Versions_Cut{versions = total, listed = VERSION_ROWS_CAPACITY})
		}
		result.byte_count = copy(result.bytes[:], ([^]u8)(raw_data(rows))[:len(rows) * size_of(storage.Version)])
	case .Version:
		result.generation = request.generation
		bytes, status := storage.version(&store_client, storage.ROOT, name, request.generation, result.bytes[:], &error)
		switch {
		case status != .Ok:
			result.status = store_failed(.Version, status, &error)
		case len(bytes) > text_model.TEXT_CAPACITY:
			result.status = .Too_Long
		case:
			result.byte_count = len(bytes)
		}
	case .Restore:
		commit, status := storage.restore(&store_client, storage.ROOT, name, request.generation, &error)
		if status != .Ok || commit < 0 {
			result.status = store_failed(.Restore, status, &error)
			return
		}
		result.generation = commit
	case .Remove:
		generation, status := storage.remove(&store_client, storage.ROOT, name, &error)
		if status != .Ok {
			result.status = store_failed(.Remove, status, &error)
			return
		}
		result.generation = generation
	}
}

// store_list opens the store, lists its objects page by page, and reads
// the first bytes of each for its title, into store_listed.
store_list :: proc "contextless" (ctx: ^system.Context) {
	result := &store_result
	note_list.list_reset(&store_listed)
	if store_client, store_opened = storage.open(ctx); !store_opened {
		result.status = .No_Store
		return
	}
	after_buffer: [note_list.NAME_BYTES]u8
	after := ""
	for {
		error: errors.Error_Record
		page, status := storage.list(&store_client, storage.ROOT, after, list_rows[:], list_names[:], &error)
		if status != .Ok {
			result.status = store_failed(.List, status, &error)
			return
		}
		if len(page) == 0 {
			return
		}
		// A page whose names are all out of the bytes of the names gives
		// no name to go on from: the list ends there, and never asks for
		// the same page again.
		advanced := false
		for row in page {
			kind, known := storage.entry_kind_of_word(row.kind)
			start, count := int(row.name_offset), int(row.name_count)
			if start < 0 || count <= 0 || count > note_list.NAME_BYTES || start > len(list_names) || count > len(list_names) - start {
				continue
			}
			name := string(list_names[start:][:count])
			after = string(after_buffer[:copy(after_buffer[:], name)])
			advanced = true
			if !known || kind != .Object {
				continue
			}
			first_error: errors.Error_Record
			first: [note_list.TITLE_BYTES + 4]u8
			bytes, read_status := storage.read_range(&store_client, storage.ROOT, name, 0, first[:], &first_error)
			if read_status != .Ok && read_status != .Damaged {
				store_failed(.Load, read_status, &first_error)
				bytes = nil
			}
			if _, problem := note_list.list_add_stored(&store_listed, name, bytes, row.generation); problem == .Full {
				system.log_fact(.Info, Notes_Cut{listed = note_list.NOTE_CAPACITY})
				return
			}
		}
		if !advanced {
			system.log_fact(.Info, Notes_Cut{listed = u64(store_listed.count)})
			return
		}
	}
}

// request_put puts a request of the window thread in the queue, and wakes
// the store thread. false: the queue is full, and nothing was put.
request_put :: proc "contextless" (request: ^store_work.Request) -> bool {
	system.lock(&store_lock)
	put := store_work.queue_push(&requests, request)
	system.unlock(&store_lock)
	if put {
		system.event_wake(&requests_event)
	}
	return put
}

// requests_room gives the requests that the queue takes now.
requests_room :: proc "contextless" () -> int {
	system.lock(&store_lock)
	defer system.unlock(&store_lock)
	return store_work.QUEUE_CAPACITY - requests.count
}

// result_take takes the oldest result for the window thread. false: none.
result_take :: proc "contextless" (result: ^store_work.Result) -> bool {
	system.lock(&store_lock)
	taken := store_work.queue_pop(&results, result)
	system.unlock(&store_lock)
	if taken {
		system.event_wake(&results_taken_event)
	}
	return taken
}
