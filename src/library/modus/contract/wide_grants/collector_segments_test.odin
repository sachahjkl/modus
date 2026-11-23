#+build !freestanding
package wide_grants

import "core:fmt"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import pr "modus:contract/plans_recipes"

@(private = "file")
PRINCIPAL :: u64(6)

// A private store in memory whose reads can fail, as a storage service that
// does not answer.
@(private = "file")
Failing_Store :: struct {
	memory:     pr.Memory_Private_Store,
	reads_fail: bool,
}

@(private = "file")
failing_store_read :: proc "contextless" (user: rawptr, name: string, into: []u8) -> (count: int, status: pr.Private_Store_Status) {
	failing := (^Failing_Store)(user)
	if failing.reads_fail {
		return 0, .Failed
	}
	writes_allowed := failing.memory.writes_allowed
	memory_port := pr.memory_private_store_port(&failing.memory)
	failing.memory.writes_allowed = writes_allowed
	return memory_port.read(memory_port.user, name, into)
}

@(private = "file")
failing_store_write :: proc "contextless" (user: rawptr, name: string, data: []u8) -> pr.Private_Store_Status {
	failing := (^Failing_Store)(user)
	writes_allowed := failing.memory.writes_allowed
	memory_port := pr.memory_private_store_port(&failing.memory)
	failing.memory.writes_allowed = writes_allowed
	return memory_port.write(memory_port.user, name, data)
}

@(private = "file")
failing_store_remove :: proc "contextless" (user: rawptr, name: string) -> pr.Private_Store_Status {
	failing := (^Failing_Store)(user)
	writes_allowed := failing.memory.writes_allowed
	memory_port := pr.memory_private_store_port(&failing.memory)
	failing.memory.writes_allowed = writes_allowed
	return memory_port.remove(memory_port.user, name)
}

@(private = "file")
failing_store_port :: proc(failing: ^Failing_Store) -> pr.Private_Store_Port {
	failing.memory.writes_allowed = -1
	return {user = failing, read = failing_store_read, write = failing_store_write, remove = failing_store_remove}
}

@(private = "file")
terms_audit :: proc(bound: i64, forwarding := Space_Forwarding.Keeps, record_size: i64 = 8) -> Space_Terms {
	return {kind_word = i64(Collector_Space_Kind.Audit), bound_records = bound, forwarding_word = i64(forwarding), record_size = record_size}
}

@(private = "file")
name_bytes :: proc(value: string) -> []u8 {
	return transmute([]u8)value
}

// record_bytes gives the record of a serial: each byte differs from one
// serial to the next, so a record in the wrong place shows.
@(private = "file")
record_bytes :: proc(serial: u64) -> (record: [8]u8) {
	for &value, index in record {
		value = u8(serial * 8 + u64(index) + 1)
	}
	return record
}

@(private = "file")
reader_of :: proc(principal: u64, name: string) -> (reader: Space_Reader) {
	reader.principal = principal
	reader.acts_for_principal = true
	copy(reader.name[:], name)
	return reader
}

// The memory of the private store and a store of spaces over it. A restart
// is a new store of spaces over the same memory.
@(private = "file")
Fixture :: struct {
	failing: Failing_Store,
	store:   Space_Store,
}

@(private = "file")
restart :: proc(fixture: ^Fixture, principal := PRINCIPAL, identifier := TEST_COLLECTOR_IDENTIFIER) {
	space_store_init(&fixture.store, principal, identifier, failing_store_port(&fixture.failing), space_window_heap_port())
}

@(private = "file")
append_records :: proc(t: ^testing.T, store: ^Space_Store, space_number: u32, first, count: u64, location := #caller_location) {
	for serial in first ..< first + count {
		record := record_bytes(serial)
		kept, refusal := record_append(store, space_number, record[:], 1000 + serial)
		testing.expect_value(t, refusal, Space_Refusal.None, location)
		testing.expect_value(t, kept, serial, location)
		// A Paired reader takes each forwarded record at once.
		for store.forward_count > 0 {
			forward_done(store)
		}
	}
}

// The segments of a space of SPACE_RECORDS_MOST records, which the tests
// open.
@(private = "file")
TEST_SEGMENTS :: SPACE_RECORDS_MOST / SPACE_SEGMENT_RECORDS

@(private = "file")
object_of :: proc(fixture: ^Fixture, space_number: u32, segment: u32) -> ^pr.Memory_Private_Object {
	name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
	return pr.memory_private_store_find(&fixture.failing.memory, segment_object_name(&name_place, space_number, u64(segment)))
}

// expect_space_whole checks that space_number holds the serials 0 ..< count
// with their bytes and times, and a chain that space_verify accepts.
@(private = "file")
expect_space_whole :: proc(t: ^testing.T, store: ^Space_Store, space_number: u32, count: u64, location := #caller_location) {
	testing.expect_value(t, space_store_ready(store), Space_Refusal.None, location)
	space := space_of(store, space_number)
	if !testing.expect(t, space != nil, "the space is missing", loc = location) {
		return
	}
	testing.expect_value(t, u64(space.count), count, location)
	testing.expect_value(t, space.next_serial, count, location)
	reader := reader_of(PRINCIPAL, "console")
	heads: [SPACE_RECORDS_MOST]Kept_Record_Head
	bytes: [SPACE_RECORDS_MOST * 8]u8
	read, refusal := records_read(store, space_number, -1, SPACE_RECORDS_MOST, &reader, heads[:], bytes[:])
	testing.expect_value(t, refusal, Space_Refusal.None, location)
	testing.expect_value(t, u64(read), count, location)
	link: blake3.Hash
	for index in 0 ..< int(count) {
		serial := u64(index)
		expected := record_bytes(serial)
		testing.expect_value(t, heads[index].serial, i64(serial), location)
		testing.expect_value(t, heads[index].time_ms, i64(1000 + serial), location)
		testing.expect(t, string(bytes[index * 8:][:8]) == string(expected[:]), "a record changed", loc = location)
		link = space_record_hash(link, serial, 1000 + serial, expected[:])
		testing.expect(t, blake3.Hash(heads[index].chain_hash) == link, "a link changed", loc = location)
	}
	testing.expect(t, space.last_hash == link, "the last link changed", loc = location)
	verified, failing_serial := space_verify(store, space_number)
	testing.expect_value(t, verified, Space_Refusal.None, location)
	testing.expect_value(t, failing_serial, u64(0), location)
}

// A reader of a whole audit reads it whole: after 4000 records, the first
// record comes from the private store with its link, and so does a run in
// the middle, then the ring. A restart reads the index, the map of each
// space and the last segments only, not each slot, and reads the first
// record again. A map that names a segment past a gap refuses the start.
@(test)
the_first_record_reads_back_after_four_thousand :: proc(t: ^testing.T) {
	fixture := new(Fixture)
	defer free(fixture)
	restart(fixture)
	space_number, opened := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(SPACE_AUDIT_BOUND_MOST))
	testing.expect_value(t, opened, Space_Refusal.None)
	append_records(t, &fixture.store, space_number, 0, 4000)
	links := make([]blake3.Hash, 4000, context.temp_allocator)
	link: blake3.Hash
	for serial in u64(0) ..< 4000 {
		record := record_bytes(serial)
		link = space_record_hash(link, serial, 1000 + serial, record[:])
		links[serial] = link
	}
	reader := reader_of(PRINCIPAL, "console")
	heads: [SPACE_RECORDS_MOST]Kept_Record_Head
	bytes: [SPACE_RECORDS_MOST * 8]u8
	check :: proc(t: ^testing.T, store: ^Space_Store, space_number: u32, reader: ^Space_Reader, after: i64, limit: int, links: []blake3.Hash, heads: []Kept_Record_Head, bytes: []u8) {
		count, refusal := records_read(store, space_number, after, limit, reader, heads, bytes)
		testing.expect_value(t, refusal, Space_Refusal.None)
		testing.expect_value(t, count, limit)
		for index in 0 ..< count {
			serial := u64(after + 1) + u64(index)
			expected := record_bytes(serial)
			testing.expect_value(t, heads[index].serial, i64(serial))
			testing.expect_value(t, heads[index].time_ms, i64(1000 + serial))
			testing.expect(t, string(bytes[index * 8:][:8]) == string(expected[:]), "a record changed")
			testing.expect(t, blake3.Hash(heads[index].chain_hash) == links[serial], "a link changed")
		}
	}
	check(t, &fixture.store, space_number, &reader, -1, 1, links, heads[:], bytes[:])
	check(t, &fixture.store, space_number, &reader, 1000, SPACE_RECORDS_MOST, links, heads[:], bytes[:])
	// A run across the place where the ring starts: the store, then the ring.
	check(t, &fixture.store, space_number, &reader, 3900, SPACE_RECORDS_MOST, links, heads[:], bytes[:])

	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
	// The index, the map of each space, the slot after the last segment, the
	// segment before the ring, the segments of the ring, and the map of the
	// place after the last one.
	testing.expectf(t, fixture.store.load_reads <= 1 + 2 * len(fixture.store.spaces) + LOAD_SEGMENTS_MOST + 1 + 1, "a start read %d objects", fixture.store.load_reads)
	fmt.printfln("modustool: a measure: a start of a space of 4000 records read %d objects", fixture.store.load_reads)
	check(t, &fixture.store, space_number, &reader, -1, 1, links, heads[:], bytes[:])
	verified, _ := space_verify(&fixture.store, space_number)
	testing.expect_value(t, verified, Space_Refusal.None)

	// A map that names a segment past a gap.
	fixture.store.spaces[space_number - 1].ring.slot_map[100] = 0
	map_name: [SEGMENT_OBJECT_NAME_BYTES]u8
	before := pr.memory_private_store_find(&fixture.failing.memory, slot_map_object_name(&map_name, space_number))^
	testing.expect_value(t, slot_map_persist(&fixture.store, space_number), Space_Refusal.None)
	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.Store_Damaged)
	pr.memory_private_store_find(&fixture.failing.memory, slot_map_object_name(&map_name, space_number))^ = before
}

// A slot map that is lost, or older than the segments, would read as a
// space with fewer records: the start reads the slot of the next segment,
// and a whole segment there refuses the start. A map that names a segment
// that its slot does not hold yet is a stop between the two writes: the
// start takes it.
@(test)
a_lost_or_older_slot_map_refuses_the_start :: proc(t: ^testing.T) {
	fixture := new(Fixture)
	defer free(fixture)
	restart(fixture)
	space_number, _ := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(SPACE_AUDIT_BOUND_MOST))
	append_records(t, &fixture.store, space_number, 0, SPACE_SEGMENT_RECORDS + 3)
	map_name: [SEGMENT_OBJECT_NAME_BYTES]u8
	map_object := pr.memory_private_store_find(&fixture.failing.memory, slot_map_object_name(&map_name, space_number))
	older := map_object^
	append_records(t, &fixture.store, space_number, SPACE_SEGMENT_RECORDS + 3, SPACE_SEGMENT_RECORDS)
	newer := map_object^

	// The map removed: the slot of the first kept segment holds it.
	map_object.used = false
	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.Store_Damaged)
	map_object^ = newer

	// An older map, which names two segments of three: the slot after them
	// holds the third.
	map_object^ = older
	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.Store_Damaged)
	map_object^ = newer

	// The newer map: the start reads each record.
	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
	testing.expect_value(t, fixture.store.spaces[space_number - 1].next_serial, u64(2 * SPACE_SEGMENT_RECORDS + 3))

	// A stop between the write of the map and of the segment: the third
	// segment is full, and the map names a fourth one that no slot holds
	// yet; the start takes it, with the records of three segments.
	append_records(t, &fixture.store, space_number, 2 * SPACE_SEGMENT_RECORDS + 3, SPACE_SEGMENT_RECORDS - 3)
	fixture.store.spaces[space_number - 1].ring.slot_map[3] = 4
	testing.expect_value(t, slot_map_persist(&fixture.store, space_number), Space_Refusal.None)
	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
	testing.expect_value(t, fixture.store.spaces[space_number - 1].next_serial, u64(3 * SPACE_SEGMENT_RECORDS))
}

// A closed audit space is dated by the first pass that knows a date, kept
// to the end of its retention, then removed: its segments and its map go,
// its row says Removed, and a reader gets Space_Removed, also after a
// restart, until a new space takes its place. A date that goes back, and a
// date one millisecond before the end, remove nothing. A removal that the
// store stops says Removing to a reader, and the next pass ends it, also
// after a restart.
@(test)
a_closed_audit_space_ends_after_its_retention :: proc(t: ^testing.T) {
	RETENTION :: i64(10_000)
	CLOSED_AT :: i64(1_000_000)
	for stopped in ([?]bool{false, true}) {
		fixture := new(Fixture)
		defer free(fixture)
		restart(fixture)
		old, _ := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(64))
		append_records(t, &fixture.store, old, 0, 2 * SPACE_SEGMENT_RECORDS + 3)
		resized, resize_refusal := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(64, .Keeps, 16))
		testing.expect_value(t, resize_refusal, Space_Refusal.None)
		reader := reader_of(PRINCIPAL, "console")
		heads: [SPACE_RECORDS_MOST]Kept_Record_Head
		bytes: [SPACE_RECORDS_MOST * 8]u8

		// No date known: nothing is dated, nothing removed.
		removed, refusal := space_closed_pass(&fixture.store, 0, false, RETENTION)
		testing.expect_value(t, refusal, Space_Refusal.None)
		testing.expect_value(t, removed, 0)
		testing.expect_value(t, fixture.store.spaces[old - 1].closed_at_ms, i64(0))
		_, _, _, undated := space_closed_next_due(&fixture.store, RETENTION)
		testing.expect(t, undated, "a closed space with no date is due for a date")
		// The first date dates it, and the date stays across a restart.
		removed, refusal = space_closed_pass(&fixture.store, CLOSED_AT, true, RETENTION)
		testing.expect_value(t, removed, 0)
		restart(fixture)
		testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
		testing.expect_value(t, fixture.store.spaces[old - 1].closed_at_ms, CLOSED_AT)
		due, dated_due, at_once, _ := space_closed_next_due(&fixture.store, RETENTION)
		testing.expect(t, dated_due && !at_once && due == CLOSED_AT + RETENTION, "the end of the retention is due")
		// A date that goes back, and one millisecond before the end: kept.
		for date in ([?]i64{CLOSED_AT - 1, 1, CLOSED_AT + RETENTION - 1}) {
			removed, _ = space_closed_pass(&fixture.store, date, true, RETENTION)
			testing.expect_value(t, removed, 0)
			count, read := records_read(&fixture.store, old, -1, 1, &reader, heads[:], bytes[:])
			testing.expect(t, read == .None && count == 1, "a kept closed space reads")
		}
		map_name: [SEGMENT_OBJECT_NAME_BYTES]u8
		if stopped {
			// The store takes the write of Removing and the remove of one
			// segment, then refuses.
			fixture.failing.memory.writes_allowed = fixture.failing.memory.writes + 2
			removed, refusal = space_closed_pass(&fixture.store, CLOSED_AT + RETENTION, true, RETENTION)
			testing.expect_value(t, refusal, Space_Refusal.Store_Failed)
			testing.expect_value(t, removed, 0)
			_, read := records_read(&fixture.store, old, -1, 1, &reader, heads[:], bytes[:])
			testing.expect_value(t, read, Space_Refusal.Space_Removed)
			_, _, at_once, _ = space_closed_next_due(&fixture.store, RETENTION)
			testing.expect(t, at_once, "a stopped removal is due at once")
			fixture.failing.memory.writes_allowed = -1
			restart(fixture)
			testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
			_, read = records_read(&fixture.store, old, -1, 1, &reader, heads[:], bytes[:])
			testing.expect_value(t, read, Space_Refusal.Space_Removed)
		}
		// At the end of the retention: removed.
		removed, refusal = space_closed_pass(&fixture.store, CLOSED_AT + RETENTION, true, RETENTION)
		testing.expect_value(t, refusal, Space_Refusal.None)
		testing.expect_value(t, removed, 1)
		for segment in u64(0) ..< 3 {
			testing.expect(t, object_of(fixture, old, u32(segment)) == nil, "a segment of the removed space stays")
		}
		testing.expect(t, pr.memory_private_store_find(&fixture.failing.memory, slot_map_object_name(&map_name, old)) == nil, "the map of the removed space stays")
		check_removed :: proc(t: ^testing.T, store: ^Space_Store, old: u32, reader: ^Space_Reader) {
			heads: [SPACE_RECORDS_MOST]Kept_Record_Head
			bytes: [SPACE_RECORDS_MOST * 8]u8
			_, read := records_read(store, old, -1, 1, reader, heads[:], bytes[:])
			testing.expect_value(t, read, Space_Refusal.Space_Removed)
			_, stats := space_stats(store, old, reader)
			testing.expect_value(t, stats, Space_Refusal.Space_Removed)
			verified, _ := space_verify(store, old)
			testing.expect_value(t, verified, Space_Refusal.Space_Removed)
			record := record_bytes(1)
			_, appended := record_append(store, old, record[:], 1)
			testing.expect_value(t, appended, Space_Refusal.Space_Removed)
		}
		check_removed(t, &fixture.store, old, &reader)
		restart(fixture)
		testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
		check_removed(t, &fixture.store, old, &reader)
		// The new space of the pair kept its records; a later pass removes
		// nothing more.
		count, read := records_read(&fixture.store, resized, -1, 1, &reader, heads[:], bytes[:])
		testing.expect(t, read == .None && count == 0, "the new space reads")
		removed, _ = space_closed_pass(&fixture.store, CLOSED_AT + 10 * RETENTION, true, RETENTION)
		testing.expect_value(t, removed, 0)
		// A new space takes the free place, and starts with no record.
		taken, taken_refusal := space_open(&fixture.store, name_bytes("other"), name_bytes("orders"), terms_audit(64))
		testing.expect_value(t, taken_refusal, Space_Refusal.None)
		testing.expect_value(t, taken, old)
		count, read = records_read(&fixture.store, taken, -1, 1, &reader, heads[:], bytes[:])
		testing.expect(t, read == .None && count == 0, "the new space of the place has no record")
		restart(fixture)
		testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
	}
}

// A closed space whose segments rotated out is removed whole: no slot of its
// place keeps a segment, the rotated ones too, so a new space in the place
// takes its slots from 0 and the store starts again; the slots that a
// rotation left and a removal missed would refuse that start.
@(test)
a_removed_rotated_space_leaves_no_slot :: proc(t: ^testing.T) {
	fixture := new(Fixture)
	defer free(fixture)
	restart(fixture)
	old, _ := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(SPACE_AUDIT_BOUND_MOST))
	append_records(t, &fixture.store, old, 0, 6 * SPACE_SEGMENT_RECORDS + 3)
	// The first four segments rotate out: their slots keep their objects.
	testing.expect_value(t, space_rotate_before(&fixture.store, old, 4 * SPACE_SEGMENT_RECORDS), Space_Refusal.None)
	testing.expect(t, object_of(fixture, old, 0) != nil, "a rotation removed a segment")
	_, _ = space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(SPACE_AUDIT_BOUND_MOST, .Keeps, 16))
	removed, refusal := space_closed_pass(&fixture.store, 1000, true, 0)
	testing.expect_value(t, refusal, Space_Refusal.None)
	removed, refusal = space_closed_pass(&fixture.store, 1000, true, 0)
	testing.expect_value(t, refusal, Space_Refusal.None)
	testing.expect_value(t, removed, 1)
	for slot in u32(0) ..< SPACE_SEGMENT_SLOTS {
		testing.expectf(t, object_of(fixture, old, slot) == nil, "the slot %d of the removed place keeps a segment", slot)
	}
	// A new space in the place, then a restart.
	taken, taken_refusal := space_open(&fixture.store, name_bytes("other"), name_bytes("orders"), terms_audit(SPACE_AUDIT_BOUND_MOST))
	testing.expect_value(t, taken_refusal, Space_Refusal.None)
	testing.expect_value(t, taken, old)
	append_records(t, &fixture.store, taken, 0, 2 * SPACE_SEGMENT_RECORDS + 1)
	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
	testing.expect_value(t, fixture.store.spaces[taken - 1].next_serial, u64(2 * SPACE_SEGMENT_RECORDS + 1))
	verified, _ := space_verify(&fixture.store, taken)
	testing.expect_value(t, verified, Space_Refusal.None)
}

// A retention of 0, or below it, ends at the first dated pass at or after
// the close, never before it.
@(test)
a_retention_of_zero_ends_at_the_close :: proc(t: ^testing.T) {
	for retention in ([?]i64{0, -1, min(i64)}) {
		fixture := new(Fixture)
		defer free(fixture)
		restart(fixture)
		old, _ := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(64))
		append_records(t, &fixture.store, old, 0, 1)
		_, _ = space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(64, .Keeps, 16))
		removed, _ := space_closed_pass(&fixture.store, 500, true, retention)
		testing.expect_value(t, removed, 0)
		removed, _ = space_closed_pass(&fixture.store, 499, true, retention)
		testing.expect_value(t, removed, 0)
		removed, _ = space_closed_pass(&fixture.store, 500, true, retention)
		testing.expect_value(t, removed, 1)
	}
}

// The state of a row of the index is a border: a word that names no state,
// an open row with the next serial or the last link of a closed one, and a
// closed row past its bound each refuse the start, even with a hash that
// matches.
@(test)
a_row_of_the_index_with_a_bad_state_refuses_the_start :: proc(t: ^testing.T) {
	fixture := new(Fixture)
	defer free(fixture)
	restart(fixture)
	space_number, _ := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(64))
	append_records(t, &fixture.store, space_number, 0, 3)
	index := pr.memory_private_store_find(&fixture.failing.memory, SPACE_INDEX_OBJECT_NAME)
	saved := index^
	rewrite :: proc(index: ^pr.Memory_Private_Object, at: int, word: u64) {
		row := index.bytes[SPACE_INDEX_HEAD_BYTES:][:SPACE_INDEX_ROW_BYTES]
		byte_order.write_u64_little_endian(row, at, word)
		hash_at := index.length - blake3.HASH_SIZE
		index_hash := blake3.derive_key(SPACE_INDEX_HASH_DOMAIN, index.bytes[:hash_at])
		copy(index.bytes[hash_at:][:blake3.HASH_SIZE], index_hash[:])
	}
	cases := [?]struct {
		at:   int,
		word: u64,
	} {
		{SPACE_INDEX_ROW_STATE_AT, 0},
		{SPACE_INDEX_ROW_STATE_AT, 5},
		{SPACE_INDEX_ROW_STATE_AT, max(u64)},
		{SPACE_INDEX_ROW_NEXT_SERIAL_AT, 1},
		{SPACE_INDEX_ROW_LAST_LINK_AT, 1},
	}
	for item in cases {
		index^ = saved
		rewrite(index, item.at, item.word)
		restart(fixture)
		testing.expectf(t, space_store_ready(&fixture.store) == .Store_Damaged, "the word %d at %d is taken", item.word, item.at)
	}
	// A closed row whose next serial passes its bound.
	index^ = saved
	rewrite(index, SPACE_INDEX_ROW_STATE_AT, u64(Space_Index_State.Closed))
	rewrite(index, SPACE_INDEX_ROW_NEXT_SERIAL_AT, 65)
	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.Store_Damaged)
	// At the bound: taken, closed.
	rewrite(index, SPACE_INDEX_ROW_NEXT_SERIAL_AT, 64)
	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
	testing.expect(t, fixture.store.spaces[space_number - 1].closed, "the row says closed")
	index^ = saved
}

// Old segments rewritten whole from another chain: each segment has its own
// hash and a last link that matches its records, so a read of them alone
// finds nothing; the read that crosses into the ring compares the last
// link with the link where the ring starts, and refuses.
@(test)
a_changed_old_segment_read_across_the_join_is_refused :: proc(t: ^testing.T) {
	fixture := new(Fixture)
	defer free(fixture)
	other := new(Fixture)
	defer free(other)
	restart(fixture)
	restart(other)
	space_number, _ := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(SPACE_AUDIT_BOUND_MOST))
	other_number, _ := space_open(&other.store, name_bytes("server"), name_bytes("orders"), terms_audit(SPACE_AUDIT_BOUND_MOST))
	testing.expect_value(t, other_number, space_number)
	append_records(t, &fixture.store, space_number, 0, 4000)
	// The other chain differs at its first record only.
	changed := [8]u8{0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE}
	_, refusal := record_append(&other.store, other_number, changed[:], 1000)
	testing.expect_value(t, refusal, Space_Refusal.None)
	append_records(t, &other.store, other_number, 1, 3999)
	ring_first := space_ring_first(&fixture.store.spaces[space_number - 1])
	testing.expect_value(t, ring_first, u64(4000 - SPACE_RECORDS_MOST))
	reader := reader_of(PRINCIPAL, "console")
	heads: [SPACE_RECORDS_MOST]Kept_Record_Head
	bytes: [SPACE_RECORDS_MOST * 8]u8
	// Before the change, a read across the join gives its records.
	count, read_refusal := records_read(&fixture.store, space_number, i64(ring_first) - 3, 4, &reader, heads[:], bytes[:])
	testing.expect_value(t, read_refusal, Space_Refusal.None)
	testing.expect_value(t, count, 4)
	name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
	for segment in u64(0) ..< ring_first / SPACE_SEGMENT_RECORDS {
		name := segment_object_name(&name_place, space_number, segment)
		pr.memory_private_store_find(&fixture.failing.memory, name)^ = pr.memory_private_store_find(&other.failing.memory, name)^
	}
	// A read that ends in a segment before the one of the join reads the
	// rewritten chain: nothing in it alone is wrong. A read checks each
	// segment that it opens to its end, so a read in the segment of the
	// join reaches the join.
	_, read_refusal = records_read(&fixture.store, space_number, i64(ring_first) - 40, 4, &reader, heads[:], bytes[:])
	testing.expect_value(t, read_refusal, Space_Refusal.None)
	// Across the join, and up to it: refused.
	_, read_refusal = records_read(&fixture.store, space_number, i64(ring_first) - 3, 4, &reader, heads[:], bytes[:])
	testing.expect_value(t, read_refusal, Space_Refusal.Chain_Broken)
	_, read_refusal = records_read(&fixture.store, space_number, i64(ring_first) - 2, 1, &reader, heads[:], bytes[:])
	testing.expect_value(t, read_refusal, Space_Refusal.Chain_Broken)
}

@(test)
segment_object_names_are_exact :: proc(t: ^testing.T) {
	place: [SEGMENT_OBJECT_NAME_BYTES]u8
	testing.expect_value(t, segment_object_name(&place, 1, 0), "collector_space_1_segment_0")
	testing.expect_value(t, segment_object_name(&place, 32, TEST_SEGMENTS), "collector_space_32_segment_4")
	testing.expect_value(t, segment_object_name(&place, 10, 0), "collector_space_10_segment_0")
	// A segment takes the name of its slot.
	testing.expect_value(t, segment_object_name(&place, max(u32), SPACE_SEGMENT_SLOTS - 1), "collector_space_4294967295_segment_255")
	testing.expect_value(t, segment_object_name(&place, 1, SPACE_SEGMENT_SLOTS), "collector_space_1_segment_0")
	testing.expect_value(t, segment_object_name(&place, 1, max(u64)), "collector_space_1_segment_255")
}

// At 0, 1, a whole segment, one past it and the bound of the space, a
// restart finds each record, its serial, its time and its link, the next
// record takes the next serial, and a closed segment is never written
// again. Each record costs one write.
@(test)
records_survive_a_restart_at_each_segment_boundary :: proc(t: ^testing.T) {
	counts := [?]u64{0, 1, SPACE_SEGMENT_RECORDS - 1, SPACE_SEGMENT_RECORDS, SPACE_SEGMENT_RECORDS + 1, 2 * SPACE_SEGMENT_RECORDS, SPACE_RECORDS_MOST - 1, SPACE_RECORDS_MOST}
	for count in counts {
		fixture := new(Fixture)
		defer free(fixture)
		restart(fixture)
		space_number, opened := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(SPACE_RECORDS_MOST))
		testing.expect_value(t, opened, Space_Refusal.None)
		writes_before := fixture.failing.memory.writes
		append_records(t, &fixture.store, space_number, 0, count)
		segments := u32((count + SPACE_SEGMENT_RECORDS - 1) / SPACE_SEGMENT_RECORDS)
		// One write for each record, and one of the slot map for each segment
		// that starts.
		testing.expect_value(t, u64(fixture.failing.memory.writes - writes_before), count + u64(segments))
		for segment in u32(0) ..= TEST_SEGMENTS {
			testing.expectf(t, (object_of(fixture, space_number, segment) != nil) == (segment < segments), "count %d: segment %d present is wrong", count, segment)
		}
		before := fixture.store.spaces[space_number - 1]

		restart(fixture)
		testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
		testing.expect_value(t, fixture.store.load_state, Space_Load_State.Loaded)
		expect_space_whole(t, &fixture.store, space_number, count)
		after := &fixture.store.spaces[space_number - 1]
		testing.expect(t, after.closed_segment_hash == before.closed_segment_hash, "a segment hash changed")
		testing.expect(t, after.last_hash == before.last_hash, "the last link changed")

		// The closed segments keep their bytes through the next record.
		closed := u32(count / SPACE_SEGMENT_RECORDS)
		saved: [TEST_SEGMENTS][SEGMENT_BYTES_MOST]u8
		saved_length: [TEST_SEGMENTS]int
		for segment in 0 ..< closed {
			object := object_of(fixture, space_number, segment)
			saved_length[segment] = object.length
			copy(saved[segment][:], object.bytes[:object.length])
		}
		record := record_bytes(count)
		serial, refusal := record_append(&fixture.store, space_number, record[:], 1000 + count)
		if count == SPACE_RECORDS_MOST {
			testing.expect_value(t, refusal, Space_Refusal.Space_Full)
			testing.expect(t, object_of(fixture, space_number, TEST_SEGMENTS) == nil, "a segment past the bound was written")
		} else {
			testing.expect_value(t, refusal, Space_Refusal.None)
			testing.expect_value(t, serial, count)
		}
		for segment in 0 ..< closed {
			object := object_of(fixture, space_number, segment)
			testing.expect_value(t, object.length, saved_length[segment])
			testing.expectf(t, string(object.bytes[:object.length]) == string(saved[segment][:saved_length[segment]]), "count %d: the closed segment %d was written again", count, segment)
		}
		expected_count := min(count + 1, SPACE_RECORDS_MOST)
		restart(fixture)
		expect_space_whole(t, &fixture.store, space_number, expected_count)
	}
}

// A restart over a store that holds several audit spaces keeps each one in
// its place, keeps the source of a space from its records and its state,
// and keeps a stranger from each; a space Keep is never in the store.
@(test)
a_restart_keeps_each_space_and_its_isolation :: proc(t: ^testing.T) {
	fixture := new(Fixture)
	defer free(fixture)
	restart(fixture)
	keep_terms := Space_Terms{kind_word = i64(Collector_Space_Kind.Keep), bound_records = 4, forwarding_word = i64(Space_Forwarding.Keeps), record_size = 8}
	keep, keep_refusal := space_open(&fixture.store, name_bytes("noisy"), name_bytes("log"), keep_terms)
	testing.expect_value(t, keep_refusal, Space_Refusal.None)
	writes_before := fixture.failing.memory.writes
	append_records(t, &fixture.store, keep, 0, 6)
	testing.expect_value(t, fixture.failing.memory.writes, writes_before)
	server, _ := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(40, .Forward))
	shop, _ := space_open(&fixture.store, name_bytes("shop"), name_bytes("log"), terms_audit(20, .Keeps, 8))
	append_records(t, &fixture.store, server, 0, 33)
	append_records(t, &fixture.store, shop, 0, 5)

	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
	testing.expect(t, space_of(&fixture.store, keep) == nil, "a space Keep came back from the store")
	expect_space_whole(t, &fixture.store, server, 33)
	expect_space_whole(t, &fixture.store, shop, 5)
	testing.expect_value(t, space_of(&fixture.store, server).forwarding, Space_Forwarding.Forward)
	testing.expect_value(t, space_of(&fixture.store, server).bound, u32(40))

	// The same pair and terms give the same space; other terms are refused.
	again, again_refusal := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(40, .Forward))
	testing.expect_value(t, again_refusal, Space_Refusal.None)
	testing.expect_value(t, again, server)
	_, thinned := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), {kind_word = i64(Collector_Space_Kind.Keep), bound_records = 40, forwarding_word = i64(Space_Forwarding.Forward), record_size = 8})
	testing.expect_value(t, thinned, Space_Refusal.Bad_Kind)

	heads: [4]Kept_Record_Head
	bytes: [32]u8
	source := reader_of(PRINCIPAL, "server")
	_, own := records_read(&fixture.store, server, -1, 4, &source, heads[:], bytes[:])
	testing.expect_value(t, own, Space_Refusal.Own_Space)
	_, own_stats := space_stats(&fixture.store, server, &source)
	testing.expect_value(t, own_stats, Space_Refusal.Own_Space)
	rows: [64]Space_Row
	listed, _ := space_rows(&fixture.store, &source, rows[:])
	testing.expect_value(t, listed, 1)
	testing.expect_value(t, rows[0].space, i64(shop))
	stranger := reader_of(PRINCIPAL + 1, "console")
	_, strange := records_read(&fixture.store, shop, -1, 4, &stranger, heads[:], bytes[:])
	testing.expect_value(t, strange, Space_Refusal.Not_Principal)
	testing.expect(t, heads == {} && bytes == {}, "a refused reader received a record")

	// The serials go on after the restart, in the next segment.
	append_records(t, &fixture.store, server, 33, 7)
	restart(fixture)
	expect_space_whole(t, &fixture.store, server, 40)
	record := record_bytes(40)
	_, full := record_append(&fixture.store, server, record[:], 1)
	testing.expect_value(t, full, Space_Refusal.Space_Full)
}

// expect_damaged restarts the fixture and checks that each step is refused
// with Store_Damaged and that no space is served.
@(private = "file")
expect_damaged :: proc(t: ^testing.T, fixture: ^Fixture, what: string, principal := PRINCIPAL, identifier := TEST_COLLECTOR_IDENTIFIER, location := #caller_location) -> bool {
	restart(fixture, principal, identifier)
	refusal := space_store_ready(&fixture.store)
	if !testing.expectf(t, refusal == .Store_Damaged, "%s: the restart gave %v", what, refusal, loc = location) {
		return false
	}
	testing.expect_value(t, fixture.store.load_state, Space_Load_State.Damaged, location)
	testing.expect_value(t, space_count(&fixture.store), 0, location)
	reader := reader_of(principal, "console")
	heads: [1]Kept_Record_Head
	bytes: [8]u8
	_, read := records_read(&fixture.store, 1, -1, 1, &reader, heads[:], bytes[:])
	testing.expect_value(t, read, Space_Refusal.Store_Damaged, location)
	record := record_bytes(0)
	_, appended := record_append(&fixture.store, 1, record[:], 1)
	testing.expect_value(t, appended, Space_Refusal.Store_Damaged, location)
	_, opened := space_open(&fixture.store, name_bytes("other"), name_bytes("log"), terms_audit(4))
	testing.expect_value(t, opened, Space_Refusal.Store_Damaged, location)
	rows: [64]Space_Row
	_, listed := space_rows(&fixture.store, &reader, rows[:])
	testing.expect_value(t, listed, Space_Refusal.Store_Damaged, location)
	return true
}

@(private = "file")
damaged_fixture :: proc(t: ^testing.T) -> ^Fixture {
	fixture := new(Fixture)
	restart(fixture)
	first, _ := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(SPACE_RECORDS_MOST))
	second, _ := space_open(&fixture.store, name_bytes("shop"), name_bytes("log"), terms_audit(8))
	append_records(t, &fixture.store, first, 0, 2 * SPACE_SEGMENT_RECORDS + 8)
	append_records(t, &fixture.store, second, 0, 3)
	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
	return fixture
}

// One flipped bit anywhere in the index or in a segment (its head, a
// record, the link of its last record, its own hash, the hash of the
// segment before it) refuses the whole restart with Store_Damaged.
@(test)
one_flipped_bit_in_any_stored_byte_refuses_the_restart :: proc(t: ^testing.T) {
	fixture := damaged_fixture(t)
	defer free(fixture)
	objects := 0
	for &object in fixture.failing.memory.objects {
		if !object.used {
			continue
		}
		objects += 1
		for byte_index in 0 ..< object.length {
			for bit in u8(0) ..< 8 {
				object.bytes[byte_index] ~= 1 << bit
				if !expect_damaged(t, fixture, string(object.name[:object.name_length])) {
					testing.expectf(t, false, "%s, byte %d, bit %d", string(object.name[:object.name_length]), byte_index, bit)
					return
				}
				object.bytes[byte_index] ~= 1 << bit
			}
		}
	}
	// The index, three segments of the first space, one of the second, and
	// the slot map of each space.
	testing.expect_value(t, objects, 7)
	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
	expect_space_whole(t, &fixture.store, 1, 2 * SPACE_SEGMENT_RECORDS + 8)
}

// A segment that is missing, cut, longer, replaced by an older version of
// itself, moved to another space or another place, or past the bound, an
// index that is missing, and a store read by the collector of another
// principal each refuse the restart.
@(test)
a_moved_missing_or_older_object_refuses_the_restart :: proc(t: ^testing.T) {
	fixture := damaged_fixture(t)
	defer free(fixture)

	// A middle segment removed.
	middle := object_of(fixture, 1, 1)
	middle.used = false
	expect_damaged(t, fixture, "a removed middle segment")
	middle.used = true

	// A segment cut by one byte, or one byte longer.
	last := object_of(fixture, 1, 2)
	last.length -= 1
	expect_damaged(t, fixture, "a cut segment")
	last.length += 2
	expect_damaged(t, fixture, "a longer segment")
	last.length -= 1

	// A segment one past the bound of its object.
	saved_length := last.length
	last.length = pr.MEMORY_PRIVATE_STORE_OBJECT_BYTES
	expect_damaged(t, fixture, "a segment past the largest segment")
	last.length = saved_length

	// The index removed, with its segments still there.
	index := pr.memory_private_store_find(&fixture.failing.memory, SPACE_INDEX_OBJECT_NAME)
	index.used = false
	expect_damaged(t, fixture, "a removed index")
	index.used = true

	// Another principal reads the store: another identifier, also in the
	// same slot, and no identifier.
	other_identifier := TEST_COLLECTOR_IDENTIFIER
	other_identifier[31] ~= 1
	expect_damaged(t, fixture, "another principal", PRINCIPAL + 1, other_identifier)
	expect_damaged(t, fixture, "another principal in the same slot", PRINCIPAL, other_identifier)
	expect_damaged(t, fixture, "no identifier", PRINCIPAL, {})

	// The index of an older release names its principal by its slot: it is
	// refused as such, not as damage.
	older_index := pr.memory_private_store_find(&fixture.failing.memory, SPACE_INDEX_OBJECT_NAME)
	saved_version := older_index.bytes[SPACE_INDEX_VERSION_AT]
	older_index.bytes[SPACE_INDEX_VERSION_AT] = u8(OLDER_SPACE_INDEX_VERSION)
	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.Older_Format)
	testing.expect_value(t, space_count(&fixture.store), 0)
	older_index.bytes[SPACE_INDEX_VERSION_AT] = saved_version

	// The segment of one space under the name of another space: its head
	// names its own space and terms.
	second := object_of(fixture, 2, 0)
	first := object_of(fixture, 1, 0)
	saved: pr.Memory_Private_Object = first^
	first.length = second.length
	copy(first.bytes[:], second.bytes[:second.length])
	expect_damaged(t, fixture, "a segment of another space")
	first^ = saved

	// Two segments swapped in place.
	other := object_of(fixture, 1, 1)
	first_bytes := first.bytes
	first.bytes = other.bytes
	other.bytes = first_bytes
	expect_damaged(t, fixture, "two swapped segments")
	other.bytes = first.bytes
	first.bytes = first_bytes

	// A segment past the last segment of the largest space.
	extra_name: [SEGMENT_OBJECT_NAME_BYTES]u8
	port := pr.memory_private_store_port(&fixture.failing.memory)
	// A segment in a slot that the map does not name: a start reads the map,
	// not that slot, and the verify of the space finds it.
	testing.expect_value(t, pr.private_store_write(&port, segment_object_name(&extra_name, 1, TEST_SEGMENTS), first.bytes[:first.length]), pr.Private_Store_Status.Ok)
	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
	stray, stray_serial := space_verify(&fixture.store, 1)
	testing.expect_value(t, stray, Space_Refusal.Chain_Broken)
	testing.expect_value(t, stray_serial, u64(3 * SPACE_SEGMENT_RECORDS))
	pr.memory_private_store_find(&fixture.failing.memory, segment_object_name(&extra_name, 1, TEST_SEGMENTS)).used = false

	// A map of a space that the index does not name, at the place after
	// the last one that it names, where a lost index leaves one: it
	// refuses the start.
	map_name: [SEGMENT_OBJECT_NAME_BYTES]u8
	map_object := pr.memory_private_store_find(&fixture.failing.memory, slot_map_object_name(&map_name, 1))
	saved_map := map_object^
	testing.expect_value(t, pr.private_store_write(&port, slot_map_object_name(&map_name, 3), map_object.bytes[:map_object.length]), pr.Private_Store_Status.Ok)
	expect_damaged(t, fixture, "a slot map that no index names")
	pr.memory_private_store_find(&fixture.failing.memory, slot_map_object_name(&map_name, 3)).used = false
	map_object^ = saved_map

	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
	expect_space_whole(t, &fixture.store, 1, 2 * SPACE_SEGMENT_RECORDS + 8)
}

// The open segment written back as it was before its last records, while a
// segment after it exists, breaks the order of the segments.
@(test)
an_older_version_of_a_closed_segment_refuses_the_restart :: proc(t: ^testing.T) {
	fixture := new(Fixture)
	defer free(fixture)
	restart(fixture)
	space_number, _ := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(SPACE_RECORDS_MOST))
	append_records(t, &fixture.store, space_number, 0, 20)
	older: pr.Memory_Private_Object = object_of(fixture, space_number, 1)^
	append_records(t, &fixture.store, space_number, 20, 20)
	object_of(fixture, space_number, 1)^ = older
	expect_damaged(t, fixture, "an older middle segment")
}

// A removed last segment is the one change that a restart cannot see from
// the store alone: the space comes back shorter, and its last link differs
// from the one that the principal copied out of the machine
// (src/md/features/module_outputs.md, "The chain of the segments").
@(test)
a_removed_last_segment_shows_as_another_last_link :: proc(t: ^testing.T) {
	fixture := new(Fixture)
	defer free(fixture)
	restart(fixture)
	space_number, _ := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(SPACE_RECORDS_MOST))
	append_records(t, &fixture.store, space_number, 0, 20)
	copied_out := space_of(&fixture.store, space_number).last_hash
	object_of(fixture, space_number, 1).used = false
	restart(fixture)
	expect_space_whole(t, &fixture.store, space_number, SPACE_SEGMENT_RECORDS)
	testing.expect(t, space_of(&fixture.store, space_number).last_hash != copied_out, "the shorter space kept the last link")
}

// A write that the store refuses keeps nothing: the space, the forward
// queue and the stored segments stay as they were, at a record inside a
// segment and at the first record of a new one. A refused index write
// opens no space. The next accepted write goes on with the next serial.
@(test)
a_refused_write_keeps_and_forwards_nothing :: proc(t: ^testing.T) {
	fixture := new(Fixture)
	defer free(fixture)
	restart(fixture)

	fixture.failing.memory.writes_allowed = fixture.failing.memory.writes
	_, refused_open := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(SPACE_RECORDS_MOST, .Forward))
	testing.expect_value(t, refused_open, Space_Refusal.Store_Failed)
	testing.expect_value(t, space_count(&fixture.store), 0)
	testing.expect(t, pr.memory_private_store_find(&fixture.failing.memory, SPACE_INDEX_OBJECT_NAME) == nil, "a refused open wrote an index")
	fixture.failing.memory.writes_allowed = -1

	space_number, opened := space_open(&fixture.store, name_bytes("server"), name_bytes("orders"), terms_audit(SPACE_RECORDS_MOST, .Forward))
	testing.expect_value(t, opened, Space_Refusal.None)
	for refused_serial in ([?]u64{0, 5, SPACE_SEGMENT_RECORDS}) {
		count := space_of(&fixture.store, space_number).count
		append_records(t, &fixture.store, space_number, u64(count), refused_serial - u64(count))
		for fixture.store.forward_count > 0 {
			forward_done(&fixture.store)
		}
		snapshot := fixture.store.spaces[space_number - 1]
		stored: [TEST_SEGMENTS + 1]pr.Memory_Private_Object
		for segment in u32(0) ..= TEST_SEGMENTS {
			if object := object_of(fixture, space_number, segment); object != nil {
				stored[segment] = object^
			}
		}
		fixture.failing.memory.writes_allowed = fixture.failing.memory.writes
		record := record_bytes(refused_serial)
		_, refusal := record_append(&fixture.store, space_number, record[:], 1)
		testing.expect_value(t, refusal, Space_Refusal.Store_Failed)
		testing.expect(t, fixture.store.spaces[space_number - 1] == snapshot, "a refused write changed the space")
		testing.expect_value(t, fixture.store.forward_count, u32(0))
		_, empty := forward_peek(&fixture.store)
		testing.expect_value(t, empty, Space_Refusal.Forward_Empty)
		for segment in u32(0) ..= TEST_SEGMENTS {
			object := object_of(fixture, space_number, segment)
			if stored[segment].used {
				testing.expect(t, object != nil && object^ == stored[segment], "a refused write changed a stored segment")
			} else {
				testing.expect(t, object == nil, "a refused write made a segment")
			}
		}
		fixture.failing.memory.writes_allowed = -1
		kept, accepted := record_append(&fixture.store, space_number, record[:], 1000 + refused_serial)
		testing.expect_value(t, accepted, Space_Refusal.None)
		testing.expect_value(t, kept, refused_serial)
		item, queued := forward_peek(&fixture.store)
		testing.expect_value(t, queued, Space_Refusal.None)
		testing.expect_value(t, item.serial, refused_serial)
		forward_done(&fixture.store)
	}
	restart(fixture)
	expect_space_whole(t, &fixture.store, space_number, SPACE_SEGMENT_RECORDS + 1)
}

// A read of the store that fails leaves no space and refuses each step
// with Store_Failed; the next step reads again, and takes the spaces.
@(test)
a_failed_read_refuses_until_the_store_answers :: proc(t: ^testing.T) {
	fixture := damaged_fixture(t)
	defer free(fixture)
	restart(fixture)
	fixture.failing.reads_fail = true
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.Store_Failed)
	testing.expect_value(t, fixture.store.load_state, Space_Load_State.Not_Loaded)
	testing.expect_value(t, space_count(&fixture.store), 0)
	record := record_bytes(0)
	_, appended := record_append(&fixture.store, 1, record[:], 1)
	testing.expect_value(t, appended, Space_Refusal.Store_Failed)
	_, opened := space_open(&fixture.store, name_bytes("other"), name_bytes("log"), terms_audit(4))
	testing.expect_value(t, opened, Space_Refusal.Store_Failed)
	fixture.failing.reads_fail = false
	expect_space_whole(t, &fixture.store, 1, 2 * SPACE_SEGMENT_RECORDS + 8)

	// A store with no port keeps no audit space.
	no_port := new(Space_Store)
	defer free(no_port)
	space_store_init(no_port, PRINCIPAL, TEST_COLLECTOR_IDENTIFIER, {}, space_window_heap_port())
	_, refused := space_open(no_port, name_bytes("server"), name_bytes("orders"), terms_audit(4))
	testing.expect_value(t, refused, Space_Refusal.Store_Failed)
}

// space_verify reads the segments back: a segment changed in the store
// after the start, removed, or one past the last, breaks the chain at the
// first serial of that segment.
@(test)
space_verify_finds_a_segment_changed_after_the_start :: proc(t: ^testing.T) {
	fixture := damaged_fixture(t)
	defer free(fixture)
	space_number := u32(1)
	verified, _ := space_verify(&fixture.store, space_number)
	testing.expect_value(t, verified, Space_Refusal.None)

	middle := object_of(fixture, space_number, 1)
	middle.bytes[SEGMENT_HEAD_BYTES + SEGMENT_RECORD_HEAD_BYTES] ~= 1
	broken, failing_serial := space_verify(&fixture.store, space_number)
	testing.expect_value(t, broken, Space_Refusal.Chain_Broken)
	testing.expect_value(t, failing_serial, u64(SPACE_SEGMENT_RECORDS))
	middle.bytes[SEGMENT_HEAD_BYTES + SEGMENT_RECORD_HEAD_BYTES] ~= 1

	last := object_of(fixture, space_number, 2)
	last.used = false
	broken, failing_serial = space_verify(&fixture.store, space_number)
	testing.expect_value(t, broken, Space_Refusal.Chain_Broken)
	testing.expect_value(t, failing_serial, u64(2 * SPACE_SEGMENT_RECORDS))
	last.used = true

	extra_name: [SEGMENT_OBJECT_NAME_BYTES]u8
	port := pr.memory_private_store_port(&fixture.failing.memory)
	pr.private_store_write(&port, segment_object_name(&extra_name, space_number, 3), last.bytes[:last.length])
	broken, failing_serial = space_verify(&fixture.store, space_number)
	testing.expect_value(t, broken, Space_Refusal.Chain_Broken)
	testing.expect_value(t, failing_serial, u64(3 * SPACE_SEGMENT_RECORDS))
}
