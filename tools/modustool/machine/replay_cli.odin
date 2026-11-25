// Host CLI for replaying a recorded process input history and diagnosing
// divergence (`modustool replay <part> <process>`,
// src/md/features/record_and_replay.md).
package machine

import "core:fmt"
import "core:os"
import "core:strings"
import "modus:contract/replay_engine"
import "modustool:foundation"

// Format property: safe identifier length bound for test part and process names.
REPLAY_CLI_NAME_MAX_BYTES :: 64

// Structured host diagnosis produced by replay_diagnose_history.
Replay_Diagnosis :: struct {
	checkpoint_count:         int,
	point_count:              int,
	diverged:                 bool,
	divergence_refusal:       replay_engine.Replay_Refusal,
	divergence_point:         u64,
	expected_rip:             u64,
	actual_rip:               u64,
	expected_rax:             u64,
	actual_rax:               u64,
	expected_branches:        u64,
	actual_branches:          u64,
	has_nearest_checkpoint:   bool,
	nearest_checkpoint_point: u64,
}

// replay_cli_name_valid validates a part or process name for safe filename
// composition, refusing empty names, path separators, traversal, and spaces.
replay_cli_name_valid :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > REPLAY_CLI_NAME_MAX_BYTES {
		return false
	}
	for b in transmute([]u8)name {
		is_alpha := (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
		is_digit := b >= '0' && b <= '9'
		is_punct := b == '_' || b == '-'
		if !is_alpha && !is_digit && !is_punct {
			return false
		}
	}
	return true
}

// replay_history_path_for builds the deterministic recorded history path
// `<folder>/replay_<part>_<process>.history` after validating both names.
replay_history_path_for :: proc(folder, part_name, process_name: string, allocator := context.allocator) -> (path: string, ok: bool) {
	if len(folder) == 0 || !replay_cli_name_valid(part_name) || !replay_cli_name_valid(process_name) {
		return "", false
	}
	clean_folder := strings.trim_right(folder, "/")
	return fmt.aprintf("%s/replay_%s_%s.history", clean_folder, part_name, process_name, allocator = allocator), true
}

// replay_diagnose_history decodes raw into a Replay_History_Index and checks
// either every observed replay step (when observed is provided) or every
// recorded point for planted rdrand divergence, recording the nearest
// checkpoint before the first divergence for debugger step-back.
replay_diagnose_history :: proc(raw: []u8, observed: []replay_engine.Replay_Observed_Step = nil) -> (report: Replay_Diagnosis, refusal: replay_engine.Replay_Refusal) {
	index := new(replay_engine.Replay_History_Index, context.temp_allocator)
	if dec_ref := replay_engine.replay_history_decode(raw, index); dec_ref != .None {
		return {}, dec_ref
	}
	report.checkpoint_count = index.checkpoint_count
	report.point_count = index.point_count

	if len(observed) > 0 {
		limit := min(len(observed), index.point_count)
		for i in 0 ..< limit {
			cmp := replay_engine.replay_compare_step(index.points[i], observed[i])
			if !cmp.matched {
				report.diverged = true
				report.divergence_refusal = cmp.refusal
				report.divergence_point = cmp.point_number
				report.expected_rip = cmp.expected_rip
				report.actual_rip = cmp.actual_rip
				report.expected_rax = cmp.expected_rax
				report.actual_rax = cmp.actual_rax
				report.expected_branches = cmp.expected_branches
				report.actual_branches = cmp.actual_branches
				_, cp, cp_ref := replay_engine.replay_find_checkpoint_before(index, cmp.point_number)
				if cp_ref == .None {
					report.has_nearest_checkpoint = true
					report.nearest_checkpoint_point = cp.point_number
				}
				return report, .None
			}
		}
		if len(observed) != index.point_count {
			report.diverged = true
			report.divergence_refusal = .Divergence_Detected
			if limit < index.point_count {
				report.divergence_point = index.points[limit].point_number
			} else {
				report.divergence_point = observed[limit].point_number
			}
			_, cp, cp_ref := replay_engine.replay_find_checkpoint_before(index, report.divergence_point)
			if cp_ref == .None {
				report.has_nearest_checkpoint = true
				report.nearest_checkpoint_point = cp.point_number
			}
		}
		return report, .None
	}

	// Offline diagnosis with no live replayer: verify every recorded point and
	// surface any planted rdrand divergence recorded in the history.
	for i in 0 ..< index.point_count {
		pt := index.points[i]
		kind, kind_ok := replay_engine.replay_input_kind_of_word(u64(pt.kind))
		if !kind_ok {
			return report, .Unknown_Input_Kind
		}
		if kind == .Planted_Rdrand_Divergence {
			report.diverged = true
			report.divergence_refusal = .Rdrand_Divergence
			report.divergence_point = pt.point_number
			report.expected_rip = pt.rip
			report.expected_rax = pt.rax
			report.expected_branches = pt.retired_conditional_branches
			_, cp, cp_ref := replay_engine.replay_find_checkpoint_before(index, pt.point_number)
			if cp_ref == .None {
				report.has_nearest_checkpoint = true
				report.nearest_checkpoint_point = cp.point_number
			}
			return report, .None
		}
	}
	return report, .None
}

// run_replay_cli implements `modustool replay <part> <process>`: loads the
// recorded history file from `build/`, diagnoses divergence on the host, and
// reports the nearest step-back checkpoint.
run_replay_cli :: proc(args: []string) -> int {
	if len(args) != 2 {
		fmt.eprintln("modustool: replay: expected `replay <part> <process>`")
		return foundation.EXIT_USAGE
	}
	part_name := args[0]
	process_name := args[1]
	path, path_ok := replay_history_path_for(foundation.BUILD_FOLDER, part_name, process_name, context.temp_allocator)
	if !path_ok {
		fmt.eprintfln("modustool: replay: refused part %q or process %q; use ASCII letters, digits, _ or -", part_name, process_name)
		return foundation.EXIT_USAGE
	}
	raw, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("modustool: replay: cannot read history %s: %v", path, read_err)
		return foundation.EXIT_FAILURE
	}
	report, diag_ref := replay_diagnose_history(raw)
	if diag_ref != .None {
		fmt.eprintfln("modustool: replay: damaged history %s: %v", path, diag_ref)
		return foundation.EXIT_FAILURE
	}
	if report.diverged {
		if report.has_nearest_checkpoint {
			fmt.eprintfln("modustool: replay: %s/%s diverged (%v) at point %d (rip 0x%x, branches %d); nearest checkpoint at point %d", part_name, process_name, report.divergence_refusal, report.divergence_point, report.expected_rip, report.expected_branches, report.nearest_checkpoint_point)
		} else {
			fmt.eprintfln("modustool: replay: %s/%s diverged (%v) at point %d (rip 0x%x, branches %d)", part_name, process_name, report.divergence_refusal, report.divergence_point, report.expected_rip, report.expected_branches)
		}
		return foundation.EXIT_FAILURE
	}
	fmt.printfln("modustool: replay: %s/%s verified clean (%d points, %d checkpoints)", part_name, process_name, report.point_count, report.checkpoint_count)
	return 0
}
