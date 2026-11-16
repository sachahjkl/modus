// The font service (src/md/features/glyphs_on_demand.md): it draws the
// glyphs of the characters past the glyph cache into the demand cache,
// which each program that the root service gives a request ring, and each
// terminal, maps read-only. It is the only program that reads outlines at
// run time.
//
// **What it is for.** A principal reads and writes characters past the 192
// of the glyph caches of the boot image. The boot image carries their
// outlines only, in the subsets of the interface font and of the font of
// the cells that this module holds; this service draws each one once, for
// all the programs, beside each glyph cache: the faces of the demand cache
// (demand_cache.Face).
//
// **The whole subset at the start.** The service draws each character of
// the subset of each face at its start, before it reads any request, then
// sets the word subset_drawn of the header and wakes the programs that
// wait on it. So the demand cache holds the same entries whatever the
// programs draw, and a program learns nothing from it about the characters
// of another program. A request then finds each character of the subset
// published before; a request that comes before the end of that work waits
// in its ring, and its answer wakes the program.
//
// **Its grants**: the demand cache with Read and Write, and the control
// ring from the root service, which names the request ring of each
// program (demand_cache.Control_Kind). It has no surface. The root service
// starts it after the compositor, as a part of the system:
// `start("glyphs")` is refused.
//
// **What a reader sees.** The log has, at its start, one line for each
// face: `glyphs: the face cells of the demand cache holds each of the 165
// characters of its subset of paper_mono`, or, when a character is
// refused or the font cannot draw it, `glyphs: the face cells of the
// demand cache lacks characters of its subset of paper_mono: <n> drawn,
// <r> refused, <a> that the font cannot draw`. Then one line of the
// totals: `glyphs: the font service drew each face of its subset into the
// demand cache before it read a request: 542 characters, <w> words of
// 1048576`. For each program, the first request with a character outside
// the subset or that does not fit the cache writes one line, the first
// answer that does not fit its ring writes one line, and the first request
// that waits past its budget writes `glyphs: <program> passed its budget
// of 32 requests in 1000 ms: ...`; the counts go on, and the stop of a
// program that had one writes its totals.
//
// **The budget of each program.** The service reads at most
// demand_cache.REQUEST_BUDGET requests of one program in each window of
// demand_cache.REQUEST_BUDGET_WINDOW_MILLISECONDS. The next ones wait in
// the ring of that program until the window ends. So a program that
// writes its ring with no end costs the service a bounded time.
//
// **What it does not do**: it draws no character outside the subset of a
// face, and publishes no entry for it. A request names characters of the
// face Interface only: the cells ask for nothing. It never evicts a glyph.
package glyphs

import "modus:contract/blake3"
import "modus:contract/demand_cache"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:support/system"
import "modus:support/vector_font"

// The render memory and the outlines of its three font files; the demand
// cache and the rings are memory of other programs.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 192, programs = 1, threads = 1}

// The outlines of each face: the subsets of the interface font and of the
// font of the cells, the same files whose glyph caches the boot image
// carries. The demand cache names each one by its hash, and a program uses
// a face only beside the glyph cache of that hash.
interface_font_file := #load("../../../resources/fonts/b612.ttf")
cell_font_file := #load("../../../resources/fonts/paper_mono.ttf")
cell_bold_font_file := #load("../../../resources/fonts/paper_mono_semibold.ttf")

// font_file_of gives the font file of a face.
font_file_of :: proc "contextless" (face: demand_cache.Face) -> []u8 {
	switch face {
	case .Interface:
		return interface_font_file
	case .Cells, .Cells_Without_Grid_Fit:
		return cell_font_file
	case .Cells_Bold:
		return cell_bold_font_file
	}
	return nil
}

// The names of a face and of its font file, for the log.
face_name_of :: proc "contextless" (face: demand_cache.Face) -> (face_name, font_name: string) {
	switch face {
	case .Interface:
		return "interface", "b612"
	case .Cells:
		return "cells", "paper_mono"
	case .Cells_Without_Grid_Fit:
		return "cells without the grid fit", "paper_mono"
	case .Cells_Bold:
		return "bold cells", "paper_mono_semibold"
	}
	return "", ""
}

// The requests of one program that one turn of the loop reads, at most:
// the capacity of its ring. A program that writes as fast as this service
// reads gets this many records drawn in each turn, and each other program
// gets its own turn: it cannot hold the service from the others. Its cost
// in time is bounded by its budget (demand_cache.REQUEST_BUDGET in each
// window of demand_cache.REQUEST_BUDGET_WINDOW_MILLISECONDS).
REQUESTS_OF_A_PROGRAM_IN_ONE_TURN :: ring.CAPACITY

render_memory: vector_font.Render_Memory
demand_fonts: [demand_cache.Face]vector_font.Demand_Font
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
	budget:         demand_cache.Request_Budget, // Its requests in the current window.
	budget_passed:  u64, // The windows in which a request of it waited past its budget.
	budget_told:    bool, // The line of a passed budget is on the log: once for each program.
}
clients: [demand_cache.CLIENT_CAPACITY]Client

// Character_Added: what character_add did with a character.
Character_Added :: enum u8 {
	Published_Before, // The cache held it.
	Drawn, // It is drawn and published now.
	Absent, // It is outside the subset, or the font cannot draw it: no entry.
	Refused, // It does not fit the cache: no entry.
}

// character_add draws one character of the subset of a face into the
// demand cache, if the cache does not hold it. A character outside the
// subset is absent with no other work: the table then holds at most the
// subsets.
character_add :: proc "contextless" (face: demand_cache.Face, character: rune) -> Character_Added {
	if !demand_cache.in_subset(face, character) {
		return .Absent
	}
	place, search := demand_cache.place_find(&writer, face, character)
	switch search {
	case .Published:
		return .Published_Before
	case .Full:
		demand_cache.refusal_count(&writer)
		return .Refused
	case .Free:
	}
	entry, result := vector_font.demand_glyph_draw(&demand_fonts[face], &writer, character, &render_memory)
	switch result {
	case .Drawn:
		demand_cache.publish(&writer, place, face, character, entry)
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
					if client.absent_told || client.answer_told || client.budget_told {
						system.log_in("programs", .Info, "glyphs: ", system.name_of(client.name[:]), " stopped: it asked for ", client.absent, " characters outside the subset, ", client.refused, " refused; ", client.answers_lost, " answers did not fit its ring; it passed its budget in ", client.budget_passed, " windows")
					}
					system.ring_close(&client.requests)
					system.close(client.memory)
					client = {}
				}
			}
		}
	}
}

// budget_pass notes that a request of a program waits in its ring past
// its budget: once in each window, and one line for each program. The
// line and the count name the budget of this program alone, so they tell
// it nothing about the requests of another.
budget_pass :: proc "contextless" (client: ^Client) {
	if !demand_cache.request_budget_pass(&client.budget) {
		return
	}
	client.budget_passed += 1
	if !client.budget_told {
		client.budget_told = true
		system.log_in("programs", .Warning, "glyphs: ", system.name_of(client.name[:]), " passed its budget of ", u64(demand_cache.REQUEST_BUDGET), " requests in ", u64(demand_cache.REQUEST_BUDGET_WINDOW_MILLISECONDS), " ms: its next requests wait in its ring until the end of the window; the next times of this program are counted, not told")
	}
}

// client_serve answers the requests of one program, at most
// REQUESTS_OF_A_PROGRAM_IN_ONE_TURN of them, and no more than its budget
// leaves at the time now. A request past the budget stays in the ring: it
// is read in the next window, not dropped. A request is read once; its
// code points are checked by request_unpack.
client_serve :: proc "contextless" (client: ^Client, now: u64) {
	turn := min(system.records_of_turn(&client.requests.commands), REQUESTS_OF_A_PROGRAM_IN_ONE_TURN)
	// A window starts at the time of the read of the request of this
	// program, not at the time of the wake of this turn: another program
	// can cause that wake, and the end of the window, which the answer
	// names, would tell this program when.
	read_time := max(now, system.time())
	for _ in 0 ..< turn {
		// The ring holds a record for this turn: the budget is taken
		// before the read, so a record past it stays in the ring.
		taken, last := demand_cache.request_budget_take(&client.budget, read_time)
		if !taken {
			budget_pass(client)
			break
		}
		// A failed read spends one request of the budget of its own
		// program only: only a writer that breaks the counters of its ring
		// makes it fail.
		record := system.receive(&client.requests.commands) or_break
		characters: [demand_cache.CHARACTERS_PER_REQUEST]rune
		count := 0
		if record.kind == u32(demand_cache.Request_Kind.Glyphs) {
			count = demand_cache.request_unpack(record, &characters)
		}
		answer := ring.Record{kind = 0, tag = record.tag}
		// A request names characters of the face Interface: the cells ask
		// for nothing.
		for character in characters[:count] {
			switch character_add(.Interface, character) {
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
		// The program learns its own window and its own count, and no
		// fact of another program.
		if last {
			answer.values[demand_cache.ANSWER_BUDGET_WINDOW_END] = client.budget.window_end
		}
		answer.values[demand_cache.ANSWER_BUDGET_PASSED] = client.budget_passed
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
	faces: [demand_cache.Face]demand_cache.Face_Header
	for face in demand_cache.Face {
		problem: vector_font.Font_Problem
		demand_fonts[face], problem = vector_font.demand_font_open(font_file_of(face), face, &render_memory)
		if problem != .None {
			face_name, font_name := face_name_of(face)
			system.log_in("programs", .Error, "glyphs: the font ", font_name, " of the face ", face_name, " is refused: ", vector_font.font_problem_names[problem])
			system.stop(1)
		}
		faces[face] = {font_hash = blake3.hash(font_file_of(face)), flags = demand_fonts[face].flags}
	}
	writer = demand_cache.writer_open(uintptr(address), vector_font.RENDERER_VERSION, faces)
	// The whole subset of each face, face after face, in the order of the
	// code points, before any request: the entries of the cache do not
	// depend on what a program draws.
	total: u64
	for face in demand_cache.Face {
		drawn, refused, absent: u64
		for range in demand_cache.subset_of(face) {
			for character in range.first ..= range.last {
				switch character_add(face, character) {
				case .Drawn, .Published_Before:
					drawn += 1
				case .Refused:
					refused += 1
				case .Absent:
					absent += 1
				}
			}
		}
		total += drawn
		face_name, font_name := face_name_of(face)
		if refused == 0 && absent == 0 {
			system.log_in("programs", .Info, "glyphs: the face ", face_name, " of the demand cache holds each of the ", u64(demand_cache.subset_count(face)), " characters of its subset of ", font_name)
		} else {
			system.log_in("programs", .Warning, "glyphs: the face ", face_name, " of the demand cache lacks characters of its subset of ", font_name, ": ", drawn, " drawn, ", refused, " refused, ", absent, " that the font cannot draw")
		}
	}
	// Each program that waits for the cells wakes: each subset is in the
	// cache.
	demand_cache.subset_drawn_set(&writer)
	system.word_wake(&writer.header.subset_drawn, system.WAKE_ALL)
	system.log_in("programs", .Info, "glyphs: the font service drew each face of its subset into the demand cache before it read a request: ", total, " characters, ", u64(writer.words_used), " words of ", u64(demand_cache.WORD_CAPACITY))
	// The time of a turn: the time at which its wait ended, the counter of
	// the time page. It decides only which rings are held and the deadline
	// of the wait: a late value delays the service and tells no program
	// anything. A window starts at the time of a read (client_serve).
	now := system.time()
	for {
		wait := system.wait_begin()
		control_serve(&control)
		for &client in clients {
			if client.memory != 0 {
				client_serve(&client, now)
			}
		}
		system.wait_records(&wait, &control.commands)
		// A ring whose budget is spent is not waited on once its pass is
		// noted: its records would end each wait at once. The end of its
		// window ends the wait.
		deadline: u64 = system.WAIT_FOREVER
		for &client in clients {
			if client.memory == 0 {
				continue
			}
			if demand_cache.request_budget_held(&client.budget, now) {
				deadline = min(deadline, client.budget.window_end)
				if client.budget.passed {
					continue
				}
			}
			system.wait_records(&wait, &client.requests.commands)
		}
		now = max(now, system.wait_end(&wait, deadline))
	}
}
