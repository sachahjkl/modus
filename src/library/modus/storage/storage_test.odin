#+build !freestanding
package storage

import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import "core:testing"

// The kind of a Listed row comes from the storage service. Each word that
// names no entry is refused first: None, one past the last kind, a
// negative word, the largest and the smallest word. Then each kind of an
// entry comes back from its own word.
@(test)
a_kind_that_names_no_entry_is_refused :: proc(t: ^testing.T) {
	refused := [?]i64{i64(Entry_Kind.None), i64(max(Entry_Kind)) + 1, -1, max(i64), min(i64)}
	for word in refused {
		_, ok := entry_kind_of_word(word)
		testing.expectf(t, !ok, "the kind %d names no entry, and it is taken", word)
	}
	for kind in Entry_Kind {
		if kind == .None {
			continue
		}
		read, ok := entry_kind_of_word(i64(kind))
		testing.expect(t, ok)
		testing.expect_value(t, read, kind)
	}
}

// The completion of a call comes from the storage service. Each outcome
// word that names no member is read first: one past the last member, a
// word far past it, the largest word. Each gives Answer_Unreadable, the
// value 0 whatever the service wrote, and the record of the word. Then each
// outcome that is not Succeeded gives its member and the value 0, and the
// success gives the value last.
@(test)
a_completion_reads_its_outcome_through_the_border :: proc(t: ^testing.T) {
	refused := [?]u64{u64(max(call_outcome.Call_Outcome)) + 1, 1 << 32, max(u64)}
	for word in refused {
		values: [7]u64
		values[0] = 12
		values[isolated.COMPLETION_OUTCOME_VALUE] = word
		value, outcome, unreadable := answer_of_completion(values)
		testing.expect_value(t, outcome, call_outcome.Call_Outcome.Answer_Unreadable)
		testing.expect_value(t, value, 0)
		testing.expect_value(t, unreadable.kind, i64(errors.Kind.Bad_Value))
		testing.expect_value(t, cast(u64)unreadable.value, word)
	}
	for member in call_outcome.Call_Outcome {
		values: [7]u64
		values[0] = 12
		values[isolated.COMPLETION_OUTCOME_VALUE] = u64(member)
		value, outcome, unreadable := answer_of_completion(values)
		testing.expect_value(t, outcome, member)
		testing.expect_value(t, unreadable, errors.Error_Record{})
		testing.expect_value(t, value, member == .Succeeded ? 12 : 0)
	}
}
