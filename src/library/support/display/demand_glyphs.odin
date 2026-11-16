package display

import "modus:contract/demand_cache"
import "modus:contract/fixed_addresses"
import "modus:contract/glyph_cache"
import "modus:contract/ring"
import "modus:support/system"

// Glyphs drawn on demand (src/md/features/glyphs_on_demand.md): the side
// of a program. The root service maps the demand cache read-only and the
// request ring of the program with Write at their fixed ranges. A frame:
//
//   display.demand_frame_begin(&demand)         // one generation for the frame
//   spacing.demand = &demand.reader              // the shaper finds and wants
//   ... shape, measure, graphics.text_proportional(..., &demand.reader) ...
//   display.demand_requests_send(&demand)       // the wanted characters, once each
//
// and the wait of its loop adds display.demand_wait: an answer of the font
// service wakes the program, display.demand_answers_take says that a glyph
// came, and the program draws again. The program never waits for the
// service: a character that is not ready draws the replacement glyph.

// The characters past the glyph cache that a program asks for in its life.
// It asks for each one once: an answer, a refusal or an absent glyph never
// makes it ask again, so a full cache costs no loop of requests.
DEMAND_ASKED_LIMIT :: 256

// Demand: the demand cache of a program and its request ring.
Demand :: struct {
	reader:          demand_cache.Reader, // The reader of the frame: the shaper and the draw take it.
	requests:        ring.Ring, // The request ring, mapped by the starter.
	asked:           [DEMAND_ASKED_LIMIT]rune, // The characters asked for, once each.
	asked_count:     int,
	asked_full_told: bool, // The line of a full list is on the log.
	tag:             u32, // The tag of the last request.
	drawn:           u64, // The characters that the answers say the demand cache holds now: drawn for this program, or before.
	absent:          u64, // The characters that the answers say the font does not have.
	refused:         u64, // The characters that the answers say did not fit the cache.
}

// demand_open opens the demand cache and the request ring that the starter
// mapped, for the glyphs that stand beside a glyph cache of the interface
// font. ok is false when the starter mapped neither (the program then
// draws the replacement glyph for each character past the glyph cache),
// or when the cache has another form (demand_cache.reader_matches).
demand_open :: proc "contextless" (ctx: ^system.Context, cache: ^glyph_cache.Cache) -> (demand: Demand, ok: bool) {
	mapped := fixed_addresses.ranges_mapped(&ctx.values)
	if .Demand_Cache not_in mapped || .Glyph_Requests not_in mapped {
		return {}, false
	}
	demand.reader, ok = demand_cache.reader_of(uintptr(demand_cache.ADDRESS), cache)
	if !ok {
		return {}, false
	}
	demand.requests, ok = ring.open(rawptr(uintptr(demand_cache.REQUESTS_ADDRESS)), demand_cache.REQUEST_RING_PAGES)
	if !ok {
		return {}, false
	}
	return demand, true
}

// demand_frame_begin starts a frame: the generation that its measure and
// its draw use, and an empty list of wanted characters.
demand_frame_begin :: proc "contextless" (demand: ^Demand) {
	demand_cache.reader_frame_begin(&demand.reader)
}

// demand_asked says if the program asked for a character before.
@(private)
demand_asked :: proc "contextless" (demand: ^Demand, character: rune) -> bool {
	for asked in demand.asked[:demand.asked_count] {
		if asked == character {
			return true
		}
	}
	return false
}

// demand_requests_send asks, at the end of a frame, for each wanted
// character that the program did not ask for before, in records of
// demand_cache.CHARACTERS_PER_REQUEST. A full ring keeps the rest: they
// stay wanted, and a later frame sends them. The answers to the records in
// the ring wake the program for that frame.
demand_requests_send :: proc "contextless" (demand: ^Demand) {
	if demand.requests.head == nil {
		return
	}
	pending: [demand_cache.WANTED_LIMIT]rune
	count := 0
	for character in demand.reader.wanted[:demand.reader.wanted_count] {
		if !demand_asked(demand, character) {
			pending[count] = character
			count += 1
		}
	}
	sent := 0
	for sent < count {
		room := DEMAND_ASKED_LIMIT - demand.asked_count
		if room == 0 {
			if !demand.asked_full_told {
				demand.asked_full_told = true
				system.log_in("programs", .Warning, "display: this program asked for ", u64(DEMAND_ASKED_LIMIT), " characters past the glyph cache: it asks for no more, and draws the replacement glyph for the others")
			}
			break
		}
		take := min(count - sent, room)
		record, packed := demand_cache.request_pack(pending[sent:sent + take], demand.tag + 1)
		if !ring.push(&demand.requests.commands, record) {
			break
		}
		demand.tag += 1
		for character in pending[sent:sent + packed] {
			demand.asked[demand.asked_count] = character
			demand.asked_count += 1
		}
		sent += packed
	}
	if sent > 0 {
		system.wake_reader(&demand.requests.commands)
	}
}

// demand_wait adds the answers of the font service to a wait list.
demand_wait :: proc "contextless" (list: ^system.Wait, demand: ^Demand) {
	if demand.requests.head != nil {
		system.wait_records(list, &demand.requests.completions)
	}
}

// demand_answers_take reads the answers of the font service. changed is
// true when an answer came: the program draws again, and its next frame
// finds the glyphs of that answer. Each count of an answer is bounded by
// the characters of one request: the answer comes from another program.
demand_answers_take :: proc "contextless" (demand: ^Demand) -> (changed: bool) {
	if demand.requests.head == nil {
		return false
	}
	for _ in 0 ..< system.records_of_turn(&demand.requests.completions) {
		record := system.receive(&demand.requests.completions) or_break
		changed = true
		demand.drawn += min(record.values[demand_cache.ANSWER_DRAWN] + record.values[demand_cache.ANSWER_PUBLISHED_BEFORE], demand_cache.CHARACTERS_PER_REQUEST)
		demand.absent += min(record.values[demand_cache.ANSWER_ABSENT], demand_cache.CHARACTERS_PER_REQUEST)
		demand.refused += min(record.values[demand_cache.ANSWER_REFUSED], demand_cache.CHARACTERS_PER_REQUEST)
	}
	return changed
}
