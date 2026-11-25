#+build !freestanding
package frame_runs

import "core:testing"

@(test)
zero_run_refuses_bad_alignment_overflow_and_bounds :: proc(t: ^testing.T) {
	// Enum border check.
	ref, ok := zero_run_refusal_of_word(u64(Zero_Run_Refusal.Bad_Commit_Size))
	testing.expect(t, ok)
	testing.expect_value(t, ref, Zero_Run_Refusal.Bad_Commit_Size)
	_, bad_high := zero_run_refusal_of_word(u64(Zero_Run_Refusal.Bad_Commit_Size) + 1)
	testing.expect(t, !bad_high)
	_, bad_max := zero_run_refusal_of_word(max(u64))
	testing.expect(t, !bad_max)

	// Zero length refused.
	p, r := zero_run_init(PAGE_SIZE, 0)
	testing.expect_value(t, r, Zero_Run_Refusal.Zero_Length)
	testing.expect(t, zero_run_is_done(&p))

	// Zero or unaligned address refused.
	_, r = zero_run_init(0, PAGE_SIZE)
	testing.expect_value(t, r, Zero_Run_Refusal.Unaligned_Address)
	_, r = zero_run_init(PAGE_SIZE + 1, PAGE_SIZE)
	testing.expect_value(t, r, Zero_Run_Refusal.Unaligned_Address)
	_, r = zero_run_init(PAGE_SIZE + PAGE_SIZE - 1, PAGE_SIZE)
	testing.expect_value(t, r, Zero_Run_Refusal.Unaligned_Address)

	// Unaligned length refused.
	_, r = zero_run_init(PAGE_SIZE, 1)
	testing.expect_value(t, r, Zero_Run_Refusal.Unaligned_Length)
	_, r = zero_run_init(PAGE_SIZE, PAGE_SIZE + 1)
	testing.expect_value(t, r, Zero_Run_Refusal.Unaligned_Length)

	// Bad slice size (0, unaligned, above ZERO_SLICE_BYTES) refused.
	_, r = zero_run_init(PAGE_SIZE, PAGE_SIZE, 0)
	testing.expect_value(t, r, Zero_Run_Refusal.Bad_Slice_Size)
	_, r = zero_run_init(PAGE_SIZE, PAGE_SIZE, PAGE_SIZE + 1)
	testing.expect_value(t, r, Zero_Run_Refusal.Bad_Slice_Size)
	_, r = zero_run_init(PAGE_SIZE, PAGE_SIZE, ZERO_SLICE_BYTES + PAGE_SIZE)
	testing.expect_value(t, r, Zero_Run_Refusal.Bad_Slice_Size)

	// Address overflow refused.
	top_aligned := max(u64) &~ (PAGE_SIZE - 1)
	_, r = zero_run_init(top_aligned, PAGE_SIZE)
	testing.expect_value(t, r, Zero_Run_Refusal.Address_Overflow)
	_, r = zero_run_init(top_aligned - PAGE_SIZE, 2 * PAGE_SIZE)
	testing.expect_value(t, r, Zero_Run_Refusal.Address_Overflow)

	// Nil progress refusals.
	testing.expect(t, zero_run_is_done(nil))
	testing.expect_value(t, zero_run_remaining_bytes(nil), u64(0))
	_, _, r = zero_run_next_slice(nil)
	testing.expect_value(t, r, Zero_Run_Refusal.Already_Done)
	testing.expect_value(t, zero_run_commit_slice(nil, PAGE_SIZE), Zero_Run_Refusal.Already_Done)
}

@(test)
zero_run_one_page_and_slice_boundaries :: proc(t: ^testing.T) {
	// Single 4 KiB page completes in 1 slice.
	p, r := zero_run_init(0x20_0000, PAGE_SIZE)
	testing.expect_value(t, r, Zero_Run_Refusal.None)
	testing.expect_value(t, p.slices_total, u32(1))
	testing.expect_value(t, zero_run_remaining_bytes(&p), PAGE_SIZE)

	addr, sz, nr := zero_run_next_slice(&p)
	testing.expect_value(t, nr, Zero_Run_Refusal.None)
	testing.expect_value(t, addr, u64(0x20_0000))
	testing.expect_value(t, sz, PAGE_SIZE)

	// Wrong commit sizes (0, wrong size) leave progress unchanged.
	testing.expect_value(t, zero_run_commit_slice(&p, 0), Zero_Run_Refusal.Bad_Commit_Size)
	testing.expect_value(t, zero_run_commit_slice(&p, PAGE_SIZE * 2), Zero_Run_Refusal.Bad_Commit_Size)
	testing.expect_value(t, p.zeroed_bytes, u64(0))
	testing.expect_value(t, p.slices_done, u32(0))
	testing.expect(t, !zero_run_is_done(&p))

	testing.expect_value(t, zero_run_commit_slice(&p, PAGE_SIZE), Zero_Run_Refusal.None)
	testing.expect(t, zero_run_is_done(&p))
	testing.expect_value(t, p.slices_done, u32(1))
	testing.expect_value(t, zero_run_remaining_bytes(&p), u64(0))

	// Post-completion calls refuse cleanly.
	_, _, nr = zero_run_next_slice(&p)
	testing.expect_value(t, nr, Zero_Run_Refusal.Already_Done)
	testing.expect_value(t, zero_run_commit_slice(&p, PAGE_SIZE), Zero_Run_Refusal.Already_Done)

	// Non-multiple of slice_bytes (ZERO_SLICE_BYTES + 1 page -> 2 slices).
	p2, r2 := zero_run_init(0x40_0000, ZERO_SLICE_BYTES + PAGE_SIZE)
	testing.expect_value(t, r2, Zero_Run_Refusal.None)
	testing.expect_value(t, p2.slices_total, u32(2))

	a1, s1, nr1 := zero_run_next_slice(&p2)
	testing.expect_value(t, nr1, Zero_Run_Refusal.None)
	testing.expect_value(t, a1, u64(0x40_0000))
	testing.expect_value(t, s1, ZERO_SLICE_BYTES)
	testing.expect_value(t, zero_run_commit_slice(&p2, s1), Zero_Run_Refusal.None)

	a2, s2, nr2 := zero_run_next_slice(&p2)
	testing.expect_value(t, nr2, Zero_Run_Refusal.None)
	testing.expect_value(t, a2, u64(0x40_0000) + ZERO_SLICE_BYTES)
	testing.expect_value(t, s2, PAGE_SIZE)
	testing.expect_value(t, zero_run_commit_slice(&p2, s2), Zero_Run_Refusal.None)
	testing.expect(t, zero_run_is_done(&p2))
}

@(test)
zero_run_one_gib_512_slices_resume_and_abort :: proc(t: ^testing.T) {
	run_1g_bytes := RUN_1G_PAGES * PAGE_SIZE
	base := u64(0x4000_0000) // 1 GiB aligned.
	p, r := zero_run_init(base, run_1g_bytes, ZERO_SLICE_BYTES)
	testing.expect_value(t, r, Zero_Run_Refusal.None)
	testing.expect_value(t, p.slices_total, u32(512))

	// Run 512 bounded slices with yields between every pair of slices.
	expected_addr := base
	for step in u32(0) ..< 512 {
		addr, sz, nr := zero_run_next_slice(&p)
		testing.expect_value(t, nr, Zero_Run_Refusal.None)
		testing.expect_value(t, addr, expected_addr)
		testing.expect_value(t, sz, ZERO_SLICE_BYTES)

		// Simulate an interruption before commit midway through the run: re-querying
		// must yield the exact same slice so resume is idempotent.
		if step == 17 {
			zero_run_note_yield(&p)
			addr_again, sz_again, nr_again := zero_run_next_slice(&p)
			testing.expect_value(t, nr_again, Zero_Run_Refusal.None)
			testing.expect_value(t, addr_again, addr)
			testing.expect_value(t, sz_again, sz)
		}

		testing.expect_value(t, zero_run_commit_slice(&p, sz), Zero_Run_Refusal.None)
		expected_addr += ZERO_SLICE_BYTES
		if !zero_run_is_done(&p) {
			zero_run_note_yield(&p)
		}
	}

	testing.expect(t, zero_run_is_done(&p))
	testing.expect_value(t, p.slices_done, u32(512))
	testing.expect_value(t, p.zeroed_bytes, run_1g_bytes)
	testing.expect_value(t, p.interrupts_seen, u32(512)) // 511 between slices + 1 mid-step 17.

	// Abort mid-run returns the exact unzeroed tail for frame reclamation.
	p_abort, r_abort := zero_run_init(base, run_1g_bytes, ZERO_SLICE_BYTES)
	testing.expect_value(t, r_abort, Zero_Run_Refusal.None)
	for _ in 0 ..< 10 {
		_, sz, _ := zero_run_next_slice(&p_abort)
		testing.expect_value(t, zero_run_commit_slice(&p_abort, sz), Zero_Run_Refusal.None)
	}
	tail_addr, tail_pages := zero_run_abort_remaining(&p_abort)
	testing.expect(t, zero_run_is_done(&p_abort))
	testing.expect_value(t, tail_addr, base + 10 * ZERO_SLICE_BYTES)
	testing.expect_value(t, tail_pages, RUN_1G_PAGES - 10 * ZERO_SLICE_PAGES)

	// Calling abort again on an already aborted run returns (0, 0).
	tail_addr2, tail_pages2 := zero_run_abort_remaining(&p_abort)
	testing.expect_value(t, tail_addr2, u64(0))
	testing.expect_value(t, tail_pages2, u64(0))
}
