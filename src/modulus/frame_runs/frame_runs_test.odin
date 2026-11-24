#+build !freestanding
package frame_runs

import "core:testing"

@(private = "file")
make_machine :: proc(frame_count: u64, budget_capacity: u64, supports_1g: bool) -> (table: Table, bits: []u64, backing: []u8) {
	words := (frame_count + 63) / 64
	bits = make([]u64, words, context.temp_allocator)
	layout := layout_of(frame_count, budget_capacity)
	backing = make([]u8, layout.total_bytes, context.temp_allocator)
	ok := table_bind(&table, backing, frame_count, budget_capacity, supports_1g)
	assert(ok)
	table_init(&table, bits)
	return table, bits, backing
}

@(private = "file")
bitmap_set_range :: proc(bits: []u64, first: u64, count: u64) {
	for f in first ..< first + count {
		bits[f / 64] |= u64(1) << (f % 64)
	}
}

@(private = "file")
bitmap_clear_range :: proc(bits: []u64, first: u64, count: u64) {
	for f in first ..< first + count {
		bits[f / 64] &~= u64(1) << (f % 64)
	}
}

// Edges and refusals first: backing too small, budget 0 / out of range,
// budget too small for run quota, 0/511/512/513 boundary checks, and
// pdpe1gb disabled.
@(test)
edges_and_refusals :: proc(t: ^testing.T) {
	// Undersized backing refused; 0-frame machine binds cleanly with 0 blocks.
	small_table: Table
	layout := layout_of(RUN_2M_PAGES * 4, 8)
	short_buf := make([]u8, layout.total_bytes - 1, context.temp_allocator)
	testing.expect(t, !table_bind(&small_table, short_buf, RUN_2M_PAGES * 4, 8, true))
	zero_table: Table
	zero_layout := layout_of(0, 4)
	zero_buf := make([]u8, zero_layout.total_bytes, context.temp_allocator)
	testing.expect(t, table_bind(&zero_table, zero_buf, 0, 4, true))
	table_init(&zero_table, nil)
	testing.expect(t, zero_table.block_2m_count == 0 && zero_table.block_1g_count == 0 && zero_table.free_runs_2m == 0 && zero_table.free_runs_1g == 0)

	// best_run_for_range at 0, 1, 511, 512, 513, 1G-1, 1G, misaligned, supports_1g false/true.
	testing.expect_value(t, best_run_for_range(0, 0, true), Run_Size.Pages_4K)
	testing.expect_value(t, best_run_for_range(0, 1, true), Run_Size.Pages_4K)
	testing.expect_value(t, best_run_for_range(0, RUN_2M_PAGES - 1, true), Run_Size.Pages_4K)
	testing.expect_value(t, best_run_for_range(0, RUN_2M_PAGES, true), Run_Size.Run_2M)
	testing.expect_value(t, best_run_for_range(0, RUN_2M_PAGES + 1, true), Run_Size.Run_2M)
	testing.expect_value(t, best_run_for_range(1, RUN_2M_PAGES, true), Run_Size.Pages_4K)
	testing.expect_value(t, best_run_for_range(RUN_2M_PAGES - 1, RUN_2M_PAGES, true), Run_Size.Pages_4K)
	testing.expect_value(t, best_run_for_range(0, RUN_1G_PAGES - 1, true), Run_Size.Run_2M)
	testing.expect_value(t, best_run_for_range(0, RUN_1G_PAGES, true), Run_Size.Run_1G)
	testing.expect_value(t, best_run_for_range(0, RUN_1G_PAGES, false), Run_Size.Run_2M)
	testing.expect_value(t, best_run_for_range(RUN_2M_PAGES, RUN_1G_PAGES, true), Run_Size.Run_2M)
	testing.expect_value(t, best_run_for_range(1, RUN_1G_PAGES, true), Run_Size.Pages_4K)

	table, bits, _ := make_machine(RUN_2M_PAGES * 4, 8, false)
	testing.expect_value(t, table.free_runs_2m, u64(4))
	// Budget 0 and out-of-range budgets are refused without touching bitmap (2M and 1G).
	_, ok0 := take_run_2m(&table, bits, 0, RUN_2M_PAGES * 4)
	testing.expect(t, !ok0 && table.free_runs_2m == 4)
	_, ok_oob := take_run_2m(&table, bits, 8, RUN_2M_PAGES * 4)
	testing.expect(t, !ok_oob && table.free_runs_2m == 4)
	_, ok1g_0 := take_run_1g(&table, bits, 0, RUN_1G_PAGES)
	testing.expect(t, !ok1g_0)
	_, ok1g_oob := take_run_1g(&table, bits, 8, RUN_1G_PAGES)
	testing.expect(t, !ok1g_oob)
	testing.expect(t, !quota_allows_2m(&table, 0, RUN_2M_PAGES))
	testing.expect(t, !quota_allows_2m(&table, 8, RUN_2M_PAGES))
	testing.expect(t, !quota_allows_1g(&table, 1, RUN_1G_PAGES)) // supports_1g is false.
	// Budget smaller than 512 pages gets quota 0 and is refused.
	_, ok_small := take_run_2m(&table, bits, 1, RUN_2M_PAGES - 1)
	testing.expect(t, !ok_small && table.free_runs_2m == 4)
	// Budget of 512 pages gets 1 run, second attempt is refused by quota.
	phys, ok1 := take_run_2m(&table, bits, 1, RUN_2M_PAGES)
	testing.expect(t, ok1 && phys % (RUN_2M_PAGES * PAGE_SIZE) == 0 && table.free_runs_2m == 3)
	_, ok2 := take_run_2m(&table, bits, 1, RUN_2M_PAGES)
	testing.expect(t, !ok2 && table.free_runs_2m == 3)
}

// Partial-decommit attack and block healing: freeing 511 of 512 pages keeps
// the budget's run quota consumed so it cannot fragment other 2 MiB blocks;
// freeing the final page heals the block and restores quota. Also tests
// budget-slot reuse when another process holds a frame inside the broken
// block (zero underflow).
@(test)
partial_decommit_quota_healing_and_budget_reuse :: proc(t: ^testing.T) {
	table, bits, _ := make_machine(RUN_2M_PAGES * 4, 8, false)
	phys, ok := take_run_2m(&table, bits, 1, RUN_2M_PAGES)
	testing.expect(t, ok)
	first := phys / PAGE_SIZE
	testing.expect(t, is_run_frame(&table, first))
	testing.expect(t, table.active_2m[1] == 1 && table.free_runs_2m == 3)

	// Free 511 of 512 pages: block does NOT heal, quota STILL 1.
	bitmap_clear_range(bits, first + 1, RUN_2M_PAGES - 1)
	on_frames_freed(&table, first + 1, RUN_2M_PAGES - 1)
	testing.expect(t, table.free_runs_2m == 3 && table.active_2m[1] == 1)
	_, attack := take_run_2m(&table, bits, 1, RUN_2M_PAGES)
	testing.expect(t, !attack)

	// Another process takes 1 page inside budget 1's broken block; budget 1
	// frees its last page and ends; slot 1 is reused; other process frees
	// its page -> block heals with no underflow on active_2m[1]!
	bitmap_set_range(bits, first + 1, 1)
	on_frames_taken(&table, first + 1, 1)
	bitmap_clear_range(bits, first, 1)
	on_frames_freed(&table, first, 1)
	testing.expect(t, table.used_in_2m[first / RUN_2M_PAGES] == 1 && table.active_2m[1] == 1)

	on_budget_ended(&table, 1)
	testing.expect(t, table.active_2m[1] == 0 && table.owner_2m[first / RUN_2M_PAGES] == 0)

	// Now other process frees its frame -> block heals to 4 free runs, active_2m[1] stays 0.
	bitmap_clear_range(bits, first + 1, 1)
	on_frames_freed(&table, first + 1, 1)
	testing.expect(t, table.free_runs_2m == 4 && table.active_2m[1] == 0)
}

// Simulated 4 GiB machine map (1,048,576 pages = 2048 x 2 MiB = 4 x 1 GiB):
// tests 1 GiB allocation, preferring split 1 GiB blocks for 2 MiB runs,
// fragmentation fallback counting, and full 1 GiB healing.
@(test)
simulated_4gib_machine_runs_and_fallback :: proc(t: ^testing.T) {
	four_gib_pages := 4 * RUN_1G_PAGES // 1,048,576 frames = 4 GiB
	table, bits, _ := make_machine(four_gib_pages, 16, true)
	testing.expect_value(t, table.free_runs_1g, u64(4))
	testing.expect_value(t, table.free_runs_2m, u64(2048))

	// Fragment block 0 (low 1 MiB reserved, like x86-64 boot memory map).
	bitmap_set_range(bits, 0, 256)
	on_frames_taken(&table, 0, 256)
	testing.expect_value(t, table.free_runs_1g, u64(3))
	testing.expect_value(t, table.free_runs_2m, u64(2047))

	// A 2 MiB allocation prefers the already-split 1 GiB block 0, keeping
	// all 3 intact 1 GiB blocks untouched!
	p2m, ok2m := take_run_2m(&table, bits, 2, RUN_2M_PAGES * 4)
	testing.expect(t, ok2m && p2m < RUN_1G_PAGES * PAGE_SIZE)
	testing.expect_value(t, table.free_runs_1g, u64(3))
	testing.expect_value(t, table.free_runs_2m, u64(2046))

	// Budget 3 takes 3 x 1 GiB runs (quota = 3 GiB).
	p1g_a, ok_a := take_run_1g(&table, bits, 3, 3 * RUN_1G_PAGES)
	p1g_b, ok_b := take_run_1g(&table, bits, 3, 3 * RUN_1G_PAGES)
	p1g_c, ok_c := take_run_1g(&table, bits, 3, 3 * RUN_1G_PAGES)
	testing.expect(t, ok_a && ok_b && ok_c)
	testing.expect(t, p1g_a % (RUN_1G_PAGES * PAGE_SIZE) == 0)
	testing.expect(t, p1g_b % (RUN_1G_PAGES * PAGE_SIZE) == 0)
	testing.expect(t, p1g_c % (RUN_1G_PAGES * PAGE_SIZE) == 0)
	testing.expect_value(t, table.free_runs_1g, u64(0))
	testing.expect_value(t, table.active_1g[3], u32(3))

	// Fourth 1 GiB attempt has no free 1 GiB run -> fails and counts fallback.
	_, ok_d := take_run_1g(&table, bits, 4, RUN_1G_PAGES)
	testing.expect(t, !ok_d)
	note_fallback(&table, .Run_1G)
	note_fallback(&table, .Run_2M)
	testing.expect_value(t, table.fallback_1g, u64(1))
	testing.expect_value(t, table.fallback_2m, u64(1))

	// Free all frames of p1g_a -> 1 GiB block heals!
	first_a := p1g_a / PAGE_SIZE
	bitmap_clear_range(bits, first_a, RUN_1G_PAGES)
	on_frames_freed(&table, first_a, RUN_1G_PAGES)
	testing.expect_value(t, table.free_runs_1g, u64(1))
	testing.expect_value(t, table.active_1g[3], u32(2))
}
