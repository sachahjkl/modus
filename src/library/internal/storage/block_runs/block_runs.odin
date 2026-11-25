// Contiguous extent coalescing and block-number sorting for storage transfers.
//
// The block service accepts multi-block Read and Write requests up to its
// reported REQUEST_BLOCKS_LIMIT when both disk block numbers and data-region
// slots are contiguous (src/md/features/storage_coalesce_and_group_commit.md).
// This package is freestanding and allocates no memory.
package block_runs

// Request names one block transfer between disk block `number` and data-region
// slot `slot`.
Request :: struct {
	number: u64,
	slot:   u64,
}

// Run is a coalesced contiguous transfer of `count` blocks starting at disk
// block `first_block` and data-region slot `first_slot`.
Run :: struct {
	first_block: u64,
	count:       u64,
	first_slot:  u64,
}

// coalesce_block_runs merges adjacent requests whose disk block numbers and
// data-region slots both advance by 1, splitting any run at
// max_blocks_per_request (clamped to at least 1). Writes at most len(out) runs
// and returns the count written.
coalesce_block_runs :: proc "contextless" (requests: []Request, max_blocks_per_request: u64, out: []Run) -> int {
	if len(requests) == 0 || len(out) == 0 {
		return 0
	}
	limit := max(max_blocks_per_request, 1)
	count := 0
	current := Run {
		first_block = requests[0].number,
		count       = 1,
		first_slot  = requests[0].slot,
	}
	for index in 1 ..< len(requests) {
		req := requests[index]
		can_extend :=
			current.count < limit &&
			current.first_block <= max(u64) - current.count &&
			req.number == current.first_block + current.count &&
			current.first_slot <= max(u64) - current.count &&
			req.slot == current.first_slot + current.count
		if can_extend {
			current.count += 1
			continue
		}
		out[count] = current
		count += 1
		if count >= len(out) {
			return count
		}
		current = Run {
			first_block = req.number,
			count       = 1,
			first_slot  = req.slot,
		}
	}
	out[count] = current
	return count + 1
}

// sort_u64_ascending sorts numbers in ascending order in place using iterative
// heapsort: O(N log N) worst-case time, O(1) stack space, zero allocation.
sort_u64_ascending :: proc "contextless" (numbers: []u64) {
	n := len(numbers)
	if n < 2 {
		return
	}
	sift_down :: proc "contextless" (a: []u64, start, end: int) {
		root := start
		for {
			child := 2 * root + 1
			if child >= end {
				return
			}
			swap := root
			if a[swap] < a[child] {
				swap = child
			}
			if child + 1 < end && a[swap] < a[child + 1] {
				swap = child + 1
			}
			if swap == root {
				return
			}
			a[root], a[swap] = a[swap], a[root]
			root = swap
		}
	}
	for start := (n - 2) / 2; start >= 0; start -= 1 {
		sift_down(numbers, start, n)
	}
	for end := n - 1; end > 0; end -= 1 {
		numbers[0], numbers[end] = numbers[end], numbers[0]
		sift_down(numbers, 0, end)
	}
}
