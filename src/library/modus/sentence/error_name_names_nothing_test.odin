#+build !freestanding
package sentence

import "modus:contract/errors"
import "core:testing"

// A name or a number that names nothing gives an error record, and the
// record gives a sentence that names the argument. The machine test waits
// for these sentences in the console.
@(test)
a_name_that_names_no_module :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	record := errors.error_make(.Absent, .Modules, 1)
	error_text(&writer, &record, "manual.about", "name")
	testing.expect_value(t, written(&writer), "manual.about: the argument name names none of the modules")
}

@(test)
a_number_that_names_no_export :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	record := errors.error_make(.Bad_Value, .None, 2, 9, 5)
	error_text(&writer, &record, "manual.signature", "export")
	testing.expect_value(t, written(&writer), "manual.signature: the argument export has the value 9, which the call refuses; it takes at most 5")

	// A module with no described export: no number is taken, and the
	// sentence gives no range.
	writer = Writer{buffer = buffer[:]}
	record = errors.error_make(.Bad_Value, .None, 2, 1, 0)
	error_text(&writer, &record, "manual.signature", "export")
	testing.expect_value(t, written(&writer), "manual.signature: the argument export has the value 1, which the call refuses")
}

@(test)
a_name_that_names_no_setting :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	record := errors.error_make(.Absent, .None, 1)
	error_text(&writer, &record, "settings.get", "name")
	testing.expect_value(t, written(&writer), "settings.get: the argument name names nothing that exists")
}

@(test)
the_stores_without_the_grant :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	record := errors.error_make(.No_Grant, .Acts_For_Principal)
	error_text(&writer, &record, "storage.stores", "")
	testing.expect_value(t, written(&writer), "storage.stores: the caller has no grant for this: to act for the principal; only the starter of the process can give this grant")
}
