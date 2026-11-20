#+build !freestanding
package operation

import "core:testing"
import "modus:contract/errors"
import "modus:contract/value_kinds"

// A word that names no member of its contract enum gives no name: one past
// the last member, the largest word of the enum, and the largest word. The
// enum None gives no name for any word, 0 too. Each member then gives its
// own name, and two members never give one name.
@(test)
a_word_that_names_no_member_has_no_name :: proc(t: ^testing.T) {
	refused_levels := [?]u64{u64(max(Log_Level)) + 1, u64(max(u8)), u64(max(u32)), max(u64)}
	for word in refused_levels {
		name, ok := contract_enum_member_name(.Log_Level, word)
		testing.expectf(t, !ok && name == "", "the word %d of a log level gives the name %q", word, name)
	}
	refused_statuses := [?]u64{u64(max(Status)) + 1, u64(max(u32)), max(u64)}
	for word in refused_statuses {
		name, ok := contract_enum_member_name(.Status, word)
		testing.expectf(t, !ok && name == "", "the word %d of a status gives the name %q", word, name)
	}
	none_words := [?]u64{0, 1, max(u64)}
	for word in none_words {
		_, ok := contract_enum_member_name(.None, word)
		testing.expectf(t, !ok, "the enum None gives a name for the word %d", word)
	}
	for level in Log_Level {
		name, ok := contract_enum_member_name(.Log_Level, u64(level))
		testing.expect(t, ok)
		testing.expect_value(t, name, LOG_LEVEL_NAMES[level])
		for other in Log_Level {
			testing.expectf(t, other == level || LOG_LEVEL_NAMES[other] != name, "the levels %v and %v have one name", level, other)
		}
	}
	for status in Status {
		name, ok := contract_enum_member_name(.Status, u64(status))
		testing.expect(t, ok)
		testing.expect_value(t, name, STATUS_NAMES[status])
	}
	refused_forms := [?]u64{u64(max(Log_Record_Form)) + 1, u64(max(u8)), max(u64)}
	for word in refused_forms {
		name, ok := contract_enum_member_name(.Log_Record_Form, word)
		testing.expectf(t, !ok && name == "", "the word %d of a record form gives the name %q", word, name)
	}
	for form in Log_Record_Form {
		name, ok := contract_enum_member_name(.Log_Record_Form, u64(form))
		testing.expect(t, ok)
		testing.expect_value(t, name, LOG_RECORD_FORM_NAMES[form])
	}
	refused_causes := [?]u64{u64(max(Stop_Cause)) + 1, u64(max(u32)), max(u64)}
	for word in refused_causes {
		name, ok := contract_enum_member_name(.Stop_Cause, word)
		testing.expectf(t, !ok && name == "", "the word %d of a stop cause gives the name %q", word, name)
		words, words_ok := contract_enum_member_words(.Stop_Cause, word)
		testing.expectf(t, !words_ok && words == "", "the word %d of a stop cause gives the words %q", word, words)
	}
	refused_outcomes := [?]u64{u64(max(Stop_Outcome)) + 1, u64(max(u32)), max(u64)}
	for word in refused_outcomes {
		name, ok := contract_enum_member_name(.Stop_Outcome, word)
		testing.expectf(t, !ok && name == "", "the word %d of a stop outcome gives the name %q", word, name)
		words, words_ok := contract_enum_member_words(.Stop_Outcome, word)
		testing.expectf(t, !words_ok && words == "", "the word %d of a stop outcome gives the words %q", word, words)
	}
	for cause in Stop_Cause {
		name, ok := contract_enum_member_name(.Stop_Cause, u64(cause))
		testing.expect(t, ok)
		testing.expect_value(t, name, STOP_CAUSE_NAMES[cause])
		for other in Stop_Cause {
			testing.expectf(t, other == cause || STOP_CAUSE_NAMES[other] != name, "the causes %v and %v have one name", cause, other)
		}
	}
	for outcome in Stop_Outcome {
		name, ok := contract_enum_member_name(.Stop_Outcome, u64(outcome))
		testing.expect(t, ok)
		testing.expect_value(t, name, STOP_OUTCOME_NAMES[outcome])
		for other in Stop_Outcome {
			testing.expectf(t, other == outcome || STOP_OUTCOME_NAMES[other] != name, "the outcomes %v and %v have one name", outcome, other)
		}
	}
	warning, warning_ok := contract_enum_member_name(.Log_Level, u64(Log_Level.Warning))
	testing.expect(t, warning_ok)
	testing.expect_value(t, warning, "Warning")
}

// The words of a member in a sentence are the words that a line of a stop
// wrote before the facts, for the two enums of a stop, and the name of the
// member for each other enum. A word that names no member, and the enum
// None, give no words.
@(test)
a_member_has_the_words_of_its_sentence :: proc(t: ^testing.T) {
	for cause in Stop_Cause {
		words, ok := contract_enum_member_words(.Stop_Cause, u64(cause))
		testing.expect(t, ok)
		testing.expect_value(t, words, STOP_CAUSE_TEXTS[cause])
	}
	for outcome in Stop_Outcome {
		words, ok := contract_enum_member_words(.Stop_Outcome, u64(outcome))
		testing.expect(t, ok)
		testing.expect_value(t, words, STOP_OUTCOME_TEXTS[outcome])
	}
	itself, itself_ok := contract_enum_member_words(.Stop_Cause, u64(Stop_Cause.Itself))
	testing.expect(t, itself_ok)
	testing.expect_value(t, itself, "itself")
	done, done_ok := contract_enum_member_words(.Stop_Outcome, u64(Stop_Outcome.Done))
	testing.expect(t, done_ok)
	testing.expect_value(t, done, "done")
	holder, holder_ok := contract_enum_member_words(.Stop_Cause, u64(Stop_Cause.Holder))
	testing.expect(t, holder_ok)
	testing.expect_value(t, holder, "a holder")
	for level in Log_Level {
		words, ok := contract_enum_member_words(.Log_Level, u64(level))
		testing.expect(t, ok)
		testing.expect_value(t, words, LOG_LEVEL_NAMES[level])
	}
	for form in Log_Record_Form {
		words, ok := contract_enum_member_words(.Log_Record_Form, u64(form))
		testing.expect(t, ok)
		testing.expect_value(t, words, LOG_RECORD_FORM_NAMES[form])
	}
	none_words := [?]u64{0, 1, max(u64)}
	for word in none_words {
		_, ok := contract_enum_member_words(.None, word)
		testing.expectf(t, !ok, "the enum None gives words for the word %d", word)
	}
	Refused_Word :: struct {
		which: value_kinds.Contract_Enum,
		word:  u64,
	}
	refused_words := [?]Refused_Word {
		{.Log_Level, u64(max(Log_Level)) + 1},
		{.Log_Level, u64(max(u32))},
		{.Log_Level, max(u64)},
		{.Status, u64(max(Status)) + 1},
		{.Status, u64(max(u32))},
		{.Status, max(u64)},
		{.Log_Record_Form, u64(max(Log_Record_Form)) + 1},
		{.Log_Record_Form, u64(max(u8))},
		{.Log_Record_Form, max(u64)},
	}
	for item in refused_words {
		words, ok := contract_enum_member_words(item.which, item.word)
		testing.expectf(t, !ok && words == "", "the word %d of %v gives the words %q", item.word, item.which, words)
	}
}

// A name that names no member gives no word: the empty name, another case
// of the letters, a name of a member of another enum, a name with a space,
// and any name of the enum None. Each member then gives back its own word
// from its name, the last member too.
@(test)
a_name_that_names_no_member_has_no_word :: proc(t: ^testing.T) {
	Refused :: struct {
		which: value_kinds.Contract_Enum,
		name:  string,
	}
	refused := [?]Refused {
		{.Log_Level, ""},
		{.Log_Level, "warning"},
		{.Log_Level, "WARNING"},
		{.Log_Level, "Warning "},
		{.Log_Level, "Fact"},
		{.Log_Record_Form, "Warning"},
		{.Log_Record_Form, "fact"},
		{.Status, ""},
		{.Status, "Itself"},
		{.Status, "Warning"},
		{.Log_Record_Form, ""},
		{.Stop_Cause, "itself"},
		{.Stop_Cause, "a holder"},
		{.Stop_Cause, "Done"},
		{.Stop_Outcome, "done"},
		{.Stop_Outcome, "Itself"},
		{.None, ""},
		{.None, "Info"},
	}
	for item in refused {
		word, ok := contract_enum_member_of_name(item.which, item.name)
		testing.expectf(t, !ok && word == 0, "the name %q of %v gives the word %d", item.name, item.which, word)
	}
	testing.expect_value(t, contract_enum_member_count(.None), 0)
	for level in Log_Level {
		word, ok := contract_enum_member_of_name(.Log_Level, LOG_LEVEL_NAMES[level])
		testing.expect(t, ok && word == u64(level))
	}
	for form in Log_Record_Form {
		word, ok := contract_enum_member_of_name(.Log_Record_Form, LOG_RECORD_FORM_NAMES[form])
		testing.expect(t, ok && word == u64(form))
	}
	last, last_ok := contract_enum_member_of_name(.Status, STATUS_NAMES[max(Status)])
	testing.expect(t, last_ok && last == u64(max(Status)))
	for cause in Stop_Cause {
		word, ok := contract_enum_member_of_name(.Stop_Cause, STOP_CAUSE_NAMES[cause])
		testing.expect(t, ok && word == u64(cause))
	}
	for outcome in Stop_Outcome {
		word, ok := contract_enum_member_of_name(.Stop_Outcome, STOP_OUTCOME_NAMES[outcome])
		testing.expect(t, ok && word == u64(outcome))
	}
}

// Each contract enum but None has the size of its type: the size of the
// field that the tool describes for it.
@(test)
each_contract_enum_has_the_size_of_its_type :: proc(t: ^testing.T) {
	testing.expect_value(t, CONTRACT_ENUM_SIZES[value_kinds.Contract_Enum.None], 0)
	testing.expect_value(t, CONTRACT_ENUM_SIZES[value_kinds.Contract_Enum.Status], u32(size_of(Status)))
	testing.expect_value(t, CONTRACT_ENUM_SIZES[value_kinds.Contract_Enum.Log_Level], u32(size_of(Log_Level)))
	testing.expect_value(t, CONTRACT_ENUM_SIZES[value_kinds.Contract_Enum.Log_Record_Form], u32(size_of(Log_Record_Form)))
	testing.expect_value(t, CONTRACT_ENUM_SIZES[value_kinds.Contract_Enum.Stop_Cause], u32(size_of(Stop_Cause)))
	testing.expect_value(t, CONTRACT_ENUM_SIZES[value_kinds.Contract_Enum.Stop_Outcome], u32(size_of(Stop_Outcome)))
	testing.expect_value(t, CONTRACT_ENUM_SIZES[value_kinds.Contract_Enum.Error_Kind], u32(size_of(errors.Kind)))
	testing.expect_value(t, CONTRACT_ENUM_SIZES[value_kinds.Contract_Enum.Error_Unit], u32(size_of(errors.Unit)))
	// A word type exactly when the table names one, at least as large as
	// its enum, and of a size that an Integer field has.
	for which in value_kinds.Contract_Enum {
		word_size := CONTRACT_ENUM_WORD_SIZES[which]
		has_word := value_kinds.CONTRACT_ENUM_TYPES[which].word_name != ""
		testing.expectf(t, has_word == (word_size != 0), "the enum %v has a word type %v and a word size %d", which, has_word, word_size)
		if has_word {
			testing.expectf(t, word_size >= CONTRACT_ENUM_SIZES[which] && (word_size == 1 || word_size == 2 || word_size == 4 || word_size == 8), "the word of %v has %d bytes", which, word_size)
		}
	}
	testing.expect_value(t, CONTRACT_ENUM_WORD_SIZES[value_kinds.Contract_Enum.Status], u32(size_of(Status_Word)))
	testing.expect_value(t, size_of(Status_Word), 8)
	// This package names each enum: a contract enum of a package that it
	// does not import would have no names here.
	for which in value_kinds.Contract_Enum {
		if which != .None {
			package_name := value_kinds.CONTRACT_ENUM_TYPES[which].package_name
			testing.expectf(t, package_name == "operation" || package_name == "errors", "the enum %v is of the package %s, which this package does not import", which, package_name)
		}
	}
}

// The enums of the error record: a word that names no member gives no name
// and no words: one past the last member, the largest word of 32 bits, and
// the largest word, which is the word -1 of the record. Each member gives
// its name, as the contract writes it, two members never one name, and the
// name gives back the word. A word of a unit names a unit, never a kind.
@(test)
the_words_of_an_error_record_have_their_names :: proc(t: ^testing.T) {
	Refused_Word :: struct {
		which: value_kinds.Contract_Enum,
		word:  u64,
	}
	refused_words := [?]Refused_Word {
		{.Error_Kind, u64(max(errors.Kind)) + 1},
		{.Error_Kind, u64(max(u32))},
		{.Error_Kind, max(u64)},
		{.Error_Unit, u64(max(errors.Unit)) + 1},
		{.Error_Unit, u64(max(u32))},
		{.Error_Unit, max(u64)},
	}
	for item in refused_words {
		name, ok := contract_enum_member_name(item.which, item.word)
		testing.expectf(t, !ok && name == "", "the word %d of %v gives the name %q", item.word, item.which, name)
		words, words_ok := contract_enum_member_words(item.which, item.word)
		testing.expectf(t, !words_ok && words == "", "the word %d of %v gives the words %q", item.word, item.which, words)
	}
	testing.expect_value(t, contract_enum_member_count(.Error_Kind), u64(max(errors.Kind)) + 1)
	testing.expect_value(t, contract_enum_member_count(.Error_Unit), u64(max(errors.Unit)) + 1)
	for kind in errors.Kind {
		name, ok := contract_enum_member_name(.Error_Kind, u64(kind))
		testing.expect(t, ok)
		testing.expect_value(t, name, errors.KIND_NAMES[kind])
		words, words_ok := contract_enum_member_words(.Error_Kind, u64(kind))
		testing.expect(t, words_ok && words == name)
		word, word_ok := contract_enum_member_of_name(.Error_Kind, name)
		testing.expect(t, word_ok && word == u64(kind))
		for other in errors.Kind {
			testing.expectf(t, other == kind || errors.KIND_NAMES[other] != name, "the kinds %v and %v have one name", kind, other)
		}
	}
	for unit in errors.Unit {
		name, ok := contract_enum_member_name(.Error_Unit, u64(unit))
		testing.expect(t, ok)
		testing.expect_value(t, name, errors.UNIT_MEMBER_NAMES[unit])
		word, word_ok := contract_enum_member_of_name(.Error_Unit, name)
		testing.expect(t, word_ok && word == u64(unit))
		for other in errors.Unit {
			testing.expectf(t, other == unit || errors.UNIT_MEMBER_NAMES[other] != name, "the units %v and %v have one name", unit, other)
		}
	}
	too_long, too_long_ok := contract_enum_member_name(.Error_Kind, u64(errors.Kind.Too_Long))
	testing.expect(t, too_long_ok && too_long == "Too_Long")
	// A name of a kind is no unit, and the words of a sentence are no name.
	_, bytes_as_kind := contract_enum_member_of_name(.Error_Kind, "Bytes")
	testing.expect(t, !bytes_as_kind)
	_, words_as_unit := contract_enum_member_of_name(.Error_Unit, "bytes")
	testing.expect(t, !words_as_unit)
}
