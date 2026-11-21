#+build !freestanding
package sentence

import "modus:contract/errors"
import op "modus:contract/operation"
import "core:strings"
import "core:testing"

// A value of a record that names no member is said as such: the sentence
// never takes it for a member. The values past the members come first:
// one past the last, a negative value, the largest value. The members come
// last.
@(test)
a_record_value_that_names_no_member_is_said :: proc(t: ^testing.T) {
	buffer: [512]u8
	no_member := [?]i64{i64(max(errors.Unanswered)) + 1, -1, max(i64)}
	for found in no_member {
		writer := Writer{buffer = buffer[:]}
		record := errors.error_make(.No_Answer, .Milliseconds, 0, 0, 1000, found)
		error_text(&writer, &record, "network.echo", "")
		line := written(&writer)
		testing.expectf(t, strings.contains(line, "which names nothing"), "found %d: the line is %q", found, line)
		testing.expectf(t, !strings.contains(line, "echo came back") && !strings.contains(line, "ARP") && !strings.contains(line, "device did not"), "found %d: the line is %q", found, line)
	}
	strengths := [?]i64{i64(max(op.Seed_Strength)) + 1, -1, max(i64)}
	for strength in strengths {
		writer := Writer{buffer = buffer[:]}
		record := errors.error_make(.Seed_Too_Weak, .None, 0, strength, i64(op.Seed_Strength.Processor))
		error_text(&writer, &record, "random.fill_for_a_key", "")
		line := written(&writer)
		testing.expectf(t, strings.contains(line, "a strength that names no member"), "strength %d: the line is %q", strength, line)
		testing.expectf(t, !strings.contains(line, "has the strength none"), "strength %d: the line is %q", strength, line)
	}
	writer := Writer{buffer = buffer[:]}
	record := errors.error_make(.No_Answer, .Milliseconds, 0, 0, 1000, i64(errors.Unanswered.Echo))
	error_text(&writer, &record, "network.echo", "")
	testing.expect(t, strings.contains(written(&writer), "no echo came back"))
	writer = Writer{buffer = buffer[:]}
	record = errors.error_make(.Seed_Too_Weak, .None, 0, i64(op.Seed_Strength.Weak), i64(op.Seed_Strength.Processor))
	error_text(&writer, &record, "random.fill_for_a_key", "")
	testing.expect(t, strings.contains(written(&writer), op.seed_strength_names[.Weak]))
	testing.expect(t, strings.contains(written(&writer), op.seed_strength_names[.Processor]))
	for unanswered in errors.Unanswered {
		read, ok := errors.unanswered_of_word(i64(unanswered))
		testing.expect(t, ok)
		testing.expect_value(t, read, unanswered)
	}
}
