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
