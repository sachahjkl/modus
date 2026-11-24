// Aligned 2 MiB and 1 GiB page-frame run allocator, per-budget run quota,
// block healing, and counted fallback (src/md/features/frames_of_a_process.md).
//
// Each 2 MiB block tracks how many of its 512 frames are in use (used_in_2m)
// and which budget last took it as a run (owner_2m). Each 1 GiB block tracks
// how many of its 512 2 MiB sub-blocks have at least one frame in use
// (used_2m_in_1g) and which budget took it as a 1 GiB run (owner_1g).
//
// A block is whole and free iff its used count is 0. A partial decommit
// leaves the block non-empty so the owning budget keeps its active run count
// until every frame in the block returns; once the last frame leaves, the
// block heals in O(1), free_runs increments, and the owner's active count
// decrements.
//
// Pure kernel part: no package mutable state, no allocator, no hardware
// instructions. Host tests exercise 4 KiB, 2 MiB, and 1 GiB boundaries,
// quotas, partial-decommit abuse, budget-slot reuse, and 4 GiB maps.
package frame_runs

import "base:intrinsics"

PAGE_SIZE :: u64(4096)
RUN_2M_PAGES :: u64(512)
RUN_1G_PAGES :: u64(512 * 512)
WORDS_PER_2M :: RUN_2M_PAGES / 64
WORDS_PER_1G :: RUN_1G_PAGES / 64

// Size class of a physical run or page table entry.
Run_Size :: enum u8 {
	Pages_4K = 0,
	Run_2M   = 1,
	Run_1G   = 2,
}

// Run tracking tables over a machine's frame bitmap. All slices are supplied
// by the caller (boot-allocated frames in the kernel; test buffers on host).
Table :: struct {
	frame_count:    u64,
	block_2m_count: u64,
	block_1g_count: u64,
	used_in_2m:     []u16, // Length >= block_2m_count; 0..512 used 4 KiB frames per 2 MiB block.
	used_2m_in_1g:  []u16, // Length >= block_1g_count; 0..512 non-empty 2 MiB blocks per 1 GiB block.
	owner_2m:       []u32, // Length >= block_2m_count; budget slot holding this 2 MiB run, or 0.
	owner_1g:       []u32, // Length >= block_1g_count; budget slot holding this 1 GiB run, or 0.
	active_2m:      []u32, // Length == budget_capacity; active 2 MiB runs held by each budget.
	active_1g:      []u32, // Length == budget_capacity; active 1 GiB runs held by each budget.
	free_runs_2m:   u64,   // Whole aligned free 2 MiB blocks right now.
	free_runs_1g:   u64,   // Whole aligned free 1 GiB blocks right now.
	fallback_2m:    u64,   // 2 MiB commit ranges that fell back to 4 KiB frames.
	fallback_1g:    u64,   // 1 GiB commit ranges that fell back to 2 MiB or 4 KiB frames.
	hint_2m:        u64,
	hint_1g:        u64,
	supports_1g:    bool,  // True when processor supports 1 GiB page entries (pdpe1gb).
}

// Sizes of the backing arrays for a machine of frame_count frames and
// budget_capacity budget slots.
Table_Layout :: struct {
	block_2m_count:   u64,
	block_1g_count:   u64,
	budget_capacity:  u64,
	used_2m_offset:   u64,
	used_1g_offset:   u64,
	owner_2m_offset:  u64,
	owner_1g_offset:  u64,
	active_2m_offset: u64,
	active_1g_offset: u64,
	total_bytes:      u64,
}

@(private = "file")
align_up_8 :: #force_inline proc "contextless" (n: u64) -> u64 {
	return (n + 7) &~ u64(7)
}

// layout_of computes aligned byte offsets and total bytes for the run
// tracking slices of a machine.
layout_of :: proc "contextless" (frame_count: u64, budget_capacity: u64) -> (layout: Table_Layout) {
	layout.block_2m_count = frame_count / RUN_2M_PAGES
	layout.block_1g_count = frame_count / RUN_1G_PAGES
	layout.budget_capacity = budget_capacity

	offset: u64 = 0
	layout.used_2m_offset = offset
	offset = align_up_8(offset + layout.block_2m_count * size_of(u16))
	layout.used_1g_offset = offset
	offset = align_up_8(offset + layout.block_1g_count * size_of(u16))
	layout.owner_2m_offset = offset
	offset = align_up_8(offset + layout.block_2m_count * size_of(u32))
	layout.owner_1g_offset = offset
	offset = align_up_8(offset + layout.block_1g_count * size_of(u32))
	layout.active_2m_offset = offset
	offset = align_up_8(offset + budget_capacity * size_of(u32))
	layout.active_1g_offset = offset
	offset = align_up_8(offset + budget_capacity * size_of(u32))
	layout.total_bytes = offset
	return layout
}

// table_bind wires a zeroed byte buffer into the slices of table according
// to layout. Returns false if backing is smaller than layout.total_bytes.
table_bind :: proc "contextless" (table: ^Table, backing: []u8, frame_count: u64, budget_capacity: u64, supports_1g: bool) -> bool {
	layout := layout_of(frame_count, budget_capacity)
	if u64(len(backing)) < layout.total_bytes {
		return false
	}
	base := raw_data(backing)
	table^ = {
		frame_count    = frame_count,
		block_2m_count = layout.block_2m_count,
		block_1g_count = layout.block_1g_count,
		used_in_2m     = ([^]u16)(uintptr(base) + uintptr(layout.used_2m_offset))[:layout.block_2m_count],
		used_2m_in_1g  = ([^]u16)(uintptr(base) + uintptr(layout.used_1g_offset))[:layout.block_1g_count],
		owner_2m       = ([^]u32)(uintptr(base) + uintptr(layout.owner_2m_offset))[:layout.block_2m_count],
		owner_1g       = ([^]u32)(uintptr(base) + uintptr(layout.owner_1g_offset))[:layout.block_1g_count],
		active_2m      = ([^]u32)(uintptr(base) + uintptr(layout.active_2m_offset))[:budget_capacity],
		active_1g      = ([^]u32)(uintptr(base) + uintptr(layout.active_1g_offset))[:budget_capacity],
		supports_1g    = supports_1g,
	}
	return true
}

// table_init scans frame_bits (1 = used, 0 = free) and computes exact
// used_in_2m, used_2m_in_1g, free_runs_2m, and free_runs_1g counts.
table_init :: proc "contextless" (table: ^Table, frame_bits: []u64) {
	table.free_runs_2m = 0
	table.free_runs_1g = 0
	table.hint_2m = 0
	table.hint_1g = 0
	for &v in table.used_2m_in_1g {
		v = 0
	}
	for &v in table.owner_2m {
		v = 0
	}
	for &v in table.owner_1g {
		v = 0
	}
	for &v in table.active_2m {
		v = 0
	}
	for &v in table.active_1g {
		v = 0
	}
	for b2 in u64(0) ..< table.block_2m_count {
		base_word := b2 * WORDS_PER_2M
		used: u16 = 0
		if base_word + WORDS_PER_2M <= u64(len(frame_bits)) {
			for w in u64(0) ..< WORDS_PER_2M {
				used += u16(intrinsics.count_ones(frame_bits[base_word + w]))
			}
		} else {
			used = u16(RUN_2M_PAGES)
		}
		table.used_in_2m[b2] = used
		if used == 0 {
			table.free_runs_2m += 1
		} else if b1 := b2 / 512; b1 < table.block_1g_count {
			table.used_2m_in_1g[b1] += 1
		}
	}
	for b1 in u64(0) ..< table.block_1g_count {
		if table.used_2m_in_1g[b1] == 0 {
			table.free_runs_1g += 1
		}
	}
}

// on_frames_taken updates block counters when frames [first_frame,
// first_frame + count) transition from free (0) to used (1) in frame_bits.
// Safe to call when table has not been initialized (block_2m_count == 0).
on_frames_taken :: proc "contextless" (table: ^Table, first_frame: u64, count: u64) {
	if count == 0 || table.block_2m_count == 0 {
		return
	}
	limit := table.block_2m_count * RUN_2M_PAGES
	if first_frame >= limit {
		return
	}
	end := min(first_frame + count, limit)
	frame := first_frame
	for frame < end {
		b2 := frame / RUN_2M_PAGES
		block_end := (b2 + 1) * RUN_2M_PAGES
		step := min(end, block_end) - frame
		before := table.used_in_2m[b2]
		if before == 0 {
			table.free_runs_2m -= 1
			if b1 := b2 / 512; b1 < table.block_1g_count {
				if table.used_2m_in_1g[b1] == 0 {
					table.free_runs_1g -= 1
				}
				table.used_2m_in_1g[b1] += 1
			}
		}
		table.used_in_2m[b2] = before + u16(step)
		frame += step
	}
}

// on_frames_freed updates block counters when frames [first_frame,
// first_frame + count) transition from used (1) to free (0) in frame_bits.
// When a 2 MiB or 1 GiB block reaches 0 used frames, it heals and releases
// its owner's active run count.
on_frames_freed :: proc "contextless" (table: ^Table, first_frame: u64, count: u64) {
	if count == 0 || table.block_2m_count == 0 {
		return
	}
	limit := table.block_2m_count * RUN_2M_PAGES
	if first_frame >= limit {
		return
	}
	end := min(first_frame + count, limit)
	frame := first_frame
	for frame < end {
		b2 := frame / RUN_2M_PAGES
		block_end := (b2 + 1) * RUN_2M_PAGES
		step := min(end, block_end) - frame
		before := table.used_in_2m[b2]
		after := before > u16(step) ? before - u16(step) : 0
		table.used_in_2m[b2] = after
		if before != 0 && after == 0 {
			table.free_runs_2m += 1
			if owner := table.owner_2m[b2]; owner != 0 {
				if u64(owner) < u64(len(table.active_2m)) && table.active_2m[owner] != 0 {
					table.active_2m[owner] -= 1
				}
				table.owner_2m[b2] = 0
			}
			if b1 := b2 / 512; b1 < table.block_1g_count {
				if table.used_2m_in_1g[b1] != 0 {
					table.used_2m_in_1g[b1] -= 1
				}
				if table.used_2m_in_1g[b1] == 0 {
					table.free_runs_1g += 1
					if owner1 := table.owner_1g[b1]; owner1 != 0 {
						if u64(owner1) < u64(len(table.active_1g)) && table.active_1g[owner1] != 0 {
							table.active_1g[owner1] -= 1
						}
						table.owner_1g[b1] = 0
					}
				}
			}
		}
		frame += step
	}
}

// is_run_frame reports whether frame belongs to a block currently owned as
// a 2 MiB or 1 GiB run. Returning such a frame directly to frame_bits
// (bypassing per-CPU caches) lets its block heal when its last page leaves.
is_run_frame :: proc "contextless" (table: ^Table, frame: u64) -> bool {
	if table.block_2m_count == 0 {
		return false
	}
	b2 := frame / RUN_2M_PAGES
	if b2 >= table.block_2m_count {
		return false
	}
	if table.owner_2m[b2] != 0 {
		return true
	}
	if b1 := b2 / 512; b1 < table.block_1g_count && table.owner_1g[b1] != 0 {
		return true
	}
	return false
}

// quota_allows_2m says whether budget (whose total capacity is
// budget_total_pages) may take another 2 MiB run.
quota_allows_2m :: proc "contextless" (table: ^Table, budget: u32, budget_total_pages: u64) -> bool {
	if budget == 0 || u64(budget) >= u64(len(table.active_2m)) {
		return false
	}
	return u64(table.active_2m[budget]) < budget_total_pages / RUN_2M_PAGES
}

// quota_allows_1g says whether budget (whose total capacity is
// budget_total_pages) may take another 1 GiB run.
quota_allows_1g :: proc "contextless" (table: ^Table, budget: u32, budget_total_pages: u64) -> bool {
	if !table.supports_1g || budget == 0 || u64(budget) >= u64(len(table.active_1g)) {
		return false
	}
	return u64(table.active_1g[budget]) < budget_total_pages / RUN_1G_PAGES
}

// take_run_1g allocates one aligned 1 GiB run from frame_bits for budget if
// pdpe1gb is supported, quota permits, and a free 1 GiB block exists.
// Returns the physical address of the first frame (non-zero) and true on
// success; returns 0 and false without modifying frame_bits otherwise.
take_run_1g :: proc "contextless" (table: ^Table, frame_bits: []u64, budget: u32, budget_total_pages: u64) -> (physical: u64, ok: bool) {
	if table.free_runs_1g == 0 || !quota_allows_1g(table, budget, budget_total_pages) {
		return 0, false
	}
	for step in u64(0) ..< table.block_1g_count {
		b1 := (table.hint_1g + step) % table.block_1g_count
		if table.used_2m_in_1g[b1] != 0 {
			continue
		}
		base_word := b1 * WORDS_PER_1G
		if base_word + WORDS_PER_1G > u64(len(frame_bits)) {
			continue
		}
		for w in u64(0) ..< WORDS_PER_1G {
			frame_bits[base_word + w] = max(u64)
		}
		base_2m := b1 * 512
		for sub in u64(0) ..< 512 {
			table.used_in_2m[base_2m + sub] = u16(RUN_2M_PAGES)
		}
		table.used_2m_in_1g[b1] = 512
		table.free_runs_2m -= 512
		table.free_runs_1g -= 1
		table.owner_1g[b1] = budget
		table.active_1g[budget] += 1
		table.hint_1g = (b1 + 1) % table.block_1g_count
		return b1 * RUN_1G_PAGES * PAGE_SIZE, true
	}
	return 0, false
}

// take_run_2m allocates one aligned 2 MiB run from frame_bits for budget if
// quota permits and a free 2 MiB block exists. When supports_1g is true and
// free 1 GiB blocks exist, pass 0 prefers a free 2 MiB block inside an
// already-split 1 GiB block so intact 1 GiB runs stay whole.
take_run_2m :: proc "contextless" (table: ^Table, frame_bits: []u64, budget: u32, budget_total_pages: u64) -> (physical: u64, ok: bool) {
	if table.free_runs_2m == 0 || !quota_allows_2m(table, budget, budget_total_pages) {
		return 0, false
	}
	prefer_split := table.supports_1g && table.free_runs_1g != 0
	passes := prefer_split ? 2 : 1
	for pass in 0 ..< passes {
		for step in u64(0) ..< table.block_2m_count {
			b2 := (table.hint_2m + step) % table.block_2m_count
			if table.used_in_2m[b2] != 0 {
				continue
			}
			if pass == 0 && prefer_split {
				if b1 := b2 / 512; b1 < table.block_1g_count && table.used_2m_in_1g[b1] == 0 {
					continue
				}
			}
			base_word := b2 * WORDS_PER_2M
			if base_word + WORDS_PER_2M > u64(len(frame_bits)) {
				continue
			}
			for w in u64(0) ..< WORDS_PER_2M {
				frame_bits[base_word + w] = max(u64)
			}
			table.used_in_2m[b2] = u16(RUN_2M_PAGES)
			table.free_runs_2m -= 1
			if b1 := b2 / 512; b1 < table.block_1g_count {
				if table.used_2m_in_1g[b1] == 0 {
					table.free_runs_1g -= 1
				}
				table.used_2m_in_1g[b1] += 1
			}
			table.owner_2m[b2] = budget
			table.active_2m[budget] += 1
			table.hint_2m = (b2 + 1) % table.block_2m_count
			return b2 * RUN_2M_PAGES * PAGE_SIZE, true
		}
	}
	return 0, false
}

// note_fallback records that a commit range eligible for wanted fell back to
// a smaller page size.
note_fallback :: proc "contextless" (table: ^Table, wanted: Run_Size) {
	switch wanted {
	case .Pages_4K:
	case .Run_2M:
		table.fallback_2m += 1
	case .Run_1G:
		table.fallback_1g += 1
	}
}

// on_budget_ended clears ownership records of a budget that is closing so
// slot reuse never inherits stale active counts or causes underflow.
on_budget_ended :: proc "contextless" (table: ^Table, budget: u32) {
	if budget == 0 {
		return
	}
	if u64(budget) < u64(len(table.active_2m)) && table.active_2m[budget] != 0 {
		for &owner in table.owner_2m {
			if owner == budget {
				owner = 0
			}
		}
		table.active_2m[budget] = 0
	}
	if u64(budget) < u64(len(table.active_1g)) && table.active_1g[budget] != 0 {
		for &owner in table.owner_1g {
			if owner == budget {
				owner = 0
			}
		}
		table.active_1g[budget] = 0
	}
}

// best_run_for_range returns the largest run size that fits at page offset
// `offset` with `remaining` pages left in the range.
best_run_for_range :: proc "contextless" (offset: u64, remaining: u64, supports_1g: bool) -> Run_Size {
	if supports_1g && offset % RUN_1G_PAGES == 0 && remaining >= RUN_1G_PAGES {
		return .Run_1G
	}
	if offset % RUN_2M_PAGES == 0 && remaining >= RUN_2M_PAGES {
		return .Run_2M
	}
	return .Pages_4K
}
