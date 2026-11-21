#+build !freestanding
package sentence

import "modus:contract/errors"
import "modus:contract/start_grant"
import "core:fmt"
import "core:testing"

// A refused debug access names the start grant that refuses by its name,
// in the words of the log of the root service.
@(test)
debug_access_refused_by_a_named_grant :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	record := errors.error_make(.No_Grant, .Debug_Access, 1, 0, 0, 1 + i64(start_grant.Grant.Store))
	error_text(&writer, &record, "debugger.attach", "process")
	testing.expect_value(t, written(&writer), "debugger.attach: the caller has no grant for this: the debug access to this process: the grant Store of the process refuses it")

	// The last start grant, and the first one: the 1 that the record adds
	// keeps the number 0 apart from "no grant is named".
	writer = Writer{buffer = buffer[:]}
	record = errors.error_make(.No_Grant, .Debug_Access, 1, 0, 0, 1 + i64(max(start_grant.Grant)))
	error_text(&writer, &record, "debugger.attach", "process")
	last_name, _ := start_grant.grant_name(i64(max(start_grant.Grant)))
	testing.expect_value(t, written(&writer), fmt.tprintf("debugger.attach: the caller has no grant for this: the debug access to this process: the grant %s of the process refuses it", last_name))
	writer = Writer{buffer = buffer[:]}
	record = errors.error_make(.No_Grant, .Debug_Access, 1, 0, 0, 1 + i64(start_grant.Grant.Root_Ring))
	error_text(&writer, &record, "debugger.attach", "process")
	testing.expect_value(t, written(&writer), "debugger.attach: the caller has no grant for this: the debug access to this process: the grant Root_Ring of the process refuses it")
}

// A refusal that names no grant: the caller asked for itself, or its grant
// `debug` was revoked.
@(test)
debug_access_refused_with_no_grant_named :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	record := errors.error_make(.No_Grant, .Debug_Access, 1)
	error_text(&writer, &record, "debugger.attach", "process")
	testing.expect_value(t, written(&writer), "debugger.attach: the caller has no grant for this: the debug access to this process")
}

// A number that names no start grant: the record came from a root service
// that has a start grant more, or from a process that wrote any value. The
// sentence gives the number and writes no name.
@(test)
debug_access_refused_by_a_grant_with_no_name :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	record := errors.error_make(.No_Grant, .Debug_Access, 1, 0, 0, 2 + i64(max(start_grant.Grant)))
	error_text(&writer, &record, "debugger.attach", "process")
	testing.expect_value(t, written(&writer), fmt.tprintf("debugger.attach: the caller has no grant for this: the debug access to this process: a grant of the process refuses it, the start grant number %d, which this process does not know", 1 + i64(max(start_grant.Grant))))

	writer = Writer{buffer = buffer[:]}
	record = errors.error_make(.No_Grant, .Debug_Access, 1, 0, 0, -5)
	error_text(&writer, &record, "debugger.attach", "process")
	testing.expect_value(t, written(&writer), "debugger.attach: the caller has no grant for this: the debug access to this process: a grant of the process refuses it, the start grant number -6, which this process does not know")
}

// Each start grant has a name, and the name is one word with no space: a
// sentence writes it between two spaces.
@(test)
each_start_grant_has_a_name :: proc(t: ^testing.T) {
	for grant in start_grant.Grant {
		name, known := start_grant.grant_name(i64(grant))
		testing.expectf(t, known && name != "", "the start grant %d has no name", i64(grant))
		for index in 0 ..< len(name) {
			testing.expectf(t, name[index] != ' ', "the name %q has a space", name)
		}
	}
	_, below := start_grant.grant_name(-1)
	_, above := start_grant.grant_name(1 + i64(max(start_grant.Grant)))
	testing.expect(t, !below && !above)
}
