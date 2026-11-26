#+build !freestanding
#+build !modus
package system

import "core:sync"
import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/output"
import "modus:contract/ring"

// Serializes host seam tests because stream_ends and wiring_ring are
// package-level state shared across the parallel Odin test runner threads.
@(private = "file")
host_stream_seam_mutex: sync.Mutex

// Small fixed-layout record written through output_write in the host seam tests.
@(private = "file")
Gap_Test_Record :: struct {
	sequence: u64,
	tag:      u64,
}

// Host-allocated backing memory for one seeded writer ring and its end page.
@(private = "file")
Host_Output_Ring :: struct {
	ring_memory: []u64,
	ring_pages:  u64,
	end_words:   ^output.End_Words,
}

@(private = "file")
host_output_ring_make :: proc(t: ^testing.T, record_size: u32, capacity: u32 = ring.CAPACITY) -> (allocated: Host_Output_Ring) {
	comp_size := output.compartment_size(record_size)
	testing.expect(t, comp_size != 0)
	pages := ring.compartment_pages(capacity, comp_size)
	testing.expect(t, pages > 0)
	allocated.ring_memory = make([]u64, int(pages) * ring.PAGE_SIZE / size_of(u64))
	allocated.ring_pages = pages
	allocated.end_words = new(output.End_Words)
	return allocated
}

@(private = "file")
host_output_ring_destroy :: proc(allocated: ^Host_Output_Ring) {
	delete(allocated.ring_memory)
	free(allocated.end_words)
	allocated^ = {}
}

// The places of the table of the ends in a host test: from the start, and
// at most.
@(private = "file")
HOST_STREAM_ENDS_FIRST :: 16
@(private = "file")
HOST_STREAM_ENDS_MOST :: 64

// The table of the ends has no count: past 16, a 17th place and up to 64
// grow it, one at a time, at the same address, each new place free; with
// the budget at 64 places, a 65th is refused and nothing changes; a place
// that frees is taken again with no growth.
@(test)
the_table_of_the_ends_grows_with_the_budget :: proc(t: ^testing.T) {
	wiring_memory := host_stream_seam_begin(t)
	defer host_stream_seam_end(wiring_memory)
	base := raw_data(stream_ends)
	for &end in stream_ends {
		end.command = .Reader_End
	}
	for count in HOST_STREAM_ENDS_FIRST + 1 ..= HOST_STREAM_ENDS_MOST {
		place := stream_end_free_place()
		testing.expectf(t, place != nil, "the place %d is not given", count)
		if place == nil {
			return
		}
		testing.expect_value(t, place.command, output.Wiring_Command.None)
		place.command = .Reader_End
		testing.expect_value(t, len(stream_ends), count)
		testing.expect_value(t, len(closed_tags), count)
		testing.expect(t, raw_data(stream_ends) == base, "the table moved")
	}
	testing.expect(t, stream_end_free_place() == nil, "a place past the budget is given")
	testing.expect_value(t, len(stream_ends), HOST_STREAM_ENDS_MOST)
	stream_ends[40].command = .None
	testing.expect(t, stream_end_free_place() == &stream_ends[40], "a free place is not taken again")
	testing.expect_value(t, len(stream_ends), HOST_STREAM_ENDS_MOST)
}

// Resets all package-level stream_ends state and attaches an empty host wiring
// ring so Closed completions sent by stream_end_finish can be inspected.
@(private = "file")
host_stream_seam_begin :: proc(t: ^testing.T) -> (wiring_memory: []u64) {
	sync.mutex_lock(&host_stream_seam_mutex)
	// The table of the ends in host memory: 16 places from the start, as a
	// test that seeds a place needs, and room to grow to 64.
	stream_ends_host_backing = make([]Stream_End, HOST_STREAM_ENDS_MOST)
	closed_tags_host_backing = make([]u32, HOST_STREAM_ENDS_MOST)
	stream_ends_host_paid = HOST_STREAM_ENDS_MOST
	stream_end_table = {count = HOST_STREAM_ENDS_FIRST}
	stream_ends = stream_ends_host_backing[:HOST_STREAM_ENDS_FIRST]
	closed_tags = closed_tags_host_backing[:HOST_STREAM_ENDS_FIRST]
	closed_tag_count = 0
	wiring_ring = {}
	wiring_memory = make([]u64, ring.PAGE_COUNT * ring.PAGE_SIZE / size_of(u64))
	opened, ok := ring.open(raw_data(wiring_memory), ring.PAGE_COUNT)
	testing.expect(t, ok)
	wiring_ring = opened
	stream_ends_host_seam_active = true
	return wiring_memory
}

@(private = "file")
host_stream_seam_end :: proc(wiring_memory: []u64) {
	stream_ends_host_seam_active = false
	stream_ends = nil
	closed_tags = nil
	closed_tag_count = 0
	stream_end_table = {}
	delete(stream_ends_host_backing)
	delete(closed_tags_host_backing)
	stream_ends_host_backing, closed_tags_host_backing, stream_ends_host_paid = nil, nil, 0
	wiring_ring = {}
	sync.mutex_unlock(&host_stream_seam_mutex)
	delete(wiring_memory)
}

// Seeds one opened Writer_End into stream_ends[slot], optionally pre-filled
// (full queue) and with a pre-seeded gap count.
@(private = "file")
host_seed_writer_end :: proc(
	t: ^testing.T,
	slot: int,
	backing: ^Host_Output_Ring,
	stream_index: u32,
	tag: u32,
	record_size: u32,
	pace: output.Wiring_Pace,
	full: bool,
	joined: bool,
	gap_count: u32 = 0,
	gap_first: u32 = 0,
	condition_given: bool = false,
	condition: output.Checked_Condition = {},
) {
	comp_size := output.compartment_size(record_size)
	opened, ok := ring.compartment_open(raw_data(backing.ring_memory), backing.ring_pages, comp_size)
	testing.expect(t, ok)
	if full {
		// Fill the command queue so ring_room reports Refuses (for Never_Holds_Writer)
		// or Holds (for Writer_Chooses / Always_Holds_Writer).
		capacity := ring.compartment_capacity(&opened.commands)
		opened.commands.counters.write = capacity
		opened.commands.counters.read = 0
	}
	stream_ends[slot] = Stream_End {
		command         = .Writer_End,
		tag             = tag,
		index           = stream_index,
		pace            = pace,
		ring_address    = raw_data(backing.ring_memory),
		ring_pages      = backing.ring_pages,
		queue           = opened,
		opened          = true,
		end_words       = backing.end_words,
		joined          = joined,
		gap_count       = gap_count,
		gap_first       = gap_first,
		condition_given = condition_given,
		condition       = condition,
	}
}

// Pops one compartment from a healthy host ring and decodes its compartment
// word and record payload.
@(private = "file")
host_pop_record :: proc(t: ^testing.T, backing: ^Host_Output_Ring, record_size: u32) -> (kind: output.Compartment_Kind, serial: u32, rec: Gap_Test_Record, ok: bool) {
	comp_size := output.compartment_size(record_size)
	opened, opened_ok := ring.compartment_open(raw_data(backing.ring_memory), backing.ring_pages, comp_size)
	testing.expect(t, opened_ok)
	buf: [output.COMPARTMENT_SIZE_MOST]u8
	popped := ring.compartment_pop(&opened.commands, buf[:comp_size])
	if !popped {
		return {}, 0, {}, false
	}
	word := (^output.Compartment_Word)(raw_data(buf[:]))^
	decoded_kind, kind_ok := output.compartment_kind_of_word(word.kind)
	testing.expect(t, kind_ok)
	if decoded_kind == .Record {
		rec = (^Gap_Test_Record)(&buf[size_of(output.Compartment_Word)])^
	}
	return decoded_kind, word.serial, rec, true
}

// Edge test: gap == bound - 1 increments to bound and stays open; next write
// (gap == bound -> bound + 1) closes the stalled ring, increments
// rings_past_gap by 1, emits Closed on the wiring ring, and still delivers the
// exact record to its sibling healthy ring.
@(test)
output_write_gap_at_bound_and_past_bound :: proc(t: ^testing.T) {
	wiring_mem := host_stream_seam_begin(t)
	defer host_stream_seam_end(wiring_mem)

	stalled := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&stalled)
	healthy := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&healthy)

	STREAM_INDEX :: u32(3)
	STALLED_TAG :: u32(101)
	HEALTHY_TAG :: u32(102)
	BOUND := output.gap_count_most(false)

	// Seed stalled ring one step below its largest gap count.
	host_seed_writer_end(t, 0, &stalled, STREAM_INDEX, STALLED_TAG, size_of(Gap_Test_Record), .Never_Holds_Writer, full = true, joined = true, gap_count = BOUND - 1, gap_first = 10)
	host_seed_writer_end(t, 1, &healthy, STREAM_INDEX, HEALTHY_TAG, size_of(Gap_Test_Record), .Writer_Chooses, full = false, joined = false)

	stream: Record_Output(Gap_Test_Record)
	stream.index = STREAM_INDEX
	stream.next_serial = 500

	// Write 1: gap advances from bound - 1 to bound; ring stays open.
	first_rec := Gap_Test_Record{sequence = 1, tag = 0xAABB_CCDD}
	status1 := output_write(&stream, first_rec, wait = false)
	testing.expect_value(t, status1, output.Stream_Status.Ok)
	testing.expect_value(t, stream_ends[0].command, output.Wiring_Command.Writer_End)
	testing.expect_value(t, stream_ends[0].gap_count, BOUND)
	testing.expect_value(t, stream_ends[0].gap_first, u32(10))
	testing.expect_value(t, stream.rings_past_gap, u64(0))
	testing.expect_value(t, stream.written, u64(1))
	testing.expect_value(t, stream.next_serial, u32(501))
	testing.expect(t, ring.empty(&wiring_ring.completions), "no ring should close at gap == bound")

	// Healthy sibling received Joined(500) then Record(500, first_rec).
	k0, s0, _, ok0 := host_pop_record(t, &healthy, size_of(Gap_Test_Record))
	testing.expect(t, ok0)
	testing.expect_value(t, k0, output.Compartment_Kind.Joined)
	testing.expect_value(t, s0, u32(500))
	k1, s1, r1, ok1 := host_pop_record(t, &healthy, size_of(Gap_Test_Record))
	testing.expect(t, ok1)
	testing.expect_value(t, k1, output.Compartment_Kind.Record)
	testing.expect_value(t, s1, u32(500))
	testing.expect_value(t, r1, first_rec)

	// Write 2: gap is now at bound; refusing one more record closes the stalled
	// ring, increments rings_past_gap by 1, sends Closed for STALLED_TAG, and
	// still delivers the exact second record to the sibling healthy ring.
	second_rec := Gap_Test_Record{sequence = 2, tag = 0x1122_3344}
	status2 := output_write(&stream, second_rec, wait = false)
	testing.expect_value(t, status2, output.Stream_Status.Ok)
	testing.expect_value(t, stream_ends[0].command, output.Wiring_Command.None)
	testing.expect_value(t, stream_ends[1].command, output.Wiring_Command.Writer_End)
	testing.expect_value(t, stream.rings_past_gap, u64(1))
	testing.expect_value(t, stream.written, u64(2))
	testing.expect_value(t, stream.discarded, u64(0))
	testing.expect_value(t, stream.next_serial, u32(502))

	// Verify Closed completion on wiring ring names STALLED_TAG through its border.
	completion, got_closed := ring.pop(&wiring_ring.completions)
	testing.expect(t, got_closed)
	comp_status, comp_tag, comp_answer, _, comp_ok := output.wiring_completion_of_record(completion)
	testing.expect(t, comp_ok)
	testing.expect_value(t, comp_status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, comp_tag, STALLED_TAG)
	testing.expect_value(t, comp_answer, output.Wiring_Answer.Closed)

	// Verify sibling healthy ring received the exact second record.
	k2, s2, r2, ok2 := host_pop_record(t, &healthy, size_of(Gap_Test_Record))
	testing.expect(t, ok2)
	testing.expect_value(t, k2, output.Compartment_Kind.Record)
	testing.expect_value(t, s2, u32(501))
	testing.expect_value(t, r2, second_rec)

	// Write 3 publishes updated rings_past_gap == 1 in healthy ring's Writer_Counts.
	third_rec := Gap_Test_Record{sequence = 3, tag = 0x5566_7788}
	status3 := output_write(&stream, third_rec, wait = false)
	testing.expect_value(t, status3, output.Stream_Status.Ok)
	published := output.writer_counts_read(raw_data(healthy.ring_memory))
	testing.expect_value(t, published.rings_past_gap, u64(1))
	testing.expect_value(t, published.written, u64(2))
}

// Multiple stalled rings at bound alongside one stalled ring at bound - 1 and
// two healthy sibling rings: every ring past bound closes, rings_past_gap
// increments by the exact count of closed rings, the ring at bound - 1 stays
// open at bound, and both healthy siblings receive the exact record.
@(test)
output_write_multiple_stalled_rings_past_gap :: proc(t: ^testing.T) {
	wiring_mem := host_stream_seam_begin(t)
	defer host_stream_seam_end(wiring_mem)

	stalled_a := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&stalled_a)
	stalled_b := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&stalled_b)
	at_edge := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&at_edge)
	healthy_a := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&healthy_a)
	healthy_b := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&healthy_b)

	STREAM_INDEX :: u32(7)
	BOUND := output.gap_count_most(false)

	host_seed_writer_end(t, 0, &stalled_a, STREAM_INDEX, 201, size_of(Gap_Test_Record), .Never_Holds_Writer, full = true, joined = true, gap_count = BOUND, gap_first = 1)
	host_seed_writer_end(t, 1, &healthy_a, STREAM_INDEX, 202, size_of(Gap_Test_Record), .Writer_Chooses, full = false, joined = true)
	host_seed_writer_end(t, 2, &stalled_b, STREAM_INDEX, 203, size_of(Gap_Test_Record), .Never_Holds_Writer, full = true, joined = true, gap_count = BOUND, gap_first = 2)
	host_seed_writer_end(t, 3, &at_edge, STREAM_INDEX, 204, size_of(Gap_Test_Record), .Never_Holds_Writer, full = true, joined = true, gap_count = BOUND - 1, gap_first = 3)
	host_seed_writer_end(t, 4, &healthy_b, STREAM_INDEX, 205, size_of(Gap_Test_Record), .Always_Holds_Writer, full = false, joined = true)

	stream: Record_Output(Gap_Test_Record)
	stream.index = STREAM_INDEX
	stream.next_serial = 99

	rec := Gap_Test_Record{sequence = 42, tag = 0xDEAD_BEEF}
	status := output_write(&stream, rec, wait = false)
	testing.expect_value(t, status, output.Stream_Status.Ok)
	testing.expect_value(t, stream.rings_past_gap, u64(2))
	testing.expect_value(t, stream.written, u64(1))
	testing.expect_value(t, stream.discarded, u64(0))
	testing.expect_value(t, stream.next_serial, u32(100))

	// Both rings at bound closed; the bound - 1 ring moved to bound and stayed open.
	testing.expect_value(t, stream_ends[0].command, output.Wiring_Command.None)
	testing.expect_value(t, stream_ends[2].command, output.Wiring_Command.None)
	testing.expect_value(t, stream_ends[3].command, output.Wiring_Command.Writer_End)
	testing.expect_value(t, stream_ends[3].gap_count, BOUND)

	// Both healthy rings received the exact record with serial 99.
	for backing in ([2]^Host_Output_Ring{&healthy_a, &healthy_b}) {
		k, s, got, ok := host_pop_record(t, backing, size_of(Gap_Test_Record))
		testing.expect(t, ok)
		testing.expect_value(t, k, output.Compartment_Kind.Record)
		testing.expect_value(t, s, u32(99))
		testing.expect_value(t, got, rec)
	}

	// Wiring ring recorded Closed for 201 and 203 in order.
	c1, ok_c1 := ring.pop(&wiring_ring.completions)
	c2, ok_c2 := ring.pop(&wiring_ring.completions)
	testing.expect(t, ok_c1 && ok_c2)
	testing.expect_value(t, c1.tag, u32(201))
	testing.expect_value(t, c2.tag, u32(203))
	testing.expect(t, ring.empty(&wiring_ring.completions))
}

// When every ring of a record output is stalled at its gap bound, each ring
// closes, rings_past_gap counts each one, the record counts as discarded (no
// ring took it), and the following write reports No_Reader.
@(test)
output_write_all_rings_past_gap_counts_discarded :: proc(t: ^testing.T) {
	wiring_mem := host_stream_seam_begin(t)
	defer host_stream_seam_end(wiring_mem)

	stalled_a := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&stalled_a)
	stalled_b := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&stalled_b)

	STREAM_INDEX :: u32(4)
	BOUND := output.gap_count_most(false)

	host_seed_writer_end(t, 0, &stalled_a, STREAM_INDEX, 301, size_of(Gap_Test_Record), .Never_Holds_Writer, full = true, joined = true, gap_count = BOUND, gap_first = 0)
	host_seed_writer_end(t, 1, &stalled_b, STREAM_INDEX, 302, size_of(Gap_Test_Record), .Never_Holds_Writer, full = true, joined = true, gap_count = BOUND, gap_first = 0)

	stream: Record_Output(Gap_Test_Record)
	stream.index = STREAM_INDEX
	stream.next_serial = 12

	status1 := output_write(&stream, Gap_Test_Record{sequence = 1, tag = 7}, wait = false)
	testing.expect_value(t, status1, output.Stream_Status.Ok)
	testing.expect_value(t, stream.rings_past_gap, u64(2))
	testing.expect_value(t, stream.written, u64(0))
	testing.expect_value(t, stream.discarded, u64(1))
	testing.expect_value(t, stream.next_serial, u32(13))

	// No live reader remains on the next write.
	status2 := output_write(&stream, Gap_Test_Record{sequence = 2, tag = 8}, wait = false)
	testing.expect_value(t, status2, output.Stream_Status.No_Reader)
	testing.expect_value(t, stream.discarded, u64(2))
	testing.expect_value(t, stream.next_serial, u32(14))
}

// Filtered ring uses the narrower gap bound (SERIAL_FORWARD_MOST - 1). A
// record that fails the filter is skipped without closing the ring even at
// bound, while a matching record at bound closes the ring and increments
// rings_past_gap without disturbing the healthy sibling.
@(test)
output_write_filtered_ring_gap_bound :: proc(t: ^testing.T) {
	wiring_mem := host_stream_seam_begin(t)
	defer host_stream_seam_end(wiring_mem)

	filtered := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&filtered)
	healthy := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&healthy)

	STREAM_INDEX :: u32(5)
	FILTERED_BOUND := output.gap_count_most(true)
	testing.expect_value(t, FILTERED_BOUND, output.SERIAL_FORWARD_MOST - 1)

	// Condition: sequence == 100 (offset 0, size 8, Unsigned, Equal).
	cond := output.Checked_Condition {
		offset     = u32(offset_of(Gap_Test_Record, sequence)),
		size       = size_of(u64),
		field_type = .Unsigned,
		comparison = .Equal,
		integer    = 100,
	}

	host_seed_writer_end(t, 0, &filtered, STREAM_INDEX, 401, size_of(Gap_Test_Record), .Never_Holds_Writer, full = true, joined = true, gap_count = FILTERED_BOUND - 1, gap_first = 1, condition_given = true, condition = cond)
	host_seed_writer_end(t, 1, &healthy, STREAM_INDEX, 402, size_of(Gap_Test_Record), .Writer_Chooses, full = false, joined = true)

	stream: Record_Output(Gap_Test_Record)
	stream.index = STREAM_INDEX
	stream.next_serial = 70

	// Matching record advances gap from FILTERED_BOUND - 1 to FILTERED_BOUND; stays open.
	match_a := Gap_Test_Record{sequence = 100, tag = 1}
	testing.expect_value(t, output_write(&stream, match_a, wait = false), output.Stream_Status.Ok)
	testing.expect_value(t, stream_ends[0].command, output.Wiring_Command.Writer_End)
	testing.expect_value(t, stream_ends[0].gap_count, FILTERED_BOUND)
	testing.expect_value(t, stream.rings_past_gap, u64(0))

	// Non-matching record is skipped by the filtered ring even at FILTERED_BOUND.
	skip_rec := Gap_Test_Record{sequence = 999, tag = 2}
	testing.expect_value(t, output_write(&stream, skip_rec, wait = false), output.Stream_Status.Ok)
	testing.expect_value(t, stream_ends[0].command, output.Wiring_Command.Writer_End)
	testing.expect_value(t, stream_ends[0].gap_count, FILTERED_BOUND)
	testing.expect_value(t, stream.rings_past_gap, u64(0))

	// Matching record at FILTERED_BOUND closes the filtered ring; healthy sibling gets all three.
	match_b := Gap_Test_Record{sequence = 100, tag = 3}
	testing.expect_value(t, output_write(&stream, match_b, wait = false), output.Stream_Status.Ok)
	testing.expect_value(t, stream_ends[0].command, output.Wiring_Command.None)
	testing.expect_value(t, stream.rings_past_gap, u64(1))

	expected := [3]Gap_Test_Record{match_a, skip_rec, match_b}
	for want, idx in expected {
		k, s, got, ok := host_pop_record(t, &healthy, size_of(Gap_Test_Record))
		testing.expect(t, ok)
		testing.expect_value(t, k, output.Compartment_Kind.Record)
		testing.expect_value(t, s, u32(70 + idx))
		testing.expect_value(t, got, want)
	}
}

// A record output Paired: a write of one pair reaches the rings of that
// pair only, whatever their sizes. Refused first: pair 0 and a pair with
// no ring, with no record in any ring; then a full ring of one pair gives
// Full and leaves the other pair writable; the end of one pair ends its
// ring alone, and the record output goes on.
@(test)
a_write_of_a_pair_reaches_the_rings_of_that_pair_only :: proc(t: ^testing.T) {
	wiring_mem := host_stream_seam_begin(t)
	defer host_stream_seam_end(wiring_mem)
	STREAM_INDEX :: u32(1)
	Large_Record :: struct {
		first:  Gap_Test_Record,
		second: Gap_Test_Record,
	}
	ring_small := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&ring_small)
	ring_large := host_output_ring_make(t, size_of(Large_Record))
	defer host_output_ring_destroy(&ring_large)
	host_seed_writer_end(t, 0, &ring_small, STREAM_INDEX, 11, size_of(Gap_Test_Record), .Writer_Chooses, full = false, joined = false)
	stream_ends[0].pair = 5
	host_seed_writer_end(t, 1, &ring_large, STREAM_INDEX, 12, size_of(Large_Record), .Writer_Chooses, full = false, joined = false)
	stream_ends[1].pair = 6
	forward: Record_Output(Any_Record, .Paired)
	forward.state.index = STREAM_INDEX

	small := Gap_Test_Record{sequence = 1, tag = 5}
	small_bytes := transmute([size_of(Gap_Test_Record)]u8)small
	testing.expect_value(t, output_write_pair(&forward, 0, small_bytes[:], wait = false), output.Stream_Status.Bad_Record)
	testing.expect_value(t, output_write_pair(&forward, 7, small_bytes[:], wait = false), output.Stream_Status.No_Reader)
	testing.expect_value(t, output_pair_rings(&forward, 7, size_of(Gap_Test_Record)), 0)
	testing.expect_value(t, output_pair_rings(&forward, 0, size_of(Gap_Test_Record)), 0)
	_, _, _, small_empty := host_pop_record(t, &ring_small, size_of(Gap_Test_Record))
	testing.expect(t, !small_empty)

	// The record of pair 5: the joined record, then the record, in its
	// ring alone. The write with no ring moved the serial.
	testing.expect_value(t, output_write_pair(&forward, 5, small_bytes[:], wait = false), output.Stream_Status.Ok)
	kind, serial, got, ok := host_pop_record(t, &ring_small, size_of(Gap_Test_Record))
	testing.expect(t, ok && kind == .Joined)
	testing.expect_value(t, serial, u32(1))
	kind, serial, got, ok = host_pop_record(t, &ring_small, size_of(Gap_Test_Record))
	testing.expect(t, ok && kind == .Record)
	testing.expect_value(t, serial, u32(1))
	testing.expect_value(t, got, small)
	_, _, _, large_empty := host_pop_record(t, &ring_large, size_of(Large_Record))
	testing.expect(t, !large_empty)

	// The ring of pair 5 is full: Full, and pair 6 still takes its record.
	small_queue := &stream_ends[0].queue.commands
	small_queue.counters.write = small_queue.counters.read + ring.compartment_capacity(small_queue)
	testing.expect_value(t, output_write_pair(&forward, 5, small_bytes[:], wait = false), output.Stream_Status.Full)
	large := Large_Record{first = {sequence = 2, tag = 6}, second = {sequence = 3, tag = 6}}
	large_bytes := transmute([size_of(Large_Record)]u8)large
	testing.expect_value(t, output_write_pair(&forward, 6, large_bytes[:], wait = false), output.Stream_Status.Ok)
	kind, _, _, ok = host_pop_record(t, &ring_large, size_of(Large_Record))
	testing.expect(t, ok && kind == .Joined)
	kind, _, _, ok = host_pop_record(t, &ring_large, size_of(Large_Record))
	testing.expect(t, ok && kind == .Record)

	// The end of pair 6: its end record and the close of its end, with its
	// word Closed; pair 5 keeps its ring, and the record output goes on.
	testing.expect_value(t, output_end_pair(&forward, 6, size_of(Large_Record)), output.Stream_Status.Ok)
	kind, _, _, ok = host_pop_record(t, &ring_large, size_of(Large_Record))
	testing.expect(t, ok && kind == .End)
	testing.expect_value(t, stream_ends[1].command, output.Wiring_Command.None)
	testing.expect_value(t, stream_ends[0].command, output.Wiring_Command.Writer_End)
	testing.expect(t, !forward.state.ended)
	closed, closed_ok := ring.pop(&wiring_ring.completions)
	testing.expect(t, closed_ok && closed.tag == 12)
	testing.expect_value(t, output_end_pair(&forward, 6, size_of(Large_Record)), output.Stream_Status.No_Reader)
}

// The pairs that a record output Paired holds, each once, then the close
// of one pair with no write: its end is free, its word Closed goes to the
// root service, and the other pair keeps its end. A pair of 0, and a pair
// with no end, close nothing.
@(test)
the_end_of_a_pair_with_no_source_closes_alone :: proc(t: ^testing.T) {
	wiring_mem := host_stream_seam_begin(t)
	defer host_stream_seam_end(wiring_mem)
	STREAM_INDEX :: u32(1)
	ring_one := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&ring_one)
	ring_two := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&ring_two)
	ring_three := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&ring_three)
	host_seed_writer_end(t, 0, &ring_one, STREAM_INDEX, 11, size_of(Gap_Test_Record), .Always_Holds_Writer, full = false, joined = false)
	stream_ends[0].pair = 5
	host_seed_writer_end(t, 1, &ring_two, STREAM_INDEX, 12, size_of(Gap_Test_Record), .Always_Holds_Writer, full = false, joined = false)
	stream_ends[1].pair = 6
	host_seed_writer_end(t, 2, &ring_three, STREAM_INDEX, 13, size_of(Gap_Test_Record), .Always_Holds_Writer, full = false, joined = false)
	stream_ends[2].pair = 5
	forward: Record_Output(Any_Record, .Paired)
	forward.state.index = STREAM_INDEX

	listed: [4]u32
	testing.expect_value(t, output_pairs(&forward, listed[:]), 2)
	testing.expect_value(t, listed[0], u32(5))
	testing.expect_value(t, listed[1], u32(6))
	small: [1]u32
	testing.expect_value(t, output_pairs(&forward, small[:]), 1)

	testing.expect_value(t, output_pair_close(&forward, 0), 0)
	testing.expect_value(t, output_pair_close(&forward, 7), 0)
	testing.expect_value(t, output_pair_close(&forward, 5), 2)
	testing.expect_value(t, stream_ends[0].command, output.Wiring_Command.None)
	testing.expect_value(t, stream_ends[2].command, output.Wiring_Command.None)
	testing.expect_value(t, stream_ends[1].command, output.Wiring_Command.Writer_End)
	for tag in ([2]u32{11, 13}) {
		closed, closed_ok := ring.pop(&wiring_ring.completions)
		testing.expect(t, closed_ok && closed.tag == tag)
	}
	testing.expect_value(t, output_pairs(&forward, listed[:]), 1)
	testing.expect_value(t, listed[0], u32(6))
}

// A record output By_Principal: a write of one principal reaches the rings
// of the readers of that principal only. Refused first: a principal past
// the field, and a write of a principal with no ring, with no record in any
// ring; a ring whose reader principal is not known takes no record of a
// principal; then the rings of one principal take it, and a live count
// sees each ring.
@(test)
a_write_of_a_principal_reaches_the_rings_of_that_principal_only :: proc(t: ^testing.T) {
	wiring_mem := host_stream_seam_begin(t)
	defer host_stream_seam_end(wiring_mem)
	STREAM_INDEX :: u32(1)
	ring_machine := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&ring_machine)
	ring_named := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&ring_named)
	ring_unknown := host_output_ring_make(t, size_of(Gap_Test_Record))
	defer host_output_ring_destroy(&ring_unknown)
	host_seed_writer_end(t, 0, &ring_machine, STREAM_INDEX, 11, size_of(Gap_Test_Record), .Writer_Chooses, full = false, joined = false)
	stream_ends[0].reader_principal = 0 + 1
	host_seed_writer_end(t, 1, &ring_named, STREAM_INDEX, 12, size_of(Gap_Test_Record), .Writer_Chooses, full = false, joined = false)
	stream_ends[1].reader_principal = 1 + 1
	host_seed_writer_end(t, 2, &ring_unknown, STREAM_INDEX, 13, size_of(Gap_Test_Record), .Writer_Chooses, full = false, joined = false)
	stream := Record_Output(Gap_Test_Record, .By_Principal){}
	stream.state.index = STREAM_INDEX

	record := Gap_Test_Record{sequence = 1, tag = 5}
	testing.expect_value(t, output_write_principal(&stream, output.READER_PRINCIPAL_LIMIT, record, wait = false), output.Stream_Status.Bad_Record)
	testing.expect_value(t, output_write_principal(&stream, max(u64), record, wait = false), output.Stream_Status.Bad_Record)
	testing.expect_value(t, output_write_principal(&stream, SCOPED_PRINCIPALS_MOST, record, wait = false), output.Stream_Status.Bad_Record)
	testing.expect_value(t, output_principal_rings(&stream, SCOPED_PRINCIPALS_MOST), 0)
	testing.expect_value(t, output_gap_principal(&stream, SCOPED_PRINCIPALS_MOST, 1), output.Stream_Status.Bad_Record)
	testing.expect(t, stream.state.scoped == {} && stream.state.counts == {}, "a refused write changed a count")
	// A principal with no ring: no reader.
	stream_ends[1].reader_principal = 0
	testing.expect_value(t, output_write_principal(&stream, 1, record, wait = false), output.Stream_Status.No_Reader)
	stream_ends[1].reader_principal = 1 + 1
	for backing in ([?]^Host_Output_Ring{&ring_machine, &ring_named, &ring_unknown}) {
		_, _, _, has := host_pop_record(t, backing, size_of(Gap_Test_Record))
		testing.expect(t, !has, "a refused write reached a ring")
	}

	// Principal 1: its ring alone.
	testing.expect_value(t, output_write_principal(&stream, 1, record, wait = false), output.Stream_Status.Ok)
	kind, _, _, ok := host_pop_record(t, &ring_named, size_of(Gap_Test_Record))
	testing.expect(t, ok && kind == .Joined)
	record_kind, _, got, record_ok := host_pop_record(t, &ring_named, size_of(Gap_Test_Record))
	testing.expect(t, record_ok && record_kind == .Record)
	testing.expect_value(t, got, record)
	_, _, _, machine_has := host_pop_record(t, &ring_machine, size_of(Gap_Test_Record))
	testing.expect(t, !machine_has, "the record of principal 1 reached principal 0")
	_, _, _, unknown_has := host_pop_record(t, &ring_unknown, size_of(Gap_Test_Record))
	testing.expect(t, !unknown_has, "the record of principal 1 reached a ring of no principal")

	// Principal 0: its ring alone.
	testing.expect_value(t, output_write_principal(&stream, 0, record, wait = false), output.Stream_Status.Ok)
	_, _, _, named_has := host_pop_record(t, &ring_named, size_of(Gap_Test_Record))
	testing.expect(t, !named_has, "the record of principal 0 reached principal 1")
	testing.expect_value(t, output_principal_rings(&stream, 0), 1)
	// Each principal has its own serials and counts: principal 0 reads the
	// serial 0 and no count of the two records of principal 1.
	_, _, _, _ = host_pop_record(t, &ring_machine, size_of(Gap_Test_Record))
	machine_kind, machine_serial, _, machine_ok := host_pop_record(t, &ring_machine, size_of(Gap_Test_Record))
	testing.expect(t, machine_ok && machine_kind == .Record)
	testing.expect_value(t, machine_serial, u32(0))
	testing.expect_value(t, stream.state.scoped[0].written, u64(1))
	testing.expect_value(t, stream.state.scoped[1].next_serial, u32(2))
	testing.expect(t, stream.state.counts == {}, "a write of a principal counted in the whole record output")
	// A loss of principal 1 reaches its ring only.
	testing.expect_value(t, output_gap_principal(&stream, 1, 3), output.Stream_Status.Ok)
	gap_kind, gap_serial, _, gap_ok := host_pop_record(t, &ring_named, size_of(Gap_Test_Record))
	testing.expect(t, gap_ok && gap_kind == .Gap)
	testing.expect_value(t, gap_serial, u32(2))
	_, _, _, machine_gap := host_pop_record(t, &ring_machine, size_of(Gap_Test_Record))
	testing.expect(t, !machine_gap, "a loss of principal 1 reached principal 0")
	testing.expect_value(t, stream.state.scoped[0].next_serial, u32(1))
	// A live count sees the ring of each principal.
	testing.expect_value(t, output_reader_count(&stream), 3)
	// Ending the output writes each principal's own serial in its end record,
	// never the serial of another principal or of the whole output.
	testing.expect_value(t, output_end(&stream, deadline = 0), output.Stream_Status.Ok)
	end_kind_m, end_serial_m, _, end_ok_m := host_pop_record(t, &ring_machine, size_of(Gap_Test_Record))
	testing.expect(t, end_ok_m && end_kind_m == .End)
	testing.expect_value(t, end_serial_m, u32(1))
	end_kind_n, end_serial_n, _, end_ok_n := host_pop_record(t, &ring_named, size_of(Gap_Test_Record))
	testing.expect(t, end_ok_n && end_kind_n == .End)
	testing.expect_value(t, end_serial_n, u32(5))
}
