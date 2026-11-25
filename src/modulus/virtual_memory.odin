package kernel

import "modulus:budget_peak"
import "base:intrinsics"
import "modulus:frame_runs"
import "modulus:memory_wx"
import op "modus:contract/operation"
import "modulus:mapping_order"
import "modulus:word_table"

// The virtual memory of a process (docs/ARCHITECTURE.md, "The virtual
// memory of a process"): commit and decommit the pages of an uncommitted
// object, and change the protection of pages. The caller holds the process
// lock of the process.

// object_only_here says if a memory object is named only by this process,
// with one mapping at most: its pages have page table entries only in this
// process. It gives that mapping, or nil when it has none. The references of the object are the handles and
// the mappings of all processes; under the process lock the handles and the
// mappings of this process do not change, and another process that names
// the object holds a reference.
object_only_here :: proc "contextless" (process: ^Process, region_index: u32) -> (found: ^Mapping, alone: bool) {
	own: u32
	mappings: u32
	for &mapping in process.mappings {
		if mapping.page_count != 0 && mapping.region == region_index {
			mappings += 1
			found = &mapping
		}
	}
	for slot in process.handles {
		if slot.kind == .Memory && slot.object == region_index {
			own += 1
		}
	}
	// At most one mapping: the decommit of an object that this process holds
	// with no mapping has no entry to clear.
	if mappings > 1 || intrinsics.atomic_load(&regions[region_index].references) != own + mappings {
		return nil, false
	}
	return found, true
}

// ranges_valid says if a table of page ranges is in an object of page_count
// pages, in increasing order, with no overlap.
ranges_valid :: proc "contextless" (ranges: []op.Page_Range, page_count: u64) -> bool {
	end: u64
	for range in ranges {
		if range.page_count == 0 || range.first >= page_count || range.page_count > page_count - range.first || range.first < end {
			return false
		}
		end = range.first + range.page_count
	}
	return true
}

// table_pages gives the pages of a table of ranges, at most the limit plus
// one: a table above op.RANGE_TABLE_PAGE_LIMIT is refused (the
// sections of one call walk each page with interrupts off).
table_pages :: proc "contextless" (counts: []u64) -> (sum: u64) {
	for count in counts {
		sum += min(count, op.RANGE_TABLE_PAGE_LIMIT + 1)
		if sum > op.RANGE_TABLE_PAGE_LIMIT {
			return op.RANGE_TABLE_PAGE_LIMIT + 1
		}
	}
	return sum
}

// demotion_table_push parks a zeroed 4 KiB page table frame on process for
// zero-allocation demotion later. Caller holds process lock.
demotion_table_push :: proc "contextless" (process: ^Process, table_phys: u64) {
	direct(table_phys, u64)^ = process.demotion_tables
	process.demotion_tables = table_phys
	process.demotion_table_count += 1
}

// demotion_table_pop pops one zeroed 4 KiB page table frame parked on
// process. Caller holds process lock.
demotion_table_pop :: proc "contextless" (process: ^Process) -> u64 {
	if process.demotion_tables == 0 {
		page_table_count_broken("parked demotion table list empty")
	}
	table_phys := process.demotion_tables
	process.demotion_tables = direct(table_phys, u64)^
	direct(table_phys, u64)^ = 0
	process.demotion_table_count -= 1
	return table_phys
}

// pt_has_present_entries reports whether a level-1 page table has any
// present entry.
@(private = "file")
pt_has_present_entries :: proc "contextless" (pt: u64) -> bool {
	entries := direct(pt, [512]u64)
	for e in entries {
		if e & PAGE_PRESENT != 0 {
			return true
		}
	}
	return false
}

// mapping_install_present_range installs page table entries (1 GiB, 2 MiB,
// or 4 KiB) for pages in [first_in_mapping, first_in_mapping + count) of
// mapping that already have physical frames in region and no present entry
// yet. Caller holds process lock; all level-1 tables of mapping are held.
//
// Replaced upper-level tables stay intact until after the new large entry is
// visible, every sibling CPU has reloaded cr3 (processor_sync), and this CPU
// has reloaded cr3 (clearing paging-structure caches per Intel SDM Vol. 3A).
// Only then are replaced tables zeroed or parked onto process.demotion_tables.
mapping_install_present_range :: proc "contextless" (process: ^Process, mapping: ^Mapping, region: ^Region, first_in_mapping: u64, count: u64) {
	if mapping.large || mapping.bits == 0 || mapping_is_switching(mapping) {
		return
	}
	allow_runs := !region.contiguous && frame_runs_arch_enabled() && process_records[index_of_process(process)].mode == .None && intrinsics.atomic_load(&region.marked_pages) == 0
	flush_and_park_pts :: proc "contextless" (process: ^Process, replaced: []u64) {
		if len(replaced) == 0 {
			return
		}
		intrinsics.atomic_thread_fence(.Seq_Cst)
		processor_sync(processors_with_table(process.table))
		if self := processor_self(); intrinsics.atomic_load(&self.table) == process.table {
			control_register_3_write(process.table)
		}
		for pt in replaced {
			demotion_table_push(process, pt)
		}
	}
	// Stack batch of replaced level-1 tables (512 bytes, 128 MiB per shootdown).
	replaced_pts: [64]u64
	replaced_count := 0
	end := first_in_mapping + count
	for page := first_in_mapping; page < end; {
		addr := mapping.address + page * PAGE_SIZE
		region_page := mapping.first + page
		remaining := end - page
		// Try 1 GiB hardware entry when aligned in both virtual address and
		// region offset and backed by an intact 1 GiB run.
		if allow_runs && frame_runs_table.supports_1g && addr % word_table.GIANT_PAGE_SIZE == 0 && region_page % frame_runs.RUN_1G_PAGES == 0 && remaining >= frame_runs.RUN_1G_PAGES {
			slot0 := intrinsics.atomic_load(region_slot(region, region_page))
			if slot0 & SLOT_RUN_1G != 0 && slot0 & PAGE_ADDRESS != 0 && slot0 & SLOT_MARKS == 0 {
				if pdpte := page_directory_pointer_entry(process.table, addr); pdpte != nil && pdpte^ & PAGE_PRESENT != 0 && pdpte^ & PAGE_LARGE == 0 && table_held_count(pdpte^) == 512 {
					pd := pdpte^ & PAGE_ADDRESS
					pd_entries := direct(pd, [512]u64)
					all_empty := true
					for k in 0 ..< 512 {
						pe := pd_entries[k]
						if pe & PAGE_PRESENT == 0 || pe & PAGE_LARGE != 0 || table_held_count(pe) != 512 || pt_has_present_entries(pe & PAGE_ADDRESS) {
							all_empty = false
							break
						}
					}
					if all_empty {
						// Replace PDPTE first while pd and its 512 PTs stay
						// intact, shoot down all CPUs + local paging-structure
						// caches, then park the 512 PTs and zeroed pd.
						intrinsics.atomic_store(pdpte, (slot0 & PAGE_ADDRESS) | mapping.bits | PAGE_LARGE)
						intrinsics.atomic_thread_fence(.Seq_Cst)
						processor_sync(processors_with_table(process.table))
						if self := processor_self(); intrinsics.atomic_load(&self.table) == process.table {
							control_register_3_write(process.table)
						}
						for pt in replaced_pts[:replaced_count] {
							demotion_table_push(process, pt)
						}
						replaced_count = 0
						for k in 0 ..< 512 {
							demotion_table_push(process, pd_entries[k] & PAGE_ADDRESS)
						}
						frames_zero(pd, 1)
						demotion_table_push(process, pd)
						mapping.present_page_count += frame_runs.RUN_1G_PAGES
						mapping.entries_1g += 1
						page += frame_runs.RUN_1G_PAGES
						continue
					}
				}
			}
		}
		// Try 2 MiB hardware entry when aligned in both virtual address and
		// region offset and backed by an intact 2 MiB run.
		if allow_runs && addr % LARGE_PAGE_SIZE == 0 && region_page % frame_runs.RUN_2M_PAGES == 0 && remaining >= frame_runs.RUN_2M_PAGES {
			slot0 := intrinsics.atomic_load(region_slot(region, region_page))
			if slot0 & SLOT_RUN_2M != 0 && slot0 & PAGE_ADDRESS != 0 && slot0 & SLOT_MARKS == 0 {
				if pde := page_directory_entry(process.table, addr); pde != nil && pde^ & PAGE_PRESENT != 0 && pde^ & PAGE_LARGE == 0 && table_held_count(pde^) == 512 {
					pt := pde^ & PAGE_ADDRESS
					if !pt_has_present_entries(pt) {
						// Replace PDE first while pt stays intact; park pt
						// only after shootdown + local cr3 reload.
						intrinsics.atomic_store(pde, (slot0 & PAGE_ADDRESS) | mapping.bits | PAGE_LARGE)
						replaced_pts[replaced_count] = pt
						replaced_count += 1
						if replaced_count == len(replaced_pts) {
							flush_and_park_pts(process, replaced_pts[:replaced_count])
							replaced_count = 0
						}
						mapping.present_page_count += frame_runs.RUN_2M_PAGES
						mapping.entries_2m += 1
						page += frame_runs.RUN_2M_PAGES
						continue
					}
				}
			}
		}
		// Fallback / normal 4 KiB entries for this PT span.
		run := min(512 - (addr >> 12 & 511), remaining)
		entry, entry_size := page_entry_with_size(process.table, addr)
		if entry != nil && entry_size == .Size_4K {
			run_entries := ([^]u64)(entry)
			for at in 0 ..< run {
				if run_entries[at] & PAGE_PRESENT != 0 {
					continue
				}
				frame := region_frame(region, region_page + at, false)
				if frame == 0 {
					continue
				}
				page_bits_now := page_bits(mapping, region_page_state(region, region_page + at))
				if page_bits_now != 0 {
					run_entries[at] = frame | page_bits_now
					mapping.present_page_count += 1
					mapping.entries_4k += 1
				}
			}
		}
		page += run
	}
	flush_and_park_pts(process, replaced_pts[:replaced_count])
}

// demote_mapping_range splits any 1 GiB or 2 MiB hardware large page
// entries intersecting [first_in_mapping, first_in_mapping + count) of a
// non-Large_Pages mapping down to 4 KiB entries using parked demotion
// tables (zero allocation). Clears SLOT_RUN_* bits on demoted runs in
// region. Caller holds process lock; pass region_locked = true if caller
// already holds region_locks[mapping.region].
demote_mapping_range :: proc "contextless" (process: ^Process, mapping: ^Mapping, region: ^Region, first_in_mapping: u64, count: u64, self: ^Processor, region_locked := false) {
	if mapping.large || (mapping.entries_2m == 0 && mapping.entries_1g == 0) || count == 0 {
		return
	}
	start_addr := mapping.address + first_in_mapping * PAGE_SIZE
	end_addr := start_addr + count * PAGE_SIZE
	flushed := false
	// Step 1: split any intersecting 1 GiB entry into 512 x 2 MiB entries.
	if mapping.entries_1g != 0 {
		addr_1g := start_addr &~ u64(word_table.GIANT_PAGE_SIZE - 1)
		for addr_1g < end_addr {
			if addr_1g >= mapping.address && addr_1g + word_table.GIANT_PAGE_SIZE <= mapping.address + mapping.page_count * PAGE_SIZE {
				if pdpte := page_directory_pointer_entry(process.table, addr_1g); pdpte != nil && pdpte^ & (PAGE_PRESENT | PAGE_LARGE) == (PAGE_PRESENT | PAGE_LARGE) {
					base_phys := pdpte^ & PAGE_ADDRESS &~ u64(word_table.GIANT_PAGE_SIZE - 1)
					leaf_bits := pdpte^ &~ (PAGE_ADDRESS | TABLE_HELD_MASK)
					pd := demotion_table_pop(process)
					pd_entries := direct(pd, [512]u64)
					for k in u64(0) ..< 512 {
						pd_entries[k] = (base_phys + k * LARGE_PAGE_SIZE) | leaf_bits
					}
					intrinsics.atomic_store(pdpte, pd | PAGE_PRESENT | PAGE_WRITE | PAGE_USER | 512 * TABLE_HELD_ONE)
					mapping.entries_1g -= 1
					mapping.entries_2m += 512
					if !region.contiguous {
						if !region_locked {
							lock_take(&region_locks[mapping.region], .Region)
						}
						rpage0 := mapping.first + (addr_1g - mapping.address) / PAGE_SIZE
						s0 := region_slot(region, rpage0)
						intrinsics.atomic_store(s0, intrinsics.atomic_load(s0) &~ SLOT_RUN_1G)
						for sub in u64(0) ..< 512 {
							ss := region_slot(region, rpage0 + sub * frame_runs.RUN_2M_PAGES)
							intrinsics.atomic_store(ss, intrinsics.atomic_load(ss) | SLOT_RUN_2M)
						}
						if !region_locked {
							lock_free(&region_locks[mapping.region], .Region)
						}
					}
					if self.table == process.table {
						page_flush(addr_1g)
					}
					flushed = true
				}
			}
			addr_1g += word_table.GIANT_PAGE_SIZE
		}
	}
	// Step 2: split any intersecting 2 MiB entry into 512 x 4 KiB entries.
	if mapping.entries_2m != 0 {
		addr_2m := start_addr &~ u64(LARGE_PAGE_SIZE - 1)
		for addr_2m < end_addr {
			if addr_2m >= mapping.address && addr_2m + LARGE_PAGE_SIZE <= mapping.address + mapping.page_count * PAGE_SIZE {
				if pde := page_directory_entry(process.table, addr_2m); pde != nil && pde^ & (PAGE_PRESENT | PAGE_LARGE) == (PAGE_PRESENT | PAGE_LARGE) {
					base_phys := pde^ & PAGE_ADDRESS &~ u64(LARGE_PAGE_SIZE - 1)
					leaf_bits := pde^ &~ (PAGE_ADDRESS | TABLE_HELD_MASK | PAGE_LARGE)
					pt := demotion_table_pop(process)
					pt_entries := direct(pt, [512]u64)
					for k in u64(0) ..< 512 {
						pt_entries[k] = (base_phys + k * PAGE_SIZE) | leaf_bits
					}
					intrinsics.atomic_store(pde, pt | PAGE_PRESENT | PAGE_WRITE | PAGE_USER | 512 * TABLE_HELD_ONE)
					mapping.entries_2m -= 1
					mapping.entries_4k += 512
					if !region.contiguous {
						if !region_locked {
							lock_take(&region_locks[mapping.region], .Region)
						}
						rpage0 := mapping.first + (addr_2m - mapping.address) / PAGE_SIZE
						s0 := region_slot(region, rpage0)
						intrinsics.atomic_store(s0, intrinsics.atomic_load(s0) &~ SLOT_RUN_2M)
						if !region_locked {
							lock_free(&region_locks[mapping.region], .Region)
						}
					}
					if self.table == process.table {
						page_flush(addr_2m)
					}
					flushed = true
				}
			}
			addr_2m += LARGE_PAGE_SIZE
		}
	}
	if flushed {
		intrinsics.atomic_thread_fence(.Seq_Cst)
		processor_sync(processors_with_table(process.table))
	}
}

// range_all_frameless reports whether every committed page in [first,
// first + count) currently has no frame (and is committed).
@(private = "file")
range_all_frameless :: proc "contextless" (region: ^Region, first: u64, count: u64) -> bool {
	for page in first ..< first + count {
		val := intrinsics.atomic_load(region_slot(region, page))
		if val & PAGE_ADDRESS != 0 || !page_committed(region, val) {
			return false
		}
	}
	return true
}

// region_prefault_range allocates and zeroes frames for every frameless
// committed page in [first, first + count) of a non-contiguous region,
// taking aligned 1 GiB or 2 MiB runs when available and permitted by quota,
// zeroing outside frame_lock, and counting fallbacks.
//
// For 1 GiB runs, zeroing runs in bounded ZERO_SLICE_BYTES (2 MiB) chunks via
// frame_runs.Zero_Run_Progress with region_lock and frame_lock released and an
// interrupt_window() opened between slices so no kernel section holds
// interrupts off across 1 GiB. Each 2 MiB slice installs its slots as soon as
// it is zeroed, and once all 512 slices complete intact, slot 0 promotes to
// SLOT_RUN_1G.
region_prefault_range :: proc "contextless" (region: ^Region, first: u64, count: u64) {
	if region.contiguous || count == 0 {
		return
	}
	region_index := u32(intrinsics.ptr_sub(region, &regions[0]))
	region_lock := &region_locks[region_index]
	end := first + count
	for offset := first; offset < end; {
		wanted := frame_runs_arch_enabled() ? frame_runs.best_run_for_range(offset, end - offset, frame_runs_table.supports_1g) : .Pages_4K
		if wanted == .Run_1G {
			lock_take(region_lock, .Region)
			if range_all_frameless(region, offset, frame_runs.RUN_1G_PAGES) {
				lock_take(&frame_lock, .Frame)
				b := region.budget
				phys, ok := frames_take_run_1g_held(b, budgets[b].quota_pages)
				if ok {
					reserved_pages -= frame_runs.RUN_1G_PAGES
				} else {
					frame_runs.note_fallback(&frame_runs_table, .Run_1G)
				}
				lock_free(&frame_lock, .Frame)
				if ok {
					progress, init_refusal := frame_runs.zero_run_init(phys, frame_runs.RUN_1G_PAGES * PAGE_SIZE, frame_runs.ZERO_SLICE_BYTES)
					if init_refusal == .None {
						// Clear SLOT_COMMITTED on unzeroed uncommitted slots while
						// region_lock is released between slices so concurrent faults
						// or decommits never double-subtract reserved_pages.
						if region.uncommitted {
							for k in u64(0) ..< frame_runs.RUN_1G_PAGES {
								slot := region_slot(region, offset + k)
								intrinsics.atomic_store(slot, intrinsics.atomic_load(slot) &~ SLOT_COMMITTED)
							}
						}
						lock_free(region_lock, .Region)

						slice_offset := offset
						all_slices_installed := true
						for !frame_runs.zero_run_is_done(&progress) {
							slice_phys, slice_bytes, next_refusal := frame_runs.zero_run_next_slice(&progress)
							if next_refusal != .None {
								break
							}
							slice_pages := slice_bytes / PAGE_SIZE
							frames_zero(slice_phys, slice_pages)

							lock_take(region_lock, .Region)
							slice_clear := true
							for k in u64(0) ..< slice_pages {
								if intrinsics.atomic_load(region_slot(region, slice_offset + k)) & PAGE_ADDRESS != 0 {
									slice_clear = false
									break
								}
							}
							if slice_clear {
								for k in u64(0) ..< slice_pages {
									slot := region_slot(region, slice_offset + k)
									state := intrinsics.atomic_load(slot) & (SLOT_STATE &~ SLOT_RUN_MASK)
									if region.uncommitted {
										state |= SLOT_COMMITTED
									}
									if k == 0 {
										state |= SLOT_RUN_2M
									}
									intrinsics.atomic_store(slot, (slice_phys + k * PAGE_SIZE) | state)
								}
								intrinsics.atomic_add(&region.present, slice_pages)
							} else {
								all_slices_installed = false
								lock_take(&frame_lock, .Frame)
								frames_free_held(slice_phys, slice_pages)
								reserved_pages += slice_pages
								lock_free(&frame_lock, .Frame)
							}
							lock_free(region_lock, .Region)

							_ = frame_runs.zero_run_commit_slice(&progress, slice_bytes)
							slice_offset += slice_pages
							if !frame_runs.zero_run_is_done(&progress) {
								frame_runs.zero_run_note_yield(&progress)
								interrupt_window()
							}
						}

						if all_slices_installed {
							lock_take(region_lock, .Region)
							all_intact := true
							for sub in u64(0) ..< 512 {
								head := intrinsics.atomic_load(region_slot(region, offset + sub * frame_runs.RUN_2M_PAGES))
								if head & PAGE_ADDRESS != phys + sub * frame_runs.ZERO_SLICE_BYTES || head & SLOT_RUN_2M == 0 {
									all_intact = false
									break
								}
							}
							if all_intact {
								for sub in u64(0) ..< 512 {
									slot := region_slot(region, offset + sub * frame_runs.RUN_2M_PAGES)
									val := intrinsics.atomic_load(slot) &~ SLOT_RUN_2M
									if sub == 0 {
										val |= SLOT_RUN_1G
									}
									intrinsics.atomic_store(slot, val)
								}
							}
							lock_free(region_lock, .Region)
						}
						offset += frame_runs.RUN_1G_PAGES
						continue
					}
					lock_take(&frame_lock, .Frame)
					frames_free_held(phys, frame_runs.RUN_1G_PAGES)
					reserved_pages += frame_runs.RUN_1G_PAGES
					frame_runs.note_fallback(&frame_runs_table, .Run_1G)
					lock_free(&frame_lock, .Frame)
				}
			}
			lock_free(region_lock, .Region)
			wanted = .Run_2M
		}
		if wanted == .Run_2M {
			lock_take(region_lock, .Region)
			if range_all_frameless(region, offset, frame_runs.RUN_2M_PAGES) {
				lock_take(&frame_lock, .Frame)
				b := region.budget
				phys, ok := frames_take_run_2m_held(b, budgets[b].quota_pages)
				if ok {
					reserved_pages -= frame_runs.RUN_2M_PAGES
				} else {
					frame_runs.note_fallback(&frame_runs_table, .Run_2M)
				}
				lock_free(&frame_lock, .Frame)
				if ok {
					frames_zero(phys, frame_runs.RUN_2M_PAGES)
					for k in u64(0) ..< frame_runs.RUN_2M_PAGES {
						slot := region_slot(region, offset + k)
						state := intrinsics.atomic_load(slot) & (SLOT_STATE &~ SLOT_RUN_MASK)
						if k == 0 {
							state |= SLOT_RUN_2M
						}
						intrinsics.atomic_store(slot, (phys + k * PAGE_SIZE) | state)
					}
					intrinsics.atomic_add(&region.present, frame_runs.RUN_2M_PAGES)
					lock_free(region_lock, .Region)
					offset += frame_runs.RUN_2M_PAGES
					continue
				}
			}
			lock_free(region_lock, .Region)
		}
		// Single 4 KiB pages up to the next 2 MiB boundary or end of range.
		next_2m := ((offset / frame_runs.RUN_2M_PAGES) + 1) * frame_runs.RUN_2M_PAGES
		step_end := min(end, next_2m)
		for page := offset; page < step_end; page += 1 {
			region_frame(region, page, true)
		}
		offset = step_end
	}
}

// memory_commit commits, or decommits, the pages of the ranges of an
// uncommitted object. It gives the pages that changed.
memory_commit :: proc "contextless" (process: ^Process, region_index: u32, ranges: []op.Page_Range, flags: op.Commit_Flags) -> (changed: u64, status: Operation_Outcome) {
	region := &regions[region_index]
	if !region.uncommitted {
		return 0, .Argument_Refused
	}
	if !ranges_valid(ranges, region.page_count) {
		return 0, .Argument_Refused
	}
	decommit := .Decommit in flags
	frames_now := .Frames_Now in flags
	region_lock := &region_locks[region_index]
	if !decommit {
		lock_take(region_lock, .Region)
		needed: u64
		for range in ranges {
			for page in range.first ..< range.first + range.page_count {
				needed += 1 - intrinsics.atomic_load(region_slot(region, page)) & SLOT_COMMITTED
			}
		}
		lock_take(&frame_lock, .Frame)
		budget := &budgets[region.budget]
		if !budget.live || budget.amounts.pages < needed {
			lock_free(&frame_lock, .Frame)
			lock_free(region_lock, .Region)
			return 0, .Budget_Or_Capacity_Exhausted
		}
		budget_pages_spend(budget, needed)
		reserved_pages += needed
		region.committed += needed
		for range in ranges {
			for page in range.first ..< range.first + range.page_count {
				slot := region_slot(region, page)
				intrinsics.atomic_store(slot, intrinsics.atomic_load(slot) | SLOT_COMMITTED)
			}
		}
		lock_free(&frame_lock, .Frame)
		lock_free(region_lock, .Region)
		if frames_now {
			for range in ranges {
				region_prefault_range(region, range.first, range.page_count)
			}
			// Install entries (4 KiB, 2 MiB, or 1 GiB) into any existing
			// mapping of this region in the calling process so arenas get
			// prefaulted large pages immediately.
			for &mapping in process.mappings {
				if mapping.page_count == 0 || mapping.region != region_index || mapping.large {
					continue
				}
				map_end := mapping.first + mapping.page_count
				for range in ranges {
					r_start := max(range.first, mapping.first)
					r_end := min(range.first + range.page_count, map_end)
					if r_start < r_end {
						mapping_install_present_range(process, &mapping, region, r_start - mapping.first, r_end - r_start)
					}
				}
			}
		}
		return needed, .Succeeded
	}
	mapping, alone := object_only_here(process, region_index)
	if !alone {
		return 0, .Wrong_State
	}
	lock_take(region_lock, .Region)
	defer lock_free(region_lock, .Region)
	self := processor_self()
	for range in ranges {
		if mapping != nil {
			r_start := max(range.first, mapping.first)
			r_end := min(range.first + range.page_count, mapping.first + mapping.page_count)
			if r_start < r_end {
				demote_mapping_range(process, mapping, region, r_start - mapping.first, r_end - r_start, self, region_locked = true)
			}
		}
		for page in range.first ..< range.first + range.page_count {
			if mapping == nil || page < mapping.first || page - mapping.first >= mapping.page_count {
				continue // Not in the mapping: no entry.
			}
			address := mapping.address + (page - mapping.first) * PAGE_SIZE
			if entry := page_entry(process.table, address); entry != nil && entry^ & PAGE_PRESENT != 0 {
				entry^ = 0
				mapping.present_page_count -= 1
				mapping.entries_4k -= 1
				if self.table == process.table {
					page_flush(address)
				}
			}
		}
	}
	intrinsics.atomic_thread_fence(.Seq_Cst)
	processor_sync(processors_with_table(process.table))
	waiters_on_frames_wake(process, region, ranges)
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	cache := &self.frame_cache
	lock_take(&cache.lock, .Cache)
	defer lock_free(&cache.lock, .Cache)
	for range in ranges {
		for page in range.first ..< range.first + range.page_count {
			slot := region_slot(region, page)
			value := intrinsics.atomic_load(slot)
			if value & SLOT_COMMITTED == 0 {
				continue
			}
			if frame := value & PAGE_ADDRESS; frame != 0 {
				frame_release_held(cache, frame)
				region.present -= 1
			} else {
				reserved_pages -= 1
			}
			intrinsics.atomic_store(slot, value & (SLOT_STATE &~ (SLOT_COMMITTED | SLOT_RUN_MASK)))
			changed += 1
		}
	}
	budget_peak.give_back(&budgets[region.budget].amounts.pages, changed)
	region.committed -= changed
	return changed, .Succeeded
}

// waiters_on_frames_wake wakes each thread of a process that has a word
// in a frame of the pages of the ranges of a memory object: a thread that
// waits, or one that registered its words and does not wait yet. A decommit
// and a revocation call it before the frames leave the process. The caller
// holds the process lock of the process, so the words of its threads do
// not grow meanwhile. A thread with more words than this table holds wakes
// anyway: a wake that was not needed is allowed (the thread reads its words
// again).
//
// The cost: the words (at most 256) are sorted once; then the slots of the
// pages are read in order, with one binary search for each slot that has a
// frame, and the walk ends when each word is matched or when it has seen
// each frame of the object (`present`). So an object of 1 GiB with few
// frames is not walked to its end, unless its last page has a frame: then
// one pass over its 262 144 slots, 2 MiB read in order.
WAITING_WORD_CAPACITY :: 256

// One registered word of a thread of a process, by the frame of its page.
@(private = "file")
Waiting_Word :: struct {
	page:   u64, // The frame of the word.
	thread: u32, // 0: woken already.
}

// waiting_words_collect gives the words of the threads of a process,
// sorted by frame. A thread with more words than the table holds is woken
// now. The caller holds the process lock of the process.
@(private = "file")
waiting_words_collect :: proc "contextless" (process: ^Process, words: ^[WAITING_WORD_CAPACITY]Waiting_Word) -> (count: int) {
	// No thread of the process waits: no pass over the thread table. Each
	// unmap of a process that waits on nothing, and each of the unmaps of
	// the end of a process, costs one read here.
	if intrinsics.atomic_load(&process.waited_words) == 0 {
		return 0
	}
	index := index_of_process(process)
	for &thread, slot in threads[1:] {
		if thread.process != index || thread.word_count == 0 {
			continue
		}
		if count + int(thread.word_count) > WAITING_WORD_CAPACITY {
			thread_words_wake(&thread)
			continue
		}
		for n in 0 ..< thread.word_count {
			words[count] = {page = wait_entry(&thread, n).word &~ (PAGE_SIZE - 1), thread = u32(slot + 1)}
			count += 1
		}
	}
	for at in 1 ..< count {
		for back := at; back > 0 && words[back - 1].page > words[back].page; back -= 1 {
			words[back - 1], words[back] = words[back], words[back - 1]
		}
	}
	return count
}

// waiting_words_wake_frame wakes each thread with a word in a frame, once,
// and gives the words that it woke.
@(private = "file")
waiting_words_wake_frame :: proc "contextless" (words: []Waiting_Word, frame: u64) -> (matched: int) {
	low, high := 0, len(words)
	for low < high {
		middle := (low + high) / 2
		if words[middle].page < frame {
			low = middle + 1
		} else {
			high = middle
		}
	}
	for at := low; at < len(words) && words[at].page == frame; at += 1 {
		if words[at].thread != 0 {
			thread_words_wake(&threads[words[at].thread])
			words[at].thread = 0
			matched += 1
		}
	}
	return matched
}

waiters_on_frames_wake :: proc "contextless" (process: ^Process, region: ^Region, ranges: []op.Page_Range) {
	words: [WAITING_WORD_CAPACITY]Waiting_Word
	count := waiting_words_collect(process, &words)
	if count == 0 {
		return
	}
	remaining := count
	frames_seen: u64
	frames := intrinsics.atomic_load(&region.present)
	for range in ranges {
		for page in range.first ..< range.first + range.page_count {
			frame := region.contiguous ? region.physical + page * PAGE_SIZE : intrinsics.atomic_load(region_slot(region, page)) & PAGE_ADDRESS
			if frame == 0 {
				continue
			}
			frames_seen += 1
			remaining -= waiting_words_wake_frame(words[:count], frame)
			if remaining == 0 || !region.contiguous && frames_seen >= frames {
				return
			}
		}
	}
}

// waiters_on_pages_wake wakes each thread of a process that has a word in
// a frame that the page table of the process names for the pages from
// address: the frames of a mapping that ends, or the frames of point copies
// that return to the history. It reads the entries, not the slots of the
// object, so a frame that the process maps in place of the frame of the
// object (a point copy) is matched too. Its caller frees no such frame
// before: a thread that waits names the frame, and the next user of the
// frame would take its wakes and give it theirs. The caller holds the
// process lock of the process. With no word waited in the process it reads
// no entry.
//
// The cost: one walk of the upper levels for each 2 MiB of the range, as
// unmap does; a 2 MiB with no table is passed whole, a large page is one
// entry, and the walk ends when it has seen `present` present pages (the
// present_page_count of the mapping) or matched each word.
waiters_on_pages_wake :: proc "contextless" (process: ^Process, address: u64, page_count: u64, present: u64) {
	words: [WAITING_WORD_CAPACITY]Waiting_Word
	count := waiting_words_collect(process, &words)
	if count == 0 || present == 0 {
		return
	}
	remaining := count
	seen: u64
	for page := u64(0); page < page_count; {
		virtual := address + page * PAGE_SIZE
		run := min(512 - (virtual >> 12 & 511), page_count - page)
		entry, entry_size := page_entry_with_size(process.table, virtual)
		if entry == nil {
			page += run // No table under this 2 MiB: no page of it is present.
			continue
		}
		if entry_size != .Size_4K {
			// One large (2 MiB or 1 GiB) page: walk its 4 KiB frames in this 2 MiB span.
			if base, ok := word_table.word_physical_of_size(entry^, virtual, entry_size); ok {
				for at in 0 ..< run {
					remaining -= waiting_words_wake_frame(words[:count], base + at * PAGE_SIZE)
				}
				seen += run
			}
		} else {
			entries := ([^]u64)(entry)
			for at in 0 ..< run {
				frame, ok := word_table.word_physical_of_size(entries[at], virtual + at * PAGE_SIZE, .Size_4K)
				if !ok {
					continue
				}
				seen += 1
				remaining -= waiting_words_wake_frame(words[:count], frame)
				if remaining == 0 || seen >= present {
					return
				}
			}
		}
		if remaining == 0 || seen >= present {
			return
		}
		page += run
	}
}


// protection_bits gives the bits of the mappings of a protection.
protection_bits :: proc "contextless" (mapping: ^Mapping, flags: op.Map_Flags) -> u64 {
	if .No_Access in flags {
		return 0
	}
	bits := PAGE_PRESENT | PAGE_USER | mapping.limit_bits & PAGE_CACHE_TYPE_BITS
	if .Write in flags {
		bits |= PAGE_WRITE
	}
	if .Execute not_in flags {
		bits |= PAGE_NO_EXECUTE
	}
	return bits
}

// protect_check finds the mapping of each range and checks what the
// protection asks, before any change: a table is done whole or not at all.
// A range covers the pages of one mapping of this process; Write needs a
// mapping made with Write, Execute one made with Execute; a part of a
// mapping needs an object with a frame list named only by this process.
protect_check :: proc "contextless" (process: ^Process, ranges: []op.Address_Range, flags: op.Map_Flags) -> (mappings: [op.RANGE_TABLE_CAPACITY]u16, status: Operation_Outcome) {
	if .Write in flags && .Execute in flags || .No_Access in flags && flags != {.No_Access} {
		return mappings, .Argument_Refused
	}
	for range, index in ranges {
		address, count := range.address, range.page_count
		if address % PAGE_SIZE != 0 || count == 0 || address >= USER_END || count > (USER_END - address) / PAGE_SIZE {
			return mappings, .Argument_Refused
		}
		found, inside := mapping_order.containing(process.mapping_order[:process.mapping_order_count], process.mappings[:], address)
		if !inside || (address - process.mappings[found].address) / PAGE_SIZE + count > process.mappings[found].page_count {
			return mappings, .Argument_Refused
		}
		mapping := &process.mappings[found]
		if mapping.address >= op.THREAD_AREA_BASE {
			return mappings, .Argument_Refused // The thread areas and the time page keep their protection.
		}
		if record_replay_mapping_has_point_copies(index_of_process(process), mapping) {
			return mappings, .Wrong_State // Point-copied shared pages keep their read-only protection while recorded/replayed.
		}
		if .Write in flags && mapping.bits & PAGE_WRITE == 0 && record_replay_write_conflict(index_of_process(process), mapping.region) {
			return mappings, .Wrong_State // A new writer of memory that a recorded process maps would write outside its gate.
		}
		// More than the handle permitted when the process mapped the object.
		if .Write in flags && mapping.limit_bits & PAGE_WRITE == 0 || .Execute in flags && mapping.limit_bits & PAGE_NO_EXECUTE != 0 {
			return mappings, .Argument_Refused
		}
		whole := address == mapping.address && count == mapping.page_count
		// A switching mapping takes Write, Execute or No_Access whole: the
		// switch of a page gives it Write or Execute at each fault of the
		// guest, so a read-only protection or a part would not hold
		// (src/md/features/guest.md, "The switch of a page").
		if mapping_is_switching(mapping) && (!whole || flags == {}) {
			return mappings, .Argument_Refused
		}
		// A part takes away from the protection of its mapping now: it
		// cannot get more than it (a part that asked for more
		// changed nothing and succeeded).
		if !whole && .No_Access not_in flags && (mapping.bits == 0 || .Write in flags && mapping.bits & PAGE_WRITE == 0 || .Execute in flags && mapping.bits & PAGE_NO_EXECUTE != 0) {
			return mappings, .Argument_Refused
		}
		if !whole {
			if regions[mapping.region].contiguous {
				return mappings, .Argument_Refused // Device memory, large pages: the protection is of the whole mapping.
			}
			if _, alone := object_only_here(process, mapping.region); !alone {
				return mappings, .Wrong_State
			}
		}
		mappings[index] = found
	}
	// One table that names one mapping whole and in part: the parts are
	// checked against the protection before the change of the whole:
	// refused.
	for range, index in ranges {
		mapping := &process.mappings[mappings[index]]
		whole := range.address == mapping.address && range.page_count == mapping.page_count
		for other, other_index in ranges {
			if other_index != index && mappings[other_index] == mappings[index] && whole != (other.address == mapping.address && other.page_count == mapping.page_count) {
				return mappings, .Argument_Refused
			}
		}
	}
	return mappings, .Succeeded
}

// protect_entries_change gives the present entries of pages of a mapping
// the protection of their mapping and of their slot. Handles 1 GiB, 2 MiB,
// and 4 KiB entries; demotes before clearing any large entry to No_Access
// so parked demotion tables stay 1-to-1 with present large entries.
protect_entries_change :: proc "contextless" (process: ^Process, mapping: ^Mapping, region: ^Region, first, count: u64, self: ^Processor) {
	if mapping.bits == 0 {
		demote_mapping_range(process, mapping, region, first, count, self)
	}
	seen: u64
	present := mapping.present_page_count
	for page := first; page < first + count && seen < present; {
		address := mapping.address + page * PAGE_SIZE
		if address % word_table.GIANT_PAGE_SIZE == 0 && first + count - page >= frame_runs.RUN_1G_PAGES {
			if pdpte := page_directory_pointer_entry(process.table, address); pdpte != nil && pdpte^ & (PAGE_PRESENT | PAGE_LARGE) == (PAGE_PRESENT | PAGE_LARGE) {
				seen += frame_runs.RUN_1G_PAGES
				pdpte^ = pdpte^ & PAGE_ADDRESS | mapping.bits | PAGE_LARGE
				if self.table == process.table {
					page_flush(address)
				}
				page += frame_runs.RUN_1G_PAGES
				continue
			}
		}
		if address % LARGE_PAGE_SIZE == 0 && first + count - page >= frame_runs.RUN_2M_PAGES {
			if pde := page_directory_entry(process.table, address); pde != nil && pde^ & (PAGE_PRESENT | PAGE_LARGE) == (PAGE_PRESENT | PAGE_LARGE) {
				seen += frame_runs.RUN_2M_PAGES
				pde^ = pde^ & PAGE_ADDRESS | mapping.bits | PAGE_LARGE
				if self.table == process.table {
					page_flush(address)
				}
				page += frame_runs.RUN_2M_PAGES
				continue
			}
		}
		run := min(512 - (address >> 12 & 511), first + count - page)
		if entry, entry_size := page_entry_with_size(process.table, address); entry != nil && entry_size == .Size_4K {
			entries := ([^]u64)(entry)
			for at in 0 ..< run {
				if entries[at] & PAGE_PRESENT == 0 {
					continue
				}
				seen += 1
				bits := page_bits(mapping, region_page_state(region, mapping.first + page + at))
				if bits == 0 {
					entries[at] = 0
					mapping.present_page_count -= 1
					mapping.entries_4k -= 1
				} else {
					entries[at] = entries[at] & PAGE_ADDRESS | bits
				}
				if self.table == process.table {
					page_flush(address + at * PAGE_SIZE)
				}
			}
		}
		page += run
	}
}

// protect_walk_count gives what a protection change of a range costs, for
// the limit of one call: the entries that the kernel changes. A whole
// mapping without No_Access updates its 4 KiB, 2 MiB, and 1 GiB entries in
// place without demoting; No_Access demotes and clears every present 4 KiB
// page. A part counts each of its pages: its marks are written in each slot.
protect_walk_count :: proc "contextless" (mapping: ^Mapping, range: op.Address_Range, flags: op.Map_Flags) -> u64 {
	whole := range.address == mapping.address && range.page_count == mapping.page_count
	switch {
	case mapping.large:
		return range.page_count / op.LARGE_PAGE_PAGES
	case whole && intrinsics.atomic_load(&regions[mapping.region].marked_pages) == 0:
		if .No_Access in flags {
			return mapping.present_page_count
		}
		return mapping.entries_4k + mapping.entries_2m + mapping.entries_1g
	}
	return range.page_count
}

// memory_protect changes the protection of the pages of the ranges, then
// makes each processor that uses the page table of the process forget the
// old translations: one processor_sync for the table.
memory_protect :: proc "contextless" (process: ^Process, ranges: []op.Address_Range, flags: op.Map_Flags) -> (changed: u64, status: Operation_Outcome) {
	places := protect_check(process, ranges, flags) or_return
	walked: u64
	for range, index in ranges {
		walked += protect_walk_count(&process.mappings[places[index]], range, flags)
	}
	if walked > op.RANGE_TABLE_PAGE_LIMIT {
		return 0, .Argument_Refused
	}
	// A whole mapping that gains Write counts as a writer of its object
	// before the check of the recorded mappings, as a new mapping does
	// (map_region): of a writer and a recorded process that maps the object
	// at the same time, one sees the other. The check in protect_check
	// refuses early; this one decides. A refusal takes the counts back.
	gains: [op.RANGE_TABLE_CAPACITY]bool
	gain_count := 0
	for range, index in ranges {
		mapping := &process.mappings[places[index]]
		whole := range.address == mapping.address && range.page_count == mapping.page_count
		if !whole || mapping.bits & PAGE_WRITE != 0 || protection_bits(mapping, flags) & PAGE_WRITE == 0 {
			continue
		}
		// Two ranges of one mapping count it once.
		counted := false
		for earlier in 0 ..< index {
			counted ||= gains[earlier] && places[earlier] == places[index]
		}
		if !counted {
			gains[index] = true
			gain_count += 1
			intrinsics.atomic_add(&regions[mapping.region].writable_mapping_count, 1)
		}
	}
	for gained, index in gains[:len(ranges)] {
		if gained && record_replay_write_conflict(index_of_process(process), process.mappings[places[index]].region) {
			for taken, back in gains[:len(ranges)] {
				if taken {
					intrinsics.atomic_sub(&regions[process.mappings[places[back]].region].writable_mapping_count, 1)
				}
			}
			return 0, .Wrong_State
		}
	}
	// W^X across all mappings of each memory object (modulus:memory_wx):
	// claim every new access under one frame-lock section before modifying any
	// page table entry, and release the old accesses only after processor_sync.
	Wx_Change :: struct {
		region:     u32,
		old_access: memory_wx.Access,
		new_access: memory_wx.Access,
	}
	wx_changes: [op.RANGE_TABLE_CAPACITY]Wx_Change
	wx_change_count := 0
	for range, index in ranges {
		mapping := &process.mappings[places[index]]
		whole := range.address == mapping.address && range.page_count == mapping.page_count
		if !whole {
			continue
		}
		seen_earlier := false
		for earlier in 0 ..< index {
			if places[earlier] == places[index] {
				seen_earlier = true
				break
			}
		}
		if seen_earlier {
			continue
		}
		old_access := memory_wx.access_of_bits(mapping.bits, mapping.limit_bits, PAGE_PRESENT, PAGE_WRITE, PAGE_NO_EXECUTE)
		new_access := memory_wx.access_of_bits(protection_bits(mapping, flags), mapping.limit_bits, PAGE_PRESENT, PAGE_WRITE, PAGE_NO_EXECUTE)
		if new_access != old_access {
			wx_changes[wx_change_count] = {region = mapping.region, old_access = old_access, new_access = new_access}
			wx_change_count += 1
		}
	}
	if wx_change_count > 0 {
		lock_take(&frame_lock, .Frame)
		claimed_all := true
		for i in 0 ..< wx_change_count {
			if !memory_wx.claim(&regions[wx_changes[i].region].wx, wx_changes[i].new_access) {
				for j in 0 ..< i {
					_ = memory_wx.release(&regions[wx_changes[j].region].wx, wx_changes[j].new_access)
				}
				claimed_all = false
				break
			}
		}
		lock_free(&frame_lock, .Frame)
		if !claimed_all {
			for taken, back in gains[:len(ranges)] {
				if taken {
					intrinsics.atomic_sub(&regions[process.mappings[places[back]].region].writable_mapping_count, 1)
				}
			}
			processor_self().operation.memory_wx_conflict = true
			return 0, .Wrong_State
		}
	}
	self := processor_self()
	for range, index in ranges {
		mapping := &process.mappings[places[index]]
		region_index := mapping.region
		region := &regions[region_index]
		first := (range.address - mapping.address) / PAGE_SIZE
		count := range.page_count
		mapping.protected = true
		if first == 0 && count == mapping.page_count {
			wrote := mapping.bits & PAGE_WRITE != 0
			mapping.bits = protection_bits(mapping, flags)
			writes := mapping.bits & PAGE_WRITE != 0
			// A gain of Write was counted above, once for the mapping.
			if writes && !wrote && !gains[index] {
				counted := false
				for earlier in 0 ..< index {
					counted ||= gains[earlier] && places[earlier] == places[index]
				}
				if !counted {
					intrinsics.atomic_add(&region.writable_mapping_count, 1)
				}
			} else if wrote && !writes {
				intrinsics.atomic_sub(&region.writable_mapping_count, 1)
			}
		}
		// The protection of each page of a part, in its slot, as marks that
		// take away from the protection of the mapping now: a part that gets
		// the protection of its mapping has no mark. A whole mapping loses
		// the marks of its pages. While an object has marks it is not mapped
		// again and not given: the marks are of the object, so
		// they would reach another mapping.
		whole := first == 0 && count == mapping.page_count
		if !whole && !mapping.large {
			demote_mapping_range(process, mapping, region, first, count, self)
		}
		if !region.contiguous && (!whole || intrinsics.atomic_load(&region.marked_pages) != 0) {
			marks: u64
			if !whole {
				if .No_Access in flags {
					marks = SLOT_NO_ACCESS
				} else {
					marks |= .Write not_in flags && mapping.bits & PAGE_WRITE != 0 ? SLOT_DENY_WRITE : 0
					marks |= .Execute not_in flags && mapping.bits & PAGE_NO_EXECUTE == 0 ? SLOT_DENY_EXECUTE : 0
				}
			}
			lock := &region_locks[region_index]
			lock_take(lock, .Region)
			for page in mapping.first + first ..< mapping.first + first + count {
				slot := region_slot(region, page)
				value := intrinsics.atomic_load(slot)
				old := value & SLOT_MARKS
				intrinsics.atomic_store(slot, value &~ SLOT_MARKS | marks)
				if old != 0 && marks == 0 {
					intrinsics.atomic_sub(&region.marked_pages, 1)
				} else if old == 0 && marks != 0 {
					intrinsics.atomic_add(&region.marked_pages, 1)
				}
			}
			lock_free(lock, .Region)
		}
		// The entries that exist take the new protection.
		if mapping.large {
			for part in 0 ..< mapping.page_count / op.LARGE_PAGE_PAGES {
				address := mapping.address + part * LARGE_PAGE_SIZE
				entry := page_directory_entry(process.table, address)
				if entry == nil {
					continue
				}
				present := entry^ & PAGE_PRESENT != 0
				frame := region.physical + (mapping.first + part * op.LARGE_PAGE_PAGES) * PAGE_SIZE
				entry^ = mapping.bits == 0 ? 0 : frame | mapping.bits | PAGE_LARGE
				if present && mapping.bits == 0 {
					mapping.present_page_count -= op.LARGE_PAGE_PAGES
					mapping.entries_2m -= 1
				} else if !present && mapping.bits != 0 {
					mapping.present_page_count += op.LARGE_PAGE_PAGES
					mapping.entries_2m += 1
				}
				if self.table == process.table {
					page_flush(address)
				}
			}
			changed += count
			continue
		}
		protect_entries_change(process, mapping, region, first, count, self)
		changed += count
	}
	intrinsics.atomic_thread_fence(.Seq_Cst)
	processor_sync(processors_with_table(process.table))
	if wx_change_count > 0 {
		lock_take(&frame_lock, .Frame)
		for change in wx_changes[:wx_change_count] {
			if !memory_wx.release(&regions[change.region].wx, change.old_access) {
				when TEST_BUILD_CHECKS_LOCK_ORDER {
					log("kernel: a W^X mapping count of a memory object would go below 0")
					machine_stop(.Invariant_Broken)
				}
			}
		}
		lock_free(&frame_lock, .Frame)
	}
	return changed, .Succeeded
}