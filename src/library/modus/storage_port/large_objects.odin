package storage_port

// The objects of any size of a private store, by ranges: the call region
// of a connection holds 64 KiB with the arguments, so a whole object of
// more passes in pieces (src/md/features/recipes.md, "The local store").

import "modus:contract/errors"
import pr "modus:contract/plans_recipes"
import "modus:storage"

// The bytes of one write_range: the call region holds them with the
// arguments.
WRITE_PIECE_BYTES :: 32 * 1024

// The pending bytes of one commit of a write by ranges: the storage service
// holds the pending blocks of a connection in a bounded pool.
COMMIT_STEP_BYTES :: 1024 * 1024
#assert(COMMIT_STEP_BYTES % WRITE_PIECE_BYTES == 0)

// read_large reads an object of any size into into using storage.read_range,
// so a service can read multi-megabyte guest kernels or initial archives
// without opening a second client.
read_large :: proc "contextless" (port: ^pr.Private_Store_Port, name: string, into: []u8) -> (count: int, status: pr.Private_Store_Status) {
	if port == nil || port.user == nil {
		return 0, .Failed
	}
	client := (^storage.Client)(port.user)
	error: errors.Error_Record
	size, size_status := storage.size(client, storage.ROOT, name, &error)
	if size_status == .Absent {
		return 0, .Absent
	}
	if size_status != .Ok || size < 0 {
		return 0, .Failed
	}
	if size > i64(len(into)) {
		return 0, .Too_Large
	}
	read_total := u64(0)
	for read_total < u64(size) {
		chunk, read_status := storage.read_range(client, storage.ROOT, name, read_total, into[read_total:size], &error)
		if read_status != .Ok || len(chunk) == 0 {
			return 0, .Failed
		}
		read_total += u64(len(chunk))
	}
	return int(read_total), .Ok
}

// write_large makes the object name the bytes of data, of any size: by
// write_range pieces, committed in steps, and a last commit that sets the
// size. A write that fails drops its pending changes, so no pending block
// stays held. A reader that comes between two steps finds other bytes
// than the whole: each writer of this port names an object by the hash of
// its bytes, or writes its head after it, so a reader checks it.
write_large :: proc "contextless" (port: ^pr.Private_Store_Port, name: string, data: []u8) -> pr.Private_Store_Status {
	if port == nil || port.user == nil {
		return .Failed
	}
	client := (^storage.Client)(port.user)
	error: errors.Error_Record
	// Pending changes that an earlier failed write could not drop go first:
	// a write never starts over them. A write after writes that dropped
	// their changes makes no call more.
	if pending_kept {
		if !pending_drop(client, string(pending_kept_name[:pending_kept_length])) {
			return .Failed
		}
		pending_kept = false
	}
	// An object that fits the call region is one write: one call, one
	// commit.
	if len(data) <= WRITE_PIECE_BYTES {
		generation, status := storage.write(client, storage.ROOT, name, data, &error)
		return status == .Ok && generation >= 0 ? .Ok : .Failed
	}
	committed := 0
	for written := 0; written < len(data); {
		part := data[written:min(written + WRITE_PIECE_BYTES, len(data))]
		if _, status := storage.write_range(client, storage.ROOT, name, u64(written), part, &error); status != .Ok {
			return write_large_abandon(client, name)
		}
		written += len(part)
		if written - committed >= COMMIT_STEP_BYTES {
			if _, status := storage.commit(client, storage.ROOT, name, &error); status != .Ok {
				return write_large_abandon(client, name)
			}
			committed = written
		}
	}
	if status := storage.set_size(client, storage.ROOT, name, u64(len(data)), &error); status != .Ok {
		return write_large_abandon(client, name)
	}
	if _, status := storage.commit(client, storage.ROOT, name, &error); status != .Ok {
		return write_large_abandon(client, name)
	}
	return .Ok
}

// write_large_abandon ends a write that failed: it drops its pending
// changes. A refused drop leaves them held on this connection, and the
// next write of the name drops them before it writes.
@(private = "file")
write_large_abandon :: proc "contextless" (client: ^storage.Client, name: string) -> pr.Private_Store_Status {
	if !pending_drop(client, name) {
		pending_kept = true
		pending_kept_length = copy(pending_kept_name[:], name)
	}
	return .Failed
}

// The object of a failed write whose pending changes the storage service
// did not drop: the next write drops them first. One client of the private
// store serves each process (store_client).
@(private = "file")
pending_kept: bool
@(private = "file")
pending_kept_name: [64]u8
@(private = "file")
pending_kept_length: int

// pending_drop drops the pending changes of this connection on the object
// name: true when it dropped them, or the object had none.
@(private = "file")
pending_drop :: proc "contextless" (client: ^storage.Client, name: string) -> bool {
	error: errors.Error_Record
	status := storage.drop_pending(client, storage.ROOT, name, &error)
	return status == .Ok || status == .Failed && error.kind == i64(errors.Kind.Absent) && (error.unit == i64(errors.Unit.Pending) || error.unit == i64(errors.Unit.Objects))
}

// The procedures of the port over the client of this process.
@(private)
port_read :: proc "contextless" (user: rawptr, name: string, into: []u8) -> (count: int, status: pr.Private_Store_Status) {
	port := pr.Private_Store_Port{user = user}
	return read_large(&port, name, into)
}

@(private)
port_write :: proc "contextless" (user: rawptr, name: string, data: []u8) -> pr.Private_Store_Status {
	port := pr.Private_Store_Port{user = user}
	return write_large(&port, name, data)
}

@(private)
port_size :: proc "contextless" (user: rawptr, name: string) -> (bytes: u64, status: pr.Private_Store_Status) {
	client := (^storage.Client)(user)
	error: errors.Error_Record
	count, size_status := storage.size(client, storage.ROOT, name, &error)
	if size_status == .Absent {
		return 0, .Absent
	}
	if size_status != .Ok || count < 0 {
		return 0, .Failed
	}
	return u64(count), .Ok
}

@(private)
port_read_range :: proc "contextless" (user: rawptr, name: string, offset: u64, into: []u8) -> (count: int, status: pr.Private_Store_Status) {
	client := (^storage.Client)(user)
	error: errors.Error_Record
	bytes, read_status := storage.read_range(client, storage.ROOT, name, offset, into, &error)
	if read_status == .Failed && error.kind == i64(errors.Kind.Absent) {
		return 0, .Absent
	}
	if read_status != .Ok {
		return 0, .Failed
	}
	return len(bytes), .Ok
}

@(private)
port_remove :: proc "contextless" (user: rawptr, name: string) -> pr.Private_Store_Status {
	client := (^storage.Client)(user)
	error: errors.Error_Record
	generation, status := storage.remove(client, storage.ROOT, name, &error)
	if status == .Absent {
		return .Absent
	}
	if status != .Ok || generation < 0 {
		return .Failed
	}
	return .Ok
}

@(private)
port_list :: proc "contextless" (user: rawptr, after: string, rows: []pr.Private_Store_Entry, names: []u8) -> (count: int, status: pr.Private_Store_Status) {
	client := (^storage.Client)(user)
	error: errors.Error_Record
	listed: [32]storage.Listed
	wanted := min(len(rows), len(listed))
	page, list_status := storage.list(client, storage.ROOT, after, listed[:wanted], names, &error)
	if list_status != .Ok {
		return 0, .Failed
	}
	for item, index in page {
		// The offsets come from the storage service: each one is checked
		// before a use, and the reader checks them again.
		if item.name_offset < 0 || item.name_count <= 0 || item.name_offset > i64(len(names)) - item.name_count {
			return 0, .Failed
		}
		rows[index] = {name_offset = int(item.name_offset), name_count = int(item.name_count), size = item.size, generation = item.generation}
	}
	return len(page), .Ok
}

@(private)
port_usage :: proc "contextless" (user: rawptr) -> (blocks: i64, limit: i64, status: pr.Private_Store_Status) {
	client := (^storage.Client)(user)
	counts, usage_status := storage.usage(client)
	if usage_status != .Ok || counts.blocks < 0 {
		return 0, 0, .Failed
	}
	return counts.blocks, counts.limit, .Ok
}
