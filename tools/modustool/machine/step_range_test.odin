package machine

import "core:strings"
import "core:testing"

// The words of a step range: each refusal first, at its edges, then the
// forms that the command takes.
@(test)
a_step_range_refuses_what_names_no_steps :: proc(t: ^testing.T) {
	refused := [][]string {
		{},
		{"1"},
		{"1", "to"},
		{"1", "until", "5"},
		{"0", "to", "5"},
		{"-1", "to", "5"},
		{"6", "to", "5"},
		{"a", "to", "5"},
		{"1", "to", "five"},
		{"1.5", "to", "5"},
		{"9223372036854775808", "to", "9223372036854775809"},
		{"10", "to", "20", "with", "10", "to", "12"},
		{"10", "to", "20", "with", "5", "to", "25"},
		{"10", "to", "20", "with", "5", "to", "3"},
		{"10", "to", "20", "with", "0", "to", "3"},
		{"10", "to", "20", "with", "5"},
		{"10", "to", "20", "of"},
		{"10", "to", "20", "of", ""},
		{"10", "to", "20", "of", "a", "of", "b"},
		{"10", "to", "20", "and", "5"},
	}
	for words in refused {
		_, problem := step_range_parse(words, context.temp_allocator)
		testing.expectf(t, problem != "", "the words %v are refused", words)
	}
	range, problem := step_range_parse({"10", "to", "20", "with", "1", "to", "3", "of", "test_output_tpm_key_4", "with", "9", "to", "9"}, context.temp_allocator)
	testing.expect_value(t, problem, "")
	testing.expect(t, range.given, "the range is given")
	testing.expect_value(t, range.span, Step_Span{10, 20})
	testing.expect_value(t, range.machine, "test_output_tpm_key_4")
	testing.expect_value(t, len(range.setup), 2)
	one, one_problem := step_range_parse({"1", "to", "1"}, context.temp_allocator)
	testing.expect_value(t, one_problem, "")
	testing.expect_value(t, one.span, Step_Span{1, 1})
}

@(test)
the_arguments_of_test_take_a_step_range_after_a_part :: proc(t: ^testing.T) {
	testing.expect_value(t, test_arguments_problem({"main_console_and_desktop", "steps", "1270", "to", "1280"}), "")
	testing.expect(t, test_arguments_problem({"main_console_and_desktop", "steps", "1280", "to", "1270"}) != "", "a reversed range is refused before the build")
	testing.expect(t, test_arguments_problem({"no_such_part", "steps", "1", "to", "2"}) != "", "a range of a part that does not exist is refused")
	testing.expect(t, test_arguments_problem({"main_console_and_desktop", "steps"}) != "", "a range with no numbers is refused")
	range, given := test_arguments_give_step_range({"main_console_and_desktop", "steps", "3", "to", "4"}, context.temp_allocator)
	testing.expect(t, given && range.span == Step_Span{3, 4}, "the range is given")
	_, from_given := test_arguments_give_step_range({"main_console_and_desktop", "from", "folder"}, context.temp_allocator)
	testing.expect(t, !from_given, "a folder of test inputs is no range")
	_, inputs_given := test_arguments_give_inputs({"main_console_and_desktop", "steps", "1", "to", "2"})
	testing.expect(t, !inputs_given, "a range of three words is no folder of test inputs")
}

// The selection: the boot steps are the waits before the first act, the
// setup steps and the range follow in the order of the scenario, and a
// step is never taken twice.
@(test)
a_step_range_selects_the_boot_the_setup_and_the_range :: proc(t: ^testing.T) {
	steps := []Step {
		{kind = .Wait, text = "kernel: ok"}, // 1
		{kind = .Wait, text = "root: ok"}, // 2
		{kind = .Launch, text = "console"}, // 3
		{kind = .Wait, text = "compositor: surface console"}, // 4
		{kind = .Type, text = "1 + 1"}, // 5
		{kind = .Wait, text = "[console] 2"}, // 6
		{kind = .Type, text = "2 + 2"}, // 7
		{kind = .Wait, text = "[console] 4"}, // 8
	}
	range, _ := step_range_parse({"7", "to", "8", "with", "3", "to", "4"}, context.temp_allocator)
	selection, problem := step_range_select(steps, range)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, selection.boot, 2)
	testing.expect_value(t, selection.setup, 2)
	testing.expect(t, slice_equal(selection.places, {0, 1, 2, 3, 6, 7}), "the places are the boot, the setup and the range")
	// A range inside the boot steps takes the boot steps before it only.
	early, _ := step_range_parse({"2", "to", "3"}, context.temp_allocator)
	early_selection, _ := step_range_select(steps, early)
	testing.expect_value(t, early_selection.boot, 1)
	testing.expect(t, slice_equal(early_selection.places, {0, 1, 2}), "a range in the boot")
	// The last step, and one past it.
	last, _ := step_range_parse({"8", "to", "8"}, context.temp_allocator)
	_, last_problem := step_range_select(steps, last)
	testing.expect_value(t, last_problem, "")
	past, _ := step_range_parse({"8", "to", "9"}, context.temp_allocator)
	_, past_problem := step_range_select(steps, past)
	testing.expect(t, strings.contains(past_problem, "past the 8 steps"), "a range past the steps is refused")
	setup_past, _ := step_range_parse({"8", "to", "8", "with", "1", "to", "7"}, context.temp_allocator)
	_, setup_past_problem := step_range_select(steps[:6], setup_past)
	testing.expect(t, setup_past_problem != "", "a setup past the steps is refused")
}

// A selection that names a value that no selected step gives is refused
// before the machine starts, with the step that gives it.
@(test)
a_step_range_refuses_a_mark_or_a_call_with_no_setup :: proc(t: ^testing.T) {
	steps := []Step {
		{kind = .Wait, text = "kernel: ok"}, // 1
		{kind = .Launch, text = "remote"}, // 2
		{kind = .Remote_Key, text = "remote: the key "}, // 3
		{kind = .Generation, text = "storage: generation "}, // 4
		{kind = .Call, text = "storage.stores()", expected = "{generation+1}"}, // 5
	}
	range, _ := step_range_parse({"5", "to", "5"}, context.temp_allocator)
	selection, _ := step_range_select(steps, range)
	problem := step_range_setup_problem(steps, selection)
	testing.expect(t, strings.contains(problem, "the step 5 names {generation") && strings.contains(problem, "`with 4 to 4`"), problem)
	with_generation, _ := step_range_parse({"5", "to", "5", "with", "4", "to", "4"}, context.temp_allocator)
	selection, _ = step_range_select(steps, with_generation)
	problem = step_range_setup_problem(steps, selection)
	testing.expect(t, strings.contains(problem, "the step 5 (Call") && strings.contains(problem, "`with 3 to 3`"), problem)
	whole, _ := step_range_parse({"5", "to", "5", "with", "2", "to", "4"}, context.temp_allocator)
	selection, _ = step_range_select(steps, whole)
	testing.expect_value(t, step_range_setup_problem(steps, selection), "")
	// A key before a start of remote again is the key of the start before.
	again := []Step{{kind = .Remote_Key, text = "remote: the key "}, {kind = .Launch, text = "remote"}, {kind = .Call, text = "monitor.processes()"}}
	again_range, _ := step_range_parse({"3", "to", "3", "with", "1", "to", "2"}, context.temp_allocator)
	again_selection, _ := step_range_select(again, again_range)
	testing.expect(t, step_range_setup_problem(again, again_selection) != "", "a call after a start again with the key before is refused")
}

@(test)
the_name_of_a_machine_is_the_name_of_its_log :: proc(t: ^testing.T) {
	testing.expect_value(t, machine_name_of_log("build/test_output_tpm_key_4.txt"), "test_output_tpm_key_4")
	testing.expect_value(t, machine_name_of_log("test_output.txt"), "test_output")
	testing.expect_value(t, machine_name_of_log("build/test_output"), "test_output")
	testing.expect_value(t, step_place(nil, 4), 4)
	testing.expect_value(t, step_place({2, 9}, 1), 9)
}

@(private = "file")
slice_equal :: proc(a, b: []int) -> bool {
	if len(a) != len(b) {
		return false
	}
	for value, index in a {
		if b[index] != value {
			return false
		}
	}
	return true
}
