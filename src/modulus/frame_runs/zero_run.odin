// Bounded resumable zeroing state machine for 1 GiB (and multi-slice) frame
// runs (src/md/features/frames_of_a_process.md).
//
// Splits a large physical run into fixed-size zeroing slices (up to
// ZERO_SLICE_BYTES = 2 MiB, 512 slices for 1 GiB) so the kernel zeroes one
// bounded chunk at a time and opens an interrupt window between slices instead
// of holding interrupts off across 1 GiB.
//
// Pure kernel part: no package mutable state, no allocator, and no hardware
// instructions.
package frame_runs

import "modus:contract/enum_word"

// Format property: one 2 MiB page-directory entry (512 pages of 4 KiB).
// Zeroing a 1 GiB run in 2 MiB slices takes 512 bounded steps and keeps each
// kernel zeroing section at the same latency bound as a single 2 MiB run.
ZERO_SLICE_BYTES :: RUN_2M_PAGES * PAGE_SIZE
ZERO_SLICE_PAGES :: RUN_2M_PAGES

// Closed set of refusals returned by the bounded resumable zeroing state
// machine. Explicit values allow clean border validation.
Zero_Run_Refusal :: enum u8 {
	None              = 0,
	Zero_Length       = 1,
	Unaligned_Address = 2,
	Unaligned_Length  = 3,
	Bad_Slice_Size    = 4,
	Address_Overflow  = 5,
	Already_Done      = 6,
	Bad_Commit_Size   = 7,
}

// Resumable progress state for zeroing a physical run in bounded slices.
Zero_Run_Progress :: struct {
	base_physical:   u64,
	total_bytes:     u64,
	slice_bytes:     u64,
	zeroed_bytes:    u64,
	slices_done:     u32,
	slices_total:    u32,
	interrupts_seen: u32,
	active:          bool,
}

// zero_run_refusal_of_word converts a raw word into Zero_Run_Refusal at a
// border, refusing any word that does not name a member.
zero_run_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Zero_Run_Refusal, ok: bool) {
	return enum_word.member_of_word(Zero_Run_Refusal, word)
}

// zero_run_init validates base_physical, total_bytes, and slice_bytes and
// prepares a resumable zeroing state. Refuses zero length, zero or unaligned
// addresses/lengths, zero/unaligned/oversized slice_bytes, u64 wraparound, or
// slice counts exceeding max(u32) without mutating caller state.
zero_run_init :: proc "contextless" (
	base_physical: u64,
	total_bytes: u64,
	slice_bytes: u64 = ZERO_SLICE_BYTES,
) -> (progress: Zero_Run_Progress, refusal: Zero_Run_Refusal) {
	if total_bytes == 0 {
		return {}, .Zero_Length
	}
	if base_physical == 0 || base_physical % PAGE_SIZE != 0 {
		return {}, .Unaligned_Address
	}
	if total_bytes % PAGE_SIZE != 0 {
		return {}, .Unaligned_Length
	}
	if slice_bytes == 0 || slice_bytes % PAGE_SIZE != 0 || slice_bytes > ZERO_SLICE_BYTES {
		return {}, .Bad_Slice_Size
	}
	if base_physical > max(u64) - total_bytes {
		return {}, .Address_Overflow
	}
	quotient := total_bytes / slice_bytes
	remainder := total_bytes % slice_bytes
	total_slices := quotient + (remainder != 0 ? u64(1) : u64(0))
	if total_slices == 0 || total_slices > u64(max(u32)) {
		return {}, .Bad_Slice_Size
	}
	return Zero_Run_Progress {
		base_physical   = base_physical,
		total_bytes     = total_bytes,
		slice_bytes     = slice_bytes,
		zeroed_bytes    = 0,
		slices_done     = 0,
		slices_total    = u32(total_slices),
		interrupts_seen = 0,
		active          = true,
	}, .None
}

// zero_run_is_done reports whether progress has completed or is inactive.
zero_run_is_done :: proc "contextless" (progress: ^Zero_Run_Progress) -> bool {
	if progress == nil || !progress.active {
		return true
	}
	return progress.zeroed_bytes >= progress.total_bytes
}

// zero_run_remaining_bytes returns the unzeroed byte count remaining in progress.
zero_run_remaining_bytes :: proc "contextless" (progress: ^Zero_Run_Progress) -> u64 {
	if progress == nil || !progress.active || progress.zeroed_bytes >= progress.total_bytes {
		return 0
	}
	return progress.total_bytes - progress.zeroed_bytes
}

// zero_run_next_slice returns the physical address and byte count of the next
// bounded slice to zero without advancing progress. Calling zero_run_next_slice
// again after an interruption before commit returns the exact same slice.
zero_run_next_slice :: proc "contextless" (progress: ^Zero_Run_Progress) -> (slice_physical: u64, slice_bytes: u64, refusal: Zero_Run_Refusal) {
	if progress == nil || !progress.active || progress.zeroed_bytes >= progress.total_bytes {
		return 0, 0, .Already_Done
	}
	remaining := progress.total_bytes - progress.zeroed_bytes
	chunk := min(remaining, progress.slice_bytes)
	return progress.base_physical + progress.zeroed_bytes, chunk, .None
}

// zero_run_commit_slice advances progress after the caller zeroes the current
// slice. Refuses any bytes_zeroed that does not match the active slice length
// without modifying progress.
zero_run_commit_slice :: proc "contextless" (progress: ^Zero_Run_Progress, bytes_zeroed: u64) -> Zero_Run_Refusal {
	if progress == nil || !progress.active || progress.zeroed_bytes >= progress.total_bytes {
		return .Already_Done
	}
	remaining := progress.total_bytes - progress.zeroed_bytes
	expected := min(remaining, progress.slice_bytes)
	if bytes_zeroed == 0 || bytes_zeroed != expected {
		return .Bad_Commit_Size
	}
	progress.zeroed_bytes += bytes_zeroed
	progress.slices_done += 1
	if progress.zeroed_bytes >= progress.total_bytes {
		progress.active = false
	}
	return .None
}

// zero_run_note_yield records an interrupt window or scheduler yield taken
// between zeroing slices.
zero_run_note_yield :: proc "contextless" (progress: ^Zero_Run_Progress) {
	if progress != nil && progress.active {
		progress.interrupts_seen += 1
	}
}

// zero_run_abort_remaining ends an in-progress zeroing run early (for example
// when a process stops) and returns the unzeroed physical tail so the caller
// can free those frames back to the frame table.
zero_run_abort_remaining :: proc "contextless" (progress: ^Zero_Run_Progress) -> (unzeroed_physical: u64, unzeroed_pages: u64) {
	if progress == nil || !progress.active || progress.zeroed_bytes >= progress.total_bytes {
		return 0, 0
	}
	remaining := progress.total_bytes - progress.zeroed_bytes
	tail_addr := progress.base_physical + progress.zeroed_bytes
	progress.active = false
	return tail_addr, remaining / PAGE_SIZE
}
