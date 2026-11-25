// Freestanding debugger step-back, branch-count interrupt point, planted
// rdrand divergence comparator, and binary history codec
// (src/md/features/record_and_replay.md).
//
// Operates strictly in caller-supplied memory with zero allocator calls and
// zero host imports so both the freestanding debugger service and host
// `modustool replay` share one contract and border.
package replay_engine

import "base:intrinsics"
import "modus:contract/enum_word"

// Format property: magic number identifying a serialized replay history index ("MODREPL1").
REPLAY_HISTORY_MAGIC :: u64(0x4D4F_4452_4550_4C31)

// Format property: binary layout version for Replay_History_Header.
REPLAY_HISTORY_VERSION :: u32(1)

// Inline capacity: fixed checkpoint index table in caller memory.
REPLAY_CHECKPOINTS_MAX :: 64

// Inline capacity: fixed input point index table in caller memory.
REPLAY_INPUT_POINTS_MAX :: 1024

// Closed border refusal set for replay history construction, step-back, and comparison.
Replay_Refusal :: enum u8 {
	None                   = 0,
	Empty_History          = 1,
	Unknown_Input_Kind     = 2,
	Non_Monotonic_Point    = 3,
	Non_Monotonic_Branches = 4,
	Capacity_Exceeded      = 5,
	Checkpoint_Not_Found   = 6,
	Target_Out_Of_Range    = 7,
	Write_Not_Found        = 8,
	Divergence_Detected    = 9,
	Rdrand_Divergence      = 10,
	Bad_Watch_Range        = 11,
	Truncated_Record       = 12,
	Bad_Header             = 13,
	Buffer_Too_Small       = 14,
}

// Closed input point kind set. Zero names no valid input point.
Replay_Input_Kind :: enum u8 {
	None                      = 0,
	Syscall_Return            = 1,
	Interrupt_At_Branch_Count = 2,
	Planted_Rdrand_Divergence = 3,
	Memory_Write              = 4,
}

// Closed debugger step-back query modes.
Replay_Step_Back_Kind :: enum u8 {
	Instruction      = 1,
	Source_Line      = 2,
	Last_Watch_Write = 3,
}

// replay_input_kind_of_word is the one border converting a transport word into Replay_Input_Kind.
replay_input_kind_of_word :: proc "contextless" (word: u64) -> (kind: Replay_Input_Kind, ok: bool) {
	return enum_word.member_of_word(Replay_Input_Kind, word)
}

// replay_refusal_of_word is the one border converting a transport word into Replay_Refusal.
replay_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Replay_Refusal, ok: bool) {
	return enum_word.member_of_word(Replay_Refusal, word)
}

// replay_step_back_kind_of_word is the one border converting a transport word into Replay_Step_Back_Kind.
replay_step_back_kind_of_word :: proc "contextless" (word: u64) -> (kind: Replay_Step_Back_Kind, ok: bool) {
	return enum_word.member_of_word(Replay_Step_Back_Kind, word)
}

// Fixed-layout binary header for serialized replay history indexes (56 bytes, zero padding).
Replay_History_Header :: struct {
	magic:            u64,
	version:          u32,
	checkpoint_count: u32,
	point_count:      u32,
	reserved:         u32,
	module_hash:      [32]u8,
}
#assert(size_of(Replay_History_Header) == 56)

// Fixed-layout checkpoint record captured at a deterministic replay boundary (72 bytes).
Replay_Checkpoint :: struct {
	point_number:                 u64,
	retired_conditional_branches: u64,
	rip:                          u64,
	rsp:                          u64,
	source_line:                  u32,
	reserved:                     u32,
	memory_digest:                [32]u8,
}
#assert(size_of(Replay_Checkpoint) == 72)

// Fixed-layout input point record including branch count for interrupt placement (64 bytes).
// `kind` is a transport word decoded only through replay_input_kind_of_word.
Replay_Input_Point :: struct {
	point_number:                 u64,
	kind:                         u32,
	source_line:                  u32,
	retired_conditional_branches: u64,
	rip:                          u64,
	rsp:                          u64,
	rax:                          u64,
	write_address:                u64,
	write_size:                   u64,
}
#assert(size_of(Replay_Input_Point) == 64)

// Caller-owned replay index holding ordered checkpoints and input points.
Replay_History_Index :: struct {
	module_hash:      [32]u8,
	checkpoint_count: int,
	point_count:      int,
	checkpoints:      [REPLAY_CHECKPOINTS_MAX]Replay_Checkpoint,
	points:           [REPLAY_INPUT_POINTS_MAX]Replay_Input_Point,
}

// Step-back plan telling the debugger which checkpoint to restore and how many
// input points to replay forward to reach the target state.
Replay_Step_Back_Plan :: struct {
	checkpoint_index: int,
	checkpoint_point: u64,
	target_point:     u64,
	target_branches:  u64,
	target_rip:       u64,
	target_line:      u32,
	steps_to_replay:  u64,
}

// Live state observed during replay at one input point for comparison.
Replay_Observed_Step :: struct {
	point_number:                 u64,
	kind:                         Replay_Input_Kind,
	retired_conditional_branches: u64,
	rip:                          u64,
	rsp:                          u64,
	rax:                          u64,
}

// Result of comparing one recorded Replay_Input_Point against observed state.
Replay_Compare_Result :: struct {
	matched:           bool,
	refusal:           Replay_Refusal,
	point_number:      u64,
	expected_rip:      u64,
	actual_rip:        u64,
	expected_rsp:      u64,
	actual_rsp:        u64,
	expected_rax:      u64,
	actual_rax:        u64,
	expected_branches: u64,
	actual_branches:   u64,
}

// replay_history_init clears index and sets its recorded module hash.
replay_history_init :: proc "contextless" (index: ^Replay_History_Index, module_hash: [32]u8) {
	index^ = {}
	index.module_hash = module_hash
}

// replay_history_add_checkpoint appends a checkpoint in strictly increasing
// point_number order with non-decreasing retired_conditional_branches.
replay_history_add_checkpoint :: proc "contextless" (index: ^Replay_History_Index, cp: Replay_Checkpoint) -> Replay_Refusal {
	if index == nil {
		return .Empty_History
	}
	if cp.reserved != 0 {
		return .Bad_Header
	}
	if index.checkpoint_count >= REPLAY_CHECKPOINTS_MAX {
		return .Capacity_Exceeded
	}
	if index.checkpoint_count > 0 {
		prev := index.checkpoints[index.checkpoint_count - 1]
		if cp.point_number <= prev.point_number {
			return .Non_Monotonic_Point
		}
		if cp.retired_conditional_branches < prev.retired_conditional_branches {
			return .Non_Monotonic_Branches
		}
	}
	index.checkpoints[index.checkpoint_count] = cp
	index.checkpoint_count += 1
	return .None
}

// replay_history_add_point validates the input kind word and monotonic ordering
// before appending pt to index.
replay_history_add_point :: proc "contextless" (index: ^Replay_History_Index, pt: Replay_Input_Point) -> Replay_Refusal {
	if index == nil {
		return .Empty_History
	}
	kind, kind_ok := replay_input_kind_of_word(u64(pt.kind))
	if !kind_ok || kind == .None {
		return .Unknown_Input_Kind
	}
	if kind == .Memory_Write {
		if pt.write_size == 0 || pt.write_address > max(u64) - pt.write_size {
			return .Bad_Watch_Range
		}
	}
	if index.point_count >= REPLAY_INPUT_POINTS_MAX {
		return .Capacity_Exceeded
	}
	if index.point_count > 0 {
		prev := index.points[index.point_count - 1]
		if pt.point_number <= prev.point_number {
			return .Non_Monotonic_Point
		}
		if pt.retired_conditional_branches < prev.retired_conditional_branches {
			return .Non_Monotonic_Branches
		}
	}
	index.points[index.point_count] = pt
	index.point_count += 1
	return .None
}

// replay_find_checkpoint_before returns the newest checkpoint whose
// point_number is at or before target_point.
replay_find_checkpoint_before :: proc "contextless" (index: ^Replay_History_Index, target_point: u64) -> (cp_index: int, checkpoint: Replay_Checkpoint, refusal: Replay_Refusal) {
	if index == nil || index.checkpoint_count <= 0 {
		return -1, {}, .Checkpoint_Not_Found
	}
	best := -1
	for i in 0 ..< index.checkpoint_count {
		if index.checkpoints[i].point_number <= target_point {
			best = i
		} else {
			break
		}
	}
	if best < 0 {
		return -1, {}, .Checkpoint_Not_Found
	}
	return best, index.checkpoints[best], .None
}

// replay_ranges_overlap checks whether [a_addr, a_addr + a_size) and
// [b_addr, b_addr + b_size) share at least one byte without overflow.
@(private = "file")
replay_ranges_overlap :: proc "contextless" (a_addr, a_size, b_addr, b_size: u64) -> bool {
	if a_size == 0 || b_size == 0 {
		return false
	}
	if a_addr > max(u64) - a_size || b_addr > max(u64) - b_size {
		return false
	}
	a_end := a_addr + a_size
	b_end := b_addr + b_size
	return a_addr < b_end && b_addr < a_end
}

// replay_step_back_target computes the nearest checkpoint and target point for
// stepping back one instruction, one source line, or to the last write touching
// [watch_address, watch_address + watch_size) strictly before current_point.
replay_step_back_target :: proc "contextless" (
	index: ^Replay_History_Index,
	current_point: u64,
	step_kind: Replay_Step_Back_Kind,
	watch_address: u64 = 0,
	watch_size: u64 = 0,
) -> (
	plan: Replay_Step_Back_Plan,
	refusal: Replay_Refusal,
) {
	if index == nil || index.point_count <= 0 {
		return {}, .Empty_History
	}
	current_idx := -1
	for i in 0 ..< index.point_count {
		if index.points[i].point_number == current_point {
			current_idx = i
			break
		}
	}
	if current_idx <= 0 {
		return {}, .Target_Out_Of_Range
	}

	target_idx := -1
	switch step_kind {
	case .Instruction:
		target_idx = current_idx - 1
	case .Source_Line:
		current_line := index.points[current_idx].source_line
		for i := current_idx - 1; i >= 0; i -= 1 {
			line := index.points[i].source_line
			if line != 0 && line != current_line {
				target_idx = i
				break
			}
		}
		if target_idx < 0 {
			return {}, .Target_Out_Of_Range
		}
	case .Last_Watch_Write:
		if watch_size == 0 || watch_address > max(u64) - watch_size {
			return {}, .Bad_Watch_Range
		}
		for i := current_idx - 1; i >= 0; i -= 1 {
			pt := index.points[i]
			pt_kind, kind_ok := replay_input_kind_of_word(u64(pt.kind))
			if !kind_ok {
				return {}, .Unknown_Input_Kind
			}
			if pt_kind == .Memory_Write && replay_ranges_overlap(pt.write_address, pt.write_size, watch_address, watch_size) {
				target_idx = i
				break
			}
		}
		if target_idx < 0 {
			return {}, .Write_Not_Found
		}
	}

	target := index.points[target_idx]
	cp_idx, cp, cp_ref := replay_find_checkpoint_before(index, target.point_number)
	if cp_ref != .None {
		return {}, cp_ref
	}
	return Replay_Step_Back_Plan {
		checkpoint_index = cp_idx,
		checkpoint_point = cp.point_number,
		target_point     = target.point_number,
		target_branches  = target.retired_conditional_branches,
		target_rip       = target.rip,
		target_line      = target.source_line,
		steps_to_replay  = target.point_number - cp.point_number,
	}, .None
}

// replay_compare_step checks an observed replay point against the recorded
// Replay_Input_Point, catching planted rdrand divergence and any mismatch in
// point number, input kind, branch count, rip, rsp, or rax.
replay_compare_step :: proc "contextless" (expected: Replay_Input_Point, actual: Replay_Observed_Step) -> Replay_Compare_Result {
	res := Replay_Compare_Result {
		point_number      = expected.point_number,
		expected_rip      = expected.rip,
		actual_rip        = actual.rip,
		expected_rsp      = expected.rsp,
		actual_rsp        = actual.rsp,
		expected_rax      = expected.rax,
		actual_rax        = actual.rax,
		expected_branches = expected.retired_conditional_branches,
		actual_branches   = actual.retired_conditional_branches,
	}
	expected_kind, kind_ok := replay_input_kind_of_word(u64(expected.kind))
	if !kind_ok || expected_kind == .None {
		res.refusal = .Unknown_Input_Kind
		return res
	}
	if expected_kind == .Planted_Rdrand_Divergence || actual.kind == .Planted_Rdrand_Divergence {
		res.refusal = .Rdrand_Divergence
		return res
	}
	if actual.point_number != expected.point_number ||
	   actual.kind != expected_kind ||
	   actual.retired_conditional_branches != expected.retired_conditional_branches ||
	   actual.rip != expected.rip ||
	   actual.rsp != expected.rsp ||
	   actual.rax != expected.rax {
		res.refusal = .Divergence_Detected
		return res
	}
	res.matched = true
	res.refusal = .None
	return res
}

// replay_history_encoded_bytes returns the exact byte length required to
// serialize index with replay_history_encode.
replay_history_encoded_bytes :: proc "contextless" (index: ^Replay_History_Index) -> int {
	if index == nil {
		return 0
	}
	return size_of(Replay_History_Header) + index.checkpoint_count * size_of(Replay_Checkpoint) + index.point_count * size_of(Replay_Input_Point)
}

// replay_history_encode writes a canonical binary snapshot of index into dst.
replay_history_encode :: proc "contextless" (index: ^Replay_History_Index, dst: []u8) -> (written: int, refusal: Replay_Refusal) {
	if index == nil || index.point_count <= 0 {
		return 0, .Empty_History
	}
	needed := replay_history_encoded_bytes(index)
	if len(dst) < needed {
		return 0, .Buffer_Too_Small
	}
	header := Replay_History_Header {
		magic            = REPLAY_HISTORY_MAGIC,
		version          = REPLAY_HISTORY_VERSION,
		checkpoint_count = u32(index.checkpoint_count),
		point_count      = u32(index.point_count),
		reserved         = 0,
		module_hash      = index.module_hash,
	}
	at := 0
	intrinsics.mem_copy_non_overlapping(&dst[at], &header, size_of(Replay_History_Header))
	at += size_of(Replay_History_Header)
	for i in 0 ..< index.checkpoint_count {
		cp := index.checkpoints[i]
		intrinsics.mem_copy_non_overlapping(&dst[at], &cp, size_of(Replay_Checkpoint))
		at += size_of(Replay_Checkpoint)
	}
	for i in 0 ..< index.point_count {
		pt := index.points[i]
		intrinsics.mem_copy_non_overlapping(&dst[at], &pt, size_of(Replay_Input_Point))
		at += size_of(Replay_Input_Point)
	}
	return at, .None
}

// replay_history_decode validates and decodes a binary replay history buffer
// into caller-owned index, re-checking every checkpoint and input point border.
replay_history_decode :: proc "contextless" (src: []u8, index: ^Replay_History_Index) -> Replay_Refusal {
	if index == nil {
		return .Empty_History
	}
	index^ = {}
	if len(src) < size_of(Replay_History_Header) {
		return .Truncated_Record
	}
	header: Replay_History_Header
	intrinsics.mem_copy_non_overlapping(&header, raw_data(src), size_of(Replay_History_Header))
	if header.magic != REPLAY_HISTORY_MAGIC || header.version != REPLAY_HISTORY_VERSION || header.reserved != 0 {
		return .Bad_Header
	}
	if header.checkpoint_count > REPLAY_CHECKPOINTS_MAX || header.point_count > REPLAY_INPUT_POINTS_MAX {
		return .Capacity_Exceeded
	}
	if header.point_count == 0 {
		return .Empty_History
	}
	expected_bytes := size_of(Replay_History_Header) + int(header.checkpoint_count) * size_of(Replay_Checkpoint) + int(header.point_count) * size_of(Replay_Input_Point)
	if len(src) != expected_bytes {
		return .Truncated_Record
	}

	replay_history_init(index, header.module_hash)
	at := size_of(Replay_History_Header)
	for _ in 0 ..< header.checkpoint_count {
		cp: Replay_Checkpoint
		intrinsics.mem_copy_non_overlapping(&cp, &src[at], size_of(Replay_Checkpoint))
		at += size_of(Replay_Checkpoint)
		if ref := replay_history_add_checkpoint(index, cp); ref != .None {
			index^ = {}
			return ref
		}
	}
	for _ in 0 ..< header.point_count {
		pt: Replay_Input_Point
		intrinsics.mem_copy_non_overlapping(&pt, &src[at], size_of(Replay_Input_Point))
		at += size_of(Replay_Input_Point)
		if ref := replay_history_add_point(index, pt); ref != .None {
			index^ = {}
			return ref
		}
	}
	return .None
}
