package build

import "core:testing"

// The check of the fact waits must find the classes of the faults that
// made a machine test wait until its bound: a fact whose sentence changed,
// a fact split into two, and a list that became one fact for each row. Each
// test gives the old wait against the new templates and checks the
// refusal first, then the waits that the new templates do render.

@(private = "file")
templates_of :: proc(texts: []string, fields: []Fact_Wait_Field) -> Fact_Wait_Templates {
	made := make([]Fact_Wait_Template, len(texts), context.temp_allocator)
	for text, index in texts {
		made[index] = fact_wait_template_make(text, fields, "test_module", context.temp_allocator)
	}
	return fact_wait_templates_make(made, context.temp_allocator)
}

@(private = "file")
verdict_of :: proc(known: ^Fact_Wait_Templates, text: string) -> Fact_Wait_Verdict {
	verdict, _, _ := fact_wait_verdict(known, text)
	return verdict
}

@(test)
a_fact_whose_sentence_changed_is_refused :: proc(t: ^testing.T) {
	known := templates_of({"storage: the block {block} has a wrong check {check}, expected {expected}"}, {{name = "block", class = .Word}, {name = "check", class = .Word}, {name = "expected", class = .Word}})
	// The old sentence said "bad" where the template now says "wrong".
	verdict, nearest, matched := fact_wait_verdict(&known, "storage: the block 12 has a bad check")
	testing.expect_value(t, verdict, Fact_Wait_Verdict.Matches_None)
	testing.expect_value(t, nearest.template, "storage: the block {block} has a wrong check {check}, expected {expected}")
	testing.expect_value(t, matched, len("storage: the block 12 has a "))
	// A word that a field of one word cannot hold: a space in a number.
	testing.expect_value(t, verdict_of(&known, "storage: the block 1 2 has a wrong check"), Fact_Wait_Verdict.Matches_None)
	// The head of a process and a mark of the scenario do not change it.
	testing.expect_value(t, verdict_of(&known, "[test_module] storage: the block {record} has a bad check"), Fact_Wait_Verdict.Matches)
	testing.expect_value(t, verdict_of(&known, "[test_module] storage: the block 12 has a bad"), Fact_Wait_Verdict.Matches_None)
	testing.expect_value(t, verdict_of(&known, "[test_module child 1] storage: the block 12 has a bad"), Fact_Wait_Verdict.Matches_None)
	// The new sentence, whole, cut inside a field, and cut at a literal.
	testing.expect_value(t, verdict_of(&known, "storage: the block 12 has a wrong check 0x0000231a, expected 0x00002b1a"), Fact_Wait_Verdict.Matches)
	testing.expect_value(t, verdict_of(&known, "storage: the block 12 has a wrong check 0x00"), Fact_Wait_Verdict.Matches)
	testing.expect_value(t, verdict_of(&known, "storage: the block "), Fact_Wait_Verdict.Matches)
	testing.expect_value(t, verdict_of(&known, "storage: "), Fact_Wait_Verdict.Matches)
}

@(test)
a_fact_split_into_two_is_refused :: proc(t: ^testing.T) {
	// One fact said the store and its count; now two facts say them.
	known := templates_of({"storage: opened the store {store}", "storage: the store {store} holds {objects} objects"}, {{name = "store", class = .Word}, {name = "objects", class = .Word}})
	testing.expect_value(t, verdict_of(&known, "storage: opened the store settings with 12 objects"), Fact_Wait_Verdict.Matches_None)
	testing.expect_value(t, verdict_of(&known, "storage: opened the store settings"), Fact_Wait_Verdict.Matches)
	testing.expect_value(t, verdict_of(&known, "storage: the store settings holds 12 objects"), Fact_Wait_Verdict.Matches)
	// One more byte past the end of the template is past its sentence.
	testing.expect_value(t, verdict_of(&known, "storage: the store settings holds 12 objects."), Fact_Wait_Verdict.Matches_None)
}

@(test)
a_list_that_became_one_fact_for_each_row_is_refused :: proc(t: ^testing.T) {
	known := templates_of({"monitor: the process {name} in the slot {slot}"}, {{name = "name", class = .Any}, {name = "slot", class = .Word}})
	testing.expect_value(t, verdict_of(&known, "monitor: 3 processes: console, log, settings"), Fact_Wait_Verdict.Matches_None)
	testing.expect_value(t, verdict_of(&known, "monitor: the processes: console, log"), Fact_Wait_Verdict.Matches_None)
	testing.expect_value(t, verdict_of(&known, "monitor: the process console in the slot 4"), Fact_Wait_Verdict.Matches)
	// A Text field can hold spaces.
	testing.expect_value(t, verdict_of(&known, "monitor: the process log reader in the slot 4"), Fact_Wait_Verdict.Matches)
	testing.expect_value(t, verdict_of(&known, "monitor: the processes console"), Fact_Wait_Verdict.Matches_None)
}

@(test)
a_wait_that_is_no_fact_wait_is_not_checked :: proc(t: ^testing.T) {
	known := templates_of({"storage: opened the store {store}"}, {{name = "store", class = .Word}})
	// A prefix that no template has: the kernel, the boot program (a word
	// with a space), a line that starts inside a sentence, an empty text.
	for text in ([]string{"kernel: ok", "boot program: ok", " windows shows a surface at 11 eighths", "", ": ", "[console]   module    adder", "storage", "storage:x"}) {
		testing.expectf(t, verdict_of(&known, text) == .Not_A_Fact_Wait, "%q is no fact wait", text)
	}
	// A head with no end is no head: its words start with "[".
	testing.expect_value(t, verdict_of(&known, "[storage storage: x"), Fact_Wait_Verdict.Not_A_Fact_Wait)
	// No template at all.
	empty := templates_of({}, {})
	testing.expect_value(t, verdict_of(&empty, "storage: anything"), Fact_Wait_Verdict.Not_A_Fact_Wait)
	// The head of a process whose module writes no fact of the prefix: the
	// console writes a result of a call whose first word is a store name.
	testing.expect_value(t, verdict_of(&known, "[console] storage: 2 objects, 0 trees"), Fact_Wait_Verdict.Not_A_Fact_Wait)
	testing.expect_value(t, verdict_of(&known, "[test_module] storage: 2 objects, 0 trees"), Fact_Wait_Verdict.Matches_None)
}

@(test)
a_text_line_of_the_same_prefix_keeps_a_wait_right :: proc(t: ^testing.T) {
	fact := fact_wait_template_make("errors: a table of {count} places", {{name = "count", class = .Word}}, "errors", context.temp_allocator)
	line := fact_wait_template_make("errors: case {value} again: {value}", nil, "a text line", context.temp_allocator)
	line.text_line = true
	known := fact_wait_templates_make({fact, line}, context.temp_allocator)
	testing.expect_value(t, verdict_of(&known, "errors: case b again: Memory_Size"), Fact_Wait_Verdict.Matches)
	testing.expect_value(t, verdict_of(&known, "errors: cases b again"), Fact_Wait_Verdict.Matches_None)
	// The prefix of a text line alone makes no wait a fact wait.
	only_line := fact_wait_templates_make({line}, context.temp_allocator)
	testing.expect_value(t, verdict_of(&only_line, "errors: anything"), Fact_Wait_Verdict.Not_A_Fact_Wait)
}

@(test)
the_prefix_later_in_a_sentence_and_the_units_match :: proc(t: ^testing.T) {
	known := templates_of({"display: {window}: the surface of {width}x{height} at {scale} eighths", "storage: the commit took {time}", "storage: {{literal}} {count}"}, {{name = "window", class = .Any}, {name = "width", class = .Word}, {name = "height", class = .Word}, {name = "scale", class = .Word}, {name = "time", class = .Word, unit = " ms"}, {name = "count", class = .Word}})
	// "monitor: " is no fact prefix of this list: the wait is not checked.
	testing.expect_value(t, verdict_of(&known, "monitor: the surface of 715x880 at 11 eighths"), Fact_Wait_Verdict.Not_A_Fact_Wait)
	testing.expect_value(t, verdict_of(&known, "display: monitor: the surface of 715x880 at 11 eighths"), Fact_Wait_Verdict.Matches)
	// A Text field holds any words, so a template that starts with one
	// takes any wait of its prefix: the check refuses less, never more.
	testing.expect_value(t, verdict_of(&known, "display: monitor: the surface of 715 x880"), Fact_Wait_Verdict.Matches)
	// The unit follows its value, with its space.
	testing.expect_value(t, verdict_of(&known, "storage: the commit took 12 ms"), Fact_Wait_Verdict.Matches)
	testing.expect_value(t, verdict_of(&known, "storage: the commit took 12 s"), Fact_Wait_Verdict.Matches_None)
	// Two braces are one brace of the sentence; the body ends at a mark.
	testing.expect_value(t, verdict_of(&known, "storage: "), Fact_Wait_Verdict.Matches)
	testing.expect_value(t, verdict_of(&known, "storage: {literal}"), Fact_Wait_Verdict.Matches)
}

@(test)
the_fact_prefix_is_a_name_then_a_colon :: proc(t: ^testing.T) {
	cases := []struct {
		text:   string,
		prefix: string,
		ok:     bool,
	}{{"storage: x", "storage: ", true}, {"address_space: edge", "address_space: ", true}, {"{window}: x", "", false}, {"boot program: ok", "", false}, {": x", "", false}, {"storage:x", "", false}, {"storage", "", false}, {"", "", false}}
	for item in cases {
		prefix, ok := fact_prefix_of(item.text)
		testing.expectf(t, prefix == item.prefix && ok == item.ok, "the fact prefix of %q is %q, %v: got %q, %v", item.text, item.prefix, item.ok, prefix, ok)
	}
}
