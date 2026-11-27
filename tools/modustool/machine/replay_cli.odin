// Host CLI for replaying a recorded process input history and diagnosing
// divergence (`modustool replay <part> <process>`,
// src/md/features/record_and_replay.md).
package machine

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "modus:contract/blake3"
import "modus:contract/input_history"
import "modus:contract/replay_engine"
import "modustool:build"
import "modustool:foundation"

// Format property: safe identifier length bound for test part and process names.
REPLAY_CLI_NAME_MAX_BYTES :: 64

// Inline capacity: chunk size for scanning a QEMU guest memory file for
// contiguous page-aligned kernel input histories.
REPLAY_MEMORY_SCAN_CHUNK_BYTES :: 4 * 1024 * 1024

// Format property: upper bound on one exported kernel input history buffer
// (16 MiB) when scanning untrusted guest memory pages.
REPLAY_KERNEL_HISTORY_MAX_BYTES :: 16 * 1024 * 1024

// Structured host diagnosis produced by replay_diagnose_history.
Replay_Diagnosis :: struct {
	is_kernel_history:        bool,
	kernel_end_reason:        input_history.History_End_Reason,
	kernel_divergence_kind:   input_history.Divergence_Kind,
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
	expected_value:           u64,
	actual_value:             u64,
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

// replay_is_kernel_history reports whether raw starts with the kernel
// input_history magic ("MODUSHIS").
replay_is_kernel_history :: proc(raw: []u8) -> bool {
	if len(raw) < size_of(u64) {
		return false
	}
	magic, ok := endian.get_u64(raw[:8], .Little)
	return ok && magic == input_history.HISTORY_MAGIC
}

// replay_diagnose_kernel_history validates every header and record of a raw
// kernel input_history buffer ("MODUSHIS") through the contract borders and
// reports clean completion or exact divergence details.
replay_diagnose_kernel_history :: proc(raw: []u8) -> (report: Replay_Diagnosis, refusal: replay_engine.Replay_Refusal) {
	reader, opened := input_history.history_reader_open(raw)
	if !opened {
		return {}, .Truncated_Record
	}
	end_reason, end_ok := input_history.history_end_reason_of_word(u64(reader.header.end_reason))
	if !end_ok || end_reason == .None {
		return {}, .Bad_Header
	}
	div_kind, div_ok := input_history.divergence_kind_of_word(u64(reader.header.divergence_kind))
	if !div_ok {
		return {}, .Bad_Header
	}

	scratch := make([]u8, input_history.MAX_RECORD_PAYLOAD_BYTES, context.temp_allocator)
	saw_end_record := false
	stream_end_reason := input_history.History_End_Reason.None
	record_count := u64(0)
	for {
		_, kind, payload, has_more, read_ok := input_history.history_reader_next_into(&reader, scratch)
		if !read_ok {
			return {}, .Truncated_Record
		}
		if !has_more {
			break
		}
		if saw_end_record {
			// Refuse any trailing record after a History_End marker.
			return {}, .Bad_Header
		}
		record_count += 1
		switch kind {
		case .None:
			return {}, .Unknown_Input_Kind
		case .Kernel_Completion:
			if _, _, ok := input_history.kernel_completion_from_payload(payload); !ok {
				return {}, .Truncated_Record
			}
		case .Cycle_Counter:
			if _, ok := input_history.cycle_counter_from_payload(payload); !ok {
				return {}, .Truncated_Record
			}
		case .Processor_Identification:
			if _, ok := input_history.cpuid_from_payload(payload); !ok {
				return {}, .Truncated_Record
			}
		case .Page_Delta:
			if _, ok := input_history.page_delta_validate(payload); !ok {
				return {}, .Truncated_Record
			}
		case .Shared_Mapping:
			if _, _, ok := input_history.shared_mapping_validate(payload); !ok {
				return {}, .Truncated_Record
			}
		case .History_End:
			_, parsed_end_reason, _, ok := input_history.history_end_from_payload(payload)
			if !ok {
				return {}, .Truncated_Record
			}
			saw_end_record = true
			stream_end_reason = parsed_end_reason
		}
	}
	// A non-Buffer_Full kernel history must carry a terminating History_End
	// record in its stream; Buffer_Full seals the header directly when no room
	// remains for a trailing record.
	if !saw_end_record && end_reason != .Buffer_Full {
		return {}, .Bad_Header
	}
	if record_count != reader.header.point_count || reader.last_point != reader.header.point_count || record_count > u64(max(int)) {
		return {}, .Bad_Header
	}
	if saw_end_record && end_reason != .Divergence && stream_end_reason != end_reason {
		return {}, .Bad_Header
	}

	report.is_kernel_history = true
	report.kernel_end_reason = end_reason
	report.point_count = int(record_count)
	if end_reason == .Divergence {
		report.diverged = true
		report.divergence_refusal = .Divergence_Detected
		report.kernel_divergence_kind = div_kind
		report.divergence_point = reader.header.divergence_point
		report.expected_value = reader.header.divergence_expected
		report.actual_value = reader.header.divergence_actual
		if div_report, found, report_ok := input_history.divergence_report_of_history(raw, scratch); report_ok && found {
			report.kernel_divergence_kind = div_report.kind
			report.divergence_point = div_report.point
			report.expected_rip = div_report.recorded_instruction_address
			report.expected_value = div_report.expected
			report.actual_value = div_report.actual
		}
	}
	return report, .None
}

// replay_diagnose_history decodes raw (either a kernel "MODUSHIS" input
// history or a "MODREPL1" Replay_History_Index) and checks for clean
// completion or divergence, recording the nearest checkpoint before the first
// divergence when checkpoints are present.
replay_diagnose_history :: proc(raw: []u8, observed: []replay_engine.Replay_Observed_Step = nil) -> (report: Replay_Diagnosis, refusal: replay_engine.Replay_Refusal) {
	if len(observed) == 0 && replay_is_kernel_history(raw) {
		return replay_diagnose_kernel_history(raw)
	}
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

// replay_extract_kernel_history_from_memory_file scans page-aligned offsets in
// a QEMU guest memory file for a valid contiguous kernel input history whose
// module_hash matches module_hash and whose end state matches want_diverged.
// When multiple valid copies exist (such as a recorded history and its replay
// copy), it returns the validated copy with the highest point count.
replay_extract_kernel_history_from_memory_file :: proc(memory_file_path: string, module_hash: [32]u8, want_diverged: bool, allocator := context.allocator) -> (bytes: []u8, found: bool) {
	if len(memory_file_path) == 0 {
		return nil, false
	}
	file, open_err := os.open(memory_file_path)
	if open_err != nil {
		return nil, false
	}
	defer os.close(file)

	file_size, size_err := os.file_size(file)
	if size_err != nil || file_size < i64(input_history.HISTORY_PAGE_SIZE) {
		return nil, false
	}

	chunk := make([]u8, REPLAY_MEMORY_SCAN_CHUNK_BYTES)
	defer delete(chunk)

	best: []u8
	best_points := -1
	best_written := u64(0)

	page_size := i64(input_history.HISTORY_PAGE_SIZE)
	for base := i64(0); base < file_size; base += i64(len(chunk)) {
		to_read := int(min(i64(len(chunk)), file_size - base))
		read_count, read_err := os.read_at(file, chunk[:to_read], base)
		if read_err != nil || read_count < size_of(input_history.History_Header) {
			break
		}
		for offset := 0; offset + size_of(input_history.History_Header) <= read_count; offset += int(page_size) {
			magic, magic_ok := endian.get_u64(chunk[offset:offset + 8], .Little)
			if !magic_ok || magic != input_history.HISTORY_MAGIC {
				continue
			}
			header: input_history.History_Header
			copy(([^]u8)(&header)[:size_of(header)], chunk[offset:offset + size_of(header)])
			if header.version != input_history.HISTORY_VERSION || header.flags != 0 || header.module_hash != module_hash {
				continue
			}
			if header.capacity_bytes < input_history.MIN_HISTORY_BUFFER_BYTES - size_of(input_history.History_Header) || header.capacity_bytes > REPLAY_KERNEL_HISTORY_MAX_BYTES {
				continue
			}
			if header.written_bytes == 0 || header.written_bytes > header.capacity_bytes {
				continue
			}
			end_reason, end_ok := input_history.history_end_reason_of_word(u64(header.end_reason))
			if !end_ok || end_reason == .None || (end_reason == .Divergence) != want_diverged {
				continue
			}
			total_size := i64(size_of(input_history.History_Header)) + i64(header.capacity_bytes)
			abs_offset := base + i64(offset)
			if abs_offset + total_size > file_size {
				continue
			}
			candidate := make([]u8, int(total_size))
			got, cand_err := os.read_at(file, candidate, abs_offset)
			if cand_err != nil || got != len(candidate) {
				delete(candidate)
				continue
			}
			diag, diag_ref := replay_diagnose_kernel_history(candidate)
			if diag_ref != .None || diag.diverged != want_diverged {
				delete(candidate)
				continue
			}
			if diag.point_count > best_points || (diag.point_count == best_points && header.written_bytes > best_written) {
				delete(best)
				best = candidate
				best_points = diag.point_count
				best_written = header.written_bytes
			} else {
				delete(candidate)
			}
		}
	}
	if best == nil {
		return nil, false
	}
	out := make([]u8, len(best), allocator)
	copy(out, best)
	delete(best)
	return out, true
}

// replay_export_and_verify_from_machine extracts a recorded kernel input
// history for process_name from machine.memory_file, writes it to
// `build/replay_<part>_<process>.history`, and verifies it through
// `modustool replay <part> <process>` (`expectation` is "clean" or "diverged").
replay_export_and_verify_from_machine :: proc(machine: ^Machine, process_name: string, expectation: string) -> bool {
	if machine == nil || machine.memory_file == "" {
		fmt.eprintfln("modustool: test failed: Export_Replay_History for %s requires a machine memory_file", process_name)
		return false
	}
	want_diverged: bool
	switch expectation {
	case "clean":
		want_diverged = false
	case "diverged":
		want_diverged = true
	case:
		fmt.eprintfln("modustool: test failed: Export_Replay_History for %s has unknown expectation %q (expected \"clean\" or \"diverged\")", process_name, expectation)
		return false
	}
	module_path := fmt.tprintf("%s/modules/%s%s", foundation.BUILD_FOLDER, process_name, build.MODULE_FILE_SUFFIX)
	module_bytes, mod_err := os.read_entire_file(module_path, context.temp_allocator)
	if mod_err != nil {
		fmt.eprintfln("modustool: test failed: cannot read module %s for replay history export: %v", module_path, mod_err)
		return false
	}
	module_hash := blake3.hash(module_bytes)
	history_bytes, found := replay_extract_kernel_history_from_memory_file(machine.memory_file, module_hash, want_diverged, context.temp_allocator)
	if !found {
		fmt.eprintfln("modustool: test failed: no valid %s kernel input history for %s found in %s", expectation, process_name, machine.memory_file)
		return false
	}
	out_path, path_ok := replay_history_path_for(foundation.BUILD_FOLDER, machine.part.name, process_name, context.temp_allocator)
	if !path_ok {
		fmt.eprintfln("modustool: test failed: cannot build replay history path for %s/%s", machine.part.name, process_name)
		return false
	}
	if write_err := os.write_entire_file(out_path, history_bytes); write_err != nil {
		fmt.eprintfln("modustool: test failed: cannot write replay history %s: %v", out_path, write_err)
		return false
	}
	cli_args := [2]string{machine.part.name, process_name}
	exit_code := run_replay_cli(cli_args[:])
	diag, diag_ref := replay_diagnose_history(history_bytes)
	if diag_ref != .None || !diag.is_kernel_history {
		fmt.eprintfln("modustool: test failed: exported history %s failed diagnosis: %v", out_path, diag_ref)
		return false
	}
	if want_diverged {
		if exit_code != foundation.EXIT_FAILURE || !diag.diverged || diag.kernel_divergence_kind != .Unexpected_Arguments || diag.expected_value == diag.actual_value {
			fmt.eprintfln("modustool: test failed: modustool replay %s %s expected Unexpected_Arguments divergence (exit %d), got exit %d, diverged=%v, kind=%v, expected=0x%x, actual=0x%x", machine.part.name, process_name, foundation.EXIT_FAILURE, exit_code, diag.diverged, diag.kernel_divergence_kind, diag.expected_value, diag.actual_value)
			return false
		}
		foundation.test_passed_print("modustool replay %s %s diagnosed live %v divergence at point %d (recorded 0x%x, replayed 0x%x) from %s", machine.part.name, process_name, diag.kernel_divergence_kind, diag.divergence_point, diag.expected_value, diag.actual_value, out_path)
		return true
	}
	if exit_code != 0 || diag.diverged || diag.point_count == 0 {
		fmt.eprintfln("modustool: test failed: modustool replay %s %s expected clean replay (exit 0), got exit %d, diverged=%v, points=%d", machine.part.name, process_name, exit_code, diag.diverged, diag.point_count)
		return false
	}
	foundation.test_passed_print("modustool replay %s %s verified clean kernel history (%d points, end %v) from %s", machine.part.name, process_name, diag.point_count, diag.kernel_end_reason, out_path)
	return true
}

// run_replay_cli implements `modustool replay <part> <process>`: loads the
// recorded history file from `build/`, diagnoses divergence on the host, and
// reports the nearest step-back checkpoint or exact kernel divergence details.
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
		if report.is_kernel_history {
			fmt.eprintfln("modustool: replay: %s/%s diverged (%v) at point %d (rip 0x%x, expected 0x%x, actual 0x%x)", part_name, process_name, report.kernel_divergence_kind, report.divergence_point, report.expected_rip, report.expected_value, report.actual_value)
		} else if report.has_nearest_checkpoint {
			fmt.eprintfln("modustool: replay: %s/%s diverged (%v) at point %d (rip 0x%x, branches %d); nearest checkpoint at point %d", part_name, process_name, report.divergence_refusal, report.divergence_point, report.expected_rip, report.expected_branches, report.nearest_checkpoint_point)
		} else {
			fmt.eprintfln("modustool: replay: %s/%s diverged (%v) at point %d (rip 0x%x, branches %d)", part_name, process_name, report.divergence_refusal, report.divergence_point, report.expected_rip, report.expected_branches)
		}
		return foundation.EXIT_FAILURE
	}
	if report.is_kernel_history {
		fmt.printfln("modustool: replay: %s/%s verified clean (%d points, end %v)", part_name, process_name, report.point_count, report.kernel_end_reason)
		return 0
	}
	fmt.printfln("modustool: replay: %s/%s verified clean (%d points, %d checkpoints)", part_name, process_name, report.point_count, report.checkpoint_count)
	return 0
}
