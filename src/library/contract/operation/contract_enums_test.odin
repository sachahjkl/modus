#+build !freestanding
package operation

import "core:testing"
import "modus:contract/value_kinds"

// A word that names no member of its contract enum gives no name: one past
// the last member, the largest word of the enum, and the largest word. The
// enum None gives no name for any word, 0 too. Each member then gives its
// own name, and two members never give one name.
@(test)
a_word_that_names_no_member_has_no_name :: proc(t: ^testing.T) {
	refused_levels := [?]u64{u64(max(Log_Level)) + 1, u64(max(u8)), max(u64)}
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
	warning, warning_ok := contract_enum_member_name(.Log_Level, u64(Log_Level.Warning))
	testing.expect(t, warning_ok)
	testing.expect_value(t, warning, "Warning")
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
}

// Each contract enum but None has the size of its type: the size of the
// field that the tool describes for it.
@(test)
each_contract_enum_has_the_size_of_its_type :: proc(t: ^testing.T) {
	testing.expect_value(t, CONTRACT_ENUM_SIZES[value_kinds.Contract_Enum.None], 0)
	testing.expect_value(t, CONTRACT_ENUM_SIZES[value_kinds.Contract_Enum.Status], u32(size_of(Status)))
	testing.expect_value(t, CONTRACT_ENUM_SIZES[value_kinds.Contract_Enum.Log_Level], u32(size_of(Log_Level)))
	testing.expect_value(t, CONTRACT_ENUM_SIZES[value_kinds.Contract_Enum.Log_Record_Form], u32(size_of(Log_Record_Form)))
	for which in value_kinds.Contract_Enum {
		if which != .None {
			testing.expectf(t, value_kinds.CONTRACT_ENUM_TYPES[which].package_name == "operation", "the enum %v is not of this package", which)
		}
	}
}
