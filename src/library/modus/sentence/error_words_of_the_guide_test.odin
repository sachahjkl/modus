#+build !freestanding
package sentence

import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/start_grant"
import "core:fmt"
import "core:strings"
import "core:testing"

// The words that docs/WRITING.md, "Words that a text does not use", refuses
// in a sentence for a reader. "error" stays a noun ("error record"), so
// it is not in the list.
@(private = "file")
REFUSED_WORDS :: [?]string{"invalid", "illegal", "fatal", "please", "sorry", "n't", "abort", "kill"}

// Each kind with each unit gives a sentence that keeps the guide: it uses
// no refused word, it shows no bare negative number, it starts with a lower
// case letter after the name of the call, and it has no end period (the
// console line continues the name).
@(test)
each_sentence_keeps_the_words_of_the_guide :: proc(t: ^testing.T) {
	buffer: [512]u8
	refused := REFUSED_WORDS
	for kind in errors.Kind {
		for unit in errors.Unit {
			writer := Writer{buffer = buffer[:]}
			record := errors.error_make(kind, unit, 1, 5, 9, 2)
			error_text(&writer, &record, "sample.fill", "memory")
			line := written(&writer)
			sentence, _ := strings.substring_from(line, len("sample.fill: "))
			lower := strings.to_lower(line, context.temp_allocator)
			for word in refused {
				testing.expectf(t, !strings.contains(lower, word), "%v %v: the sentence %q uses %q", kind, unit, line, word)
			}
			testing.expectf(t, !strings.contains(line, "(-"), "%v %v: the sentence %q shows a bare negative number", kind, unit, line)
			testing.expectf(t, len(sentence) > 0 && !(sentence[0] >= 'A' && sentence[0] <= 'Z'), "%v %v: the sentence %q starts with a capital letter", kind, unit, line)
			testing.expectf(t, !strings.has_suffix(line, "."), "%v %v: the sentence %q has an end period", kind, unit, line)
		}
	}
}

// A refusal with no cause names who refused and says that no cause came:
// the status is a fact of the sentence, not the whole message.
@(test)
a_refusal_with_no_cause_says_who_refused :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	record := errors.error_make(.Refused, .None, 0, 0, 0, 7)
	error_text(&writer, &record, "storage.write", "")
	testing.expect_value(t, written(&writer), "storage.write: the receiver refused the call and gave no cause")

	// A kernel status is named in words, never by its name or its number.
	writer = Writer{buffer = buffer[:]}
	record = errors.error_make(.Refused, .None, 0, 0, 0, i64(op.Status.No_Right))
	record.operation = i64(op.Operation.Memory_Map)
	kernel_error_text(&writer, &record)
	testing.expect_value(t, written(&writer), "Memory_Map: the kernel refused the call: a handle does not have the right that the operation needs")

	writer = Writer{buffer = buffer[:]}
	record = errors.error_make(.Refused, .Kernel_Status, 0, 0, 0, i64(op.Status.Bad_Handle))
	error_text(&writer, &record, "monitor.count", "")
	testing.expect_value(t, written(&writer), "monitor.count: the kernel refused an operation of the call: a handle names no object of the kind that the operation needs")

	// A word of Kernel_Status that names no status, a negative word and the
	// largest word give the sentence with no cause: never a number.
	for word in ([?]i64{i64(max(op.Status)) + 1, -1, max(i64)}) {
		writer = Writer{buffer = buffer[:]}
		record = errors.error_make(.Refused, .Kernel_Status, 0, 0, 0, word)
		error_text(&writer, &record, "monitor.count", "")
		testing.expect_value(t, written(&writer), "monitor.count: the receiver refused the call and gave no cause")
	}
}

// A status, a kind or a problem that the sentence cannot name in words is
// not written as a number: the number stays on the detail lines.
@(test)
no_status_or_kind_is_written_as_a_number :: proc(t: ^testing.T) {
	buffer: [256]u8
	// Each code is a number that no other field of its record holds, so
	// the sentence holds it only if it writes the code.
	Coded :: struct {
		record: errors.Error_Record,
		code:   i64,
	}
	CODE :: 4242
	cases := [?]Coded {
		{errors.error_make(.Refused, .None, 0, 0, 0, CODE), CODE},
		{errors.error_make(.Refused, .Kernel_Status, 0, 0, 0, CODE), CODE},
		{errors.error_make(.Device, .None, 0, 0, 0, CODE), CODE},
		{errors.error_make(.Malformed, .None, 0, CODE, 0, 9), CODE},
		{{kind = i64(max(errors.Kind)) + CODE}, i64(max(errors.Kind)) + CODE},
		{errors.error_make(.No_Grant, .Debug_Access, 0, 0, 0, 1 + i64(max(start_grant.Grant)) + CODE), i64(max(start_grant.Grant)) + CODE},
		{errors.error_make(.No_Answer, .Milliseconds, 0, 0, 500, i64(max(errors.Unanswered)) + CODE), i64(max(errors.Unanswered)) + CODE},
	}
	for &item in cases {
		writer := Writer{buffer = buffer[:]}
		error_text(&writer, &item.record, "call", "")
		line := written(&writer)
		testing.expectf(t, !strings.contains(line, fmt.tprint(item.code)), "the sentence %q writes the code %d", line, item.code)
	}
	for status in op.Status {
		text := kernel_status_text(status)
		testing.expectf(t, len(text) > 0 && !strings.contains_any(text, "0123456789_"), "the words of %v are %q", status, text)
	}
}

// A missing grant says who can give it. The debug access is not a start
// grant, so its sentence names no fix.
@(test)
a_missing_grant_says_who_gives_it :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	record := errors.error_make(.No_Grant, .Acts_For_Principal)
	error_text(&writer, &record, "monitor.processes", "")
	testing.expect_value(t, written(&writer), "monitor.processes: the caller has no grant for this: to act for the principal; only the starter of the process can give this grant")

	writer = Writer{buffer = buffer[:]}
	record = errors.error_make(.No_Grant, .Debug_Access, 1)
	error_text(&writer, &record, "debugger.attach", "process")
	testing.expect(t, !strings.contains(written(&writer), "starter"))
}

// A full table, an answer that did not come and a module that breaks the
// format each say the problem first, with the facts that a reader can use.
@(test)
the_problem_comes_before_its_code :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	record := errors.error_make(.Full)
	error_text(&writer, &record, "debugger.attach", "")
	testing.expect_value(t, written(&writer), "debugger.attach: the receiver has no free place for the call")

	writer = Writer{buffer = buffer[:]}
	record = errors.error_make(.No_Answer, .Milliseconds, 0, 0x0A000202, 2000, i64(errors.Unanswered.Echo))
	error_text(&writer, &record, "net.ping", "")
	testing.expect_value(t, written(&writer), "net.ping: 10.0.2.2 did not answer in 2000 ms: no echo came back")

	writer = Writer{buffer = buffer[:]}
	record = errors.error_make(.No_Answer, .Milliseconds, 0, 0, 500, i64(errors.Unanswered.Device))
	error_text(&writer, &record, "disk.read", "")
	testing.expect_value(t, written(&writer), "disk.read: no answer came in 500 ms: the device did not answer")

	writer = Writer{buffer = buffer[:]}
	record = errors.error_make(.Malformed, .None, 1, 3, 0, 9)
	error_text(&writer, &record, "manual.show", "name")
	testing.expect_value(t, written(&writer), "manual.show: the module of the argument name breaks a rule of the module format at byte 9")
}
