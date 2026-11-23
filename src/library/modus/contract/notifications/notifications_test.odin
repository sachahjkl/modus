#+build !freestanding
package notifications

import "core:testing"

@(test)
notifications_rate_limit_dnd_and_expiration :: proc(t: ^testing.T) {
	_, bad := urgency_of_word(99)
	testing.expect(t, !bad)

	q: Notification_Queue
	queue_init(&q)

	_, re := queue_post(&q, 1, .Normal, 1000, 5000, nil, nil)
	testing.expect_value(t, re, Notification_Refusal.Empty_Title)

	id1, r1 := queue_post(&q, 1, .Normal, 1000, 5000, transmute([]u8)string("Build done"), transmute([]u8)string("0 errors"))
	testing.expect_value(t, r1, Notification_Refusal.None)
	testing.expect(t, id1 > 0)

	// Second post within 500ms from same source is rate-limited.
	_, r2 := queue_post(&q, 1, .Normal, 1200, 5000, transmute([]u8)string("Spam"), nil)
	testing.expect_value(t, r2, Notification_Refusal.Rate_Limited)

	// Do-Not-Disturb blocks Normal but lets Critical through.
	q.do_not_disturb = true
	_, r3 := queue_post(&q, 2, .Normal, 2000, 5000, transmute([]u8)string("Quiet"), nil)
	testing.expect_value(t, r3, Notification_Refusal.Suppressed)
	id_crit, r4 := queue_post(&q, 2, .Critical, 2000, 5000, transmute([]u8)string("Low battery"), nil)
	testing.expect_value(t, r4, Notification_Refusal.None)

	testing.expect_value(t, queue_expire(&q, 6500), 1) // id1 expired at 6000
	testing.expect_value(t, queue_dismiss(&q, id_crit), Notification_Refusal.None)
	testing.expect_value(t, queue_dismiss(&q, id_crit), Notification_Refusal.Not_Found)
}

// A labelled source past its bound of cards is refused, and the refusal
// changes nothing: no card, and no time of the rate of the source. A label
// past its bound is refused too. Then a card of the source keeps its label,
// and the principal source has no bound of its own.
@(test)
a_labelled_source_stops_at_its_bound_of_cards :: proc(t: ^testing.T) {
	q: Notification_Queue
	queue_init(&q)
	source := source_of_caller_name("clock")
	testing.expect(t, source != PRINCIPAL_SOURCE && source & (u64(1) << 63) != 0)
	testing.expect(t, source_of_caller_name("") != PRINCIPAL_SOURCE)
	testing.expect(t, source_of_caller_name("clock") != source_of_caller_name("paint"))
	label := transmute([]u8)string("clock")
	title := transmute([]u8)string("the timer ended")
	long_label := make([]u8, MAX_LABEL_BYTES + 1, context.temp_allocator)
	_, refused := queue_post(&q, source, .Normal, 0, 8000, title, nil, long_label, CARDS_PER_SOURCE_LIMIT)
	testing.expect_value(t, refused, Notification_Refusal.Label_Too_Long)
	testing.expect_value(t, source_card_count(&q, source), 0)
	for index in 0 ..< CARDS_PER_SOURCE_LIMIT {
		_, posted := queue_post(&q, source, .Normal, u64(index) * 1000, 8000, title, nil, label, CARDS_PER_SOURCE_LIMIT)
		testing.expect_value(t, posted, Notification_Refusal.None)
	}
	_, full := queue_post(&q, source, .Normal, 10_000, 8000, title, nil, label, CARDS_PER_SOURCE_LIMIT)
	testing.expect_value(t, full, Notification_Refusal.Source_Full)
	testing.expect_value(t, source_card_count(&q, source), CARDS_PER_SOURCE_LIMIT)
	// The refusal kept no time: once a card leaves, the next post is not
	// rate-limited by the refused one.
	testing.expect_value(t, queue_expire(&q, 8000), 1)
	id, again := queue_post(&q, source, .Normal, 10_000, 8000, title, nil, label, CARDS_PER_SOURCE_LIMIT)
	testing.expect_value(t, again, Notification_Refusal.None)
	// A label of exactly the bound is kept whole.
	whole := make([]u8, MAX_LABEL_BYTES, context.temp_allocator)
	for &byte in whole {
		byte = 'a'
	}
	other := source_of_caller_name(string(whole))
	_, bound_label := queue_post(&q, other, .Normal, 0, 8000, title, nil, whole, CARDS_PER_SOURCE_LIMIT)
	testing.expect_value(t, bound_label, Notification_Refusal.None)
	// The principal posts past the bound of a caller.
	for index in 0 ..< CARDS_PER_SOURCE_LIMIT + 2 {
		_, principal := queue_post(&q, PRINCIPAL_SOURCE, .Normal, u64(index) * 1000, 8000, title, nil)
		testing.expect_value(t, principal, Notification_Refusal.None)
	}
	for &item in q.items {
		if item.active && item.id == id {
			testing.expect_value(t, string(item.label[:item.label_len]), "clock")
			testing.expect_value(t, string(item.title[:item.title_len]), "the timer ended")
		}
		if item.active && item.source_id == PRINCIPAL_SOURCE {
			testing.expect_value(t, item.label_len, u8(0))
		}
	}
}

// A full queue refuses a post and changes nothing: no card, and no time of
// the rate of its source. The rate is kept by source: two sources that
// share a remainder of 16 keep two slots.
@(test)
a_full_queue_changes_nothing_and_the_rate_is_by_source :: proc(t: ^testing.T) {
	q: Notification_Queue
	queue_init(&q)
	title := transmute([]u8)string("card")
	for source in 1 ..= MAX_NOTIFICATIONS {
		_, posted := queue_post(&q, u64(source), .Normal, 1000, 8000, title, nil)
		testing.expect_value(t, posted, Notification_Refusal.None)
	}
	NEW :: u64(1000)
	_, full := queue_post(&q, NEW, .Normal, 2000, 8000, title, nil)
	testing.expect_value(t, full, Notification_Refusal.Queue_Full)
	_, kept_slot := rate_slot(&q, NEW)
	testing.expect(t, !kept_slot, "a refused post keeps no time")
	testing.expect_value(t, queue_dismiss(&q, 1), Notification_Refusal.None)
	_, again := queue_post(&q, NEW, .Normal, 2000, 8000, title, nil)
	testing.expect_value(t, again, Notification_Refusal.None)

	other: Notification_Queue
	queue_init(&other)
	_, first := queue_post(&other, 1, .Normal, 0, 8000, title, nil)
	_, shared_remainder := queue_post(&other, 17, .Normal, 0, 8000, title, nil)
	testing.expect(t, first == .None && shared_remainder == .None)
	_, soon := queue_post(&other, 1, .Normal, 100, 8000, title, nil)
	testing.expect_value(t, soon, Notification_Refusal.Rate_Limited)
	_, later := queue_post(&other, 1, .Normal, 600, 8000, title, nil)
	testing.expect_value(t, later, Notification_Refusal.None)
}

// A time of a card outside the range of the contract is refused, at each
// edge, and the refusal keeps no card and no time of the rate. A time that
// would pass the largest time of the clock is refused too.
@(test)
a_show_time_outside_the_range_is_refused :: proc(t: ^testing.T) {
	q: Notification_Queue
	queue_init(&q)
	title := transmute([]u8)string("the timer ended")
	for refused_time in ([?]u64{0, 1, SHOW_MILLISECONDS_LEAST - 1, SHOW_MILLISECONDS_MOST + 1, max(u64)}) {
		_, refusal := queue_post(&q, 1, .Normal, 1000, refused_time, title, nil)
		testing.expect_value(t, refusal, Notification_Refusal.Show_Time_Out_Of_Range)
	}
	_, near_the_end := queue_post(&q, 1, .Normal, max(u64) - 10, SHOW_MILLISECONDS_LEAST, title, nil)
	testing.expect_value(t, near_the_end, Notification_Refusal.Show_Time_Out_Of_Range)
	testing.expect_value(t, source_card_count(&q, 1), 0)
	// The refusals kept no time of the rate: a post at once is taken.
	_, least := queue_post(&q, 1, .Normal, 1000, SHOW_MILLISECONDS_LEAST, title, nil)
	testing.expect_value(t, least, Notification_Refusal.None)
	_, most := queue_post(&q, 2, .Normal, 1000, SHOW_MILLISECONDS_MOST, title, nil)
	testing.expect_value(t, most, Notification_Refusal.None)
	// The rate of one source is the one number of the contract.
	_, early := queue_post(&q, 1, .Normal, 1000 + RATE_INTERVAL_MILLISECONDS - 1, SHOW_MILLISECONDS_DEFAULT, title, nil)
	testing.expect_value(t, early, Notification_Refusal.Rate_Limited)
	_, on_time := queue_post(&q, 1, .Normal, 1000 + RATE_INTERVAL_MILLISECONDS, SHOW_MILLISECONDS_DEFAULT, title, nil)
	testing.expect_value(t, on_time, Notification_Refusal.None)
}
