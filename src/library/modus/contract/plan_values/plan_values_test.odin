#+build !freestanding
package plan_values

import "core:testing"
import "modus:contract/chosen_values"

// record_of writes a record of chosen values of changes into a buffer.
@(private = "file")
record_of :: proc(buffer: []u8, changes: []chosen_values.Change) -> []u8 {
	written, _ := chosen_values.write_record({}, changes, buffer)
	return buffer[:written]
}

// good_set writes a set of two owners: storage with a default, and
// display with a default and a lock.
@(private = "file")
good_set :: proc(out: []u8) -> int {
	@(static) storage_defaults: [256]u8
	@(static) display_defaults: [256]u8
	@(static) display_locks: [256]u8
	@(static) empty: [64]u8
	blocks := [2]Owner_Block {
		{owner = "storage", defaults = record_of(storage_defaults[:], {{name = "keep_all_minutes", kind = .Choose, value = 30}}), locks = record_of(empty[:], nil)},
		{owner = "display", defaults = record_of(display_defaults[:], {{name = "bar_edge", kind = .Choose, value = 2}}), locks = record_of(display_locks[:], {{name = "consent_arm_milliseconds", kind = .Choose, value = 1000}})},
	}
	return set_write(out, 0, 7, blocks[:])
}

// A set that breaks a rule is refused whole, at each edge: too short, no
// magic, another principal, no generation, a count past the capacity or
// with reserved bits, an owner of no name or with bytes after its name, an
// owner twice, a block past the bytes, a record that is not one, a name
// that is a default and a lock, a byte after the last block. The success
// comes last.
@(test)
a_set_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	buffer: [SET_SIZE]u8
	written := good_set(buffer[:])
	testing.expect(t, written > SET_HEADER_SIZE)
	_, problem := set_check(buffer[:])
	testing.expect_value(t, problem, Set_Problem.None)
	Case :: struct {
		change:  proc(bytes: []u8, written: int),
		problem: Set_Problem,
	}
	cases := [?]Case {
		{proc(bytes: []u8, written: int) {word_put(bytes, 0, SET_MAGIC + 1)}, .Bad_Magic},
		{proc(bytes: []u8, written: int) {word_put(bytes, 8, 1)}, .Not_Machine},
		{proc(bytes: []u8, written: int) {word_put(bytes, 8, max(u64))}, .Not_Machine},
		{proc(bytes: []u8, written: int) {word_put(bytes, 16, 0)}, .Zero_Generation},
		{proc(bytes: []u8, written: int) {word_put(bytes, 24, OWNER_CAPACITY + 1)}, .Too_Many_Owners},
		{proc(bytes: []u8, written: int) {word_put(bytes, 24, 2 | 1 << 32)}, .Reserved_Not_Zero},
		{proc(bytes: []u8, written: int) {bytes[SET_HEADER_SIZE] = 'S'}, .Bad_Owner},
		{proc(bytes: []u8, written: int) {bytes[SET_HEADER_SIZE] = 0}, .Bad_Owner},
		{proc(bytes: []u8, written: int) {bytes[SET_HEADER_SIZE + chosen_values.NAME_SIZE - 1] = 'x'}, .Bad_Owner},
		{proc(bytes: []u8, written: int) {word_put(bytes, SET_HEADER_SIZE + chosen_values.NAME_SIZE, max(u64))}, .Too_Short},
		{proc(bytes: []u8, written: int) {bytes[SET_HEADER_SIZE + OWNER_HEAD_SIZE] ~= 0xFF}, .Bad_Record},
		{proc(bytes: []u8, written: int) {bytes[written] = 1}, .Reserved_Not_Zero},
		{proc(bytes: []u8, written: int) {bytes[len(bytes) - 1] = 1}, .Reserved_Not_Zero},
	}
	for item, index in cases {
		changed := buffer
		item.change(changed[:], written)
		_, refused := set_check(changed[:])
		testing.expectf(t, refused == item.problem, "case %d gives %v, not %v", index, refused, item.problem)
	}
	_, short := set_check(buffer[:SET_HEADER_SIZE - 1])
	testing.expect_value(t, short, Set_Problem.Too_Short)
	_, cut := set_check(buffer[:SET_HEADER_SIZE + 4])
	testing.expect_value(t, cut, Set_Problem.Too_Short)
	// An owner twice, and a name that is a default and a lock.
	twice: [SET_SIZE]u8
	empty: [64]u8
	blank := record_of(empty[:], nil)
	set_write(twice[:], 0, 1, {{owner = "storage", defaults = blank, locks = blank}, {owner = "storage", defaults = blank, locks = blank}})
	_, twice_problem := set_check(twice[:])
	testing.expect_value(t, twice_problem, Set_Problem.Owner_Twice)
	both_defaults, both_locks: [256]u8
	both: [SET_SIZE]u8
	set_write(both[:], 0, 1, {{owner = "display", defaults = record_of(both_defaults[:], {{name = "bar_edge", kind = .Choose, value = 2}}), locks = record_of(both_locks[:], {{name = "bar_edge", kind = .Choose, value = 1}})}})
	_, both_problem := set_check(both[:])
	testing.expect_value(t, both_problem, Set_Problem.Default_And_Lock)
	// The success: the head, and the values of each owner.
	head, _ := set_check(buffer[:])
	testing.expect(t, head.generation == 7 && head.owner_count == 2)
	display, display_found := owner_values_of(buffer[:], "display")
	testing.expect(t, display_found && locked(display, "consent_arm_milliseconds", any_word) && !locked(display, "bar_edge", any_word))
	_, absent := owner_values_of(buffer[:], "network")
	testing.expect(t, !absent)
}

// The page of an owner: a page of another magic, lengths past the page, and
// a damaged record are refused with no value; a written page reads back.
@(test)
the_page_of_an_owner_reads_back :: proc(t: ^testing.T) {
	buffer: [SET_SIZE]u8
	good_set(buffer[:])
	values, _ := owner_values_of(buffer[:], "display")
	page: [OWNER_PAGE_SIZE]u8
	testing.expect(t, owner_page_write(page[:], values))
	read, ok := owner_page_read(page[:])
	testing.expect(t, ok && locked(read, "consent_arm_milliseconds", any_word))
	word, found := chosen_values.find(read.defaults, "bar_edge")
	testing.expect(t, found && word == 2)
	zeros: [OWNER_PAGE_SIZE]u8
	_, zeros_ok := owner_page_read(zeros[:])
	testing.expect(t, !zeros_ok)
	long := page
	word_put(long[:], 8, max(u64))
	_, long_ok := owner_page_read(long[:])
	testing.expect(t, !long_ok)
	damaged := page
	damaged[OWNER_PAGE_HEADER_SIZE] ~= 0xFF
	_, damaged_ok := owner_page_read(damaged[:])
	testing.expect(t, !damaged_ok)
	_, short_ok := owner_page_read(page[:OWNER_PAGE_HEADER_SIZE - 1])
	testing.expect(t, !short_ok)
	none: [OWNER_PAGE_SIZE]u8
	testing.expect(t, owner_page_write(none[:], {}))
	empty, empty_ok := owner_page_read(none[:])
	testing.expect(t, empty_ok && empty.defaults.count == 0 && empty.locks.count == 0)
}

// The precedence: a lock hides a choice, a choice hides a default, and a
// word that the border refuses holds as no value of its layer.
@(test)
a_lock_hides_a_choice_and_a_choice_hides_a_default :: proc(t: ^testing.T) {
	border :: proc "contextless" (word: u64) -> bool {return word >= 10 && word <= 20}
	defaults_bytes, locks_bytes, chosen_bytes: [256]u8
	plan := Owner_Values{}
	plan.defaults, _ = chosen_values.read_record(record_of(defaults_bytes[:], {{name = "a", kind = .Choose, value = 11}, {name = "b", kind = .Choose, value = 12}, {name = "c", kind = .Choose, value = 99}}))
	plan.locks, _ = chosen_values.read_record(record_of(locks_bytes[:], {{name = "d", kind = .Choose, value = 15}, {name = "e", kind = .Choose, value = 5}}))
	chosen, _ := chosen_values.read_record(record_of(chosen_bytes[:], {{name = "b", kind = .Choose, value = 13}, {name = "d", kind = .Choose, value = 16}, {name = "e", kind = .Choose, value = 17}}))
	Case :: struct {
		name:  string,
		word:  u64,
		layer: chosen_values.Layer,
		found: bool,
	}
	for item in ([?]Case{{"a", 11, .Plan_Default, true}, {"b", 13, .Chosen, true}, {"c", 0, .Contract_Default, false}, {"d", 15, .Locked, true}, {"e", 17, .Chosen, true}, {"f", 0, .Contract_Default, false}}) {
		word, layer, found := value_in_force(item.name, chosen, plan, border)
		testing.expectf(t, word == item.word && layer == item.layer && found == item.found, "%s gives %d %v %v", item.name, word, layer, found)
	}
	// The lock agrees with the value in force: a lock whose word the border
	// refuses locks nothing, and a field with no lock is not locked.
	testing.expect(t, locked(plan, "d", border))
	testing.expect(t, !locked(plan, "e", border))
	testing.expect(t, !locked(plan, "a", border))
	testing.expect(t, !locked(plan, "f", border))
}

@(private = "file")
any_word :: proc "contextless" (word: u64) -> bool {return true}

// A text lock agrees with text_in_force: a text that the border refuses
// locks nothing.
@(test)
a_text_lock_that_its_border_refuses_locks_nothing :: proc(t: ^testing.T) {
	short :: proc "contextless" (text: string) -> bool {return len(text) <= 4}
	locks_bytes: [256]u8
	plan := Owner_Values{}
	plan.locks, _ = chosen_values.read_record(record_of(locks_bytes[:], {{name = "a", kind = .Choose_Text, text = "abcd"}, {name = "b", kind = .Choose_Text, text = "abcde"}}))
	testing.expect(t, text_locked(plan, "a", short))
	testing.expect(t, !text_locked(plan, "b", short))
	testing.expect(t, !text_locked(plan, "c", short))
}

// The page that the core writes again: a copy refuses a page whose
// sequence is odd (a write in progress), and a page or a copy shorter than
// a page; a publish keeps the sequence word through the write, leaves it
// even and two past the one before, and a publish that does not fit
// leaves a page with no value.
@(test)
a_page_written_again_is_copied_whole_or_not_at_all :: proc(t: ^testing.T) {
	buffer: [SET_SIZE]u8
	good_set(buffer[:])
	values, _ := owner_values_of(buffer[:], "display")
	page, out: [OWNER_PAGE_SIZE]u8
	testing.expect(t, owner_page_publish(page[:], values))
	testing.expect_value(t, owner_page_sequence_load(page[:]), 2)
	sequence, copied, _ := owner_page_copy(page[:], out[:])
	testing.expect(t, copied && sequence == 2)
	read, read_ok := owner_page_read(out[:])
	testing.expect(t, read_ok && locked(read, "consent_arm_milliseconds", any_word))
	// A second publish: the sequence moves by two, and the values hold.
	testing.expect(t, owner_page_publish(page[:], {}))
	testing.expect_value(t, owner_page_sequence_load(page[:]), 4)
	sequence, copied, _ = owner_page_copy(page[:], out[:])
	empty, empty_ok := owner_page_read(out[:])
	testing.expect(t, copied && sequence == 4 && empty_ok && empty.locks.count == 0)
	// A write in progress: the copy gives nothing.
	owner_page_sequence(page[:])^ = 5
	_, odd_copied, odd_met := owner_page_copy(page[:], out[:])
	testing.expect(t, !odd_copied && odd_met == 5)
	owner_page_sequence(page[:])^ = 4
	// A page or a copy one byte short.
	_, short_page, _ := owner_page_copy(page[:OWNER_PAGE_SIZE - 1], out[:])
	_, short_out, _ := owner_page_copy(page[:], out[:OWNER_PAGE_SIZE - 1])
	testing.expect(t, !short_page && !short_out)
	testing.expect(t, !owner_page_sizes_valid(page[:OWNER_PAGE_SIZE - 1], out[:]) && owner_page_sizes_valid(page[:], out[:]))
	// The largest sequence wraps to an even word.
	owner_page_sequence(page[:])^ = max(u32) - 1
	testing.expect(t, owner_page_publish(page[:], values))
	testing.expect_value(t, owner_page_sequence_load(page[:]) & 1, 0)
	// Values that do not fit: the page holds no value, with an even
	// sequence, and still reads.
	texts: [OWNER_PAGE_SIZE]u8
	wide := values
	wide.defaults.texts = texts[:]
	testing.expect(t, !owner_page_publish(page[:], wide))
	testing.expect_value(t, owner_page_sequence_load(page[:]) & 1, 0)
	sequence, copied, _ = owner_page_copy(page[:], out[:])
	none, none_ok := owner_page_read(out[:])
	testing.expect(t, copied && none_ok && none.defaults.count == 0 && none.locks.count == 0)
}