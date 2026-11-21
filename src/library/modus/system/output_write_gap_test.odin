#+build !freestanding
package system

import "core:sync"
import "core:testing"
import op "modus:contract/operation"
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

// Resets all package-level stream_ends state and attaches an empty host wiring
// ring so Closed completions sent by stream_end_finish can be inspected.
@(private = "file")
host_stream_seam_begin :: proc(t: ^testing.T) -> (wiring_memory: []u64) {
	sync.mutex_lock(&host_stream_seam_mutex)
	stream_ends = {}
	closed_tags = {}
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
	stream_ends = {}
	closed_tags = {}
	closed_tag_count = 0
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
	testing.expect_value(t, comp_status, op.Status.Ok)
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
