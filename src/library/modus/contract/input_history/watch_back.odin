// The watch back over a history: which input point wrote some bytes last
// (src/md/features/record_and_replay.md, "The debugger: step back, and a
// watch back").
//
// An input history holds each byte that entered the process from outside:
// the changed ranges of its point copies and of its shared pages
// (Page_Delta), and the bytes that a kernel entry copied into its memory
// (Kernel_Completion). So the last input that wrote a variable is a scan of
// the history, with no replay. A write by an instruction of the process
// itself is not an input and is not in the history: only a replay with a
// data breakpoint finds it (watch_back_plan).
package input_history

import op "modus:contract/operation"

// The most bytes that one watch back covers: one page, the size of the
// largest range of a page delta.
WATCH_BACK_SIZE_LIMIT :: u64(4096)
// The written bytes that a match keeps, from its first watched byte.
WATCH_BACK_SHOWN_BYTES :: 8

// Why history_find_last_write found no match. None: it found one.
Watch_Back_Refusal :: enum u8 {
	None            = 0,
	Bad_Size        = 1, // The size is 0, or larger than WATCH_BACK_SIZE_LIMIT.
	Bad_Address     = 2, // The address is 0, or the range passes USER_END or wraps.
	Damaged_History = 3, // The header, a record, or the order of the input points is not valid.
	No_Write        = 4, // No input before the point wrote a byte of the range.
}

// The last input that wrote a byte of the watched range.
Watch_Back_Match :: struct {
	point_number:        u64, // The input point of the record that wrote.
	history_byte_offset: u64, // The bytes of records before that record, as a checkpoint counts them.
	kind:                History_Record_Kind, // Page_Delta or Kernel_Completion.
	instruction_address: u64, // The instruction of the thread at the point.
	stack_pointer:       u64, // The stack pointer of the thread at the point.
	written_address:     u64, // The first byte of the watched range that the record wrote.
	written_count:       u64, // The bytes of the watched range that the record wrote, in all its ranges.
	shown_count:         u32, // The bytes of shown_bytes that hold a value (1 ..= WATCH_BACK_SHOWN_BYTES).
	shown_bytes:         [WATCH_BACK_SHOWN_BYTES]u8, // The values written from written_address, while the run stays contiguous.
}

// The overlap of one written run with the watched range, and the written
// values from its first watched byte.
@(private = "file")
Run_Overlap :: struct {
	first:  u64, // The first watched byte that the run wrote.
	count:  u64, // The watched bytes that the run wrote.
	values: []u8, // The written values from first, count bytes.
}

// run_overlap compares one written run [run_start, run_start + len(run))
// with the watched range. The run comes from a record that passed the
// border, so it lies below USER_END and its end does not wrap.
@(private = "file")
run_overlap :: proc "contextless" (run_start: u64, run: []u8, watch_start, watch_end: u64) -> (overlap: Run_Overlap, ok: bool) {
	run_end := run_start + u64(len(run))
	if len(run) == 0 || run_start >= watch_end || watch_start >= run_end {
		return {}, false
	}
	first := max(run_start, watch_start)
	last := min(run_end, watch_end)
	skip := first - run_start
	return Run_Overlap{first = first, count = last - first, values = run[skip:skip + (last - first)]}, true
}

// match_take adds one overlapping run to the match of its record: the
// earliest watched byte gives the address and the shown values.
@(private = "file")
match_take :: proc "contextless" (match: ^Watch_Back_Match, overlap: Run_Overlap) {
	if match.written_count == 0 || overlap.first < match.written_address {
		match.written_address = overlap.first
		match.shown_count = u32(min(overlap.count, WATCH_BACK_SHOWN_BYTES))
		match.shown_bytes = {}
		copy(match.shown_bytes[:], overlap.values[:match.shown_count])
	}
	match.written_count += overlap.count
}

// page_delta_runs_overlap decodes the ranges of a page delta and adds each
// one that writes a watched byte to match. The bounds of each range are
// checked again, so that a payload that changed after its check can give a
// wrong answer but never a read outside the payload.
@(private = "file")
page_delta_runs_overlap :: proc "contextless" (payload: []u8, watch_start, watch_end: u64, match: ^Watch_Back_Match) -> (ok: bool) {
	if len(payload) < size_of(Page_Delta_Header) {
		return false
	}
	header: Page_Delta_Header
	copy(([^]u8)(&header)[:size_of(header)], payload[:size_of(header)])
	if header.virtual_address % HISTORY_PAGE_SIZE != 0 || header.virtual_address >= op.USER_END {
		return false
	}
	cursor := size_of(Page_Delta_Header)
	for _ in 0 ..< header.range_count {
		if len(payload) - cursor < size_of(Page_Delta_Range) {
			return false
		}
		entry: Page_Delta_Range
		copy(([^]u8)(&entry)[:size_of(entry)], payload[cursor:cursor + size_of(entry)])
		cursor += size_of(Page_Delta_Range)
		length := int(entry.length)
		if u64(entry.offset) + u64(length) > HISTORY_PAGE_SIZE || len(payload) - cursor < length {
			return false
		}
		run := payload[cursor:cursor + length]
		cursor += length
		if overlap, overlaps := run_overlap(header.virtual_address + u64(entry.offset), run, watch_start, watch_end); overlaps {
			match_take(match, overlap)
		}
	}
	return true
}

// history_find_last_write finds the last input point strictly before
// before_point (each point when before_point is 0) whose record wrote a byte
// of [address, address + size): a range of a Page_Delta, or the bytes that a
// Kernel_Completion copied into the process.
//
// The input points of a history only grow, so the scan keeps the last
// record that overlaps. It stops at the first record at or past
// before_point, after that record passed the border. A record that the scan
// reads and that fails the border, or a point that does not grow, refuses
// the whole history, because a scan that skips a record can name a write
// that a later one hid.
//
// The reader takes the header once: the kernel appends records past
// written_bytes only, so the records that the scan reads do not change.
history_find_last_write :: proc "contextless" (history_bytes: []u8, address: u64, size: u64, before_point: u64) -> (match: Watch_Back_Match, refusal: Watch_Back_Refusal) {
	if size == 0 || size > WATCH_BACK_SIZE_LIMIT {
		return {}, .Bad_Size
	}
	if address == 0 || address >= op.USER_END || size > op.USER_END - address {
		return {}, .Bad_Address
	}
	watch_end := address + size
	reader, opened := history_reader_open(history_bytes)
	if !opened {
		return {}, .Damaged_History
	}
	found := false
	previous_point := u64(0)
	for {
		record_offset := reader.read_offset
		record_header, kind, payload, has_more, ok := history_reader_next(&reader)
		if !ok {
			return {}, .Damaged_History
		}
		if !has_more {
			break
		}
		if record_header.point_number <= previous_point {
			return {}, .Damaged_History
		}
		previous_point = record_header.point_number
		if before_point != 0 && record_header.point_number >= before_point {
			break
		}
		candidate := Watch_Back_Match {
			point_number        = record_header.point_number,
			history_byte_offset = record_offset,
			kind                = kind,
			instruction_address = record_header.instruction_address,
			stack_pointer       = record_header.stack_pointer,
		}
		switch kind {
		case .Page_Delta:
			if !page_delta_runs_overlap(payload, address, watch_end, &candidate) {
				return {}, .Damaged_History
			}
		case .Kernel_Completion:
			entry, copied, decoded := kernel_completion_from_payload(payload)
			if !decoded {
				return {}, .Damaged_History
			}
			if entry.copied_bytes_count > 0 {
				if overlap, overlaps := run_overlap(entry.copied_user_address, copied, address, watch_end); overlaps {
					match_take(&candidate, overlap)
				}
			}
		case .None, .Cycle_Counter, .Processor_Identification, .History_End, .Shared_Mapping:
		}
		if candidate.written_count > 0 {
			match = candidate
			found = true
		}
	}
	if !found {
		return {}, .No_Write
	}
	return match, .None
}

// checkpoint_plan_for_target selects the newest checkpoint strictly before
// target_point and gives the input points that a replay runs from it to
// reach target_point. A checkpoint at the target point holds the state
// after its write, so it cannot show the write happen: the checkpoint must
// be earlier. With no such checkpoint the status is No_Prior_Checkpoint,
// and a replay starts at the first instruction.
checkpoint_plan_for_target :: proc "contextless" (checkpoints: ^Checkpoint_Ring, target_point: u64) -> Step_Back_Plan {
	if checkpoints == nil || checkpoints.capacity == 0 || checkpoints.capacity > CHECKPOINT_RING_CAPACITY || target_point == 0 {
		return {status = .Invalid_Request}
	}
	if checkpoints.head >= checkpoints.capacity || checkpoints.count > checkpoints.capacity {
		return {status = .Invalid_Request}
	}
	target := Replay_Position{point_number = target_point}
	chosen, found := checkpoint_ring_nearest_before(checkpoints, target)
	if !found {
		return {status = .No_Prior_Checkpoint, target_position = target, replay_points_to_advance = target_point}
	}
	return Step_Back_Plan {
		status                   = .Ok,
		checkpoint               = chosen,
		start_position           = chosen.position,
		target_position          = target,
		replay_points_to_advance = target_point - chosen.position.point_number,
		single_steps_after_point = 0,
		history_start_offset     = chosen.history_byte_offset,
	}
}
