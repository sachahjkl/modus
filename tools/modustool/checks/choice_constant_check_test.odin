package checks

import "core:testing"
import "modustool:foundation"

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

import "modus:choices"

run :: proc "contextless" () {
	choices.start(u64(choices.MODE_STOP))
	if choices.LIMIT_PAGES > 2 {
	}
}
`

// The same family in a package of the tool, whose second member another
// package of the tool uses through the source library of the tool: the
// family is refused, as it is when the two are one package. An import of
// another library with a near name names no package of the tool.
@(test)
a_family_used_through_a_package_of_the_tool_is_refused :: proc(t: ^testing.T) {
	used := "package user\n\nimport \"" + foundation.TOOL_IMPORT_START + "choices\"\n\nrun :: proc \"contextless\" () {\n\tchoices.start(u64(choices.MODE_STOP))\n}\n"
	sources := []Export_Source {
		{path = foundation.TOOL_SOURCE_FOLDER + "/choices/choices.odin", text = CHOICES_DECLARED},
		{path = foundation.TOOL_SOURCE_FOLDER + "/user/main.odin", text = used},
	}
	families, ok := choice_families_of_sources(sources)
	testing.expect(t, ok)
	if !testing.expect_value(t, len(families), 1) {
		return
	}
	testing.expect_value(t, families[0].folder, foundation.TOOL_SOURCE_FOLDER + "/choices")
	testing.expect_value(t, len(families[0].members), 2)
	other := "package user\n\nimport \"" + foundation.TOOL_LIBRARY_NAME + "x:choices\"\n\nrun :: proc \"contextless\" () {\n\tchoices.start(u64(choices.MODE_STOP))\n}\n"
	sources[1].text = other
	families_of_other, other_ok := choice_families_of_sources(sources)
	testing.expect(t, other_ok)
	testing.expect_value(t, len(families_of_other), 0)
}

// The family of modes is refused once, with its two members that the code
// uses as choices, and the first use in the order of the files.
@(test)
a_family_used_in_a_switch_and_as_an_argument_is_refused :: proc(t: ^testing.T) {
	sources := []Export_Source {
		{path = "src/library/modus/choices/choices.odin", text = CHOICES_DECLARED},
		{path = "src/processes/user/main.odin", text = CHOICES_USED},
	}
	families, ok := choice_families_of_sources(sources)
	testing.expect(t, ok)
	testing.expect_value(t, len(families), 1)
	if len(families) != 1 {
		return
	}
	family := families[0]
	testing.expect_value(t, family.folder, "src/library/modus/choices")
	testing.expect_value(t, family.word, "MODE")
	testing.expect_value(t, family.word_place, Choice_Word_Place.First)
	testing.expect_value(t, len(family.members), 2)
	if len(family.members) == 2 {
		testing.expect_value(t, family.members[0], "MODE_STOP")
		testing.expect_value(t, family.members[1], "MODE_WRITE")
	}
	testing.expect_value(t, family.use_file, "src/library/modus/choices/choices.odin")
	testing.expect_value(t, family.use_line, 13)
	testing.expect_value(t, family.use_form, Choice_Use_Form.Case_Of_A_Switch)
	testing.expect(t, choice_exception_of(family) == nil)
}

// Each other form of a use as a choice, one family for each: a comparison,
// an assignment and a declaration, a field of a literal and an index named
// like a choice, through an import with its own name.
@(private = "file")
CHOICES_OF_EACH_FORM :: `package forms

import other "modus:choices"

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
		{path = "src/library/modus/choices/choices.odin", text = "package choices\n\nMODE_WAIT :: 0\nMODE_WRITE :: 1\n\nstart :: proc \"contextless\" (mode: u64) {}\n"},
		{path = "src/processes/forms/main.odin", text = CHOICES_OF_EACH_FORM},
	}
	families, ok := choice_families_of_sources(sources)
	testing.expect(t, ok)
	Expected :: struct {
		folder: string,
		word:   string,
		form:   Choice_Use_Form,
	}
	// MODE_ has one member that the code uses as a choice: one constant
	// is a constant, and no family.
	expected := [?]Expected {
		{"src/processes/forms", "FORM", .Compared_With_A_Choice},
		{"src/processes/forms", "KIND", .Compared_With_A_Choice},
		{"src/processes/forms", "STATE", .Given_To_A_Choice},
	}
	testing.expect_value(t, len(families), len(expected))
	for family, index in families {
		if index >= len(expected) {
			break
		}
		testing.expect_value(t, family.folder, expected[index].folder)
		testing.expect_value(t, family.word, expected[index].word)
		testing.expect_value(t, family.use_form, expected[index].form)
		testing.expect_value(t, len(family.members), 2)
	}
}

// The forms of a family that a first word and a literal do not show: a
// family by its last word, character constants, values computed from
// other constants, and several constants in one declaration. Each is
// refused once.
@(private = "file")
CHOICES_OF_OTHER_FORMS :: `package other_forms

READ_REQUEST :: 0
WRITE_REQUEST :: 1

ACCENT_GRAVE :: '` + "`" + `'
ACCENT_TILDE :: '~'

BASE :: 0x10
LEVEL_LOW :: BASE + 1
LEVEL_HIGH :: (BASE | 0x20) + 2

STAGE_ONE, STAGE_TWO :: 1, 2

serve :: proc "contextless" (request: u32, accent: rune, level: u64, stage: int) -> int {
	if request == READ_REQUEST || request == WRITE_REQUEST {
		return 1
	}
	switch accent {
	case ACCENT_GRAVE, ACCENT_TILDE:
		return 2
	}
	switch level {
	case LEVEL_LOW, LEVEL_HIGH:
		return 3
	}
	if stage == STAGE_ONE || stage == STAGE_TWO {
		return 4
	}
	return 0
}
`

@(test)
families_by_the_last_word_characters_and_computed_values_are_refused :: proc(t: ^testing.T) {
	sources := []Export_Source{{path = "src/processes/other_forms/main.odin", text = CHOICES_OF_OTHER_FORMS}}
	families, ok := choice_families_of_sources(sources)
	testing.expect(t, ok)
	Expected :: struct {
		word:  string,
		place: Choice_Word_Place,
	}
	// In the order of the list: the first words, then the last word.
	expected := [?]Expected{{"ACCENT", .First}, {"LEVEL", .First}, {"STAGE", .First}, {"REQUEST", .Last}}
	testing.expect_value(t, len(families), len(expected))
	for family, index in families {
		if index >= len(expected) {
			break
		}
		testing.expect_value(t, family.word, expected[index].word)
		testing.expect_value(t, family.word_place, expected[index].place)
		testing.expect_value(t, len(family.members), 2)
	}
	testing.expect_value(t, last_word_of("READ_REQUEST"), "REQUEST")
	testing.expect_value(t, last_word_of("REQUEST"), "REQUEST")
	testing.expect_value(t, last_word_of("REQUEST_"), "REQUEST_")
	testing.expect_value(t, choice_family_text("REQUEST", .Last), "_REQUEST")
	testing.expect_value(t, choice_family_text("MODE", .First), "MODE_")
}

// The negative answers of an export, compared with a value named like a
// choice: a negated literal, a negated constant, a conversion of a
// negation, a difference below 0. Each is a member. The values past the
// limit on the negative side, and a negation of a value past it, are not
// members.
@(private = "file")
NEGATIVE_CHOICES :: `package negatives

ERROR_NAME :: -1
ERROR_FULL :: -(2)
THREE :: 3
ERROR_ABSENT :: -THREE
ERROR_GONE :: i64(-4)
ERROR_LATE :: THREE - 8
ERROR_HUGE :: -256
ERROR_HUGER :: -0x7FFF_FFFF_FFFF_FFFF

answer_text :: proc "contextless" (answer: i64) -> string {
	switch answer {
	case ERROR_NAME, ERROR_FULL:
		return "a"
	case ERROR_HUGE, ERROR_HUGER:
		return "b"
	}
	if answer == ERROR_ABSENT || answer == ERROR_GONE || answer == ERROR_LATE {
		return "c"
	}
	return ""
}
`

@(test)
a_family_of_negative_answers_is_refused :: proc(t: ^testing.T) {
	sources := []Export_Source{{path = "src/processes/negatives/main.odin", text = NEGATIVE_CHOICES}}
	families, ok := choice_families_of_sources(sources)
	testing.expect(t, ok)
	testing.expect_value(t, len(families), 1)
	if len(families) != 1 {
		return
	}
	family := families[0]
	testing.expect_value(t, family.word, "ERROR")
	testing.expect_value(t, family.word_place, Choice_Word_Place.First)
	expected := [?]string{"ERROR_ABSENT", "ERROR_FULL", "ERROR_GONE", "ERROR_LATE", "ERROR_NAME"}
	testing.expect_value(t, len(family.members), len(expected))
	for name in expected {
		found := false
		for member in family.members {
			found ||= member == name
		}
		testing.expectf(t, found, "%s is a member of the family", name)
	}
	for member in family.members {
		testing.expectf(t, member != "ERROR_HUGE" && member != "ERROR_HUGER", "%s is past the limit, and it is a member", member)
	}
}

// A source that the parser refuses stops the check: it is never read as a
// source with no family.
@(test)
a_source_that_does_not_parse_stops_the_check :: proc(t: ^testing.T) {
	sources := []Export_Source{{path = "src/processes/broken/main.odin", text = "package broken\n\nMODE_A :: 0\nwords :: proc( {\n"}}
	_, ok := choice_families_of_sources(sources)
	testing.expect(t, !ok)
}

// The forms that are not choices come last, and give no family: sizes and
// limits used as quantities, a comparison with a name that is not a
// choice, two constants compared, values past the limit of a choice, one
// constant used as a choice, a character in a switch, an enum in a switch,
// a switch on a length.
@(private = "file")
CONSTANTS_THAT_KEEP_THE_RULE :: `package quantities

SIZE_SMALL :: 4
SIZE_LARGE :: 8
MASK_LOW :: 0x100
MASK_HIGH :: 0x200
MODE_ONLY :: 1
FORM_COLUMNS_MOST :: 32
FORM_ROWS_MOST :: 26
BOX_FORM_COLUMNS :: 30 + 2
BOX_FORM_ROWS :: 26

#assert(BOX_FORM_COLUMNS == FORM_COLUMNS_MOST)
#assert(BOX_FORM_ROWS == FORM_ROWS_MOST)

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
	// A switch on a length: its cases are quantities.
	switch len(buffer) {
	case SIZE_SMALL, SIZE_LARGE:
		return 4
	}
	return SIZE_SMALL + SIZE_LARGE
}
`

@(test)
quantities_limits_and_enums_keep_the_rule :: proc(t: ^testing.T) {
	sources := []Export_Source{{path = "src/processes/quantities/main.odin", text = CONSTANTS_THAT_KEEP_THE_RULE}}
	families, ok := choice_families_of_sources(sources)
	testing.expect(t, ok)
	for family in families {
		testing.expectf(t, false, "%s: the family %s is not a closed set of choices", family.folder, choice_family_text(family.word, family.word_place))
	}
}

// A package with an enum, its alias, and each refused form of a cast of a
// word to an enum: kept in a declaration, in an assignment and in a return,
// passed to a procedure, switched on, kept in the init of an if, compared
// with a variable and not with a member, used as an index, and made with
// `cast` and `transmute`.
@(private = "file")
CASTS_DECLARED :: `package casts

Mode :: enum u32 {
	First  = 1,
	Second = 2,
}

Alias :: Mode

use :: proc "contextless" (mode: Mode) {}

kept :: proc "contextless" (word: u32) -> Mode {
	declared := Mode(word)
	assigned: Mode
	assigned = Alias(word)
	_, _ = declared, assigned
	return Mode(word)
}

passed :: proc "contextless" (word: u32) {
	use(Mode(word))
}

switched :: proc "contextless" (word: u32) {
	switch Mode(word) {
	case .First, .Second:
	}
}

in_an_if :: proc "contextless" (word: u32) {
	if mode := Mode(word); mode == .First {
	}
}

with_a_variable :: proc "contextless" (word: u32, wanted: Mode) -> bool {
	return Mode(word) == wanted
}

as_an_index :: proc "contextless" (word: u32, names: [Mode]string) -> string {
	return names[Mode(word)]
}

with_cast :: proc "contextless" (word: u32) -> (Mode, Mode) {
	return cast(Mode)word, transmute(Mode)word
}

Chained :: Alias

Distinct_Mode :: distinct Mode

when ODIN_OS == .Linux {
	In_A_When :: enum u8 {
		One = 1,
	}
}

more_forms :: proc "contextless" (word: u32, bytes: [4]u32) -> (Chained, Distinct_Mode, In_A_When, Mode, [4]Mode, Mode) {
	chained := Chained(word)
	distinct_mode := Distinct_Mode(word)
	in_a_when := In_A_When(word)
	pointer := (^Mode)(&word)^
	array := transmute([4]Mode)bytes
	automatic: Mode = auto_cast word
	return chained, distinct_mode, in_a_when, pointer, array, automatic
}
`

// A package that imports the enum, casts a word through the import, and
// declares an alias of the enum through the import.
@(private = "file")
CASTS_IMPORTED :: `package importer

import other "modus:casts"

through_an_import :: proc "contextless" (word: u32) {
	other.use(other.Mode(word))
}

Imported_Alias :: other.Mode

through_an_imported_alias :: proc "contextless" (word: u32) -> Imported_Alias {
	return Imported_Alias(word)
}
`

// A third package that casts through the alias of the importer, and a
// package that imports the enum by a relative path.
@(private = "file")
CASTS_THROUGH_TWO_IMPORTS :: `package third

import "modus:importer"

through_two_imports :: proc "contextless" (word: u32) -> importer.Imported_Alias {
	return importer.Imported_Alias(word)
}
`

@(private = "file")
CASTS_RELATIVE :: `package relative

import neighbour "../../library/modus/casts"

through_a_relative_import :: proc "contextless" (word: u32) -> neighbour.Mode {
	return neighbour.Mode(word)
}
`

// Each refused form is refused, with its file, its line and its form; no
// cast is accepted that the rule refuses.
@(test)
a_cast_of_a_word_to_an_enum_is_refused :: proc(t: ^testing.T) {
	sources := []Export_Source {
		{path = "src/library/modus/casts/casts.odin", text = CASTS_DECLARED},
		{path = "src/library/modus/importer/importer.odin", text = CASTS_IMPORTED},
		{path = "src/processes/third/main.odin", text = CASTS_THROUGH_TWO_IMPORTS},
		{path = "src/processes/relative/main.odin", text = CASTS_RELATIVE},
	}
	casts, ok := enum_casts_of_sources(sources)
	testing.expect(t, ok)
	Expected :: struct {
		file:      string,
		line:      int,
		type_name: string,
		form:      Enum_Cast_Form,
	}
	DECLARED :: "src/library/modus/casts/casts.odin"
	expected := [?]Expected {
		{DECLARED, 13, "Mode", .Kept}, // A declaration.
		{DECLARED, 15, "Alias", .Kept}, // An assignment, through an alias.
		{DECLARED, 17, "Mode", .Kept}, // A return.
		{DECLARED, 21, "Mode", .Passed},
		{DECLARED, 25, "Mode", .Switched},
		{DECLARED, 31, "Mode", .Kept}, // The init of an if.
		{DECLARED, 36, "Mode", .Kept}, // Compared with a variable, not with a member.
		{DECLARED, 40, "Mode", .Kept}, // An index.
		{DECLARED, 44, "Mode", .Kept}, // cast.
		{DECLARED, 44, "Mode", .Kept}, // transmute.
		{DECLARED, 58, "Chained", .Kept}, // A chain of two aliases.
		{DECLARED, 59, "Distinct_Mode", .Kept}, // A distinct enum.
		{DECLARED, 60, "In_A_When", .Kept}, // An enum of a when block.
		{DECLARED, 61, "^Mode", .Kept}, // A pointer.
		{DECLARED, 62, "[]Mode", .Kept}, // An array.
		{DECLARED, 63, AUTO_CAST_TYPE_NAME, .Kept}, // An auto_cast, whose target is no type of the tree.
		{"src/library/modus/importer/importer.odin", 6, "other.Mode", .Passed},
		{"src/library/modus/importer/importer.odin", 12, "Imported_Alias", .Kept}, // An alias through an import.
		{"src/processes/relative/main.odin", 6, "neighbour.Mode", .Kept}, // A relative import.
		{"src/processes/third/main.odin", 6, "importer.Imported_Alias", .Kept}, // The alias of an import, from a third package.
	}
	testing.expect_value(t, len(casts), len(expected))
	for item, index in expected[:min(len(expected), len(casts))] {
		found := casts[index]
		testing.expectf(t, found.file == item.file && found.line == item.line && found.type_name == item.type_name && found.form == item.form, "the cast %d is %s:%d %s %v, not %s:%d %s %v", index, found.file, found.line, found.type_name, found.form, item.file, item.line, item.type_name, item.form)
	}
	// No exception of the repository holds a cast of these sources.
	refused, _ := enum_casts_judged(casts, ENUM_CAST_EXCEPTIONS[:])
	testing.expect_value(t, len(refused), len(casts))
}

// An exception holds the casts of its file and its enum, and only as many
// as its count: a second cast in the file refuses both and the row, a cast
// of another file or of another enum is refused, and a row with no cast is
// refused. The good case last: one cast, one row of count 1.
@(test)
an_exception_holds_its_count_of_casts_in_its_file :: proc(t: ^testing.T) {
	exceptions := []Enum_Cast_Exception{{file = "src/a/a.odin", type_name = "Mode", count = 1, reason = "a test"}}
	two := []Enum_Cast{{file = "src/a/a.odin", line = 3, type_name = "Mode"}, {file = "src/a/a.odin", line = 9, type_name = "Mode"}}
	refused, faults := enum_casts_judged(two, exceptions)
	testing.expect_value(t, len(refused), 2)
	testing.expect_value(t, len(faults), 1)
	if len(faults) == 1 {
		testing.expect_value(t, faults[0].found, 2)
	}
	others := []Enum_Cast{{file = "src/b/b.odin", line = 3, type_name = "Mode"}, {file = "src/a/a.odin", line = 4, type_name = "Other"}}
	refused, faults = enum_casts_judged(others, exceptions)
	testing.expect_value(t, len(refused), 2)
	testing.expect_value(t, len(faults), 1)
	if len(faults) == 1 {
		testing.expect_value(t, faults[0].found, 0)
	}
	// A tree under another root holds the same file at the end of its path.
	one := []Enum_Cast{{file = "/tmp/root/src/a/a.odin", line = 3, type_name = "Mode"}}
	refused, faults = enum_casts_judged(one, exceptions)
	testing.expect_value(t, len(refused), 0)
	testing.expect_value(t, len(faults), 0)
}

// A source that the parser refuses is no source with no cast.
@(test)
a_broken_source_is_no_source_with_no_cast :: proc(t: ^testing.T) {
	sources := []Export_Source{{path = "src/processes/broken/main.odin", text = "package broken\n\nrun :: proc( {\n"}}
	_, ok := enum_casts_of_sources(sources)
	testing.expect(t, !ok)
}

// The one form that the check accepts: a cast that is one operand of == or
// != with a member, written `.First`, `Mode.First` or through an import,
// on either side and in parentheses. The comparison is read once and never
// kept. The other uses of an enum type are no casts: its members, its
// count, its largest member, a loop over it and an enumerated array.
@(private = "file")
CASTS_ACCEPTED :: `package accepted

import other "modus:casts"

Mode :: enum u32 {
	First  = 1,
	Second = 2,
}

compared :: proc "contextless" (word: u32) -> bool {
	a := Mode(word) == .First
	b := Mode(word) != Mode.Second
	c := .First == Mode(word)
	d := (Mode(word)) == .Second
	e := other.Mode(word) == other.Mode.First
	if Mode(word) == .First && other.Mode(word) != .Second {
	}
	names: [Mode]string
	count := len(Mode) + int(max(Mode))
	for member in Mode {
		_ = names[member]
	}
	return a && b && c && d && e && count > 0
}
`

@(test)
a_cast_compared_with_a_member_is_accepted :: proc(t: ^testing.T) {
	sources := []Export_Source {
		{path = "src/library/modus/casts/casts.odin", text = CASTS_DECLARED},
		{path = "src/processes/accepted/main.odin", text = CASTS_ACCEPTED},
	}
	casts, ok := enum_casts_of_sources(sources)
	testing.expect(t, ok)
	for found in casts {
		testing.expectf(t, found.file != "src/processes/accepted/main.odin", "the accepted form at line %d is refused as %v", found.line, found.form)
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
	families, casts, stop_faults, file_count, ok := choice_families_of_tree("")
	testing.expect(t, ok)
	testing.expect(t, file_count > 100)
	refused_stop_words, stop_word_exception_faults := stop_words_judged(stop_faults, STOP_WORD_EXCEPTIONS[:])
	for fault in refused_stop_words {
		testing.expectf(t, false, "%s:%d: %s %s", fault.file, fault.line, stop_word_fault_words[fault.kind], fault.name)
	}
	for fault in stop_word_exception_faults {
		testing.expectf(t, false, "the exception %s of %s holds %d faults, and the file has %d", stop_word_fault_words[fault.exception.kind], fault.exception.file, fault.exception.count, fault.found)
	}
	refused_casts, exception_faults := enum_casts_judged(casts, ENUM_CAST_EXCEPTIONS[:])
	for cast_of_word in refused_casts {
		testing.expectf(t, false, "%s:%d: a cast of a word to the enum %s is %s", cast_of_word.file, cast_of_word.line, cast_of_word.type_name, enum_cast_form_words[cast_of_word.form])
	}
	for fault in exception_faults {
		testing.expectf(t, false, "the exception %s of %s holds %d casts, and the file has %d", fault.exception.type_name, fault.exception.file, fault.exception.count, fault.found)
	}
	for family in families {
		if choice_exception_of(family) == nil {
			testing.expectf(t, false, "%s:%d: the constants %s of %s are a closed set of choices", family.use_file, family.use_line, choice_family_text(family.word, family.word_place), family.folder)
		}
	}
	for exception in CHOICE_CONSTANT_EXCEPTIONS {
		matched := false
		for family in families {
			if choice_exception_matches(exception, family) {
				matched = true
			}
		}
		testing.expectf(t, matched, "the exception %s of %s names no family", choice_family_text(exception.word, exception.word_place), exception.folder)
	}
}
