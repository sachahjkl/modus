// The port of a private store over the storage client: the services of the
// declarations (plans, recipes, projects) keep their records through
// plans_recipes.Private_Store_Port, and this package binds that port to the
// private store that the root service gave the process
// (src/md/features/declarations.md, "Storage").
package storage_port

import "modus:contract/errors"
import pr "modus:contract/plans_recipes"
import "modus:storage"
import "modus:system"

// The connection to the private store of the process.
store_client: storage.Client

// The bytes of a call region that a range leaves to the record of the call
// and to the name of the object.
CALL_RECORD_ROOM :: 4096

// bind opens the private store that the root service gave in the context,
// and gives its port. ok is false for a process with no grant Store: the
// port then has no procedure, and each read and write fails. One range is
// at most what the call region takes beside the record of its call.
bind :: proc "contextless" (ctx: ^system.Context) -> (port: pr.Private_Store_Port, ok: bool) {
	store_client, ok = storage.open(ctx)
	if !ok {
		return {}, false
	}
	if len(store_client.region) <= 2 * CALL_RECORD_ROOM {
		return {}, false
	}
	return {
		user = &store_client,
		read = read,
		write = write,
		size = size,
		read_range = read_range,
		write_range = write_range,
		commit = commit,
		remove = remove,
		list = list,
		range_bytes_most = len(store_client.region) - CALL_RECORD_ROOM,
	}, true
}

@(private = "file")
read :: proc "contextless" (user: rawptr, name: string, into: []u8) -> (count: int, status: pr.Private_Store_Status) {
	client := (^storage.Client)(user)
	error: errors.Error_Record
	// The read of the storage client cuts an object that does not fit: the
	// size comes first, so a long object is refused and never read in part.
	size, size_status := storage.size(client, storage.ROOT, name, &error)
	if storage.export_failed_with(size_status, size, .Absent) {
		return 0, .Absent
	}
	if size_status != .Ok || size < 0 {
		return 0, .Failed
	}
	if size > i64(len(into)) {
		return 0, .Too_Large
	}
	bytes, found, read_status := storage.read(client, storage.ROOT, name, into, &error)
	if read_status != .Ok {
		return 0, .Failed
	}
	if !found {
		return 0, .Absent
	}
	if i64(len(bytes)) != size {
		return 0, .Failed
	}
	return len(bytes), .Ok
}

@(private = "file")
write :: proc "contextless" (user: rawptr, name: string, data: []u8) -> pr.Private_Store_Status {
	client := (^storage.Client)(user)
	error: errors.Error_Record
	generation, status := storage.write(client, storage.ROOT, name, data, &error)
	if status != .Ok || generation < 0 {
		return .Failed
	}
	return .Ok
}

@(private = "file")
size :: proc "contextless" (user: rawptr, name: string) -> (bytes: u64, status: pr.Private_Store_Status) {
	client := (^storage.Client)(user)
	error: errors.Error_Record
	count, size_status := storage.size(client, storage.ROOT, name, &error)
	if storage.export_failed_with(size_status, count, .Absent) {
		return 0, .Absent
	}
	if size_status != .Ok || count < 0 {
		return 0, .Failed
	}
	return u64(count), .Ok
}

@(private = "file")
read_range :: proc "contextless" (user: rawptr, name: string, offset: u64, into: []u8) -> (count: int, status: pr.Private_Store_Status) {
	client := (^storage.Client)(user)
	error: errors.Error_Record
	bytes, range_status := storage.read_range(client, storage.ROOT, name, offset, into, &error)
	if range_status != .Ok {
		return 0, .Failed
	}
	return len(bytes), .Ok
}

@(private = "file")
write_range :: proc "contextless" (user: rawptr, name: string, offset: u64, data: []u8) -> pr.Private_Store_Status {
	client := (^storage.Client)(user)
	error: errors.Error_Record
	written, status := storage.write_range(client, storage.ROOT, name, offset, data, &error)
	if status != .Ok || written < 0 {
		return .Failed
	}
	return .Ok
}

@(private = "file")
commit :: proc "contextless" (user: rawptr, name: string) -> pr.Private_Store_Status {
	client := (^storage.Client)(user)
	error: errors.Error_Record
	_, status := storage.commit(client, storage.ROOT, name, &error)
	return status == .Ok ? .Ok : .Failed
}

@(private = "file")
remove :: proc "contextless" (user: rawptr, name: string) -> pr.Private_Store_Status {
	client := (^storage.Client)(user)
	error: errors.Error_Record
	generation, status := storage.remove(client, storage.ROOT, name, &error)
	if storage.export_failed_with(status, generation, .Absent) {
		return .Absent
	}
	if status != .Ok || generation < 0 {
		return .Failed
	}
	return .Ok
}

// The rows and the name bytes of one page of a list.
LIST_PAGE_ROWS :: 64
list_rows: [LIST_PAGE_ROWS]storage.Listed
list_names: [LIST_PAGE_ROWS * 64]u8

@(private = "file")
list :: proc "contextless" (user: rawptr, after: string, into: []pr.Private_Object_Name) -> (count: int, status: pr.Private_Store_Status) {
	client := (^storage.Client)(user)
	error: errors.Error_Record
	rows := list_rows[:min(len(into), LIST_PAGE_ROWS)]
	page, list_status := storage.list(client, storage.ROOT, after, rows, list_names[:], &error)
	if list_status != .Ok {
		return 0, .Failed
	}
	for row in page {
		kind, kind_ok := storage.entry_kind_of_word(row.kind)
		if !kind_ok || kind != .Object {
			continue
		}
		if row.name_offset < 0 || row.name_count <= 0 || row.name_count > 64 || row.name_offset > i64(len(list_names)) - row.name_count {
			return 0, .Failed
		}
		into[count] = {}
		pr.private_object_name_append(&into[count], string(list_names[row.name_offset:][:row.name_count]))
		count += 1
	}
	// A page of trees only would end the list early: its last name goes on
	// as the start of the next page through the caller, which pages after
	// the last name that it got. A page that held only trees gives one
	// more page here.
	if count == 0 && len(page) > 0 {
		last := page[len(page) - 1]
		if last.name_offset >= 0 && last.name_count > 0 && last.name_offset <= i64(len(list_names)) - last.name_count {
			next: pr.Private_Object_Name
			pr.private_object_name_append(&next, string(list_names[last.name_offset:][:last.name_count]))
			return list(user, pr.private_object_name_text(&next), into)
		}
	}
	return count, .Ok
}
