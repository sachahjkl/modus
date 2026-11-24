package kernel

import "modulus:budget_peak"
import "base:intrinsics"
import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import "modus:contract/input_history"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modulus:replay_filter"

// Process input record and replay in the kernel
// (src/md/features/record_and_replay.md).
//
// A recorded or replayed process runs single-threaded on one pinned processor
// with CR4.TSD and CPUID faulting enabled whenever its thread runs. Normal
// threads pay one test of a byte in the hot cache line of Thread at each
// switch and zero MSR or CR4 writes.
//
// Read-only shared pages (such as the time page and read-only pages written by
// another process) are backed by private point copies paid by the budget of
// the history memory object. At each input point while recording, the kernel
// snapshots each live shared page once into per-processor scratch memory,
// diffs it against the point copy, writes changed byte ranges into the input
// history, and updates the point copy from the snapshot. Pages that the
// recorded process and a shared writer both map with Write are recorded at
// the leave of each input point ("Shared writers" below). On replay, each
// record is copied once into private per-processor scratch memory before
// validation, and a Page_Delta applies to a tracked point copy, or else to a
// page that the replayed process maps with Write (a shared page or the
// context page of the record), never to any other page.

POINT_COPY_CAPACITY :: 32
// The pages that a recorded process maps with Write and that another
// process maps with Write too: one baseline frame each, paid by the budget
// of the history. Each kernel entry copies them once, so the count bounds
// the cost of an entry.
SHARED_PAGE_CAPACITY :: 64
// The longest wait of a shared writer for the recorded thread: one stint.
SHARED_WRITER_WAIT_BOUND_MILLISECONDS :: TIME_SLICE * 1000 / TICKS_PER_SECOND
RECORD_COPY_SCRATCH_BYTES :: 8192
REPLAY_RECORD_SCRATCH_BYTES :: size_of(input_history.Kernel_Completion_Payload) + RECORD_COPY_SCRATCH_BYTES

#assert(REPLAY_RECORD_SCRATCH_BYTES >= input_history.PAGE_DELTA_MAX_BYTES)
// A replay maps a stand-in mapping for each mapping that a record names, and
// a record names at most one for each point copy and each shared page.
#assert(input_history.STAND_IN_MAPPING_CAPACITY == POINT_COPY_CAPACITY + SHARED_PAGE_CAPACITY)
#assert(input_history.STAND_IN_PAGE_LIMIT == u64(POINT_COPY_CAPACITY + SHARED_PAGE_CAPACITY))
#assert(REPLAY_RECORD_SCRATCH_BYTES >= size_of(input_history.Cycle_Counter_Payload))
#assert(REPLAY_RECORD_SCRATCH_BYTES >= size_of(input_history.Cpuid_Payload))
#assert(REPLAY_RECORD_SCRATCH_BYTES >= size_of(input_history.History_End_Payload))

// One private page frame backing a read-only shared page of a recorded or
// replayed process. Paid by the current budget of Process_Record_State.history_region.
Point_Copy :: struct {
	virtual_address: u64, // Page-aligned user virtual address in the target process.
	source_region:   u32, // Original memory object (e.g. time_region).
	source_page:     u64, // Page index inside source_region.
	original_bits:   u64, // Page table permission bits when the point copy was installed.
	copy_frame:      u64, // Physical frame of the private copy.
	active:          bool,
}

// One page that the recorded process and a shared writer both map with
// Write. The baseline holds the bytes of the page when the recorded thread
// last reached an input point: the diff at its leave gives what the writers
// wrote meanwhile.
Shared_Page :: struct {
	virtual_address: u64, // Page-aligned user virtual address in the recorded process.
	region:          u32, // The shared memory object.
	page:            u64, // Page index inside region.
	baseline_frame:  u64, // Physical frame of the baseline copy.
	active:          bool,
}

// A mapping that a recorded process made, after its start, of memory that
// another process holds, whose Shared_Mapping record waits for the
// Kernel_Completion of its Memory_Map: the replay reads the completion
// first, and maps its stand-in mapping at the recorded address.
Pending_Shared_Mapping :: struct {
	virtual_address: u64,
	page_count:      u64,
	access:          input_history.Shared_Mapping_Access,
	active:          bool,
}

// Per-process record/replay state, indexed by process slot. Kept out of
// Process so unrecorded processes pay no cache footprint.
Process_Record_State :: struct {
	mode:              input_history.Record_Mode,
	recorder_process:  u32, // Process slot of the recorder or replayer.
	recorder_serial:   u32, // Serial of the recorder or replayer.
	history_region:    u32, // Contiguous memory object of the input history (kernel holds one reference).
	history_buffer:    []u8, // Direct-mapped bytes of history_region.
	writer:            input_history.History_Writer,
	reader:            input_history.History_Reader,
	point_copies:      [POINT_COPY_CAPACITY]Point_Copy,
	point_copy_count:  u32,
	handle_map:        replay_filter.Replay_Handle_Map, // Replay translation from recorded handle -> real handle.
	stint_start_point: u64, // Point count when the current stint started (atomic).
	pinned_processor:  u32, // Single processor index assigned to this process.
	// The shared writers (shared_writers_setup). The gate
	// is Inactive when no other process writes a page that this process
	// maps with Write. Process lock of the recorded process.
	gate:               replay_filter.Shared_Writer_Gate,
	generation:         u64, // Names this record for the writer threads that the gate counted.
	shared_pages:       [SHARED_PAGE_CAPACITY]Shared_Page,
	shared_page_count:  u32,
	// The replay: the private pages that it maps where the record had a
	// shared mapping (replay_stand_in_mapping_add_locked). Each place is a
	// memory object of the replay, paid by the budget of the history. The
	// record keeps the same set for each Shared_Mapping that it writes,
	// with the shared memory object as the place: a mapping that the replay
	// could not hold is refused while the process runs, not at its replay.
	stand_ins:          input_history.Stand_In_Mapping_Set,
	// A mapping of received memory that the recorded process made in this
	// kernel entry (record_received_mapping_locked): its Shared_Mapping and
	// its first bytes enter the history right after the completion of its
	// Memory_Map (record_received_mapping_write_locked).
	pending_mapping:    Pending_Shared_Mapping,
	has_shared_writers: bool, // The gate is in use: the writers know this record (atomic).
	writers_held:       bool, // The writers wait for the recorded thread: the pick passes over them (atomic).
	writers_held_since: u64, // Milliseconds since boot when the recorded thread last left its input point (atomic).
	writer_wait_armed:  bool, // The gate counts the wait of a writer (gate.wait_timer_armed, atomic copy for the tick).
	writer_wait_since:  u64, // The first start of that wait (gate.wait_started_tick, atomic copy for the tick).
}

process_records: []Process_Record_State // One for each process slot: tables_start.
// Read-only zero page used to encode initial point copy deltas without placing
// a 4 KiB array on the kernel stack.
@(rodata)
RECORD_ZERO_PAGE: [PAGE_SIZE]u8
// Count of processes currently in Recording or Replaying mode.
record_replay_active_count: u32
// Count of records whose gate holds shared writers: the pick and the tick
// read this one word when it is 0.
shared_writer_recordings: u32
// The generation of the last record that published a gate. Control lock.
record_generation_last: u64

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

// region_mappings_of gives the mappings of region_index in one process, and
// those with Write. It takes the process lock of that process, or uses the
// lock that this processor holds already.
@(private = "file")
region_mappings_of :: proc "contextless" (index: u32, region_index: u32) -> (mappings: u32, writable: u32) {
	taken := process_lock(index)
	defer process_unlock(index, taken)
	for place in processes[index].mapping_order[:processes[index].mapping_order_count] {
		mapping := &processes[index].mappings[place]
		if mapping.region == region_index {
			mappings += 1
			if mapping.bits & PAGE_WRITE != 0 {
				writable += 1
			}
		}
	}
	return
}

// region_others_none says, from the counts of the object, that no process
// other than target_index maps region_index (with Write, when writable):
// then no table of another process needs a read. A count that says some
// other process does is answered by the read of each process.
@(private = "file")
region_others_none :: proc "contextless" (target_index: u32, region_index: u32, writable: bool) -> bool {
	own, own_writable := region_mappings_of(target_index, region_index)
	if writable {
		return intrinsics.atomic_load(&regions[region_index].writable_mapping_count) <= own_writable
	}
	return intrinsics.atomic_load(&regions[region_index].mapping_count) <= own
}

// region_mapped_writable_by_other says whether any live process other than
// target_index maps region_index with Write permission. Caller holds Control.
@(private = "file")
region_mapped_writable_by_other :: proc "contextless" (target_index: u32, region_index: u32) -> bool {
	if region_others_none(target_index, region_index, true) {
		return false
	}
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
	if region_others_none(target_index, region_index, false) {
		return false
	}
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

// process_own_region_references counts how many handles and mappings in
// process refer to region_index. Caller holds process's process lock.
@(private = "file")
process_own_region_references :: proc "contextless" (process: ^Process, region_index: u32) -> (count: u32) {
	for slot in process.handles {
		if slot.kind == .Memory && slot.object == region_index {
			count += 1
		}
	}
	for mapping in process.mappings {
		if mapping.page_count != 0 && mapping.region == region_index {
			count += 1
		}
	}
	return count
}

// process_disqualified_for_recording checks the exclusions: device memory,
// ports, interrupts, IOMMU-declared memory, guests, and for a replay
// writable shared memory objects. A record takes memory that it shares with
// Write: its other writers become shared writers (shared_writers_setup). A
// replay holds no peer, so a shared object there is a refusal. Caller holds
// Control and target's process lock.
// region_record_allowed_static identifies kernel-created read-only static
// regions (the time page and immutable boot/debug images) that use
// region_device for pre-allocated physical memory rather than hardware MMIO.
@(private = "file")
region_record_allowed_static :: #force_inline proc "contextless" (region_index: u32) -> bool {
	return region_index != 0 && (region_index == time_region || region_index == boot_image_region || region_index == debug_image_region)
}

@(private = "file")
process_disqualified_for_recording :: proc "contextless" (target_index: u32, shared_writers_allowed: bool) -> bool {
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
			if region.device && !region_record_allowed_static(slot.object) {
				return true
			}
			if intrinsics.atomic_load(&region.declared) != 0 {
				return true
			}
			// A handle alone writes nothing: a later map of it by the process
			// is checked then (record_replay_map_check).
			if !shared_writers_allowed && .Write in slot.rights && region_mapped_by_other(target_index, slot.object) {
				return true
			}
		}
	}
	for mapping in target.mappings {
		if mapping.page_count == 0 {
			continue
		}
		region := &regions[mapping.region]
		if region.device && !region_record_allowed_static(mapping.region) {
			return true
		}
		if intrinsics.atomic_load(&region.declared) != 0 {
			return true
		}
		if !shared_writers_allowed && mapping.bits & PAGE_WRITE != 0 && region_mapped_by_other(target_index, mapping.region) {
			return true
		}
	}
	return false
}

// history_region_in_use says whether any active record/replay session already
// owns this memory object.
@(private = "file")
history_region_in_use :: proc "contextless" (region_index: u32) -> bool {
	for &rec in process_records[1:] {
		if intrinsics.atomic_load(&rec.mode) != .None && rec.history_region == region_index {
			return true
		}
	}
	return false
}

// point_copy_frame_allocate takes one physical page frame paid by the current
// budget of history_region. Always reads regions[history_region].budget under
// frame_lock so budget_release reparenting is always respected.
@(private = "file")
point_copy_frame_allocate :: proc "contextless" (history_region: u32) -> (frame: u64, ok: bool) {
	lock_take(&frame_lock, .Frame)
	budget := regions[history_region].budget
	if budget == 0 || !budgets[budget].live || budgets[budget].amounts.pages == 0 {
		lock_free(&frame_lock, .Frame)
		return 0, false
	}
	frame = frame_take_held()
	if frame == 0 {
		lock_free(&frame_lock, .Frame)
		return 0, false
	}
	budget_pages_spend(&budgets[budget], 1)
	lock_free(&frame_lock, .Frame)
	frames_zero(frame, 1)
	return frame, true
}

// point_copy_frame_free returns one point-copy physical frame and refunds its
// page to the current budget of history_region under frame_lock.
@(private = "file")
point_copy_frame_free :: proc "contextless" (history_region: u32, frame: u64) {
	if frame == 0 {
		return
	}
	lock_take(&frame_lock, .Frame)
	frames_free_held(frame, 1)
	budget := regions[history_region].budget
	if budget != 0 && budgets[budget].live {
		budget_peak.give_back(&budgets[budget].amounts.pages, 1)
	}
	lock_free(&frame_lock, .Frame)
}

// point_copies_setup allocates private point copies for every read-only page
// of target that has an external writer (time_region or another live process
// mapping the region with Write). Replaces target's PTEs with the private
// copies. Refuses uncommitted or No_Access shared pages so no protected page
// is exposed. Caller holds Control and target's process lock.
@(private = "file")
point_copies_setup :: proc "contextless" (target_index: u32, rec: ^Process_Record_State, copy_initial: bool) -> Operation_Outcome {
	target := &processes[target_index]
	for &mapping in target.mappings {
		if mapping.page_count == 0 || mapping.bits & PAGE_WRITE != 0 {
			continue
		}
		has_writer := mapping.region == time_region || region_mapped_writable_by_other(target_index, mapping.region)
		if !has_writer {
			continue
		}
		// Refuse large, No_Access, or uncommitted shared read-only mappings so
		// point copies never expose protected or uncommitted pages.
		region := &regions[mapping.region]
		if mapping.large || mapping.bits & PAGE_PRESENT == 0 || region.uncommitted {
			point_copies_teardown(target_index, rec)
			return .Wrong_State
		}
		for page in u64(0) ..< mapping.page_count {
			if rec.point_copy_count >= POINT_COPY_CAPACITY {
				point_copies_teardown(target_index, rec)
				return .Budget_Or_Capacity_Exhausted
			}
			source_page := mapping.first + page
			state := region_page_state(region, source_page)
			bits := page_bits(&mapping, state)
			if bits == 0 || !page_committed(region, state) {
				point_copies_teardown(target_index, rec)
				return .Wrong_State
			}
			vaddr := mapping.address + page * PAGE_SIZE
			entry := page_entry(target.table, vaddr)
			if entry == nil {
				continue
			}
			copy_frame, allocated := point_copy_frame_allocate(rec.history_region)
			if !allocated {
				point_copies_teardown(target_index, rec)
				return .Budget_Or_Capacity_Exhausted
			}
			if copy_initial {
				source_frame := region_frame(region, source_page, false)
				if source_frame != 0 {
					intrinsics.mem_copy_non_overlapping(direct(copy_frame, u8), direct(source_frame, u8), PAGE_SIZE)
				}
			}
			was_present := entry^ & PAGE_PRESENT != 0
			entry^ = copy_frame | bits
			if !was_present {
				mapping.present_page_count += 1
			}
			rec.point_copies[rec.point_copy_count] = {
				virtual_address = vaddr,
				source_region   = mapping.region,
				source_page     = source_page,
				original_bits   = bits,
				copy_frame      = copy_frame,
				active          = true,
			}
			rec.point_copy_count += 1
		}
	}
	return .Succeeded
}

// point_copies_teardown restores original PTEs (respecting current protection
// and present state so mapping.present_page_count stays exact) and frees every
// point copy frame back to the current budget of rec.history_region.
// Caller holds target's process lock.
@(private = "file")
point_copies_teardown :: proc "contextless" (target_index: u32, rec: ^Process_Record_State) {
	if rec.point_copy_count == 0 {
		return
	}
	target := &processes[target_index]
	// A thread that waits on a word of a point copy names the copy frame,
	// which returns to the history below and can serve another process:
	// it wakes first, while the entry still names the copy.
	if target.table != 0 {
		for index in u32(0) ..< rec.point_copy_count {
			if pc := &rec.point_copies[index]; pc.active {
				waiters_on_pages_wake(target, pc.virtual_address, 1, 1)
			}
		}
	}
	self := processor_self()
	restored_any := false
	for index in u32(0) ..< rec.point_copy_count {
		pc := &rec.point_copies[index]
		if !pc.active {
			continue
		}
		if target.table != 0 {
			if mapping := mapping_at(target, pc.virtual_address); mapping != nil && mapping.region == pc.source_region {
				if entry := page_entry(target.table, pc.virtual_address); entry != nil && entry^ & PAGE_PRESENT != 0 {
					region := &regions[pc.source_region]
					source_frame := region_frame(region, pc.source_page, false)
					current_bits := page_bits(mapping, region_page_state(region, pc.source_page))
					if source_frame != 0 && current_bits != 0 {
						entry^ = source_frame | current_bits
					} else {
						entry^ = 0
						mapping.present_page_count -= 1
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
		point_copy_frame_free(rec.history_region, pc.copy_frame)
		pc^ = {}
	}
	rec.point_copy_count = 0
}

// record_replay_mapping_has_point_copies says whether mapping contains any
// active point copies (used by Memory_Protect to refuse changing protection on
// point-copied shared pages). Caller holds process's process lock.
record_replay_mapping_has_point_copies :: proc "contextless" (process_index: u32, mapping: ^Mapping) -> bool {
	rec := &process_records[process_index]
	if rec.mode == .None || rec.point_copy_count == 0 {
		return false
	}
	end := mapping.address + mapping.page_count * PAGE_SIZE
	for index in u32(0) ..< rec.point_copy_count {
		pc := &rec.point_copies[index]
		if pc.active && pc.virtual_address >= mapping.address && pc.virtual_address < end {
			return true
		}
	}
	return false
}

// record_replay_on_unmap releases any point copies inside an unmapped virtual
// address range after unmap cleared and synchronized the PTEs, and decrements
// Region.recorded_mappings. Caller holds process's process lock.
record_replay_on_unmap :: proc "contextless" (process_index: u32, region_index: u32, address: u64, page_count: u64) {
	rec := &process_records[process_index]
	if rec.mode == .None {
		return
	}
	intrinsics.atomic_sub(&regions[region_index].recorded_mappings, 1)
	end := address + page_count * PAGE_SIZE
	if rec.mode == .Recording {
		// The replay unmaps its stand-in mapping at the same input point:
		// the record keeps its set as the replay will have it. A mapping
		// that failed in its own Memory_Map writes no Shared_Mapping.
		_ = input_history.stand_in_mapping_set_remove_range(&rec.stand_ins, address, page_count)
		pending := rec.pending_mapping
		if pending.active && pending.virtual_address < end && address < pending.virtual_address + pending.page_count * PAGE_SIZE {
			rec.pending_mapping = {}
		}
		// The memory object of an unmapped shared page can end: no diff
		// reads it again.
		for index in u32(0) ..< rec.shared_page_count {
			page := &rec.shared_pages[index]
			if page.active && page.virtual_address >= address && page.virtual_address < end {
				point_copy_frame_free(rec.history_region, page.baseline_frame)
				page^ = {}
			}
		}
	} else {
		// A stand-in mapping that the replay unmaps ends: its memory object
		// can serve again, for another process, and a later delta there is
		// a divergence.
		_ = input_history.stand_in_mapping_set_remove(&rec.stand_ins, region_index)
	}
	if rec.point_copy_count == 0 {
		return
	}
	for index in u32(0) ..< rec.point_copy_count {
		pc := &rec.point_copies[index]
		if pc.active && pc.virtual_address >= address && pc.virtual_address < end {
			point_copy_frame_free(rec.history_region, pc.copy_frame)
			pc^ = {}
		}
	}
}

// record_replay_map_check enforces mapping isolation while any process is
// recorded or replayed, before map_region changes anything:
// - A recorded or replayed process cannot map an active history buffer, device
//   memory or IOMMU-declared memory (Wrong_State).
// - A recorded process maps memory that another process holds (a window
//   surface, a ring) only by itself, after the checks of
//   record_received_mapping_admit: received is true, and map_region then
//   gives the mapping to record_received_mapping_locked. A replay holds no
//   peer, and a map by another process changes the address space at any
//   instruction: both are refused (Wrong_State).
// - Another process cannot gain a writable mapping to a region currently
//   mapped by a recorded or replayed process (Wrong_State).
// Called from map_region under process's process lock.
record_replay_map_check :: proc "contextless" (process_index: u32, region_index: u32, flags: op.Map_Flags, first: u64, count: u64, by_the_process: bool) -> (received: bool, status: Operation_Outcome) {
	if intrinsics.atomic_load(&record_replay_active_count) == 0 {
		return false, .Succeeded
	}
	mode := intrinsics.atomic_load(&process_records[process_index].mode)
	if mode == .None {
		if .Write in flags && intrinsics.atomic_load(&regions[region_index].recorded_mappings) != 0 {
			return false, .Wrong_State
		}
		return false, .Succeeded
	}
	region := &regions[region_index]
	if history_region_in_use(region_index) || (region.device && !region_record_allowed_static(region_index)) || intrinsics.atomic_load(&region.declared) != 0 {
		return false, .Wrong_State
	}
	own_refs := process_own_region_references(&processes[process_index], region_index)
	if intrinsics.atomic_load(&region.references) <= own_refs {
		return false, .Succeeded
	}
	if mode != .Recording || !by_the_process {
		return false, .Wrong_State
	}
	return true, record_received_mapping_admit(process_index, region_index, flags, first, count)
}

// record_received_mapping_admit refuses, before any change, a mapping of
// received memory that the record or its replay cannot hold: an access
// that no stand-in mapping can have, an uncommitted or large-page object,
// more pages than one Shared_Mapping names, a stand-in mapping past the
// capacity of a replay, or a second mapping of an object that the process
// maps already: the replay gives each mapping its own stand-in memory, so
// the writes of the process through one would not reach the other. Then it
// asks for the control lock: the scan of the
// writers of the object (record_received_mapping_locked) takes the lock of
// each other process. A range that map_region refuses itself gives Ok here,
// and map_region gives its own status. Caller holds the process lock.
@(private = "file")
record_received_mapping_admit :: proc "contextless" (process_index: u32, region_index: u32, flags: op.Map_Flags, first: u64, count: u64) -> Operation_Outcome {
	rec := &process_records[process_index]
	region := &regions[region_index]
	if _, access_ok := input_history.shared_mapping_access_of_map_flags(flags); !access_ok || region.uncommitted || region.large_pages {
		return .Wrong_State
	}
	count := count
	if count == 0 && first < region.page_count {
		count = region.page_count - first
	}
	if count == 0 || first >= region.page_count || count > region.page_count - first {
		return .Succeeded
	}
	if count > input_history.SHARED_MAPPING_PAGE_LIMIT || rec.stand_ins.count >= input_history.STAND_IN_MAPPING_CAPACITY || count > input_history.STAND_IN_PAGE_LIMIT - rec.stand_ins.page_count {
		return .Budget_Or_Capacity_Exhausted
	}
	for mapping in processes[process_index].mappings {
		if mapping.page_count != 0 && mapping.region == region_index {
			return .Wrong_State
		}
	}
	return require_control()
}

// record_received_mapping_locked takes a mapping that the recorded process
// just made of memory that another process holds. The set of the stand-in
// mappings gets it, and the pages that another process writes get what the
// record needs while the process runs: a point copy for each page mapped
// without Write, or a baseline under the gate of its shared writers for
// each page mapped with Write. A page that no other process writes needs
// nothing more: only its first bytes, which the history takes after the
// completion of the Memory_Map. On a refusal, map_region unmaps the
// mapping, which takes back what this procedure took for each page before
// the failed one: the entries go to 0 before the shoot-down, and
// record_replay_on_unmap frees the point copies and the baselines of the
// range, removes the stand-in entry and clears the pending mapping. The
// pending mapping is set last, so a refusal never leaves one.
// Caller holds Control and the process lock; the recorded thread is in its
// kernel entry, at an input point.
record_received_mapping_locked :: proc "contextless" (process: ^Process, mapping: ^Mapping) -> Operation_Outcome {
	process_index := index_of_process(process)
	rec := &process_records[process_index]
	region := &regions[mapping.region]
	access := mapping.bits & PAGE_WRITE != 0 ? input_history.Shared_Mapping_Access.Read_Write : input_history.Shared_Mapping_Access.Read
	for page in u64(0) ..< mapping.page_count {
		state := region_page_state(region, mapping.first + page)
		if page_bits(mapping, state) == 0 || !page_committed(region, state) {
			return .Wrong_State
		}
	}
	entry := input_history.Shared_Mapping_Payload {
		virtual_address = mapping.address,
		page_count      = mapping.page_count,
		access          = u32(access),
	}
	if !input_history.stand_in_mapping_set_add(&rec.stand_ins, entry, access, mapping.region, region.serial) {
		return .Budget_Or_Capacity_Exhausted
	}
	// The scan comes after map_region counted this mapping in
	// recorded_mappings, and a writer counts its mapping, or the Write that
	// a protect gives, in writable_mapping_count before it reads
	// recorded_mappings (map_region, memory_protect). So of a writer and
	// this mapping made at the same time, one sees the other: the writer is
	// refused, or its count makes the scan below read its process, whose
	// lock holds it until its mapping is whole.
	switch access {
	case .None:
		return .Wrong_State
	case .Read:
		if mapping.region == time_region || region_mapped_writable_by_other(process_index, mapping.region) {
			point_copies_install_locked(process_index, rec, mapping) or_return
		}
	case .Read_Write:
		// Refuse if another recorded process also maps this object: it could
		// hold a live read mapping with no gate, so writes here would escape
		// its input history. Control is held and the own mapping counts 1.
		if intrinsics.atomic_load(&regions[mapping.region].recorded_mappings) > 1 {
			return .Wrong_State
		}
		if region_mapped_writable_by_other(process_index, mapping.region) {
			shared_pages_install_locked(process_index, rec, mapping) or_return
		}
	}
	rec.pending_mapping = {
		virtual_address = mapping.address,
		page_count      = mapping.page_count,
		access          = access,
		active          = true,
	}
	return .Succeeded
}

// point_copy_free_slots gives the count of the point copies that a record
// can still take: the slots past the count, and the slots that an unmap
// freed.
@(private = "file")
point_copy_free_slots :: proc "contextless" (rec: ^Process_Record_State) -> (free: u64) {
	free = u64(POINT_COPY_CAPACITY - rec.point_copy_count)
	for index in u32(0) ..< rec.point_copy_count {
		if !rec.point_copies[index].active {
			free += 1
		}
	}
	return free
}

// point_copy_slot_take gives a free slot of the point copies: one that an
// unmap freed, else the next one. The caller checked point_copy_free_slots.
@(private = "file")
point_copy_slot_take :: proc "contextless" (rec: ^Process_Record_State) -> ^Point_Copy {
	for index in u32(0) ..< rec.point_copy_count {
		if !rec.point_copies[index].active {
			return &rec.point_copies[index]
		}
	}
	rec.point_copy_count += 1
	return &rec.point_copies[rec.point_copy_count - 1]
}

// point_copies_install_locked puts a point copy in place of each page of a
// mapping that the recorded process just made without Write: the process
// reads the bytes of the copy, and each input point writes what the writer
// changed since (record_refresh_point_copies_locked). The page tables of
// the mapping exist: map_region holds an entry for each page. Caller holds
// the process lock.
@(private = "file")
point_copies_install_locked :: proc "contextless" (process_index: u32, rec: ^Process_Record_State, mapping: ^Mapping) -> Operation_Outcome {
	if point_copy_free_slots(rec) < mapping.page_count {
		return .Budget_Or_Capacity_Exhausted
	}
	target := &processes[process_index]
	region := &regions[mapping.region]
	self := processor_self()
	status := Operation_Outcome.Succeeded
	for page in u64(0) ..< mapping.page_count {
		source_page := mapping.first + page
		bits := page_bits(mapping, region_page_state(region, source_page))
		virtual_address := mapping.address + page * PAGE_SIZE
		entry := page_entry(target.table, virtual_address)
		if entry == nil {
			status = .Wrong_State
			break
		}
		copy_frame, allocated := point_copy_frame_allocate(rec.history_region)
		if !allocated {
			status = .Budget_Or_Capacity_Exhausted
			break
		}
		if source_frame := region_frame(region, source_page, false); source_frame != 0 {
			intrinsics.mem_copy_non_overlapping(direct(copy_frame, u8), direct(source_frame, u8), PAGE_SIZE)
		}
		if entry^ & PAGE_PRESENT == 0 {
			mapping.present_page_count += 1
		}
		entry^ = copy_frame | bits
		if self.table == target.table {
			page_flush(virtual_address)
		}
		point_copy_slot_take(rec)^ = {
			virtual_address = virtual_address,
			source_region   = mapping.region,
			source_page     = source_page,
			original_bits   = bits,
			copy_frame      = copy_frame,
			active          = true,
		}
	}
	// The entries named the frames of the object for a moment: no other
	// processor keeps that translation.
	intrinsics.atomic_thread_fence(.Seq_Cst)
	processor_sync(processors_with_table(target.table))
	return status
}

// shared_page_free_slots gives the count of the shared pages that a record
// can still take.
@(private = "file")
shared_page_free_slots :: proc "contextless" (rec: ^Process_Record_State) -> (free: u64) {
	free = u64(SHARED_PAGE_CAPACITY - rec.shared_page_count)
	for index in u32(0) ..< rec.shared_page_count {
		if !rec.shared_pages[index].active {
			free += 1
		}
	}
	return free
}

// shared_page_slot_take gives a free slot of the shared pages. The caller
// checked shared_page_free_slots.
@(private = "file")
shared_page_slot_take :: proc "contextless" (rec: ^Process_Record_State) -> ^Shared_Page {
	for index in u32(0) ..< rec.shared_page_count {
		if !rec.shared_pages[index].active {
			return &rec.shared_pages[index]
		}
	}
	rec.shared_page_count += 1
	return &rec.shared_pages[rec.shared_page_count - 1]
}

// shared_pages_install_locked takes each page of a mapping with Write that
// the recorded process just made, and that another process writes: the
// writers enter the gate (made now, if the record had none), and each page
// gets a baseline with its bytes of now. The leave of this input point
// writes what the writers changed since (record_leave_input_point). Each
// check comes before the gate changes: a writer that is recorded itself,
// or that writes for another record, a full table of writers and a spent
// budget refuse the mapping, and the unmap frees the baselines. Caller
// holds Control and the process lock.
@(private = "file")
shared_pages_install_locked :: proc "contextless" (process_index: u32, rec: ^Process_Record_State, mapping: ^Mapping) -> Operation_Outcome {
	if shared_page_free_slots(rec) < mapping.page_count {
		return .Budget_Or_Capacity_Exhausted
	}
	shared_writers_add_of_region(process_index, rec, mapping.region, admit_only = true) or_return
	// The recorded thread is in this kernel entry: it enters the gate at
	// its input point, and its leave waits for the writers.
	thread := &threads[processor_self().current]
	if thread.process != process_index || thread.record_outside_point {
		return .Wrong_State
	}
	region := &regions[mapping.region]
	for page in u64(0) ..< mapping.page_count {
		baseline, allocated := point_copy_frame_allocate(rec.history_region)
		if !allocated {
			return .Budget_Or_Capacity_Exhausted
		}
		source_page := mapping.first + page
		if source_frame := region_frame(region, source_page, false); source_frame != 0 {
			intrinsics.mem_copy_non_overlapping(direct(baseline, u8), direct(source_frame, u8), PAGE_SIZE)
		}
		shared_page_slot_take(rec)^ = {
			virtual_address = mapping.address + page * PAGE_SIZE,
			region          = mapping.region,
			page            = source_page,
			baseline_frame  = baseline,
			active          = true,
		}
	}
	// A gate that this map makes, and that fails before its publication,
	// goes: no record keeps a gate that no writer knows.
	gate_made := rec.gate.state == .Inactive
	if gate_made {
		if !replay_filter.shared_writer_gate_init(&rec.gate, process_index, processes[process_index].serial, SHARED_WRITER_WAIT_BOUND_MILLISECONDS) {
			rec.gate = {}
			return .Wrong_State
		}
		if !replay_filter.register_recorded_thread(&rec.gate, thread_index(thread), starts_at_input_point = true) {
			rec.gate = {}
			return .Wrong_State
		}
	}
	// The admission saw each writer under the control lock, and a new
	// writer is refused since map_region counted this mapping: the adds
	// do not fail, and a failure takes back a gate that this map made.
	if added := shared_writers_add_of_region(process_index, rec, mapping.region); added != .Succeeded {
		if gate_made {
			rec.gate = {}
		}
		return added
	}
	shared_writers_publish(process_index, rec)
	return .Succeeded
}

// record_replay_write_conflict says if Memory_Protect would give Write to a
// process that is not recorded on memory that a recorded or replayed process
// maps: that process would become a writer that no gate holds, as a new
// mapping with Write would (record_replay_map_conflict). Caller holds the
// process lock of process_index.
record_replay_write_conflict :: proc "contextless" (process_index: u32, region_index: u32) -> bool {
	if intrinsics.atomic_load(&record_replay_active_count) == 0 || intrinsics.atomic_load(&process_records[process_index].mode) != .None {
		return false
	}
	return intrinsics.atomic_load(&regions[region_index].recorded_mappings) != 0
}

// record_replay_mark_mappings adjusts Region.recorded_mappings for all active
// mappings of target_index when entering or leaving record/replay mode.
// Caller holds target_index's process lock.
@(private = "file")
record_replay_mark_mappings :: proc "contextless" (target_index: u32, add: bool) {
	target := &processes[target_index]
	for mapping in target.mappings {
		if mapping.page_count == 0 {
			continue
		}
		if add {
			intrinsics.atomic_add(&regions[mapping.region].recorded_mappings, 1)
		} else {
			intrinsics.atomic_sub(&regions[mapping.region].recorded_mappings, 1)
		}
	}
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

// choose_pinned_processor picks one processor index inside caller_limit.
@(private = "file")
choose_pinned_processor :: proc "contextless" (caller_index: u32) -> (cpu_index: u32, ok: bool) {
	allowed := intrinsics.atomic_load(&threads[caller_index].processors_limit) & machine_processors()
	if allowed == 0 {
		return 0, false
	}
	self_index := processor_self().index
	if allowed & (u64(1) << self_index) != 0 {
		return self_index, true
	}
	return u32(intrinsics.count_trailing_zeros(allowed)), true
}

// record_replay_control handles Record_Start, Record_End, and Replay_Start
// commands of Thread_Control. Caller holds caller_process's process lock.
record_replay_control :: proc "contextless" (caller_index: u32, caller_process: ^Process, command: op.Thread_Control_Command, v: [7]u64, results: ^[7]u64) -> Operation_Outcome {
	_ = results
	if v[0] == 0 {
		return .Argument_Refused
	}
	target_slot := handle_find(caller_process, v[0], .Process, {.Debug}) or_return
	target_index := target_slot.object
	can_read_state := .Read in target_slot.rights
	caller_process_index := index_of_process(caller_process)
	if target_index == caller_process_index {
		self_found := can_read_state ? u64(op.Process_State.Ready) : 0
		if command == .Record_End {
			return thread_control_state_refuse(.Not_Recording, 1, v[0], 0, self_found)
		}
		return thread_control_state_refuse(.Process_Not_Created, 1, v[0], u64(op.Process_State.Created), self_found)
	}
	if (command == .Record_Start || command == .Replay_Start) && !intrinsics.atomic_load(&cpuid_faulting_supported) {
		return .Operation_Unsupported
	}
	require_control() or_return
	target_taken := process_lock(target_index)
	defer process_unlock(target_index, target_taken)
	target := &processes[target_index]
	target_state := can_read_state ? u64(target.state) : 0
	if target.state == .None || target.state == .Stopped {
		// Without Read, keep the refusal identical for Stopped and Ready
		// targets so a Debug-only handle cannot oracle target state.
		if !can_read_state && command != .Record_End {
			return thread_control_state_refuse(.Process_Not_Created, 1, v[0], u64(op.Process_State.Created), 0)
		}
		return thread_control_state_refuse(.Process_Stopped, 1, v[0], 0, target_state)
	}
	rec := &process_records[target_index]
	switch command {
	case .Record_Start:
		if target.state != .Created {
			return thread_control_state_refuse(.Process_Not_Created, 1, v[0], u64(op.Process_State.Created), target_state)
		}
		if rec.mode != .None {
			return thread_control_state_refuse(.Process_Recording, 1, v[0], 0, target_state)
		}
		if process_disqualified_for_recording(target_index, shared_writers_allowed = true) {
			return thread_control_state_refuse(.Process_Disqualified, 1, v[0], 0, target_state)
		}
		memory_slot := handle_find(caller_process, v[1], .Memory, {.Read, .Write}) or_return
		region_index := memory_slot.object
		region := &regions[region_index]
		if !region.contiguous || region.device || region.page_count * PAGE_SIZE < input_history.MIN_HISTORY_BUFFER_BYTES {
			return .Argument_Refused
		}
		if history_region_in_use(region_index) {
			return thread_control_state_refuse(.History_In_Use, 2, v[1])
		}
		pinned_cpu, pinned_ok := choose_pinned_processor(caller_index)
		if !pinned_ok {
			return thread_control_state_refuse(.No_Pinned_Processor, 1, v[0], 0, target_state)
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
			return .Argument_Refused
		}
		// Hold a kernel reference on history_region before allocating point
		// copies so regions[history_region] stays valid across rollback or teardown.
		intrinsics.atomic_add(&region.references, 1)
		intrinsics.mem_zero(rec, size_of(Process_Record_State))
		rec.recorder_process = caller_process_index
		rec.recorder_serial = caller_process.serial
		rec.history_region = region_index
		rec.history_buffer = history_buffer
		rec.writer = writer
		rec.pinned_processor = pinned_cpu
		// Mark the mappings of the target and count the record before any
		// scan of the other processes: a process that maps a region of the
		// target with Write (or gives itself Write with Memory_Protect)
		// after the scan of its process lock is refused there
		// (record_replay_map_conflict, record_replay_write_conflict), and one
		// that did it before is seen by the scan. So the set of writers that
		// the gate holds is the whole set.
		record_replay_mark_mappings(target_index, true)
		intrinsics.atomic_add(&record_replay_active_count, 1)
		cpu := processor_self()
		if setup_status := record_start_setup(cpu, target_index, rec); setup_status != .Succeeded {
			shared_writers_teardown(target_index, rec)
			point_copies_teardown(target_index, rec)
			record_replay_mark_mappings(target_index, false)
			intrinsics.atomic_sub(&record_replay_active_count, 1)
			intrinsics.mem_zero(rec, size_of(Process_Record_State))
			region_release(region_index)
			if setup_status == .Wrong_State {
				return thread_control_state_refuse(.Process_Disqualified, 1, v[0], 0, target_state)
			}
			return setup_status
		}
		intrinsics.atomic_store(&rec.mode, input_history.Record_Mode.Recording)
		shared_writers_publish(target_index, rec)
		return .Succeeded

	case .Record_End:
		if rec.mode == .None || rec.recorder_process != caller_process_index || rec.recorder_serial != caller_process.serial {
			return thread_control_state_refuse(.Not_Recording, 1, v[0], 0, target_state)
		}
		record_replay_end_locked(target_index, .Recorder_Stopped)
		return .Succeeded

	case .Replay_Start:
		if target.state != .Created {
			return thread_control_state_refuse(.Process_Not_Created, 1, v[0], u64(op.Process_State.Created), target_state)
		}
		if rec.mode != .None {
			return thread_control_state_refuse(.Process_Recording, 1, v[0], 0, target_state)
		}
		if process_disqualified_for_recording(target_index, shared_writers_allowed = false) {
			return thread_control_state_refuse(.Process_Disqualified, 1, v[0], 0, target_state)
		}
		memory_slot := handle_find(caller_process, v[1], .Memory, {.Read, .Write}) or_return
		region_index := memory_slot.object
		region := &regions[region_index]
		if !region.contiguous || region.device || region.page_count * PAGE_SIZE < size_of(input_history.History_Header) {
			return .Argument_Refused
		}
		if history_region_in_use(region_index) {
			return thread_control_state_refuse(.History_In_Use, 2, v[1])
		}
		pinned_cpu, pinned_ok := choose_pinned_processor(caller_index)
		if !pinned_ok {
			return thread_control_state_refuse(.No_Pinned_Processor, 1, v[0], 0, target_state)
		}
		history_buffer := ([^]u8)(direct(region.physical, u8))[:region.page_count * PAGE_SIZE]
		reader, reader_ok := input_history.history_reader_open(history_buffer)
		if !reader_ok {
			return .Argument_Refused
		}
		if reader.header.xcr0_components & ~transmute(u64)extended_state_components != 0 {
			return .Argument_Refused
		}
		intrinsics.atomic_add(&region.references, 1)
		intrinsics.mem_zero(rec, size_of(Process_Record_State))
		rec.recorder_process = caller_process_index
		rec.recorder_serial = caller_process.serial
		rec.history_region = region_index
		rec.history_buffer = history_buffer
		rec.reader = reader
		rec.pinned_processor = pinned_cpu
		if setup_status := point_copies_setup(target_index, rec, copy_initial = false); setup_status != .Succeeded {
			intrinsics.mem_zero(rec, size_of(Process_Record_State))
			region_release(region_index)
			if setup_status == .Wrong_State {
				return thread_control_state_refuse(.Process_Disqualified, 1, v[0], 0, target_state)
			}
			return setup_status
		}
		// The context of the replay is the context of the record: the
		// starter of the replay wrote its own, which goes first, so that no
		// byte of it stays where the record had a zero.
		replay_context_page_clear_locked(target_index)
		// The head of the history before the first instruction: the private
		// pages where the record had shared mappings, then the first bytes of
		// the time page (cycle_frequency, cycle_start), of the context and of
		// the shared pages.
		if !replay_head_apply_locked(processor_self(), target_index) {
			replay_stand_in_mappings_unmap(target_index)
			point_copies_teardown(target_index, rec)
			intrinsics.mem_zero(rec, size_of(Process_Record_State))
			region_release(region_index)
			return .Argument_Refused
		}
		record_replay_mark_mappings(target_index, true)
		intrinsics.atomic_store(&rec.mode, input_history.Record_Mode.Replaying)
		intrinsics.atomic_add(&record_replay_active_count, 1)
		return .Succeeded

	case .None, .Stop, .Resume, .Read_Registers, .Write_Registers, .Read_Extended_State, .Write_Extended_State, .Read_Schedule, .Write_Schedule, .Read_Breakpoints, .Write_Breakpoints, .Read_Memory, .Read_Placement, .Write_Placement, .Read_Process_Schedule, .Write_Process_Schedule, .Start_Counters, .Read_Counters, .Stop_Counters, .Wait_Room:
		return .Argument_Refused
	}
	return .Argument_Refused
}

// record_start_setup builds what a record holds before its first
// instruction: the point copies with their first bytes, the context page,
// and the shared pages with the gate of their writers. A failure leaves
// what it built for the teardown of the caller. Caller holds Control and
// target's process lock.
@(private = "file")
record_start_setup :: proc "contextless" (cpu: ^Processor, target_index: u32, rec: ^Process_Record_State) -> Operation_Outcome {
	point_copies_setup(target_index, rec, copy_initial = true) or_return
	// The first bytes of each point copy, so that the replay starts with the
	// same read-only shared pages. Each run of point copies of one memory
	// object at following addresses is one shared mapping: the replay maps
	// private pages there before it writes their first bytes.
	index := u32(0)
	for index < rec.point_copy_count {
		first := &rec.point_copies[index]
		run := u32(1)
		if first.active && point_copy_needs_stand_in(first) {
			for index + run < rec.point_copy_count && u64(run) < input_history.SHARED_MAPPING_PAGE_LIMIT {
				next := &rec.point_copies[index + run]
				if !next.active || !point_copy_needs_stand_in(next) || next.source_region != first.source_region || next.virtual_address != first.virtual_address + u64(run) * PAGE_SIZE {
					break
				}
				run += 1
			}
			if !record_shared_mapping_locked(rec, first.virtual_address, u64(run), .Read, first.source_region) {
				return .Argument_Refused
			}
		}
		for page in index ..< index + run {
			pc := &rec.point_copies[page]
			if !pc.active {
				continue
			}
			after_page := direct(pc.copy_frame, [PAGE_SIZE]u8)
			written, changed, ok := input_history.page_delta_encode(pc.virtual_address, &RECORD_ZERO_PAGE, after_page, cpu.page_delta_scratch[:])
			if !ok || (changed && !input_history.history_writer_append(&rec.writer, .Page_Delta, 0, 0, cpu.page_delta_scratch[:written])) {
				return .Argument_Refused
			}
		}
		index += run
	}
	// The context is an input that the starter wrote before the first
	// instruction: the replay writes it back at the same place.
	if !record_context_page_locked(cpu, target_index, rec) {
		return .Argument_Refused
	}
	return shared_writers_setup(cpu, target_index, rec)
}

// point_copy_needs_stand_in says whether a replay must map a private page
// where this point copy is. The kernel maps the time page in every process,
// and the starter of a replay maps its context page, so a replay has those
// pages already; each other page came from a process that the replay does
// not hold.
@(private = "file")
point_copy_needs_stand_in :: proc "contextless" (pc: ^Point_Copy) -> bool {
	return pc.source_region != time_region && pc.virtual_address != op.CONTEXT_ADDRESS
}

// record_shared_mapping_locked writes the Shared_Mapping record of a range
// of the head whose pages another process writes, and adds it to the set
// of the stand-in mappings that the replay will make. false: the history is
// full, or the range fails the border of the contract or the set. Caller
// holds the process lock of the recorded process.
@(private = "file")
record_shared_mapping_locked :: proc "contextless" (rec: ^Process_Record_State, virtual_address: u64, page_count: u64, access: input_history.Shared_Mapping_Access, region_index: u32) -> bool {
	entry := input_history.Shared_Mapping_Payload {
		virtual_address = virtual_address,
		page_count      = page_count,
		access          = u32(access),
	}
	return input_history.stand_in_mapping_set_add(&rec.stand_ins, entry, access, region_index, regions[region_index].serial) && input_history.history_writer_append(&rec.writer, .Shared_Mapping, 0, 0, ([^]u8)(&entry)[:size_of(entry)])
}

// record_replay_thread_create_refused checks single-thread and placement-limit
// invariants before thread_create allocates resources. Caller holds Control
// and process_index's process lock.
record_replay_thread_create_refused :: proc "contextless" (process_index: u32, placement_limit: u64) -> bool {
	rec := &process_records[process_index]
	if rec.mode == .None {
		return false
	}
	// Single-thread mode: only the first thread (Process_Start) is allowed.
	if processes[process_index].thread_count != 0 {
		return true
	}
	pinned_mask := u64(1) << rec.pinned_processor
	return pinned_mask & placement_limit == 0
}

// record_replay_thread_init attaches a newly created first thread to its
// process's record or replay mode and narrows its processor placement to the
// intersection of its pinned processor and its creator's placement limit.
// Caller holds Control and process lock.
record_replay_thread_init :: proc "contextless" (process_index: u32, thread: ^Thread) {
	rec := &process_records[process_index]
	if rec.mode == .None {
		return
	}
	intrinsics.atomic_store(&thread.record_mode, rec.mode)
	// A new thread has run no instruction: it starts at an input point, so
	// its first leave copies what the writers wrote before it.
	thread.record_outside_point = false
	if rec.gate.state == .Active && !replay_filter.register_recorded_thread(&rec.gate, thread_index(thread), starts_at_input_point = true) {
		// A thread that the gate does not hold would read the shared pages
		// while a writer writes them: the history ends rather than lose an
		// input. The record holds one thread, so this is a full table of
		// the gate, which the history reports as full.
		record_replay_end_locked(process_index, .Buffer_Full)
		intrinsics.atomic_store(&thread.record_mode, input_history.Record_Mode.None)
		return
	}
	pinned_mask := (u64(1) << rec.pinned_processor) & thread.processors_limit
	every_processor := machine_processors()
	intrinsics.atomic_store(&thread.processors, pinned_mask)
	intrinsics.atomic_store(&thread.processors_limit, pinned_mask)
	intrinsics.atomic_store(&thread.placement_restricted, pinned_mask != every_processor)
}

// record_replay_thread_finished removes a thread that ends from the gate of
// its record: a thread that left at an input point, or outside one, holds no
// writer any more. A writer that waited for it may then run. Caller holds
// the process lock of process_index.
record_replay_thread_finished :: proc "contextless" (process_index: u32, thread_slot: u32) {
	rec := &process_records[process_index]
	if rec.mode != .Recording || rec.gate.state != .Active {
		return
	}
	if replay_filter.unregister_recorded_thread(&rec.gate, thread_slot) {
		if rec.gate.thread_count == 0 {
			intrinsics.atomic_store(&rec.writers_held, false)
		}
		shared_writer_wait_mirror_locked(rec)
		if rec.gate.waiting_writer_count != 0 {
			kick_all()
		}
	}
}

// record_replay_end_locked ends recording or replay of target_index, writes
// the end record or header summary, clears thread record modes, synchronizes
// processors so CR4.TSD and CPUID faulting are unloaded everywhere, restores
// point copies, and releases the history region reference.
// Caller holds Control lock and target_index's process lock.
record_replay_end_locked :: proc "contextless" (target_index: u32, reason: input_history.History_End_Reason, div_kind: input_history.Divergence_Kind = .None, div_point: u64 = 0, div_expected: u64 = 0, div_actual: u64 = 0) {
	rec := &process_records[target_index]
	if rec.mode == .None {
		return
	}
	reason, div_kind, div_point, div_expected, div_actual := reason, div_kind, div_point, div_expected, div_actual
	mode := rec.mode
	if mode == .Recording {
		if !rec.writer.ended {
			if !input_history.history_writer_append_end(&rec.writer, 0, 0, reason, div_kind, div_expected, div_actual) {
				_ = input_history.history_header_record_end(rec.history_buffer, reason, div_kind, div_point, div_expected, div_actual)
			}
		}
	} else {
		if reason == .Normal_Stop {
			reason, div_kind, div_point, div_expected, div_actual = replay_end_check_locked(target_index)
		}
		_ = input_history.history_header_record_end(rec.history_buffer, reason, div_kind, div_point, div_expected, div_actual)
	}
	for &thread in threads[1:] {
		if thread.process == target_index {
			intrinsics.atomic_store(&thread.record_mode, input_history.Record_Mode.None)
			thread.record_wait_pending = false
			thread.record_outside_point = false
		}
	}
	// The gate ends with the history: each writer runs freely again.
	if rec.gate.state == .Active {
		if reason == .Revocation {
			_, _ = replay_filter.shared_writer_revoke_immediately(&rec.gate)
		} else {
			_ = replay_filter.shared_writer_end_normal(&rec.gate)
		}
	}
	shared_writers_teardown(target_index, rec)
	// Clear recorded_mappings before tearing down mode so other processes are
	// unblocked cleanly.
	record_replay_mark_mappings(target_index, false)
	intrinsics.atomic_store(&rec.mode, input_history.Record_Mode.None)
	// Synchronize every other processor so CR4.TSD and CPUID faulting are
	// unloaded via sync_acknowledge even when point_copy_count == 0.
	intrinsics.atomic_thread_fence(.Seq_Cst)
	processor_sync(all_other_processors())
	self := processor_self()
	if self.record_traps_loaded && (self.current == 0 || intrinsics.atomic_load(&threads[self.current].record_mode) == .None) {
		record_traps_unload(self)
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

// replay_end_check_locked decides how a replay ends when its process stops.
// A stop by its own instructions (a stop of itself, of its last thread, a
// fault) must be where the record stopped: the next record of the history,
// after the deltas that the writers wrote at the last entry, is the end
// with Normal_Stop, else the replay diverged there (Unexpected_End). A stop
// by another process (its holder, the replayer, the close of its last
// handle) says nothing of the replay: it ends with Normal_Stop. Caller
// holds Control and target_index's process lock.
@(private = "file")
replay_end_check_locked :: proc "contextless" (target_index: u32) -> (reason: input_history.History_End_Reason, div_kind: input_history.Divergence_Kind, div_point: u64, div_expected: u64, div_actual: u64) {
	switch processes[target_index].cause {
	case .Holder, .Handles_Closed, .None:
		return .Normal_Stop, .None, 0, 0, 0
	case .Itself, .Last_Thread_Ended, .Fault, .Not_Committed, .Cannot_Return, .Fault_Unanswered:
	}
	rec := &process_records[target_index]
	cpu := processor_self()
	if !replay_apply_pending_page_deltas_locked(cpu, target_index) {
		return .Divergence, .Missing_Record, input_history.history_reader_next_point(&rec.reader), 0, 0
	}
	record_header, kind, payload, has_more, read_ok := input_history.history_reader_next_into(&rec.reader, cpu.replay_record_scratch[:])
	check := input_history.replay_end_check(read_ok && has_more, kind, payload)
	if check.divergence == .None {
		return .Normal_Stop, .None, 0, 0, 0
	}
	return .Divergence, check.divergence, replay_record_point(&rec.reader, record_header, read_ok && has_more), check.expected, check.actual
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
	if intrinsics.atomic_load(&rec.mode) == .None || rec.recorder_process != holder_index || rec.recorder_serial != holder.serial {
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
	for target_index in u32(1) ..< process_capacity {
		rec := &process_records[target_index]
		if intrinsics.atomic_load(&rec.mode) != .None && rec.recorder_process == recorder_index && rec.recorder_serial == recorder_serial {
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
	if intrinsics.atomic_load(&rec.mode) == .Recording {
		intrinsics.atomic_store(&rec.stint_start_point, intrinsics.atomic_load(&rec.writer.point_count))
	}
}

// record_replay_stint_bound_check enforces the one-stint bound: if a recorded
// thread ran an entire time slice without reaching any input point, end the
// input history immediately so no peer or sibling waits indefinitely.
// Caller holds no locks (called from VECTOR_TIMER only when strategy_tick ended
// a full stint).
record_replay_stint_bound_check :: proc "contextless" (thread: ^Thread) {
	process_index := thread.process
	rec := &process_records[process_index]
	if intrinsics.atomic_load(&rec.mode) != .Recording {
		return
	}
	if intrinsics.atomic_load(&rec.writer.point_count) != intrinsics.atomic_load(&rec.stint_start_point) {
		return
	}
	control_take()
	taken := process_lock(process_index)
	if rec.mode == .Recording && rec.writer.point_count == intrinsics.atomic_load(&rec.stint_start_point) {
		record_replay_end_locked(process_index, .Stint_Bound_Reached)
	}
	process_unlock(process_index, taken)
	control_free()
}

// record_refresh_point_copies_locked snapshots each live shared page ONCE into
// per-processor scratch memory, compares against the point copy, appends a
// Page_Delta when bytes changed, and updates the point copy from that exact
// snapshot. Returns false if the history buffer is full.
// Caller holds process_index's process lock.
@(private = "file")
record_refresh_point_copies_locked :: proc "contextless" (cpu: ^Processor, process_index: u32, thread: ^Thread) -> bool {
	rec := &process_records[process_index]
	pending := rec.pending_mapping
	for index in u32(0) ..< rec.point_copy_count {
		pc := &rec.point_copies[index]
		if !pc.active {
			continue
		}
		// A point copy of a mapping whose Shared_Mapping is not written
		// yet: a delta before it would name a page that the replay does not
		// map yet. The copy keeps its bytes, and the next point writes what
		// changed since.
		if pending.active && pc.virtual_address >= pending.virtual_address && pc.virtual_address - pending.virtual_address < pending.page_count * PAGE_SIZE {
			continue
		}
		source_frame := region_frame(&regions[pc.source_region], pc.source_page, false)
		if source_frame == 0 {
			continue
		}
		// Single snapshot of the live shared page eliminates two-pass TOCTOU.
		intrinsics.mem_copy_non_overlapping(&cpu.page_snapshot_scratch[0], direct(source_frame, u8), PAGE_SIZE)
		before_page := direct(pc.copy_frame, [PAGE_SIZE]u8)
		written, changed, ok := input_history.page_delta_encode(pc.virtual_address, before_page, &cpu.page_snapshot_scratch, cpu.page_delta_scratch[:])
		if !ok {
			return false
		}
		if !changed {
			continue
		}
		if !input_history.history_writer_append(&rec.writer, .Page_Delta, thread.frame.rip, thread.frame.rsp, cpu.page_delta_scratch[:written]) {
			return false
		}
		intrinsics.mem_copy_non_overlapping(direct(pc.copy_frame, u8), &cpu.page_snapshot_scratch[0], PAGE_SIZE)
	}
	return true
}

// replay_apply_pending_page_deltas_locked snapshots each leading Page_Delta
// record ONCE into private per-processor scratch memory and applies it
// (replay_page_delta_apply_locked). false: a damaged record, or a delta
// with no page to write; the divergence is at the next point of the reader.
// Caller holds process_index's process lock.
@(private = "file")
replay_apply_pending_page_deltas_locked :: proc "contextless" (cpu: ^Processor, process_index: u32) -> bool {
	rec := &process_records[process_index]
	for {
		record_header, kind, payload, stride, has_more, ok := input_history.history_reader_peek_into(&rec.reader, cpu.replay_record_scratch[:])
		if !ok {
			return false
		}
		if !has_more || kind != .Page_Delta {
			return true
		}
		if !replay_page_delta_apply_locked(process_index, payload) {
			return false
		}
		input_history.history_reader_advance(&rec.reader, record_header, stride)
	}
}

// replay_page_delta_apply_locked writes one Page_Delta into the page of the
// replay at its address: a point copy, else a stand-in page that the replay
// mapped for a shared mapping of the record, else a page that the process
// maps with Write (replay_shared_page_frame_locked), such as its context
// page. Never another page. Caller holds process_index's process lock.
@(private = "file")
replay_page_delta_apply_locked :: proc "contextless" (process_index: u32, payload: []u8) -> bool {
	rec := &process_records[process_index]
	delta_header, delta_ok := input_history.page_delta_validate(payload)
	if !delta_ok {
		return false
	}
	target_frame: u64
	for index in u32(0) ..< rec.point_copy_count {
		pc := &rec.point_copies[index]
		if pc.active && pc.virtual_address == delta_header.virtual_address {
			target_frame = pc.copy_frame
			break
		}
	}
	if target_frame == 0 {
		if stand_in, _, found := input_history.stand_in_mapping_set_find(&rec.stand_ins, delta_header.virtual_address); found {
			// The mapping there must still be the stand-in mapping: the same
			// memory object, by its slot and its serial. An unmap removes it
			// from the set (record_replay_on_unmap); the serial also keeps a
			// slot that serves again from passing for it.
			if mapping := mapping_at(&processes[process_index], delta_header.virtual_address); mapping != nil && mapping.region == stand_in.place && regions[mapping.region].serial == stand_in.place_serial && !mapping.large {
				target_frame = region_frame(&regions[stand_in.place], mapping.first + (delta_header.virtual_address - mapping.address) / PAGE_SIZE, true)
			}
		}
	}
	if target_frame == 0 {
		// The page of a shared writer that the starter of the replay mapped
		// itself: in the replay it is a page that the process maps with
		// Write, and no peer writes it.
		target_frame = replay_shared_page_frame_locked(process_index, delta_header.virtual_address)
	}
	if target_frame == 0 {
		return false
	}
	return input_history.page_delta_apply(payload, direct(target_frame, [PAGE_SIZE]u8))
}

// replay_head_apply_locked reads the head of the history before the first
// instruction of a replay: each Shared_Mapping maps private pages at its
// place (replay_stand_in_mapping_add_locked), and each Page_Delta writes the
// first bytes of a page. It stops at the first record of another kind.
// false: a damaged record, a mapping that the replay cannot make, or a
// delta with no page. Its caller then unmaps the stand-in mappings that it
// made (replay_stand_in_mappings_unmap): a process that Replay_Start
// refused never runs, and keeps no page that the history paid. Caller
// holds Control and process_index's process lock.
@(private = "file")
replay_head_apply_locked :: proc "contextless" (cpu: ^Processor, process_index: u32) -> bool {
	rec := &process_records[process_index]
	for {
		record_header, kind, payload, stride, has_more, ok := input_history.history_reader_peek_into(&rec.reader, cpu.replay_record_scratch[:])
		if !ok {
			return false
		}
		if !has_more {
			return true
		}
		if kind == .Shared_Mapping {
			entry, access, valid := input_history.shared_mapping_validate(payload)
			if !valid || !replay_stand_in_mapping_add_locked(process_index, entry, access) {
				return false
			}
		} else if kind == .Page_Delta {
			if !replay_page_delta_apply_locked(process_index, payload) {
				return false
			}
		} else {
			return true
		}
		input_history.history_reader_advance(&rec.reader, record_header, stride)
	}
}

// replay_stand_in_mapping_add_locked maps a new memory object of the replay
// at the place of a shared mapping of the record, with the access that the
// recorded process had: no peer writes it, and the deltas of the history
// write what the peer wrote. The budget of the history pays it, as it pays
// the point copies: the replayer pays its replay. A range that the replay
// maps already, whole, inside one mapping (its context page, a page that
// its starter mapped) takes the deltas there, and needs no stand-in. After
// the start (in_head false), the recorded process made the mapping itself
// at that address, so a range that the replay maps already is refused. The
// stand-in mapping never has Execute. Caller holds process_index's process
// lock, and Control in the head.
@(private = "file")
replay_stand_in_mapping_add_locked :: proc "contextless" (process_index: u32, entry: input_history.Shared_Mapping_Payload, access: input_history.Shared_Mapping_Access, in_head := true) -> bool {
	rec := &process_records[process_index]
	process := &processes[process_index]
	end := entry.virtual_address + entry.page_count * PAGE_SIZE
	if existing := mapping_at(process, entry.virtual_address); existing != nil {
		return in_head && end <= existing.address + existing.page_count * PAGE_SIZE
	}
	if !input_history.stand_in_mapping_set_admits(&rec.stand_ins, entry) {
		return false
	}
	// The budget of the history pays: region_create reads it under the
	// frame lock, as a release of that budget changes it there.
	region, created := region_create(0, entry.page_count, budget_of_region = rec.history_region)
	if created != .Succeeded {
		return false
	}
	flags: op.Map_Flags
	switch access {
	case .None:
		regions[region].references = 1
		region_release(region)
		return false
	case .Read:
	case .Read_Write:
		flags = {.Write}
	}
	if _, mapped := map_region(process, region, entry.virtual_address, flags, 0, 0, by_the_process = !in_head); mapped != .Succeeded {
		regions[region].references = 1
		region_release(region)
		return false
	}
	if !input_history.stand_in_mapping_set_add(&rec.stand_ins, entry, access, region, regions[region].serial) {
		// The set admitted it above, under the same lock. If it refuses
		// anyway, no stand-in mapping that the set does not name stays.
		if mapping := mapping_at(process, entry.virtual_address); mapping != nil && mapping.region == region {
			unmap(process, mapping)
		}
		return false
	}
	return true
}

// replay_received_mapping_locked takes the Shared_Mapping that follows the
// completion of a Memory_Map in the history: the recorded process mapped
// memory that it received after its start. The record and the map of the
// replay must agree (input_history.replay_shared_mapping_check); then the
// replay maps a stand-in mapping at the recorded address, and the deltas
// that follow write its bytes. A disagreement, or a stand-in mapping that
// the replay cannot make (an address that the replay maps already, a full
// set, a spent budget), is a divergence at the point of the Shared_Mapping,
// and leaves no stand-in mapping. Caller holds the process lock.
@(private = "file")
replay_received_mapping_locked :: proc "contextless" (cpu: ^Processor, process_index: u32, command_values: [7]u64, completion_address: u64) -> (check: input_history.Replay_Check_Result, point: u64) {
	rec := &process_records[process_index]
	record_header, kind, payload, stride, has_more, ok := input_history.history_reader_peek_into(&rec.reader, cpu.replay_record_scratch[:])
	if !ok || !has_more || kind != .Shared_Mapping {
		return {.Missing_Record, u64(input_history.History_Record_Kind.Shared_Mapping), u64(kind)}, input_history.history_reader_next_point(&rec.reader)
	}
	entry, access, valid := input_history.shared_mapping_validate(payload)
	if !valid {
		return {.Missing_Record, u64(input_history.History_Record_Kind.Shared_Mapping), 0}, record_header.point_number
	}
	check = input_history.replay_shared_mapping_check(command_values, completion_address, entry, access)
	if check.divergence != .None {
		return check, record_header.point_number
	}
	if !replay_stand_in_mapping_add_locked(process_index, entry, access, in_head = false) {
		return {.Unexpected_Arguments, entry.virtual_address, 0}, record_header.point_number
	}
	input_history.history_reader_advance(&rec.reader, record_header, stride)
	return {}, 0
}

// replay_stand_in_mappings_unmap unmaps each stand-in mapping of a replay
// that Replay_Start refused: the process never runs, and its address space
// keeps no page that the history paid. A mapping that is no longer the
// stand-in mapping (another object, or the same slot with another serial)
// stays. Caller holds Control and process_index's process lock.
@(private = "file")
replay_stand_in_mappings_unmap :: proc "contextless" (process_index: u32) {
	rec := &process_records[process_index]
	process := &processes[process_index]
	for stand_in in rec.stand_ins.mappings[:rec.stand_ins.count] {
		mapping := mapping_at(process, stand_in.virtual_address)
		if mapping != nil && mapping.region == stand_in.place && regions[mapping.region].serial == stand_in.place_serial {
			unmap(process, mapping)
		}
	}
	rec.stand_ins = {}
}

// replay_record_point gives the input point of a divergence found at a
// record that a replay read: the point of that record, or, when the history
// had no valid record there, the point that the next record must have.
@(private = "file")
replay_record_point :: proc "contextless" (reader: ^input_history.History_Reader, record_header: input_history.History_Record_Header, read: bool) -> u64 {
	if read {
		return record_header.point_number
	}
	return input_history.history_reader_next_point(reader)
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

// read_instruction_bytes_locked reads up to 3 bytes at rip safely through the
// direct map without faulting. Caller holds process's process lock.
@(private = "file")
read_instruction_bytes_locked :: proc "contextless" (process: ^Process, rip: u64, out: ^[3]u8) -> int {
	count := 0
	for offset in u64(0) ..< 3 {
		if rip > USER_END - 1 - offset {
			break
		}
		pb := process_byte_read(process, rip + offset)
		if !pb.readable {
			break
		}
		out[offset] = pb.value
		count += 1
	}
	return count
}

// record_replay_handle_gp handles #GP from a recorded or replayed user thread
// (or a thread whose recording just ended while traps were still loaded on
// this processor). When the faulting instruction is rdtsc (0F 31), rdtscp
// (0F 01 F9), or cpuid (0F A2), it emulates, records, or replays it and
// advances RIP, returning true so no #GP is delivered to a user fault handler.
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
	instruction_bytes: [3]u8
	byte_count := read_instruction_bytes_locked(process, thread.frame.rip, &instruction_bytes)
	decoded := replay_filter.decode_trapped_instruction(instruction_bytes[:byte_count])
	if mode == .None {
		process_unlock(process_index, taken)
		if cpu.record_traps_loaded {
			record_traps_unload(cpu)
			if decoded.kind != .None {
				// Recording ended concurrently before the IPI arrived; retry
				// the instruction with hardware traps now disabled.
				return true
			}
		}
		return false
	}
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
			a, b, c, d := processor_identification_read(leaf, subleaf)
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

	// Replaying mode: snapshot record once into private scratch before checking.
	if !replay_apply_pending_page_deltas_locked(cpu, process_index) {
		point := input_history.history_reader_next_point(&rec.reader)
		process_unlock(process_index, taken)
		replay_stop_on_divergence(process_index, .Missing_Record, point, 0, 0)
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
	rec_header, rec_kind, rec_payload, has_more, read_ok := input_history.history_reader_next_into(&rec.reader, cpu.replay_record_scratch[:])
	check := input_history.replay_step_check(actual, read_ok && has_more, rec_header, rec_kind, rec_payload)
	if check.divergence != .None {
		point := replay_record_point(&rec.reader, rec_header, read_ok && has_more)
		process_unlock(process_index, taken)
		replay_stop_on_divergence(process_index, check.divergence, point, check.expected, check.actual)
		return true
	}
	switch decoded.kind {
	case .None:
	case .Rdtsc:
		payload, ok := input_history.cycle_counter_from_payload(rec_payload)
		if !ok {
			point := rec_header.point_number
			process_unlock(process_index, taken)
			replay_stop_on_divergence(process_index, .Missing_Record, point, 0, 0)
			return true
		}
		thread.frame.rax = u64(u32(payload.cycles))
		thread.frame.rdx = u64(u32(payload.cycles >> 32))
		thread.frame.rip += u64(decoded.length)
	case .Rdtscp:
		payload, ok := input_history.cycle_counter_from_payload(rec_payload)
		if !ok {
			point := rec_header.point_number
			process_unlock(process_index, taken)
			replay_stop_on_divergence(process_index, .Missing_Record, point, 0, 0)
			return true
		}
		thread.frame.rax = u64(u32(payload.cycles))
		thread.frame.rdx = u64(u32(payload.cycles >> 32))
		thread.frame.rcx = u64(payload.processor_auxiliary)
		thread.frame.rip += u64(decoded.length)
	case .Cpuid:
		payload, ok := input_history.cpuid_from_payload(rec_payload)
		if !ok {
			point := rec_header.point_number
			process_unlock(process_index, taken)
			replay_stop_on_divergence(process_index, .Missing_Record, point, 0, 0)
			return true
		}
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
record_command_output_range :: proc "contextless" (command: ring.Record, outcome: call_outcome.Call_Outcome, results: [7]u64) -> (address: u64, size: u64) {
	if outcome != .Succeeded {
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
	case .Memory_Read:
		// The bytes that the copy wrote: the replay gives them again.
		return v[2], results[0]
	case .Thread_Control:
		sub, sub_ok := enum_word.member_of_word(op.Thread_Control_Command, v[2])
		if !sub_ok {
			return 0, 0
		}
		switch sub {
		case .Read_Registers, .Read_Extended_State, .Read_Schedule, .Read_Breakpoints, .Read_Memory, .Read_Placement, .Read_Process_Schedule, .Read_Counters:
			return v[3], results[0]
		case .None, .Stop, .Resume, .Write_Registers, .Write_Extended_State, .Write_Schedule, .Write_Breakpoints, .Write_Placement, .Write_Process_Schedule, .Start_Counters, .Stop_Counters, .Record_Start, .Record_End, .Replay_Start, .Wait_Room:
		}
	case .None, .Log, .Memory_Create, .Memory_Map, .Memory_Unmap, .Memory_Size, .Process_Create, .Process_Start, .Process_Stop, .Handle_Give, .Handle_Close, .Interrupt_Read, .Device_Create, .Machine_Stop, .Thread_Create, .Thread_Stop, .Thread_State, .Word_Wait, .Word_Wake, .Budget_Create, .Budget_Read, .Handle_State, .Handle_Revoke, .Memory_Physical, .Process_Module, .Strategy_Set, .Memory_Commit, .Memory_Protect, .Fault_Handler_Set, .Fault_Answer, .Events_Set, .Guest_Run:
	}
	return 0, 0
}

// record_self_stop_completion_locked records the final Process_Stop or
// Thread_Stop command BEFORE process_stop ends the input history, so replay
// observes the exact stopping command followed by History_End(.Normal_Stop).
// Caller holds Control and thread.process's process lock.
record_self_stop_completion_locked :: proc "contextless" (cpu: ^Processor, thread: ^Thread, command: ring.Record) {
	process_index := thread.process
	rec := &process_records[process_index]
	if rec.mode != .Recording {
		return
	}
	return_time := intrinsics.atomic_load(&time_milliseconds)
	thread.replay_return_time = return_time
	if !record_refresh_point_copies_locked(cpu, process_index, thread) {
		record_replay_end_locked(process_index, .Buffer_Full)
		return
	}
	entry := input_history.Kernel_Completion_Payload {
		command_kind             = command.kind,
		command_tag              = command.tag,
		command_values           = command.values,
		completion_status        = u32(call_outcome.Call_Outcome.Succeeded),
		return_time_milliseconds = return_time,
	}
	if !input_history.history_writer_append_kernel_completion(&rec.writer, thread.frame.rip, thread.frame.rsp, entry, nil) {
		record_replay_end_locked(process_index, .Buffer_Full)
	}
}

// record_kernel_completion records one executed kernel command (or a
// zero-command wait entry) and refreshes point copies. Called from enter()
// or run() with NO locks held.
record_kernel_completion :: proc "contextless" (cpu: ^Processor, thread: ^Thread, command: ring.Record, outcome: call_outcome.Call_Outcome, completion_values: [7]u64) {
	process_index := thread.process
	process := &processes[process_index]
	return_time := intrinsics.atomic_load(&time_milliseconds)
	taken := process_lock(process_index)
	rec := &process_records[process_index]
	if rec.mode != .Recording {
		process_unlock(process_index, taken)
		return
	}
	thread.replay_return_time = return_time
	buffer_ok := record_refresh_point_copies_locked(cpu, process_index, thread)
	copied_slice: []u8
	copied_address: u64
	if buffer_ok {
		out_address, out_size := record_command_output_range(command, outcome, completion_values)
		if out_size > 0 {
			if out_address == 0 || out_size > RECORD_COPY_SCRATCH_BYTES || !user_range(process, out_address, out_size, false) {
				buffer_ok = false
			} else {
				user_copy_from_process(&cpu.record_copy_scratch[0], out_address, out_size)
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
			completion_status        = u32(outcome),
			copied_bytes_count       = u32(len(copied_slice)),
			completion_values        = completion_values,
			return_time_milliseconds = return_time,
			copied_user_address      = copied_address,
		}
		buffer_ok = input_history.history_writer_append_kernel_completion(&rec.writer, thread.frame.rip, thread.frame.rsp, entry, copied_slice)
	}
	if buffer_ok && rec.pending_mapping.active {
		// Only the completion of the Memory_Map that made the mapping takes
		// it. Another completion cannot come first: the map and this record
		// run in one kernel entry, and a stop ends the record (which zeroes
		// the pending mapping). If it came, the history gets no
		// Shared_Mapping, and the replay stops at the first delta of that
		// mapping with Missing_Record: a clear refusal, never a wrong place.
		if command.kind &~ op.COMMAND_NAMES_ERROR_DETAILS == u32(op.Operation.Memory_Map) && outcome == .Succeeded && completion_values[0] == rec.pending_mapping.virtual_address {
			buffer_ok = record_received_mapping_write_locked(cpu, process_index, thread)
		} else {
			rec.pending_mapping = {}
		}
	}
	process_unlock(process_index, taken)
	if !buffer_ok {
		record_end_on_buffer_full(process_index)
	}
}

// record_received_mapping_write_locked writes, right after the completion
// of the Memory_Map that made it, the Shared_Mapping of a mapping of
// received memory, then the first bytes of each of its pages: the bytes
// that the process sees, from its point copy, from the baseline of its
// shared page, else from the page of the object, which no other process
// writes. The replay reads the completion, maps its stand-in mapping at
// that address, and writes these bytes there. false: the history is full.
// Caller holds the process lock.
@(private = "file")
record_received_mapping_write_locked :: proc "contextless" (cpu: ^Processor, process_index: u32, thread: ^Thread) -> bool {
	rec := &process_records[process_index]
	pending := rec.pending_mapping
	rec.pending_mapping = {}
	entry := input_history.Shared_Mapping_Payload {
		virtual_address = pending.virtual_address,
		page_count      = pending.page_count,
		access          = u32(pending.access),
	}
	if !input_history.history_writer_append(&rec.writer, .Shared_Mapping, thread.frame.rip, thread.frame.rsp, ([^]u8)(&entry)[:size_of(entry)]) {
		return false
	}
	mapping := mapping_at(&processes[process_index], pending.virtual_address)
	for page in u64(0) ..< pending.page_count {
		virtual_address := pending.virtual_address + page * PAGE_SIZE
		seen := received_page_bytes_locked(rec, mapping, virtual_address)
		written, changed, ok := input_history.page_delta_encode(virtual_address, &RECORD_ZERO_PAGE, seen, cpu.page_delta_scratch[:])
		if !ok || (changed && !input_history.history_writer_append(&rec.writer, .Page_Delta, thread.frame.rip, thread.frame.rsp, cpu.page_delta_scratch[:written])) {
			return false
		}
	}
	return true
}

// received_page_bytes_locked gives the bytes of a page of a received
// mapping as the history must hold them at its Shared_Mapping: the point
// copy, else the baseline of the shared page, else the page of the object.
// A page with no frame yet holds zeros. Caller holds the process lock.
@(private = "file")
received_page_bytes_locked :: proc "contextless" (rec: ^Process_Record_State, mapping: ^Mapping, virtual_address: u64) -> ^[PAGE_SIZE]u8 {
	for index in u32(0) ..< rec.point_copy_count {
		if pc := &rec.point_copies[index]; pc.active && pc.virtual_address == virtual_address {
			return direct(pc.copy_frame, [PAGE_SIZE]u8)
		}
	}
	for index in u32(0) ..< rec.shared_page_count {
		if page := &rec.shared_pages[index]; page.active && page.virtual_address == virtual_address {
			return direct(page.baseline_frame, [PAGE_SIZE]u8)
		}
	}
	if mapping != nil {
		if frame := region_frame(&regions[mapping.region], mapping.first + (virtual_address - mapping.address) / PAGE_SIZE, false); frame != 0 {
			return direct(frame, [PAGE_SIZE]u8)
		}
	}
	return &RECORD_ZERO_PAGE
}

// record_context_page_locked writes the context page of the target into
// the history as its first bytes (src/md/features/record_and_replay.md,
// "What an input history holds"). A process
// with no context page, or a context page that a point copy already
// records, adds nothing. false: the history is full. Caller holds target's
// process lock.
@(private = "file")
record_context_page_locked :: proc "contextless" (cpu: ^Processor, target_index: u32, rec: ^Process_Record_State) -> bool {
	for index in u32(0) ..< rec.point_copy_count {
		if rec.point_copies[index].active && rec.point_copies[index].virtual_address == op.CONTEXT_ADDRESS {
			return true
		}
	}
	mapping := mapping_at(&processes[target_index], op.CONTEXT_ADDRESS)
	if mapping == nil || mapping.large {
		return true
	}
	region := &regions[mapping.region]
	frame := region_frame(region, mapping.first + (op.CONTEXT_ADDRESS - mapping.address) / PAGE_SIZE, false)
	if frame == 0 || region.device {
		return true
	}
	written, changed, ok := input_history.page_delta_encode(op.CONTEXT_ADDRESS, &RECORD_ZERO_PAGE, direct(frame, [PAGE_SIZE]u8), cpu.page_delta_scratch[:])
	return ok && (!changed || input_history.history_writer_append(&rec.writer, .Page_Delta, 0, 0, cpu.page_delta_scratch[:written]))
}

// Shared writers (src/md/features/record_and_replay.md, "The hard cases, and
// the choices"). A page that the recorded process maps with Write, and that
// another process maps with Write too, cannot take a point copy: the writes of
// the recorded process must reach the peer at once. So the peer writes the
// real page, and only while the recorded thread is at an input point. The
// pure gate (replay_filter.Shared_Writer_Gate), under the process lock of the
// recorded process, decides; the kernel keeps three hooks:
//
// - the pick of a processor (shared_writer_run_begin) asks the gate before a
//   thread of a writer runs, and the leave of the processor
//   (shared_writer_run_end) ends that run. The pick passes over a waiting
//   writer by one hint (shared_writer_held), so a processor does not take it
//   again and again;
// - the kernel entry of the recorded thread (record_enter_input_point) copies
//   each shared page into its baseline, then lets the writers run;
// - the return of the recorded thread to its own instructions
//   (record_leave_input_point) waits until no writer is on a processor, then
//   writes each range that the writers changed as a Page_Delta, at that point.
//
// The tick of the first processor (shared_writer_wait_bound_check) ends the
// history when a writer waited one stint: a record never holds a process
// that the recorder does not hold for ever.

// shared_writers_add_of_region adds each other live process that maps
// region_index with Write as a shared writer of the gate. A writer that is
// recorded or replayed itself, or that writes for another record, is
// refused: one gate holds each writer. admit_only: the same checks, and a
// count of the new writers against the free slots of the gate, with no
// change; the gate can be Inactive then. Caller holds Control and target's
// process lock.
@(private = "file")
shared_writers_add_of_region :: proc "contextless" (target_index: u32, rec: ^Process_Record_State, region_index: u32, admit_only := false) -> Operation_Outcome {
	new_writers: u32
	if region_others_none(target_index, region_index, true) {
		return .Succeeded
	}
	for &other, slot in processes[1:] {
		other_index := u32(slot + 1)
		if other_index == target_index {
			continue
		}
		other_taken := process_lock(other_index)
		writes := false
		if other.state != .None && other.state != .Stopped {
			for mapping in other.mappings {
				if mapping.page_count != 0 && mapping.region == region_index && mapping.bits & PAGE_WRITE != 0 {
					writes = true
					break
				}
			}
		}
		serial := other.serial
		process_unlock(other_index, other_taken)
		if !writes {
			continue
		}
		if intrinsics.atomic_load(&process_records[other_index].mode) != .None {
			return .Wrong_State
		}
		if writes_for := intrinsics.atomic_load(&other.shared_writer_of); writes_for != 0 && writes_for != target_index {
			return .Wrong_State
		}
		known := false
		for entry in rec.gate.writers {
			if entry.process_slot == other_index && entry.process_serial == serial {
				known = true
				break
			}
		}
		if known {
			continue
		}
		if admit_only {
			new_writers += 1
			if new_writers > replay_filter.SHARED_WRITER_CAPACITY - rec.gate.writer_count {
				return .Budget_Or_Capacity_Exhausted
			}
		} else if !replay_filter.add_shared_writer(&rec.gate, other_index, serial) {
			return .Budget_Or_Capacity_Exhausted
		}
	}
	return .Succeeded
}

// shared_writers_setup finds each page that the target maps with Write and
// that another live process maps with Write too, keeps a baseline copy of
// it paid by the budget of the history, records its first bytes, and makes
// the gate of its writers. Large pages, uncommitted objects and pages with
// no access are refused: the copy of each entry must stay bounded and see
// what the process sees. Caller holds Control and target's process lock.
@(private = "file")
shared_writers_setup :: proc "contextless" (cpu: ^Processor, target_index: u32, rec: ^Process_Record_State) -> Operation_Outcome {
	target := &processes[target_index]
	for &mapping in target.mappings {
		if mapping.page_count == 0 || mapping.bits & PAGE_WRITE == 0 || !region_mapped_writable_by_other(target_index, mapping.region) {
			continue
		}
		region := &regions[mapping.region]
		if mapping.large || region.uncommitted || region.device {
			return .Wrong_State
		}
		if rec.gate.state == .Inactive && !replay_filter.shared_writer_gate_init(&rec.gate, target_index, target.serial, SHARED_WRITER_WAIT_BOUND_MILLISECONDS) {
			return .Wrong_State
		}
		shared_writers_add_of_region(target_index, rec, mapping.region) or_return
		if mapping.page_count > u64(SHARED_PAGE_CAPACITY - rec.shared_page_count) {
			return .Budget_Or_Capacity_Exhausted
		}
		// The replay holds no writer: it maps private pages here, and each
		// Page_Delta of the history writes them.
		if !record_shared_mapping_locked(rec, mapping.address, mapping.page_count, .Read_Write, mapping.region) {
			return .Argument_Refused
		}
		for page in u64(0) ..< mapping.page_count {
			if rec.shared_page_count >= SHARED_PAGE_CAPACITY {
				return .Budget_Or_Capacity_Exhausted
			}
			source_page := mapping.first + page
			if page_bits(&mapping, region_page_state(region, source_page)) == 0 {
				return .Wrong_State
			}
			baseline, allocated := point_copy_frame_allocate(rec.history_region)
			if !allocated {
				return .Budget_Or_Capacity_Exhausted
			}
			virtual_address := mapping.address + page * PAGE_SIZE
			rec.shared_pages[rec.shared_page_count] = {
				virtual_address = virtual_address,
				region          = mapping.region,
				page            = source_page,
				baseline_frame  = baseline,
				active          = true,
			}
			rec.shared_page_count += 1
			if source_frame := region_frame(region, source_page, false); source_frame != 0 {
				intrinsics.mem_copy_non_overlapping(direct(baseline, u8), direct(source_frame, u8), PAGE_SIZE)
			}
			// The first bytes of the page are an input, as those of a point copy.
			written, changed, ok := input_history.page_delta_encode(virtual_address, &RECORD_ZERO_PAGE, direct(baseline, [PAGE_SIZE]u8), cpu.page_delta_scratch[:])
			if !ok || (changed && !input_history.history_writer_append(&rec.writer, .Page_Delta, 0, 0, cpu.page_delta_scratch[:written])) {
				return .Argument_Refused
			}
		}
	}
	return .Succeeded
}

// shared_writers_publish tells each writer of the gate that its threads ask
// the gate before they run. The generation names this record for the writer
// threads that the gate counts, so a run that ends after a later record
// began changes nothing there. A record publishes again when a mapping
// that the process makes after its start adds writers: the generation and
// the count of the records stay. Caller holds Control and target's process
// lock.
@(private = "file")
shared_writers_publish :: proc "contextless" (target_index: u32, rec: ^Process_Record_State) {
	if rec.gate.state != .Active {
		return
	}
	if !intrinsics.atomic_load(&rec.has_shared_writers) {
		record_generation_last += 1
		rec.generation = record_generation_last
	}
	for entry in rec.gate.writers {
		if entry.process_slot != 0 {
			intrinsics.atomic_store(&processes[entry.process_slot].shared_writer_of, target_index)
		}
	}
	if !intrinsics.atomic_load(&rec.has_shared_writers) {
		intrinsics.atomic_store(&rec.has_shared_writers, true)
		intrinsics.atomic_add(&shared_writer_recordings, 1)
	}
}

// shared_writers_teardown frees the baselines, tells each writer that it
// runs freely again, and wakes the idle processors so that a writer that
// waited runs. Caller holds Control and target's process lock.
@(private = "file")
shared_writers_teardown :: proc "contextless" (target_index: u32, rec: ^Process_Record_State) {
	for index in u32(0) ..< rec.shared_page_count {
		page := &rec.shared_pages[index]
		if page.active {
			point_copy_frame_free(rec.history_region, page.baseline_frame)
		}
		page^ = {}
	}
	rec.shared_page_count = 0
	if rec.gate.state == .Inactive {
		return
	}
	for entry in rec.gate.writers {
		if entry.process_slot != 0 && processes[entry.process_slot].serial == entry.process_serial {
			_, _ = intrinsics.atomic_compare_exchange_strong(&processes[entry.process_slot].shared_writer_of, target_index, 0)
		}
	}
	intrinsics.atomic_store(&rec.writers_held, false)
	if intrinsics.atomic_load(&rec.has_shared_writers) {
		intrinsics.atomic_store(&rec.has_shared_writers, false)
		intrinsics.atomic_sub(&shared_writer_recordings, 1)
	}
	rec.gate = {}
	kick_all()
}

// record_replay_writer_stopped removes a stopped process from the gate that
// it wrote for. It runs at the cleanup, when no thread of the process is on
// a processor, so the recorded thread no longer waits for a writer that
// cannot write. Caller holds Control and no process lock.
record_replay_writer_stopped :: proc "contextless" (writer_index: u32) {
	target_index := intrinsics.atomic_load(&processes[writer_index].shared_writer_of)
	if target_index == 0 {
		return
	}
	taken := process_lock(target_index)
	rec := &process_records[target_index]
	if rec.mode == .Recording && rec.gate.state == .Active {
		_ = replay_filter.remove_shared_writer(&rec.gate, writer_index, processes[writer_index].serial)
	}
	intrinsics.atomic_store(&processes[writer_index].shared_writer_of, 0)
	process_unlock(target_index, taken)
}

// shared_writer_held is the hint of the pick: a thread of a shared writer
// whose recorded thread runs its own instructions. Each candidate of a pick
// pays one load of a word that is 0 when no record has a shared writer. The
// gate decides under the lock at the run (shared_writer_run_begin).
shared_writer_held :: #force_inline proc "contextless" (thread: ^Thread) -> bool {
	if intrinsics.atomic_load(&shared_writer_recordings) == 0 {
		return false
	}
	target_index := intrinsics.atomic_load(&processes[thread.process].shared_writer_of)
	return target_index != 0 && intrinsics.atomic_load(&process_records[target_index].writers_held)
}

// shared_writer_run_begin asks the gate before a processor runs a thread of
// a shared writer. false: the recorded thread runs its own instructions or
// waits to: the thread goes back to its queue. The caller holds no lock.
shared_writer_run_begin :: proc "contextless" (thread: ^Thread) -> bool {
	writer_index := thread.process
	target_index := intrinsics.atomic_load(&processes[writer_index].shared_writer_of)
	if target_index == 0 {
		return true
	}
	taken := process_lock(target_index)
	defer process_unlock(target_index, taken)
	rec := &process_records[target_index]
	if rec.mode != .Recording || rec.gate.state != .Active {
		return true
	}
	serial := processes[writer_index].serial
	may_run, decision := replay_filter.shared_writer_may_run(&rec.gate, writer_index, serial, intrinsics.atomic_load(&time_milliseconds))
	switch decision {
	case .Run_Freely:
		return true
	case .Wait_Input_Point:
		// The gate armed the bound for this writer: the tick reads it.
		shared_writer_wait_mirror_locked(rec)
		return false
	case .Run_At_Input_Point:
	}
	began := may_run && replay_filter.shared_writer_begin_run(&rec.gate, writer_index, serial)
	shared_writer_wait_mirror_locked(rec)
	if !began {
		return false
	}
	thread.shared_writer_gate_process = target_index
	thread.shared_writer_gate_generation = rec.generation
	return true
}

// shared_writer_run_end ends the run that shared_writer_run_begin counted,
// when the processor leaves the thread. A record that ended or that another
// record replaced (another generation) changes nothing. The caller holds no
// lock.
shared_writer_run_end :: proc "contextless" (thread: ^Thread) {
	target_index := thread.shared_writer_gate_process
	generation := thread.shared_writer_gate_generation
	thread.shared_writer_gate_process = 0
	thread.shared_writer_gate_generation = 0
	if target_index == 0 {
		return
	}
	taken := process_lock(target_index)
	rec := &process_records[target_index]
	if rec.mode == .Recording && rec.generation == generation {
		_ = replay_filter.shared_writer_end_run(&rec.gate, thread.process, processes[thread.process].serial)
	}
	process_unlock(target_index, taken)
}

// shared_writers_on_processor_locked says if a thread of a writer is on a
// processor. The count of the process covers a writer that a processor took
// before the gate counted it, at the start of the record. Caller holds
// target's process lock.
@(private = "file")
shared_writers_on_processor_locked :: proc "contextless" (rec: ^Process_Record_State) -> bool {
	if rec.gate.active_writer_cpus != 0 {
		return true
	}
	for entry in rec.gate.writers {
		if entry.process_slot != 0 && processes[entry.process_slot].serial == entry.process_serial && u32(intrinsics.atomic_load(&processes[entry.process_slot].holds)) != 0 {
			return true
		}
	}
	return false
}

// shared_writers_preempt ends the stint of each processor that runs a thread
// of a writer of target_index, so the recorded thread waits at most for the
// end of a kernel entry of a writer. It reads the current thread of each
// processor with no lock: a processor that changed its thread meanwhile
// passes through schedule once more.
@(private = "file")
shared_writers_preempt :: proc "contextless" (target_index: u32) {
	self := processor_self()
	for cpu in processors[:processor_count] {
		if cpu == self {
			continue
		}
		running := intrinsics.atomic_load(&cpu.current)
		if running != 0 && intrinsics.atomic_load(&processes[threads[running].process].shared_writer_of) == target_index {
			intrinsics.atomic_store(&cpu.preempt, true)
			apic_send(cpu.apic_id, VECTOR_WAKE)
		}
	}
}

// shared_pages_diff_locked writes, as Page_Delta records at this point, each
// range of a shared page that changed since the baseline. No writer is on a
// processor, so each page holds still during its read. A page with no frame
// yet holds zeros. false: the history is full. Caller holds the process lock.
@(private = "file")
shared_pages_diff_locked :: proc "contextless" (cpu: ^Processor, rec: ^Process_Record_State, thread: ^Thread) -> bool {
	for index in u32(0) ..< rec.shared_page_count {
		page := &rec.shared_pages[index]
		if !page.active {
			continue
		}
		live := &RECORD_ZERO_PAGE
		if frame := region_frame(&regions[page.region], page.page, false); frame != 0 {
			live = direct(frame, [PAGE_SIZE]u8)
		}
		written, changed, ok := input_history.page_delta_encode(page.virtual_address, direct(page.baseline_frame, [PAGE_SIZE]u8), live, cpu.page_delta_scratch[:])
		if !ok {
			return false
		}
		if changed && !input_history.history_writer_append(&rec.writer, .Page_Delta, thread.frame.rip, thread.frame.rsp, cpu.page_delta_scratch[:written]) {
			return false
		}
	}
	return true
}

// record_enter_input_point runs at the start of a kernel entry of a recorded
// thread that ran its own instructions. While it ran, no writer was on a
// processor, so each shared page holds what the recorded process left there:
// the baseline takes it, then the writers may run. Caller holds no lock.
record_enter_input_point :: proc "contextless" (thread: ^Thread) {
	thread.record_outside_point = false
	process_index := thread.process
	rec := &process_records[process_index]
	if !intrinsics.atomic_load(&rec.has_shared_writers) {
		return
	}
	taken := process_lock(process_index)
	released := false
	if rec.mode == .Recording && rec.gate.state == .Active {
		for index in u32(0) ..< rec.shared_page_count {
			page := &rec.shared_pages[index]
			if !page.active {
				continue
			}
			if frame := region_frame(&regions[page.region], page.page, false); frame != 0 {
				intrinsics.mem_copy_non_overlapping(direct(page.baseline_frame, u8), direct(frame, u8), PAGE_SIZE)
			} else {
				frames_zero(page.baseline_frame, 1)
			}
		}
		// A writer that is ready now waits from this entry on, unless it
		// waited already: the gate keeps the first start of the wait until
		// a writer runs, so a thread that enters and leaves again before
		// any writer is taken does not move the bound.
		shared_writers_waiting_mark_locked(rec, intrinsics.atomic_load(&time_milliseconds))
		_ = replay_filter.recorded_thread_enter_input_point(&rec.gate, thread_index(thread))
		intrinsics.atomic_store(&rec.writers_held, false)
		// Only a writer that waits needs an idle processor to look again.
		released = rec.gate.waiting_writer_count != 0
		shared_writer_wait_mirror_locked(rec)
	}
	process_unlock(process_index, taken)
	if released {
		kick_all()
	}
}

// shared_writers_waiting_mark_locked tells the gate of each writer that has
// a thread ready and on no processor: the gate marks it waiting and arms
// the bound at start, or keeps the start of an earlier wait. Caller holds
// the process lock of the recorded process.
@(private = "file")
shared_writers_waiting_mark_locked :: proc "contextless" (rec: ^Process_Record_State, start: u64) {
	for entry in rec.gate.writers {
		if entry.process_slot != 0 && shared_writer_has_ready_thread(entry.process_slot, entry.process_serial) {
			_, _ = replay_filter.shared_writer_may_run(&rec.gate, entry.process_slot, entry.process_serial, start)
		}
	}
}

// shared_writer_wait_mirror_locked copies the bound of the gate where the
// tick reads it with no lock. Caller holds the process lock of the recorded
// process, after each change of the gate.
@(private = "file")
shared_writer_wait_mirror_locked :: proc "contextless" (rec: ^Process_Record_State) {
	intrinsics.atomic_store(&rec.writer_wait_since, rec.gate.wait_started_tick)
	intrinsics.atomic_store(&rec.writer_wait_armed, rec.gate.wait_timer_armed)
}

// record_leave_input_point runs before a recorded thread at an input point
// returns to its own instructions. false: a writer is still on a processor;
// its processor got an interrupt, the leave stays asked, and the caller
// passes through schedule before it tries again. true: no writer runs until
// the next input point, and the history holds each range that the writers
// wrote at this point. Caller holds no lock.
record_leave_input_point :: proc "contextless" (cpu: ^Processor, thread: ^Thread) -> bool {
	process_index := thread.process
	rec := &process_records[process_index]
	if !intrinsics.atomic_load(&rec.has_shared_writers) {
		thread.record_outside_point = true
		return true
	}
	taken := process_lock(process_index)
	if rec.mode != .Recording || rec.gate.state != .Active {
		process_unlock(process_index, taken)
		thread.record_outside_point = true
		return true
	}
	if !rec.writers_held {
		intrinsics.atomic_store(&rec.writers_held_since, intrinsics.atomic_load(&time_milliseconds))
		intrinsics.atomic_store(&rec.writers_held, true)
	}
	thread_id := thread_index(thread)
	if shared_writers_on_processor_locked(rec) {
		_ = replay_filter.recorded_thread_request_leave(&rec.gate, thread_id)
		shared_writer_wait_mirror_locked(rec)
		process_unlock(process_index, taken)
		shared_writers_preempt(process_index)
		return false
	}
	switch replay_filter.recorded_thread_leave_input_point(&rec.gate, thread_id) {
	case .Left, .Refused:
		// Refused: the gate does not hold this thread (it left already).
	case .Must_Wait_Writers:
		process_unlock(process_index, taken)
		shared_writers_preempt(process_index)
		return false
	}
	buffer_ok := shared_pages_diff_locked(cpu, rec, thread)
	thread.record_outside_point = true
	process_unlock(process_index, taken)
	if !buffer_ok {
		record_end_on_buffer_full(process_index)
	}
	return true
}

// shared_writer_has_ready_thread says if a process has a thread that is
// ready and on no processor: a writer that waits. It reads with no lock: the
// bound acts on what the tick saw.
@(private = "file")
shared_writer_has_ready_thread :: proc "contextless" (process_index: u32, serial: u32) -> bool {
	if processes[process_index].serial != serial {
		return false
	}
	for &thread in threads[1:] {
		if thread.process == process_index && intrinsics.atomic_load(&thread.state) == .Ready && intrinsics.atomic_load(&thread.processor) == 0 && intrinsics.atomic_load(&thread.control_stops) == 0 {
			return true
		}
	}
	return false
}

// shared_writer_wait_bound_check ends the history of each record whose
// writer waited one stint for its recorded thread: the writer then runs.
// The gate decides, from the first start of the wait, which it keeps until
// a writer runs; the kernel entries of the recorded thread do not move it.
// A writer that became ready while the recorded thread ran its own
// instructions, and that no entry saw yet, waits since the thread left its
// input point. Runs at the tick of the first processor, with no lock held;
// it takes the control lock only for a record past its bound.
shared_writer_wait_bound_check :: proc "contextless" (now: u64) {
	for target_index in u32(1) ..< process_capacity {
		rec := &process_records[target_index]
		if !intrinsics.atomic_load(&rec.has_shared_writers) {
			continue
		}
		armed := intrinsics.atomic_load(&rec.writer_wait_armed)
		since: u64
		switch {
		case armed:
			since = intrinsics.atomic_load(&rec.writer_wait_since)
		case intrinsics.atomic_load(&rec.writers_held):
			since = intrinsics.atomic_load(&rec.writers_held_since)
		case:
			continue
		}
		if now < since || now - since < SHARED_WRITER_WAIT_BOUND_MILLISECONDS {
			continue
		}
		// With no wait that the gate knows, a writer must be ready now. The
		// table of the writers is read with no lock, as a hint: the gate
		// decides under the lock.
		if !armed && !shared_writers_any_ready(rec) {
			continue
		}
		control_take()
		taken := process_lock(target_index)
		if rec.mode == .Recording && rec.gate.state == .Active {
			if !rec.gate.wait_timer_armed && rec.writers_held {
				shared_writers_waiting_mark_locked(rec, rec.writers_held_since)
			}
			if expired, _ := replay_filter.shared_writer_stint_expired(&rec.gate, now); expired {
				record_replay_end_locked(target_index, .Stint_Bound_Reached)
			} else {
				shared_writer_wait_mirror_locked(rec)
			}
		}
		process_unlock(target_index, taken)
		control_free()
	}
}

// shared_writers_any_ready says if a writer of the gate has a thread ready
// and on no processor. It reads with no lock: a hint for the tick.
@(private = "file")
shared_writers_any_ready :: proc "contextless" (rec: ^Process_Record_State) -> bool {
	for entry in rec.gate.writers {
		if entry.process_slot != 0 && shared_writer_has_ready_thread(entry.process_slot, entry.process_serial) {
			return true
		}
	}
	return false
}

// replay_context_page_clear_locked zeroes the context page of a process that
// has not run, before the history writes the context of the record there.
// Caller holds the process lock.
@(private = "file")
replay_context_page_clear_locked :: proc "contextless" (process_index: u32) {
	if frame := replay_shared_page_frame_locked(process_index, op.CONTEXT_ADDRESS); frame != 0 {
		frames_zero(frame, 1)
	}
}

// replay_shared_page_frame_locked gives the frame of a page that a replayed
// process maps with Write, for a Page_Delta that a shared writer wrote in
// the record. A page with no frame yet gets one: the record saw its bytes.
// 0: no such page. Caller holds the process lock.
@(private = "file")
replay_shared_page_frame_locked :: proc "contextless" (process_index: u32, virtual_address: u64) -> u64 {
	mapping := mapping_at(&processes[process_index], virtual_address)
	if mapping == nil || mapping.large || mapping.bits & PAGE_WRITE == 0 {
		return 0
	}
	region := &regions[mapping.region]
	if region.device {
		return 0
	}
	page := mapping.first + (virtual_address - mapping.address) / PAGE_SIZE
	state := region_page_state(region, page)
	if page_bits(mapping, state) == 0 || !page_committed(region, state) {
		return 0
	}
	return region_frame(region, page, true)
}

// record_wait_wake_completion records a deferred pure-wait entry right when
// the recorded thread wakes up in run(), capturing the post-wake millisecond
// timestamp and post-wake point copy deltas. Caller holds NO locks.
record_wait_wake_completion :: proc "contextless" (cpu: ^Processor, thread: ^Thread) {
	thread.record_wait_pending = false
	if intrinsics.atomic_load(&thread.record_mode) != .Recording {
		return
	}
	record_kernel_completion(cpu, thread, ring.Record{values = {0 = thread.frame.rdi}}, .Succeeded, {})
}

// record_replay_entry_return_time gives the recorded return time for rax in
// run() from per-thread state so recorded and replayed threads see the exact
// millisecond value written into the input history without data races.
record_replay_entry_return_time :: proc "contextless" (thread: ^Thread) -> u64 {
	if intrinsics.atomic_load(&thread.record_mode) == .None {
		return intrinsics.atomic_load(&time_milliseconds)
	}
	return thread.replay_return_time
}

// replay_enter handles a kernel entry of a replayed thread: validates each
// command against a single-fetch private snapshot of the next recorded record,
// executes only local address-space/handle/stop operations for real with
// recorded->real handle translation, replays recorded completions and copied
// bytes, and applies Page_Delta records strictly to tracked point copies.
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
		if !replay_apply_pending_page_deltas_locked(cpu, process_index) {
			point := input_history.history_reader_next_point(&rec.reader)
			process_unlock(process_index, taken)
			replay_stop_on_divergence(process_index, .Missing_Record, point, 0, 0)
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
		rec_header, rec_kind, rec_payload, has_more, read_ok := input_history.history_reader_next_into(&rec.reader, cpu.replay_record_scratch[:])
		check := input_history.replay_step_check(actual, read_ok && has_more, rec_header, rec_kind, rec_payload)
		if check.divergence != .None {
			point := replay_record_point(&rec.reader, rec_header, read_ok && has_more)
			process_unlock(process_index, taken)
			replay_stop_on_divergence(process_index, check.divergence, point, check.expected, check.actual)
			return
		}
		kc, _, kc_ok := input_history.kernel_completion_from_payload(rec_payload)
		if !kc_ok {
			point := rec_header.point_number
			process_unlock(process_index, taken)
			replay_stop_on_divergence(process_index, .Missing_Record, point, 0, 0)
			return
		}
		thread.replay_return_time = kc.return_time_milliseconds
		if !replay_apply_pending_page_deltas_locked(cpu, process_index) {
			point := input_history.history_reader_next_point(&rec.reader)
			process_unlock(process_index, taken)
			replay_stop_on_divergence(process_index, .Missing_Record, point, 0, 0)
			return
		}
		process_unlock(process_index, taken)
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
		if !replay_apply_pending_page_deltas_locked(cpu, process_index) {
			point := input_history.history_reader_next_point(&rec.reader)
			process_unlock(process_index, taken)
			replay_stop_on_divergence(process_index, .Missing_Record, point, 0, 0)
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
		rec_header, rec_kind, rec_payload, has_more, read_ok := input_history.history_reader_next_into(&rec.reader, cpu.replay_record_scratch[:])
		check := input_history.replay_step_check(actual, read_ok && has_more, rec_header, rec_kind, rec_payload)
		if check.divergence != .None {
			point := replay_record_point(&rec.reader, rec_header, read_ok && has_more)
			process_unlock(process_index, taken)
			replay_stop_on_divergence(process_index, check.divergence, point, check.expected, check.actual)
			return
		}
		kc, copied_bytes, kc_ok := input_history.kernel_completion_from_payload(rec_payload)
		if !kc_ok {
			point := rec_header.point_number
			process_unlock(process_index, taken)
			replay_stop_on_divergence(process_index, .Missing_Record, point, 0, 0)
			return
		}
		thread.replay_return_time = kc.return_time_milliseconds

		// Copy recorded output bytes into user memory while holding process lock.
		copy_failed := false
		if len(copied_bytes) > 0 && kc.copied_user_address != 0 {
			if user_range(process, kc.copied_user_address, u64(len(copied_bytes)), true) {
				user_copy_to_process(kc.copied_user_address, raw_data(copied_bytes), u64(len(copied_bytes)))
			} else {
				copy_failed = true
			}
		}

		// Translate recorded local handles while holding process lock.
		operation, op_known := enum_word.member_of_word(op.Operation, u64(command.kind &~ op.COMMAND_NAMES_ERROR_DETAILS))
		recorded_status, status_known := enum_word.member_of_word(call_outcome.Call_Outcome, u64(kc.completion_status))
		exec_command := command
		run_local := false
		refused_op := false
		record_new_handle := false
		received_mapping: input_history.Replay_Check_Result
		received_mapping_point: u64
		if !copy_failed && op_known && status_known && recorded_status == .Succeeded {
			switch replay_filter.replay_operation_policy(operation) {
			case .Refused:
				refused_op = true
			case .Synthetic:
			case .Real_Local:
				switch operation {
				case .Memory_Create:
					run_local = true
					record_new_handle = true
				case .Memory_Map:
					// Memory that the record received from another process:
					// its Shared_Mapping follows this completion, and a
					// stand-in mapping takes the place of the map. The copied
					// bytes of the completion are written already, so the
					// scratch can hold the next record.
					if _, next_kind, _, _, next_has_more, next_ok := input_history.history_reader_peek_into(&rec.reader, cpu.replay_record_scratch[:]); next_ok && next_has_more && next_kind == .Shared_Mapping {
						received_mapping, received_mapping_point = replay_received_mapping_locked(cpu, process_index, exec_command.values, kc.completion_values[0])
					} else if exec_command.values[1] == 0 {
						if real_mem, mapped := replay_filter.replay_handle_map_lookup(&rec.handle_map, exec_command.values[0]); mapped {
							exec_command.values[0] = real_mem
						}
						if exec_command.values[2] == 0 {
							exec_command.values[2] = kc.completion_values[0]
						}
						run_local = true
					}
				case .Memory_Commit:
					if real_mem, mapped := replay_filter.replay_handle_map_lookup(&rec.handle_map, exec_command.values[0]); mapped {
						exec_command.values[0] = real_mem
					}
					run_local = true
				case .Memory_Unmap, .Process_Stop, .Thread_Stop:
					if exec_command.values[0] == 0 {
						run_local = true
					}
				case .Memory_Protect:
					run_local = true
				case .Handle_Close:
					if real_handle, removed := replay_filter.replay_handle_map_remove(&rec.handle_map, exec_command.values[0]); removed {
						exec_command.values[0] = real_handle
						run_local = true
					}
				case .None, .Log, .Memory_Size, .Process_Create, .Process_Start, .Process_State, .Handle_Give, .Interrupt_Read, .Device_Create, .Inspect, .Machine_Stop, .Thread_Create, .Thread_State, .Word_Wait, .Word_Wake, .Budget_Create, .Budget_Read, .Handle_State, .Handle_Revoke, .Memory_Physical, .Process_Module, .Strategy_Set, .Fault_Handler_Set, .Fault_Answer, .Events_Set, .Thread_Control, .Guest_Run, .Log_Read, .Memory_Read:
				}
			}
		}
		process_unlock(process_index, taken)

		if received_mapping.divergence != .None {
			replay_stop_on_divergence(process_index, received_mapping.divergence, received_mapping_point, received_mapping.expected, received_mapping.actual)
			return
		}
		if copy_failed {
			replay_stop_on_divergence(process_index, .Unexpected_Arguments, rec_header.point_number, kc.copied_user_address, 0)
			return
		}
		if refused_op {
			replay_stop_on_divergence(process_index, .Unexpected_Operation, rec_header.point_number, u64(operation), u64(call_outcome.Call_Outcome.Wrong_State))
			return
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
			if operation == .Memory_Map && real_results[0] != kc.completion_values[0] {
				replay_stop_on_divergence(process_index, .Unexpected_Arguments, rec_header.point_number, kc.completion_values[0], real_results[0])
				return
			}
			if record_new_handle {
				map_taken := process_lock(process_index)
				inserted := process_records[process_index].mode == .Replaying && replay_filter.replay_handle_map_insert(&process_records[process_index].handle_map, kc.completion_values[0], real_results[0])
				process_unlock(process_index, map_taken)
				if !inserted {
					replay_stop_on_divergence(process_index, .Unexpected_Operation, rec_header.point_number, kc.completion_values[0], real_results[0])
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
	trailing_ok := true
	trailing_point := u64(0)
	if process_records[process_index].mode == .Replaying {
		trailing_ok = replay_apply_pending_page_deltas_locked(cpu, process_index)
		trailing_point = input_history.history_reader_next_point(&process_records[process_index].reader)
	}
	process_unlock(process_index, taken)
	if !trailing_ok {
		replay_stop_on_divergence(process_index, .Missing_Record, trailing_point, 0, 0)
		return
	}
}
