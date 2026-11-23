package console

// A plan written in the console (src/md/features/declarations.md, "A plan
// written in the console"): the names of the evaluation that make the
// values of a plan, `plan`, `module` and `store`, and the reader that turns
// a plan given to a table of plan rows into those rows (modus:plan_reader).
//
// Merge note, work/limits_text_and_clipboard: a line of the console holds
// 4096 bytes there (line_editor.LINE_CAPACITY), not 200, so a plan of one
// line can give each text value at its bound; nothing here names the bound
// of a line. A plan longer than a line stays the Later entry of ROADMAP.md,
// "A plan longer than one line".

import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"
import "modus:lex_evaluator"
import "modus:plan_reader"
import "modus:sentence"
import "modus:system"

// The names of the evaluation that make the values of a plan. They have no
// effect, and come before a command of the same name.
PLAN_NAME :: "plan"
MODULE_NAME :: "module"
STORE_NAME :: "store"

// plan_name_signature gives the signature of a name of the evaluation that
// makes a value of a plan. found is false for another name.
plan_name_signature :: proc "contextless" (name: string) -> (signature: lex_evaluator.Command_Signature, found: bool) {
	switch name {
	case PLAN_NAME:
		signature = {parameter_count = 1, untyped = true}
		signature.names[0] = "record"
		return signature, true
	case MODULE_NAME:
		signature = {parameter_count = 1, untyped = true}
		signature.names[0] = "hash"
		return signature, true
	case STORE_NAME:
		// store(name, .read, .write): a text, then the rights.
		signature = {parameter_count = 1, untyped = true}
		signature.names[0] = "name"
		return signature, true
	}
	return {}, false
}

// plan_name_run makes the value of a name of the evaluation of a plan.
plan_name_run :: proc "contextless" (name: string, arguments: []Value) -> Value {
	switch name {
	case PLAN_NAME:
		if len(arguments) != 1 {
			return fail("plan takes one record: plan { values = { owner = { field = value } } }")
		}
		made, problem := lex_evaluator.plan_value_make(&line_evaluation, arguments[0])
		switch problem {
		case .None:
			return made
		case .Not_A_Record:
			return fail("plan takes one record: plan { values = { owner = { field = value } } }")
		case .Pool_Full:
			return fail("a line holds ", i64(lex_evaluator.TAGGED_RECORD_CAPACITY), " plans at most")
		}
	case MODULE_NAME:
		if len(arguments) != 1 || arguments[0].kind != .Hash {
			return fail("module takes one hash: module(blake3:…)")
		}
		return {kind = .Module_Ref, detail = arguments[0].detail}
	case STORE_NAME:
		made, problem := lex_evaluator.store_ref_make(&line_evaluation, arguments)
		switch problem {
		case .None:
			return made
		case .Not_A_Record:
			return fail("store takes a name and its rights: store(\"notes\", .read, .write)")
		case .Pool_Full:
			return fail("the line has too many items of lists")
		}
	}
	return fail("no name of a plan: ", name)
}

// The rows of the plans of one line: one table of rows of the largest plan.
plan_rows_bytes: [pr.MAX_PLAN_ENTRIES * size_of(pr.Plan_Entry_Row)]u8

// plan_rows_of_argument turns a plan given to a table parameter of an
// export into the rows of that table, when its record is the record of the
// rows of a plan (plan_reader.rows_layout_matches). converted is false for
// another argument. A plan given to any other table fails the line.
plan_rows_of_argument :: proc "contextless" (found: ^Command, index: int, argument: ^Value) -> (converted: bool) {
	if argument.kind != .Plan_Value || found.run != nil || index >= int(found.parameter_count) || found.parameters[index] != .Table {
		return false
	}
	detail := found.function.parameter_details[index]
	if !plan_reader.rows_layout_matches(found.file, detail) {
		fail(found.name, ": the argument ", found.parameter_names[index], " is no table of the rows of a plan, so it takes no plan")
		return false
	}
	rows := ([^]pr.Plan_Entry_Row)(raw_data(plan_rows_bytes[:]))[:pr.MAX_PLAN_ENTRIES]
	count, refusal := plan_reader.read(&line_evaluation, argument^, console_image_of_plans(), rows)
	if refusal.problem != .None {
		writer := sentence.Writer{buffer = scratch[scratch_count:]}
		plan_reader.refusal_write(&writer, refusal)
		text := sentence.written(&writer)
		scratch_count += len(text)
		fail(found.name, ": ", text)
		return false
	}
	bytes := scratch_bytes(count * size_of(pr.Plan_Entry_Row))
	if bytes == nil && count != 0 {
		fail("the line has too many records")
		return false
	}
	copy(bytes, plan_rows_bytes[:count * size_of(pr.Plan_Entry_Row)])
	argument^ = {kind = .Table, record = bytes, file = found.file, detail = detail}
	return true
}

// console_image_of_plans gives the reader the boot image of the console.
console_image_of_plans :: proc "contextless" () -> plan_reader.Image {
	of_name :: proc "contextless" (user: rawptr, name: string) -> []u8 {
		return system.image_find(image, name)
	}
	of_hash :: proc "contextless" (user: rawptr, hash: blake3.Hash) -> []u8 {
		entry := system.image_entry_of(image, hash)
		if entry == nil {
			return nil
		}
		return image[entry.offset:][:entry.size]
	}
	return {module_of_name = of_name, module_of_hash = of_hash}
}

