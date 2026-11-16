package display

import "modus:contract/demand_cache"
import "modus:contract/fixed_addresses"
import "modus:contract/glyph_cache"
import "modus:contract/ring"
import "modus:contract/settings"
import "modus:support/graphics"
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
// The requests of a whole life fit the budget of one window of the font
// service: a program that asks only for what it draws is never held.
#assert((DEMAND_ASKED_LIMIT + demand_cache.CHARACTERS_PER_REQUEST - 1) / demand_cache.CHARACTERS_PER_REQUEST <= demand_cache.REQUEST_BUDGET)

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
	demand.reader, ok = demand_cache.reader_of(uintptr(demand_cache.ADDRESS), .Interface, cache)
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

// ---- The faces of the cells: the text of cells of graphics draws a
// character past the glyph cache from the face of its glyph cache. A
// program that the starter gave the demand cache, a terminal too, gets
// them with its text settings (text_settings_load); it asks for nothing,
// as each character of a cell face is drawn at the start of the font
// service (src/md/features/glyphs_on_demand.md, "A terminal maps the
// cache and gets no ring").

// The reader of each glyph cache of cells of this program, and of its bold
// weight. A reader whose glyph cache is absent, refused or of another form
// is not open.
cell_demand_readers: [settings.Grid_Fit]demand_cache.Reader
cell_demand_open: [settings.Grid_Fit]bool
bold_cell_demand_reader: demand_cache.Reader
bold_cell_demand_open: bool
// The word subset_drawn was 1 at the last look: cell_demand_completed
// gives true once, when it changes.
cell_subset_drawn_seen: bool

// cell_demand_load opens the cell faces of the demand cache that the
// starter mapped, beside the glyph caches of cells that text_settings_load
// validated: the face Cells beside the cache with the grid fit, the face
// Cells_Without_Grid_Fit beside the other, the face Cells_Bold beside the
// bold cache.
@(private)
cell_demand_load :: proc "contextless" (ctx: ^system.Context, bold: ^glyph_cache.Cache, bold_valid: bool) {
	if .Demand_Cache not_in fixed_addresses.ranges_mapped(&ctx.values) {
		return
	}
	faces := [settings.Grid_Fit]demand_cache.Face {
		.On  = .Cells,
		.Off = .Cells_Without_Grid_Fit,
	}
	for face, grid_fit in faces {
		if glyph_cache_valid[grid_fit] {
			cell_demand_readers[grid_fit], cell_demand_open[grid_fit] = demand_cache.reader_of(uintptr(demand_cache.ADDRESS), face, &glyph_caches[grid_fit])
		}
	}
	if bold_valid {
		bold_cell_demand_reader, bold_cell_demand_open = demand_cache.reader_of(uintptr(demand_cache.ADDRESS), .Cells_Bold, bold)
	}
	if reader := cell_demand_any(); reader != nil {
		cell_subset_drawn_seen = demand_cache.subset_drawn(reader)
	}
}

// cell_demand_any gives an open reader of a cell face, or nil: each one
// reads the same header.
@(private)
cell_demand_any :: proc "contextless" () -> ^demand_cache.Reader {
	for &reader, grid_fit in cell_demand_readers {
		if cell_demand_open[grid_fit] {
			return &reader
		}
	}
	if bold_cell_demand_open {
		return &bold_cell_demand_reader
	}
	return nil
}

// cell_demand_given gives graphics the faces of the glyph cache of cells of
// a grid fit and of the bold cache: text_settings_apply calls it.
@(private)
cell_demand_given :: proc "contextless" (grid_fit: settings.Grid_Fit, cells_drawn: bool) {
	regular: ^demand_cache.Reader
	bold: ^demand_cache.Reader
	if cells_drawn && cell_demand_open[grid_fit] {
		regular = &cell_demand_readers[grid_fit]
	}
	if cells_drawn && bold_cell_demand_open {
		bold = &bold_cell_demand_reader
	}
	graphics.text_demand_use(regular, bold)
}

// text_demand_frame_begin starts the frame of each cell face: one
// generation for the cells of the frame. The drawing module calls it at
// each draw; a program that draws cells itself calls it at its frame. A
// face whose frame never starts finds no entry: its cells draw the
// replacement glyph.
text_demand_frame_begin :: proc "contextless" () {
	for &reader, grid_fit in cell_demand_readers {
		if cell_demand_open[grid_fit] {
			demand_cache.reader_frame_begin(&reader)
		}
	}
	if bold_cell_demand_open {
		demand_cache.reader_frame_begin(&bold_cell_demand_reader)
	}
}

// cell_demand_holds says if the face of the cells that the program draws
// now holds a character at the generation of its frame: a cell of it then
// draws its glyph, not the replacement glyph.
cell_demand_holds :: proc "contextless" (character: rune) -> bool {
	reader := graphics.text_state.cell_demand
	if reader == nil || !graphics.text_vector_drawn() {
		return false
	}
	_, state := demand_cache.find(reader, character)
	return state == .Drawn
}

// cell_demand_wait adds the word subset_drawn of the demand cache to a wait
// list while it is 0: the font service wakes the program when it has
// published each subset.
cell_demand_wait :: proc "contextless" (list: ^system.Wait) {
	reader := cell_demand_any()
	if reader == nil || cell_subset_drawn_seen {
		return
	}
	system.wait_word(list, &reader.header.subset_drawn, 0)
}

// cell_demand_completed gives true once, at the first look after the font
// service published each subset, when the program opened its faces
// before: its cells that drew the replacement glyph can draw their
// glyphs, and the program draws its whole window, as its cells did not
// change.
cell_demand_completed :: proc "contextless" () -> bool {
	reader := cell_demand_any()
	if reader == nil || cell_subset_drawn_seen || !demand_cache.subset_drawn(reader) {
		return false
	}
	cell_subset_drawn_seen = true
	return true
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
