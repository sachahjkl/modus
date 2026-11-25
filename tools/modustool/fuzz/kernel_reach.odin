// Counted-kernel reached-procedure coverage parser and deterministic report
// builder for `fuzz operations` (src/md/infrastructure/kernel_fuzzing.md).
package fuzz

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

// Closed border refusal set for counted-kernel procedure listing parsing and
// reachability reporting.
Kernel_Reach_Refusal :: enum u8 {
	None,
	Empty_Listing,
	Malformed_Line,
	Edge_Out_Of_Range,
	Empty_Procedure_Name,
	Duplicate_Procedure,
	Zero_Edge_Count,
}

// One kernel procedure's contiguous guard range in the counted-kernel listing.
Kernel_Procedure_Span :: struct {
	name:       string,
	first_edge: int,
	edge_count: int,
}

// Computed coverage summary for one kernel procedure.
Kernel_Procedure_Coverage :: struct {
	name:        string,
	total_edges: int,
	hit_edges:   int,
	reached:     bool,
}

// Whole deterministic reached vs unreached procedure coverage report.
Kernel_Reach_Report :: struct {
	total_procedures:     int,
	reached_procedures:   int,
	unreached_procedures: int,
	total_edges:          int,
	hit_edges:            int,
	procedures:           []Kernel_Procedure_Coverage,
}

// kernel_procedure_listing_parse parses a counted-kernel procedure listing
// (`<procedure_name> <first_edge> <edge_count>` per non-empty, non-comment
// line) and validates every span against total_kernel_edges.
kernel_procedure_listing_parse :: proc(text: string, total_kernel_edges: int, allocator := context.allocator) -> (spans: []Kernel_Procedure_Span, refusal: Kernel_Reach_Refusal) {
	if total_kernel_edges < 1 || total_kernel_edges > KERNEL_EDGES_MOST {
		return nil, .Edge_Out_Of_Range
	}
	list := make([dynamic]Kernel_Procedure_Span, allocator)
	defer if refusal != .None {
		for item in list {
			delete(item.name, allocator)
		}
		delete(list)
	}

	seen := make(map[string]bool, allocator = context.temp_allocator)
	rest := text
	for raw_line in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw_line)
		if len(line) == 0 || strings.has_prefix(line, "#") {
			continue
		}
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) != 3 {
			return nil, .Malformed_Line
		}
		name := fields[0]
		if len(name) == 0 {
			return nil, .Empty_Procedure_Name
		}
		if name in seen {
			return nil, .Duplicate_Procedure
		}
		first_edge, first_ok := strconv.parse_int(fields[1], 10)
		edge_count, count_ok := strconv.parse_int(fields[2], 10)
		if !first_ok || !count_ok {
			return nil, .Malformed_Line
		}
		if edge_count <= 0 {
			return nil, .Zero_Edge_Count
		}
		if first_edge < 0 || first_edge > total_kernel_edges || edge_count > total_kernel_edges - first_edge {
			return nil, .Edge_Out_Of_Range
		}
		cloned := strings.clone(name, allocator)
		seen[name] = true
		append(&list, Kernel_Procedure_Span{name = cloned, first_edge = first_edge, edge_count = edge_count})
	}

	if len(list) == 0 {
		return nil, .Empty_Listing
	}
	return list[:], .None
}

// kernel_procedure_spans_free frees memory allocated by kernel_procedure_listing_parse.
kernel_procedure_spans_free :: proc(spans: []Kernel_Procedure_Span, allocator := context.allocator) {
	for item in spans {
		delete(item.name, allocator)
	}
	delete(spans, allocator)
}

// kernel_reach_report_build intersects counted-kernel procedure spans with a
// corpus edge-hit array (non-zero byte = edge reached) and returns a
// deterministically sorted report (reached procedures sorted by name, followed
// by unreached procedures sorted by name).
kernel_reach_report_build :: proc(spans: []Kernel_Procedure_Span, edge_hits: []u8, allocator := context.allocator) -> (report: Kernel_Reach_Report, refusal: Kernel_Reach_Refusal) {
	if len(spans) == 0 {
		return {}, .Empty_Listing
	}
	if len(edge_hits) == 0 || len(edge_hits) > KERNEL_EDGES_MOST {
		return {}, .Edge_Out_Of_Range
	}
	procs := make([]Kernel_Procedure_Coverage, len(spans), allocator)
	defer if refusal != .None {
		delete(procs, allocator)
	}

	for span, idx in spans {
		if len(span.name) == 0 {
			return {}, .Empty_Procedure_Name
		}
		if span.edge_count <= 0 {
			return {}, .Zero_Edge_Count
		}
		if span.first_edge < 0 || span.first_edge > len(edge_hits) || span.edge_count > len(edge_hits) - span.first_edge {
			return {}, .Edge_Out_Of_Range
		}
		hits := 0
		for edge in span.first_edge ..< span.first_edge + span.edge_count {
			if edge_hits[edge] != 0 {
				hits += 1
			}
		}
		reached := hits > 0
		procs[idx] = {
			name        = span.name,
			total_edges = span.edge_count,
			hit_edges   = hits,
			reached     = reached,
		}
		report.total_procedures += 1
		report.total_edges += span.edge_count
		report.hit_edges += hits
		if reached {
			report.reached_procedures += 1
		} else {
			report.unreached_procedures += 1
		}
	}

	slice.sort_by(procs, proc(a, b: Kernel_Procedure_Coverage) -> bool {
		if a.reached != b.reached {
			return a.reached
		}
		return a.name < b.name
	})
	report.procedures = procs
	return report, .None
}

// kernel_reach_report_format renders a deterministic plain-text coverage
// summary listing reached and unreached kernel procedures with edge ratios.
kernel_reach_report_format :: proc(report: Kernel_Reach_Report, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	proc_pct := report.total_procedures > 0 ? f64(report.reached_procedures) * 100.0 / f64(report.total_procedures) : 0.0
	edge_pct := report.total_edges > 0 ? f64(report.hit_edges) * 100.0 / f64(report.total_edges) : 0.0
	fmt.sbprintfln(&b, "kernel procedures reached: %d / %d (%.1f%%), edges: %d / %d (%.1f%%)", report.reached_procedures, report.total_procedures, proc_pct, report.hit_edges, report.total_edges, edge_pct)
	for item in report.procedures {
		tag := item.reached ? "reached" : "unreached"
		fmt.sbprintfln(&b, "  %-9s %s (%d/%d edges)", tag, item.name, item.hit_edges, item.total_edges)
	}
	return strings.to_string(b)
}
