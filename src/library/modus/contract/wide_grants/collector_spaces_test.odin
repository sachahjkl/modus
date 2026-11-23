#+build !freestanding
package wide_grants

import "core:testing"
import pr "modus:contract/plans_recipes"

// memory_store_bind empties store for principal over a new private store in
// memory, which the caller frees.
@(private = "file")
memory_store_bind :: proc(store: ^Space_Store, principal: u64, windows_paid: u32 = SPACE_WINDOWS_STATED) -> ^pr.Memory_Private_Store {
	memory := new(pr.Memory_Private_Store)
	space_store_init(store, principal, pr.memory_private_store_port(memory), space_window_heap_port(), windows_paid)
	return memory
}

@(private = "file")
audit_terms :: proc(bound: i64, record_size: i64 = 8, forwarding := Space_Forwarding.Keeps) -> Space_Terms {
	return {kind_word = i64(Collector_Space_Kind.Audit), bound_records = bound, forwarding_word = i64(forwarding), record_size = record_size}
}

@(private = "file")
keep_terms :: proc(bound: i64, record_size: i64 = 8, forwarding := Space_Forwarding.Keeps) -> Space_Terms {
	return {kind_word = i64(Collector_Space_Kind.Keep), bound_records = bound, forwarding_word = i64(forwarding), record_size = record_size}
}

@(private = "file")
text :: proc(value: string) -> []u8 {
	return transmute([]u8)value
}

@(private = "file")
record_of :: proc(value: u8) -> [8]u8 {
	return {value, value, value, value, value, value, value, value}
}

@(private = "file")
principal_reader :: proc(principal: u64, name: string) -> (reader: Space_Reader) {
	reader.principal = principal
	reader.acts_for_principal = true
	copy(reader.name[:], name)
	return reader
}

@(test)
space_open_refuses_each_bad_term :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 0)
	defer free(memory)

	long_name: [SPACE_NAME_BYTES]u8
	for &value in long_name {
		value = 'a'
	}
	control := [3]u8{'a', 0x07, 'b'}
	cases := [?]struct {
		source:  []u8,
		output:  []u8,
		terms:   Space_Terms,
		refusal: Space_Refusal,
	}{
		{nil, text("orders"), audit_terms(4), .Bad_Name},
		{long_name[:], text("orders"), audit_terms(4), .Bad_Name},
		{long_name[:SPACE_NAME_BYTES - 1], text("orders"), audit_terms(4), .None},
		{control[:], text("orders"), audit_terms(4), .Bad_Name},
		{text("server"), text(""), audit_terms(4), .Bad_Name},
		{text("server"), text("orders"), {kind_word = 0, bound_records = 4, forwarding_word = 1, record_size = 8}, .Bad_Kind},
		{text("server"), text("orders"), {kind_word = 3, bound_records = 4, forwarding_word = 1, record_size = 8}, .Bad_Kind},
		{text("server"), text("orders"), {kind_word = -1, bound_records = 4, forwarding_word = 1, record_size = 8}, .Bad_Kind},
		{text("server"), text("orders"), {kind_word = 2, bound_records = 4, forwarding_word = 0, record_size = 8}, .Bad_Forwarding},
		{text("server"), text("orders"), {kind_word = 2, bound_records = 4, forwarding_word = 3, record_size = 8}, .Bad_Forwarding},
		{text("server"), text("orders"), {kind_word = 2, bound_records = 4, forwarding_word = min(i64), record_size = 8}, .Bad_Forwarding},
		{text("server"), text("orders"), audit_terms(0), .Bad_Bound},
		{text("server"), text("orders"), audit_terms(-1), .Bad_Bound},
		{text("server"), text("orders"), audit_terms(SPACE_AUDIT_BOUND_MOST + 1), .Bad_Bound},
		{text("server"), text("orders"), audit_terms(4, 0), .Bad_Record_Size},
		{text("server"), text("orders"), audit_terms(4, SPACE_RECORD_BYTES_MOST + 1), .Bad_Record_Size},
		{text("server"), text("orders"), audit_terms(4, max(i64)), .Bad_Record_Size},
	}
	for item, index in cases {
		_, refusal := space_open(store, item.source, item.output, item.terms)
		testing.expectf(t, refusal == item.refusal, "case %d: %v, expected %v", index, refusal, item.refusal)
	}
	testing.expect_value(t, space_count(store), 1)
}

@(test)
space_open_keeps_one_space_for_one_pair_and_bounds_the_room :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 0)
	defer free(memory)

	first, refusal := space_open(store, text("server"), text("orders"), audit_terms(4))
	testing.expect_value(t, refusal, Space_Refusal.None)
	again, _ := space_open(store, text("server"), text("orders"), audit_terms(4))
	testing.expect_value(t, again, first)
	_, refusal = space_open(store, text("server"), text("orders"), keep_terms(4))
	testing.expect_value(t, refusal, Space_Refusal.Bad_Kind)
	_, refusal = space_open(store, text("server"), text("orders"), audit_terms(5))
	testing.expect_value(t, refusal, Space_Refusal.Bad_Kind)
	resized, _ := space_open(store, text("server"), text("orders"), audit_terms(4, 16))
	testing.expect(t, resized != first, "a new record size gets a new space")
	testing.expect_value(t, source_count(store), 1)
	testing.expect(t, space_of(store, first).closed, "the space of the old record size closes")
}

// The windows of the budget: a wide grant beside five other spaces when the
// budget pays eight windows, and beside six when it pays nine; one more
// other space is refused, before or after the grant, since the act spaces
// that are not open keep their windows. An act space takes a window that
// the others leave, and the refusals change nothing.
@(test)
a_wide_grant_keeps_its_windows_beside_other_spaces :: proc(t: ^testing.T) {
	for others in ([?]int{5, 6}) {
		store := new(Space_Store)
		defer free(store)
		memory := memory_store_bind(store, 0, u32(others) + ACT_SPACES_RESERVED)
		defer free(memory)
		name: [2]u8 = {'s', 'a'}
		for index in 0 ..< others {
			name[1] = 'a' + u8(index)
			_, refusal := space_open(store, name[:], text("orders"), audit_terms(SPACE_RECORDS_MOST))
			testing.expectf(t, refusal == .None, "%d others: space %d: %v", others, index, refusal)
		}
		// The next other space would take a window of the grant.
		_, refusal := space_open(store, text("late"), text("orders"), keep_terms(1))
		testing.expect_value(t, refusal, Space_Refusal.Memory_Refused)
		testing.expect_value(t, space_count(store), others)
		// A space of a source named like a writer, with another output, is no
		// act space.
		_, refusal = space_open(store, text("remote"), text("calls"), keep_terms(1))
		testing.expect_value(t, refusal, Space_Refusal.Memory_Refused)
		for source in ([?]string{"root", "remote"}) {
			_, refusal = space_open(store, text(source), text(ACT_OUTPUT_NAME), audit_terms(SPACE_AUDIT_BOUND_MOST, 64))
			testing.expect_value(t, refusal, Space_Refusal.None)
		}
		// Two act spaces open: the third keeps its window still.
		_, refusal = space_open(store, text("late"), text("orders"), keep_terms(1))
		testing.expect_value(t, refusal, Space_Refusal.Memory_Refused)
		_, refusal = space_open(store, text("compositor"), text(ACT_OUTPUT_NAME), audit_terms(SPACE_AUDIT_BOUND_MOST, 64))
		testing.expect_value(t, refusal, Space_Refusal.None)
		open, acts := space_windows_open(store)
		testing.expect_value(t, open, u32(others) + ACT_SPACES_RESERVED)
		testing.expect_value(t, acts, ACT_SPACES_RESERVED)
		// Each window paid: nothing more opens, not even an act space again.
		_, refusal = space_open(store, text("late"), text("orders"), keep_terms(1))
		testing.expect_value(t, refusal, Space_Refusal.Memory_Refused)
		_, refusal = space_open(store, text("console"), text(ACT_OUTPUT_NAME), audit_terms(SPACE_AUDIT_BOUND_MOST, 64))
		testing.expect_value(t, refusal, Space_Refusal.Memory_Refused)
	}
	testing.expect_value(t, int(ACT_SPACES_RESERVED), card(ACT_PRODUCERS_WIRED))
}

// A window that the kernel does not commit refuses the space, with no
// change.
@(test)
a_window_that_is_not_committed_refuses_the_space :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 0)
	defer free(memory)
	refusing := store.windows
	refusing.take = proc "contextless" (user: rawptr, place: u32) -> ^Space_Window {
		return nil
	}
	store.windows = refusing
	_, refusal := space_open(store, text("server"), text("orders"), audit_terms(4))
	testing.expect_value(t, refusal, Space_Refusal.Memory_Refused)
	testing.expect_value(t, space_count(store), 0)
}

// The places of the table: a closed audit space keeps its place, so 32
// record sizes of one pair fill the table, and the next size is refused; a
// space Keep frees its place when its size changes.
@(test)
space_open_refuses_past_its_places :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 0)
	defer free(memory)
	for size in 1 ..= SPACE_CAPACITY {
		_, refusal := space_open(store, text("server"), text("orders"), audit_terms(4, i64(size)))
		testing.expect_value(t, refusal, Space_Refusal.None)
	}
	testing.expect_value(t, space_count(store), SPACE_CAPACITY)
	open, _ := space_windows_open(store)
	testing.expect_value(t, open, u32(1))
	_, refusal := space_open(store, text("server"), text("orders"), audit_terms(4, SPACE_CAPACITY + 1))
	testing.expect_value(t, refusal, Space_Refusal.Space_Limit_Reached)
	_, refusal = space_open(store, text("late"), text("o"), keep_terms(1))
	testing.expect_value(t, refusal, Space_Refusal.Space_Limit_Reached)

	kept := new(Space_Store)
	defer free(kept)
	kept_memory := memory_store_bind(kept, 0)
	defer free(kept_memory)
	old, _ := space_open(kept, text("server"), text("log"), keep_terms(4, 8))
	resized, resized_refusal := space_open(kept, text("server"), text("log"), keep_terms(4, 16))
	testing.expect_value(t, resized_refusal, Space_Refusal.None)
	testing.expect(t, space_of(kept, old) == nil || old == resized, "the old space Keep frees its place")
	testing.expect_value(t, space_count(kept), 1)
	open, _ = space_windows_open(kept)
	testing.expect_value(t, open, u32(1))
	testing.expect_value(t, space_of(kept, resized).record_size, u32(16))
}

// A record size that changes closes the old audit space: it takes no
// record, its records stay readable whole from the store and its chain
// verifies, before and after a restart, with no window; the new space takes
// records.
@(test)
a_closed_audit_space_keeps_its_records :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 0)
	defer free(memory)
	old, _ := space_open(store, text("server"), text("orders"), audit_terms(SPACE_AUDIT_BOUND_MOST))
	for value in 0 ..< 100 {
		record := record_of(u8(value))
		_, refusal := record_append(store, old, record[:], u64(value))
		testing.expect_value(t, refusal, Space_Refusal.None)
	}
	resized, _ := space_open(store, text("server"), text("orders"), audit_terms(SPACE_AUDIT_BOUND_MOST, 16))
	reader: Space_Reader = {principal = 0, acts_for_principal = true}
	copy(reader.name[:], "console")
	check :: proc(t: ^testing.T, store: ^Space_Store, old: u32, reader: ^Space_Reader) {
		closed := space_of(store, old)
		testing.expect(t, closed != nil && closed.closed && closed.ring == nil, "the old space is closed, with no window")
		record := record_of(1)
		_, refusal := record_append(store, old, record[:], 1000)
		testing.expect_value(t, refusal, Space_Refusal.Space_Closed)
		heads: [SPACE_RECORDS_MOST]Kept_Record_Head
		bytes: [SPACE_RECORDS_MOST * 8]u8
		count, read := records_read(store, old, 95, SPACE_RECORDS_MOST, reader, heads[:], bytes[:])
		testing.expect_value(t, read, Space_Refusal.None)
		testing.expect_value(t, count, 4)
		testing.expect_value(t, heads[3].serial, i64(99))
		count, read = records_read(store, old, -1, 1, reader, heads[:], bytes[:])
		testing.expect_value(t, read, Space_Refusal.None)
		testing.expect_value(t, count, 1)
		testing.expect_value(t, heads[0].serial, i64(0))
		verified, _ := space_verify(store, old)
		testing.expect_value(t, verified, Space_Refusal.None)
	}
	check(t, store, old, &reader)
	record := [16]u8{1 = 7}
	_, refusal := record_append(store, resized, record[:], 200)
	testing.expect_value(t, refusal, Space_Refusal.None)
	// A restart: the closed space comes back from its row, with no window.
	space_store_init(store, 0, pr.memory_private_store_port(memory), space_window_heap_port(), SPACE_WINDOWS_STATED)
	testing.expect_value(t, space_store_ready(store), Space_Refusal.None)
	check(t, store, old, &reader)
	open, _ := space_windows_open(store)
	testing.expect_value(t, open, u32(1))
}

@(test)
record_append_refuses_unknown_spaces_and_wrong_sizes :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 0)
	defer free(memory)
	space, _ := space_open(store, text("server"), text("orders"), audit_terms(4))
	record := record_of(1)
	for number in ([?]u32{0, 2, SPACE_CAPACITY, SPACE_CAPACITY + 1, max(u32)}) {
		_, refusal := record_append(store, number, record[:], 1)
		testing.expectf(t, refusal == .Unknown_Space, "the space %d is unknown", number)
	}
	_, refusal := record_append(store, space, record[:7], 1)
	testing.expect_value(t, refusal, Space_Refusal.Wrong_Size)
	_, refusal = record_append(store, space, nil, 1)
	testing.expect_value(t, refusal, Space_Refusal.Wrong_Size)
	longer: [9]u8
	_, refusal = record_append(store, space, longer[:], 1)
	testing.expect_value(t, refusal, Space_Refusal.Wrong_Size)
	testing.expect_value(t, kept_record_count(store), u64(0))
}

@(test)
a_full_audit_space_refuses_and_changes_nothing :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 0)
	defer free(memory)
	space, _ := space_open(store, text("server"), text("orders"), audit_terms(2))
	for value in u8(0) ..< 2 {
		record := record_of(value)
		serial, refusal := record_append(store, space, record[:], u64(value))
		testing.expect_value(t, refusal, Space_Refusal.None)
		testing.expect_value(t, serial, u64(value))
	}
	held := space_of(store, space)
	before := held^
	before_ring := held.ring^
	record := record_of(9)
	_, refusal := record_append(store, space, record[:], 9)
	testing.expect_value(t, refusal, Space_Refusal.Space_Full)
	testing.expect_value(t, held.count, before.count)
	testing.expect_value(t, held.next_serial, before.next_serial)
	testing.expect(t, held.last_hash == before.last_hash, "a refused record changes no link")
	testing.expect(t, held.ring.bytes == before_ring.bytes, "a refused record changes no byte")
	testing.expect_value(t, held.removed, u64(0))
	testing.expect_value(t, held.refused_full, u64(1))
	refusal, _ = space_verify(store, space)
	testing.expect_value(t, refusal, Space_Refusal.None)
}

@(test)
a_full_keep_space_thins_its_oldest_record_and_counts_it :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 0)
	defer free(memory)
	space, _ := space_open(store, text("server"), text("orders"), keep_terms(2))
	for value in u8(0) ..< 5 {
		record := record_of(value)
		_, refusal := record_append(store, space, record[:], u64(value))
		testing.expect_value(t, refusal, Space_Refusal.None)
	}
	held := space_of(store, space)
	testing.expect_value(t, held.count, u32(2))
	testing.expect_value(t, held.removed, u64(3))
	reader := principal_reader(0, "console")
	heads: [4]Kept_Record_Head
	bytes: [32]u8
	count, refusal := records_read(store, space, -1, SPACE_RECORDS_MOST, &reader, heads[:], bytes[:])
	testing.expect_value(t, refusal, Space_Refusal.None)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, heads[0].serial, i64(3))
	testing.expect_value(t, heads[1].serial, i64(4))
	testing.expect_value(t, bytes[0], u8(3))
	testing.expect_value(t, bytes[8], u8(4))
	refusal, _ = space_verify(store, space)
	testing.expect_value(t, refusal, Space_Refusal.Bad_Kind)
}

@(test)
a_forwarded_record_is_kept_first_and_a_full_queue_holds_the_writer :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 0)
	defer free(memory)
	space, _ := space_open(store, text("shop"), text("orders"), keep_terms(SPACE_RECORDS_MOST, 8, .Forward))
	_, refusal := forward_peek(store)
	testing.expect_value(t, refusal, Space_Refusal.Forward_Empty)
	testing.expect_value(t, forward_done(store), Space_Refusal.Forward_Empty)

	for value in u8(0) ..< FORWARD_QUEUE_PER_SPACE_LIMIT {
		record := record_of(value)
		serial, append_refusal := record_append(store, space, record[:], 1)
		testing.expect_value(t, append_refusal, Space_Refusal.None)
		item, peek_refusal := forward_peek(store)
		testing.expect_value(t, peek_refusal, Space_Refusal.None)
		testing.expect_value(t, item.serial, u64(0))
		_ = serial
	}
	held := space_of(store, space)
	kept_before := held.count
	record := record_of(99)
	_, refusal = record_append(store, space, record[:], 1)
	testing.expect_value(t, refusal, Space_Refusal.Forward_Full)
	testing.expect_value(t, held.count, kept_before)
	testing.expect_value(t, held.next_serial, u64(FORWARD_QUEUE_PER_SPACE_LIMIT))

	for expected in u64(0) ..< FORWARD_QUEUE_PER_SPACE_LIMIT {
		item, peek_refusal := forward_peek(store)
		testing.expect_value(t, peek_refusal, Space_Refusal.None)
		testing.expect_value(t, item.serial, expected)
		testing.expect_value(t, item.bytes[0], u8(expected))
		testing.expect_value(t, forward_done(store), Space_Refusal.None)
	}
	testing.expect_value(t, held.forwarded, u64(FORWARD_QUEUE_PER_SPACE_LIMIT))
	serial, after_refusal := record_append(store, space, record[:], 1)
	testing.expect_value(t, after_refusal, Space_Refusal.None)
	testing.expect_value(t, serial, u64(FORWARD_QUEUE_PER_SPACE_LIMIT))
}

@(test)
a_space_that_keeps_only_forwards_nothing :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 0)
	defer free(memory)
	space, _ := space_open(store, text("server"), text("log"), audit_terms(4))
	record := record_of(1)
	_, refusal := record_append(store, space, record[:], 1)
	testing.expect_value(t, refusal, Space_Refusal.None)
	_, refusal = forward_peek(store)
	testing.expect_value(t, refusal, Space_Refusal.Forward_Empty)
}

@(test)
records_read_serves_the_principal_and_never_the_source :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 3)
	defer free(memory)
	space, _ := space_open(store, text("server"), text("orders"), audit_terms(4))
	for value in u8(0) ..< 3 {
		record := record_of(value)
		record_append(store, space, record[:], u64(10 + value))
	}
	heads: [4]Kept_Record_Head
	bytes: [32]u8

	not_acting := principal_reader(3, "console")
	not_acting.acts_for_principal = false
	other := principal_reader(4, "console")
	source := principal_reader(3, "server")
	readers := [?]struct {
		reader:  Space_Reader,
		refusal: Space_Refusal,
	}{
		{not_acting, .Not_Principal},
		{other, .Not_Principal},
		{source, .Own_Space},
	}
	for item in readers {
		reader := item.reader
		count, refusal := records_read(store, space, -1, SPACE_RECORDS_MOST, &reader, heads[:], bytes[:])
		testing.expect_value(t, refusal, item.refusal)
		testing.expect_value(t, count, 0)
	}
	_, refusal := records_read(store, space, -1, SPACE_RECORDS_MOST, nil, heads[:], bytes[:])
	testing.expect_value(t, refusal, Space_Refusal.Not_Principal)
	testing.expect(t, heads == {}, "a refused reader receives no head")

	reader := principal_reader(3, "console")
	count: int
	count, refusal = records_read(store, space, 0, SPACE_RECORDS_MOST, &reader, heads[:], bytes[:])
	testing.expect_value(t, refusal, Space_Refusal.None)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, heads[0].serial, i64(1))
	testing.expect_value(t, heads[0].time_ms, i64(11))
	testing.expect_value(t, heads[0].size, i64(8))

	count, refusal = records_read(store, space, 2, SPACE_RECORDS_MOST, &reader, heads[:], bytes[:])
	testing.expect_value(t, count, 0)
	count, refusal = records_read(store, space, max(i64), SPACE_RECORDS_MOST, &reader, heads[:], bytes[:])
	testing.expect_value(t, count, 0)

	// The count of the full answer passes what the places hold.
	small_heads: [1]Kept_Record_Head
	count, refusal = records_read(store, space, -1, SPACE_RECORDS_MOST, &reader, small_heads[:], bytes[:])
	testing.expect_value(t, count, 3)
	testing.expect_value(t, small_heads[0].serial, i64(0))
	small_bytes: [12]u8
	heads = {}
	count, refusal = records_read(store, space, -1, SPACE_RECORDS_MOST, &reader, heads[:], small_bytes[:])
	testing.expect_value(t, count, 3)
	testing.expect_value(t, heads[1].size, i64(0))

	_, refusal = records_read(store, 0, -1, SPACE_RECORDS_MOST, &reader, heads[:], bytes[:])
	testing.expect_value(t, refusal, Space_Refusal.Unknown_Space)
}

@(test)
space_verify_finds_a_changed_record_and_a_changed_last_link :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 0)
	defer free(memory)
	space, _ := space_open(store, text("server"), text("orders"), audit_terms(8))
	for value in u8(0) ..< 4 {
		record := record_of(value)
		record_append(store, space, record[:], u64(value))
	}
	refusal, failing := space_verify(store, space)
	testing.expect_value(t, refusal, Space_Refusal.None)

	held := space_of(store, space)
	held.ring.bytes[2 * SPACE_RECORD_BYTES_MOST] ~= 1
	refusal, failing = space_verify(store, space)
	testing.expect_value(t, refusal, Space_Refusal.Chain_Broken)
	testing.expect_value(t, failing, u64(2))
	held.ring.bytes[2 * SPACE_RECORD_BYTES_MOST] ~= 1

	held.ring.times[1] += 1
	refusal, failing = space_verify(store, space)
	testing.expect_value(t, refusal, Space_Refusal.Chain_Broken)
	testing.expect_value(t, failing, u64(1))
	held.ring.times[1] -= 1

	held.last_hash[0] ~= 1
	refusal, failing = space_verify(store, space)
	testing.expect_value(t, refusal, Space_Refusal.Chain_Broken)
	testing.expect_value(t, failing, u64(4))
	held.last_hash[0] ~= 1

	// A removal of the last record shows as a last link that is not the
	// last hash.
	held.count -= 1
	refusal, _ = space_verify(store, space)
	testing.expect_value(t, refusal, Space_Refusal.Chain_Broken)
	held.count += 1

	refusal, _ = space_verify(store, 0)
	testing.expect_value(t, refusal, Space_Refusal.Unknown_Space)
}

@(test)
space_forwarding_border_refuses_unknown_words :: proc(t: ^testing.T) {
	for word in ([?]u64{0, 3, max(u64)}) {
		_, ok := space_forwarding_of_word(word)
		testing.expectf(t, !ok, "the word %d names no forwarding", word)
	}
	forwarding, ok := space_forwarding_of_word(2)
	testing.expect(t, ok)
	testing.expect_value(t, forwarding, Space_Forwarding.Forward)
}

@(test)
space_rows_give_the_counts_of_each_space :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 0)
	defer free(memory)
	space, _ := space_open(store, text("server"), text("orders"), keep_terms(1))
	for value in u8(0) ..< 3 {
		record := record_of(value)
		record_append(store, space, record[:], 0)
	}
	row := space_row_of(space_of(store, space), space)
	testing.expect_value(t, row.space, i64(space))
	testing.expect_value(t, row.kept, i64(1))
	testing.expect_value(t, row.removed, i64(2))
	testing.expect_value(t, row.next_serial, i64(3))
	testing.expect_value(t, string(row.source[:6]), "server")
	testing.expect_value(t, kept_record_count(store), u64(1))
}

@(test)
records_read_refuses_each_limit_out_of_its_bound :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 0)
	defer free(memory)
	space, _ := space_open(store, text("server"), text("orders"), audit_terms(8))
	for value in u8(0) ..< 5 {
		record := record_of(value)
		record_append(store, space, record[:], u64(value))
	}
	reader := principal_reader(0, "console")
	heads: [8]Kept_Record_Head
	bytes: [64]u8
	for limit in ([?]int{min(int), -1, 0, SPACE_RECORDS_MOST + 1, max(int)}) {
		count, refusal := records_read(store, space, -1, limit, &reader, heads[:], bytes[:])
		testing.expectf(t, refusal == .Bad_Limit, "the limit %d was taken", limit)
		testing.expect_value(t, count, 0)
	}
	testing.expect(t, heads == {}, "a refused limit wrote a head")

	// A limit of 1 gives the oldest record after the serial, then the next.
	count, refusal := records_read(store, space, -1, 1, &reader, heads[:], bytes[:])
	testing.expect_value(t, refusal, Space_Refusal.None)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, heads[0].serial, i64(0))
	count, refusal = records_read(store, space, heads[0].serial, 2, &reader, heads[:], bytes[:])
	testing.expect_value(t, count, 2)
	testing.expect_value(t, heads[0].serial, i64(1))
	testing.expect_value(t, heads[1].serial, i64(2))
	count, refusal = records_read(store, space, -1, SPACE_RECORDS_MOST, &reader, heads[:], bytes[:])
	testing.expect_value(t, count, 5)
}

@(test)
space_rows_and_space_stats_hide_a_space_from_its_source :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 2)
	defer free(memory)
	server_space, _ := space_open(store, text("server"), text("orders"), audit_terms(4))
	shop_space, _ := space_open(store, text("shop"), text("orders"), audit_terms(4))
	record := record_of(7)
	record_append(store, server_space, record[:], 1)
	rows: [SPACE_CAPACITY]Space_Row

	not_acting := principal_reader(2, "console")
	not_acting.acts_for_principal = false
	other := principal_reader(3, "console")
	for item in ([?]Space_Reader{not_acting, other}) {
		reader := item
		count, refusal := space_rows(store, &reader, rows[:])
		testing.expect_value(t, refusal, Space_Refusal.Not_Principal)
		testing.expect_value(t, count, 0)
		_, refusal = space_stats(store, server_space, &reader)
		testing.expect_value(t, refusal, Space_Refusal.Not_Principal)
	}
	count, refusal := space_rows(store, nil, rows[:])
	testing.expect_value(t, refusal, Space_Refusal.Not_Principal)
	testing.expect(t, rows == {}, "a refused reader received a row")

	// The source sees the spaces of the others, never its own.
	source := principal_reader(2, "server")
	count, refusal = space_rows(store, &source, rows[:])
	testing.expect_value(t, refusal, Space_Refusal.None)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, rows[0].space, i64(shop_space))
	row: Space_Row
	row, refusal = space_stats(store, server_space, &source)
	testing.expect_value(t, refusal, Space_Refusal.Own_Space)
	testing.expect(t, row == {}, "a refused stats gave a row")

	console := principal_reader(2, "console")
	count, refusal = space_rows(store, &console, rows[:])
	testing.expect_value(t, count, 2)
	// The count of the full answer passes what the rows hold.
	count, refusal = space_rows(store, &console, rows[:0])
	testing.expect_value(t, count, 2)
	row, refusal = space_stats(store, server_space, &console)
	testing.expect_value(t, refusal, Space_Refusal.None)
	testing.expect_value(t, row.kept, i64(1))
	testing.expect_value(t, row.next_serial, i64(1))
	for number in ([?]u32{0, SPACE_CAPACITY, SPACE_CAPACITY + 1, max(u32)}) {
		_, refusal = space_stats(store, number, &console)
		testing.expectf(t, refusal == .Unknown_Space, "the space %d gave a row", number)
	}
}

@(test)
space_open_allowed_refuses_the_source_and_a_stranger :: proc(t: ^testing.T) {
	store := new(Space_Store)
	defer free(store)
	memory := memory_store_bind(store, 5)
	defer free(memory)
	source := principal_reader(5, "server")
	testing.expect_value(t, space_open_allowed(store, text("server"), &source), Space_Refusal.Own_Space)
	testing.expect_value(t, space_open_allowed(store, text("shop"), &source), Space_Refusal.None)
	stranger := principal_reader(6, "console")
	testing.expect_value(t, space_open_allowed(store, text("server"), &stranger), Space_Refusal.Not_Principal)
	testing.expect_value(t, space_open_allowed(store, text("server"), nil), Space_Refusal.Not_Principal)
	// A name one byte longer than the source is another process.
	longer := principal_reader(5, "server2")
	testing.expect_value(t, space_open_allowed(store, text("server"), &longer), Space_Refusal.None)
}
