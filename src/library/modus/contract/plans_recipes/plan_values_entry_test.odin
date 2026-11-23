#+build !freestanding
package plans_recipes

import "core:testing"
import "modus:contract/chosen_values"

// A Value entry: a name that is not `owner.field`, a layer that is not
// Plan_Default or Locked, a field of another kind, and value words on
// another kind are refused at the border; a value counts in the hash and
// in the difference, and each change of it asks the consent. Its row and
// its store record read back.
@(test)
a_plan_value_is_read_at_its_border :: proc(t: ^testing.T) {
	good, made := plan_entry_make_value("display", "bar_edge", 2, .Plan_Default)
	testing.expect(t, made)
	for name in ([?][2]string{{"Display", "bar_edge"}, {"display", ""}, {"", "bar_edge"}, {"display", "9edge"}}) {
		_, refused := plan_entry_make_value(name[0], name[1], 1, .Plan_Default)
		testing.expectf(t, !refused, "the name %v is taken", name)
	}
	for layer in ([?]chosen_values.Layer{.Contract_Default, .Chosen}) {
		_, refused := plan_entry_make_value("display", "bar_edge", 1, layer)
		testing.expectf(t, !refused, "the layer %v is taken", layer)
	}
	plan_of :: proc(entry: Plan_Entry) -> (plan: Plan_Spec) {
		plan.entry_count = 1
		plan.entries[0] = entry
		return plan
	}
	Case :: struct {
		change:  proc(entry: ^Plan_Entry),
		refusal: Plan_Refusal,
	}
	cases := [?]Case {
		{proc(entry: ^Plan_Entry) {entry.value_layer_word = 0}, .Bad_Value},
		{proc(entry: ^Plan_Entry) {entry.value_layer_word = 2}, .Bad_Value},
		{proc(entry: ^Plan_Entry) {entry.value_layer_word = 4}, .Bad_Value},
		{proc(entry: ^Plan_Entry) {entry.value_layer_word = max(u64)}, .Bad_Value},
		{proc(entry: ^Plan_Entry) {entry.role_word = 1}, .Bad_Value},
		{proc(entry: ^Plan_Entry) {entry.store_rights_word = 1}, .Bad_Value},
		{proc(entry: ^Plan_Entry) {entry.module_hash[0] = 1}, .Bad_Value},
		{proc(entry: ^Plan_Entry) {entry.name_bytes[7] = '_'}, .Bad_Value},
	}
	for item, index in cases {
		entry := good
		item.change(&entry)
		plan := plan_of(entry)
		refusal, _ := plan_validate(&plan)
		testing.expectf(t, refusal == item.refusal, "case %d gives %v", index, refusal)
	}
	// Value words on another kind.
	store, _ := plan_entry_make_store("notes", .Read_Only)
	store.value_word = 1
	store_plan := plan_of(store)
	store_refusal, _ := plan_validate(&store_plan)
	testing.expect_value(t, store_refusal, Plan_Refusal.Bad_Entry_Kind)
	// Two values of one field are one entry twice.
	twice := plan_of(good)
	twice.entries[1], twice.entry_count = good, 2
	twice.entries[1].value_word = 3
	twice_refusal, _ := plan_validate(&twice)
	testing.expect_value(t, twice_refusal, Plan_Refusal.Duplicate_Entry)
	// The hash holds the word and the layer; a change asks the consent.
	current := plan_of(good)
	proposed := current
	proposed.entries[0].value_word = 1
	first, _ := plan_hash(&current)
	second, _ := plan_hash(&proposed)
	testing.expect(t, first != second)
	locked := current
	locked.entries[0].value_layer_word = u64(chosen_values.Layer.Locked)
	third, _ := plan_hash(&locked)
	testing.expect(t, third != first)
	difference: Plan_Difference
	testing.expect_value(t, plan_diff_compute(&current, &proposed, &difference), Plan_Refusal.None)
	testing.expect(t, difference.changed_values == 1 && difference.any_grant_added && difference.changes[0].old_value_word == 2 && difference.changes[0].new_value_word == 1)
	added: Plan_Difference
	testing.expect_value(t, plan_diff_compute(nil, &current, &added), Plan_Refusal.None)
	testing.expect(t, added.added_values == 1 && added.any_grant_added)
	// The row reads back.
	row := plan_entry_row_of_entry(&current.entries[0])
	back: Plan_Spec
	refusal, _ := plan_of_rows(0, {row}, &back)
	testing.expect(t, refusal == .None && back.entries[0] == current.entries[0])
	owner, field, parts_ok := plan_value_parts(&back.entries[0])
	testing.expect(t, parts_ok && owner == "display" && field == "bar_edge")
}
