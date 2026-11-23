package checks

import "core:testing"

// Each binding that breaks the rule comes first: an error record with an
// i64 result, an error record with no result, an outcome with no
// require_results, an outcome alone with no require_results. A binding with
// the attribute and the outcome first, a binding of an export that cannot
// fail, and a procedure outside a foreign block are the last cases, which
// the check takes.
@(test)
a_binding_of_an_export_that_can_fail_gives_the_outcome_and_forces_its_read :: proc(t: ^testing.T) {
	source := `package caller

import "modus:contract/call_outcome"
import "modus:contract/errors"

foreign _ {
	sign_form :: proc "c" (value: i64, error: ^errors.Error_Record) -> i64 ---
	no_result :: proc "c" (value: i64, error: ^errors.Error_Record) ---
	dropped :: proc "c" (value: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) ---
	dropped_alone :: proc "c" (error: ^errors.Error_Record) -> call_outcome.Call_Outcome ---
	@(require_results)
	kept :: proc "c" (value: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) ---
	total :: proc "c" (value: i64) -> i64 ---
}

outside :: proc "c" (value: i64, error: ^errors.Error_Record) -> i64 {
	return value
}
`
	found := make([dynamic]Outcome_Binding_Fault, context.temp_allocator)
	count, ok := outcome_binding_faults_of_source("caller.odin", source, &found)
	testing.expect(t, ok)
	testing.expect_value(t, count, 5)
	testing.expect_value(t, len(found), 4)
	if len(found) != 4 {
		return
	}
	testing.expect_value(t, found[0].binding, "sign_form")
	testing.expect_value(t, found[0].reason, Outcome_Binding_Reason.Error_Record_Without_Outcome)
	testing.expect_value(t, found[1].binding, "no_result")
	testing.expect_value(t, found[1].reason, Outcome_Binding_Reason.Error_Record_Without_Outcome)
	testing.expect_value(t, found[2].binding, "dropped")
	testing.expect_value(t, found[2].reason, Outcome_Binding_Reason.Outcome_Without_Required_Read)
	testing.expect_value(t, found[3].binding, "dropped_alone")
	testing.expect_value(t, found[3].reason, Outcome_Binding_Reason.Outcome_Without_Required_Read)
}

// A source that the parser refuses is a failure of the check, never a
// file with no binding.
@(test)
a_source_that_does_not_parse_fails_the_check :: proc(t: ^testing.T) {
	found := make([dynamic]Outcome_Binding_Fault, context.temp_allocator)
	_, ok := outcome_binding_faults_of_source("broken.odin", "package broken\n\nforeign _ {\n\tbroken :: proc \"c\" (\n", &found)
	testing.expect(t, !ok)
}

// The rule holds in the sources of the repository. The count of the files
// proves that the tree was read.
@(test)
outcome_bindings_of_the_repository :: proc(t: ^testing.T) {
	found, file_count, binding_count, ok := outcome_binding_faults_of_tree("")
	testing.expect(t, ok)
	testing.expect(t, file_count > 100)
	testing.expect(t, binding_count > 0)
	for item in found {
		testing.expectf(t, false, "%s:%d: the binding %s breaks the rule: %v", item.file, item.line, item.binding, item.reason)
	}
}
