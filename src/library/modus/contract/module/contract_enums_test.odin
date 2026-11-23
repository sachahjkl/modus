#+build !freestanding
package module

import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/pointer_pictures"
import "modus:contract/storage_status"
import "modus:contract/value_kinds"

// For each contract enum, the words that name no member come first: one
// past the last member, the largest word of 32 bits, and the largest word,
// the word -1 of a record; each gives no name and no words, and the enum
// None gives no name for any word. Then each member gives a name that is
// not empty, that no other member of its enum has, and that gives back its
// word; another case of the letters names nothing.
@(test)
each_contract_enum_names_its_members :: proc(t: ^testing.T) {
	for which in value_kinds.Contract_Enum {
		count := contract_enum_member_count(which)
		if which == .None {
			testing.expect_value(t, count, 0)
			for word in ([3]u64{0, 1, max(u64)}) {
				_, named := contract_enum_member_name(which, word)
				testing.expectf(t, !named, "the enum None names the word %d", word)
			}
			continue
		}
		testing.expectf(t, count > 0, "the enum %v has no member", which)
		for word in ([3]u64{count, u64(max(u32)), max(u64)}) {
			name, named := contract_enum_member_name(which, word)
			words, words_named := contract_enum_member_words(which, word)
			testing.expectf(t, !named && name == "" && !words_named && words == "", "the word %d of %v gives %q", word, which, name)
		}
		for word in 0 ..< count {
			name, named := contract_enum_member_name(which, word)
			testing.expectf(t, named && name != "", "the word %d of %v has no name", word, which)
			back, back_ok := contract_enum_member_of_name(which, name)
			testing.expectf(t, back_ok && back == word, "the name %q of %v gives back %d", name, which, back)
			for other in 0 ..< word {
				other_name, _ := contract_enum_member_name(which, other)
				testing.expectf(t, other_name != name, "the words %d and %d of %v have one name", other, word, which)
			}
			if name[0] >= 'A' && name[0] <= 'Z' {
				lower := make([]u8, len(name), context.temp_allocator)
				copy(lower, name)
				lower[0] += 'a' - 'A'
				_, lower_ok := contract_enum_member_of_name(which, string(lower))
				testing.expectf(t, !lower_ok, "the name %q of %v is read in lower case", name, which)
			}
		}
		_, empty_ok := contract_enum_member_of_name(which, "")
		testing.expect(t, !empty_ok)
	}
}

// The words of a stop in a sentence are the words that a line of a stop
// wrote before the facts; each other enum writes the name of its member.
@(test)
a_member_has_the_words_of_its_sentence :: proc(t: ^testing.T) {
	for cause in op.Stop_Cause {
		words, ok := contract_enum_member_words(.Stop_Cause, u64(cause))
		testing.expect(t, ok && words == op.STOP_CAUSE_TEXTS[cause])
	}
	for outcome in op.Stop_Outcome {
		words, ok := contract_enum_member_words(.Stop_Outcome, u64(outcome))
		testing.expect(t, ok && words == op.STOP_OUTCOME_TEXTS[outcome])
	}
	itself, itself_ok := contract_enum_member_words(.Stop_Cause, u64(op.Stop_Cause.Itself))
	testing.expect(t, itself_ok && itself == "itself")
	// The name, not the words, gives back the member.
	_, words_ok := contract_enum_member_of_name(.Stop_Cause, "itself")
	testing.expect(t, !words_ok)
	for which in value_kinds.Contract_Enum {
		if which == .None || which == .Stop_Cause || which == .Stop_Outcome {
			continue
		}
		for word in 0 ..< contract_enum_member_count(which) {
			name, _ := contract_enum_member_name(which, word)
			words, _ := contract_enum_member_words(which, word)
			testing.expectf(t, words == name, "the word %d of %v writes %q, not its name %q", word, which, words, name)
		}
	}
	// Some names, as a principal types them in a condition.
	too_long, _ := contract_enum_member_name(.Error_Kind, u64(errors.Kind.Too_Long))
	gone, _ := contract_enum_member_name(.Storage_Status, u64(storage_status.Status.Gone))
	in_doubt, _ := contract_enum_member_name(.Call_Outcome, u64(call_outcome.Call_Outcome.Callee_Stopped_During_The_Call))
	find, _ := contract_enum_member_name(.Load_Stage, u64(Load_Stage.Find))
	pixels, _ := contract_enum_member_name(.Pointer_Part, u64(pointer_pictures.Part.Pixels))
	memory, _ := contract_enum_member_name(.Object_Kind, u64(op.Object_Kind.Memory))
	testing.expect(t, too_long == "Too_Long" && gone == "Gone" && in_doubt == "Callee_Stopped_During_The_Call" && find == "Find" && pixels == "Pixels" && memory == "Memory")
}

// Each contract enum but None has the size of its type, and a word type
// exactly when the table names one, at least as large as the enum and of
// a size that an Integer field has.
@(test)
each_contract_enum_has_the_size_of_its_type :: proc(t: ^testing.T) {
	testing.expect_value(t, CONTRACT_ENUM_SIZES[.None], 0)
	testing.expect_value(t, CONTRACT_ENUM_SIZES[.Status], u32(size_of(op.Status)))
	testing.expect_value(t, CONTRACT_ENUM_SIZES[.Storage_Status], u32(size_of(storage_status.Status)))
	for which in value_kinds.Contract_Enum {
		size := CONTRACT_ENUM_SIZES[which]
		testing.expectf(t, which == .None || size == 1 || size == 2 || size == 4 || size == 8, "the enum %v has %d bytes", which, size)
		word_size := CONTRACT_ENUM_WORD_SIZES[which]
		has_word := value_kinds.CONTRACT_ENUM_TYPES[which].word_name != ""
		testing.expectf(t, has_word == (word_size != 0), "the enum %v has a word type %v and a word size %d", which, has_word, word_size)
		if has_word {
			testing.expectf(t, word_size >= size && word_size == 8, "the word of %v has %d bytes", which, word_size)
		}
	}
}
