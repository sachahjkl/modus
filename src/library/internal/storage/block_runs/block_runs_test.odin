#+build !freestanding
package block_runs

import "core:testing"

@(test)
coalesce_empty_and_single_edges :: proc(t: ^testing.T) {
	out: [8]Run
	// 0 requests.
	testing.expect_value(t, coalesce_block_runs(nil, 64, out[:]), 0)
	testing.expect_value(t, coalesce_block_runs([]Request{}, 64, out[:]), 0)
	// Empty output buffer.
	one := [1]Request{{number = 10, slot = 0}}
	testing.expect_value(t, coalesce_block_runs(one[:], 64, nil), 0)
	// 1 request.
	testing.expect_value(t, coalesce_block_runs(one[:], 64, out[:]), 1)
	testing.expect_value(t, out[0], Run{first_block = 10, count = 1, first_slot = 0})
	// max_blocks_per_request == 0 clamps to 1 (never loops or drops).
	two := [2]Request{{number = 10, slot = 0}, {number = 11, slot = 1}}
	testing.expect_value(t, coalesce_block_runs(two[:], 0, out[:]), 2)
	testing.expect_value(t, out[0], Run{first_block = 10, count = 1, first_slot = 0})
	testing.expect_value(t, out[1], Run{first_block = 11, count = 1, first_slot = 1})
}

@(test)
coalesce_contiguous_and_non_contiguous_cases :: proc(t: ^testing.T) {
	out: [16]Run

	// Contiguous disk + contiguous slot -> 1 run.
	both := [4]Request{
		{number = 100, slot = 2},
		{number = 101, slot = 3},
		{number = 102, slot = 4},
		{number = 103, slot = 5},
	}
	testing.expect_value(t, coalesce_block_runs(both[:], 64, out[:]), 1)
	testing.expect_value(t, out[0], Run{first_block = 100, count = 4, first_slot = 2})

	// Contiguous disk + non-contiguous slot -> MUST NOT coalesce.
	slot_gap := [3]Request{
		{number = 100, slot = 0},
		{number = 101, slot = 2},
		{number = 102, slot = 3},
	}
	testing.expect_value(t, coalesce_block_runs(slot_gap[:], 64, out[:]), 2)
	testing.expect_value(t, out[0], Run{first_block = 100, count = 1, first_slot = 0})
	testing.expect_value(t, out[1], Run{first_block = 101, count = 2, first_slot = 2})

	// Non-contiguous disk + contiguous slot -> MUST NOT coalesce.
	disk_gap := [3]Request{
		{number = 100, slot = 0},
		{number = 102, slot = 1},
		{number = 103, slot = 2},
	}
	testing.expect_value(t, coalesce_block_runs(disk_gap[:], 64, out[:]), 2)
	testing.expect_value(t, out[0], Run{first_block = 100, count = 1, first_slot = 0})
	testing.expect_value(t, out[1], Run{first_block = 102, count = 2, first_slot = 1})

	// Descending disk blocks and duplicate disk blocks -> MUST NOT coalesce.
	desc_dup := [4]Request{
		{number = 50, slot = 0},
		{number = 49, slot = 1},
		{number = 49, slot = 2},
		{number = 50, slot = 2},
	}
	testing.expect_value(t, coalesce_block_runs(desc_dup[:], 64, out[:]), 4)
}

@(test)
coalesce_splits_at_max_blocks_per_request :: proc(t: ^testing.T) {
	reqs: [13]Request
	for i in 0 ..< len(reqs) {
		reqs[i] = {number = u64(200 + i), slot = u64(i)}
	}
	out: [16]Run

	// Exact bound (4), one past bound (5), and multi-chunk split (13 with limit 4 -> 4 + 4 + 4 + 1).
	testing.expect_value(t, coalesce_block_runs(reqs[:4], 4, out[:]), 1)
	testing.expect_value(t, out[0], Run{first_block = 200, count = 4, first_slot = 0})

	testing.expect_value(t, coalesce_block_runs(reqs[:5], 4, out[:]), 2)
	testing.expect_value(t, out[0], Run{first_block = 200, count = 4, first_slot = 0})
	testing.expect_value(t, out[1], Run{first_block = 204, count = 1, first_slot = 4})

	n := coalesce_block_runs(reqs[:], 4, out[:])
	testing.expect_value(t, n, 4)
	testing.expect_value(t, out[0], Run{first_block = 200, count = 4, first_slot = 0})
	testing.expect_value(t, out[1], Run{first_block = 204, count = 4, first_slot = 4})
	testing.expect_value(t, out[2], Run{first_block = 208, count = 4, first_slot = 8})
	testing.expect_value(t, out[3], Run{first_block = 212, count = 1, first_slot = 12})

	// Output buffer smaller than required run count truncates safely without OOB.
	small_out: [2]Run
	testing.expect_value(t, coalesce_block_runs(reqs[:], 4, small_out[:]), 2)
	testing.expect_value(t, small_out[0], Run{first_block = 200, count = 4, first_slot = 0})
	testing.expect_value(t, small_out[1], Run{first_block = 204, count = 4, first_slot = 4})
}

@(test)
coalesce_guards_u64_overflow :: proc(t: ^testing.T) {
	out: [8]Run

	// Disk block wraps past max(u64) to 0 -> MUST NOT coalesce across wrap.
	block_wrap := [3]Request{
		{number = max(u64) - 1, slot = 0},
		{number = max(u64), slot = 1},
		{number = 0, slot = 2},
	}
	n := coalesce_block_runs(block_wrap[:], 64, out[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, out[0], Run{first_block = max(u64) - 1, count = 2, first_slot = 0})
	testing.expect_value(t, out[1], Run{first_block = 0, count = 1, first_slot = 2})

	// Slot wraps past max(u64) to 0 -> MUST NOT coalesce across wrap.
	slot_wrap := [3]Request{
		{number = 10, slot = max(u64) - 1},
		{number = 11, slot = max(u64)},
		{number = 12, slot = 0},
	}
	n = coalesce_block_runs(slot_wrap[:], 64, out[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, out[0], Run{first_block = 10, count = 2, first_slot = max(u64) - 1})
	testing.expect_value(t, out[1], Run{first_block = 12, count = 1, first_slot = 0})
}

@(test)
sort_u64_ascending_edges_and_coalesce_improvement :: proc(t: ^testing.T) {
	empty: [0]u64
	sort_u64_ascending(empty[:])

	one := [1]u64{42}
	sort_u64_ascending(one[:])
	testing.expect_value(t, one[0], u64(42))

	scrambled := [8]u64{13, 10, 15, 11, 12, 14, max(u64), 0}
	sort_u64_ascending(scrambled[:])
	expected := [8]u64{0, 10, 11, 12, 13, 14, 15, max(u64)}
	testing.expect_value(t, scrambled, expected)

	// Reversed contiguous sequence coalesces from 6 runs down to 1 after sorting.
	nums := [6]u64{105, 104, 103, 102, 101, 100}
	sort_u64_ascending(nums[:])
	reqs: [6]Request
	for num, idx in nums {
		reqs[idx] = {number = num, slot = u64(idx)}
	}
	out: [6]Run
	testing.expect_value(t, coalesce_block_runs(reqs[:], 64, out[:]), 1)
	testing.expect_value(t, out[0], Run{first_block = 100, count = 6, first_slot = 0})
}
