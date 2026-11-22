#+build !freestanding
package errors

import "core:testing"

// An error record comes from another process. Each word of its kind, its
// unit and its end that names no member is refused first: -1, one past the
// last member, the largest and the smallest word. Then each member comes
// back from its own word.
@(test)
a_word_of_an_error_record_that_names_no_member_is_refused :: proc(t: ^testing.T) {
	refuse :: proc(t: ^testing.T, words: []i64, read: proc "contextless" (word: i64) -> bool) {
		for word in words {
			testing.expectf(t, !read(word), "the word %d names no member, and it is taken", word)
		}
	}
	refuse(t, {-1, i64(max(Kind)) + 1, max(i64), min(i64)}, proc "contextless" (word: i64) -> bool {
		_, ok := kind_of_word(word)
		return ok
	})
	refuse(t, {-1, i64(max(Unit)) + 1, max(i64), min(i64)}, proc "contextless" (word: i64) -> bool {
		_, ok := unit_of_word(word)
		return ok
	})
	refuse(t, {-1, i64(max(End)) + 1, max(i64), min(i64)}, proc "contextless" (word: i64) -> bool {
		_, ok := end_of_word(word)
		return ok
	})
	for member in Kind {
		read, ok := kind_of_word(i64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in Unit {
		read, ok := unit_of_word(i64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
	for member in End {
		read, ok := end_of_word(i64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
}

// The fields of a log fact of an error record keep each word as it came: a
// kind and a unit that name no member (-1, one past the last member, the
// largest and the smallest word) stay their words, never another member,
// so a reader writes their number. A record of each member last, and the
// seven values in the order of the record.
@(test)
the_fields_of_an_error_record_keep_each_word :: proc(t: ^testing.T) {
	words := [?]i64{-1, i64(max(Kind)) + 1, i64(max(Unit)) + 1, max(i64), min(i64), 0}
	for word in words {
		fields := error_record_fact_fields({kind = word, unit = word, operation = word, argument = word, value = word, limit = word, found = word})
		testing.expect_value(t, u64(fields.kind), u64(word))
		testing.expect_value(t, u64(fields.unit), u64(word))
		testing.expect(t, fields.operation == word && fields.argument == word && fields.value == word && fields.limit == word && fields.found == word)
	}
	record := Error_Record{kind = i64(Kind.Too_Long), unit = i64(Unit.Bytes), operation = 3, argument = 2, value = 300, limit = 255, found = 7}
	fields := error_record_fact_fields(record)
	// The fields have the layout of the record: the same bytes.
	testing.expect_value(t, transmute([7]u64)fields, transmute([7]u64)record)
	kind, kind_ok := kind_of_word(i64(fields.kind))
	testing.expect(t, kind_ok && kind == .Too_Long)
	unit, unit_ok := unit_of_word(i64(fields.unit))
	testing.expect(t, unit_ok && unit == .Bytes)
	// Each member has a name and each unit a name of the contract, which
	// a column and a fact write: no name is empty.
	for member in Kind {
		testing.expectf(t, KIND_NAMES[member] != "", "the kind %v has no name", member)
	}
	for member in Unit {
		testing.expectf(t, UNIT_MEMBER_NAMES[member] != "", "the unit %v has no name", member)
	}
}

// A refusal record that another process sent is refused when its kind or
// its unit names no member, or when its kind is None: each edge of each
// word, and the zero record. Each other value passes as it is.
@(test)
a_refusal_record_that_names_no_kind_is_refused :: proc(t: ^testing.T) {
	bad_words := [?]i64{-1, i64(max(Kind)) + 1, max(i64), min(i64)}
	for word in bad_words {
		record, ok := refusal_record_of_values(completion_values({kind = word, unit = i64(Unit.Bytes)}))
		testing.expectf(t, !ok, "the kind word %d names no member, and it is taken", word)
		testing.expect_value(t, record, Error_Record{})
	}
	bad_unit_words := [?]i64{-1, i64(max(Unit)) + 1, max(i64), min(i64)}
	for word in bad_unit_words {
		_, ok := refusal_record_of_values(completion_values({kind = i64(Kind.Device), unit = word}))
		testing.expectf(t, !ok, "the unit word %d names no member, and it is taken", word)
	}
	_, zero_ok := refusal_record_of_values({})
	testing.expect(t, !zero_ok)
	_, none_ok := refusal_record_of_values(completion_values({kind = i64(Kind.None), unit = i64(Unit.Bytes), value = 5}))
	testing.expect(t, !none_ok)
	// Last: a whole record passes with each field as it was.
	sent := Error_Record{kind = i64(Kind.Device), unit = i64(Unit.Dropped_Writes), operation = 4, argument = 1, value = -3, limit = max(i64), found = min(i64)}
	record, ok := refusal_record_of_values(completion_values(sent))
	testing.expect(t, ok)
	testing.expect_value(t, record, sent)
}
