#+build !freestanding
package notifications

import "core:testing"

@(test)
notifications_rate_limit_dnd_and_expiration :: proc(t: ^testing.T) {
	_, bad := urgency_of_word(99)
	testing.expect(t, !bad)

	q: Notification_Queue
	queue_init(&q, min_interval_ms = 500)

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
	queue_init(&q, min_interval_ms = 500)
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
