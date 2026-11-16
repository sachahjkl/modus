package modustool

// The edge counters and the traced comparisons of the instrumented child
// (src/md/infrastructure/fuzzing.md, "Edge counters from the LLVM of the
// build"). The pass `sancov-module` of `opt` adds to each instrumented
// package one byte for each edge, which the code adds one to, a table of
// the addresses of the edges, and a call before each comparison. These
// procedures are the calls that the pass names. In a build with no pass
// nothing calls them: the counters are then empty, and the engine runs
// with no guide.

// The most separate ranges of counters: the link merges the counters of
// every package into one section, so each package gives the same range.
FUZZ_COUNTER_RANGE_CAPACITY :: 16

// The comparisons of one execution that the engine keeps, the last ones
// when an execution makes more.
FUZZ_COMPARE_CAPACITY :: 1024

Fuzz_Counter_Range :: struct {
	start: [^]u8,
	count: int,
}

// One traced comparison: its two values and their size in bytes.
Fuzz_Compare :: struct {
	first:  u64,
	second: u64,
	size:   u8,
}

fuzz_counter_ranges: [FUZZ_COUNTER_RANGE_CAPACITY]Fuzz_Counter_Range
fuzz_counter_range_count: int
fuzz_edge_addresses: int // The entries of the tables of the addresses: one for each edge.

// Only the execution of the code under test records comparisons: the code
// of the engine between two executions is not instrumented, and the flag
// keeps a traced call of the dictionary or of the corpus out too.
fuzz_compare_tracing: bool
fuzz_compares: [FUZZ_COMPARE_CAPACITY]Fuzz_Compare
fuzz_compare_count: int

@(export, link_name = "__sanitizer_cov_8bit_counters_init")
fuzz_counters_init :: proc "c" (start, end: [^]u8) {
	count := int(uintptr(end) - uintptr(start))
	if count <= 0 {
		return
	}
	for item in fuzz_counter_ranges[:fuzz_counter_range_count] {
		if item.start == start {
			return
		}
	}
	if fuzz_counter_range_count < FUZZ_COUNTER_RANGE_CAPACITY {
		fuzz_counter_ranges[fuzz_counter_range_count] = {start = start, count = count}
		fuzz_counter_range_count += 1
	}
}

@(export, link_name = "__sanitizer_cov_pcs_init")
fuzz_edge_addresses_init :: proc "c" (start, end: [^]uintptr) {
	// Each edge has two words: its address and its flags.
	count := int((uintptr(end) - uintptr(start)) / (2 * size_of(uintptr)))
	if fuzz_edge_addresses == 0 {
		fuzz_edge_addresses = count
	}
}

fuzz_compare_record :: #force_inline proc "contextless" (first, second: u64, size: u8) {
	if !fuzz_compare_tracing || first == second {
		return
	}
	fuzz_compares[fuzz_compare_count % FUZZ_COMPARE_CAPACITY] = {first = first, second = second, size = size}
	fuzz_compare_count += 1
}

@(export, link_name = "__sanitizer_cov_trace_cmp1")
fuzz_trace_compare_1 :: proc "c" (first, second: u8) {fuzz_compare_record(u64(first), u64(second), 1)}
@(export, link_name = "__sanitizer_cov_trace_cmp2")
fuzz_trace_compare_2 :: proc "c" (first, second: u16) {fuzz_compare_record(u64(first), u64(second), 2)}
@(export, link_name = "__sanitizer_cov_trace_cmp4")
fuzz_trace_compare_4 :: proc "c" (first, second: u32) {fuzz_compare_record(u64(first), u64(second), 4)}
@(export, link_name = "__sanitizer_cov_trace_cmp8")
fuzz_trace_compare_8 :: proc "c" (first, second: u64) {fuzz_compare_record(first, second, 8)}
@(export, link_name = "__sanitizer_cov_trace_const_cmp1")
fuzz_trace_constant_compare_1 :: proc "c" (first, second: u8) {fuzz_compare_record(u64(first), u64(second), 1)}
@(export, link_name = "__sanitizer_cov_trace_const_cmp2")
fuzz_trace_constant_compare_2 :: proc "c" (first, second: u16) {fuzz_compare_record(u64(first), u64(second), 2)}
@(export, link_name = "__sanitizer_cov_trace_const_cmp4")
fuzz_trace_constant_compare_4 :: proc "c" (first, second: u32) {fuzz_compare_record(u64(first), u64(second), 4)}
@(export, link_name = "__sanitizer_cov_trace_const_cmp8")
fuzz_trace_constant_compare_8 :: proc "c" (first, second: u64) {fuzz_compare_record(first, second, 8)}

// A switch: cases[0] is the count of the cases, cases[1] the size of the
// value in bits, then the value of each case.
@(export, link_name = "__sanitizer_cov_trace_switch")
fuzz_trace_switch :: proc "c" (value: u64, cases: [^]u64) {
	count := min(int(cases[0]), 64)
	size := u8(cases[1] / 8)
	for index in 0 ..< count {
		fuzz_compare_record(value, cases[2 + index], size)
	}
}

// The pass declares the call of an indirect call; this build does not ask
// for it, and a link that names it finds it.
@(export, link_name = "__sanitizer_cov_trace_pc_indir")
fuzz_trace_indirect_call :: proc "c" (callee: u64) {}

// fuzz_counter_count gives the counters of the binary: 0 when it was not
// instrumented.
fuzz_counter_count :: proc() -> (count: int) {
	for item in fuzz_counter_ranges[:fuzz_counter_range_count] {
		count += item.count
	}
	return count
}

// fuzz_counters_clear sets each counter to zero before an execution, and
// forgets the comparisons of the execution before.
fuzz_counters_clear :: proc() {
	for item in fuzz_counter_ranges[:fuzz_counter_range_count] {
		for index in 0 ..< item.count {
			item.start[index] = 0
		}
	}
	fuzz_compare_count = 0
}

// fuzz_counter_at gives the counter of an edge, by its number over all the
// ranges.
fuzz_counter_at :: proc(number: int) -> u8 {
	rest := number
	for item in fuzz_counter_ranges[:fuzz_counter_range_count] {
		if rest < item.count {
			return item.start[rest]
		}
		rest -= item.count
	}
	return 0
}

// The class of a count, as AFL counts them: 1, 2, 3, 4 to 7, 8 to 15, 16
// to 31, 32 to 127, 128 and more. 0: the edge did not run.
fuzz_count_class :: proc(count: u8) -> int {
	switch count {
	case 0:
		return 0
	case 1:
		return 1
	case 2:
		return 2
	case 3:
		return 3
	case 4 ..= 7:
		return 4
	case 8 ..= 15:
		return 5
	case 16 ..= 31:
		return 6
	case 32 ..= 127:
		return 7
	}
	return 8
}

FUZZ_COUNT_CLASSES :: 8 // The classes of a count that ran, from 1.
