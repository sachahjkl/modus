#+build !freestanding
package wide_grants

import "core:testing"

// The border of an answer refuses each wrong word first: no flow, a
// decision that names nothing, a refusal with words, scopes that name no
// scope or Send_Input alone, a duration of 0 or one past the bound, a count
// of 0 or one past the most, an id of 0, an id twice, an id past the count.
// A good answer round-trips last.
@(test)
a_screen_answer_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	good := Screen_Answer {
		flow_serial  = 7,
		decision     = .Give,
		authorities  = {.View_Screen, .Send_Input},
		duration_ms  = SCREEN_DURATION_ONE_HOUR,
		window_count = 3,
		window_ids   = {0 = 1, 1 = 5, 2 = SCREEN_WINDOW_ID_MOST},
	}
	base := screen_answer_values(good)
	change :: proc(values: [7]u64, place: int, word: u64) -> [7]u64 {
		changed := values
		changed[place] = word
		return changed
	}
	cases := [?]struct {
		values:  [7]u64,
		refusal: Screen_Answer_Refusal,
	} {
		{change(base, 0, 0), .No_Flow},
		{change(base, 1, 0), .Bad_Decision},
		{change(base, 1, 3), .Bad_Decision},
		{change(base, 1, max(u64)), .Bad_Decision},
		{{7, u64(Screen_Decision.Refuse), 1, 0, 0, 0, 0}, .Words_After_Refuse},
		{change(base, 2, 0), .Bad_Authorities},
		{change(base, 2, 1), .Bad_Authorities},
		{change(base, 2, wide_authorities_to_word({.Send_Input})), .Bad_Authorities},
		{change(base, 3, 0), .Bad_Duration},
		{change(base, 3, MAX_WIDE_GRANT_DURATION_MS + 1), .Bad_Duration},
		{change(base, 4, 0), .Bad_Window_Count},
		{change(base, 4, SCREEN_WINDOWS_MOST + 1), .Bad_Window_Count},
		{change(base, 5, base[5] & ~u64(0xFFFF_FFFF)), .Bad_Window},
		{change(base, 5, (base[5] & 0xFFFF_FFFF) | (1 << 32)), .Bad_Window},
		{change(base, 6, base[6] | (9 << 32)), .Bad_Window},
		{change(base, 4, 2), .Bad_Window},
		{change(base, 2, wide_authorities_to_word({.View_Screen, .Read_Semantic_Tree})), .Bad_Authorities},
	}
	for case_of, index in cases {
		_, refusal := screen_answer_of_values(case_of.values)
		testing.expectf(t, refusal == case_of.refusal, "case %d: %v, not %v", index, refusal, case_of.refusal)
	}
	refused, refusal := screen_answer_of_values({7, u64(Screen_Decision.Refuse), 0, 0, 0, 0, 0})
	testing.expect_value(t, refusal, Screen_Answer_Refusal.None)
	testing.expect_value(t, refused.decision, Screen_Decision.Refuse)
	read, read_refusal := screen_answer_of_values(base)
	testing.expect_value(t, read_refusal, Screen_Answer_Refusal.None)
	testing.expect_value(t, read, good)
	testing.expect(t, window_in_bound(&read, 5))
	testing.expect(t, !window_in_bound(&read, 0))
	testing.expect(t, !window_in_bound(&read, 2))
	testing.expect(t, !window_in_bound(&refused, 1))
	// A window that closes leaves the bound; the others stay, and with
	// none left no window is in it.
	window_leaves_bound(&read, 5)
	testing.expect(t, !window_in_bound(&read, 5))
	testing.expect(t, window_in_bound(&read, 1) && window_in_bound(&read, SCREEN_WINDOW_ID_MOST))
	testing.expect_value(t, read.window_count, u32(2))
	window_leaves_bound(&read, 77)
	testing.expect_value(t, read.window_count, u32(2))
	window_leaves_bound(&read, 1)
	window_leaves_bound(&read, SCREEN_WINDOW_ID_MOST)
	testing.expect_value(t, read.window_count, u32(0))
	testing.expect(t, !window_in_bound(&read, 1))
}

// The ask of an agent on a stream of `remote`: a stream of each wrong
// length, another kind, a reserved word, scopes that name nothing, a scope
// that the screen does not draw, Send_Input alone, a duration of 0 or one
// past the bound. A good ask round-trips last.
@(test)
an_ask_of_an_agent_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	bytes: [32]u8
	good, written := wide_grant_ask_write(bytes[:], {.View_Screen, .Send_Input}, SCREEN_DURATION_ONE_HOUR)
	testing.expect(t, written)
	_, no_room := wide_grant_ask_write(bytes[:23], {.View_Screen}, 1)
	testing.expect(t, !no_room)
	changed :: proc(from: []u8, offset: int, word: u64, size: int) -> [24]u8 {
		copy_of: [24]u8
		copy(copy_of[:], from)
		for index in 0 ..< size {
			copy_of[offset + index] = u8(word >> (8 * u64(index)))
		}
		return copy_of
	}
	cases := [?]struct {
		bytes: [24]u8,
		field: i64,
	} {
		{changed(good, 0, 1, 4), WIDE_GRANT_ASK_FIELD_KIND},
		{changed(good, 0, 0, 4), WIDE_GRANT_ASK_FIELD_KIND},
		{changed(good, 0, max(u64), 4), WIDE_GRANT_ASK_FIELD_KIND},
		{changed(good, 4, 1, 4), WIDE_GRANT_ASK_FIELD_RESERVED},
		{changed(good, 8, 0, 8), WIDE_GRANT_ASK_FIELD_AUTHORITIES},
		{changed(good, 8, 1, 8), WIDE_GRANT_ASK_FIELD_AUTHORITIES},
		{changed(good, 8, wide_authorities_to_word({.Send_Input}), 8), WIDE_GRANT_ASK_FIELD_AUTHORITIES},
		{changed(good, 8, wide_authorities_to_word({.View_Screen, .Read_Semantic_Tree}), 8), WIDE_GRANT_ASK_FIELD_AUTHORITIES},
		{changed(good, 8, max(u64), 8), WIDE_GRANT_ASK_FIELD_AUTHORITIES},
		{changed(good, 16, 0, 8), WIDE_GRANT_ASK_FIELD_DURATION},
		{changed(good, 16, MAX_WIDE_GRANT_DURATION_MS + 1, 8), WIDE_GRANT_ASK_FIELD_DURATION},
		{changed(good, 16, max(u64), 8), WIDE_GRANT_ASK_FIELD_DURATION},
	}
	for case_of, index in cases {
		ask := case_of.bytes
		_, _, error, ok := wide_grant_ask_check(ask[:])
		testing.expectf(t, !ok && error.argument == case_of.field, "case %d: ok %v, field %d", index, ok, error.argument)
	}
	for length in ([?]int{0, 1, 23, 25, 32}) {
		longer: [32]u8
		copy(longer[:], good)
		_, _, error, ok := wide_grant_ask_check(longer[:length])
		testing.expectf(t, !ok && error.argument == 0, "a stream of %d bytes is taken", length)
	}
	authorities, duration, _, ok := wide_grant_ask_check(good)
	testing.expect(t, ok)
	testing.expect_value(t, authorities, Wide_Authorities{.View_Screen, .Send_Input})
	testing.expect_value(t, duration, SCREEN_DURATION_ONE_HOUR)
	edge, _ := wide_grant_ask_write(bytes[:], {.View_Screen}, MAX_WIDE_GRANT_DURATION_MS)
	_, edge_duration, _, edge_ok := wide_grant_ask_check(edge)
	testing.expect(t, edge_ok && edge_duration == MAX_WIDE_GRANT_DURATION_MS)
}

// A writer runs an act only when its record left: each status of the
// output but Ok refuses the act while a grant holds, a ring with no reader
// as well as a full one; with no grant the writer writes nothing.
@(test)
an_act_whose_record_did_not_leave_does_not_run :: proc(t: ^testing.T) {
	Fake :: struct {
		status: Act_Write_Status,
		writes: int,
	}
	write :: proc "contextless" (user: rawptr, record: Act_Stream_Record) -> Act_Write_Status {
		fake := (^Fake)(user)
		fake.writes += 1
		return fake.status
	}
	record := Act_Stream_Record{grant_serial = 3, principal_id = 1, timestamp_ms = 10, producer_word = u64(Act_Producer.Remote_Service), act_kind_word = u64(Act_Kind.Call_Made)}
	for status in Act_Write_Status {
		fake := Fake{status = status}
		outcome, given := act_emit(write, &fake, record)
		testing.expect_value(t, given, status)
		testing.expect_value(t, outcome, status == .Ok ? Act_Emit_Outcome.Recorded : Act_Emit_Outcome.Refused)
		testing.expect_value(t, fake.writes, 1)
	}
	no_grant := record
	no_grant.grant_serial = 0
	fake := Fake{status = .No_Reader}
	outcome, _ := act_emit(write, &fake, no_grant)
	testing.expect_value(t, outcome, Act_Emit_Outcome.No_Grant)
	testing.expect_value(t, fake.writes, 0)
}

// The display writes its counts before each other record: a key at 100,
// then a view that opens at 200, gives the counts at 100 then the view at
// 200, so the times of the ring never go back, and the end has no counts
// left. A record of counts that does not leave refuses the record after it
// and keeps the counts; a change of window carries the counts itself.
@(test)
the_counts_leave_before_each_other_record_of_the_display :: proc(t: ^testing.T) {
	Fake :: struct {
		status:  Act_Write_Status,
		records: [8]Act_Stream_Record,
		count:   int,
	}
	write :: proc "contextless" (user: rawptr, record: Act_Stream_Record) -> Act_Write_Status {
		fake := (^Fake)(user)
		if fake.status == .Ok {
			fake.records[fake.count] = record
			fake.count += 1
		}
		return fake.status
	}
	frame_read :: proc(time_ms: u64) -> Act_Stream_Record {
		return {grant_serial = 2, principal_id = 1, timestamp_ms = time_ms, producer_word = u64(Act_Producer.Trusted_Display), act_kind_word = u64(Act_Kind.Frame_Read), detail_word_0 = 1}
	}
	target := Input_Target{window = 5}
	input_target_count(&target, .Key, 100)
	// The ring is full: the counts do not leave, so the view does not open,
	// and the counts wait.
	fake := Fake{status = .Full}
	outcome, status := display_emit(write, &fake, &target, frame_read(200))
	testing.expect_value(t, outcome, Act_Emit_Outcome.Refused)
	testing.expect_value(t, status, Act_Write_Status.Full)
	testing.expect_value(t, target.keys, u64(1))
	fake.status = .Ok
	outcome, _ = display_emit(write, &fake, &target, frame_read(200))
	testing.expect_value(t, outcome, Act_Emit_Outcome.Recorded)
	testing.expect_value(t, fake.count, 2)
	testing.expect_value(t, Act_Kind(fake.records[0].act_kind_word), Act_Kind.Input_Counted)
	testing.expect_value(t, fake.records[0].timestamp_ms, u64(100))
	testing.expect_value(t, fake.records[0].detail_word_0, u64(1))
	testing.expect_value(t, Act_Kind(fake.records[1].act_kind_word), Act_Kind.Frame_Read)
	testing.expect_value(t, fake.records[1].timestamp_ms, u64(200))
	for index in 1 ..< fake.count {
		testing.expect(t, fake.records[index].timestamp_ms >= fake.records[index - 1].timestamp_ms, "a time of the ring went back")
	}
	_, needed := input_target_counts_record(&target, 2, 1)
	testing.expect(t, !needed)
	// A change of window carries the counts: no record of counts before it.
	input_target_count(&target, .Press, 300)
	change, _ := input_target_record(&target, 2, 1, 9, 310)
	_, _ = display_emit(write, &fake, &target, change)
	testing.expect_value(t, fake.count, 3)
	testing.expect_value(t, Act_Kind(fake.records[2].act_kind_word), Act_Kind.Target_Window_Changed)
	testing.expect_value(t, fake.records[2].detail_word_1, u64(1))
	// No grant: nothing is written.
	no_grant := frame_read(400)
	no_grant.grant_serial = 0
	outcome, _ = display_emit(write, &fake, &target, no_grant)
	testing.expect_value(t, outcome, Act_Emit_Outcome.No_Grant)
	testing.expect_value(t, fake.count, 3)
}

// The record of a call of `remote`: the head of the hash, little-endian,
// and the bytes of the request, from the writer `remote`; it passes the
// border of a ring of act records, with no window.
@(test)
a_call_leaves_its_record :: proc(t: ^testing.T) {
	hash: [32]u8
	for index in 0 ..< 32 {
		hash[index] = u8(index + 1)
	}
	record := call_made_record(4, 1, hash, 104, 77)
	testing.expect_value(t, record.detail_word_0, u64(0x0807060504030201))
	testing.expect_value(t, record.detail_word_1, u64(104))
	testing.expect_value(t, record.target_window_id, u64(0))
	producer, kind, refusal := act_stream_record_validate(&record)
	testing.expect_value(t, refusal, Act_Wiring_Refusal.None)
	testing.expect_value(t, producer, Act_Producer.Remote_Service)
	testing.expect_value(t, kind, Act_Kind.Call_Made)
	no_grant := call_made_record(0, 1, hash, 104, 77)
	Fake :: struct {
		writes: int,
	}
	write :: proc "contextless" (user: rawptr, record: Act_Stream_Record) -> Act_Write_Status {
		(^Fake)(user).writes += 1
		return .Ok
	}
	fake: Fake
	outcome, _ := act_emit(write, &fake, no_grant)
	testing.expect_value(t, outcome, Act_Emit_Outcome.No_Grant)
	testing.expect_value(t, fake.writes, 0)
}

// The trusted display writes one record for each change of the window of
// the input, with the counts of the window before it; a refused record
// leaves the target as it was, so the next act asks for the record again.
@(test)
the_input_of_a_viewer_leaves_one_record_per_target :: proc(t: ^testing.T) {
	target: Input_Target
	first, needed := input_target_record(&target, 2, 1, 7, 100)
	testing.expect(t, needed)
	testing.expect_value(t, first.target_window_id, u64(7))
	testing.expect_value(t, Act_Kind(first.act_kind_word), Act_Kind.Target_Window_Changed)
	// The record did not leave: no change.
	_, needed = input_target_record(&target, 2, 1, 7, 100)
	testing.expect(t, needed)
	input_target_taken(&target, 7)
	for index in u64(0) ..< 40 {
		input_target_count(&target, .Key, 101 + index)
	}
	input_target_count(&target, .Press, 141)
	input_target_count(&target, .Move, 150)
	_, needed = input_target_record(&target, 2, 1, 7, 110)
	testing.expect(t, !needed)
	next, next_needed := input_target_record(&target, 2, 1, 9, 120)
	testing.expect(t, next_needed)
	testing.expect_value(t, next.detail_word_0, u64(40))
	testing.expect_value(t, next.detail_word_1, u64(1))
	producer, kind, refusal := act_stream_record_validate(&next)
	testing.expect_value(t, refusal, Act_Wiring_Refusal.None)
	testing.expect_value(t, producer, Act_Producer.Trusted_Display)
	testing.expect_value(t, kind, Act_Kind.Target_Window_Changed)
	input_target_taken(&target, 9)
	testing.expect_value(t, target, Input_Target{window = 9})
}

// The counts of the last window: none waits with no key and no press, and
// a move counts nothing; the record of the counts carries the time of the
// last act, so at the end of a grant it comes before the end; once taken,
// the counts start again on the same window.
@(test)
the_counts_of_the_last_window_are_kept :: proc(t: ^testing.T) {
	target: Input_Target
	_, needed := input_target_counts_record(&target, 2, 1)
	testing.expect(t, !needed)
	input_target_taken(&target, 5)
	input_target_count(&target, .Move, 200)
	_, needed = input_target_counts_record(&target, 2, 1)
	testing.expect(t, !needed)
	input_target_count(&target, .Key, 210)
	input_target_count(&target, .Key, 220)
	input_target_count(&target, .Press, 230)
	input_target_count(&target, .Move, 900)
	counts, counts_needed := input_target_counts_record(&target, 2, 1)
	testing.expect(t, counts_needed)
	testing.expect_value(t, counts.timestamp_ms, u64(230))
	testing.expect_value(t, counts.target_window_id, u64(5))
	testing.expect_value(t, counts.detail_word_0, u64(2))
	testing.expect_value(t, counts.detail_word_1, u64(1))
	_, kind, refusal := act_stream_record_validate(&counts)
	testing.expect_value(t, refusal, Act_Wiring_Refusal.None)
	testing.expect_value(t, kind, Act_Kind.Input_Counted)
	input_target_counts_taken(&target)
	_, needed = input_target_counts_record(&target, 2, 1)
	testing.expect(t, !needed)
	testing.expect_value(t, target.window, u64(5))
}

// The border of a screen and of a mark: a flow of 0, a word past the
// record, scopes that name no scope, a duration out of bound, a clear with
// words; then the good records round-trip.
@(test)
a_screen_or_a_mark_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	show := Screen_Show{flow_serial = 3, principal_id = 1, authorities = {.View_Screen}, duration_ms = 1000, client_key_head = 0xAB}
	values := screen_show_values(show)
	bad_shows := [?][7]u64{{0, 1, 2, 1000, 0, 0, 0}, {3, 1, 2, 1000, 0, 1, 0}, {3, 1, 0, 1000, 0, 0, 0}, {3, 1, 4, 1000, 0, 0, 0}, {3, 1, 2, 0, 0, 0, 0}, {3, 1, 2, MAX_WIDE_GRANT_DURATION_MS + 1, 0, 0, 0}}
	for bad in bad_shows {
		_, ok := screen_show_of_values(bad)
		testing.expect(t, !ok, "a wrong screen is taken")
	}
	read, ok := screen_show_of_values(values)
	testing.expect(t, ok && read == show)

	bad_marks := [?][7]u64{{0, 1, 0, 0, 0, 0, 0}, {1, 0, 0, 5, 1, 0, 0}, {1, 0, 2, 0, 1, 0, 0}, {1, 0, 2, 5, 0, 0, 0}, {1, 0, 2, 5, 1, 0, 9}}
	for bad in bad_marks {
		_, mark_ok := mark_of_values(bad)
		testing.expect(t, !mark_ok, "a wrong mark is taken")
	}
	cleared, cleared_ok := mark_of_values({})
	testing.expect(t, cleared_ok && cleared.grant_serial == 0)
	mark := Mark{grant_serial = 4, principal_id = 1, authorities = {.View_Screen, .Send_Input}, ends_at_ms = 99, flow_serial = 3}
	mark_read, mark_ok := mark_of_values(mark_values(mark))
	testing.expect(t, mark_ok && mark_read == mark)
}
