package modustool

import "core:testing"
import "modus:contract/operation_sequence"

// The table of the address parameters refuses a parameter with no row, a
// parameter with two rows, and a row that names no address parameter;
// the table of the tool is whole.
@(test)
the_table_of_the_address_parameters_has_one_row_for_each_address :: proc(t: ^testing.T) {
	whole := fuzz_address_parameters
	without_last := whole[:len(whole) - 1]
	testing.expect(t, fuzz_address_parameters_problem(without_last) != "", "a table with no row for the last address parameter is taken")
	twice := make([dynamic]Fuzz_Address_Parameter, context.temp_allocator)
	append(&twice, ..whole[:])
	append(&twice, whole[0])
	testing.expect(t, fuzz_address_parameters_problem(twice[:]) != "", "a table with two rows for one parameter is taken")
	not_address := make([dynamic]Fuzz_Address_Parameter, context.temp_allocator)
	append(&not_address, ..whole[:])
	append(&not_address, Fuzz_Address_Parameter{operation = .Memory_Create, parameter = 0})
	testing.expect(t, fuzz_address_parameters_problem(not_address[:]) != "", "a row on a handle parameter is taken")
	out_of_range := make([dynamic]Fuzz_Address_Parameter, context.temp_allocator)
	append(&out_of_range, ..whole[:])
	append(&out_of_range, Fuzz_Address_Parameter{operation = .Log, parameter = operation_sequence.ARGUMENTS})
	testing.expect(t, fuzz_address_parameters_problem(out_of_range[:]) != "", "a row past the parameters is taken")
	append(&out_of_range, Fuzz_Address_Parameter{operation = .Log, parameter = -1})
	testing.expect(t, fuzz_address_parameters_problem(out_of_range[len(out_of_range) - 1:]) != "", "a row before the parameters is taken")
	testing.expect_value(t, fuzz_address_parameters_problem(whole[:]), "")
}

// A reference with no enumeration Operation, or with a member that it
// does not name, stops the start; the reference of the contract gives the
// kind of each result that names one.
@(test)
the_result_kinds_come_from_the_reference_comments :: proc(t: ^testing.T) {
	_, no_enumeration := fuzz_operation_results_read("package operation\n")
	testing.expect(t, !no_enumeration, "a reference with no enumeration Operation is taken")
	short := "Operation :: enum u32 {\n\tNone = 0,\n\tLog = 1, // (log, address, length, level, channel, channel, runs).\n}\n"
	_, short_ok := fuzz_operation_results_read(short)
	testing.expect(t, !short_ok, "a reference that names two operations is taken")
	results, ok := fuzz_operation_results_read(fuzz_operation_reference)
	testing.expect(t, ok)
	testing.expect_value(t, results[.Memory_Create], Fuzz_Operation_Result{handle = true, kind = .Memory})
	testing.expect_value(t, results[.Program_Create], Fuzz_Operation_Result{handle = true, kind = .Program})
	testing.expect_value(t, results[.Thread_Create], Fuzz_Operation_Result{handle = true, kind = .Thread})
	testing.expect_value(t, results[.Budget_Create], Fuzz_Operation_Result{handle = true, kind = .Budget})
	testing.expect_value(t, results[.Handle_Give], Fuzz_Operation_Result{handle = true})
	testing.expect_value(t, results[.Memory_Map], Fuzz_Operation_Result{address = true})
	testing.expect_value(t, results[.Memory_Size], Fuzz_Operation_Result{})
	testing.expect_value(t, results[.Memory_Physical], Fuzz_Operation_Result{})
	testing.expect_value(t, fuzz_operation_result_of("handle, address, value"), Fuzz_Operation_Result{handle = true})
	testing.expect_value(t, fuzz_operation_result_of(""), Fuzz_Operation_Result{})
}

// For each choice input, the generator builds a sequence that check
// accepts and reads back whole: the empty input, inputs of each single
// byte, inputs of all ones (the most steps), and inputs of a fixed
// generator of numbers.
@(test)
the_generator_gives_a_sequence_that_check_accepts :: proc(t: ^testing.T) {
	if !testing.expect(t, fuzz_operation_sequence_start(), "the grammar of the generator does not start") {
		return
	}
	expect_accepted :: proc(t: ^testing.T, input: []u8, loc := #caller_location) {
		verdict := fuzz_operation_sequence_generated_execute(input)
		testing.expectf(t, verdict.oracle == .None, "%v: %s", verdict.oracle, verdict.text, loc = loc)
	}
	expect_accepted(t, nil)
	for value in 0 ..= 255 {
		single := [1]u8{u8(value)}
		expect_accepted(t, single[:])
	}
	// The areas take about 4 KiB of choices, and each step at most about
	// 70 bytes.
	ones := make([]u8, 16 << 10, context.temp_allocator)
	for &item in ones {
		item = 0xFF
	}
	expect_accepted(t, ones)
	choices := fuzz_choices_of(ones)
	sequence := new(operation_sequence.Sequence, context.temp_allocator)
	fuzz_operation_sequence_generate(&choices, sequence)
	testing.expect_value(t, sequence.step_count, operation_sequence.STEPS_MOST)
	testing.expect_value(t, sequence.area_count, operation_sequence.AREAS_MOST)

	random := Fuzz_Random{state = 1}
	input := make([]u8, 4 << 10, context.temp_allocator)
	for _ in 0 ..< 2_000 {
		length := fuzz_random_below(&random, len(input) + 1)
		for &item in input[:length] {
			item = u8(fuzz_random_next(&random))
		}
		expect_accepted(t, input[:length])
	}
}

// Each seed of the raw target passes its oracles.
@(test)
the_seeds_of_the_operation_sequence_pass :: proc(t: ^testing.T) {
	if !testing.expect(t, fuzz_operation_sequence_start(), "the grammar of the generator does not start") {
		return
	}
	seeds := make([dynamic][]u8, context.temp_allocator)
	context.allocator = context.temp_allocator
	fuzz_operation_sequence_seeds(&seeds)
	testing.expect(t, len(seeds) > 3)
	for seed, index in seeds {
		verdict := fuzz_operation_sequence_execute(seed)
		testing.expectf(t, verdict.oracle == .None, "seed %d: %v: %s", index, verdict.oracle, verdict.text)
	}
}
