#+build !freestanding
#+build !modus
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
		plan = test_plan(0, 1, 2)
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
	proposed := test_plan_copy(&current)
	proposed.entries[0].value_word = 1
	first, _ := plan_hash(&current)
	second, _ := plan_hash(&proposed)
	testing.expect(t, first != second)
	locked := test_plan_copy(&current)
	locked.entries[0].value_layer_word = u64(chosen_values.Layer.Locked)
	third, _ := plan_hash(&locked)
	testing.expect(t, third != first)
	difference := test_difference()
	testing.expect_value(t, plan_diff_compute(&current, &proposed, &difference), Plan_Refusal.None)
	testing.expect(t, difference.changed_values == 1 && difference.any_grant_added && difference.changes[0].old_value_word == 2 && difference.changes[0].new_value_word == 1)
	added := test_difference()
	testing.expect_value(t, plan_diff_compute(nil, &current, &added), Plan_Refusal.None)
	testing.expect(t, added.added_values == 1 && added.any_grant_added)
	// The row reads back.
	row_of: [1]Plan_Entry_Row
	testing.expect_value(t, plan_rows_of_entry(&current.entries[0], row_of[:]), 1)
	back := test_plan(0, 0)
	refusal, _ := plan_of_rows(0, row_of[:], &back)
	testing.expect(t, refusal == .None && back.entries[0] == current.entries[0])
	owner, field, parts_ok := plan_value_parts(&back.entries[0])
	testing.expect(t, parts_ok && owner == "display" && field == "bar_edge")
}

// A text Value entry at its edges: the empty text, 256 bytes, 257 bytes,
// a text that is not UTF-8, and each control byte that could break a line
// of the trusted display; a word with a text, a text with a word, bytes
// after the text and a kind of no member are refused at the border; the
// text counts in the hash and in the difference, and its row and its
// store record read back with it.
@(test)
a_text_plan_value_is_read_at_its_border :: proc(t: ^testing.T) {
	long := [PLAN_VALUE_TEXT_BYTES + 1]u8{}
	for &byte in long {
		byte = 'a'
	}
	_, past := plan_entry_make_text_value("browser", "home", string(long[:]), .Plan_Default)
	testing.expect(t, !past)
	for text in ([?]string{"\xff", "a\xc3", "\xed\xa0\x80", "a\nb", "a\rb", "\tx", "\x00", "x\x7f", "\x1b[2J"}) {
		_, refused := plan_entry_make_text_value("browser", "home", text, .Plan_Default)
		testing.expectf(t, !refused, "%q is taken", text)
	}
	empty, empty_made := plan_entry_make_text_value("browser", "home", "", .Plan_Default)
	most, most_made := plan_entry_make_text_value("browser", "home", string(long[:PLAN_VALUE_TEXT_BYTES]), .Locked)
	testing.expect(t, empty_made && most_made)
	plan_of :: proc(entry: Plan_Entry) -> (plan: Plan_Spec) {
		plan = test_plan(0, 1, 2)
		plan.entries[0] = entry
		return plan
	}
	for entry in ([?]Plan_Entry{empty, most}) {
		plan := plan_of(entry)
		refusal, _ := plan_validate(&plan)
		testing.expect_value(t, refusal, Plan_Refusal.None)
	}
	home, _ := plan_entry_make_text_value("browser", "home", "http://example.org/a,b", .Plan_Default)
	Case :: struct {
		change: proc(entry: ^Plan_Entry),
		about:  string,
	}
	cases := [?]Case {
		{proc(entry: ^Plan_Entry) {entry.value_word = 1}, "a text with a word"},
		{proc(entry: ^Plan_Entry) {entry.value_text[PLAN_VALUE_TEXT_BYTES - 1] = 'x'}, "a byte after the text"},
		{proc(entry: ^Plan_Entry) {entry.value_text_length = PLAN_VALUE_TEXT_BYTES + 1}, "a length past the bound"},
		{proc(entry: ^Plan_Entry) {entry.value_text[0] = 0xFF}, "a text that is not UTF-8"},
		{proc(entry: ^Plan_Entry) {entry.value_text[0] = '\n'}, "a line feed"},
		{proc(entry: ^Plan_Entry) {entry.value_kind_word = 0}, "no kind"},
		{proc(entry: ^Plan_Entry) {entry.value_kind_word = 3}, "a kind of no member"},
		{proc(entry: ^Plan_Entry) {entry.value_kind_word = max(u64)}, "the largest kind"},
		{proc(entry: ^Plan_Entry) {entry.value_kind_word = u64(chosen_values.Entry_Kind.Word)}, "a word that holds a text"},
	}
	for item in cases {
		entry := home
		item.change(&entry)
		plan := plan_of(entry)
		refusal, _ := plan_validate(&plan)
		testing.expectf(t, refusal == .Bad_Value, "%s gives %v", item.about, refusal)
	}
	// A store grant that carries a text or a kind of value is refused.
	store, _ := plan_entry_make_store("notes", .Read_Only)
	store.value_kind_word = u64(chosen_values.Entry_Kind.Text)
	store_plan := plan_of(store)
	store_refusal, _ := plan_validate(&store_plan)
	testing.expect_value(t, store_refusal, Plan_Refusal.Bad_Entry_Kind)
	// The hash and the difference: another text is another plan, and the
	// difference carries the new text, which the dialog shows.
	other, _ := plan_entry_make_text_value("browser", "home", "http://example.org/b", .Plan_Default)
	first, second := plan_of(home), plan_of(other)
	first_hash, _ := plan_hash(&first)
	second_hash, _ := plan_hash(&second)
	testing.expect(t, first_hash != second_hash)
	difference := test_difference()
	testing.expect_value(t, plan_diff_compute(&first, &second, &difference), Plan_Refusal.None)
	testing.expect(t, difference.change_count == 1 && difference.changes[0].change == .Changed && difference.any_grant_added)
	item := &difference.changes[0]
	testing.expect_value(t, string(item.new_value_text[:item.new_value_text_length]), "http://example.org/b")
	// The rows of a text: one for each 40 bytes, joined back into one entry;
	// the empty text and a text of exactly 40 bytes take one row.
	rows: [PLAN_TEXT_ROWS_MOST + 1]Plan_Entry_Row
	count := plan_rows_of_entry(&first.entries[0], rows[:])
	testing.expect_value(t, count, 1)
	long_entry, _ := plan_entry_make_text_value("browser", "home", string(long[:PLAN_VALUE_TEXT_BYTES]), .Plan_Default)
	count = plan_rows_of_entry(&long_entry, rows[:])
	testing.expect_value(t, count, PLAN_TEXT_ROWS_MOST)
	testing.expect_value(t, plan_rows_of_entry(&long_entry, rows[:PLAN_TEXT_ROWS_MOST - 1]), 0)
	back := test_plan(0, 0)
	refusal, _ := plan_of_rows(0, rows[:count], &back)
	testing.expect(t, refusal == .None && back.entry_count == 1 && plan_value_text(&back.entries[0]) == string(long[:PLAN_VALUE_TEXT_BYTES]))
	for text in ([?]string{"", "0123456789012345678901234567890123456789"}) {
		edge, _ := plan_entry_make_text_value("browser", "home", text, .Plan_Default)
		testing.expect_value(t, plan_rows_of_entry(&edge, rows[:]), 1)
		edge_refusal, _ := plan_of_rows(0, rows[:1], &back)
		testing.expect(t, edge_refusal == .None && plan_value_text(&back.entries[0]) == text)
	}
	// Each break of the parts is refused at its row.
	Part_Case :: struct {
		change: proc(rows: []Plan_Entry_Row),
		about:  string,
		row:    u32,
	}
	part_cases := [?]Part_Case {
		{proc(rows: []Plan_Entry_Row) {rows[1].value_word = 2}, "a part out of order", 1},
		{proc(rows: []Plan_Entry_Row) {rows[1].name[0] = 'x'}, "a part of another name", 1},
		{proc(rows: []Plan_Entry_Row) {rows[1].value_layer_word = 3}, "a part of another layer", 1},
		{proc(rows: []Plan_Entry_Row) {rows[0].value_text[39] = 0}, "a short part before another", 1},
		{proc(rows: []Plan_Entry_Row) {rows[2] = {}; rows[2] = rows[1]; rows[2].value_word = 2; rows[2].value_text = {}}, "an empty part", 2},
		{proc(rows: []Plan_Entry_Row) {rows[1].value_text[0] = 0; rows[1].value_text[1] = 'a'}, "bytes after the zero of a part", 1},
	}
	for item in part_cases {
		broken_rows: [PLAN_TEXT_ROWS_MOST]Plan_Entry_Row
		broken_count := plan_rows_of_entry(&long_entry, broken_rows[:])
		item.change(broken_rows[:])
		broken_refusal, at := plan_of_rows(0, broken_rows[:broken_count], &back)
		testing.expectf(t, broken_refusal == .Bad_Value && at == item.row, "%s gives %v at %d", item.about, broken_refusal, at)
	}
	// A part past 256 bytes: one row more after the longest text.
	past_rows: [PLAN_TEXT_ROWS_MOST + 1]Plan_Entry_Row
	past_count := plan_rows_of_entry(&long_entry, past_rows[:])
	past_rows[past_count] = past_rows[past_count - 1]
	past_rows[past_count].value_word = i64(past_count)
	past_refusal, past_at := plan_of_rows(0, past_rows[:past_count + 1], &back)
	testing.expect(t, past_refusal == .Bad_Value && past_at == u32(past_count))
	digest, _ := plan_hash(&first)
	record := Applied_Plan_Record{plan_hash = digest, generation = 1}
	object := make([]u8, plan_generation_size(first.entry_count), context.temp_allocator)
	written, encode_refusal := encode_plan_generation(&record, &first, object[:])
	testing.expect_value(t, encode_refusal, Plan_Refusal.None)
	decoded := test_plan(0, 0)
	_, decode_refusal := decode_plan_generation(object[:written], 0, 1, &decoded)
	testing.expect(t, decode_refusal == .None && plan_value_text(&decoded.entries[0]) == "http://example.org/a,b")
	// An object of the row before, magic MODPGEN1, and a magic one byte
	// past: each refused at its head, with no plan.
	for last in ([2]u8{'1', '3'}) {
		older := make([]u8, len(object), context.temp_allocator)
		copy(older, object)
		older[7] = last
		_, older_refusal := decode_plan_generation(older[:written], 0, 1, &decoded)
		testing.expect_value(t, older_refusal, Plan_Refusal.Bad_Header)
		testing.expect(t, decoded.entry_count == 0 && decoded.principal == 0)
	}
}
