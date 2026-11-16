package modustool

import "core:testing"

// A package that declares a family of modes and uses it as choices: a case
// of a switch, and an argument of a parameter named `mode` from another
// package, through a conversion. MODE_WAIT is never used as a choice.
@(private = "file")
CHOICES_DECLARED :: `package choices

MODE_WAIT :: 0
MODE_WRITE :: 1
MODE_STOP :: u64(2)
LIMIT_PAGES :: 4
LIMIT_BYTES :: 8

start :: proc "contextless" (mode: u64) {}

words :: proc "contextless" (mode: u64) -> string {
	switch mode {
	case MODE_WRITE:
		return "write"
	}
	return "wait"
}
`

@(private = "file")
CHOICES_USED :: `package user

import "modus:support/choices"

run :: proc "contextless" () {
	choices.start(u64(choices.MODE_STOP))
	if choices.LIMIT_PAGES > 2 {
	}
}
`

// The family of modes is refused once, with its two members that the code
// uses as choices, and the first use in the order of the files.
@(test)
a_family_used_in_a_switch_and_as_an_argument_is_refused :: proc(t: ^testing.T) {
	sources := []Export_Source {
		{path = "src/library/support/choices/choices.odin", text = CHOICES_DECLARED},
		{path = "src/programs/user/main.odin", text = CHOICES_USED},
	}
	families, ok := choice_families_of_sources(sources)
	testing.expect(t, ok)
	testing.expect_value(t, len(families), 1)
	if len(families) != 1 {
		return
	}
	family := families[0]
	testing.expect_value(t, family.folder, "src/library/support/choices")
	testing.expect_value(t, family.first_word, "MODE")
	testing.expect_value(t, len(family.members), 2)
	if len(family.members) == 2 {
		testing.expect_value(t, family.members[0], "MODE_STOP")
		testing.expect_value(t, family.members[1], "MODE_WRITE")
	}
	testing.expect_value(t, family.use_file, "src/library/support/choices/choices.odin")
	testing.expect_value(t, family.use_line, 13)
	testing.expect_value(t, family.use_form, Choice_Use_Form.Case_Of_A_Switch)
	testing.expect(t, choice_exception_of(family) == nil)
}

// Each other form of a use as a choice, one family for each: a comparison,
// an assignment and a declaration, a field of a literal and an index named
// like a choice, through an import with its own name.
@(private = "file")
CHOICES_OF_EACH_FORM :: `package forms

import other "modus:support/choices"

KIND_FIRST :: 1
KIND_SECOND :: 2
STATE_OPEN :: 0
STATE_SHUT :: 1
FORM_SHORT :: 3
FORM_LONG :: 4
VALUE_FORM :: 5

Thing :: struct {
	form: u64,
}

compare :: proc "contextless" (record: Thing, kind: u64) -> bool {
	return record.form == FORM_SHORT || kind == KIND_FIRST || KIND_SECOND != kind
}

assign :: proc "contextless" () -> (state: u64) {
	state = STATE_OPEN
	next_state := STATE_SHUT
	return next_state
}

fill :: proc "contextless" (values: ^[8]u64) -> Thing {
	values[VALUE_FORM] = u64(FORM_LONG)
	other.start(other.MODE_WRITE)
	return Thing{form = FORM_SHORT}
}
`

@(test)
each_form_of_a_use_as_a_choice_is_refused :: proc(t: ^testing.T) {
	sources := []Export_Source {
		{path = "src/library/support/choices/choices.odin", text = "package choices\n\nMODE_WAIT :: 0\nMODE_WRITE :: 1\n\nstart :: proc \"contextless\" (mode: u64) {}\n"},
		{path = "src/programs/forms/main.odin", text = CHOICES_OF_EACH_FORM},
	}
	families, ok := choice_families_of_sources(sources)
	testing.expect(t, ok)
	Expected :: struct {
		folder:     string,
		first_word: string,
		form:       Choice_Use_Form,
	}
	// MODE_ has one member that the code uses as a choice: one constant
	// is a constant, and no family.
	expected := [?]Expected {
		{"src/programs/forms", "FORM", .Compared_With_A_Choice},
		{"src/programs/forms", "KIND", .Compared_With_A_Choice},
		{"src/programs/forms", "STATE", .Given_To_A_Choice},
	}
	testing.expect_value(t, len(families), len(expected))
	for family, index in families {
		if index >= len(expected) {
			break
		}
		testing.expect_value(t, family.folder, expected[index].folder)
		testing.expect_value(t, family.first_word, expected[index].first_word)
		testing.expect_value(t, family.use_form, expected[index].form)
		testing.expect_value(t, len(family.members), 2)
	}
}

// A source that the parser refuses stops the check: it is never read as a
// source with no family.
@(test)
a_source_that_does_not_parse_stops_the_check :: proc(t: ^testing.T) {
	sources := []Export_Source{{path = "src/programs/broken/main.odin", text = "package broken\n\nMODE_A :: 0\nwords :: proc( {\n"}}
	_, ok := choice_families_of_sources(sources)
	testing.expect(t, !ok)
}

// The forms that are not choices come last, and give no family: sizes and
// limits used as quantities, a comparison with a name that is not a
// choice, values past the limit of a choice, one constant used as a choice,
// a character in a switch, an enum in a switch.
@(private = "file")
CONSTANTS_THAT_KEEP_THE_RULE :: `package quantities

SIZE_SMALL :: 4
SIZE_LARGE :: 8
MASK_LOW :: 0x100
MASK_HIGH :: 0x200
MODE_ONLY :: 1

Colour :: enum u8 {
	Red,
	Blue,
}

measure :: proc "contextless" (count: int, flags: u64, mode: u64, character: u8, colour: Colour) -> int {
	buffer: [SIZE_LARGE]u8
	if count == SIZE_SMALL || count != SIZE_LARGE {
		return len(buffer)
	}
	switch flags {
	case MASK_LOW, MASK_HIGH:
		return 1
	}
	if mode == MODE_ONLY {
		return 2
	}
	switch character {
	case 'a', 'b':
		return 3
	}
	switch colour {
	case .Red, .Blue:
	}
	return SIZE_SMALL + SIZE_LARGE
}
`

@(test)
quantities_limits_and_enums_keep_the_rule :: proc(t: ^testing.T) {
	sources := []Export_Source{{path = "src/programs/quantities/main.odin", text = CONSTANTS_THAT_KEEP_THE_RULE}}
	families, ok := choice_families_of_sources(sources)
	testing.expect(t, ok)
	for family in families {
		testing.expectf(t, false, "%s: the family %s_ is not a closed set of choices", family.folder, family.first_word)
	}
}

// A name holds a choice when one of its words, whole, is a word of a
// choice. The names that must not match come first.
@(test)
the_words_of_a_choice :: proc(t: ^testing.T) {
	not_choices := [?]string{"", "_", "count", "SIZE", "modes", "kinder", "MODEL", "transform", "VALUE_SIZE"}
	for name in not_choices {
		testing.expectf(t, !name_is_a_choice(name), "%q is no choice", name)
	}
	choices := [?]string{"mode", "VALUE_MODE", "change_mode", "record_kind", "State", "seed_strength"}
	for name in choices {
		testing.expectf(t, name_is_a_choice(name), "%q is a choice", name)
	}
	testing.expect_value(t, first_word_of("MODE_UNLOCK"), "MODE")
	testing.expect_value(t, first_word_of("MODE"), "MODE")
	testing.expect_value(t, first_word_of("_MODE"), "_MODE")
}

// The rule holds in the sources of the repository: each family that the
// code uses as choices is an exception of an outside standard, and each
// exception still names a family.
@(test)
choice_constants_of_the_repository :: proc(t: ^testing.T) {
	families, file_count, ok := choice_families_of_tree("")
	testing.expect(t, ok)
	testing.expect(t, file_count > 100)
	for family in families {
		if choice_exception_of(family) == nil {
			testing.expectf(t, false, "%s:%d: the constants %s_ of %s are a closed set of choices", family.use_file, family.use_line, family.first_word, family.folder)
		}
	}
	for exception in CHOICE_CONSTANT_EXCEPTIONS {
		matched := false
		for family in families {
			if exception.folder == family.folder && exception.first_word == family.first_word {
				matched = true
			}
		}
		testing.expectf(t, matched, "the exception %s_ of %s names no family", exception.first_word, exception.folder)
	}
}
