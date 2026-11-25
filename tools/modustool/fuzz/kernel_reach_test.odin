// Host unit tests for counted-kernel reached-procedure coverage reporting
// (kernel_reach.odin).
package fuzz

import "core:strings"
import "core:testing"

@(test)
kernel_reach_refuses_malformed_and_out_of_range_listings :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Invalid edge totals and empty listings are refused.
	_, ref := kernel_procedure_listing_parse("a 0 1\n", 0, context.temp_allocator)
	testing.expect_value(t, ref, Kernel_Reach_Refusal.Edge_Out_Of_Range)
	_, ref = kernel_procedure_listing_parse("a 0 1\n", KERNEL_EDGES_MOST + 1, context.temp_allocator)
	testing.expect_value(t, ref, Kernel_Reach_Refusal.Edge_Out_Of_Range)
	_, ref = kernel_procedure_listing_parse("# comment only\n\n", 16, context.temp_allocator)
	testing.expect_value(t, ref, Kernel_Reach_Refusal.Empty_Listing)

	// Malformed lines, zero edge counts, out-of-range spans, and duplicate names are refused.
	_, ref = kernel_procedure_listing_parse("bad_line_only_two 0\n", 16, context.temp_allocator)
	testing.expect_value(t, ref, Kernel_Reach_Refusal.Malformed_Line)
	_, ref = kernel_procedure_listing_parse("proc_a nope 2\n", 16, context.temp_allocator)
	testing.expect_value(t, ref, Kernel_Reach_Refusal.Malformed_Line)
	_, ref = kernel_procedure_listing_parse("proc_a 0 0\n", 16, context.temp_allocator)
	testing.expect_value(t, ref, Kernel_Reach_Refusal.Zero_Edge_Count)
	_, ref = kernel_procedure_listing_parse("proc_a -1 2\n", 16, context.temp_allocator)
	testing.expect_value(t, ref, Kernel_Reach_Refusal.Edge_Out_Of_Range)
	_, ref = kernel_procedure_listing_parse("proc_a 14 4\n", 16, context.temp_allocator)
	testing.expect_value(t, ref, Kernel_Reach_Refusal.Edge_Out_Of_Range)
	_, ref = kernel_procedure_listing_parse("proc_a 0 2\nproc_a 2 2\n", 16, context.temp_allocator)
	testing.expect_value(t, ref, Kernel_Reach_Refusal.Duplicate_Procedure)

	// Report builder refuses empty inputs and short hitsets.
	_, ref = kernel_reach_report_build(nil, make([]u8, 8, context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, ref, Kernel_Reach_Refusal.Empty_Listing)
	one := [1]Kernel_Procedure_Span{{name = "p", first_edge = 0, edge_count = 4}}
	_, ref = kernel_reach_report_build(one[:], nil, context.temp_allocator)
	testing.expect_value(t, ref, Kernel_Reach_Refusal.Edge_Out_Of_Range)
	_, ref = kernel_reach_report_build(one[:], make([]u8, 3, context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, ref, Kernel_Reach_Refusal.Edge_Out_Of_Range)
}

@(test)
kernel_reach_produces_sorted_coverage_report :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	listing := "# counted kernel procedure spans\nschedule 8 4\nmemory_map 0 4\nwait_wake 4 4\n"
	spans, parse_ref := kernel_procedure_listing_parse(listing, 12, context.temp_allocator)
	testing.expect_value(t, parse_ref, Kernel_Reach_Refusal.None)
	testing.expect_value(t, len(spans), 3)

	// Mark 2 edges in memory_map (0, 2) and 1 edge in wait_wake (5); leave schedule unreached.
	hits: [12]u8
	hits[0] = 3
	hits[2] = 1
	hits[5] = 7

	report, rep_ref := kernel_reach_report_build(spans, hits[:], context.temp_allocator)
	testing.expect_value(t, rep_ref, Kernel_Reach_Refusal.None)
	testing.expect_value(t, report.total_procedures, 3)
	testing.expect_value(t, report.reached_procedures, 2)
	testing.expect_value(t, report.unreached_procedures, 1)
	testing.expect_value(t, report.total_edges, 12)
	testing.expect_value(t, report.hit_edges, 3)

	// Reached procedures come first alphabetically, then unreached alphabetically.
	testing.expect_value(t, report.procedures[0].name, "memory_map")
	testing.expect_value(t, report.procedures[0].hit_edges, 2)
	testing.expect_value(t, report.procedures[1].name, "wait_wake")
	testing.expect_value(t, report.procedures[1].hit_edges, 1)
	testing.expect_value(t, report.procedures[2].name, "schedule")
	testing.expect_value(t, report.procedures[2].hit_edges, 0)
	testing.expect(t, !report.procedures[2].reached, "schedule is reported as unreached")

	text := kernel_reach_report_format(report, context.temp_allocator)
	testing.expect(t, strings.contains(text, "kernel procedures reached: 2 / 3"), "report header shows procedure ratio")
	testing.expect(t, strings.contains(text, "reached   memory_map (2/4 edges)"), "report lists reached memory_map")
	testing.expect(t, strings.contains(text, "unreached schedule (0/4 edges)"), "report lists unreached schedule")
}
