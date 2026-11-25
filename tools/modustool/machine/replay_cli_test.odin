// Host unit tests for `modustool replay <part> <process>` (replay_cli.odin).
package machine

import "core:testing"
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
	replay_engine.replay_history_init(clean_idx, {7, 8, 9})
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
