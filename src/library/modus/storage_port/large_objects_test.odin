#+build !freestanding
package storage_port

import "core:testing"
import "modus:contract/errors"
import pr "modus:contract/plans_recipes"
import "modus:contract/storage_status"
import store "modus:contract/store"

@(private = "file")
Fake_Store :: struct {
	name:                string,
	committed:           []u8,
	committed_len:       int,
	pending:             []u8,
	pending_len:         int,
	has_pending:         bool,
	absent:              bool,
	read_chunk_limit:    int,
	size_status:         storage_status.Status,
	size_override:       i64,
	use_size_override:   bool,
	read_fail_at_call:   int,
	read_zero_at_call:   int,
	read_overshoot_call: int,
	write_status:        storage_status.Status,
	write_generation:    i64,
	write_range_fail_at: int,
	commit_fail_at:      int,
	set_size_status:     storage_status.Status,
	drop_status:         storage_status.Status,
	drop_error:          errors.Error_Record,
	drop_fail_once:      bool,
	// Call counts and last arguments.
	write_calls:         int,
	write_range_calls:   int,
	commit_calls:        int,
	set_size_calls:      int,
	drop_calls:          int,
	read_range_calls:    int,
	last_drop_name_buf:  [store.ENTRY_NAME_CAPACITY]u8,
	last_drop_name_len:  int,
}

@(private = "file")
fake_size :: proc "contextless" (user: rawptr, name: string, _: ^errors.Error_Record) -> (i64, storage_status.Status) {
	s := (^Fake_Store)(user)
	if s.size_status != .Ok {
		return -1, s.size_status
	}
	if s.absent || (s.name != "" && name != s.name) {
		return -1, .Absent
	}
	if s.use_size_override {
		return s.size_override, .Ok
	}
	return i64(s.committed_len), .Ok
}

@(private = "file")
fake_read_range :: proc "contextless" (user: rawptr, name: string, offset: u64, into: []u8, _: ^errors.Error_Record) -> ([]u8, storage_status.Status) {
	s := (^Fake_Store)(user)
	s.read_range_calls += 1
	if s.read_fail_at_call > 0 && s.read_range_calls == s.read_fail_at_call {
		return nil, .Failed
	}
	if s.read_zero_at_call > 0 && s.read_range_calls == s.read_zero_at_call {
		return into[:0], .Ok
	}
	if s.read_overshoot_call > 0 && s.read_range_calls == s.read_overshoot_call {
		// Return a slice larger than remaining size to test upper-bound guard.
		return s.committed[:s.committed_len], .Ok
	}
	if s.absent || (s.name != "" && name != s.name) || offset > u64(s.committed_len) {
		return nil, .Absent
	}
	avail := s.committed_len - int(offset)
	take := min(avail, len(into))
	if s.read_chunk_limit > 0 {
		take = min(take, s.read_chunk_limit)
	}
	copy(into[:take], s.committed[int(offset):int(offset) + take])
	return into[:take], .Ok
}

@(private = "file")
fake_write :: proc "contextless" (user: rawptr, name: string, data: []u8, _: ^errors.Error_Record) -> (i64, storage_status.Status) {
	s := (^Fake_Store)(user)
	s.write_calls += 1
	if s.write_status != .Ok {
		return -1, s.write_status
	}
	if s.write_generation < 0 {
		return s.write_generation, .Ok
	}
	s.name = name
	s.absent = false
	copy(s.committed[:len(data)], data)
	s.committed_len = len(data)
	return s.write_generation, .Ok
}

@(private = "file")
fake_write_range :: proc "contextless" (user: rawptr, name: string, offset: u64, data: []u8, _: ^errors.Error_Record) -> (i64, storage_status.Status) {
	s := (^Fake_Store)(user)
	s.write_range_calls += 1
	if s.write_range_fail_at > 0 && s.write_range_calls == s.write_range_fail_at {
		return -1, .Failed
	}
	s.name = name
	s.has_pending = true
	end := int(offset) + len(data)
	copy(s.pending[int(offset):end], data)
	if end > s.pending_len {
		s.pending_len = end
	}
	return i64(len(data)), .Ok
}

@(private = "file")
fake_set_size :: proc "contextless" (user: rawptr, _: string, size: u64, _: ^errors.Error_Record) -> storage_status.Status {
	s := (^Fake_Store)(user)
	s.set_size_calls += 1
	if s.set_size_status != .Ok {
		return s.set_size_status
	}
	s.has_pending = true
	s.pending_len = int(size)
	return .Ok
}

@(private = "file")
fake_commit :: proc "contextless" (user: rawptr, _: string, _: ^errors.Error_Record) -> storage_status.Status {
	s := (^Fake_Store)(user)
	s.commit_calls += 1
	if s.commit_fail_at > 0 && s.commit_calls == s.commit_fail_at {
		return .Failed
	}
	s.absent = false
	copy(s.committed[:s.pending_len], s.pending[:s.pending_len])
	s.committed_len = s.pending_len
	s.has_pending = false
	return .Ok
}

@(private = "file")
fake_drop_pending :: proc "contextless" (user: rawptr, name: string, error: ^errors.Error_Record) -> storage_status.Status {
	s := (^Fake_Store)(user)
	s.drop_calls += 1
	s.last_drop_name_len = copy(s.last_drop_name_buf[:], name)
	if s.drop_fail_once {
		s.drop_fail_once = false
		if error != nil {
			error^ = errors.error_make(.Busy, .Pending)
		}
		return .Failed
	}
	if s.drop_status != .Ok {
		if error != nil {
			error^ = s.drop_error
		}
		return s.drop_status
	}
	s.has_pending = false
	s.pending_len = s.committed_len
	copy(s.pending[:s.committed_len], s.committed[:s.committed_len])
	return .Ok
}

@(private = "file")
FAKE_OPS :: Large_Ops {
	size         = fake_size,
	read_range   = fake_read_range,
	write        = fake_write,
	write_range  = fake_write_range,
	set_size     = fake_set_size,
	commit       = fake_commit,
	drop_pending = fake_drop_pending,
}

// read_large refuses nil port/user, absent objects, negative sizes, buffers
// one byte short, zero-length chunks, read errors, and overshoot chunks;
// then succeeds for 0 bytes, exact-fit buffers, and multi-chunk reads.
@(test)
read_large_refuses_edges_and_reads_chunks :: proc(t: ^testing.T) {
	buf: [64]u8
	// Nil port and nil user.
	count, status := read_large(nil, "a", buf[:])
	testing.expect(t, count == 0 && status == .Failed)
	empty_port := pr.Private_Store_Port{}
	count, status = read_large(&empty_port, "a", buf[:])
	testing.expect(t, count == 0 && status == .Failed)
	count, status = read_large_with(nil, FAKE_OPS, "a", buf[:])
	testing.expect(t, count == 0 && status == .Failed)

	data := make([]u8, WRITE_PIECE_BYTES + 17)
	defer delete(data)
	for i in 0 ..< len(data) {
		data[i] = u8((i * 31 + 7) & 0xFF)
	}
	backing := make([]u8, len(data))
	defer delete(backing)
	copy(backing, data)

	// Absent object.
	st := Fake_Store{name = "blob", committed = backing, committed_len = len(backing), absent = true, size_status = .Ok}
	out := make([]u8, len(data))
	defer delete(out)
	count, status = read_large_with(&st, FAKE_OPS, "blob", out)
	testing.expect(t, count == 0 && status == .Absent)

	// Size error and negative size.
	st.absent = false
	st.size_status = .Failed
	count, status = read_large_with(&st, FAKE_OPS, "blob", out)
	testing.expect(t, count == 0 && status == .Failed)
	st.size_status = .Ok
	st.use_size_override = true
	st.size_override = -1
	count, status = read_large_with(&st, FAKE_OPS, "blob", out)
	testing.expect(t, count == 0 && status == .Failed)
	st.use_size_override = false

	// One byte short -> Too_Large.
	count, status = read_large_with(&st, FAKE_OPS, "blob", out[:len(data) - 1])
	testing.expect(t, count == 0 && status == .Too_Large)

	// Read error on second chunk.
	st.read_chunk_limit = 8192
	st.read_fail_at_call = 2
	count, status = read_large_with(&st, FAKE_OPS, "blob", out)
	testing.expect(t, count == 0 && status == .Failed)
	st.read_fail_at_call = 0

	// Zero-length chunk refuses instead of looping forever.
	st.read_range_calls = 0
	st.read_zero_at_call = 2
	count, status = read_large_with(&st, FAKE_OPS, "blob", out)
	testing.expect(t, count == 0 && status == .Failed)
	st.read_zero_at_call = 0

	// Chunk larger than remaining bytes is refused.
	st.read_range_calls = 0
	st.read_overshoot_call = 2
	count, status = read_large_with(&st, FAKE_OPS, "blob", out)
	testing.expect(t, count == 0 && status == .Failed)
	st.read_overshoot_call = 0

	// Zero-byte object succeeds with zero read_range calls.
	st.committed_len = 0
	st.read_range_calls = 0
	count, status = read_large_with(&st, FAKE_OPS, "blob", out[:0])
	testing.expect(t, count == 0 && status == .Ok && st.read_range_calls == 0)

	// Multi-chunk exact-fit read succeeds and preserves every byte.
	st.committed_len = len(data)
	st.read_range_calls = 0
	count, status = read_large_with(&st, FAKE_OPS, "blob", out)
	testing.expect_value(t, status, pr.Private_Store_Status.Ok)
	testing.expect_value(t, count, len(data))
	testing.expect(t, st.read_range_calls == 5)
	for i in 0 ..< len(data) {
		if out[i] != data[i] {
			testing.expectf(t, false, "byte %d differed: got %d want %d", i, out[i], data[i])
			return
		}
	}
}

// write_large uses single write up to WRITE_PIECE_BYTES, switches to
// write_range + stepped commits + set_size + commit past WRITE_PIECE_BYTES,
// drops pending changes on every failure path, and retries a kept 255-byte
// name before the next write.
@(test)
write_large_bounds_steps_and_abandon :: proc(t: ^testing.T) {
	// Nil port/user/pending.
	testing.expect_value(t, write_large(nil, "a", nil), pr.Private_Store_Status.Failed)
	empty_port := pr.Private_Store_Port{}
	testing.expect_value(t, write_large(&empty_port, "a", nil), pr.Private_Store_Status.Failed)
	testing.expect_value(t, write_large_with(nil, FAKE_OPS, nil, "a", nil), pr.Private_Store_Status.Failed)

	total_size := COMMIT_STEP_BYTES + WRITE_PIECE_BYTES + 13
	payload := make([]u8, total_size)
	defer delete(payload)
	for i in 0 ..< len(payload) {
		payload[i] = u8((i * 17 + 3) & 0xFF)
	}
	committed := make([]u8, total_size)
	defer delete(committed)
	pending_buf := make([]u8, total_size)
	defer delete(pending_buf)

	st := Fake_Store{committed = committed, pending = pending_buf}
	pending: Pending_State

	// Single-write failure: negative generation or non-Ok status.
	st.write_status = .Failed
	testing.expect_value(t, write_large_with(&st, FAKE_OPS, &pending, "small", payload[:0]), pr.Private_Store_Status.Failed)
	st.write_status = .Ok
	st.write_generation = -1
	testing.expect_value(t, write_large_with(&st, FAKE_OPS, &pending, "small", payload[:1]), pr.Private_Store_Status.Failed)
	st.write_generation = 1

	// Zero bytes and exact WRITE_PIECE_BYTES use single write, zero write_range.
	st.write_calls, st.write_range_calls = 0, 0
	testing.expect_value(t, write_large_with(&st, FAKE_OPS, &pending, "zero", payload[:0]), pr.Private_Store_Status.Ok)
	testing.expect_value(t, write_large_with(&st, FAKE_OPS, &pending, "exact", payload[:WRITE_PIECE_BYTES]), pr.Private_Store_Status.Ok)
	testing.expect(t, st.write_calls == 2 && st.write_range_calls == 0 && st.committed_len == WRITE_PIECE_BYTES)

	// One byte past WRITE_PIECE_BYTES uses write_range + set_size + commit.
	st.write_calls, st.write_range_calls, st.commit_calls, st.set_size_calls = 0, 0, 0, 0
	testing.expect_value(t, write_large_with(&st, FAKE_OPS, &pending, "plus1", payload[:WRITE_PIECE_BYTES + 1]), pr.Private_Store_Status.Ok)
	testing.expect(t, st.write_calls == 0 && st.write_range_calls == 2 && st.set_size_calls == 1 && st.commit_calls == 1)
	testing.expect_value(t, st.committed_len, WRITE_PIECE_BYTES + 1)

	// Past COMMIT_STEP_BYTES: one stepped commit at COMMIT_STEP_BYTES plus final commit.
	st.write_range_calls, st.commit_calls, st.set_size_calls = 0, 0, 0
	testing.expect_value(t, write_large_with(&st, FAKE_OPS, &pending, "large", payload), pr.Private_Store_Status.Ok)
	testing.expect_value(t, st.write_range_calls, COMMIT_STEP_BYTES / WRITE_PIECE_BYTES + 2)
	testing.expect_value(t, st.set_size_calls, 1)
	testing.expect_value(t, st.commit_calls, 2)
	testing.expect_value(t, st.committed_len, len(payload))
	for i in 0 ..< len(payload) {
		if st.committed[i] != payload[i] {
			testing.expectf(t, false, "large byte %d differed", i)
			return
		}
	}

	// Failure in write_range drops pending; Absent/Pending error still clears pending.
	st.write_range_calls, st.drop_calls = 0, 0
	st.write_range_fail_at = 2
	st.drop_status = .Failed
	st.drop_error = errors.error_make(.Absent, .Pending)
	testing.expect_value(t, write_large_with(&st, FAKE_OPS, &pending, "fail_range", payload[:WRITE_PIECE_BYTES + 1]), pr.Private_Store_Status.Failed)
	testing.expect(t, st.drop_calls == 1 && !pending.kept)
	st.write_range_fail_at = 0
	st.drop_status = .Ok

	// Failure in intermediate commit drops pending.
	st.write_range_calls, st.commit_calls, st.drop_calls = 0, 0, 0
	st.commit_fail_at = 1
	testing.expect_value(t, write_large_with(&st, FAKE_OPS, &pending, "fail_mid_commit", payload), pr.Private_Store_Status.Failed)
	testing.expect(t, st.drop_calls == 1 && !st.has_pending && !pending.kept)

	// Failure in set_size drops pending.
	st.commit_fail_at = 0
	st.set_size_status = .Failed
	st.drop_calls = 0
	testing.expect_value(t, write_large_with(&st, FAKE_OPS, &pending, "fail_size", payload[:WRITE_PIECE_BYTES + 1]), pr.Private_Store_Status.Failed)
	testing.expect(t, st.drop_calls == 1 && !st.has_pending && !pending.kept)
	st.set_size_status = .Ok

	// Failure in final commit with a 255-byte name whose drop fails keeps
	// the full 255-byte name, blocks the next write while drop fails, then
	// drops the full name before the next write runs.
	long_name_buf: [store.ENTRY_NAME_CAPACITY]u8
	for i in 0 ..< len(long_name_buf) {
		long_name_buf[i] = u8('a' + (i % 26))
	}
	long_name := string(long_name_buf[:])
	st.commit_calls, st.drop_calls = 0, 0
	st.commit_fail_at = 1
	st.drop_fail_once = true
	testing.expect_value(t, write_large_with(&st, FAKE_OPS, &pending, long_name, payload[:WRITE_PIECE_BYTES + 1]), pr.Private_Store_Status.Failed)
	testing.expect(t, pending.kept && pending.length == store.ENTRY_NAME_CAPACITY)
	testing.expect_value(t, string(pending.name[:pending.length]), long_name)

	// Next write fails immediately without calling write if drop fails again.
	st.commit_fail_at = 0
	st.write_calls = 0
	st.drop_fail_once = true
	testing.expect_value(t, write_large_with(&st, FAKE_OPS, &pending, "next", payload[:16]), pr.Private_Store_Status.Failed)
	testing.expect(t, pending.kept && st.write_calls == 0)

	// Once drop succeeds, it receives the full 255-byte name and the new write succeeds.
	testing.expect_value(t, write_large_with(&st, FAKE_OPS, &pending, "next", payload[:16]), pr.Private_Store_Status.Ok)
	testing.expect(t, !pending.kept && st.write_calls == 1)
	testing.expect_value(t, string(st.last_drop_name_buf[:st.last_drop_name_len]), long_name)
}
