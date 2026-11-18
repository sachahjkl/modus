package similarity

import "core:fmt"
import "core:strings"
import "core:testing"

// The host tests of the similarity finder: small sources with a known
// answer (src/md/infrastructure/similarity_finder.md, "13. The tests").

// A procedure of about 55 nodes. {name}, {total}, {count}, {value},
// {values}, {limit} and {extra} are replaced by each test.
@(private = "file")
SIMILARITY_TEST_PROCEDURE :: `{name} :: proc({values}: []int, {limit}: int) -> int {
	{total} := 0
	{count} := 0
	for {value} in {values} {
		{total} += {value} * {value}
		{count} += 1
	}
	if {total} > {limit} {
		{total} = {limit}
	}{extra}
	if {count} == 0 {
		return 0
	}
	return {total} / {count}
}
`

// The names of the locals of SIMILARITY_TEST_PROCEDURE, in the order of
// its placeholders.
@(private = "file")
SIMILARITY_TEST_NAMES :: [5]string{"total", "count", "value", "values", "limit"}

@(private = "file")
similarity_test_procedure :: proc(name: string, names := SIMILARITY_TEST_NAMES, extra := "") -> string {
	text := SIMILARITY_TEST_PROCEDURE
	replacements := [?][2]string{{"{name}", name}, {"{total}", names[0]}, {"{count}", names[1]}, {"{value}", names[2]}, {"{values}", names[3]}, {"{limit}", names[4]}, {"{extra}", extra}}
	for replacement in replacements {
		text, _ = strings.replace_all(text, replacement[0], replacement[1], context.temp_allocator)
	}
	return text
}

@(private = "file")
similarity_test_file :: proc(package_name: string, bodies: ..string) -> string {
	return strings.concatenate({"package ", package_name, "\n\nimport \"modus:support/shared_package\"\n\n", strings.join(bodies, "\n", context.temp_allocator)}, context.temp_allocator)
}

@(private = "file")
similarity_test_families :: proc(analysis: ^Similarity_Analysis, kind: Similarity_Piece_Kind) -> []Similarity_Family {
	found := make([dynamic]Similarity_Family, context.temp_allocator)
	for family in analysis.families {
		if family.reported && family.kind == kind {
			append(&found, family)
		}
	}
	return found[:]
}

@(private = "file")
similarity_test_text :: proc(analysis: ^Similarity_Analysis, node: i32) -> string {
	return similarity_node_text(analysis, node)
}

// Two procedures that are equal but for the names of their locals, in two
// support packages: one utility to centralise, with no blank, and its home
// in the support package that both import.
@(test)
similarity_equal_procedures_in_two_packages :: proc(t: ^testing.T) {
	sources := []Similarity_Source {
		{path = "src/library/support/first_package/first.odin", text = similarity_test_file("first_package", similarity_test_procedure("first_sum"))},
		{path = "src/library/support/second_package/second.odin", text = similarity_test_file("second_package", similarity_test_procedure("second_sum", {"sum", "number", "item", "items", "bound"}))},
	}
	analysis := similarity_analyse(sources, "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	families := similarity_test_families(analysis, .Procedure)
	testing.expect_value(t, len(families), 1)
	if len(families) != 1 {
		return
	}
	family := families[0]
	testing.expect_value(t, family.category, Similarity_Category.Utility_To_Centralise)
	testing.expect_value(t, family.template.parameter_count, 0)
	testing.expect_value(t, family.template.gaps, 0)
	testing.expect_value(t, similarity_lowest_score_of(family.template), 1.0)
	testing.expect_value(t, family.home, "modus:support/shared_package")
}

@(private = "file")
similarity_lowest_score_of :: proc(template: Similarity_Template) -> f64 {
	lowest := 1.0
	for score in template.scores {
		lowest = min(lowest, score)
	}
	return lowest
}

// `a := x; b := a` against `a := x; b := x`: not equal; one value blank at
// the second statement.
@(test)
similarity_data_flow_is_not_renaming :: proc(t: ^testing.T) {
	first := similarity_test_procedure("first_copy", extra = "\n\tfirst_copy_value := limit\n\tsecond_copy_value := first_copy_value\n\ttotal += second_copy_value")
	second := similarity_test_procedure("second_copy", extra = "\n\tfirst_copy_value := limit\n\tsecond_copy_value := limit\n\ttotal += second_copy_value")
	sources := []Similarity_Source{{path = "src/processes/copies/main.odin", text = similarity_test_file("copies", first, second)}}
	analysis := similarity_analyse(sources, "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	families := similarity_test_families(analysis, .Procedure)
	testing.expect_value(t, len(families), 1)
	if len(families) != 1 {
		return
	}
	template := families[0].template
	testing.expect_value(t, template.parameter_count, 1)
	testing.expect_value(t, len(template.blanks), 1)
	if len(template.blanks) == 1 {
		blank := template.blanks[0]
		testing.expect_value(t, blank.kind, Similarity_Blank_Kind.Value)
		testing.expect_value(t, similarity_test_text(analysis, blank.arguments[0]), "first_copy_value")
		testing.expect_value(t, similarity_test_text(analysis, blank.arguments[1]), "limit")
	}
}

// Two procedures that differ by one literal: one value blank, ?1 in the
// text of the template, and each literal as an argument.
@(test)
similarity_one_literal_is_one_blank :: proc(t: ^testing.T) {
	first := similarity_test_procedure("first_limit", extra = "\n\ttotal += 1000")
	second := similarity_test_procedure("second_limit", extra = "\n\ttotal += 2000")
	sources := []Similarity_Source{{path = "src/processes/limits/main.odin", text = similarity_test_file("limits", first, second)}}
	analysis := similarity_analyse(sources, "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	families := similarity_test_families(analysis, .Procedure)
	testing.expect_value(t, len(families), 1)
	if len(families) != 1 {
		return
	}
	family := families[0]
	testing.expect_value(t, family.category, Similarity_Category.Parametric_Family)
	testing.expect_value(t, family.template.parameter_count, 1)
	testing.expect(t, strings.contains(similarity_template_text(analysis, family.template), "total += ?1"), "the template text holds ?1 at the literal")
	if len(family.template.blanks) == 1 {
		testing.expect_value(t, similarity_test_text(analysis, family.template.blanks[0].arguments[0]), "1000")
		testing.expect_value(t, similarity_test_text(analysis, family.template.blanks[0].arguments[1]), "2000")
	}
}

@(private = "file")
SIMILARITY_TEST_TYPED :: `{name} :: proc(values: []{type}, limit: {type}) -> {type} {
	total := values[0]
	count := 0
	for value in values {
		total += value * value
		count += 1
	}
	if total > limit {
		total = limit
	}
	if count == 0 {
		return total
	}
	return total / limit
}
`

// One procedure for u32 and for u64: one type blank, though the type is
// at three places.
@(test)
similarity_one_type_is_one_blank :: proc(t: ^testing.T) {
	first, _ := strings.replace_all(SIMILARITY_TEST_TYPED, "{type}", "u32", context.temp_allocator)
	first, _ = strings.replace_all(first, "{name}", "sum_u32", context.temp_allocator)
	second, _ := strings.replace_all(SIMILARITY_TEST_TYPED, "{type}", "u64", context.temp_allocator)
	second, _ = strings.replace_all(second, "{name}", "sum_u64", context.temp_allocator)
	sources := []Similarity_Source{{path = "src/processes/types/main.odin", text = similarity_test_file("types", first, second)}}
	analysis := similarity_analyse(sources, "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	families := similarity_test_families(analysis, .Procedure)
	testing.expect_value(t, len(families), 1)
	if len(families) != 1 {
		return
	}
	template := families[0].template
	testing.expect_value(t, template.parameter_count, 1)
	testing.expect_value(t, len(template.blanks), 3)
	for blank in template.blanks {
		testing.expect_value(t, blank.kind, Similarity_Blank_Kind.Type)
	}
}

// The same pair of different literals at two places gives one blank.
@(test)
similarity_same_pair_is_one_blank :: proc(t: ^testing.T) {
	first := similarity_test_procedure("first_step", extra = "\n\ttotal += 7\n\tcount += 7")
	second := similarity_test_procedure("second_step", extra = "\n\ttotal += 9\n\tcount += 9")
	sources := []Similarity_Source{{path = "src/processes/steps/main.odin", text = similarity_test_file("steps", first, second)}}
	analysis := similarity_analyse(sources, "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	families := similarity_test_families(analysis, .Procedure)
	testing.expect_value(t, len(families), 1)
	if len(families) == 1 {
		testing.expect_value(t, families[0].template.parameter_count, 1)
		testing.expect_value(t, len(families[0].template.blanks), 2)
	}
}

@(private = "file")
SIMILARITY_TEST_BOOLEAN :: `{name} :: proc(values: []int, limit: int) -> bool {
	total := 0
	count := 0
	for value in values {
		total += value * value
		count += 1
	}
	if count == 0 {
		return false
	}
	{end}
}
`

// `if a > b { return true }; return false` against `return b < a`: equal
// after the normal form, and the family names the two rules.
@(test)
similarity_boolean_return_is_equal :: proc(t: ^testing.T) {
	first, _ := strings.replace_all(SIMILARITY_TEST_BOOLEAN, "{end}", "if total > limit {\n\t\treturn true\n\t}\n\treturn false", context.temp_allocator)
	first, _ = strings.replace_all(first, "{name}", "first_check", context.temp_allocator)
	second, _ := strings.replace_all(SIMILARITY_TEST_BOOLEAN, "{end}", "return limit < total", context.temp_allocator)
	second, _ = strings.replace_all(second, "{name}", "second_check", context.temp_allocator)
	sources := []Similarity_Source{{path = "src/processes/checks/main.odin", text = similarity_test_file("checks", first, second)}}
	analysis := similarity_analyse(sources, "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	families := similarity_test_families(analysis, .Procedure)
	testing.expect_value(t, len(families), 1)
	if len(families) != 1 {
		return
	}
	family := families[0]
	testing.expect_value(t, family.template.parameter_count, 0)
	testing.expect_value(t, family.category, Similarity_Category.Local_Repetition)
	testing.expect(t, .Boolean_Return in family.rules, "the family names the boolean return")
	testing.expect(t, .Comparison_Direction in family.rules, "the family names the direction of a comparison")
}

// `x * y` against `y * x` is not equal: `*` keeps the order of its operands.
@(test)
similarity_multiplication_keeps_its_order :: proc(t: ^testing.T) {
	first := similarity_test_procedure("first_product", extra = "\n\ttotal += value_left * value_right")
	second := similarity_test_procedure("second_product", extra = "\n\ttotal += value_right * value_left")
	sources := []Similarity_Source{{path = "src/processes/products/main.odin", text = similarity_test_file("products", strings.concatenate({"value_left := 3\nvalue_right := 5\n", first, second}, context.temp_allocator))}}
	analysis := similarity_analyse(sources, "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	families := similarity_test_families(analysis, .Procedure)
	testing.expect_value(t, len(families), 1)
	if len(families) == 1 {
		testing.expect(t, families[0].template.parameter_count >= 1, "the two orders are different")
	}
}

// An expression with five uses: one family of repeated expressions.
@(test)
similarity_repeated_expression :: proc(t: ^testing.T) {
	expression := "clamp_value(first_value * 3 + second_value, 0, first_value + second_value + 7)"
	body := strings.concatenate({"spread :: proc(first_value, second_value: int) -> int {\n\tfirst_result := ", expression, "\n\tsecond_result := ", expression, " * 2\n\tthird_result := 1 + ", expression, "\n\tfourth_result := ", expression, " - 4\n\tfifth_result := ", expression, " / 3\n\treturn first_result + second_result + third_result + fourth_result + fifth_result\n}\n"}, context.temp_allocator)
	sources := []Similarity_Source{{path = "src/processes/spread/main.odin", text = similarity_test_file("spread", body)}}
	analysis := similarity_analyse(sources, "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	families := similarity_test_families(analysis, .Expression)
	testing.expect_value(t, len(families), 1)
	if len(families) == 1 {
		testing.expect_value(t, families[0].category, Similarity_Category.Repeated_Expression)
		testing.expect_value(t, len(families[0].template.members), 5)
	}
}

@(private = "file")
SIMILARITY_TEST_RUN :: `	total := 0
	for step in 0 ..< 10 {
		total += step * base
		total -= step
		total += base * 2 + step
	}
	total *= 3
	if total > 1000 {
		{inside}
	}
`

@(private = "file")
SIMILARITY_TEST_OTHER_WORK :: `	first_other := extra * 4
	second_other := first_other + extra
	if second_other > 100 {
		second_other = second_other - first_other * 2
	}
	for index in 0 ..< second_other {
		first_other += index * extra
	}
`

@(private = "file")
similarity_test_run_sources :: proc(inside: string) -> []Similarity_Source {
	run, _ := strings.replace_all(SIMILARITY_TEST_RUN, "{inside}", inside, context.temp_allocator)
	first := strings.concatenate({"first_user :: proc(base: int) -> int {\n", run, "\treturn total + base\n}\n"}, context.temp_allocator)
	second := strings.concatenate({"second_user :: proc(base: int, extra: int) -> int {\n", SIMILARITY_TEST_OTHER_WORK, run, SIMILARITY_TEST_OTHER_WORK, "\treturn total - extra\n}\n"}, context.temp_allocator)
	sources := make([]Similarity_Source, 1, context.temp_allocator)
	sources[0] = {path = "src/processes/runs/main.odin", text = similarity_test_file("runs", first, second)}
	return sources
}

// A run of statements in two procedures, with one input (base) and one
// output (total).
@(test)
similarity_run_with_its_data_flow :: proc(t: ^testing.T) {
	analysis := similarity_analyse(similarity_test_run_sources("total = 1000"), "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	families := similarity_test_families(analysis, .Run)
	testing.expect_value(t, len(families), 1)
	if len(families) == 1 {
		testing.expect_value(t, families[0].run_inputs, 1)
		testing.expect_value(t, families[0].run_outputs, 1)
		testing.expect(t, !families[0].control_leaves, "control does not leave the run")
		testing.expect_value(t, families[0].category, Similarity_Category.Local_Repetition)
	}
}

// A run with a `return` is not one call.
@(test)
similarity_run_that_control_leaves :: proc(t: ^testing.T) {
	analysis := similarity_analyse(similarity_test_run_sources("return 0"), "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	families := similarity_test_families(analysis, .Run)
	testing.expect_value(t, len(families), 1)
	if len(families) == 1 {
		testing.expect(t, families[0].control_leaves, "control leaves the run")
		testing.expect_value(t, families[0].category, Similarity_Category.Similar_Behaviour)
	}
}

// A member in the kernel and one in a support package: the rules keep
// them apart, and the home is a contract package by a decision.
@(test)
similarity_kernel_and_support_are_kept_apart :: proc(t: ^testing.T) {
	sources := []Similarity_Source {
		{path = "src/kernel/sums.odin", text = similarity_test_file("kernel", similarity_test_procedure("kernel_sum"))},
		{path = "src/library/support/sums/sums.odin", text = similarity_test_file("sums", similarity_test_procedure("support_sum"))},
	}
	analysis := similarity_analyse(sources, "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	families := similarity_test_families(analysis, .Procedure)
	testing.expect_value(t, len(families), 1)
	if len(families) == 1 {
		testing.expect_value(t, families[0].category, Similarity_Category.Kept_Apart_By_The_Rules)
		testing.expect_value(t, families[0].home, "a contract package, by a decision")
	}
}

// Two procedures that differ by one field name: a blank that is not a
// parameter, so the family is a family of similar behaviour.
@(test)
similarity_field_name_is_not_a_parameter :: proc(t: ^testing.T) {
	first := similarity_test_procedure("first_field", extra = "\n\ttotal += shared_record.count")
	second := similarity_test_procedure("second_field", extra = "\n\ttotal += shared_record.length")
	sources := []Similarity_Source{{path = "src/processes/fields/main.odin", text = similarity_test_file("fields", first, second)}}
	analysis := similarity_analyse(sources, "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	families := similarity_test_families(analysis, .Procedure)
	testing.expect_value(t, len(families), 1)
	if len(families) != 1 {
		return
	}
	testing.expect_value(t, families[0].category, Similarity_Category.Similar_Behaviour)
	found := false
	for blank in families[0].template.blanks {
		found = found || blank.kind == .Not_A_Parameter
	}
	testing.expect(t, found, "the field name is a blank that is not a parameter")
}

// Two procedures that differ by one added statement: one child that only
// the second has, and the score 1 - (difference of the sizes) / (sum of
// the sizes).
@(test)
similarity_added_statement_score :: proc(t: ^testing.T) {
	first := similarity_test_procedure("shorter")
	second := similarity_test_procedure("longer", extra = "\n\tcount = limit")
	sources := []Similarity_Source{{path = "src/processes/added/main.odin", text = similarity_test_file("added", first, second)}}
	analysis := similarity_analyse(sources, "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	families := similarity_test_families(analysis, .Procedure)
	testing.expect_value(t, len(families), 1)
	if len(families) != 1 {
		return
	}
	family := families[0]
	shorter := analysis.pieces[family.template.members[0]].size
	longer := analysis.pieces[family.template.members[1]].size
	testing.expect_value(t, family.category, Similarity_Category.Similar_Behaviour)
	testing.expect_value(t, family.template.only_in_members[1], 1)
	testing.expect_value(t, family.template.matched, shorter)
	expected := 1 - f64(longer - shorter) / f64(shorter + longer)
	testing.expectf(t, abs(family.template.scores[1] - expected) < 1e-9, "the score is %f, and %f is expected", family.template.scores[1], expected)
}

// The runs of two equal procedures are inside the procedures: the family
// of the procedures holds them, and the report shows the procedures only.
@(test)
similarity_held_family_is_not_reported :: proc(t: ^testing.T) {
	sources := []Similarity_Source{{path = "src/processes/held/main.odin", text = similarity_test_file("held", similarity_test_procedure("first_held"), similarity_test_procedure("second_held", {"sum", "number", "item", "items", "bound"}))}}
	analysis := similarity_analyse(sources, "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	testing.expect(t, analysis.measures.families_held >= 1, "a family of runs is held")
	reported := 0
	for family in analysis.families {
		if family.reported {
			reported += 1
			testing.expect_value(t, family.kind, Similarity_Piece_Kind.Procedure)
		}
	}
	testing.expect_value(t, reported, 1)
}

// Two families that share nodes: the greedy selection counts the shared
// nodes once, so it ranks one of the two.
@(test)
similarity_greedy_selection_counts_shared_nodes_once :: proc(t: ^testing.T) {
	run, _ := strings.replace_all(SIMILARITY_TEST_RUN, "{inside}", "total = 1000", context.temp_allocator)
	equal := strings.concatenate({"proc(base: int) -> int {\n", run, "\treturn total + base\n}\n"}, context.temp_allocator)
	third := strings.concatenate({"third_user :: proc(base: int, extra: int) -> int {\n", SIMILARITY_TEST_OTHER_WORK, run, SIMILARITY_TEST_OTHER_WORK, "\treturn total - extra\n}\n"}, context.temp_allocator)
	text := similarity_test_file("greedy", strings.concatenate({"first_user :: ", equal}, context.temp_allocator), strings.concatenate({"second_user :: ", equal}, context.temp_allocator), third)
	analysis := similarity_analyse([]Similarity_Source{{path = "src/processes/greedy/main.odin", text = text}}, "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	ranked := 0
	saved: i64 = 0
	for family in analysis.families {
		if family.rank > 0 {
			ranked += 1
			saved += family.saved_nodes
		}
	}
	testing.expect_value(t, ranked, 1)
	testing.expect_value(t, analysis.measures.saved_nodes, saved)
	testing.expect_value(t, len(similarity_test_families(analysis, .Procedure)) + len(similarity_test_families(analysis, .Run)), 2)
}

// A line of the kept list takes its family out of the ranking and keeps
// it in the measures; a line that names no family is stale.
@(test)
similarity_kept_list :: proc(t: ^testing.T) {
	sources := []Similarity_Source {
		{path = "src/library/support/first_package/first.odin", text = similarity_test_file("first_package", similarity_test_procedure("first_sum"))},
		{path = "src/library/support/second_package/second.odin", text = similarity_test_file("second_package", similarity_test_procedure("second_sum"))},
	}
	first_run := similarity_analyse(sources, "", context.temp_allocator)
	families := similarity_test_families(first_run, .Procedure)
	similarity_analysis_destroy(first_run)
	testing.expect_value(t, len(families), 1)
	if len(families) != 1 {
		return
	}
	kept_text := fmt.tprintf("%016x two copies on purpose\n0000000000000000 a family that is gone\n", families[0].template_hash)
	analysis := similarity_analyse(sources, kept_text, context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	kept := similarity_test_families(analysis, .Procedure)
	testing.expect_value(t, len(kept), 1)
	if len(kept) == 1 {
		testing.expect(t, kept[0].kept, "the family is kept")
		testing.expect_value(t, kept[0].kept_reason, "two copies on purpose")
		testing.expect_value(t, kept[0].rank, 0)
	}
	testing.expect(t, analysis.measures.any_family_nodes[.System] > 0, "the kept family stays in the measures")
	testing.expect_value(t, len(analysis.kept), 2)
	if len(analysis.kept) == 2 {
		testing.expect(t, analysis.kept[0].used, "the first line names the family")
		testing.expect(t, !analysis.kept[1].used, "the second line is stale")
	}
	testing.expect(t, strings.contains(similarity_report(analysis, nil, -1), "names no family"), "the report lists the stale line")
}

// The same procedure in x_linux.odin and x_other.odin is a platform variant.
@(test)
similarity_platform_variant :: proc(t: ^testing.T) {
	sources := []Similarity_Source {
		{path = "src/library/support/watch/watch_linux.odin", text = similarity_test_file("watch", similarity_test_procedure("watch_sum"))},
		{path = "src/library/support/watch/watch_other.odin", text = similarity_test_file("watch", similarity_test_procedure("watch_sum"))},
	}
	analysis := similarity_analyse(sources, "", context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	families := similarity_test_families(analysis, .Procedure)
	testing.expect_value(t, len(families), 1)
	if len(families) == 1 {
		testing.expect_value(t, families[0].category, Similarity_Category.Platform_Variant)
	}
}

// The filter of the near pairs drops no pair whose bound reaches the
// threshold: the filtered pairs hold each such pair of all the pairs.
@(test)
similarity_near_filter_drops_no_pair :: proc(t: ^testing.T) {
	bodies := [?]string {
		similarity_test_procedure("plain"),
		similarity_test_procedure("with_literal", extra = "\n\ttotal += 1000"),
		similarity_test_procedure("with_field", extra = "\n\ttotal += shared_record.count"),
		similarity_test_procedure("with_statement", extra = "\n\tcount = limit"),
		similarity_test_procedure("with_two", extra = "\n\ttotal += 7\n\tcount += 7"),
		strings.concatenate({"other_work :: proc(extra: int) -> int {\n", SIMILARITY_TEST_OTHER_WORK, SIMILARITY_TEST_OTHER_WORK, "\treturn first_other\n}\n"}, context.temp_allocator),
	}
	analysis := similarity_analysis_make([]Similarity_Source{{path = "src/processes/filter/main.odin", text = similarity_test_file("filter", ..bodies[:])}}, context.temp_allocator)
	defer similarity_analysis_destroy(analysis)
	similarity_add_procedure_pieces(analysis)
	near := make([dynamic]i32, context.temp_allocator)
	for _, index in analysis.pieces {
		append(&near, i32(index))
	}
	testing.expect(t, len(near) >= 6, "each procedure is a piece")
	filtered, _ := similarity_near_pairs(analysis.nodes, analysis.pieces[:], near[:], SIMILARITY_COVERAGE_LEAST, context.temp_allocator)
	for first in 0 ..< len(near) {
		for other in first + 1 ..< len(near) {
			matched, _ := similarity_upper_matched(analysis.nodes, analysis.pieces[:], near[first], near[other], context.temp_allocator)
			score := similarity_score(matched, analysis.pieces[near[first]].size, analysis.pieces[near[other]].size)
			if score < SIMILARITY_COVERAGE_LEAST {
				continue
			}
			found := false
			for pair in filtered {
				found = found || (pair[0] == near[first] && pair[1] == near[other])
			}
			testing.expectf(t, found, "the pair %d %d with the score %f is in the filtered pairs", near[first], near[other], score)
		}
	}
}

// Two runs on the same sources give the same bytes of the report and of
// the two tables.
@(test)
similarity_output_is_reproducible :: proc(t: ^testing.T) {
	sources := []Similarity_Source {
		{path = "src/library/support/first_package/first.odin", text = similarity_test_file("first_package", similarity_test_procedure("first_sum"), similarity_test_procedure("first_limit", extra = "\n\ttotal += 1000"))},
		{path = "src/library/support/second_package/second.odin", text = similarity_test_file("second_package", similarity_test_procedure("second_sum", {"sum", "number", "item", "items", "bound"}), similarity_test_procedure("second_limit", extra = "\n\ttotal += 2000"))},
		{path = "src/processes/runs/main.odin", text = similarity_test_run_sources("total = 1000")[0].text},
	}
	outputs: [2][3]string
	for &output in outputs {
		analysis := similarity_analyse(sources, "", context.temp_allocator)
		output[0] = strings.clone(similarity_report(analysis, nil, -1), context.temp_allocator)
		output[1] = strings.clone(similarity_families_table(analysis), context.temp_allocator)
		output[2] = strings.clone(similarity_members_table(analysis), context.temp_allocator)
		similarity_analysis_destroy(analysis)
	}
	for index in 0 ..< 3 {
		testing.expect(t, outputs[0][index] == outputs[1][index], "two runs give the same bytes")
	}
	testing.expect(t, strings.contains(outputs[0][0], "## The ranked families"), "the report ranks the families")
}
