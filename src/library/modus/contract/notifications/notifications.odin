// Pure freestanding desktop notification queue, per-source rate limiting,
// Do-Not-Disturb filtering, and typed wire border.
package notifications

import "modus:contract/enum_word"

MAX_NOTIFICATIONS :: 64
MAX_TITLE_BYTES :: 96
MAX_BODY_BYTES :: 256
MAX_ACTIONS :: 3
MAX_ACTION_LABEL_BYTES :: 32
// The label of a card: the process name of a caller that does not act for
// the principal, as the root service names the connection.
MAX_LABEL_BYTES :: 32
// The cards that one labelled source shows at once: a process cannot fill
// the corner of the screen (src/md/features/tray_widgets.md, "The export
// notify").
CARDS_PER_SOURCE_LIMIT :: 3
// The source of the cards of the principal. A labelled source never has
// this number: source_of_caller_name sets the top bit.
PRINCIPAL_SOURCE :: u64(1)

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
	Label_Too_Long = 9, // The label passes MAX_LABEL_BYTES.
	Source_Full   = 10, // The source shows its bound of cards already.
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
	label:        [MAX_LABEL_BYTES]u8, // The process name of the caller, or empty for the principal.
	label_len:    u8,
}

// The sources whose last post the queue keeps for its rate: a source keeps
// its own slot, never a slot of another source. A full table gives the slot
// of the oldest post to a new source.
RATE_SOURCES :: 64

Notification_Queue :: struct {
	items:               [MAX_NOTIFICATIONS]Notification,
	next_id:             u64,
	do_not_disturb:      bool,
	min_interval_ms:     u64,
	rate_sources:        [RATE_SOURCES]u64, // The source of each slot; 0 is a free slot.
	rate_times_ms:       [RATE_SOURCES]u64, // The time of the last post of the source of the slot.
}

// rate_slot gives the slot of a source in the table of the rate, or the
// slot that a post of the source would take: a free one, else the one of
// the oldest post. found is false for a source with no slot.
rate_slot :: proc "contextless" (q: ^Notification_Queue, source_id: u64) -> (slot: int, found: bool) {
	oldest := 0
	for place in 0 ..< RATE_SOURCES {
		if q.rate_sources[place] == source_id && source_id != 0 {
			return place, true
		}
		if q.rate_sources[place] == 0 && q.rate_sources[oldest] != 0 || q.rate_sources[place] != 0 && q.rate_sources[oldest] != 0 && q.rate_times_ms[place] < q.rate_times_ms[oldest] {
			oldest = place
		}
	}
	return oldest, false
}

queue_init :: proc "contextless" (q: ^Notification_Queue, min_interval_ms: u64 = 1_000) {
	if q == nil {
		return
	}
	q^ = {next_id = 1, min_interval_ms = min_interval_ms}
}

// source_of_caller_name gives the source of the cards of a caller by its
// process name: the 64-bit FNV-1a hash of the name with the top bit set, so
// it is never PRINCIPAL_SOURCE.
source_of_caller_name :: proc "contextless" (name: string) -> u64 {
	hash: u64 = 0xCBF2_9CE4_8422_2325
	for index in 0 ..< len(name) {
		hash = (hash ~ u64(name[index])) * 0x0000_0100_0000_01B3
	}
	return hash | (u64(1) << 63)
}

// source_card_count gives the active cards of a source.
source_card_count :: proc "contextless" (q: ^Notification_Queue, source_id: u64) -> int {
	if q == nil {
		return 0
	}
	count := 0
	for &it in q.items {
		count += it.active && it.source_id == source_id ? 1 : 0
	}
	return count
}

// queue_post adds a card. A label names the caller on the card; a
// cards_limit above 0 bounds the active cards of the source. Each refusal
// changes nothing, the rate of the source too.
queue_post :: proc "contextless" (
	q: ^Notification_Queue,
	source_id: u64,
	urgency: Urgency,
	now_ms: u64,
	ttl_ms: u64,
	title: []u8,
	body: []u8,
	label: []u8 = nil,
	cards_limit := 0,
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
	if len(label) > MAX_LABEL_BYTES {
		return 0, .Label_Too_Long
	}
	if q.do_not_disturb && urgency != .Critical {
		return 0, .Suppressed
	}
	if cards_limit > 0 && source_card_count(q, source_id) >= cards_limit {
		return 0, .Source_Full
	}
	// Rate-limit non-critical notifications per source_id. The check only
	// reads: the time of the post is kept after the last refusal, so a
	// refused post costs the source nothing.
	rated := urgency != .Critical && q.min_interval_ms > 0
	slot, has_slot := rate_slot(q, source_id)
	if rated && has_slot && now_ms >= q.rate_times_ms[slot] && now_ms - q.rate_times_ms[slot] < q.min_interval_ms {
		return 0, .Rate_Limited
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
	if rated {
		q.rate_sources[slot], q.rate_times_ms[slot] = source_id, now_ms
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
		label_len  = u8(len(label)),
	}
	copy(it.title[:], title)
	copy(it.body[:], body)
	copy(it.label[:], label)
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
