// The write of one module file into the store module_files
// (src/md/features/processes_from_a_disk.md, "How the file reaches the
// disk"). The bytes go into the staging object of the nickname by ranges,
// committed in steps; at the end one clone makes the nickname name them, in
// one commit, and the staging object goes. A write that stops in its middle
// drops its pending changes and its staging object: the file before stays
// under the nickname and runs, and no pending block of the storage service
// stays held. The module module_files gives the calls of its client of
// the storage service, and a host test gives a store in memory.
package module_files_core

import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/storage_status"
import "modus:disk_process"

// The bytes of one write_range: the call region of a connection has 64 KiB,
// and holds the arguments too.
WRITE_PIECE :: 32 * 1024

// The bytes of the pending changes of one commit of a staging object. The
// storage service holds the pending blocks of a connection in a bounded
// pool, so a large file is committed in steps of 1 MiB; the steps are on
// the staging object, which no load reads, and the nickname changes once,
// at the end.
COMMIT_STEP_BYTES :: 1024 * 1024
#assert(COMMIT_STEP_BYTES % WRITE_PIECE == 0)

// The least rate of the body of a receive. A link that gives a module file
// at this rate is slow and works. The total deadline of a body is
// RECEIVE_START_MILLISECONDS and the time of its Content-Length at this
// rate: 1054 seconds for a file of 64 MiB.
RECEIVE_LEAST_BYTES_PER_SECOND :: 64 * 1024
RECEIVE_START_MILLISECONDS :: disk_process.LOAD_DEADLINE_MILLISECONDS

// receive_total_deadline gives the time past which a body of size bytes,
// asked at the time start, ends its receive, whatever pieces came.
receive_total_deadline :: proc "contextless" (start: u64, size: int) -> u64 {
	return start + RECEIVE_START_MILLISECONDS + u64(size) * 1000 / RECEIVE_LEAST_BYTES_PER_SECOND
}

// The calls of the storage service that the write of a file makes: the
// client of this service on a machine, a fake in a host test. Each call
// writes the error record of a status Failed.
File_Store :: struct {
	user:         rawptr,
	write_range:  proc "contextless" (user: rawptr, name: string, offset: u64, bytes: []u8, error: ^errors.Error_Record) -> storage_status.Status,
	set_size:     proc "contextless" (user: rawptr, name: string, size: u64, error: ^errors.Error_Record) -> storage_status.Status,
	commit:       proc "contextless" (user: rawptr, name: string, error: ^errors.Error_Record) -> storage_status.Status,
	clone:        proc "contextless" (user: rawptr, name: string, new_name: string, error: ^errors.Error_Record) -> storage_status.Status,
	remove:       proc "contextless" (user: rawptr, name: string, error: ^errors.Error_Record) -> storage_status.Status,
	drop_pending: proc "contextless" (user: rawptr, name: string, error: ^errors.Error_Record) -> storage_status.Status,
}

// The write of one file by pieces: its nickname and its staging object,
// the bytes written so far, the bytes of the last commit, the hash of the
// bytes written, and the error record of the call that the store refused.
File_Stream :: struct {
	store:          ^File_Store,
	nickname:       string,
	staging:        [disk_process.STAGING_NAME_LIMIT]u8,
	staging_length: int,
	hasher:         blake3.Hasher,
	written:        int,
	committed:      int,
	open:           bool, // The staging object can hold pending changes or bytes: an end or an abandon must close it.
	store_error:    errors.Error_Record, // The record of the refused call, for a status Failed.
}

// file_stream_begin starts the write of a file of a nickname.
file_stream_begin :: proc "contextless" (stream: ^File_Stream, store: ^File_Store, nickname: string) {
	stream^ = {store = store, nickname = nickname, hasher = blake3.hasher_make(), open = true}
	stream.staging_length = len(disk_process.staging_name_write(&stream.staging, nickname))
}

// file_stream_staging gives the name of the staging object of the write.
file_stream_staging :: proc "contextless" (stream: ^File_Stream) -> string {
	return string(stream.staging[:stream.staging_length])
}

// file_stream_piece writes one piece after the bytes written so far, as a
// pending change of the staging object, adds it to the hash, and commits
// the pending changes at each COMMIT_STEP_BYTES. The piece is memory of
// this service: the bytes hashed are the bytes written. A refusal of the
// store abandons the write, and gives its status; store_error then has
// the record of a status Failed.
file_stream_piece :: proc "contextless" (stream: ^File_Stream, bytes: []u8) -> storage_status.Status {
	store := stream.store
	staging := file_stream_staging(stream)
	for at := 0; at < len(bytes); at += WRITE_PIECE {
		part := bytes[at:min(at + WRITE_PIECE, len(bytes))]
		if status := store.write_range(store.user, staging, u64(stream.written), part, &stream.store_error); status != .Ok {
			file_stream_abandon(stream)
			return status
		}
		blake3.hasher_update(&stream.hasher, part)
		stream.written += len(part)
		if stream.written - stream.committed >= COMMIT_STEP_BYTES {
			if status := store.commit(store.user, staging, &stream.store_error); status != .Ok {
				file_stream_abandon(stream)
				return status
			}
			stream.committed = stream.written
		}
	}
	return .Ok
}

// file_stream_end sets the size of the staging object to the bytes
// written, since a staging object that a stop left can be longer, commits
// it, makes the nickname name its bytes in one commit, removes it, and
// gives the hash of the bytes written. A refusal abandons the write, as
// file_stream_piece does.
file_stream_end :: proc "contextless" (stream: ^File_Stream) -> (hash: blake3.Hash, status: storage_status.Status) {
	store := stream.store
	staging := file_stream_staging(stream)
	if status = store.set_size(store.user, staging, u64(stream.written), &stream.store_error); status != .Ok {
		file_stream_abandon(stream)
		return {}, status
	}
	if status = store.commit(store.user, staging, &stream.store_error); status != .Ok {
		file_stream_abandon(stream)
		return {}, status
	}
	stream.committed = stream.written
	if status = store.clone(store.user, staging, stream.nickname, &stream.store_error); status != .Ok {
		file_stream_abandon(stream)
		return {}, status
	}
	// The nickname holds the file now: a staging object that stays costs
	// blocks until the next write of the nickname, and fails nothing.
	ignored: errors.Error_Record
	_ = store.remove(store.user, staging, &ignored)
	stream.open = false
	return blake3.hasher_finish(&stream.hasher), .Ok
}

// file_stream_abandon ends a write that stops before its end: it drops the
// pending changes of the staging object and removes it. The nickname keeps
// the file before. A failure of the drop or of the remove changes nothing
// for the caller: it already has the error record of the first failure.
file_stream_abandon :: proc "contextless" (stream: ^File_Stream) {
	if !stream.open {
		return
	}
	stream.open = false
	store := stream.store
	staging := file_stream_staging(stream)
	ignored: errors.Error_Record
	_ = store.drop_pending(store.user, staging, &ignored)
	_ = store.remove(store.user, staging, &ignored)
}
