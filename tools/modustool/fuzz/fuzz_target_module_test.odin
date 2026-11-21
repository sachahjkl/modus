package fuzz

import "core:testing"
import "modus:contract/module"

// The seed of the check whose run found a module that the generator built
// by the rules and that validate refused: a place of a record stream over
// another write of a loader. The run of the check follows the edges of
// its instrumented build, so a host test cannot replay that one input from
// the seed; it draws inputs of the generator from the seed instead.
FUZZ_MODULE_PLACES_SEED :: 11282785145277346468

// The inputs that the test draws, each of the size of the input of that
// finding before its minimization.
FUZZ_MODULE_PLACES_INPUTS :: 20_000
FUZZ_MODULE_PLACES_INPUT_SIZE :: 40

// Each module that the generator builds by the rules from the inputs of
// the seed passes validate, keeps the rules of its record streams, and
// gives no finding to its readers: no place of a record stream meets a
// import slot, a rebase location or the own-hash place.
@(test)
the_generator_builds_places_that_validate_takes :: proc(t: ^testing.T) {
	random := Fuzz_Random{state = FUZZ_MODULE_PLACES_SEED}
	input: [FUZZ_MODULE_PLACES_INPUT_SIZE]u8
	for number in 0 ..< FUZZ_MODULE_PLACES_INPUTS {
		for &value in input {
			value = u8(fuzz_random_next(&random))
		}
		file, _ := fuzz_module_build(input[:], allow_break = false)
		error := module.validate(file)
		fault, place := module.record_streams_check(file)
		free_all(context.temp_allocator)
		if !testing.expectf(t, error == .None && fault == .None, "the input %d of the seed gives the error %v and the fault %v at the row %d", number, error, fault, place) {
			return
		}
	}
	for number in 0 ..< FUZZ_MODULE_PLACES_INPUTS / 10 {
		for &value in input {
			value = u8(fuzz_random_next(&random))
		}
		verdict := fuzz_module_generated_execute(input[:])
		passed := testing.expectf(t, verdict.oracle == .None, "the input %d of the seed gives a finding: %s", number, verdict.text)
		free_all(context.temp_allocator)
		if !passed {
			return
		}
	}
}
