package build

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "modustool:foundation"

// The command `modustool floors measured <log> ...`
// (src/md/features/module_budget_request.md, "The first state of work"):
// it reads the facts Budget_Peak_At_Ready of the logs of machine runs, and
// prints for each module the peak of its budget at its first state of
// work, the floor of its start, and the working memory that its source
// states so that its floor holds the peak exactly. A module that marks its
// working memory "Measure pending" and has no peak in the logs is named:
// it says no first state of work. The command changes no file.

// The words of the template of Budget_Peak_At_Ready
// (src/modules/system/root/facts_start.odin). A host test reads the
// template and checks that it holds them.
FLOORS_PEAK_HEAD :: "root: "
FLOORS_PEAK_MIDDLE :: " reached its first state of work with a peak of "
FLOORS_PEAK_FLOOR :: " pages, for a floor of "
FLOORS_PEAK_END :: " pages"

// The mark of a working memory that waits for its measure.
FLOORS_MEASURE_PENDING :: "Measure pending"

// One module of the logs: the largest peak that a line gives, and the
// floor of the start of that line.
Floor_Measure :: struct {
	name:  string,
	peak:  u64,
	floor: u64,
}

// floors_measured_of_text gives the measure of each module that the lines
// of a rendered log name, in the order of their first line. Of two lines of
// one module (a restart, two runs), the larger peak holds. A line that is
// not whole is left out.
floors_measured_of_text :: proc(text: string, measures: ^[dynamic]Floor_Measure) {
	rest := text
	for len(rest) > 0 {
		end := strings.index_byte(rest, '\n')
		line := end < 0 ? rest : rest[:end]
		rest = end < 0 ? "" : rest[end + 1:]
		line = strings.trim_right(line, "\r")
		head := strings.index(line, FLOORS_PEAK_HEAD)
		middle := strings.index(line, FLOORS_PEAK_MIDDLE)
		if head < 0 || middle <= head + len(FLOORS_PEAK_HEAD) {
			continue
		}
		name := line[head + len(FLOORS_PEAK_HEAD):middle]
		numbers := line[middle + len(FLOORS_PEAK_MIDDLE):]
		floor_place := strings.index(numbers, FLOORS_PEAK_FLOOR)
		if floor_place < 0 || !strings.has_suffix(numbers, FLOORS_PEAK_END) {
			continue
		}
		peak, peak_ok := strconv.parse_u64_of_base(numbers[:floor_place], 10)
		floor, floor_ok := strconv.parse_u64_of_base(numbers[floor_place + len(FLOORS_PEAK_FLOOR):len(numbers) - len(FLOORS_PEAK_END)], 10)
		if !peak_ok || !floor_ok || strings.contains(name, " ") {
			continue
		}
		known := false
		for &item in measures {
			if item.name == name {
				known = true
				if peak > item.peak {
					item.peak, item.floor = peak, floor
				}
			}
		}
		if !known {
			append(measures, Floor_Measure{name = strings.clone(name, context.temp_allocator), peak = peak, floor = floor})
		}
	}
}

// working_memory_measured gives the working memory that a source states so
// that the floor of its start is the peak: the working memory that it
// states now, and the peak less the floor. It is never below 0, and a sum
// past 64 bits stops at the largest.
//
// Example: a stated 2048 pages, a peak of 1500 for a floor of 2400 give
// 1148; a peak of 2600 gives 2248.
working_memory_measured :: proc(stated, peak, floor: u64) -> u64 {
	if peak >= floor {
		grown := peak - floor
		return stated > max(u64) - grown ? max(u64) : stated + grown
	}
	return stated - min(stated, floor - peak)
}

// run_floors runs `modustool floors measured <log> ...`.
run_floors :: proc(args: []string) -> int {
	usage_text :: "modustool floors measured <log of a machine run> ..."
	if len(args) < 2 || args[0] != "measured" {
		fmt.eprintln(usage_text)
		return foundation.EXIT_USAGE
	}
	measures := make([dynamic]Floor_Measure, context.temp_allocator)
	catalog: Fact_Catalog
	catalog_made := false
	for path in args[1:] {
		bytes, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil {
			fmt.eprintfln("modustool: floors measured: cannot read %s: %v", path, read_error)
			return foundation.EXIT_FAILURE
		}
		text := string(bytes)
		// A raw serial log holds its facts as bytes: the module files of
		// this build render them.
		if strings.contains(text, FACT_LINE_MARK) {
			if !catalog_made {
				problem: string
				catalog, problem = fact_catalog_of_build(context.temp_allocator)
				if problem != "" {
					fmt.eprintfln("modustool: floors measured: the facts of %s cannot be rendered: %s", path, problem)
					return foundation.EXIT_FAILURE
				}
				catalog_made = true
			}
			text, _ = fact_lines_render(&catalog, text)
		}
		floors_measured_of_text(text, &measures)
	}
	for build in foundation.module_builds {
		if !build.entry {
			continue
		}
		described, described_ok := describe_package(build.source)
		if !described_ok {
			return foundation.EXIT_FAILURE
		}
		measured := false
		for item in measures {
			if item.name != build.name {
				continue
			}
			measured = true
			stated := described.budget.parts.working_memory_pages
			fmt.printfln("%s: a peak of %d pages, for a floor of %d pages: state working_memory_pages = %d in place of %d", build.name, item.peak, item.floor, working_memory_measured(stated, item.peak, item.floor), stated)
		}
		if !measured && described.budget.stated && strings.contains(described.budget.comment, FLOORS_MEASURE_PENDING) {
			fmt.printfln("%s: no peak in the logs: it says no first state of work, and its working memory stays pending", build.name)
		}
	}
	return 0
}
