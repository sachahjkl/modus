#+build !freestanding
package wide_grants

import "core:fmt"
import "core:testing"
import "modus:contract/blake3"
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
failing_store_port :: proc(failing: ^Failing_Store) -> pr.Private_Store_Port {
	failing.memory.writes_allowed = -1
	return {user = failing, read = failing_store_read, write = failing_store_write}
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
restart :: proc(fixture: ^Fixture, principal := PRINCIPAL) {
	space_store_init(&fixture.store, principal, failing_store_port(&fixture.failing))
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
	// The index, the map of each space, the segment before the ring and the
	// segments of the ring.
	testing.expectf(t, fixture.store.load_reads <= 1 + SPACE_CAPACITY + LOAD_SEGMENTS_MOST + 1, "a start read %d objects", fixture.store.load_reads)
	fmt.printfln("modustool: a measure: a start of a space of 4000 records read %d objects", fixture.store.load_reads)
	check(t, &fixture.store, space_number, &reader, -1, 1, links, heads[:], bytes[:])
	verified, _ := space_verify(&fixture.store, space_number)
	testing.expect_value(t, verified, Space_Refusal.None)

	// A map that names a segment past a gap.
	fixture.store.slot_maps[space_number - 1][100] = 0
	map_name: [SEGMENT_OBJECT_NAME_BYTES]u8
	before := pr.memory_private_store_find(&fixture.failing.memory, slot_map_object_name(&map_name, space_number))^
	testing.expect_value(t, slot_map_persist(&fixture.store, space_number), Space_Refusal.None)
	restart(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.Store_Damaged)
	pr.memory_private_store_find(&fixture.failing.memory, slot_map_object_name(&map_name, space_number))^ = before
}

@(test)
segment_object_names_are_exact :: proc(t: ^testing.T) {
	place: [SEGMENT_OBJECT_NAME_BYTES]u8
	testing.expect_value(t, segment_object_name(&place, 1, 0), "collector_space_1_segment_0")
	testing.expect_value(t, segment_object_name(&place, SPACE_CAPACITY, TEST_SEGMENTS), "collector_space_8_segment_4")
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
	rows: [SPACE_CAPACITY]Space_Row
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
expect_damaged :: proc(t: ^testing.T, fixture: ^Fixture, what: string, principal := PRINCIPAL, location := #caller_location) -> bool {
	restart(fixture, principal)
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
	rows: [SPACE_CAPACITY]Space_Row
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

	// Another principal reads the store.
	expect_damaged(t, fixture, "another principal", PRINCIPAL + 1)

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

	// A map that names a segment past a gap, and a map of a space that the
	// index does not name: each refuses the start.
	map_name: [SEGMENT_OBJECT_NAME_BYTES]u8
	map_object := pr.memory_private_store_find(&fixture.failing.memory, slot_map_object_name(&map_name, 1))
	saved_map := map_object^
	testing.expect_value(t, pr.private_store_write(&port, slot_map_object_name(&map_name, 5), map_object.bytes[:map_object.length]), pr.Private_Store_Status.Ok)
	expect_damaged(t, fixture, "a slot map that no index names")
	pr.memory_private_store_find(&fixture.failing.memory, slot_map_object_name(&map_name, 5)).used = false
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
	space_store_init(no_port, PRINCIPAL, {})
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
