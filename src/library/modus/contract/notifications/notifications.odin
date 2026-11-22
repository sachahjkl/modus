// Pure freestanding desktop notification queue, per-source rate limiting,
// Do-Not-Disturb filtering, and typed wire border.
package notifications

import "modus:contract/enum_word"

MAX_NOTIFICATIONS :: 64
MAX_TITLE_BYTES :: 96
MAX_BODY_BYTES :: 256
MAX_ACTIONS :: 3
MAX_ACTION_LABEL_BYTES :: 32

Urgency :: enum u8 {
	Low      = 1,
	Normal   = 2,
	Critical = 3,
}

urgency_of_word :: proc "contextless" (word: u64) -> (u: Urgency, ok: bool) {
	return enum_word.member_of_word(Urgency, word)
}

Notification_Refusal :: enum u8 {
	None          = 0,
	Nil_Queue     = 1,
	Empty_Title   = 2,
	Title_Too_Long = 3,
	Body_Too_Long = 4,
	Rate_Limited  = 5,
	Suppressed    = 6,
	Queue_Full    = 7,
	Not_Found     = 8,
}

Notification :: struct {
	active:       bool,
	id:           u64,
	source_id:    u64,
	urgency:      Urgency,
	created_ms:   u64,
	expire_ms:    u64,
	title:        [MAX_TITLE_BYTES]u8,
	title_len:    u16,
	body:         [MAX_BODY_BYTES]u8,
	body_len:     u16,
	action_count: u8,
	actions:      [MAX_ACTIONS][MAX_ACTION_LABEL_BYTES]u8,
	action_lens:  [MAX_ACTIONS]u8,
}

Notification_Queue :: struct {
	items:               [MAX_NOTIFICATIONS]Notification,
	next_id:             u64,
	do_not_disturb:      bool,
	min_interval_ms:     u64,
	last_source_id:      [16]u64,
	last_source_time_ms: [16]u64,
}

queue_init :: proc "contextless" (q: ^Notification_Queue, min_interval_ms: u64 = 1_000) {
	if q == nil {
		return
	}
	q^ = {next_id = 1, min_interval_ms = min_interval_ms}
}

queue_post :: proc "contextless" (
	q: ^Notification_Queue,
	source_id: u64,
	urgency: Urgency,
	now_ms: u64,
	ttl_ms: u64,
	title: []u8,
	body: []u8,
) -> (id: u64, refusal: Notification_Refusal) {
	if q == nil {
		return 0, .Nil_Queue
	}
	if len(title) == 0 {
		return 0, .Empty_Title
	}
	if len(title) > MAX_TITLE_BYTES {
		return 0, .Title_Too_Long
	}
	if len(body) > MAX_BODY_BYTES {
		return 0, .Body_Too_Long
	}
	if q.do_not_disturb && urgency != .Critical {
		return 0, .Suppressed
	}
	// Rate-limit non-critical notifications per source_id.
	if urgency != .Critical && q.min_interval_ms > 0 {
		slot_idx := int(source_id % 16)
		if q.last_source_id[slot_idx] == source_id && now_ms >= q.last_source_time_ms[slot_idx] && now_ms - q.last_source_time_ms[slot_idx] < q.min_interval_ms {
			return 0, .Rate_Limited
		}
		q.last_source_id[slot_idx] = source_id
		q.last_source_time_ms[slot_idx] = now_ms
	}
	free_idx := -1
	for &it, i in q.items {
		if !it.active {
			free_idx = i
			break
		}
	}
	if free_idx < 0 {
		return 0, .Queue_Full
	}
	assigned := q.next_id
	q.next_id += 1
	it := &q.items[free_idx]
	it^ = {
		active     = true,
		id         = assigned,
		source_id  = source_id,
		urgency    = urgency,
		created_ms = now_ms,
		expire_ms  = ttl_ms > 0 ? now_ms + ttl_ms : 0,
		title_len  = u16(len(title)),
		body_len   = u16(len(body)),
	}
	copy(it.title[:], title)
	copy(it.body[:], body)
	return assigned, .None
}

queue_dismiss :: proc "contextless" (q: ^Notification_Queue, id: u64) -> Notification_Refusal {
	if q == nil {
		return .Nil_Queue
	}
	for &it in q.items {
		if it.active && it.id == id {
			it.active = false
			return .None
		}
	}
	return .Not_Found
}

queue_expire :: proc "contextless" (q: ^Notification_Queue, now_ms: u64) -> int {
	if q == nil {
		return 0
	}
	removed := 0
	for &it in q.items {
		if it.active && it.expire_ms != 0 && now_ms >= it.expire_ms {
			it.active = false
			removed += 1
		}
	}
	return removed
}
