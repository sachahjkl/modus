package checks

import "core:testing"
import "modustool:foundation"

// A module that skips each border of a stop. Each form below is refused:
// a conversion to a stop enum, compared with a member too, through an
// alias of the file, a chain of aliases, a `distinct` type, a `#type`, and
// an alias inside a procedure; a stop operation named by its member,
// implicit, in parentheses, through `Operation`, kept in a variable, given
// to a typed variable, and in the kind of a command record, through an
// alias too; a word converted to `Operation`; and a stop with the outcome
// None.
@(private = "file")
STOP_WORDS_REFUSED :: `package user

import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:support/system"

Outcome :: op.Stop_Outcome
Chained :: Outcome
Distinct_Outcome :: distinct op.Stop_Outcome
Typed_Cause :: #type op.Stop_Cause
Kernel_Operation :: op.Operation

kept :: proc "contextless" (word: u64) -> op.Stop_Cause {
	return op.Stop_Cause(word)
}

compared :: proc "contextless" (word: u64) -> bool {
	return op.Stop_Outcome(word) == .Done
}

cast_forms :: proc "contextless" (word: u32, words: [2]u32) -> (op.Stop_Outcome, [2]op.Stop_Cause) {
	return cast(op.Stop_Outcome)word, transmute([2]op.Stop_Cause)words
}

through_aliases :: proc "contextless" (word: u32) -> (Outcome, Chained, Distinct_Outcome, Typed_Cause) {
	Local :: op.Stop_Outcome
	_ = Local(word)
	return Outcome(word), Chained(word), Distinct_Outcome(word), Typed_Cause(word)
}

raw :: proc "contextless" (child: system.Handle) {
	system.call(.Process_Stop, u64(child), 0)
	system.call((.Process_State), u64(child))
	system.call_with_error(nil, op.Operation.Process_Stop, u64(child), 0)
	kept_operation := op.Operation.Process_State
	system.call(kept_operation, u64(child))
	system.call(op.Operation(8), u64(child), 0)
	system.call(Kernel_Operation(9), u64(child))
	command := ring.Record{kind = u32(Kernel_Operation.Process_Stop), values = {0 = u64(child)}}
	commands := [1]ring.Record{command}
	completions: [1]ring.Record
	system.commands_call(commands[:], completions[:])
	typed_operation: op.Operation = .Process_Stop
	system.call(typed_operation, u64(child), 0)
}

stop_with_none :: proc "contextless" () {
	system.stop(.None)
}

stop_with_none_of_an_alias :: proc "contextless" () {
	system.stop(Outcome.None)
}
`

// The forms that stay: the borders, the members, the words of a member, the
// type of the state, a stop with an outcome, and the other operations.
@(private = "file")
STOP_WORDS_ACCEPTED :: `package user

import op "modus:contract/operation"
import "modus:support/system"

DONE :: op.Stop_Outcome.Done

read :: proc "contextless" (child: system.Handle, word: u64) -> bool {
	state, cause, outcome := system.process_state(child)
	alone, _ := op.stop_outcome_of_word(word)
	word_of_member := u64(op.Stop_Cause.Itself)
	texts := op.STOP_OUTCOME_TEXTS
	system.call(.Memory_Size, u64(child))
	system.call(op.Operation.Memory_Size, u64(child))
	other_state := op.Process_State(word) == .Stopped
	system.process_stop(child)
	return state == .Stopped && cause == .Itself && outcome == DONE && alone == .Done && word_of_member != 0 && len(texts) > 0 && other_state
}

end :: proc "contextless" () {
	system.stop(.Done)
}
`

// The homes: the contract package operation converts in its borders, the
// support package system calls the two operations, the kernel dispatches
// them, and the tool names them in its fuzzer.
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
	other.call(op.Operation.Process_Stop, process, 0)
	other.stop(.None)
}
`

@(private = "file")
STOP_WORDS_HOME_KERNEL :: `package kernel

import op "modus:contract/operation"

dispatch :: proc "contextless" (word: u32) -> bool {
	switch op.Operation(word) {
	case .Process_Stop, .Process_State:
		return true
	}
	return false
}
`

@(private = "file")
STOP_WORDS_HOME_TOOL :: `package fuzz

import "modustool:operation"

parameters := [1]Parameter_Of{{operation = .Process_State, parameter = 1}}
`

@(test)
each_form_that_skips_a_stop_border_is_refused :: proc(t: ^testing.T) {
	sources := []Export_Source{{path = "src/modules/tests/user/main.odin", text = STOP_WORDS_REFUSED}}
	faults, ok := stop_word_faults_of_sources(sources)
	testing.expect(t, ok)
	counts: [Stop_Word_Fault_Kind]int
	for fault in faults {
		counts[fault.kind] += 1
	}
	// op.Stop_Cause(word), op.Stop_Outcome(word) == .Done, cast, transmute,
	// Local, Outcome, Chained, Distinct_Outcome, Typed_Cause.
	testing.expect_value(t, counts[.Conversion], 9)
	// .Process_Stop, (.Process_State), op.Operation.Process_Stop,
	// op.Operation.Process_State, Kernel_Operation.Process_Stop, and the
	// .Process_Stop of the typed variable.
	testing.expect_value(t, counts[.Operation_Named], 6)
	// op.Operation(8), Kernel_Operation(9).
	testing.expect_value(t, counts[.Operation_Conversion], 2)
	// .None, Outcome.None.
	testing.expect_value(t, counts[.Stop_With_No_Outcome], 2)
}

@(test)
a_source_that_does_not_parse_stops_the_check_of_the_stop_words :: proc(t: ^testing.T) {
	sources := []Export_Source{{path = "src/modules/tests/user/main.odin", text = "package user\n\nbroken :: proc( {\n"}}
	_, ok := stop_word_faults_of_sources(sources)
	testing.expect(t, !ok)
}

// An exception holds its faults only with its count: one mention more in
// its file refuses the row and each mention, and the count that it names
// holds them, the last case.
@(test)
an_exception_of_the_stop_words_holds_its_count :: proc(t: ^testing.T) {
	file := foundation.DEMONSTRATION_MODULE_SOURCES + "address_space/main.odin"
	exceptions := []Stop_Word_Exception{{file, .Operation_Named, 1, "a test"}}
	one := "package address_space\n\nimport op \"modus:contract/operation\"\n\nword := u32(op.Operation.Process_Stop)\n"
	two := "package address_space\n\nimport op \"modus:contract/operation\"\n\nword := u32(op.Operation.Process_Stop)\nother := u32(op.Operation.Process_State)\n"
	faults, ok := stop_word_faults_of_sources([]Export_Source{{path = file, text = two}})
	testing.expect(t, ok)
	refused, stale := stop_words_judged(faults, exceptions)
	testing.expect_value(t, len(refused), 2)
	if testing.expect_value(t, len(stale), 1) {
		testing.expect_value(t, stale[0].found, 2)
	}
	faults, ok = stop_word_faults_of_sources([]Export_Source{{path = file, text = one}})
	testing.expect(t, ok)
	refused, stale = stop_words_judged(faults, exceptions)
	testing.expect_value(t, len(refused), 0)
	testing.expect_value(t, len(stale), 0)
}

@(test)
the_borders_and_the_homes_are_accepted :: proc(t: ^testing.T) {
	sources := []Export_Source {
		{path = "src/modules/tests/user/main.odin", text = STOP_WORDS_ACCEPTED},
		{path = "src/library/contract/operation/stop.odin", text = STOP_WORDS_HOME_CONTRACT},
		{path = "src/library/support/system/stop.odin", text = STOP_WORDS_HOME_SYSTEM},
		{path = "src/kernel/dispatch.odin", text = STOP_WORDS_HOME_KERNEL},
		{path = foundation.TOOL_SOURCE_FOLDER + "/fuzz/parameters.odin", text = STOP_WORDS_HOME_TOOL},
	}
	faults, ok := stop_word_faults_of_sources(sources)
	testing.expect(t, ok)
	for fault in faults {
		testing.expectf(t, false, "%s:%d: %v of %s is refused", fault.file, fault.line, fault.kind, fault.name)
	}
}
