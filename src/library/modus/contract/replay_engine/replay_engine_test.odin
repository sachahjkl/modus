#+build !freestanding
// Host unit tests for debugger step-back, branch-count interrupt points,
// planted rdrand divergence detection, and binary history codec.
package replay_engine

import "core:testing"

@(test)
replay_engine_refuses_bad_words_ordering_and_corrupt_buffers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Enum transport border refuses unknown words.
	_, bad_kind_ok := replay_input_kind_of_word(99)
	testing.expect(t, !bad_kind_ok, "unknown Replay_Input_Kind word is refused")
	_, bad_ref_ok := replay_refusal_of_word(255)
	testing.expect(t, !bad_ref_ok, "unknown Replay_Refusal word is refused")
	_, bad_sb_ok := replay_step_back_kind_of_word(0)
	testing.expect(t, !bad_sb_ok, "zero Replay_Step_Back_Kind word is refused")

	index := new(Replay_History_Index, context.temp_allocator)
	replay_history_init(index, {1, 2, 3})

	// Empty history refuses step-back and checkpoint lookups.
	_, _, cp_ref := replay_find_checkpoint_before(index, 10)
	testing.expect_value(t, cp_ref, Replay_Refusal.Checkpoint_Not_Found)
	_, sb_ref := replay_step_back_target(index, 10, .Instruction)
	testing.expect_value(t, sb_ref, Replay_Refusal.Empty_History)

	// Zero or unknown kind words are refused on add_point.
	testing.expect_value(t, replay_history_add_point(index, {point_number = 1, kind = 0}), Replay_Refusal.Unknown_Input_Kind)
	testing.expect_value(t, replay_history_add_point(index, {point_number = 1, kind = 77}), Replay_Refusal.Unknown_Input_Kind)

	// Bad memory write ranges (zero size or u64 overflow) are refused.
	testing.expect_value(t, replay_history_add_point(index, {point_number = 1, kind = u32(Replay_Input_Kind.Memory_Write), write_address = 0x1000, write_size = 0}), Replay_Refusal.Bad_Watch_Range)
	testing.expect_value(t, replay_history_add_point(index, {point_number = 1, kind = u32(Replay_Input_Kind.Memory_Write), write_address = max(u64) - 2, write_size = 8}), Replay_Refusal.Bad_Watch_Range)

	// Non-monotonic point numbers and branch counts are refused.
	testing.expect_value(t, replay_history_add_point(index, {point_number = 10, kind = u32(Replay_Input_Kind.Syscall_Return), retired_conditional_branches = 100}), Replay_Refusal.None)
	testing.expect_value(t, replay_history_add_point(index, {point_number = 10, kind = u32(Replay_Input_Kind.Syscall_Return), retired_conditional_branches = 100}), Replay_Refusal.Non_Monotonic_Point)
	testing.expect_value(t, replay_history_add_point(index, {point_number = 11, kind = u32(Replay_Input_Kind.Interrupt_At_Branch_Count), retired_conditional_branches = 99}), Replay_Refusal.Non_Monotonic_Branches)

	// Non-zero reserved field on checkpoint is refused.
	testing.expect_value(t, replay_history_add_checkpoint(index, {point_number = 10, reserved = 1}), Replay_Refusal.Bad_Header)

	// Decode refuses truncated buffers and damaged headers.
	decoded := new(Replay_History_Index, context.temp_allocator)
	testing.expect_value(t, replay_history_decode(nil, decoded), Replay_Refusal.Truncated_Record)
	bad_hdr: [size_of(Replay_History_Header)]u8
	testing.expect_value(t, replay_history_decode(bad_hdr[:], decoded), Replay_Refusal.Bad_Header)
}

@(test)
replay_engine_step_back_watch_back_and_rdrand_divergence :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	index := new(Replay_History_Index, context.temp_allocator)
	replay_history_init(index, {0xAA, 0xBB, 0xCC})

	// Record two checkpoints and five ordered input points including a branch-count
	// interrupt point, a memory write, and a planted rdrand point.
	testing.expect_value(t, replay_history_add_checkpoint(index, {point_number = 1, retired_conditional_branches = 10, rip = 0x401000, rsp = 0x7FF0, source_line = 10}), Replay_Refusal.None)
	testing.expect_value(t, replay_history_add_checkpoint(index, {point_number = 4, retired_conditional_branches = 80, rip = 0x401040, rsp = 0x7FE0, source_line = 14}), Replay_Refusal.None)

	testing.expect_value(t, replay_history_add_point(index, {point_number = 1, kind = u32(Replay_Input_Kind.Syscall_Return), source_line = 10, retired_conditional_branches = 10, rip = 0x401000, rsp = 0x7FF0, rax = 0}), Replay_Refusal.None)
	testing.expect_value(t, replay_history_add_point(index, {point_number = 2, kind = u32(Replay_Input_Kind.Memory_Write), source_line = 12, retired_conditional_branches = 35, rip = 0x401018, rsp = 0x7FE8, rax = 1, write_address = 0x600000, write_size = 8}), Replay_Refusal.None)
	testing.expect_value(t, replay_history_add_point(index, {point_number = 3, kind = u32(Replay_Input_Kind.Interrupt_At_Branch_Count), source_line = 12, retired_conditional_branches = 64, rip = 0x40102C, rsp = 0x7FE8, rax = 2}), Replay_Refusal.None)
	testing.expect_value(t, replay_history_add_point(index, {point_number = 4, kind = u32(Replay_Input_Kind.Syscall_Return), source_line = 14, retired_conditional_branches = 80, rip = 0x401040, rsp = 0x7FE0, rax = 3}), Replay_Refusal.None)
	testing.expect_value(t, replay_history_add_point(index, {point_number = 5, kind = u32(Replay_Input_Kind.Planted_Rdrand_Divergence), source_line = 15, retired_conditional_branches = 92, rip = 0x401055, rsp = 0x7FE0, rax = 0x1234}), Replay_Refusal.None)

	// Step back one instruction from point 4 -> point 3 (branch-count interrupt) from checkpoint 1.
	inst_plan, inst_ref := replay_step_back_target(index, 4, .Instruction)
	testing.expect_value(t, inst_ref, Replay_Refusal.None)
	testing.expect_value(t, inst_plan.checkpoint_point, u64(1))
	testing.expect_value(t, inst_plan.target_point, u64(3))
	testing.expect_value(t, inst_plan.target_branches, u64(64))
	testing.expect_value(t, inst_plan.steps_to_replay, u64(2))

	// Step back one source line from point 3 (line 12) -> point 1 (line 10).
	line_plan, line_ref := replay_step_back_target(index, 3, .Source_Line)
	testing.expect_value(t, line_ref, Replay_Refusal.None)
	testing.expect_value(t, line_plan.target_point, u64(1))
	testing.expect_value(t, line_plan.target_line, u32(10))

	// Watch back for last write touching 0x600004 (4 bytes, overlaps [0x600000, 0x600008)) from point 4 -> point 2.
	watch_plan, watch_ref := replay_step_back_target(index, 4, .Last_Watch_Write, 0x600004, 4)
	testing.expect_value(t, watch_ref, Replay_Refusal.None)
	testing.expect_value(t, watch_plan.checkpoint_point, u64(1))
	testing.expect_value(t, watch_plan.target_point, u64(2))
	testing.expect_value(t, watch_plan.target_rip, u64(0x401018))

	// Watch back on an untouched address returns Write_Not_Found.
	_, miss_ref := replay_step_back_target(index, 4, .Last_Watch_Write, 0x700000, 8)
	testing.expect_value(t, miss_ref, Replay_Refusal.Write_Not_Found)

	// Comparison: exact match passes; branch/register mismatch triggers Divergence_Detected;
	// planted rdrand triggers Rdrand_Divergence.
	ok_cmp := replay_compare_step(index.points[2], {point_number = 3, kind = .Interrupt_At_Branch_Count, retired_conditional_branches = 64, rip = 0x40102C, rsp = 0x7FE8, rax = 2})
	testing.expect(t, ok_cmp.matched && ok_cmp.refusal == .None, "matching branch-count interrupt point passes")

	bad_branch := replay_compare_step(index.points[2], {point_number = 3, kind = .Interrupt_At_Branch_Count, retired_conditional_branches = 65, rip = 0x40102C, rsp = 0x7FE8, rax = 2})
	testing.expect(t, !bad_branch.matched && bad_branch.refusal == .Divergence_Detected, "branch count mismatch triggers Divergence_Detected")
	testing.expect_value(t, bad_branch.expected_branches, u64(64))
	testing.expect_value(t, bad_branch.actual_branches, u64(65))

	rdrand_cmp := replay_compare_step(index.points[4], {point_number = 5, kind = .Syscall_Return, retired_conditional_branches = 92, rip = 0x401055, rsp = 0x7FE0, rax = 0x9999})
	testing.expect(t, !rdrand_cmp.matched && rdrand_cmp.refusal == .Rdrand_Divergence, "planted rdrand triggers Rdrand_Divergence")

	// Binary encode/decode round-trip preserves checkpoints and input points exactly.
	needed := replay_history_encoded_bytes(index)
	buf := make([]u8, needed, context.temp_allocator)
	_, small_ref := replay_history_encode(index, buf[:needed - 1])
	testing.expect_value(t, small_ref, Replay_Refusal.Buffer_Too_Small)

	written, enc_ref := replay_history_encode(index, buf)
	testing.expect_value(t, enc_ref, Replay_Refusal.None)
	testing.expect_value(t, written, needed)

	decoded := new(Replay_History_Index, context.temp_allocator)
	testing.expect_value(t, replay_history_decode(buf[:written], decoded), Replay_Refusal.None)
	testing.expect_value(t, decoded.checkpoint_count, 2)
	testing.expect_value(t, decoded.point_count, 5)
	testing.expect_value(t, decoded.points[2].retired_conditional_branches, u64(64))
	testing.expect_value(t, decoded.module_hash, index.module_hash)
}
