#+build !freestanding
package system

import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/ring"
import "core:testing"

// The kernel and the root service write the status word of a completion.
// A word that names no status is refused first: one past the last status,
// a word of the high bit, the largest word. The refusal is Bad_Operation
// with the record Bad_Value of the word, never a status that the word did
// not name. Then each status comes back from its own word, with no record.
@(test)
status_of_word_refuses_a_word_that_names_no_status :: proc(t: ^testing.T) {
	refused_words := [?]u32{u32(max(Status)) + 1, 1 << 31, max(u32)}
	for word in refused_words {
		status, refusal := status_of_word(word)
		testing.expect_value(t, status, Status.Bad_Operation)
		testing.expect_value(t, refusal.kind, i64(errors.Kind.Bad_Value))
		testing.expect_value(t, refusal.value, i64(word))
		testing.expect_value(t, refusal.limit, i64(max(Status)))
	}
	for member in Status {
		status, refusal := status_of_word(u32(member))
		testing.expect_value(t, status, member)
		testing.expect_value(t, refusal, errors.Error_Record{})
	}
}

// The root service writes the kind of each command of the service ring. A
// kind that names no command is refused first: None, one past the last
// command, a word of the high bit, the largest word. Then each command
// comes back from its own kind.
@(test)
service_command_of_record_refuses_a_kind_that_names_no_command :: proc(t: ^testing.T) {
	refused_kinds := [?]u32{u32(isolated.Service_Command.None), u32(max(isolated.Service_Command)) + 1, 1 << 31, max(u32)}
	for kind in refused_kinds {
		_, ok := service_command_of_record(ring.Record{kind = kind})
		testing.expectf(t, !ok, "the kind %d names no service command, and it is taken", kind)
	}
	for member in isolated.Service_Command {
		if member == .None {
			continue
		}
		read, ok := service_command_of_record(ring.Record{kind = u32(member)})
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
}

// The size of the memory of a ring is checked before its product: the
// edges are 0, 1, the smallest ring, a count whose capacity is not a power
// of two, the largest ring, one page past it, and the largest count, whose
// product would wrap to a power of two.
@(test)
ring_pages_refusal_refuses_a_size_that_is_no_ring :: proc(t: ^testing.T) {
	largest := ring.pages(ring.CAPACITY_LIMIT)
	refused_counts := [?]u64{0, 1, ring.PAGE_COUNT + 2, largest - 1, largest + 1, 1 << 59 + 1, max(u64)}
	for count in refused_counts {
		refusal, refused := ring_pages_refusal(count)
		testing.expectf(t, refused, "the count of %d pages is no ring, and it is taken", count)
		testing.expect_value(t, refusal.kind, i64(errors.Kind.Bad_Value))
		testing.expect_value(t, refusal.unit, i64(errors.Unit.Pages))
		testing.expect_value(t, refusal.argument, 1)
		testing.expect_value(t, refusal.limit, i64(largest))
		testing.expect(t, refusal.value >= 0)
	}
	taken_counts := [?]u64{ring.PAGE_COUNT, ring.pages(64), ring.pages(ring.CAPACITY_LIMIT / 2), largest}
	for count in taken_counts {
		refusal, refused := ring_pages_refusal(count)
		testing.expectf(t, !refused, "the count of %d pages is a ring, and it is refused", count)
		testing.expect_value(t, refusal, errors.Error_Record{})
	}
}
