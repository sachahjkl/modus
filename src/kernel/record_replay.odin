package kernel

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:contract/input_history"
import op "modus:contract/operation"
import "modus:contract/ring"
import "kernel:replay_filter"

// Process input record and replay in the kernel
// (src/md/features/record_and_replay.md).
//
// A recorded or replayed process runs on one processor with CR4.TSD and CPUID
// faulting enabled whenever its thread is on a processor. Normal threads pay
// one test of a byte in the hot cache line of Thread at each switch and zero
// MSR or CR4 writes.
//
// Read-only shared pages (such as the time page and read-only pages written by
// another process) are backed by private point copies paid by the budget of
// the history memory object. At each input point while recording, the kernel
// diffs each point copy against its source page and writes any changed byte
// ranges into the input history. On replay, those deltas apply to the replay
// process's own private point copies, never touching the live shared pages.

POINT_COPY_CAPACITY :: 32
RECORD_COPY_SCRATCH_BYTES :: 8192

// One private page frame backing a read-only shared page of a recorded or
// replayed process. Paid by Process_Record_State.history_budget.
Point_Copy :: struct {
	virtual_address: u64, // Page-aligned user virtual address in the target process.
	source_region:   u32, // Original memory object (e.g. time_region).
	source_page:     u64, // Page index inside source_region.
	original_bits:   u64, // Original page table entry permission bits.
	copy_frame:      u64, // Physical frame of the private copy.
	active:          bool,
}

// Per-process record/replay state, indexed by process slot. Kept out of
// Process so unrecorded processes pay no cache footprint.
Process_Record_State :: struct {
	mode:               input_history.Record_Mode,
	recorder_process:   u32, // Process slot of the recorder or replayer.
	recorder_serial:    u32, // Serial of the recorder or replayer.
	history_region:     u32, // Contiguous memory object of the input history (kernel holds one reference).
	history_budget:     u32, // Budget that paid for the history region and pays for point copies.
	history_buffer:     []u8, // Direct-mapped bytes of history_region.
	writer:             input_history.History_Writer,
	reader:             input_history.History_Reader,
	point_copies:       [POINT_COPY_CAPACITY]Point_Copy,
	point_copy_count:   u32,
	stint_start_point:  u64, // Point count when the current stint started (for the one-stint bound).
	replay_return_time: u64, // Return value in rax for the current kernel entry.
	pinned_processor:   u32, // Single processor index assigned to this process.
}

process_records: [PROCESS_CAPACITY]Process_Record_State
// Read-only zero page in BSS used for encoding initial point copy deltas
// without placing a 4 KiB array on the kernel stack.
record_zero_page: [PAGE_SIZE]u8
// Count of processes currently in Recording or Replaying mode.
record_replay_active_count: u32

// Machine capabilities probed safely via register trials at processor start.
cpuid_faulting_supported: bool
tsc_aux_supported: bool

// record_replay_processor_setup probes CPUID faulting (MSR_PLATFORM_INFO bit 31
// and MSR_MISC_FEATURES_ENABLES bit 0) and MSR_TSC_AUX on each processor at
// boot using register trials, leaving CPUID faulting disabled.
record_replay_processor_setup :: proc "contextless" (cpu: ^Processor) {
	supported := false
	platform_info: u64
	if model_specific_register_trial_read(replay_filter.MSR_PLATFORM_INFO, &platform_info) && replay_filter.platform_info_supports_cpuid_faulting(platform_info) {
		misc: u64
		if model_specific_register_trial_read(replay_filter.MSR_MISC_FEATURES_ENABLES, &misc) {
			cleared := replay_filter.misc_features_with_cpuid_faulting(misc, false)
			if model_specific_register_trial_write(replay_filter.MSR_MISC_FEATURES_ENABLES, cleared) {
				supported = true
			}
		}
	}
	aux_ok := false
	aux_value: u64
	if model_specific_register_trial_read(replay_filter.MSR_TSC_AUX, &aux_value) && model_specific_register_trial_write(replay_filter.MSR_TSC_AUX, aux_value) {
		aux_ok = true
	}
	if cpu.index == 0 {
		intrinsics.atomic_store(&cpuid_faulting_supported, supported)
		intrinsics.atomic_store(&tsc_aux_supported, aux_ok)
	} else {
		if !supported {
			intrinsics.atomic_store(&cpuid_faulting_supported, false)
		}
		if !aux_ok {
			intrinsics.atomic_store(&tsc_aux_supported, false)
		}
	}
}

// record_replay_log writes one boot line stating whether CPUID faulting is
// available for record and replay.
record_replay_log :: proc "contextless" () {
	if intrinsics.atomic_load(&cpuid_faulting_supported) {
		log("kernel: record and replay: CPUID faulting supported; rdtsc, rdtscp and cpuid trap for recorded and replayed threads only")
	} else {
		log("kernel: record and replay: CPUID faulting not supported on this machine; Record_Start and Replay_Start give Unsupported")
	}
}

// record_traps_load turns on CR4.TSD and CPUID faulting on this processor for
// a recorded or replayed thread, and fixes TSC_AUX when supported.
record_traps_load :: proc "contextless" (cpu: ^Processor) {
	control_register_4_write(replay_filter.cr4_with_timestamp_disable(control_register_4_read(), true))
	misc := model_specific_register_read(replay_filter.MSR_MISC_FEATURES_ENABLES)
	model_specific_register_write(replay_filter.MSR_MISC_FEATURES_ENABLES, replay_filter.misc_features_with_cpuid_faulting(misc, true))
	if intrinsics.atomic_load(&tsc_aux_supported) {
		model_specific_register_write(replay_filter.MSR_TSC_AUX, u64(replay_filter.RECORDED_PROCESSOR_AUXILIARY))
	}
	cpu.record_traps_loaded = true
}

// record_traps_unload clears CR4.TSD and CPUID faulting on this processor so
// normal threads run with no trap overhead.
record_traps_unload :: proc "contextless" (cpu: ^Processor) {
	control_register_4_write(replay_filter.cr4_with_timestamp_disable(control_register_4_read(), false))
	misc := model_specific_register_read(replay_filter.MSR_MISC_FEATURES_ENABLES)
	model_specific_register_write(replay_filter.MSR_MISC_FEATURES_ENABLES, replay_filter.misc_features_with_cpuid_faulting(misc, false))
	cpu.record_traps_loaded = false
}

// region_mapped_writable_by_other says whether any live process other than
// target_index maps region_index with Write permission. Caller holds Control.
@(private = "file")
region_mapped_writable_by_other :: proc "contextless" (target_index: u32, region_index: u32) -> bool {
	for &other, slot in processes[1:] {
		other_index := u32(slot + 1)
		if other_index == target_index {
			continue
		}
		other_taken := process_lock(other_index)
		writable := false
		if other.state != .None && other.state != .Stopped {
			for mapping in other.mappings {
				if mapping.page_count != 0 && mapping.region == region_index && mapping.bits & PAGE_WRITE != 0 {
					writable = true
					break
				}
			}
		}
		process_unlock(other_index, other_taken)
		if writable {
			return true
		}
	}
	return false
}

// region_mapped_by_other says whether any live process other than target_index
// maps region_index at all. Caller holds Control.
@(private = "file")
region_mapped_by_other :: proc "contextless" (target_index: u32, region_index: u32) -> bool {
	for &other, slot in processes[1:] {
		other_index := u32(slot + 1)
		if other_index == target_index {
			continue
		}
		other_taken := process_lock(other_index)
		mapped := false
		if other.state != .None && other.state != .Stopped {
			for mapping in other.mappings {
				if mapping.page_count != 0 && mapping.region == region_index {
					mapped = true
					break
				}
			}
		}
		process_unlock(other_index, other_taken)
		if mapped {
			return true
		}
	}
	return false
}

// process_disqualified_for_recording checks the exclusions: device memory,
// ports, interrupts, IOMMU-declared memory, guests, or writable shared
// mappings. Caller holds Control and target's process lock.
@(private = "file")
process_disqualified_for_recording :: proc "contextless" (target_index: u32) -> bool {
	target := &processes[target_index]
	if target.has_ports || process_is_guest(target_index) {
		return true
	}
	for slot in target.handles {
		if slot.kind == .Ports || slot.kind == .Interrupt {
			return true
		}
		if slot.kind == .Memory {
			region := &regions[slot.object]
			if region.device && slot.object != time_region {
				return true
			}
			if intrinsics.atomic_load(&region.declared) != 0 {
				return true
			}
		}
	}
	for mapping in target.mappings {
		if mapping.page_count == 0 {
			continue
		}
		region := &regions[mapping.region]
		if region.device && mapping.region != time_region {
			return true
		}
		if intrinsics.atomic_load(&region.declared) != 0 {
			return true
		}
		// Refuse a writable mapping shared with another live process.
		if mapping.bits & PAGE_WRITE != 0 && region_mapped_by_other(target_index, mapping.region) {
			return true
		}
	}
	return false
}

// history_region_in_use says whether any active record/replay session already
// owns this memory object. Caller holds Control.
@(private = "file")
history_region_in_use :: proc "contextless" (region_index: u32) -> bool {
	for &rec in process_records[1:] {
		if rec.mode != .None && rec.history_region == region_index {
			return true
		}
	}
	return false
}

// point_copy_frame_allocate takes one physical page frame paid by budget.
@(private = "file")
point_copy_frame_allocate :: proc "contextless" (budget: u32) -> (frame: u64, ok: bool) {
	lock_take(&frame_lock, .Frame)
	if !budgets[budget].live || budgets[budget].amounts.pages == 0 {
		lock_free(&frame_lock, .Frame)
		return 0, false
	}
	frame = frame_take_held()
	if frame == 0 {
		lock_free(&frame_lock, .Frame)
		return 0, false
	}
	budgets[budget].amounts.pages -= 1
	lock_free(&frame_lock, .Frame)
	frames_zero(frame, 1)
	return frame, true
}

// point_copy_frame_free returns one point-copy physical frame and refunds its
// page to budget.
@(private = "file")
point_copy_frame_free :: proc "contextless" (budget: u32, frame: u64) {
	if frame == 0 {
		return
	}
	lock_take(&frame_lock, .Frame)
	frames_free_held(frame, 1)
	if budgets[budget].live {
		budgets[budget].amounts.pages += 1
	}
	lock_free(&frame_lock, .Frame)
}

// point_copies_setup allocates private point copies for every read-only page
// of target that has an external writer (time_region or another live process
// mapping the region with Write). Replaces target's PTEs with the private
// copies. Caller holds Control and target's process lock.
@(private = "file")
point_copies_setup :: proc "contextless" (target_index: u32, rec: ^Process_Record_State, copy_initial: bool) -> Operation_Outcome {
	target := &processes[target_index]
	for &mapping in target.mappings {
		if mapping.page_count == 0 || mapping.bits & PAGE_PRESENT == 0 || mapping.bits & PAGE_WRITE != 0 || mapping.large {
			continue
		}
		has_writer := mapping.region == time_region || region_mapped_writable_by_other(target_index, mapping.region)
		if !has_writer {
			continue
		}
		for page in u64(0) ..< mapping.page_count {
			if rec.point_copy_count >= POINT_COPY_CAPACITY {
				point_copies_teardown(target_index, rec)
				return .No_Slot
			}
			vaddr := mapping.address + page * PAGE_SIZE
			entry := page_entry(target.table, vaddr)
			if entry == nil {
				continue
			}
			copy_frame, allocated := point_copy_frame_allocate(rec.history_budget)
			if !allocated {
				point_copies_teardown(target_index, rec)
				return .No_Budget
			}
			source_page := mapping.first + page
			if copy_initial {
				source_frame := region_frame(&regions[mapping.region], source_page, false)
				if source_frame != 0 {
					direct(copy_frame, [PAGE_SIZE]u8)^ = direct(source_frame, [PAGE_SIZE]u8)^
				}
			}
			original_bits := page_bits(&mapping, region_page_state(&regions[mapping.region], source_page))
			if original_bits == 0 {
				original_bits = mapping.bits
			}
			was_present := entry^ & PAGE_PRESENT != 0
			entry^ = copy_frame | original_bits
			if !was_present {
				mapping.present_page_count += 1
			}
			rec.point_copies[rec.point_copy_count] = {
				virtual_address = vaddr,
				source_region   = mapping.region,
				source_page     = source_page,
				original_bits   = original_bits,
				copy_frame      = copy_frame,
				active          = true,
			}
			rec.point_copy_count += 1
		}
	}
	return .Ok
}

// point_copies_teardown restores original PTEs (if target still has its page
// table) and frees every point copy frame back to rec.history_budget.
// Caller holds target's process lock.
@(private = "file")
point_copies_teardown :: proc "contextless" (target_index: u32, rec: ^Process_Record_State) {
	if rec.point_copy_count == 0 {
		return
	}
	target := &processes[target_index]
	self := processor_self()
	restored_any := false
	for index in u32(0) ..< rec.point_copy_count {
		pc := &rec.point_copies[index]
		if !pc.active {
			continue
		}
		if target.table != 0 {
			if mapping := mapping_at(target, pc.virtual_address); mapping != nil && mapping.region == pc.source_region {
				if entry := page_entry(target.table, pc.virtual_address); entry != nil {
					source_frame := region_frame(&regions[pc.source_region], pc.source_page, false)
					if source_frame != 0 {
						entry^ = source_frame | pc.original_bits
					} else {
						if entry^ & PAGE_PRESENT != 0 {
							mapping.present_page_count -= 1
						}
						entry^ = 0
					}
					if self.table == target.table {
						page_flush(pc.virtual_address)
					}
					restored_any = true
				}
			}
		}
	}
	if restored_any && target.table != 0 {
		intrinsics.atomic_thread_fence(.Seq_Cst)
		processor_sync(processors_with_table(target.table))
	}
	for index in u32(0) ..< rec.point_copy_count {
		pc := &rec.point_copies[index]
		if !pc.active {
			continue
		}
		point_copy_frame_free(rec.history_budget, pc.copy_frame)
		pc^ = {}
	}
	rec.point_copy_count = 0
}

// record_replay_on_unmap releases any point copies inside an unmapped virtual
// address range after unmap cleared and synchronized the PTEs. Caller holds
// process's process lock.
record_replay_on_unmap :: proc "contextless" (process_index: u32, address: u64, page_count: u64) {
	rec := &process_records[process_index]
	if rec.mode == .None || rec.point_copy_count == 0 {
		return
	}
	end := address + page_count * PAGE_SIZE
	for index in u32(0) ..< rec.point_copy_count {
		pc := &rec.point_copies[index]
		if pc.active && pc.virtual_address >= address && pc.virtual_address < end {
			point_copy_frame_free(rec.history_budget, pc.copy_frame)
			pc^ = {}
		}
	}
}

// record_replay_map_conflict checks whether a new writable mapping conflicts
// with an active recorded process. Called from map_region under process lock.
record_replay_map_conflict :: proc "contextless" (process_index: u32, region_index: u32, flags: op.Map_Flags) -> bool {
	if intrinsics.atomic_load(&record_replay_active_count) == 0 || .Write not_in flags {
		return false
	}
	// If the mapping process itself is being recorded, refuse a writable region
	// that has more than one reference outside this process.
	if process_records[process_index].mode == .Recording {
		if intrinsics.atomic_load(&regions[region_index].references) > 1 {
			return true
		}
	}
	return false
}

// main_module_hash_of gives the BLAKE3 hash of the main module of process,
// or all zeros if no module record was registered.
@(private = "file")
main_module_hash_of :: proc "contextless" (process: ^Process) -> [32]u8 {
	for item in process.modules {
		if item.size != 0 && item.base == op.PROCESS_BASE {
			return item.hash
		}
	}
	for item in process.modules {
		if item.size != 0 {
			return item.hash
		}
	}
	return {}
}

// record_replay_control handles Record_Start, Record_End, and Replay_Start
// commands of Thread_Control. Caller holds caller_process's process lock.
record_replay_control :: proc "contextless" (caller_index: u32, caller_process: ^Process, command: op.Thread_Control_Command, v: [7]u64, results: ^[7]u64) -> Operation_Outcome {
	_ = results
	if v[0] == 0 {
		return .Bad_Handle
	}
	target_slot := handle_find(caller_process, v[0], .Process, {.Debug}) or_return
	target_index := target_slot.object
	caller_process_index := index_of_process(caller_process)
	if target_index == caller_process_index {
		return .Bad_State
	}
	// Record_Start and Replay_Start require CPUID faulting on every processor.
	if (command == .Record_Start || command == .Replay_Start) && !intrinsics.atomic_load(&cpuid_faulting_supported) {
		return .Bad_Operation
	}
	require_control() or_return
	target_taken := process_lock(target_index)
	defer process_unlock(target_index, target_taken)
	target := &processes[target_index]
	if target.state == .None || target.state == .Stopped {
		return .Bad_State
	}
	rec := &process_records[target_index]
	switch command {
	case .Record_Start:
		if target.state != .Created || rec.mode != .None {
			return .Bad_State
		}
		if process_disqualified_for_recording(target_index) {
			return .Bad_State
		}
		memory_slot := handle_find(caller_process, v[1], .Memory, {.Read, .Write}) or_return
		region_index := memory_slot.object
		region := &regions[region_index]
		if !region.contiguous || region.device || region.page_count * PAGE_SIZE < input_history.MIN_HISTORY_BUFFER_BYTES {
			return .Bad_Operation
		}
		if history_region_in_use(region_index) {
			return .Bad_State
		}
		history_buffer := ([^]u8)(direct(region.physical, u8))[:region.page_count * PAGE_SIZE]
		writer, writer_ok := input_history.history_writer_init(
			history_buffer,
			main_module_hash_of(target),
			cycle_frequency,
			cycle_start,
			transmute(u64)extended_state_components,
		)
		if !writer_ok {
			return .Bad_Operation
		}
		intrinsics.mem_zero(rec, size_of(Process_Record_State))
		rec.mode = .Recording
		rec.recorder_process = caller_process_index
		rec.recorder_serial = caller_process.serial
		rec.history_region = region_index
		rec.history_budget = region.budget
		rec.history_buffer = history_buffer
		rec.writer = writer
		rec.pinned_processor = processor_self().index
		if setup_status := point_copies_setup(target_index, rec, copy_initial = true); setup_status != .Ok {
			intrinsics.mem_zero(rec, size_of(Process_Record_State))
			return setup_status
		}
		// Record initial non-zero point copy contents into the history so replay
		// starts with the exact same read-only shared page values.
		cpu := processor_self()
		for index in u32(0) ..< rec.point_copy_count {
			pc := &rec.point_copies[index]
			if !pc.active {
				continue
			}
			after_page := direct(pc.copy_frame, [PAGE_SIZE]u8)
			written, changed, ok := input_history.page_delta_encode(pc.virtual_address, &record_zero_page, after_page, cpu.page_delta_scratch[:])
			if !ok || (changed && !input_history.history_writer_append(&rec.writer, .Page_Delta, 0, 0, cpu.page_delta_scratch[:written])) {
				point_copies_teardown(target_index, rec)
				intrinsics.mem_zero(rec, size_of(Process_Record_State))
				return .Bad_Operation
			}
		}
		intrinsics.atomic_add(&region.references, 1)
		intrinsics.atomic_add(&record_replay_active_count, 1)
		return .Ok

	case .Record_End:
		if rec.mode == .None || rec.recorder_process != caller_process_index || rec.recorder_serial != caller_process.serial {
			return .Bad_State
		}
		record_replay_end_locked(target_index, .Recorder_Stopped)
		return .Ok

	case .Replay_Start:
		if target.state != .Created || rec.mode != .None {
			return .Bad_State
		}
		if process_disqualified_for_recording(target_index) {
			return .Bad_State
		}
		memory_slot := handle_find(caller_process, v[1], .Memory, {.Read, .Write}) or_return
		region_index := memory_slot.object
		region := &regions[region_index]
		if !region.contiguous || region.device || region.page_count * PAGE_SIZE < size_of(input_history.History_Header) {
			return .Bad_Operation
		}
		if history_region_in_use(region_index) {
			return .Bad_State
		}
		history_buffer := ([^]u8)(direct(region.physical, u8))[:region.page_count * PAGE_SIZE]
		reader, reader_ok := input_history.history_reader_open(history_buffer)
		if !reader_ok {
			return .Bad_Operation
		}
		// Refuse replay on a machine missing extended state components recorded in the history.
		if reader.header.xcr0_components & ~transmute(u64)extended_state_components != 0 {
			return .Bad_Operation
		}
		intrinsics.mem_zero(rec, size_of(Process_Record_State))
		rec.mode = .Replaying
		rec.recorder_process = caller_process_index
		rec.recorder_serial = caller_process.serial
		rec.history_region = region_index
		rec.history_budget = region.budget
		rec.history_buffer = history_buffer
		rec.reader = reader
		rec.pinned_processor = processor_self().index
		if setup_status := point_copies_setup(target_index, rec, copy_initial = false); setup_status != .Ok {
			intrinsics.mem_zero(rec, size_of(Process_Record_State))
			return setup_status
		}
		intrinsics.atomic_add(&region.references, 1)
		intrinsics.atomic_add(&record_replay_active_count, 1)
		return .Ok

	case .None, .Stop, .Resume, .Read_Registers, .Write_Registers, .Read_Extended_State, .Write_Extended_State, .Read_Schedule, .Write_Schedule, .Read_Breakpoints, .Write_Breakpoints, .Read_Memory, .Read_Placement, .Write_Placement, .Read_Process_Schedule, .Write_Process_Schedule, .Start_Counters, .Read_Counters, .Stop_Counters:
		return .Bad_Operation
	}
	return .Bad_Operation
}

// record_replay_thread_init attaches a newly created thread to its process's
// record or replay mode and narrows its processor placement to the single
// pinned processor. Caller holds Control and process lock.
record_replay_thread_init :: proc "contextless" (process_index: u32, thread: ^Thread) {
	rec := &process_records[process_index]
	if rec.mode == .None {
		return
	}
	intrinsics.atomic_store(&thread.record_mode, rec.mode)
	pinned_mask := u64(1) << rec.pinned_processor
	every_processor := machine_processors()
	if pinned_mask & every_processor == 0 {
		pinned_mask = u64(1)
	}
	intrinsics.atomic_store(&thread.processors, pinned_mask)
	intrinsics.atomic_store(&thread.processors_limit, pinned_mask)
	intrinsics.atomic_store(&thread.placement_restricted, pinned_mask != every_processor)
}

// record_replay_end_locked ends recording or replay of target_index, writes
// the end record or header summary, clears thread record modes, restores point
// copies, and releases the history region reference.
// Caller holds Control lock and target_index's process lock.
record_replay_end_locked :: proc "contextless" (target_index: u32, reason: input_history.History_End_Reason, div_kind: input_history.Divergence_Kind = .None, div_point: u64 = 0, div_expected: u64 = 0, div_actual: u64 = 0) {
	rec := &process_records[target_index]
	if rec.mode == .None {
		return
	}
	mode := rec.mode
	if mode == .Recording {
		if !rec.writer.ended {
			if !input_history.history_writer_append_end(&rec.writer, 0, 0, reason, div_kind, div_expected, div_actual) {
				_ = input_history.history_header_record_end(rec.history_buffer, reason, div_kind, div_point, div_expected, div_actual)
			}
		}
	} else {
		_ = input_history.history_header_record_end(rec.history_buffer, reason, div_kind, div_point, div_expected, div_actual)
	}
	for &thread in threads[1:] {
		if thread.process == target_index {
			intrinsics.atomic_store(&thread.record_mode, input_history.Record_Mode.None)
		}
	}
	point_copies_teardown(target_index, rec)
	history_region := rec.history_region
	intrinsics.mem_zero(rec, size_of(Process_Record_State))
	intrinsics.atomic_sub(&record_replay_active_count, 1)
	switch reason {
	case .Stint_Bound_Reached:
		log_with_level(.Warning, "kernel: process ", Module_Name{process_name(&processes[target_index])}, ": input history ended: stint bound reached without an input point")
	case .Revocation:
		log_with_level(.Info, "kernel: process ", Module_Name{process_name(&processes[target_index])}, ": input history ended immediately on revocation")
	case .Buffer_Full:
		log_with_level(.Warning, "kernel: process ", Module_Name{process_name(&processes[target_index])}, ": input history ended: history buffer full")
	case .Divergence:
		log_with_level(.Warning, "kernel: process ", Module_Name{process_name(&processes[target_index])}, ": replay stopped on divergence kind ", u64(div_kind), " at point ", div_point)
	case .Normal_Stop, .Recorder_Stopped, .None:
	}
	region_release(history_region)
}

// record_right_closed ends recording or replay when a recorder closes or loses
// its last Process handle with Debug on the target process. Caller holds
// Control lock and holder's process lock.
record_right_closed :: proc "contextless" (holder: ^Process, closed: ^Handle_Slot) {
	if intrinsics.atomic_load(&record_replay_active_count) == 0 {
		return
	}
	target_index := closed.object
	holder_index := index_of_process(holder)
	rec := &process_records[target_index]
	if rec.mode == .None || rec.recorder_process != holder_index || rec.recorder_serial != holder.serial {
		return
	}
	for &slot in holder.handles {
		if &slot != closed && slot.kind == .Process && slot.object == target_index && .Debug in slot.rights {
			return
		}
	}
	taken := process_lock(target_index)
	record_replay_end_locked(target_index, .Recorder_Stopped)
	process_unlock(target_index, taken)
}

// record_replay_recorder_stopped ends every recording/replay owned by a
// recorder process that stopped. Caller holds Control lock and no process lock.
record_replay_recorder_stopped :: proc "contextless" (recorder_index: u32, recorder_serial: u32) {
	if intrinsics.atomic_load(&record_replay_active_count) == 0 {
		return
	}
	for target_index in u32(1) ..< PROCESS_CAPACITY {
		rec := &process_records[target_index]
		if rec.mode != .None && rec.recorder_process == recorder_index && rec.recorder_serial == recorder_serial {
			taken := process_lock(target_index)
			record_replay_end_locked(target_index, .Recorder_Stopped)
			process_unlock(target_index, taken)
		}
	}
}

// record_replay_on_revocation ends an active recording immediately when a
// revocation ends a holding of process_index. Caller holds Control and
// process_index's process lock. Never delays revocation.
record_replay_on_revocation :: proc "contextless" (process_index: u32) {
	if process_records[process_index].mode == .Recording {
		record_replay_end_locked(process_index, .Revocation)
	}
}

// record_replay_stint_start notes the current point count when a recorded
// thread begins a scheduler stint.
record_replay_stint_start :: proc "contextless" (process_index: u32) {
	rec := &process_records[process_index]
	if rec.mode == .Recording {
		rec.stint_start_point = rec.writer.point_count
	}
}

// record_replay_stint_bound_check enforces the one-stint bound: if a recorded
// thread ran an entire time slice without reaching any input point, end the
// input history immediately so no peer or sibling waits indefinitely.
// Caller holds no locks (called from VECTOR_TIMER).
record_replay_stint_bound_check :: proc "contextless" (thread: ^Thread) {
	process_index := thread.process
	if process_records[process_index].mode != .Recording {
		return
	}
	if process_records[process_index].writer.point_count != process_records[process_index].stint_start_point {
		return
	}
	control_take()
	taken := process_lock(process_index)
	if process_records[process_index].mode == .Recording && process_records[process_index].writer.point_count == process_records[process_index].stint_start_point {
		record_replay_end_locked(process_index, .Stint_Bound_Reached)
	}
	process_unlock(process_index, taken)
	control_free()
}

// record_refresh_point_copies_locked compares each active point copy against
// its live shared page, appends a Page_Delta record when bytes changed, and
// refreshes the point copy. Returns false if the history buffer is full.
// Caller holds process_index's process lock.
@(private = "file")
record_refresh_point_copies_locked :: proc "contextless" (cpu: ^Processor, process_index: u32, thread: ^Thread) -> bool {
	rec := &process_records[process_index]
	for index in u32(0) ..< rec.point_copy_count {
		pc := &rec.point_copies[index]
		if !pc.active {
			continue
		}
		source_frame := region_frame(&regions[pc.source_region], pc.source_page, false)
		if source_frame == 0 {
			continue
		}
		before_page := direct(pc.copy_frame, [PAGE_SIZE]u8)
		after_page := direct(source_frame, [PAGE_SIZE]u8)
		written, changed, ok := input_history.page_delta_encode(pc.virtual_address, before_page, after_page, cpu.page_delta_scratch[:])
		if !ok {
			return false
		}
		if !changed {
			continue
		}
		if !input_history.history_writer_append(&rec.writer, .Page_Delta, thread.frame.rip, thread.frame.rsp, cpu.page_delta_scratch[:written]) {
			return false
		}
		before_page^ = after_page^
	}
	return true
}

// replay_apply_pending_page_deltas_locked consumes every leading Page_Delta
// record from rec.reader and applies it to the matching private point copy (or
// mapped page) of process_index. Returns false if a Page_Delta is malformed or
// targets an unmapped page. Caller holds process_index's process lock.
@(private = "file")
replay_apply_pending_page_deltas_locked :: proc "contextless" (process_index: u32) -> bool {
	rec := &process_records[process_index]
	process := &processes[process_index]
	for {
		_, kind, payload, stride, has_more, ok := input_history.history_reader_peek(&rec.reader)
		if !ok {
			return false
		}
		if !has_more || kind != .Page_Delta {
			return true
		}
		delta_header, delta_ok := input_history.page_delta_validate(payload)
		if !delta_ok {
			return false
		}
		// Find the physical frame to patch: prefer private point copy, else
		// mapped writable page of the replay process.
		target_frame: u64
		for index in u32(0) ..< rec.point_copy_count {
			pc := &rec.point_copies[index]
			if pc.active && pc.virtual_address == delta_header.virtual_address {
				target_frame = pc.copy_frame
				break
			}
		}
		if target_frame == 0 {
			if mapping := mapping_at(process, delta_header.virtual_address); mapping != nil && mapping.region != time_region && !regions[mapping.region].device {
				page := (delta_header.virtual_address - mapping.address) / PAGE_SIZE
				target_frame = region_frame(&regions[mapping.region], mapping.first + page, true)
			}
		}
		if target_frame == 0 {
			return false
		}
		if !input_history.page_delta_apply(payload, direct(target_frame, [PAGE_SIZE]u8)) {
			return false
		}
		rec.reader.read_offset += stride
	}
}

// replay_stop_on_divergence records a divergence in the history header, tears
// down replay mode, and stops the replayed process immediately.
// Caller holds NO locks.
@(private = "file")
replay_stop_on_divergence :: proc "contextless" (process_index: u32, div_kind: input_history.Divergence_Kind, point, expected, actual: u64) {
	control_take()
	taken := process_lock(process_index)
	record_replay_end_locked(process_index, .Divergence, div_kind, point, expected, actual)
	process_unlock(process_index, taken)
	process_stop(process_index, .Holder, .None)
	control_free()
}

// record_end_on_buffer_full ends recording cleanly when the history buffer
// fills up so no input is silently dropped. Caller holds NO locks.
@(private = "file")
record_end_on_buffer_full :: proc "contextless" (process_index: u32) {
	control_take()
	taken := process_lock(process_index)
	record_replay_end_locked(process_index, .Buffer_Full)
	process_unlock(process_index, taken)
	control_free()
}

// record_replay_handle_gp handles #GP from a recorded or replayed user thread.
// When the faulting instruction is rdtsc (0F 31), rdtscp (0F 01 F9), or cpuid
// (0F A2), it emulates the instruction, records or replays its result, advances
// RIP, and returns true so the fault is never delivered to a user handler.
// Caller holds NO locks.
record_replay_handle_gp :: proc "contextless" (cpu: ^Processor, thread: ^Thread) -> bool {
	if thread.frame.error != 0 {
		return false
	}
	process_index := thread.process
	process := &processes[process_index]
	taken := process_lock(process_index)
	rec := &process_records[process_index]
	mode := rec.mode
	if mode == .None {
		process_unlock(process_index, taken)
		return false
	}
	// Read up to 3 instruction bytes safely through the direct map.
	instruction_bytes: [3]u8
	byte_count := 0
	for offset in u64(0) ..< 3 {
		if thread.frame.rip > USER_END - 1 - offset {
			break
		}
		pb := process_byte_read(process, thread.frame.rip + offset)
		if !pb.readable {
			break
		}
		instruction_bytes[offset] = pb.value
		byte_count += 1
	}
	decoded := replay_filter.decode_trapped_instruction(instruction_bytes[:byte_count])
	if decoded.kind == .None {
		process_unlock(process_index, taken)
		return false
	}

	if mode == .Recording {
		rip := thread.frame.rip
		rsp := thread.frame.rsp
		buffer_ok := record_refresh_point_copies_locked(cpu, process_index, thread)
		switch decoded.kind {
		case .None:
		case .Rdtsc:
			cycles := cycles_now()
			thread.frame.rax = u64(u32(cycles))
			thread.frame.rdx = u64(u32(cycles >> 32))
			thread.frame.rip += u64(decoded.length)
			if buffer_ok {
				buffer_ok = input_history.history_writer_append_cycle_counter(&rec.writer, rip, rsp, {
					cycles              = cycles,
					processor_auxiliary = 0,
					is_rdtscp           = 0,
				})
			}
		case .Rdtscp:
			cycles := cycles_now()
			aux := replay_filter.RECORDED_PROCESSOR_AUXILIARY
			thread.frame.rax = u64(u32(cycles))
			thread.frame.rdx = u64(u32(cycles >> 32))
			thread.frame.rcx = u64(aux)
			thread.frame.rip += u64(decoded.length)
			if buffer_ok {
				buffer_ok = input_history.history_writer_append_cycle_counter(&rec.writer, rip, rsp, {
					cycles              = cycles,
					processor_auxiliary = aux,
					is_rdtscp           = 1,
				})
			}
		case .Cpuid:
			leaf := u32(thread.frame.rax)
			subleaf := u32(thread.frame.rcx)
			a, b, c, d := intrinsics.x86_cpuid(leaf, subleaf)
			filtered := replay_filter.filter_cpuid_result(leaf, subleaf, {a, b, c, d})
			thread.frame.rax = u64(filtered.eax)
			thread.frame.rbx = u64(filtered.ebx)
			thread.frame.rcx = u64(filtered.ecx)
			thread.frame.rdx = u64(filtered.edx)
			thread.frame.rip += u64(decoded.length)
			if buffer_ok {
				buffer_ok = input_history.history_writer_append_cpuid(&rec.writer, rip, rsp, {
					leaf    = leaf,
					subleaf = subleaf,
					eax     = filtered.eax,
					ebx     = filtered.ebx,
					ecx     = filtered.ecx,
					edx     = filtered.edx,
				})
			}
		}
		process_unlock(process_index, taken)
		if !buffer_ok {
			record_end_on_buffer_full(process_index)
		}
		return true
	}

	// Replaying mode.
	if !replay_apply_pending_page_deltas_locked(process_index) {
		process_unlock(process_index, taken)
		replay_stop_on_divergence(process_index, .Missing_Record, rec.reader.read_offset, 0, 0)
		return true
	}
	actual := input_history.Replay_Actual_Event {
		instruction_address = thread.frame.rip,
		stack_pointer       = thread.frame.rsp,
	}
	switch decoded.kind {
	case .None:
	case .Rdtsc:
		actual.kind = .Cycle_Counter
		actual.is_rdtscp = 0
	case .Rdtscp:
		actual.kind = .Cycle_Counter
		actual.is_rdtscp = 1
	case .Cpuid:
		actual.kind = .Processor_Identification
		actual.cpuid_leaf = u32(thread.frame.rax)
		actual.cpuid_subleaf = u32(thread.frame.rcx)
	}
	rec_header, rec_kind, rec_payload, has_more, read_ok := input_history.history_reader_next(&rec.reader)
	check := input_history.replay_step_check(actual, read_ok && has_more, rec_header, rec_kind, rec_payload)
	if check.divergence != .None {
		point := rec_header.point_number
		process_unlock(process_index, taken)
		replay_stop_on_divergence(process_index, check.divergence, point, check.expected, check.actual)
		return true
	}
	switch decoded.kind {
	case .None:
	case .Rdtsc:
		payload, _ := input_history.cycle_counter_from_payload(rec_payload)
		thread.frame.rax = u64(u32(payload.cycles))
		thread.frame.rdx = u64(u32(payload.cycles >> 32))
		thread.frame.rip += u64(decoded.length)
	case .Rdtscp:
		payload, _ := input_history.cycle_counter_from_payload(rec_payload)
		thread.frame.rax = u64(u32(payload.cycles))
		thread.frame.rdx = u64(u32(payload.cycles >> 32))
		thread.frame.rcx = u64(payload.processor_auxiliary)
		thread.frame.rip += u64(decoded.length)
	case .Cpuid:
		payload, _ := input_history.cpuid_from_payload(rec_payload)
		thread.frame.rax = u64(payload.eax)
		thread.frame.rbx = u64(payload.ebx)
		thread.frame.rcx = u64(payload.ecx)
		thread.frame.rdx = u64(payload.edx)
		thread.frame.rip += u64(decoded.length)
	}
	process_unlock(process_index, taken)
	return true
}

// record_command_output_range gives the user-space buffer written by a
// succeeded kernel command, if any, so the recorder captures those bytes.
@(private = "file")
record_command_output_range :: proc "contextless" (command: ring.Record, status: op.Status, results: [7]u64) -> (address: u64, size: u64) {
	if status != .Ok {
		return 0, 0
	}
	operation, known := enum_word.member_of_word(op.Operation, u64(command.kind &~ op.COMMAND_NAMES_ERROR_DETAILS))
	if !known {
		return 0, 0
	}
	v := command.values
	switch operation {
	case .Process_State:
		if v[1] != 0 {
			return v[1], size_of(op.Stop_Report)
		}
	case .Inspect:
		return v[3], results[0]
	case .Log_Read:
		return v[4], results[0] * size_of(op.Log_Record)
	case .Thread_Control:
		sub, sub_ok := enum_word.member_of_word(op.Thread_Control_Command, v[2])
		if !sub_ok {
			return 0, 0
		}
		switch sub {
		case .Read_Registers, .Read_Extended_State, .Read_Schedule, .Read_Breakpoints, .Read_Memory, .Read_Placement, .Read_Process_Schedule, .Read_Counters:
			return v[3], results[0]
		case .None, .Stop, .Resume, .Write_Registers, .Write_Extended_State, .Write_Schedule, .Write_Breakpoints, .Write_Placement, .Write_Process_Schedule, .Start_Counters, .Stop_Counters, .Record_Start, .Record_End, .Replay_Start:
		}
	case .None, .Log, .Memory_Create, .Memory_Map, .Memory_Unmap, .Memory_Size, .Process_Create, .Process_Start, .Process_Stop, .Handle_Give, .Handle_Close, .Interrupt_Read, .Device_Create, .Machine_Stop, .Thread_Create, .Thread_Stop, .Thread_State, .Word_Wait, .Word_Wake, .Budget_Create, .Budget_Read, .Handle_State, .Handle_Revoke, .Memory_Physical, .Process_Module, .Strategy_Set, .Memory_Commit, .Memory_Protect, .Fault_Handler_Set, .Fault_Answer, .Events_Set, .Guest_Run:
	}
	return 0, 0
}

// record_kernel_completion records one executed kernel command (or a
// zero-command wait entry) and refreshes point copies. Called from enter()
// with NO locks held.
record_kernel_completion :: proc "contextless" (cpu: ^Processor, thread: ^Thread, command: ring.Record, status: op.Status, completion_values: [7]u64) {
	process_index := thread.process
	process := &processes[process_index]
	return_time := intrinsics.atomic_load(&time_milliseconds)
	taken := process_lock(process_index)
	rec := &process_records[process_index]
	if rec.mode != .Recording {
		process_unlock(process_index, taken)
		return
	}
	rec.replay_return_time = return_time
	buffer_ok := record_refresh_point_copies_locked(cpu, process_index, thread)
	copied_slice: []u8
	copied_address: u64
	if buffer_ok {
		out_address, out_size := record_command_output_range(command, status, completion_values)
		if out_size > 0 {
			if out_size > RECORD_COPY_SCRATCH_BYTES || !user_range(process, out_address, out_size, false) {
				buffer_ok = false
			} else {
				user_copy(&cpu.record_copy_scratch[0], rawptr(uintptr(out_address)), out_size)
				copied_slice = cpu.record_copy_scratch[:out_size]
				copied_address = out_address
			}
		}
	}
	if buffer_ok {
		entry := input_history.Kernel_Completion_Payload {
			command_kind             = command.kind,
			command_tag              = command.tag,
			command_values           = command.values,
			completion_status        = u32(status),
			copied_bytes_count       = u32(len(copied_slice)),
			completion_values        = completion_values,
			return_time_milliseconds = return_time,
			copied_user_address      = copied_address,
		}
		buffer_ok = input_history.history_writer_append_kernel_completion(&rec.writer, thread.frame.rip, thread.frame.rsp, entry, copied_slice)
	}
	process_unlock(process_index, taken)
	if !buffer_ok {
		record_end_on_buffer_full(process_index)
	}
}

// record_replay_entry_return_time gives the recorded return time for rax in
// run() so recorded and replayed threads see the exact millisecond value
// written into the input history.
record_replay_entry_return_time :: proc "contextless" (process_index: u32) -> u64 {
	rec := &process_records[process_index]
	if rec.mode == .None {
		return intrinsics.atomic_load(&time_milliseconds)
	}
	return rec.replay_return_time
}

// replay_enter handles a kernel entry of a replayed thread: validates each
// command against the recorded input history, executes only local
// address-space/thread commands for real (never side-effecting handle ops),
// replays recorded completions and copied bytes, and applies page deltas.
replay_enter :: proc "contextless" (cpu: ^Processor, index: u32) {
	thread := &threads[index]
	process_index := thread.process
	process := &processes[process_index]
	intrinsics.atomic_add(&process.entries, 1)
	thread.in_enter = true
	wait_begin(thread)

	// Pure wait/yield entry with no commands in the ring.
	if ring.empty(&thread.ring.commands) {
		taken := process_lock(process_index)
		rec := &process_records[process_index]
		if rec.mode != .Replaying {
			process_unlock(process_index, taken)
			return
		}
		if !replay_apply_pending_page_deltas_locked(process_index) {
			process_unlock(process_index, taken)
			replay_stop_on_divergence(process_index, .Missing_Record, rec.reader.read_offset, 0, 0)
			return
		}
		actual := input_history.Replay_Actual_Event {
			kind                = .Kernel_Completion,
			instruction_address = thread.frame.rip,
			stack_pointer       = thread.frame.rsp,
			command_kind        = 0,
			command_tag         = 0,
			command_values      = {0 = thread.frame.rdi},
		}
		rec_header, rec_kind, rec_payload, has_more, read_ok := input_history.history_reader_next(&rec.reader)
		check := input_history.replay_step_check(actual, read_ok && has_more, rec_header, rec_kind, rec_payload)
		if check.divergence != .None {
			point := rec_header.point_number
			process_unlock(process_index, taken)
			replay_stop_on_divergence(process_index, check.divergence, point, check.expected, check.actual)
			return
		}
		kc, _, _ := input_history.kernel_completion_from_payload(rec_payload)
		rec.replay_return_time = kc.return_time_milliseconds
		_ = replay_apply_pending_page_deltas_locked(process_index)
		process_unlock(process_index, taken)
		// Do not sleep in replay mode: return immediately with recorded time.
		return
	}

	for _ in 0 ..< ring.CAPACITY {
		if ring.empty(&thread.ring.commands) {
			break
		}
		if ring.full(&thread.ring.completions) {
			thread.word_changed = true
			break
		}
		command, popped := ring.pop(&thread.ring.commands)
		if !popped {
			break
		}
		taken := process_lock(process_index)
		rec := &process_records[process_index]
		if rec.mode != .Replaying {
			process_unlock(process_index, taken)
			return
		}
		if !replay_apply_pending_page_deltas_locked(process_index) {
			process_unlock(process_index, taken)
			replay_stop_on_divergence(process_index, .Missing_Record, rec.reader.read_offset, 0, 0)
			return
		}
		actual := input_history.Replay_Actual_Event {
			kind                = .Kernel_Completion,
			instruction_address = thread.frame.rip,
			stack_pointer       = thread.frame.rsp,
			command_kind        = command.kind,
			command_tag         = command.tag,
			command_values      = command.values,
		}
		rec_header, rec_kind, rec_payload, has_more, read_ok := input_history.history_reader_next(&rec.reader)
		check := input_history.replay_step_check(actual, read_ok && has_more, rec_header, rec_kind, rec_payload)
		if check.divergence != .None {
			point := rec_header.point_number
			process_unlock(process_index, taken)
			replay_stop_on_divergence(process_index, check.divergence, point, check.expected, check.actual)
			return
		}
		kc, copied_bytes, _ := input_history.kernel_completion_from_payload(rec_payload)
		rec.replay_return_time = kc.return_time_milliseconds
		// Copy recorded output bytes into user memory when present.
		copy_failed := false
		if len(copied_bytes) > 0 && kc.copied_user_address != 0 {
			if user_range(process, kc.copied_user_address, u64(len(copied_bytes)), true) {
				user_copy(rawptr(uintptr(kc.copied_user_address)), raw_data(copied_bytes), u64(len(copied_bytes)))
			} else {
				copy_failed = true
			}
		}
		process_unlock(process_index, taken)
		if copy_failed {
			replay_stop_on_divergence(process_index, .Unexpected_Arguments, rec_header.point_number, kc.copied_user_address, 0)
			return
		}

		// Run only local address-space and thread operations for real when the
		// recorded operation succeeded; never execute side-effecting handle ops.
		operation, op_known := enum_word.member_of_word(op.Operation, u64(command.kind &~ op.COMMAND_NAMES_ERROR_DETAILS))
		recorded_status, status_known := enum_word.member_of_word(op.Status, u64(kc.completion_status))
		if op_known && status_known && recorded_status == .Ok && replay_filter.replay_operation_policy(operation) == .Real_Local {
			run_local := true
			exec_command := command
			switch operation {
			case .Memory_Map:
				if exec_command.values[1] != 0 {
					run_local = false
				} else if exec_command.values[2] == 0 {
					// Map at the exact virtual address chosen during recording.
					exec_command.values[2] = kc.completion_values[0]
				}
			case .Memory_Unmap, .Process_Stop:
				if exec_command.values[0] != 0 {
					run_local = false
				}
			case .Thread_Stop:
				if exec_command.values[0] != 0 {
					run_local = false
				}
			case .Memory_Create, .Memory_Commit, .Memory_Protect, .Thread_Create:
			case .None, .Log, .Memory_Size, .Process_Create, .Process_Start, .Process_State, .Handle_Give, .Handle_Close, .Interrupt_Read, .Device_Create, .Inspect, .Machine_Stop, .Thread_State, .Word_Wait, .Word_Wake, .Budget_Create, .Budget_Read, .Handle_State, .Handle_Revoke, .Memory_Physical, .Process_Module, .Strategy_Set, .Fault_Handler_Set, .Fault_Answer, .Events_Set, .Thread_Control, .Guest_Run, .Log_Read:
				run_local = false
			}
			if run_local {
				real_results: [7]u64
				real_status := command_run(index, exec_command, &real_results)
				if intrinsics.atomic_load(&thread.stop_requested) {
					return
				}
				if real_status != recorded_status {
					replay_stop_on_divergence(process_index, .Unexpected_Operation, rec_header.point_number, u64(recorded_status), u64(real_status))
					return
				}
			}
		}

		completion := ring.Record {
			kind   = kc.completion_status,
			tag    = command.tag,
			values = kc.completion_values,
		}
		_ = ring.push(&thread.ring.completions, completion)
	}
	// Apply any trailing Page_Delta records before returning to user mode.
	taken := process_lock(process_index)
	if process_records[process_index].mode == .Replaying {
		_ = replay_apply_pending_page_deltas_locked(process_index)
	}
	process_unlock(process_index, taken)
}
