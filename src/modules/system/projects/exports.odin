// The exports of the projects service that act for the principal of the
// caller (src/md/features/declarations.md, "Projects").
package projects_service

import "base:intrinsics"
import "internal:projects/projects_core"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import pr "modus:contract/plans_recipes"
import "modus:contract/value_kinds"
import "modus:disk_process"
import "modus:system"

// The bytes of the evaluation of a project.lex that load takes.
PROJECT_EVALUATION_BYTES_MOST :: projects_core.MAX_PROJECT_EVALUATION_BYTES

// The failures of the exports of this file, each with its error record:
// - Grant_Or_Right_Missing: No_Grant, Connection (the call came through no
//   connection), or No_Grant, Acts_For_Principal (the caller does not act
//   for its principal).
// - Wrong_State: State, Requests: the service has not started its tables.
// - The outcome of a refusal of the project or of its pins
//   (project_refusal_fail): the value found is the Project_Refusal.

// The loaded projects.
loaded_projects: projects_core.Loaded_Projects

// The parts of the call, copied once out of the call region.
copied_project_name: [pr.MAX_ENTRY_NAME_BYTES]u8
copied_input_name: [pr.MAX_ENTRY_NAME_BYTES]u8
copied_evaluation: [PROJECT_EVALUATION_BYTES_MOST]u8
copied_update_pins: [pr.MAX_PINS_LEX_BYTES]u8
copied_target: pr.Pin_Target
old_pins_text: [pr.MAX_PINS_LEX_BYTES]u8
new_pins_text: [pr.MAX_PINS_LEX_BYTES]u8

// caller_principal gives the principal of the caller of the export that
// runs. When acts is true it refuses a caller that does not act for it: a
// load and an update change what the principal builds.
@(private = "file")
caller_principal :: proc "contextless" (acts: bool, error: ^errors.Error_Record) -> (principal: u64, failure: call_outcome.Call_Outcome, ok: bool) {
	connection := system.service_caller()
	if connection == nil {
		failure, _ = call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Connection)
		return 0, failure, false
	}
	if acts && connection.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0 {
		failure, _ = call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
		return 0, failure, false
	}
	if !service_state.initialized {
		failure, _ = call_outcome.fail(error, .Wrong_State, .State, .Requests)
		return 0, failure, false
	}
	return isolated.caller_principal(connection.grant), .Succeeded, true
}

// name_copy copies a Text argument once into place and gives its bytes.
@(private = "file")
name_copy :: proc "contextless" (text: ^string, place: []u8, argument: i64, error: ^errors.Error_Record) -> (name: []u8, failure: call_outcome.Call_Outcome, ok: bool) {
	if text == nil {
		failure, _ = call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, argument)
		return nil, failure, false
	}
	view := intrinsics.volatile_load(text)
	if len(view) == 0 {
		failure, _ = call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, argument, 0, i64(len(place)))
		return nil, failure, false
	}
	if len(view) > len(place) {
		failure, _ = call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, argument, i64(len(view)), i64(len(place)))
		return nil, failure, false
	}
	intrinsics.mem_copy_non_overlapping(&place[0], raw_data(view), len(view))
	return place[:len(view)], .Succeeded, true
}

// bytes_copy copies a Bytes argument once into place and gives its bytes.
@(private = "file")
bytes_copy :: proc "contextless" (bytes: ^system.Bytes_To_Read, place: []u8, argument: i64, error: ^errors.Error_Record) -> (copied: []u8, failure: call_outcome.Call_Outcome, ok: bool) {
	if bytes == nil {
		return nil, .Succeeded, true
	}
	count := intrinsics.volatile_load(&bytes.count)
	if count > u64(len(place)) {
		failure, _ = call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, argument, i64(min(count, u64(max(i64)))), i64(len(place)))
		return nil, failure, false
	}
	if count > 0 {
		intrinsics.mem_copy_non_overlapping(&place[0], bytes.bytes, int(count))
	}
	return place[:count], .Succeeded, true
}

// project_refusal_fail writes the error record of a refusal of the projects
// contract, with the refusal as the value found.
@(private = "file")
project_refusal_fail :: proc "contextless" (error: ^errors.Error_Record, refusal: pr.Project_Refusal, argument: i64) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	found := i64(refusal)
	switch refusal {
	case .Unknown_Project, .Pin_Not_Found, .Unknown_Console, .No_Active_Console:
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .None, argument, 0, 0, found)
	case .Too_Many_Pins, .Too_Many_Modules, .Too_Many_Stores, .Project_Limit_Reached, .Console_Limit_Reached, .Nesting_Depth_Exceeded:
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Full, .None, argument, 0, 0, found)
	case .Buffer_Too_Small:
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, argument, 0, pr.MAX_PINS_LEX_BYTES, found)
	case .Consent_Required, .Untrusted_Consent, .Store_Rights_Exceeded, .Undeclared_Store:
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Stores, argument, 0, 0, found)
	case .Child_Console_Active:
		return call_outcome.fail(error, .Wrong_State, .State, .None, argument, 0, 0, found)
	case .Store_Failed:
		return call_outcome.fail(error, .Callee_Unavailable, .Device, .Store, argument, 0, 0, found)
	case .Store_Damaged:
		return call_outcome.fail(error, .Data_Damaged, .Damaged, .Store, argument, 0, 0, found)
	case .Bad_Evaluation, .Evaluation_Refused, .Not_A_Project, .Malformed_Syntax, .Trailing_Tokens:
		return call_outcome.fail(error, .Argument_Refused, .Malformed, .None, argument, 0, 0, found)
	case .None, .Invalid_Pin_Name, .Zero_Hash, .Duplicate_Pin, .Invalid_Upstream_Ref, .Invalid_Hash_Literal, .Unknown_Field, .Missing_Field, .Duplicate_Field, .Bad_Resolver_Action, .Bad_Resolver_Status, .Invalid_Address, .Host_Mismatch, .Hash_Mismatch, .Invalid_Module_Name, .Duplicate_Module, .Invalid_Store_Name, .Duplicate_Store, .Bad_Store_Rights, .Empty_Console:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, argument, 0, 0, found)
	}
	return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, argument, 0, 0, found)
}

// load reads a project for the principal of the caller: the evaluation of
// its project.lex, which the evaluation process gave, and its pins.lex.
//
// - **tree_name**: the name of the project, a Lex name.
// - **project_evaluation**: the canonical output of the evaluation of
//   project.lex, whose value is a project with a field source.
// - **pins_lex**: the text of pins.lex; empty for a project with no input.
//
// The value is the count of pins. A failure gives its outcome and its error
// record (the list above), with the refusal as the value found.
@(export, link_name = "load")
load :: proc "c" (tree_name: ^string, project_evaluation: ^system.Bytes_To_Read, pins_lex: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	principal, failure, allowed := caller_principal(true, error)
	if !allowed {
		return failure, 0
	}
	name, name_failure, name_ok := name_copy(tree_name, copied_project_name[:], 1, error)
	if !name_ok {
		return name_failure, 0
	}
	evaluation, evaluation_failure, evaluation_ok := bytes_copy(project_evaluation, copied_evaluation[:], 2, error)
	if !evaluation_ok {
		return evaluation_failure, 0
	}
	pins_text, pins_failure, pins_ok := bytes_copy(pins_lex, copied_update_pins[:], 3, error)
	if !pins_ok {
		return pins_failure, 0
	}
	pin_count, refusal := projects_core.load_project(&loaded_projects, &service_state, principal, name, evaluation, pins_text)
	if refusal != .None {
		system.log_fact(.Warning, Project_Command_Refused{refusal_code = u64(refusal)})
		argument := i64(2)
		if refusal == .Malformed_Syntax || refusal == .Invalid_Hash_Literal || refusal == .Unknown_Field || refusal == .Missing_Field || refusal == .Duplicate_Field || refusal == .Duplicate_Pin || refusal == .Too_Many_Pins || refusal == .Invalid_Pin_Name || refusal == .Invalid_Upstream_Ref {
			argument = 3
		}
		return project_refusal_fail(error, refusal, argument)
	}
	return .Succeeded, i64(pin_count)
}

// new makes a project of the principal of the caller with no project.lex
// (src/md/features/program_loop.md, "The loop, line by line"): its source
// is the empty tree, and its console has the store of its name, with Read
// and Write, which holds its source. The project is kept as each loaded
// project is, in the private store of the service. Its name has the rules
// of a nickname of a disk process, so its module can have its name in the
// store module_files.
//
// - **project_name**: 1 to 23 bytes, with no zero byte and no /; not
//   module_files and not grant_table; and a Lex name.
//
// The result is 0, or a negative number with an error record:
// ERROR_NO_CALLER, ERROR_ACTS_FOR_PRINCIPAL, ERROR_NOT_READY, or
// ERROR_PROJECT: Empty, Too_Long, Bad_Byte, or Exists for module_files and
// grant_table, which the store module_files keeps, for the name, or the
// refusal of the project as the value found.
//
// Example: `projects.new("hello")`.
@(export, link_name = "new")
new_project :: proc "c" (project_name: ^string, error: ^errors.Error_Record) -> i64 {
	principal, failure, allowed := caller_principal(true, error)
	if !allowed {
		return failure
	}
	name, name_failure, name_ok := name_copy(project_name, copied_project_name[:], 1, error)
	if !name_ok {
		return name_failure
	}
	if refusal := disk_process.nickname_refusal(string(name), len(name), 1, .Make); refusal.kind != 0 {
		error^ = refusal
		return ERROR_PROJECT
	}
	evaluation: [pr.PROJECT_NEW_EVALUATION_BYTES]u8
	written, written_ok := pr.project_new_evaluation(string(name), evaluation[:])
	if !written_ok {
		return project_refusal_fail(error, .Bad_Evaluation, 1)
	}
	if _, refusal := projects_core.load_project(&loaded_projects, &service_state, principal, name, evaluation[:written], nil); refusal != .None {
		system.log_fact(.Warning, Project_Command_Refused{refusal_code = u64(refusal)})
		return project_refusal_fail(error, refusal, 1)
	}
	system.log_fact(.Info, Project_Made{project = value_kinds.module_name_field(string(name)), principal = principal})
	return 0
}

// update moves one input of a loaded project of the principal of the caller
// to a new tree hash.
//
// - **project_name**: the name that load gave the project.
// - **input_name**: the name of the input in pins.lex.
// - **target**: the new tree hash of the input.
// - **summary**: one row: the count of lines of pins.lex that changed, 0
//   or 1, the number of that line, and the old and the new tree hash.
// - **pins_lex**: the whole new pins.lex, for the caller to write in the
//   store of the project.
// - **result**: the line that changed, as "-" and the old line, then "+"
//   and the new line, each with its line end; empty when nothing changed.
//
// The value is the count of bytes of the changed line text. A failure gives
// its outcome and its error record (the list above), with the refusal as the
// value found.
@(export, link_name = "update")
update :: proc "c" (
	project_name: ^string,
	input_name: ^string,
	target: ^pr.Pin_Target,
	summary: ^system.Table_To_Append(pr.Pin_Update_Row),
	pins_lex: ^system.Bytes_To_Append,
	result: ^[]u8,
	error: ^errors.Error_Record,
) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	principal, failure, allowed := caller_principal(true, error)
	if !allowed {
		return failure, 0
	}
	name, name_failure, name_ok := name_copy(project_name, copied_project_name[:], 1, error)
	if !name_ok {
		return name_failure, 0
	}
	input, input_failure, input_ok := name_copy(input_name, copied_input_name[:], 2, error)
	if !input_ok {
		return input_failure, 0
	}
	if target == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 3)
	}
	copied_target = intrinsics.volatile_load(target)
	update, refusal := projects_core.update_pin(&loaded_projects, &service_state, principal, name, input, blake3.Hash(copied_target.tree_hash), old_pins_text[:], new_pins_text[:])
	if refusal != .None {
		system.log_fact(.Warning, Project_Command_Refused{refusal_code = u64(refusal)})
		argument := i64(1)
		if refusal == .Pin_Not_Found || refusal == .Invalid_Pin_Name {
			argument = 2
		} else if refusal == .Zero_Hash {
			argument = 3
		}
		return project_refusal_fail(error, refusal, argument)
	}
	if summary != nil {
		system.table_append(summary, pr.Pin_Update_Row{
			changed_lines = i64(update.changed_lines),
			line_number   = i64(update.line_number),
			old_tree_hash = value_kinds.Hash_Field(update.old_tree_hash),
			new_tree_hash = value_kinds.Hash_Field(update.new_tree_hash),
		})
	}
	if pins_lex != nil {
		system.bytes_append(pins_lex, new_pins_text[:update.new_length])
	}
	written := 0
	if update.changed_lines == 1 {
		written = text_put(result^, written, "-")
		written = text_put(result^, written, string(update.old_line))
		written = text_put(result^, written, "\n+")
		written = text_put(result^, written, string(update.new_line))
		written = text_put(result^, written, "\n")
	}
	return .Succeeded, i64(written)
}

// text_put writes text at offset of a Text result as far as it fits, and
// gives the count that the whole text needs.
@(private = "file")
text_put :: proc "contextless" (buffer: []u8, offset: int, text: string) -> int {
	for index in 0 ..< len(text) {
		if offset + index < len(buffer) {
			buffer[offset + index] = text[index]
		}
	}
	return offset + len(text)
}

// pins gives the pinned inputs of a loaded project of the principal of the
// caller, in the order of pins.lex.
//
// The value is the count of pins. A failure gives its outcome and its error
// record (the list above), with Unknown_Project as the value found.
@(export, link_name = "pins")
pins :: proc "c" (project_name: ^string, result: ^[]pr.Pin_Row, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	principal, failure, allowed := caller_principal(false, error)
	if !allowed {
		return failure, 0
	}
	name, name_failure, name_ok := name_copy(project_name, copied_project_name[:], 1, error)
	if !name_ok {
		return name_failure, 0
	}
	project, refusal := projects_core.project_of(&loaded_projects, &service_state, principal, name)
	if refusal != .None {
		return project_refusal_fail(error, refusal, 1)
	}
	for index in 0 ..< project.pin_count {
		if index < len(result^) {
			result[index] = pr.pin_row_of_entry(&project.pins[index])
		}
	}
	return .Succeeded, i64(project.pin_count)
}

// build_recipe gives the recipe of the inputs tree of a project of the
// principal of the caller: the builder that the recipes service runs itself,
// and one input for each pin: a tree, by the tree hash that pins.lex gives
// it, under the name of the pin. The caller registers it with recipes.register and builds it
// with recipes.build.
//
// - **project_name**: the name that load gave the project.
// - **head**: one row: the builder hash and the output kind Tree.
// - **result**: one row for each input, in the order of pins.lex.
//
// The value is the count of inputs. A failure gives its outcome and its
// error record (the list above), with the refusal as the value found:
// Unknown_Project, Pin_Not_Found for a project with no pin, Store_Failed and
// Store_Damaged for the private store.
@(export, link_name = "build_recipe")
build_recipe :: proc "c" (project_name: ^string, head: ^system.Table_To_Append(pr.Recipe_Head), result: ^[]pr.Recipe_Input_Row, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	principal, failure, allowed := caller_principal(false, error)
	if !allowed {
		return failure, 0
	}
	name, name_failure, name_ok := name_copy(project_name, copied_project_name[:], 1, error)
	if !name_ok {
		return name_failure, 0
	}
	spec, refusal := projects_core.inputs_recipe(&loaded_projects, &service_state, principal, name)
	if refusal != .None {
		system.log_fact(.Warning, Project_Command_Refused{refusal_code = u64(refusal)})
		return project_refusal_fail(error, refusal, 1)
	}
	if head != nil {
		system.table_append(head, pr.Recipe_Head{output_kind_word = i64(spec.output_kind), builder_hash = value_kinds.Hash_Field(spec.builder_hash)})
	}
	for index in 0 ..< int(spec.input_count) {
		if index < len(result^) {
			input := &spec.inputs[index]
			row := pr.Recipe_Input_Row{kind_word = i64(input.kind), hash = value_kinds.Hash_Field(input.hash)}
			copy(row.name[:], input.name_bytes[:input.name_length])
			result[index] = row
		}
	}
	return .Succeeded, i64(spec.input_count)
}
