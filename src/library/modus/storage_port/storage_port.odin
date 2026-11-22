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
	return {user = &store_client, read = read, write = write}, true
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
