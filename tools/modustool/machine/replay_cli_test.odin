// Host unit tests for `modustool replay <part> <process>` (replay_cli.odin).
package machine

import "core:encoding/endian"
import "core:os"
import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/input_history"
import op "modus:contract/operation"
import "modus:contract/replay_engine"
import "modustool:foundation"

@(test)
replay_cli_refuses_bad_args_and_path_traversal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Wrong argument counts are refused with EXIT_USAGE.
	testing.expect_value(t, run_replay_cli(nil), foundation.EXIT_USAGE)
	testing.expect_value(t, run_replay_cli({"main"}), foundation.EXIT_USAGE)
	testing.expect_value(t, run_replay_cli({"main", "console", "extra"}), foundation.EXIT_USAGE)

	// Unsafe part or process names (path traversal, slashes, spaces) are refused.
	for bad in ([]string{"", "../etc", "a/b", "a\\b", "has space", "bad.name"}) {
		testing.expectf(t, !replay_cli_name_valid(bad), "name %q must be refused", bad)
		_, ok := replay_history_path_for("build", bad, "console", context.temp_allocator)
		testing.expect(t, !ok, "unsafe part name refuses path")
		testing.expect_value(t, run_replay_cli({bad, "console"}), foundation.EXIT_USAGE)
	}

	// Valid names build a deterministic path inside build folder.
	path, ok := replay_history_path_for("build/", "debugger", "console", context.temp_allocator)
	testing.expect(t, ok, "valid names build replay history path")
	testing.expect_value(t, path, "build/replay_debugger_console.history")

	// Missing file returns EXIT_FAILURE cleanly.
	testing.expect_value(t, run_replay_cli({"no_such_part_xyz", "console"}), foundation.EXIT_FAILURE)
}

@(test)
replay_diagnose_history_detects_clean_and_diverged_runs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Corrupt buffer is refused.
	_, bad_ref := replay_diagnose_history(nil)
	testing.expect_value(t, bad_ref, replay_engine.Replay_Refusal.Truncated_Record)

	// Build a clean two-point history with one checkpoint.
	clean_idx := new(replay_engine.Replay_History_Index, context.temp_allocator)
	replay_engine.replay_history_init(clean_idx, [32]u8{0 = 7, 1 = 8, 2 = 9})
	testing.expect_value(t, replay_engine.replay_history_add_checkpoint(clean_idx, {point_number = 1, retired_conditional_branches = 10, rip = 0x1000, rsp = 0x8000, source_line = 5}), replay_engine.Replay_Refusal.None)
	testing.expect_value(t, replay_engine.replay_history_add_point(clean_idx, {point_number = 1, kind = u32(replay_engine.Replay_Input_Kind.Syscall_Return), source_line = 5, retired_conditional_branches = 10, rip = 0x1000, rsp = 0x8000, rax = 11}), replay_engine.Replay_Refusal.None)
	testing.expect_value(t, replay_engine.replay_history_add_point(clean_idx, {point_number = 2, kind = u32(replay_engine.Replay_Input_Kind.Interrupt_At_Branch_Count), source_line = 6, retired_conditional_branches = 42, rip = 0x1020, rsp = 0x8000, rax = 22}), replay_engine.Replay_Refusal.None)

	clean_buf := make([]u8, replay_engine.replay_history_encoded_bytes(clean_idx), context.temp_allocator)
	written, enc_ref := replay_engine.replay_history_encode(clean_idx, clean_buf)
	testing.expect_value(t, enc_ref, replay_engine.Replay_Refusal.None)

	// Offline diagnosis and matching observed run both report clean.
	report, diag_ref := replay_diagnose_history(clean_buf[:written])
	testing.expect_value(t, diag_ref, replay_engine.Replay_Refusal.None)
	testing.expect(t, !report.diverged, "clean history has no divergence")
	testing.expect_value(t, report.point_count, 2)
	testing.expect_value(t, report.checkpoint_count, 1)

	matching_obs := [2]replay_engine.Replay_Observed_Step{
		{point_number = 1, kind = .Syscall_Return, retired_conditional_branches = 10, rip = 0x1000, rsp = 0x8000, rax = 11},
		{point_number = 2, kind = .Interrupt_At_Branch_Count, retired_conditional_branches = 42, rip = 0x1020, rsp = 0x8000, rax = 22},
	}
	match_report, match_ref := replay_diagnose_history(clean_buf[:written], matching_obs[:])
	testing.expect_value(t, match_ref, replay_engine.Replay_Refusal.None)
	testing.expect(t, !match_report.diverged, "matching observed replay passes cleanly")

	// Diverged register / branch count reports exact point and nearest checkpoint.
	diverged_obs := matching_obs
	diverged_obs[1].retired_conditional_branches = 43
	div_report, div_ref := replay_diagnose_history(clean_buf[:written], diverged_obs[:])
	testing.expect_value(t, div_ref, replay_engine.Replay_Refusal.None)
	testing.expect(t, div_report.diverged, "branch count mismatch is diagnosed as divergence")
	testing.expect_value(t, div_report.divergence_refusal, replay_engine.Replay_Refusal.Divergence_Detected)
	testing.expect_value(t, div_report.divergence_point, u64(2))
	testing.expect(t, div_report.has_nearest_checkpoint, "nearest checkpoint is identified for step-back")
	testing.expect_value(t, div_report.nearest_checkpoint_point, u64(1))

	// Planted rdrand divergence is detected directly in offline history diagnosis.
	testing.expect_value(t, replay_engine.replay_history_add_point(clean_idx, {point_number = 3, kind = u32(replay_engine.Replay_Input_Kind.Planted_Rdrand_Divergence), source_line = 7, retired_conditional_branches = 55, rip = 0x1040, rsp = 0x8000, rax = 0xCAFE}), replay_engine.Replay_Refusal.None)
	rdrand_buf := make([]u8, replay_engine.replay_history_encoded_bytes(clean_idx), context.temp_allocator)
	rdrand_len, rdrand_enc := replay_engine.replay_history_encode(clean_idx, rdrand_buf)
	testing.expect_value(t, rdrand_enc, replay_engine.Replay_Refusal.None)

	rdrand_report, rdrand_ref := replay_diagnose_history(rdrand_buf[:rdrand_len])
	testing.expect_value(t, rdrand_ref, replay_engine.Replay_Refusal.None)
	testing.expect(t, rdrand_report.diverged, "planted rdrand point triggers divergence")
	testing.expect_value(t, rdrand_report.divergence_refusal, replay_engine.Replay_Refusal.Rdrand_Divergence)
	testing.expect_value(t, rdrand_report.divergence_point, u64(3))
	testing.expect(t, rdrand_report.has_nearest_checkpoint && rdrand_report.nearest_checkpoint_point == 1, "planted rdrand points back to checkpoint 1")
}

// Kernel "MODUSHIS" history diagnosis refuses damaged, unended, or truncated
// buffers, verifies clean Normal_Stop and Recorder_Stopped histories, reports
// exact divergence details, and extracts matching histories from a memory file.
@(test)
replay_diagnose_kernel_history_and_memory_extraction :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	module_hash := [32]u8{0 = 0x42, 1 = 0x19, 31 = 0xAB}
	other_hash := [32]u8{0 = 0x99}
	page := int(input_history.HISTORY_PAGE_SIZE)

	// Refusal 1: truncated buffer with MODUSHIS magic.
	truncated: [16]u8
	endian.put_u64(truncated[:8], .Little, input_history.HISTORY_MAGIC)
	_, trunc_ref := replay_diagnose_history(truncated[:])
	testing.expect_value(t, trunc_ref, replay_engine.Replay_Refusal.Truncated_Record)

	// Refusal 2: initialized history with end_reason == None is refused.
	unended := make([]u8, page, context.temp_allocator)
	unended_writer, ok := input_history.history_writer_init(unended, module_hash, 1_000_000_000, 100, 7)
	testing.expect(t, ok, "kernel history writer initializes")
	testing.expect(t, input_history.history_writer_append_cycle_counter(&unended_writer, 0x401000, 0x7000, {cycles = 12345}), "append cycle counter")
	_, unended_ref := replay_diagnose_history(unended)
	testing.expect_value(t, unended_ref, replay_engine.Replay_Refusal.Bad_Header)

	// Refusal 3: history with end_reason set in header but missing History_End record.
	missing_end := make([]u8, page, context.temp_allocator)
	copy(missing_end, unended)
	testing.expect(t, input_history.history_header_record_end(missing_end, .Normal_Stop, .None, 0, 0, 0), "seal header directly")
	_, missing_end_ref := replay_diagnose_history(missing_end)
	testing.expect_value(t, missing_end_ref, replay_engine.Replay_Refusal.Bad_Header)

	// Refusal 4: trailing record after History_End is refused.
	trailing := make([]u8, page, context.temp_allocator)
	trailing_writer, trailing_ok := input_history.history_writer_init(trailing, module_hash, 1_000_000_000, 150, 7)
	testing.expect(t, trailing_ok, "trailing history writer initializes")
	testing.expect(t, input_history.history_writer_append_end(&trailing_writer, 0x401100, 0x7000, .Recorder_Stopped), "append early end")
	// Force writer open to plant a malformed trailing record after History_End.
	trailing_writer.ended = false
	testing.expect(t, input_history.history_writer_append_cycle_counter(&trailing_writer, 0x401110, 0x7000, {cycles = 999}), "plant trailing record")
	testing.expect(t, input_history.history_header_record_end(trailing, .Recorder_Stopped, .None, 0, 0, 0), "seal trailing header")
	_, trailing_ref := replay_diagnose_history(trailing)
	testing.expect_value(t, trailing_ref, replay_engine.Replay_Refusal.Bad_Header)

	// Success 1: clean Recorder_Stopped kernel history (console/window shape).
	clean := make([]u8, page, context.temp_allocator)
	clean_writer, clean_ok := input_history.history_writer_init(clean, module_hash, 1_000_000_000, 200, 7)
	testing.expect(t, clean_ok, "clean history writer initializes")
	testing.expect(t, input_history.history_writer_append_kernel_completion(&clean_writer, 0x402000, 0x7000, {command_kind = u32(op.Operation.Word_Wake), command_values = {0 = 0x500000, 1 = 0x1111}, completion_status = u32(call_outcome.Call_Outcome.Succeeded)}, nil), "append completion")
	testing.expect(t, input_history.history_writer_append_end(&clean_writer, 0x402010, 0x7000, .Recorder_Stopped), "append recorder stopped end")
	testing.expect(t, input_history.history_header_record_end(clean, .Recorder_Stopped, .None, 0, 0, 0), "record header end")

	// Refusal 5: mismatched header point_count is refused.
	bad_count := make([]u8, page, context.temp_allocator)
	copy(bad_count, clean)
	bad_hdr := (^input_history.History_Header)(raw_data(bad_count))
	bad_hdr.point_count = 99
	_, bad_count_ref := replay_diagnose_history(bad_count)
	testing.expect_value(t, bad_count_ref, replay_engine.Replay_Refusal.Bad_Header)

	// Refusal 6: mismatched header end_reason vs stream History_End reason is refused.
	bad_reason := make([]u8, page, context.temp_allocator)
	copy(bad_reason, clean)
	testing.expect(t, input_history.history_header_record_end(bad_reason, .Normal_Stop, .None, 0, 0, 0), "overwrite header end reason")
	_, bad_reason_ref := replay_diagnose_history(bad_reason)
	testing.expect_value(t, bad_reason_ref, replay_engine.Replay_Refusal.Bad_Header)

	clean_report, clean_ref := replay_diagnose_history(clean)
	testing.expect_value(t, clean_ref, replay_engine.Replay_Refusal.None)
	testing.expect(t, clean_report.is_kernel_history, "recognized as kernel history")
	testing.expect(t, !clean_report.diverged, "clean kernel history has no divergence")
	testing.expect_value(t, clean_report.kernel_end_reason, input_history.History_End_Reason.Recorder_Stopped)
	testing.expect_value(t, clean_report.point_count, 2)

	// Success 2: diverged kernel history (planted rdrand Unexpected_Arguments).
	diverged := make([]u8, page, context.temp_allocator)
	div_writer, div_ok := input_history.history_writer_init(diverged, module_hash, 1_000_000_000, 300, 7)
	testing.expect(t, div_ok, "diverged history writer initializes")
	testing.expect(t, input_history.history_writer_append_cpuid(&div_writer, 0x403000, 0x7000, {leaf = 1, eax = 1, ebx = 2, ecx = 0, edx = 4}), "append cpuid")
	testing.expect(t, input_history.history_writer_append_kernel_completion(&div_writer, 0x403040, 0x7000, {command_kind = u32(op.Operation.Word_Wake), command_values = {0 = 0x500000, 1 = 0xAAAA_BBBB}, completion_status = u32(call_outcome.Call_Outcome.Succeeded)}, nil), "append checksum wake")
	testing.expect(t, input_history.history_writer_append_end(&div_writer, 0x403060, 0x7000, .Normal_Stop), "append original normal stop")
	testing.expect(t, input_history.history_header_record_end(diverged, .Divergence, .Unexpected_Arguments, 2, 0xAAAA_BBBB, 0xCCCC_DDDD), "record replay divergence in header")

	div_report, div_ref := replay_diagnose_history(diverged)
	testing.expect_value(t, div_ref, replay_engine.Replay_Refusal.None)
	testing.expect(t, div_report.is_kernel_history && div_report.diverged, "diverged kernel history detected")
	testing.expect_value(t, div_report.kernel_divergence_kind, input_history.Divergence_Kind.Unexpected_Arguments)
	testing.expect_value(t, div_report.divergence_point, u64(2))
	testing.expect_value(t, div_report.expected_rip, u64(0x403040))
	testing.expect_value(t, div_report.expected_value, u64(0xAAAA_BBBB))
	testing.expect_value(t, div_report.actual_value, u64(0xCCCC_DDDD))

	// Memory-file extraction: places noise, unended, clean, and diverged
	// histories at page-aligned offsets and extracts each by hash and state.
	mem_path := foundation.BUILD_FOLDER + "/test_replay_extract_memory.raw"
	_ = os.make_directory_all(foundation.BUILD_FOLDER)
	defer _ = os.remove(mem_path)
	mem_buf := make([]u8, page + len(unended) + len(clean) + len(diverged), context.temp_allocator)
	copy(mem_buf[page:], unended)
	copy(mem_buf[page + len(unended):], clean)
	copy(mem_buf[page + len(unended) + len(clean):], diverged)
	testing.expect(t, os.write_entire_file(mem_path, mem_buf) == nil, "write synthetic guest memory file")

	// Missing hash returns not found.
	_, missing_found := replay_extract_kernel_history_from_memory_file(mem_path, other_hash, false, context.temp_allocator)
	testing.expect(t, !missing_found, "unknown module hash is not extracted")

	// Extract clean history.
	got_clean, got_clean_ok := replay_extract_kernel_history_from_memory_file(mem_path, module_hash, false, context.temp_allocator)
	testing.expect(t, got_clean_ok, "clean history extracted from memory file")
	got_clean_diag, got_clean_ref := replay_diagnose_history(got_clean)
	testing.expect_value(t, got_clean_ref, replay_engine.Replay_Refusal.None)
	testing.expect(t, !got_clean_diag.diverged && got_clean_diag.point_count == 2, "extracted clean history verifies")

	// Extract diverged history.
	got_div, got_div_ok := replay_extract_kernel_history_from_memory_file(mem_path, module_hash, true, context.temp_allocator)
	testing.expect(t, got_div_ok, "diverged history extracted from memory file")
	got_div_diag, got_div_ref := replay_diagnose_history(got_div)
	testing.expect_value(t, got_div_ref, replay_engine.Replay_Refusal.None)
	testing.expect(t, got_div_diag.diverged && got_div_diag.kernel_divergence_kind == .Unexpected_Arguments, "extracted diverged history verifies")
}
