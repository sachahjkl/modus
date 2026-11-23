#+build !freestanding
package monitor

import "core:testing"
import "modus:contract/chosen_values"
import module "modus:contract/module"
import "modus:contract/plan_values"

// The sample period at its border: one under the least, one past the
// most, 0 and the largest word hold as no value at each layer; the least
// and the most are taken; a lock hides a choice, a choice hides a default
// of the plan.
@(test)
the_sample_interval_is_read_at_its_border_and_by_its_layer :: proc(t: ^testing.T) {
	record_of :: proc(word: u64) -> chosen_values.Record {
		bytes := make([]u8, chosen_values.HEADER_SIZE + chosen_values.ENTRY_SIZE, context.temp_allocator)
		changes := [1]chosen_values.Change{{name = SAMPLE_INTERVAL_NAME, kind = .Choose, value = word}}
		written, _ := chosen_values.write_record({}, changes[:], bytes)
		record, _ := chosen_values.read_record(bytes[:written])
		return record
	}
	milliseconds, layer := sample_interval_of_record({}, {})
	testing.expect(t, milliseconds == SAMPLE_INTERVAL_DEFAULT && layer == .Contract_Default)
	for word in ([?]u64{0, SAMPLE_INTERVAL_LEAST - 1, SAMPLE_INTERVAL_MOST + 1, max(u64)}) {
		bad := record_of(word)
		milliseconds, layer = sample_interval_of_record(bad, {defaults = bad, locks = bad})
		testing.expectf(t, milliseconds == SAMPLE_INTERVAL_DEFAULT && layer == .Contract_Default, "the word %d is taken", word)
	}
	for word in ([?]u64{SAMPLE_INTERVAL_LEAST, SAMPLE_INTERVAL_MOST}) {
		milliseconds, layer = sample_interval_of_record(record_of(word), {})
		testing.expect(t, milliseconds == word && layer == .Chosen)
	}
	milliseconds, layer = sample_interval_of_record({}, plan_values.Owner_Values{defaults = record_of(1000)})
	testing.expect(t, milliseconds == 1000 && layer == .Plan_Default)
	milliseconds, layer = sample_interval_of_record(record_of(2000), plan_values.Owner_Values{defaults = record_of(1000)})
	testing.expect(t, milliseconds == 2000 && layer == .Chosen)
	milliseconds, layer = sample_interval_of_record(record_of(2000), plan_values.Owner_Values{defaults = record_of(1000), locks = record_of(4000)})
	testing.expect(t, milliseconds == 4000 && layer == .Locked)
}

// The arguments of set: a Presence word that names no member (2 and the
// largest word) is refused before its value is read, Absent is refused
// with any value, a period one under the least, one past the most, a
// negative one and the largest are refused, and the least and the most are
// taken.
@(test)
set_refuses_a_presence_word_that_names_no_member :: proc(t: ^testing.T) {
	Case :: struct {
		presence: module.Presence,
		value:    i64,
		interval: u64,
		refusal:  Set_Refusal,
	}
	for item in ([?]Case {
		{module.Presence(2), 1000, 0, .Presence_Not_Member},
		{module.Presence(max(u64)), 1000, 0, .Presence_Not_Member},
		{.Absent, 1000, 0, .Absent},
		{.Absent, 0, 0, .Absent},
		{.Given, SAMPLE_INTERVAL_LEAST - 1, 0, .Out_Of_Range},
		{.Given, SAMPLE_INTERVAL_MOST + 1, 0, .Out_Of_Range},
		{.Given, -1, 0, .Out_Of_Range},
		{.Given, min(i64), 0, .Out_Of_Range},
		{.Given, max(i64), 0, .Out_Of_Range},
		{.Given, 0, 0, .Out_Of_Range},
		{.Given, SAMPLE_INTERVAL_LEAST, SAMPLE_INTERVAL_LEAST, .None},
		{.Given, SAMPLE_INTERVAL_MOST, SAMPLE_INTERVAL_MOST, .None},
	}) {
		interval, refusal := sample_interval_of_arguments(item.presence, item.value)
		testing.expectf(t, interval == item.interval && refusal == item.refusal, "%v %d gives %d %v", item.presence, item.value, interval, refusal)
	}
}
