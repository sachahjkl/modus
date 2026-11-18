package modustool

import "core:testing"

// A package whose exports keep the rule: each export that fails gives an
// error record, and each negative result of an export with no record is an
// answer, not a failure.
@(private = "file")
EXPORTS_THAT_KEEP_THE_RULE :: `package good

import "modus:contract/errors"

ERROR :: -1
LIMIT :: 8

// A failure with an error record: the check does not read this export.
@(export, link_name = "checked")
checked :: proc "c" (value: i64, error: ^errors.Error_Record) -> i64 {
	if value < 0 {
		return -1
	}
	if value > LIMIT {
		return errors.fail(error, ERROR, .Bad_Value, .None, 1, value, LIMIT)
	}
	return value
}

// A minus before a variable is an answer: the number that the text holds.
@(export, link_name = "number")
number :: proc "c" (value: i64, negative: i64) -> i64 {
	return negative != 0 ? -value : value
}

// A helper that never gives a negative constant.
twice :: proc "contextless" (value: i64) -> i64 {
	return value * 2
}

@(export, link_name = "doubled")
doubled :: proc "c" (value: i64) -> i64 {
	return i64(twice(value))
}

// A procedure literal inside the body: its return is not a return of the export.
@(export, link_name = "inner")
inner :: proc "c" () -> i64 {
	find :: proc "contextless" () -> i64 {
		return -1
	}
	return find() + 1
}

// No result, and the entry: the check reads neither.
@(export, link_name = "clear")
clear :: proc "c" () {
}

@(export, link_name = "entry")
entry :: proc "c" (address: rawptr) -> i64 {
	return -1
}

// A procedure that is not an export can give -1.
find_index :: proc "contextless" () -> int {
	return -1
}
`

// A package with each form of a failure that gives no error record, one
// return for each.
@(private = "file")
EXPORTS_THAT_BREAK_THE_RULE :: `package bad

NONE :: -1
STATUS_BASE :: 4

@(export, link_name = "literal")
literal :: proc "c" (value: i64) -> i64 {
	if value < 0 {
		return -1
	}
	return value
}

@(export, link_name = "status")
status :: proc "c" (value: i64) -> i64 {
	return -i64(value)
}

@(export, link_name = "constant")
constant :: proc "c" () -> i64 {
	return NONE
}

@(export, link_name = "negated_constant")
negated_constant :: proc "c" () -> i64 {
	return -STATUS_BASE
}

@(export, link_name = "choice")
choice :: proc "c" (value: i64) -> i64 {
	return value == 0 ? (-1) : value
}

// A helper of the same package, two calls deep, through a conversion.
failing_helper :: proc "contextless" (value: i64) -> int {
	if value == 0 {
		return -1
	}
	return int(value)
}

outer_helper :: proc "contextless" (value: i64) -> int {
	return failing_helper(value)
}

@(export, link_name = "helped")
helped :: proc "c" (value: i64) -> i64 {
	return i64(outer_helper(value))
}
`

// The rule holds: no export of the good package is named, and the check
// read the three exports with an i64 result, no error record and a name
// other than entry.
@(test)
exports_that_keep_the_rule :: proc(t: ^testing.T) {
	found := make([dynamic]Export_Without_Error_Record, context.temp_allocator)
	sources := []Export_Source{{path = "good/good.odin", text = EXPORTS_THAT_KEEP_THE_RULE}}
	export_count, ok := exports_without_error_record_of_package(sources, &found)
	testing.expect(t, ok)
	testing.expect_value(t, export_count, 3)
	for item in found {
		testing.expectf(t, false, "%s:%d: %s", item.file, item.line, item.export)
	}
}

// Each form of the bad package is named once, with the line of its return.
@(test)
exports_that_break_the_rule :: proc(t: ^testing.T) {
	found := make([dynamic]Export_Without_Error_Record, context.temp_allocator)
	sources := []Export_Source{{path = "bad/bad.odin", text = EXPORTS_THAT_BREAK_THE_RULE}}
	export_count, ok := exports_without_error_record_of_package(sources, &found)
	testing.expect(t, ok)
	testing.expect_value(t, export_count, 6)
	Expected :: struct {
		export: string,
		line:   int,
	}
	expected := [?]Expected{{"literal", 9}, {"status", 16}, {"constant", 21}, {"negated_constant", 26}, {"choice", 31}, {"helped", 48}}
	testing.expect_value(t, len(found), len(expected))
	for item, index in found {
		if index >= len(expected) {
			break
		}
		testing.expect_value(t, item.export, expected[index].export)
		testing.expect_value(t, item.line, expected[index].line)
		testing.expect_value(t, item.file, "bad/bad.odin")
	}
}

// The helpers of one package are in its other files too.
@(test)
exports_with_a_helper_in_another_file :: proc(t: ^testing.T) {
	found := make([dynamic]Export_Without_Error_Record, context.temp_allocator)
	sources := []Export_Source {
		{path = "two/exports.odin", text = "package two\n\n@(export, link_name = \"show\")\nshow :: proc \"c\" () -> i64 {\n\treturn find()\n}\n"},
		{path = "two/find.odin", text = "package two\n\nfind :: proc \"contextless\" () -> i64 {\n\treturn -1\n}\n"},
	}
	export_count, ok := exports_without_error_record_of_package(sources, &found)
	testing.expect(t, ok)
	testing.expect_value(t, export_count, 1)
	testing.expect_value(t, len(found), 1)
	if len(found) == 1 {
		testing.expect_value(t, found[0].export, "show")
		testing.expect_value(t, found[0].file, "two/exports.odin")
		testing.expect_value(t, found[0].line, 5)
	}
}

// The rule holds in the processes and the modules of the repository.
//
// The count of the packages proves that the tree was read. The count of the
// exports only has to be positive: it falls each time an export gets an
// error record, so a larger fixed bound fails on a correct change.
@(test)
export_error_records_of_the_repository :: proc(t: ^testing.T) {
	found, package_count, export_count, ok := exports_without_error_record_of_tree("")
	testing.expect(t, ok)
	testing.expect(t, package_count > 50)
	testing.expect(t, export_count > 0)
	for item in found {
		testing.expectf(t, false, "%s:%d: the export %s gives a negative number with no error record", item.file, item.line, item.export)
	}
}
