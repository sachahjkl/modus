#+build !freestanding
package module_files_core

import "base:runtime"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/storage_status"
import "modus:disk_process"

// A store in memory with the semantics of the calls of a file stream, as
// the storage service has them: the pending changes of an object are apart
// from its committed bytes until a commit, a drop forgets them, a remove
// removes the committed object and leaves its pending changes held, and a
// clone makes a version of its target.
Fake_Store :: struct {
	committed:     map[string][dynamic]u8,
	pending:       map[string][dynamic]u8,
	versions:      map[string]int,
	commits:       int,
	drops:         int,
	writes:        int,
	write_failing: int, // The write_range that fails, counted from 1; 0: none.
	drop_refused:  bool, // Each drop_pending is refused, and drops nothing.
	context_of_test: runtime.Context, // The calls of the stream are contextless: the maps take the allocator of the test.
}

@(private = "file")
fake_of :: proc "contextless" (user: rawptr) -> ^Fake_Store {
	return (^Fake_Store)(user)
}

@(private = "file")
fake_pending :: proc(store: ^Fake_Store, name: string) -> ^[dynamic]u8 {
	if name not_in store.pending {
		bytes := make([dynamic]u8, context.temp_allocator)
		if committed, found := store.committed[name]; found {
			append(&bytes, ..committed[:])
		}
		store.pending[name] = bytes
	}
	return &store.pending[name]
}

fake_file_store :: proc(store: ^Fake_Store) -> File_Store {
	store.committed = make(map[string][dynamic]u8, context.temp_allocator)
	store.pending = make(map[string][dynamic]u8, context.temp_allocator)
	store.versions = make(map[string]int, context.temp_allocator)
	store.context_of_test = context
	return {
		user = store,
		write_range = proc "contextless" (user: rawptr, name: string, offset: u64, bytes: []u8, error: ^errors.Error_Record) -> storage_status.Status {
			store := fake_of(user)
			context = store.context_of_test
			store.writes += 1
			if store.writes == store.write_failing {
				error^ = errors.error_make(.Full, .Blocks)
				return .Failed
			}
			pending := fake_pending(store, name)
			for u64(len(pending)) < offset + u64(len(bytes)) {
				append(pending, 0)
			}
			copy(pending[offset:], bytes)
			return .Ok
		},
		set_size = proc "contextless" (user: rawptr, name: string, size: u64, error: ^errors.Error_Record) -> storage_status.Status {
			store := fake_of(user)
			context = store.context_of_test
			pending := fake_pending(store, name)
			resize(pending, int(size))
			return .Ok
		},
		commit = proc "contextless" (user: rawptr, name: string, error: ^errors.Error_Record) -> storage_status.Status {
			store := fake_of(user)
			context = store.context_of_test
			pending, found := store.pending[name]
			if !found {
				return .Failed
			}
			store.committed[name] = pending
			delete_key(&store.pending, name)
			store.commits += 1
			return .Ok
		},
		clone = proc "contextless" (user: rawptr, name: string, new_name: string, error: ^errors.Error_Record) -> storage_status.Status {
			store := fake_of(user)
			context = store.context_of_test
			source, found := store.committed[name]
			if !found {
				return .Failed
			}
			copied := make([dynamic]u8, context.temp_allocator)
			append(&copied, ..source[:])
			store.committed[new_name] = copied
			store.versions[new_name] += 1
			return .Ok
		},
		remove = proc "contextless" (user: rawptr, name: string, error: ^errors.Error_Record) -> storage_status.Status {
			store := fake_of(user)
			context = store.context_of_test
			delete_key(&store.committed, name)
			return .Ok
		},
		drop_pending = proc "contextless" (user: rawptr, name: string, error: ^errors.Error_Record) -> storage_status.Status {
			store := fake_of(user)
			context = store.context_of_test
			if store.drop_refused {
				error^ = errors.error_make(.Refused, .Pending)
				return .Failed
			}
			store.drops += 1
			delete_key(&store.pending, name)
			return .Ok
		},
	}
}

@(private = "file")
bytes_of :: proc(count: int, seed: u8) -> []u8 {
	bytes := make([]u8, count, context.temp_allocator)
	for &byte, index in bytes {
		byte = u8(index * 7) + seed
	}
	return bytes
}

// stream_whole writes bytes as a file of nickname, the head piece first,
// then pieces of WRITE_PIECE, as receive and put do.
@(private = "file")
stream_whole :: proc(store: ^File_Store, nickname: string, bytes: []u8, head: int) -> (hash: blake3.Hash, status: storage_status.Status) {
	stream: File_Stream
	if status = file_stream_begin(&stream, store, nickname); status != .Ok {
		return
	}
	if status = file_stream_piece(&stream, bytes[:head]); status != .Ok {
		return
	}
	for at := head; at < len(bytes); at += WRITE_PIECE {
		if status = file_stream_piece(&stream, bytes[at:min(at + WRITE_PIECE, len(bytes))]); status != .Ok {
			return
		}
	}
	return file_stream_end(&stream)
}

@(private = "file")
staging_of :: proc(nickname: string) -> string {
	name: [disk_process.STAGING_NAME_LIMIT]u8
	return strings.clone(disk_process.staging_name_write(&name, nickname), context.temp_allocator)
}

// The edges of a piece and of a step of commits, each with the head of
// the answer before it: the nickname holds the bytes, one version, and no
// staging object or pending change stays.
@(test)
a_file_at_each_edge_reaches_its_nickname_whole :: proc(t: ^testing.T) {
	sizes := [?]int{1, WRITE_PIECE - 1, WRITE_PIECE, WRITE_PIECE + 1, COMMIT_STEP_BYTES - 1, COMMIT_STEP_BYTES, COMMIT_STEP_BYTES + 1}
	for size in sizes {
		for head in ([?]int{0, 1, 100}) {
			if head > size {
				continue
			}
			fake: Fake_Store
			store := fake_file_store(&fake)
			bytes := bytes_of(size, u8(head))
			hash, status := stream_whole(&store, "hello", bytes, head)
			testing.expectf(t, status == .Ok, "%d bytes, head %d: status %v", size, head, status)
			testing.expectf(t, hash == blake3.hash(bytes), "%d bytes, head %d: the hash is not the hash of the bytes", size, head)
			held := fake.committed["hello"]
			testing.expectf(t, len(held) == size && string(held[:]) == string(bytes), "%d bytes, head %d: the nickname holds %d bytes", size, head, len(held))
			testing.expect_value(t, fake.versions["hello"], 1)
			_, staging_left := fake.committed[staging_of("hello")]
			testing.expect(t, !staging_left)
			testing.expect_value(t, len(fake.pending), 0)
			// One commit for each full step, and the last: a file under 2 MiB
			// has one step at most, whatever its head.
			testing.expectf(t, fake.commits == size / COMMIT_STEP_BYTES + 1, "%d bytes, head %d: %d commits", size, head, fake.commits)
		}
	}
}

// A head that is not a whole piece moves each step: the step commits at
// the first piece that brings the pending bytes to 1 MiB or past it.
@(test)
the_head_of_the_answer_shifts_the_steps :: proc(t: ^testing.T) {
	fake: Fake_Store
	store := fake_file_store(&fake)
	stream: File_Stream
	testing.expect_value(t, file_stream_begin(&stream, &store, "hello"), storage_status.Status.Ok)
	bytes := bytes_of(2 * COMMIT_STEP_BYTES, 3)
	testing.expect_value(t, file_stream_piece(&stream, bytes[:100]), storage_status.Status.Ok)
	at := 100
	for at + WRITE_PIECE <= COMMIT_STEP_BYTES {
		testing.expect_value(t, file_stream_piece(&stream, bytes[at:at + WRITE_PIECE]), storage_status.Status.Ok)
		at += WRITE_PIECE
	}
	// 100 bytes and 31 pieces: 100 bytes short of 1 MiB, no commit yet.
	testing.expect_value(t, stream.written, COMMIT_STEP_BYTES - WRITE_PIECE + 100)
	testing.expect_value(t, fake.commits, 0)
	testing.expect_value(t, file_stream_piece(&stream, bytes[at:at + WRITE_PIECE]), storage_status.Status.Ok)
	testing.expect_value(t, fake.commits, 1)
	testing.expect_value(t, stream.committed, COMMIT_STEP_BYTES + 100)
	// The nickname does not exist before the end: a step is on the
	// staging object.
	_, named := fake.committed["hello"]
	testing.expect(t, !named)
	file_stream_abandon(&stream)
}

// A body that ends early, and a store that refuses a piece: the file
// before stays under the nickname, the pending changes are dropped, and
// the staging object goes.
@(test)
a_write_that_stops_keeps_the_file_before :: proc(t: ^testing.T) {
	fake: Fake_Store
	store := fake_file_store(&fake)
	old := bytes_of(3 * WRITE_PIECE, 9)
	_, status := stream_whole(&store, "hello", old, 0)
	testing.expect_value(t, status, storage_status.Status.Ok)

	// The body ends after one step and one piece more.
	stream: File_Stream
	testing.expect_value(t, file_stream_begin(&stream, &store, "hello"), storage_status.Status.Ok)
	new_bytes := bytes_of(COMMIT_STEP_BYTES + WRITE_PIECE, 1)
	for at := 0; at < len(new_bytes); at += WRITE_PIECE {
		testing.expect_value(t, file_stream_piece(&stream, new_bytes[at:at + WRITE_PIECE]), storage_status.Status.Ok)
	}
	file_stream_abandon(&stream)
	testing.expect(t, string(fake.committed["hello"][:]) == string(old))
	testing.expect_value(t, fake.versions["hello"], 1)
	_, staging_left := fake.committed[staging_of("hello")]
	testing.expect(t, !staging_left)
	testing.expect_value(t, len(fake.pending), 0)
	drops := fake.drops
	// A second abandon does nothing.
	file_stream_abandon(&stream)
	testing.expect_value(t, fake.drops, drops)

	// The third write_range is refused: its status and the error record of
	// the store come back, and nothing changed under the nickname.
	fake.writes = 0
	fake.write_failing = 3
	_, status = stream_whole(&store, "hello", bytes_of(5 * WRITE_PIECE, 2), 0)
	testing.expect_value(t, status, storage_status.Status.Failed)
	testing.expect(t, string(fake.committed["hello"][:]) == string(old))
	testing.expect_value(t, len(fake.pending), 0)
}

// A shorter file over a longer one, and over a longer staging object that
// a stop left: the nickname holds the new bytes and no tail of the old.
@(test)
a_shorter_file_replaces_a_longer_one_whole :: proc(t: ^testing.T) {
	fake: Fake_Store
	store := fake_file_store(&fake)
	_, status := stream_whole(&store, "hello", bytes_of(COMMIT_STEP_BYTES + 5, 4), 0)
	testing.expect_value(t, status, storage_status.Status.Ok)
	fake.committed[staging_of("hello")] = make([dynamic]u8, 4 * WRITE_PIECE, context.temp_allocator)
	short := bytes_of(WRITE_PIECE + 1, 5)
	_, status = stream_whole(&store, "hello", short, 1)
	testing.expect_value(t, status, storage_status.Status.Ok)
	held := fake.committed["hello"]
	testing.expect(t, len(held) == len(short) && string(held[:]) == string(short))
	testing.expect_value(t, fake.versions["hello"], 2)
	_, staging_left := fake.committed[staging_of("hello")]
	testing.expect(t, !staging_left)
}

// A staging name is never a nickname: it passes NAME_LIMIT, and the
// listing and the import scan skip it.
@(test)
a_staging_name_is_no_nickname :: proc(t: ^testing.T) {
	name := staging_of("a")
	testing.expect(t, disk_process.staging_name_is(name))
	testing.expect(t, len(name) > disk_process.NAME_LIMIT)
	testing.expect(t, disk_process.nickname_refusal(name, len(name), 1, .Read).kind != 0)
	testing.expect(t, !disk_process.staging_name_is(disk_process.STAGING_PREFIX))
	testing.expect(t, !disk_process.staging_name_is("hello"))
	longest: [disk_process.NAME_LIMIT]u8
	for &byte in longest {
		byte = 'z'
	}
	testing.expect_value(t, len(staging_of(string(longest[:]))), disk_process.STAGING_NAME_LIMIT)
}

// The total deadline of a body: the start allowance, then the bytes at the
// least rate.
@(test)
the_total_deadline_follows_the_length :: proc(t: ^testing.T) {
	testing.expect_value(t, receive_total_deadline(0, 0), u64(RECEIVE_START_MILLISECONDS))
	testing.expect_value(t, receive_total_deadline(0, RECEIVE_LEAST_BYTES_PER_SECOND), u64(RECEIVE_START_MILLISECONDS + 1000))
	testing.expect_value(t, receive_total_deadline(0, disk_process.FILE_BYTES_LIMIT), u64(RECEIVE_START_MILLISECONDS + 1_024_000))
	testing.expect_value(t, receive_total_deadline(5, 1), u64(5 + RECEIVE_START_MILLISECONDS))
}

// A drop that the store refuses: the abandon reports it, the pending
// changes stay held, a remove does not drop them, and the next write of
// the nickname drops them before it writes. A drop refused at the start of
// a write stops the write: it never writes over pending changes.
@(test)
a_refused_drop_is_reported_then_dropped_by_the_next_write :: proc(t: ^testing.T) {
	fake: Fake_Store
	store := fake_file_store(&fake)
	old := bytes_of(WRITE_PIECE, 3)
	_, status := stream_whole(&store, "hello", old, 0)
	testing.expect_value(t, status, storage_status.Status.Ok)

	stream: File_Stream
	testing.expect_value(t, file_stream_begin(&stream, &store, "hello"), storage_status.Status.Ok)
	testing.expect_value(t, file_stream_piece(&stream, bytes_of(WRITE_PIECE, 4)), storage_status.Status.Ok)
	fake.drop_refused = true
	file_stream_abandon(&stream)
	testing.expect(t, stream.pending_kept)
	_, held := fake.pending[staging_of("hello")]
	testing.expect(t, held, "a remove leaves the pending changes held")
	testing.expect(t, string(fake.committed["hello"][:]) == string(old))

	// The drop is refused again: the next write does not start.
	again: File_Stream
	testing.expect_value(t, file_stream_begin(&again, &store, "hello"), storage_status.Status.Failed)
	testing.expect(t, !again.open)
	testing.expect_value(t, again.store_error.kind, i64(errors.Kind.Refused))

	// The store drops again: the next write drops the held changes first,
	// and writes the new file whole.
	fake.drop_refused = false
	new_bytes := bytes_of(WRITE_PIECE + 7, 5)
	_, status = stream_whole(&store, "hello", new_bytes, 0)
	testing.expect_value(t, status, storage_status.Status.Ok)
	testing.expect(t, string(fake.committed["hello"][:]) == string(new_bytes))
	testing.expect_value(t, len(fake.pending), 0)
}
