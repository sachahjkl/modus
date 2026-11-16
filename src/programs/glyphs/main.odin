// The font service (src/md/features/glyphs_on_demand.md): it draws the
// glyphs of the characters past the glyph cache into the demand cache,
// which each program that the root service gives a request ring maps
// read-only. It is the only program that reads outlines at run time.
//
// **What it is for.** A principal reads and writes characters past the 192
// of the glyph caches of the boot image. The boot image carries their
// outlines only, in the subset of the interface font that this module
// holds; this service draws each one once, for all the programs.
//
// **The whole subset at the start.** The service draws each character of
// demand_cache.subset_ranges at its start, before it reads any request. So
// the demand cache holds the same entries whatever the programs draw, and
// a program learns nothing from it about the characters of another
// program. A request then finds each character of the subset published
// before; a request that comes before the end of that work waits in its
// ring, and its answer wakes the program.
//
// **Its grants**: the demand cache with Read and Write, and the control
// ring from the root service, which names the request ring of each
// program (demand_cache.Control_Kind). It has no surface. The root service
// starts it after the compositor, as a part of the system:
// `start("glyphs")` is refused.
//
// **What a reader sees.** The log has, at its start, `glyphs: the font
// service drew the <n> characters of its subset of b612 into the demand
// cache before it read a request: <n> drawn, 0 refused, 0 that the font
// cannot draw; <w> words of 262144`, where n is demand_cache.subset_count:
// 47 today. For each program, the first request with a character outside
// the subset or that does not fit the cache writes one line, and the first
// answer that does not fit its ring writes one line; the counts go on, and
// the stop of a program that had one writes its totals.
//
// **What it does not do**: it draws no character outside the subset, and
// publishes no entry for it. It never evicts a glyph.
package glyphs

import "modus:contract/blake3"
import "modus:contract/demand_cache"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:support/system"
import "modus:support/vector_font"

// The render memory and the outlines of one font; the demand cache and the
// rings are memory of other programs.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 192, programs = 1, threads = 1}

FONT_NAME :: "b612"
// The outlines: the subset of the interface font, the same file whose
// glyph cache the boot image carries. The demand cache names it by its
// hash, and a program uses it only beside the glyph cache of that hash.
font_file := #load("../../../resources/fonts/b612.ttf")

// The requests of one program that one turn of the loop reads, at most:
// the capacity of its ring. A program that writes as fast as this service
// reads gets this many records drawn in each turn, and each other program
// gets its own turn: it cannot hold the service from the others. Its cost
// in time has no other bound: a budget of requests for each program is
// planned work of ROADMAP.md.
REQUESTS_OF_A_PROGRAM_IN_ONE_TURN :: ring.CAPACITY

render_memory: vector_font.Render_Memory
demand_font: vector_font.Demand_Font
writer: demand_cache.Writer

// One program: its request ring, and the counts of what it asked for.
Client :: struct {
	memory:         system.Handle, // 0: a free place.
	requests:       ring.Ring,
	name:           system.Name,
	absent:         u64, // The characters outside the subset that it asked for.
	refused:        u64, // The characters that did not fit the cache.
	answers_lost:   u64, // The answers that did not fit its ring.
	absent_told:    bool, // The line of an absent or refused character is on the log: once for each program.
	answer_told:    bool, // The line of an answer that did not fit is on the log: once for each program.
}
clients: [demand_cache.CLIENT_CAPACITY]Client

// Character_Added: what character_add did with a character.
Character_Added :: enum u8 {
	Published_Before, // The cache held it.
	Drawn, // It is drawn and published now.
	Absent, // It is outside the subset, or the font cannot draw it: no entry.
	Refused, // It does not fit the cache: no entry.
}

// character_add draws one character of the subset into the demand cache,
// if the cache does not hold it. A character outside the subset is absent
// with no other work: the table then holds at most the subset.
character_add :: proc "contextless" (character: rune) -> Character_Added {
	if !demand_cache.in_subset(character) {
		return .Absent
	}
	place, search := demand_cache.place_find(&writer, character)
	switch search {
	case .Published:
		return .Published_Before
	case .Full:
		demand_cache.refusal_count(&writer)
		return .Refused
	case .Free:
	}
	entry, result := vector_font.demand_glyph_draw(&demand_font, &writer, character, &render_memory)
	switch result {
	case .Drawn:
		demand_cache.publish(&writer, place, character, entry)
		return .Drawn
	case .Absent:
		return .Absent
	case .Refused:
		demand_cache.refusal_count(&writer)
		return .Refused
	}
	return .Absent
}

// control_serve adds and removes the request rings that the root service
// names. A ring past the capacity is closed, with a line: that program
// draws the replacement glyph for each character past the glyph cache that
// the cache does not hold.
control_serve :: proc "contextless" (control: ^ring.Ring) {
	for _ in 0 ..< system.records_of_turn(&control.commands) {
		record := system.receive(&control.commands) or_break
		handle := system.Handle(record.values[0])
		#partial switch demand_cache.Control_Kind(record.kind) {
		case .Client_Add:
			name := system.name_unpack({record.values[1], record.values[2], record.values[3], record.values[4]})
			place: ^Client
			for &client in clients {
				if client.memory == 0 {
					place = &client
					break
				}
			}
			if place == nil {
				system.log_in("programs", .Warning, "glyphs: no room for the requests of ", system.name_of(name[:]), ": this service serves ", u64(demand_cache.CLIENT_CAPACITY), " programs")
				system.close(handle)
				continue
			}
			requests, status := system.ring_open(handle)
			if status != .Ok {
				system.log_in("programs", .Warning, "glyphs: the request ring of ", system.name_of(name[:]), " does not open: status ", status)
				system.close(handle)
				continue
			}
			place^ = {memory = handle, requests = requests, name = name}
		case .Client_Remove:
			for &client in clients {
				if client.memory != 0 && client.memory == handle {
					// The totals of a program whose lines were told once.
					if client.absent_told || client.answer_told {
						system.log_in("programs", .Info, "glyphs: ", system.name_of(client.name[:]), " stopped: it asked for ", client.absent, " characters outside the subset, ", client.refused, " refused; ", client.answers_lost, " answers did not fit its ring")
					}
					system.ring_close(&client.requests)
					system.close(client.memory)
					client = {}
				}
			}
		}
	}
}

// client_serve answers the requests of one program, at most
// REQUESTS_OF_A_PROGRAM_IN_ONE_TURN of them. A request is read once; its
// code points are checked by request_unpack.
client_serve :: proc "contextless" (client: ^Client) {
	turn := min(system.records_of_turn(&client.requests.commands), REQUESTS_OF_A_PROGRAM_IN_ONE_TURN)
	for _ in 0 ..< turn {
		record := system.receive(&client.requests.commands) or_break
		characters: [demand_cache.CHARACTERS_PER_REQUEST]rune
		count := 0
		if record.kind == u32(demand_cache.Request_Kind.Glyphs) {
			count = demand_cache.request_unpack(record, &characters)
		}
		answer := ring.Record{kind = 0, tag = record.tag}
		for character in characters[:count] {
			switch character_add(character) {
			case .Published_Before:
				answer.values[demand_cache.ANSWER_PUBLISHED_BEFORE] += 1
			case .Drawn:
				answer.values[demand_cache.ANSWER_DRAWN] += 1
			case .Absent:
				answer.values[demand_cache.ANSWER_ABSENT] += 1
			case .Refused:
				answer.values[demand_cache.ANSWER_REFUSED] += 1
			}
		}
		answer.values[demand_cache.ANSWER_GENERATION] = writer.generation
		client.absent += answer.values[demand_cache.ANSWER_ABSENT]
		client.refused += answer.values[demand_cache.ANSWER_REFUSED]
		name := system.name_of(client.name[:])
		// One line for each program, not for each request: a program that
		// asks for absent characters with no end must not fill the log of
		// the machine. The counts go on, and its stop writes them.
		if !client.absent_told && (answer.values[demand_cache.ANSWER_REFUSED] != 0 || answer.values[demand_cache.ANSWER_ABSENT] != 0) {
			client.absent_told = true
			level := answer.values[demand_cache.ANSWER_REFUSED] == 0 ? op.Log_Level.Info : op.Log_Level.Warning
			system.log_in("programs", level, "glyphs: ", name, " asked for ", u64(count), " characters: ", answer.values[demand_cache.ANSWER_DRAWN], " drawn, ", answer.values[demand_cache.ANSWER_PUBLISHED_BEFORE], " in the cache before, ", answer.values[demand_cache.ANSWER_ABSENT], " outside the subset, ", answer.values[demand_cache.ANSWER_REFUSED], " refused; the next ones of this program are counted, not told")
		}
		if !system.send(&client.requests.completions, answer) {
			client.answers_lost += 1
			if !client.answer_told {
				client.answer_told = true
				system.log_in("programs", .Warning, "glyphs: an answer to ", name, " does not fit its ring: it finds the glyphs at its next frame; the next ones of this program are counted, not told")
			}
		}
	}
}

// The entry of the font service: it maps the demand cache, writes its
// header, draws the whole subset, then serves the request rings for ever.
// With no demand cache, or a font that the renderer refuses, it stops with
// the code 1, and each program draws the replacement glyph past the glyph
// cache.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	address, status := system.memory_map(ctx.handles[demand_cache.SERVICE_GRANT_CACHE])
	if status != .Ok {
		system.log_in("programs", .Error, "glyphs: the demand cache does not map: status ", status)
		system.stop(1)
	}
	control: ring.Ring
	control, status = system.ring_open(ctx.handles[demand_cache.SERVICE_GRANT_CONTROL])
	if status != .Ok {
		system.log_in("programs", .Error, "glyphs: the control ring does not open: status ", status)
		system.stop(1)
	}
	problem: vector_font.Font_Problem
	demand_font, problem = vector_font.demand_font_open(font_file, true, &render_memory)
	if problem != .None {
		system.log_in("programs", .Error, "glyphs: the font ", FONT_NAME, " is refused: ", vector_font.font_problem_names[problem])
		system.stop(1)
	}
	writer = demand_cache.writer_open(uintptr(address), blake3.hash(font_file), vector_font.RENDERER_VERSION, demand_font.flags)
	// The whole subset, in the order of the code points, before any
	// request: the entries of the cache do not depend on what a program
	// draws.
	drawn, refused, absent: u64
	for range in demand_cache.subset_ranges {
		for character in range.first ..= range.last {
			switch character_add(character) {
			case .Drawn, .Published_Before:
				drawn += 1
			case .Refused:
				refused += 1
			case .Absent:
				absent += 1
			}
		}
	}
	level := refused == 0 && absent == 0 ? op.Log_Level.Info : op.Log_Level.Warning
	system.log_in("programs", level, "glyphs: the font service drew the ", u64(demand_cache.subset_count()), " characters of its subset of ", FONT_NAME, " into the demand cache before it read a request: ", drawn, " drawn, ", refused, " refused, ", absent, " that the font cannot draw; ", u64(writer.words_used), " words of ", u64(demand_cache.WORD_CAPACITY))
	for {
		wait := system.wait_begin()
		control_serve(&control)
		for &client in clients {
			if client.memory != 0 {
				client_serve(&client)
			}
		}
		system.wait_records(&wait, &control.commands)
		for &client in clients {
			if client.memory != 0 {
				system.wait_records(&wait, &client.requests.commands)
			}
		}
		system.wait_end(&wait)
	}
}
