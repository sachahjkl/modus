package checks

import "core:testing"

// A module that converts words to the two stop enums in each form, and
// calls the two stop operations raw: each one is refused, the conversion
// compared with a member too.
@(private = "file")
STOP_WORDS_REFUSED :: `package user

import op "modus:contract/operation"
import "modus:support/system"

kept :: proc "contextless" (word: u64) -> op.Stop_Cause {
	return op.Stop_Cause(word)
}

compared :: proc "contextless" (word: u64) -> bool {
	return op.Stop_Outcome(word) == .Done
}

cast_forms :: proc "contextless" (word: u32, words: [2]u32) -> (op.Stop_Outcome, [2]op.Stop_Cause) {
	return cast(op.Stop_Outcome)word, transmute([2]op.Stop_Cause)words
}

raw :: proc "contextless" (child: system.Handle) {
	system.call(.Process_Stop, u64(child), 0)
	system.call((.Process_State), u64(child))
	system.call_with_error(nil, op.Operation.Process_Stop, u64(child), 0)
}
`

// The forms that stay: the borders, the members, the words of a member, the
// type of the state, and the other operations of the library.
@(private = "file")
STOP_WORDS_ACCEPTED :: `package user

import op "modus:contract/operation"
import "modus:support/system"

read :: proc "contextless" (child: system.Handle, word: u64) -> bool {
	state, cause, outcome := system.process_state(child)
	alone, _ := op.stop_outcome_of_word(word)
	word_of_member := u64(op.Stop_Cause.Itself)
	texts := op.STOP_OUTCOME_TEXTS
	system.call(.Memory_Size, u64(child))
	other_state := op.Process_State(word) == .Stopped
	return state == .Stopped && cause == .Itself && outcome == .Done && alone == .Done && word_of_member != 0 && len(texts) > 0 && other_state
}
`

// The home packages: the contract package operation converts in its
// borders, and the support package system calls the two operations.
@(private = "file")
STOP_WORDS_HOME_CONTRACT :: `package operation

Stop_Outcome :: enum u32 {
	None = 0,
	Done = 1,
}

border :: proc "contextless" (word: u32) -> Stop_Outcome {
	return Stop_Outcome(word)
}
`

@(private = "file")
STOP_WORDS_HOME_SYSTEM :: `package system

import op "modus:contract/operation"
import other "modus:support/system"

state :: proc "contextless" (process: u64) {
	other.call(.Process_State, process)
}
`

@(test)
a_conversion_and_a_raw_call_of_a_stop_are_refused :: proc(t: ^testing.T) {
	sources := []Export_Source{{path = "src/modules/tests/user/main.odin", text = STOP_WORDS_REFUSED}}
	faults, ok := stop_word_faults_of_sources(sources)
	testing.expect(t, ok)
	conversions, raw_calls := 0, 0
	for fault in faults {
		switch fault.kind {
		case .Conversion:
			conversions += 1
		case .Raw_Call:
			raw_calls += 1
		}
	}
	// op.Stop_Cause(word), op.Stop_Outcome(word) == .Done, cast, transmute.
	testing.expect_value(t, conversions, 4)
	// The implicit member, the member in parentheses, Operation.Process_Stop.
	testing.expect_value(t, raw_calls, 3)
}

@(test)
a_source_that_does_not_parse_stops_the_check_of_the_stop_words :: proc(t: ^testing.T) {
	sources := []Export_Source{{path = "src/modules/tests/user/main.odin", text = "package user\n\nbroken :: proc( {\n"}}
	_, ok := stop_word_faults_of_sources(sources)
	testing.expect(t, !ok)
}

@(test)
the_borders_and_the_home_packages_are_accepted :: proc(t: ^testing.T) {
	sources := []Export_Source {
		{path = "src/modules/tests/user/main.odin", text = STOP_WORDS_ACCEPTED},
		{path = "src/library/contract/operation/stop.odin", text = STOP_WORDS_HOME_CONTRACT},
		{path = "src/library/support/system/stop.odin", text = STOP_WORDS_HOME_SYSTEM},
	}
	faults, ok := stop_word_faults_of_sources(sources)
	testing.expect(t, ok)
	for fault in faults {
		testing.expectf(t, false, "%s:%d: %v of %s is refused", fault.file, fault.line, fault.kind, fault.name)
	}
}
