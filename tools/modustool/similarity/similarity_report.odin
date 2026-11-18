package similarity

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "modustool:foundation"

// The report of the similarity finder, its two tables, and the command
// `modustool similarity` (src/md/infrastructure/similarity_finder.md,
// "12. The commands and the output").

SIMILARITY_OUTPUT_FOLDER :: foundation.BUILD_FOLDER + "/similarity"
SIMILARITY_REPORT_FILE :: SIMILARITY_OUTPUT_FOLDER + "/report.txt"
SIMILARITY_FAMILIES_FILE :: SIMILARITY_OUTPUT_FOLDER + "/families.tsv"
SIMILARITY_MEMBERS_FILE :: SIMILARITY_OUTPUT_FOLDER + "/members.tsv"
SIMILARITY_KEPT_FILE :: foundation.TOOL_SOURCE_FOLDER + "/similarity/similarity_kept.txt"

// The families that the terminal shows; the report file holds each one.
SIMILARITY_TERMINAL_FAMILIES_MOST :: 30
// The least score that `similarity near` lists, and the count that it shows.
SIMILARITY_NEAR_SCORE_LEAST :: 0.5
SIMILARITY_NEAR_LISTED_MOST :: 20

// The source files that a command of the tool writes: the finder does not
// read them, as their source is not Odin code of the project.
SIMILARITY_GENERATED_SOURCES :: [?]string{foundation.FONT_OUTPUT, foundation.BOOT_DISPLAY_FONT_OUTPUT}
// The first line of a file that a command writes.
SIMILARITY_GENERATED_MARK :: "// This file is the output of"

// similarity_repository_sources reads each Odin file of src/ and tools/,
// except the copies of the works of others and the files that a command
// writes.
similarity_repository_sources :: proc(allocator: mem.Allocator) -> (sources: []Similarity_Source, skipped: []Similarity_Skipped_File, ok: bool) {
	paths := make([dynamic]string, context.temp_allocator)
	folders := foundation.SOURCE_FOLDERS
	for folder in folders {
		foundation.source_files_of_a_folder(folder, &paths) or_return
	}
	foundation.source_files_of_a_folder(foundation.TOOL_SOURCE_FOLDER, &paths) or_return
	copied := make(map[string]bool, context.temp_allocator)
	lines := foundation.manifest_lines(foundation.CRYPTOGRAPHY_MANIFEST) or_return
	for fields in lines {
		if len(fields) > 0 {
			copied[fields[0]] = true
		}
	}
	generated := SIMILARITY_GENERATED_SOURCES
	read := make([dynamic]Similarity_Source, allocator)
	not_read := make([dynamic]Similarity_Skipped_File, allocator)
	slice.sort(paths[:])
	for path in paths {
		if path in copied {
			append(&not_read, Similarity_Skipped_File{path = strings.clone(path, allocator), reason = "a copy of a work of others: " + foundation.CRYPTOGRAPHY_MANIFEST})
			continue
		}
		if _, is_generated := slice.linear_search(generated[:], path); is_generated {
			append(&not_read, Similarity_Skipped_File{path = strings.clone(path, allocator), reason = "written by a command of the tool"})
			continue
		}
		text, error := os.read_entire_file(path, allocator)
		if error != nil {
			fmt.eprintfln("modustool: cannot read %s: %v", path, error)
			return nil, nil, false
		}
		if strings.has_prefix(string(text), SIMILARITY_GENERATED_MARK) {
			append(&not_read, Similarity_Skipped_File{path = strings.clone(path, allocator), reason = "it says that a command wrote it"})
			continue
		}
		append(&read, Similarity_Source{path = strings.clone(path, allocator), text = string(text)})
	}
	return read[:], not_read[:], true
}

@(private = "file")
similarity_percent :: proc(part, whole: i64) -> f64 {
	if whole == 0 {
		return 0
	}
	return 100 * f64(part) / f64(whole)
}

// The text of a node of the source, with each run of white space as one
// space and no tab, for one line of the report and one cell of a table.
similarity_node_text :: proc(analysis: ^Similarity_Analysis, node: i32) -> string {
	item := analysis.nodes[node]
	text := analysis.files[item.file].text
	start := clamp(int(item.start), 0, len(text))
	end := clamp(int(item.end), start, len(text))
	builder := strings.builder_make(context.temp_allocator)
	space := false
	for character in text[start:end] {
		if strings.is_space(character) {
			space = true
			continue
		}
		if space && strings.builder_len(builder) > 0 {
			strings.write_byte(&builder, ' ')
		}
		space = false
		strings.write_rune(&builder, character)
	}
	return strings.to_string(builder)
}

@(private = "file")
Similarity_Replacement :: struct {
	start: i32,
	end:   i32,
	text:  string,
}

// similarity_template_text prints a template from the source of its first
// member: each blank is `?n`, and a place that some members do not have is
// `?-`.
similarity_template_text :: proc(analysis: ^Similarity_Analysis, template: Similarity_Template) -> string {
	nodes := analysis.nodes
	first := analysis.pieces[template.members[0]]
	text := analysis.files[nodes[first.first].file].text
	text_start := clamp(nodes[first.first].start, 0, i32(len(text)))
	text_end := clamp(nodes[first.last].end, text_start, i32(len(text)))
	replacements := make([dynamic]Similarity_Replacement, context.temp_allocator)
	for blank in template.blanks {
		mark := blank.gap ? "?-" : fmt.tprintf("?%d", blank.number)
		append(&replacements, Similarity_Replacement{start = nodes[blank.place].start, end = nodes[blank.place].end, text = mark})
	}
	slice.sort_by(replacements[:], proc(a, b: Similarity_Replacement) -> bool {
		return a.start < b.start || (a.start == b.start && a.end > b.end)
	})
	builder := strings.builder_make(context.temp_allocator)
	cursor := text_start
	for replacement in replacements {
		if replacement.start < cursor || replacement.end > text_end || replacement.end < replacement.start {
			continue
		}
		strings.write_string(&builder, text[cursor:replacement.start])
		strings.write_string(&builder, replacement.text)
		cursor = replacement.end
	}
	strings.write_string(&builder, text[cursor:text_end])
	return strings.to_string(builder)
}

@(private = "file")
similarity_member_place :: proc(analysis: ^Similarity_Analysis, piece: i32) -> string {
	item := analysis.pieces[piece]
	nodes := analysis.nodes
	return fmt.tprintf("%s:%d-%d", analysis.files[nodes[item.first].file].path, nodes[item.first].first_line, nodes[item.last].last_line)
}

@(private = "file")
similarity_lowest_score :: proc(template: Similarity_Template) -> f64 {
	lowest := 1.0
	for score in template.scores {
		lowest = min(lowest, score)
	}
	return lowest
}

@(private = "file")
Similarity_Report_Order :: struct {
	group:  i32, // 0 ranked, 1 factorable and not ranked, 2 no call replaces it, 3 kept.
	rank:   i32,
	size:   i32,
	hash:   u64,
	family: i32,
}

// The reported families in the order of the report: the ranked families
// by rank, the other factorable families, the families that no call
// replaces, then the kept families, each by the size of its template.
similarity_report_order :: proc(analysis: ^Similarity_Analysis) -> []i32 {
	order := make([dynamic]Similarity_Report_Order, context.temp_allocator)
	for family, index in analysis.families {
		if !family.reported {
			continue
		}
		group: i32 = 2
		switch {
		case family.kept:
			group = 3
		case family.rank > 0:
			group = 0
		case similarity_category_is_factorable(family.category):
			group = 1
		}
		append(&order, Similarity_Report_Order{group = group, rank = family.rank, size = family.template.matched, hash = family.template_hash, family = i32(index)})
	}
	slice.sort_by(order[:], proc(a, b: Similarity_Report_Order) -> bool {
		if a.group != b.group {
			return a.group < b.group
		}
		if a.rank != b.rank {
			return a.rank < b.rank
		}
		if a.size != b.size {
			return a.size > b.size
		}
		return a.hash < b.hash || (a.hash == b.hash && a.family < b.family)
	})
	result := make([]i32, len(order), context.temp_allocator)
	for item, index in order {
		result[index] = item.family
	}
	return result
}

@(private = "file")
similarity_write_family :: proc(builder: ^strings.Builder, analysis: ^Similarity_Analysis, family: Similarity_Family, title: string) {
	template := family.template
	fmt.sbprintfln(builder, "### %s", title)
	fmt.sbprintfln(builder, "")
	fmt.sbprintfln(builder, "- Uses: %d. Packages: %s.", len(template.members), strings.join(family.packages, ", ", context.temp_allocator))
	fmt.sbprintfln(builder, "- The lowest score with the first member: %.3f. The template: %d nodes, about %d lines, %d blanks, %d places that some members do not have.", similarity_lowest_score(template), template.matched, family.template_lines, template.parameter_count, template.gaps)
	fmt.sbprintfln(builder, "- Home: %s. Template hash: %016x.", family.home, family.template_hash)
	if family.rules != {} {
		names := make([dynamic]string, context.temp_allocator)
		for rule in Similarity_Rule {
			if rule in family.rules {
				append(&names, similarity_rule_name(rule))
			}
		}
		fmt.sbprintfln(builder, "- The rules of the normal form that some members needed: %s.", strings.join(names[:], ", ", context.temp_allocator))
	}
	if family.kind == .Run {
		fmt.sbprintfln(builder, "- The run reads %d locals from before it and gives %d locals to the statements after it.", family.run_inputs, family.run_outputs)
	}
	if family.control_leaves {
		fmt.sbprintfln(builder, "- Control leaves the run: a member returns, breaks, continues, defers or uses or_return.")
	}
	if family.holds_using {
		fmt.sbprintfln(builder, "- A member holds `using`: a name in it can be a field that the finder reads as a global.")
	}
	if template.cheap {
		fmt.sbprintfln(builder, "- Aligned by the shape of the children only: the pieces are larger than the bound of the weighted alignment.")
	}
	for blank in template.blanks {
		if !blank.gap && blank.kind != .Value {
			fmt.sbprintfln(builder, "- ?%d is a blank of kind %s.", blank.number, similarity_blank_kind_name(blank.kind))
		}
	}
	fmt.sbprintfln(builder, "")
	fmt.sbprintfln(builder, "```odin")
	fmt.sbprintfln(builder, "%s", similarity_template_text(analysis, template))
	fmt.sbprintfln(builder, "```")
	fmt.sbprintfln(builder, "")
	for member, position in template.members {
		arguments := make([dynamic]string, context.temp_allocator)
		shown := make(map[i32]bool, context.temp_allocator)
		for blank in template.blanks {
			if blank.gap || blank.number in shown {
				continue
			}
			shown[blank.number] = true
			append(&arguments, fmt.tprintf("?%d = `%s`", blank.number, similarity_node_text(analysis, blank.arguments[position])))
		}
		line := fmt.tprintf("- %s, coverage %.3f, score with the first %.3f", similarity_member_place(analysis, member), template.coverages[position], template.scores[position])
		if len(arguments) > 0 {
			line = fmt.tprintf("%s: %s", line, strings.join(arguments[:], ", ", context.temp_allocator))
		}
		if template.only_in_members[position] > 0 {
			line = fmt.tprintf("%s; %d children that only this member has", line, template.only_in_members[position])
		}
		fmt.sbprintfln(builder, "%s", line)
	}
	fmt.sbprintfln(builder, "")
}

// similarity_report writes the report. family_limit bounds the families
// of each list, or -1 for each one. The report holds no time, so the same
// sources give the same bytes.
similarity_report :: proc(analysis: ^Similarity_Analysis, skipped: []Similarity_Skipped_File, family_limit: int) -> string {
	builder := strings.builder_make(context.temp_allocator)
	measures := analysis.measures
	fmt.sbprintfln(&builder, "# The similarity of the Odin sources")
	fmt.sbprintfln(&builder, "")
	fmt.sbprintfln(&builder, "The design: src/md/infrastructure/similarity_finder.md. A blank is ?n, a place that some members do not have is ?-.")
	fmt.sbprintfln(&builder, "")
	fmt.sbprintfln(&builder, "## The measures")
	fmt.sbprintfln(&builder, "")
	fmt.sbprintfln(&builder, "| Area | Files | Procedures | Nodes | Lines |")
	fmt.sbprintfln(&builder, "|---|---|---|---|---|")
	for area in Similarity_Area {
		fmt.sbprintfln(&builder, "| %s | %d | %d | %d | %d |", similarity_area_name(area), measures.files[area], measures.procedures[area], measures.nodes[area], measures.lines[area])
	}
	fmt.sbprintfln(&builder, "")
	fmt.sbprintfln(&builder, "Files not read: %d.", len(skipped))
	for file in skipped {
		fmt.sbprintfln(&builder, "- %s: %s", file.path, file.reason)
	}
	if len(analysis.parse_fault) > 0 {
		fmt.sbprintfln(&builder, "Files that the parser did not read whole, and that the finder does not compare: %d.", len(analysis.parse_fault))
		for path in analysis.parse_fault {
			fmt.sbprintfln(&builder, "- %s", path)
		}
	}
	fmt.sbprintfln(&builder, "")
	filter := measures.near_filter
	fmt.sbprintfln(&builder, "The near pass compares %d procedures and blocks: %d pairs in all, %d share a feature of their prefixes, %d pass the sizes and the two vectors, %d reach the threshold %.2f by their bound.", measures.near_pieces, filter.all_pairs, filter.prefix_pairs, filter.kept_pairs, measures.near_pairs_above, SIMILARITY_COVERAGE_LEAST)
	fmt.sbprintfln(&builder, "Pairs aligned by the shape of the children only, because the product of their sizes passes %d nodes: %d.", SIMILARITY_WEIGHTED_ALIGNMENT_NODE_PRODUCT_MOST, measures.cheap_pairs)
	fmt.sbprintfln(&builder, "Just outside: %d groups of procedures of %d to %d nodes, %d runs of %d to %d nodes, %d groups of expressions of %d to %d nodes, %d pairs with a bound from %.2f to %.2f.", measures.near_minimum_groups[.Procedure], SIMILARITY_PIECE_NODES_NEAR_MINIMUM, SIMILARITY_PIECE_NODES_LEAST - 1, measures.near_minimum_groups[.Run], SIMILARITY_PIECE_NODES_NEAR_MINIMUM, SIMILARITY_PIECE_NODES_LEAST - 1, measures.near_minimum_groups[.Expression], SIMILARITY_EXPRESSION_NODES_NEAR_MINIMUM, SIMILARITY_EXPRESSION_NODES_LEAST - 1, measures.near_threshold_pairs, SIMILARITY_SCORE_NEAR_THRESHOLD, SIMILARITY_COVERAGE_LEAST)
	reported := 0
	kept := 0
	ranked := 0
	for family in analysis.families {
		reported += family.reported ? 1 : 0
		kept += family.kept ? 1 : 0
		ranked += family.rank > 0 ? 1 : 0
	}
	fmt.sbprintfln(&builder, "Families: %d found, %d held by a larger family, %d reported, %d kept, %d ranked, %d that save nothing after the ones ranked before them. Members dropped under the coverage %.2f: %d.", measures.families_found, measures.families_held, reported, kept, ranked, measures.families_unranked, SIMILARITY_COVERAGE_LEAST, measures.members_below_coverage)
	fmt.sbprintfln(&builder, "")
	fmt.sbprintfln(&builder, "## The totals")
	fmt.sbprintfln(&builder, "")
	fmt.sbprintfln(&builder, "The nodes and the lines in a family of each category, each one counted once, and their share of the area.")
	fmt.sbprintfln(&builder, "")
	fmt.sbprintfln(&builder, "| Category | System nodes | System lines | Tool nodes | Tool lines | Tests nodes | Tests lines |")
	fmt.sbprintfln(&builder, "|---|---|---|---|---|---|---|")
	for category in Similarity_Category {
		row := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&row, "| %s", similarity_category_name(category))
		for area in Similarity_Area {
			fmt.sbprintf(&row, " | %d (%.1f%%) | %d (%.1f%%)", measures.family_nodes[category][area], similarity_percent(measures.family_nodes[category][area], measures.nodes[area]), measures.family_lines[category][area], similarity_percent(measures.family_lines[category][area], measures.lines[area]))
		}
		fmt.sbprintfln(&builder, "%s |", strings.to_string(row))
	}
	any_row := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&any_row, "| any family")
	for area in Similarity_Area {
		fmt.sbprintf(&any_row, " | %d (%.1f%%) | %d (%.1f%%)", measures.any_family_nodes[area], similarity_percent(measures.any_family_nodes[area], measures.nodes[area]), measures.any_family_lines[area], similarity_percent(measures.any_family_lines[area], measures.lines[area]))
	}
	fmt.sbprintfln(&builder, "%s |", strings.to_string(any_row))
	fmt.sbprintfln(&builder, "")
	fmt.sbprintfln(&builder, "A factoring of the %d ranked families saves %d nodes and %d lines.", ranked, measures.saved_nodes, measures.saved_lines)
	fmt.sbprintfln(&builder, "")
	order := similarity_report_order(analysis)
	sections := [4]string{"## The ranked families", "## The families that save nothing after the ranked ones", "## The families that no call replaces", "## The kept families"}
	section := -1
	shown := 0
	for index in order {
		family := analysis.families[index]
		group := 2
		switch {
		case family.kept:
			group = 3
		case family.rank > 0:
			group = 0
		case similarity_category_is_factorable(family.category):
			group = 1
		}
		if group != section {
			section = group
			shown = 0
			fmt.sbprintfln(&builder, "%s", sections[group])
			fmt.sbprintfln(&builder, "")
		}
		if family_limit >= 0 && shown >= family_limit {
			continue
		}
		shown += 1
		title: string
		switch group {
		case 0:
			title = fmt.tprintf("%d. %s: saves %d nodes and %d lines with %d uses", family.rank, similarity_category_name(family.category), family.saved_nodes, family.saved_lines, family.selected_uses)
		case 3:
			title = fmt.tprintf("%s, kept: %s", similarity_category_name(family.category), family.kept_reason)
		case:
			title = fmt.tprintf("%s: a template of %d nodes", similarity_category_name(family.category), family.template.matched)
		}
		similarity_write_family(&builder, analysis, family, title)
	}
	stale := 0
	for line in analysis.kept {
		if !line.used {
			stale += 1
		}
	}
	if stale > 0 {
		fmt.sbprintfln(&builder, "## The stale lines of %s", SIMILARITY_KEPT_FILE)
		fmt.sbprintfln(&builder, "")
		for line in analysis.kept {
			switch {
			case !line.valid:
				fmt.sbprintfln(&builder, "- line %d is not 16 hexadecimal digits, a space and a reason: %s", line.line, line.text)
			case !line.used:
				fmt.sbprintfln(&builder, "- line %d names no family: %s", line.line, line.text)
			}
		}
		fmt.sbprintfln(&builder, "")
	}
	return strings.to_string(builder)
}

// similarity_times_text gives the time of each phase: a measure of one
// run, printed on the terminal and kept out of the report file.
similarity_times_text :: proc(analysis: ^Similarity_Analysis, read: time.Duration) -> string {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&builder, "modustool: the time of each phase of this run, a measure:")
	fmt.sbprintfln(&builder, "  the read of the files: %.3f s", time.duration_seconds(read))
	for phase in Similarity_Phase {
		fmt.sbprintfln(&builder, "  %s: %.3f s", similarity_phase_name(phase), time.duration_seconds(analysis.measures.times[phase]))
	}
	return strings.to_string(builder)
}

@(private = "file")
similarity_cell :: proc(text: string) -> string {
	cell, _ := strings.replace_all(text, "\t", " ", context.temp_allocator)
	return cell
}

// similarity_families_table gives families.tsv: one row for each reported
// family, in the order of the report.
similarity_families_table :: proc(analysis: ^Similarity_Analysis) -> string {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&builder, "rank\tcategory\tsaved_nodes\tsaved_lines\tuses\tlowest_score\ttemplate_nodes\tblanks\tgaps\thome\ttemplate_hash\tfirst_member\tkept")
	for index in similarity_report_order(analysis) {
		family := analysis.families[index]
		template := family.template
		fmt.sbprintfln(&builder, "%d\t%s\t%d\t%d\t%d\t%.3f\t%d\t%d\t%d\t%s\t%016x\t%s\t%s", family.rank, similarity_category_name(family.category), family.saved_nodes, family.saved_lines, len(template.members), similarity_lowest_score(template), template.matched, template.parameter_count, template.gaps, similarity_cell(family.home), family.template_hash, similarity_member_place(analysis, template.members[0]), similarity_cell(family.kept_reason))
	}
	return strings.to_string(builder)
}

// similarity_members_table gives members.tsv: one row for each member of
// each reported family.
similarity_members_table :: proc(analysis: ^Similarity_Analysis) -> string {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&builder, "template_hash\tfile\tfirst_line\tlast_line\tpackage\tarea\tscore\tcoverage\targuments")
	nodes := analysis.nodes
	for index in similarity_report_order(analysis) {
		family := analysis.families[index]
		template := family.template
		for member, position in template.members {
			piece := analysis.pieces[member]
			file := analysis.files[nodes[piece.first].file]
			arguments := make([dynamic]string, context.temp_allocator)
			shown := make(map[i32]bool, context.temp_allocator)
			for blank in template.blanks {
				if blank.gap || blank.number in shown {
					continue
				}
				shown[blank.number] = true
				append(&arguments, fmt.tprintf("?%d=%s", blank.number, similarity_node_text(analysis, blank.arguments[position])))
			}
			fmt.sbprintfln(&builder, "%016x\t%s\t%d\t%d\t%s\t%s\t%.3f\t%.3f\t%s", family.template_hash, file.path, nodes[piece.first].first_line, nodes[piece.last].last_line, file.folder, similarity_area_name(file.area), template.scores[position], template.coverages[position], similarity_cell(strings.join(arguments[:], "; ", context.temp_allocator)))
		}
	}
	return strings.to_string(builder)
}

@(private = "file")
similarity_place_argument :: proc(argument: string) -> (path: string, line: i32, ok: bool) {
	colon := strings.last_index_byte(argument, ':')
	if colon <= 0 {
		return "", 0, false
	}
	value, parsed := strconv.parse_int(argument[colon + 1:])
	if !parsed || value <= 0 {
		return "", 0, false
	}
	return argument[:colon], i32(value), true
}

@(private = "file")
similarity_write_pair :: proc(builder: ^strings.Builder, analysis: ^Similarity_Analysis, first, other: i32) {
	template := similarity_pair_template(analysis, first, other)
	fmt.sbprintfln(builder, "%s and %s: score %.3f, %d nodes in the template, %d blanks, %d places that only the first has, %d children that only the second has", similarity_member_place(analysis, first), similarity_member_place(analysis, other), template.scores[1], template.matched, template.parameter_count, template.gaps, template.only_in_members[1])
	fmt.sbprintfln(builder, "```odin")
	fmt.sbprintfln(builder, "%s", similarity_template_text(analysis, template))
	fmt.sbprintfln(builder, "```")
	shown := make(map[i32]bool, context.temp_allocator)
	for blank in template.blanks {
		if blank.gap || blank.number in shown {
			continue
		}
		shown[blank.number] = true
		fmt.sbprintfln(builder, "?%d (%s): `%s` and `%s`", blank.number, similarity_blank_kind_name(blank.kind), similarity_node_text(analysis, blank.arguments[0]), similarity_node_text(analysis, blank.arguments[1]))
	}
}

// similarity_near_text gives the procedures most similar to the one that
// holds a line.
similarity_near_text :: proc(analysis: ^Similarity_Analysis, path: string, line: i32) -> (text: string, ok: bool) {
	target := similarity_procedure_piece_at(analysis, path, line)
	if target < 0 {
		return fmt.tprintf("modustool: no procedure of %s holds the line %d", path, line), false
	}
	builder := strings.builder_make(context.temp_allocator)
	results := similarity_near_procedures(analysis, target, SIMILARITY_NEAR_SCORE_LEAST)
	fmt.sbprintfln(&builder, "The procedure %s, %d nodes: %d procedures with a score of %.2f or more.", similarity_member_place(analysis, target), analysis.pieces[target].size, len(results), SIMILARITY_NEAR_SCORE_LEAST)
	fmt.sbprintfln(&builder, "")
	for result, index in results {
		if index >= SIMILARITY_NEAR_LISTED_MOST {
			fmt.sbprintfln(&builder, "And %d more, each with a lower score.", len(results) - index)
			break
		}
		similarity_write_pair(&builder, analysis, target, result.piece)
		fmt.sbprintfln(&builder, "")
	}
	return strings.to_string(builder), true
}

// similarity_pair_text gives the score of two procedures and their template.
similarity_pair_text :: proc(analysis: ^Similarity_Analysis, first_path: string, first_line: i32, other_path: string, other_line: i32) -> (text: string, ok: bool) {
	first := similarity_procedure_piece_at(analysis, first_path, first_line)
	if first < 0 {
		return fmt.tprintf("modustool: no procedure of %s holds the line %d", first_path, first_line), false
	}
	other := similarity_procedure_piece_at(analysis, other_path, other_line)
	if other < 0 {
		return fmt.tprintf("modustool: no procedure of %s holds the line %d", other_path, other_line), false
	}
	if similarity_pieces_overlap(analysis.nodes, analysis.pieces[first], analysis.pieces[other]) {
		return "modustool: the two places name one procedure, or one inside the other", false
	}
	builder := strings.builder_make(context.temp_allocator)
	similarity_write_pair(&builder, analysis, first, other)
	return strings.to_string(builder), true
}

@(private = "file")
similarity_write_output :: proc(path, text: string) -> bool {
	if error := os.write_entire_file(path, text); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, error)
		return false
	}
	return true
}

// run_similarity is the command `similarity`: the report of the whole
// repository, or `near <file>:<line>`, or `pair <file>:<line> <file>:<line>`.
run_similarity :: proc(args: []string) -> int {
	usage_line :: "modustool: similarity | similarity near <file>:<line> | similarity pair <file>:<line> <file>:<line>"
	mode := len(args) == 0 ? "report" : args[0]
	switch {
	case mode == "report":
	case mode == "near" && len(args) == 2:
	case mode == "pair" && len(args) == 3:
	case:
		fmt.eprintln(usage_line)
		return foundation.EXIT_USAGE
	}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		fmt.eprintln("modustool: cannot reserve the memory of the similarity finder")
		return foundation.EXIT_FAILURE
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	context.allocator = allocator
	read_start := time.tick_now()
	sources, skipped, read := similarity_repository_sources(allocator)
	if !read {
		return foundation.EXIT_FAILURE
	}
	read_time := time.tick_since(read_start)
	switch mode {
	case "near":
		path, line, ok := similarity_place_argument(args[1])
		if !ok {
			fmt.eprintln(usage_line)
			return foundation.EXIT_USAGE
		}
		analysis := similarity_analysis_make(sources, allocator)
		defer similarity_analysis_destroy(analysis)
		similarity_add_procedure_pieces(analysis)
		text, found := similarity_near_text(analysis, path, line)
		if !found {
			fmt.eprintln(text)
			return foundation.EXIT_FAILURE
		}
		fmt.print(text)
		return 0
	case "pair":
		first_path, first_line, first_ok := similarity_place_argument(args[1])
		other_path, other_line, other_ok := similarity_place_argument(args[2])
		if !first_ok || !other_ok {
			fmt.eprintln(usage_line)
			return foundation.EXIT_USAGE
		}
		analysis := similarity_analysis_make(sources, allocator)
		defer similarity_analysis_destroy(analysis)
		similarity_add_procedure_pieces(analysis)
		text, found := similarity_pair_text(analysis, first_path, first_line, other_path, other_line)
		if !found {
			fmt.eprintln(text)
			return foundation.EXIT_FAILURE
		}
		fmt.print(text)
		return 0
	}
	kept_text := ""
	if os.exists(SIMILARITY_KEPT_FILE) {
		data, error := os.read_entire_file(SIMILARITY_KEPT_FILE, allocator)
		if error != nil {
			fmt.eprintfln("modustool: cannot read %s: %v", SIMILARITY_KEPT_FILE, error)
			return foundation.EXIT_FAILURE
		}
		kept_text = string(data)
	}
	analysis := similarity_analyse(sources, kept_text, allocator)
	defer similarity_analysis_destroy(analysis)
	if error := os.make_directory_all(SIMILARITY_OUTPUT_FOLDER); error != nil && error != .Exist {
		fmt.eprintfln("modustool: cannot make %s: %v", SIMILARITY_OUTPUT_FOLDER, error)
		return foundation.EXIT_FAILURE
	}
	report := similarity_report(analysis, skipped, -1)
	if !similarity_write_output(SIMILARITY_REPORT_FILE, report) || !similarity_write_output(SIMILARITY_FAMILIES_FILE, similarity_families_table(analysis)) || !similarity_write_output(SIMILARITY_MEMBERS_FILE, similarity_members_table(analysis)) {
		return foundation.EXIT_FAILURE
	}
	fmt.print(similarity_report(analysis, skipped, SIMILARITY_TERMINAL_FAMILIES_MOST))
	fmt.print(similarity_times_text(analysis, read_time))
	fmt.printfln("modustool: the whole report: %s, and the tables %s and %s", SIMILARITY_REPORT_FILE, SIMILARITY_FAMILIES_FILE, SIMILARITY_MEMBERS_FILE)
	return 0
}
