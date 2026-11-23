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

// bind opens the private store that the root service gave in the context,
// and gives its port. ok is false for a process with no grant Store: the
// port then has no procedure, and each read and write fails.
bind :: proc "contextless" (ctx: ^system.Context) -> (port: pr.Private_Store_Port, ok: bool) {
	store_client, ok = storage.open(ctx)
	if !ok {
		return {}, false
	}
	return {user = &store_client, size = size, read = read, write = write}, true
}

// The bytes of one call to the storage service: an object past them
// crosses in ranges of this size, so its size is bounded by the store and
// not by the call region of the connection.
PIECE_BYTES :: 16 * 1024

@(private = "file")
size :: proc "contextless" (user: rawptr, name: string) -> (bytes: int, status: pr.Private_Store_Status) {
	client := (^storage.Client)(user)
	error: errors.Error_Record
	object_size, size_status := storage.size(client, storage.ROOT, name, &error)
	if storage.export_failed_with(size_status, object_size, .Absent) {
		return 0, .Absent
	}
	if size_status != .Ok || object_size < 0 || object_size > i64(max(int)) {
		return 0, .Failed
	}
	return int(object_size), .Ok
}

@(private = "file")
read :: proc "contextless" (user: rawptr, name: string, into: []u8) -> (count: int, status: pr.Private_Store_Status) {
	client := (^storage.Client)(user)
	error: errors.Error_Record
	// The size comes first, so a long object is refused and never read in
	// part.
	object_size: int
	object_size, status = size(user, name)
	if status != .Ok {
		return 0, status
	}
	if object_size > len(into) {
		return 0, .Too_Large
	}
	if object_size <= PIECE_BYTES {
		bytes, found, read_status := storage.read(client, storage.ROOT, name, into, &error)
		if read_status != .Ok {
			return 0, .Failed
		}
		if !found {
			return 0, .Absent
		}
		if len(bytes) != object_size {
			return 0, .Failed
		}
		return len(bytes), .Ok
	}
	// A range of each piece. A write of another connection between two
	// ranges gives a mix of two states: the reader checks the object (a
	// plan generation names its hash), and a size that changed is a failure.
	for offset := 0; offset < object_size; {
		piece := into[offset:min(object_size, offset + PIECE_BYTES)]
		bytes, range_status := storage.read_range(client, storage.ROOT, name, u64(offset), piece, &error)
		if range_status != .Ok || len(bytes) == 0 {
			return 0, .Failed
		}
		offset += len(bytes)
	}
	if after, after_status := size(user, name); after_status != .Ok || after != object_size {
		return 0, .Failed
	}
	return object_size, .Ok
}

@(private = "file")
write :: proc "contextless" (user: rawptr, name: string, data: []u8) -> pr.Private_Store_Status {
	client := (^storage.Client)(user)
	error: errors.Error_Record
	if len(data) <= PIECE_BYTES {
		generation, status := storage.write(client, storage.ROOT, name, data, &error)
		if status != .Ok || generation < 0 {
			return .Failed
		}
		return .Ok
	}
	// Pending changes of the connection, then one commit: a reader finds the
	// object of before or the whole new one.
	if storage.set_size(client, storage.ROOT, name, u64(len(data)), &error) != .Ok {
		return .Failed
	}
	for offset := 0; offset < len(data); offset += PIECE_BYTES {
		piece := data[offset:min(len(data), offset + PIECE_BYTES)]
		if _, status := storage.write_range(client, storage.ROOT, name, u64(offset), piece, &error); status != .Ok {
			return .Failed
		}
	}
	if _, status := storage.commit(client, storage.ROOT, name, &error); status != .Ok {
		return .Failed
	}
	return .Ok
}
