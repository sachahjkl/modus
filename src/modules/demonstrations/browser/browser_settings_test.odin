#+build !freestanding
package browser

import "base:intrinsics"
import "core:testing"
import "modus:contract/chosen_values"
import "modus:contract/plan_values"

// The test runs on the host: the module serves exports, and the serving
// code of src/library/modus/system calls an export through an entry of the
// machine that the host does not have. No test here calls an export; a
// call stops the test.
@(export, link_name = "export_call")
host_export_call :: proc "c" (address: uintptr, integers, floats, results: rawptr) {intrinsics.trap()}

// The precedence of the home: a lock of the plan hides a choice, a choice
// hides a default of the plan, and a word that names no page holds as no
// value at each layer.
@(test)
the_home_is_read_at_its_border_and_by_its_layer :: proc(t: ^testing.T) {
	record_of :: proc(changes: []chosen_values.Change) -> chosen_values.Record {
		bytes := make([]u8, chosen_values.HEADER_SIZE + 4 * chosen_values.ENTRY_SIZE, context.temp_allocator)
		written, _ := chosen_values.write_record({}, changes, bytes)
		record, _ := chosen_values.read_record(bytes[:written])
		return record
	}
	home, layer := home_of_record({}, {})
	testing.expect(t, home == HOME_DEFAULT && layer == .Contract_Default)
	for word in ([?]u64{u64(len(Built_In_Page)), 255, max(u64)}) {
		bad := record_of({{name = HOME_NAME, kind = .Choose, value = word}})
		home, layer = home_of_record(bad, {defaults = bad, locks = bad})
		testing.expectf(t, home == HOME_DEFAULT && layer == .Contract_Default, "the word %d is taken", word)
	}
	chosen := record_of({{name = HOME_NAME, kind = .Choose, value = u64(Built_In_Page.Guide)}})
	defaults := record_of({{name = HOME_NAME, kind = .Choose, value = u64(Built_In_Page.Forms)}})
	locks := record_of({{name = HOME_NAME, kind = .Choose, value = u64(Built_In_Page.Properties)}})
	home, layer = home_of_record({}, plan_values.Owner_Values{defaults = defaults})
	testing.expect(t, home == .Forms && layer == .Plan_Default)
	home, layer = home_of_record(chosen, plan_values.Owner_Values{defaults = defaults})
	testing.expect(t, home == .Guide && layer == .Chosen)
	home, layer = home_of_record(chosen, plan_values.Owner_Values{defaults = defaults, locks = locks})
	testing.expect(t, home == .Properties && layer == .Locked)
	testing.expect(t, home_border(u64(Built_In_Page.Forms)) && !home_border(u64(len(Built_In_Page))))
}
