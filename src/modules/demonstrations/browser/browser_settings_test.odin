#+build !freestanding
package browser

import "base:intrinsics"
import "core:strings"
import "core:testing"
import "modus:contract/chosen_values"
import "modus:contract/plan_values"

// The test runs on the host: the module serves exports, and the serving
// code of src/library/modus/system calls an export through an entry of the
// machine that the host does not have. No test here calls an export; a
// call stops the test.
@(export, link_name = "export_call")
host_export_call :: proc "c" (address: uintptr, integers, floats, results: rawptr) {intrinsics.trap()}

// The border of a home at its edges: the empty text, the bound of 160
// bytes, one past it, a text that is not UTF-8, and addresses that the
// browser refuses; a text that it takes is kept in its canonical form.
@(test)
a_home_is_read_at_its_border :: proc(t: ^testing.T) {
	room: [ADDRESS_CAPACITY + 8]u8
	_, empty, _ := home_problem_of("", room[:])
	testing.expect_value(t, empty, Home_Problem.Too_Short)
	// HOME_BYTES_MOST bytes: "http://h/" and a path of 64 bytes is the
	// longest path; a long query fills the rest.
	at_bound := strings.concatenate({"http://h/", strings.repeat("p", 63, context.temp_allocator), "?", strings.repeat("q", HOME_BYTES_MOST - 9 - 63 - 1, context.temp_allocator)}, context.temp_allocator)
	testing.expect_value(t, len(at_bound), HOME_BYTES_MOST)
	canonical, bound_problem, _ := home_problem_of(at_bound, room[:])
	testing.expect(t, bound_problem == .None && canonical == at_bound)
	past := strings.concatenate({at_bound, "q"}, context.temp_allocator)
	_, past_problem, _ := home_problem_of(past, room[:])
	testing.expect_value(t, past_problem, Home_Problem.Too_Long)
	for text in ([?]string{"modus://\xff", "http://a/\xc3", "\xed\xa0\x80"}) {
		_, utf8_problem, _ := home_problem_of(text, room[:])
		testing.expectf(t, utf8_problem == .Not_Utf8, "%q is taken", text)
	}
	Refused :: struct {
		text:    string,
		address: Address_Problem,
	}
	for item in ([?]Refused{{"ftp://example.org", .Scheme_Unknown}, {"http://", .Host_Empty}, {"   ", .Empty}, {"http://a b", .Host_Byte_Refused}, {"http://a:0/", .Port_Refused}, {"http://a:65536/", .Port_Refused}}) {
		_, problem, address_problem := home_problem_of(item.text, room[:])
		testing.expectf(t, problem == .Address_Refused && address_problem == item.address, "%q gives %v, %v", item.text, problem, address_problem)
	}
	guide, guide_problem, _ := home_problem_of("  modus://guide  ", room[:])
	testing.expect(t, guide_problem == .None && guide == "modus://guide")
	testing.expect(t, home_border("modus://forms") && !home_border("") && !home_border(past))
}

// The precedence of the home: a lock of the plan hides a choice, a choice
// hides a default of the plan, and a text that the border refuses holds as
// no value at each layer.
@(test)
the_home_is_read_by_its_layer :: proc(t: ^testing.T) {
	record_of :: proc(text: string) -> chosen_values.Record {
		bytes := make([]u8, chosen_values.HEADER_SIZE + chosen_values.ENTRY_SIZE + len(text), context.temp_allocator)
		changes := [1]chosen_values.Change{{name = HOME_NAME, kind = .Choose_Text, text = text}}
		written, _ := chosen_values.write_record({}, changes[:], bytes)
		record, _ := chosen_values.read_record(bytes[:written])
		return record
	}
	room: [ADDRESS_CAPACITY + 8]u8
	home, layer := home_of_record({}, {}, room[:])
	testing.expect(t, home == HOME_DEFAULT && layer == .Contract_Default)
	for text in ([?]string{"", "ftp://x", strings.repeat("a", HOME_BYTES_MOST + 1, context.temp_allocator)}) {
		bad := record_of(text)
		home, layer = home_of_record(bad, {defaults = bad, locks = bad}, room[:])
		testing.expectf(t, home == HOME_DEFAULT && layer == .Contract_Default, "%q is taken", text)
	}
	// A word of the name home is no text: it holds as no value.
	word_bytes: [chosen_values.HEADER_SIZE + chosen_values.ENTRY_SIZE]u8
	written, _ := chosen_values.write_record({}, {{name = HOME_NAME, kind = .Choose, value = 1}}, word_bytes[:])
	word_record, _ := chosen_values.read_record(word_bytes[:written])
	home, layer = home_of_record(word_record, {}, room[:])
	testing.expect(t, home == HOME_DEFAULT && layer == .Contract_Default)
	chosen := record_of("http://example.org/start")
	defaults := record_of("modus://forms")
	locks := record_of("modus://properties")
	home, layer = home_of_record({}, plan_values.Owner_Values{defaults = defaults}, room[:])
	testing.expect(t, home == "modus://forms" && layer == .Plan_Default)
	home, layer = home_of_record(chosen, plan_values.Owner_Values{defaults = defaults}, room[:])
	testing.expect(t, home == "http://example.org/start" && layer == .Chosen)
	home, layer = home_of_record(chosen, plan_values.Owner_Values{defaults = defaults, locks = locks}, room[:])
	testing.expect(t, home == "modus://properties" && layer == .Locked)
}
