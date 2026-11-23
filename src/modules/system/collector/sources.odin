// The record input sources and the record output forward of the collector
// (src/md/features/module_outputs.md, "The collector"): each wiring of
// sources is a source whose records the collector keeps in the space of
// its terms, and a space that forwards gives each record, once kept, to the
// ring of forward that pairs with that source.
//
// The rules are pure (modus:contract/wide_grants, collector_links.odin):
// this file reads the rings, gives the records to those rules, and writes
// the rings of the pairs through the library. A record leaves a source
// ring only into a link, which keeps it pending until its space keeps it;
// a link with a pending record reads no more of its ring, so the ring
// fills and holds its writer. No record is lost in the collector.
package collector_service

import "modus:contract/errors"
import "modus:contract/isolated"
import op "modus:contract/operation"
import "modus:contract/module"
import "modus:contract/output"
import "modus:contract/wide_grants"
import "modus:system"

// The streams to keep, each with the terms of its space.
sources: system.Record_Input_With_Terms(system.Any_Record, wide_grants.Space_Terms, .Many_Types)

// The kept records, one ring for each source that asks to forward.
forward: system.Record_Output(system.Any_Record, .Paired)

// The reads of one source in one pass: a busy source does not keep the
// others, the forward and the exports waiting.
SOURCE_READS_PER_PASS :: 16

// The words of the wait of the loop that the rings of the sources and of
// the pairs leave to the other words: the event word, the rings of the
// exports and of the delegated commands, and the wiring ring.
COLLECTOR_WAIT_WORDS_KEPT :: 16

// The time after which a loop that holds a record that its store refused
// tries again, in milliseconds: a store that refuses comes back with no
// word that the loop can wait on.
PENDING_RETRY_MILLISECONDS :: 1000

source_links: wide_grants.Source_Links // Its port: link_tables_port, set at the start.
source_record: [module.RECORD_SIZE_LIMIT]u8

// forward_write is the write of the port of the pairs: one record into the
// rings of one pair, with no wait, so a full ring never stops the loop.
@(private = "file")
forward_write :: proc "contextless" (user: rawptr, pair: u32, bytes: []u8) -> wide_grants.Forward_Write {
	// A write to a pair with no ring yet would count the record as
	// discarded and move the serial of forward for nothing.
	if system.output_pair_rings(&forward, pair, u32(len(bytes))) == 0 {
		return .No_Ring
	}
	switch system.output_write_pair(&forward, pair, bytes, wait = false) {
	case .Ok:
		return .Taken
	case .Full:
		return .Full
	case .No_Reader, .No_Writer, .Ended, .Bad_Record, .No_Record:
		return .No_Ring
	}
	return .No_Ring
}

// forward_finish ends the rings of one pair with no wait: a ring with no
// room is closed, and its reader reads Side_Closed after its records.
@(private = "file")
forward_finish :: proc "contextless" (user: rawptr, pair: u32, record_size: u32, error: errors.Error_Record) {
	_ = system.output_end_pair(&forward, pair, record_size, error, system.time())
}

forward_port :: proc "contextless" () -> wide_grants.Forward_Port {
	return {write = forward_write, finish = forward_finish}
}

// source_open opens the link of a new source: its names, which the root
// service wrote after its terms, its terms and the size of its record. A
// source that the border or the space refuses is closed: its writer reads
// Side_Closed, and never waits for a reader that does not read. A source
// whose space another link still feeds waits in its ring, unread, until
// that link ends: held says so, and the loop tries again.
@(private = "file")
source_open :: proc "contextless" (tag: u32) -> (opened: ^wide_grants.Source_Link, held: bool) {
	names, source_length, output_length, names_ok := system.input_source_names(&sources, tag)
	terms: wide_grants.Space_Terms
	_, description, described := system.input_description(&sources, tag)
	refusal := wide_grants.Space_Refusal.Bad_Name
	if names_ok && described && system.input_terms(&sources, &terms, tag) {
		link: ^wide_grants.Source_Link
		link, refusal = wide_grants.link_open(&source_links, &space_service.store, tag, names.source[:source_length], names.output[:output_length], terms, description.size)
		if refusal == .None {
			system.log_fact(.Info, Source_Opened{space = u64(link.space), wiring_number = u64(tag), source = names.source, output = names.output})
			return link, false
		}
		if refusal == .Space_Held {
			return nil, true
		}
	}
	system.log_fact(.Warning, Source_Refused{wiring_number = u64(tag), refusal_code = u64(refusal)})
	system.input_close(&sources, tag)
	// A pair of this source that came already ends with the refusal; one
	// that comes later has no source, and pairs_orphaned_close closes it.
	if described {
		_ = system.output_end_pair(&forward, tag, description.size, errors.error_make(.Refused, .Records, 0, i64(refusal), 0, i64(tag)), system.time())
	}
	return nil, false
}

// source_end_error gives the error record that ends the pair of a source:
// the error record of its end record, or for an end word the record State
// of the unit Wirings, whose value is the end word.
@(private = "file")
source_end_error :: proc "contextless" (item: system.Input_Item) -> errors.Error_Record {
	if item.end_word != .None {
		return errors.error_make(.State, .Wirings, 0, i64(item.end_word), 0, i64(item.tag))
	}
	return item.error
}

// source_read reads one source into its space, up to SOURCE_READS_PER_PASS
// records, and stops at a record that its space holds pending.
@(private = "file")
source_read :: proc "contextless" (link: ^wide_grants.Source_Link) {
	for _ in 0 ..< SOURCE_READS_PER_PASS {
		if link.state != .Open {
			return
		}
		if link.pending {
			if step, _ := wide_grants.link_retry(&space_service.store, link); step != .Kept {
				return
			}
		}
		// A ring of act records is not read while its space has room for one
		// ring only: the ring fills, and its writer refuses its next act. Each
		// record in the ring is an act that ran, which that room keeps.
		if space := wide_grants.space_of(&space_service.store, link.space); space != nil && wide_grants_space_is_acts(space) && !wide_grants.act_link_may_read(&grant_act_router, &space_service.store, link) {
			return
		}
		item, status := system.input_read_from(&sources, link.tag, source_record[:], 0)
		switch status {
		case .Ok:
			switch item.kind {
			case .Record:
				// A ring of an act record output carries the records of the
				// grant that holds only: a record of no grant, of an ended
				// grant or of another producer closes the ring, and its space
				// keeps nothing (wide_grants.act_link_keep).
				if space := wide_grants.space_of(&space_service.store, link.space); space != nil && wide_grants_space_is_acts(space) {
					expected_producer, _ := wide_grants.act_producer_from_source_name(wide_grants_name_slice(&space.source))
					act_step, act_refusal, space_refusal := wide_grants.act_link_keep(&grant_act_router, &space_service.store, link, source_record[:item.record_size], expected_producer, system.time())
					switch act_step {
					case .Kept:
						continue
					case .Held:
						return
					case .Refused:
						system.log_fact(.Warning, Act_Source_Refused{wiring_number = u64(link.tag), act_refusal_code = u64(act_refusal), space_refusal_code = u64(space_refusal)})
						system.input_close(&sources, link.tag)
						act_ring_closed(system.time()) // main.odin
						return
					}
				}
				step, refusal := wide_grants.link_keep(&space_service.store, link, source_record[:item.record_size], system.time())
				switch step {
				case .Kept:
				case .Held:
					return
				case .Refused:
					system.log_fact(.Warning, Source_Refused{wiring_number = u64(link.tag), refusal_code = u64(refusal)})
					system.input_close(&sources, link.tag)
					wide_grants.link_close(link, errors.error_make(.Bad_Value, .Records, 0, i64(refusal), i64(link.record_size), i64(link.tag)))
					return
				}
			case .Joined, .Gap, .End:
			}
		case .Ended:
			wide_grants.link_end(link, source_end_error(item))
			act_link_ended(link)
			return
		case .Bad_Record:
			wide_grants.link_end(link, item.refusal)
			act_link_ended(link)
			return
		case .No_Writer:
			// The library closed the ring with no end record.
			wide_grants.link_end(link, errors.error_make(.State, .Wirings, 0, 0, 0, i64(link.tag)))
			act_link_ended(link)
			return
		case .No_Record, .Full, .No_Reader:
			return
		}
	}
}

// sources_pass reads each source into its space, gives the queue to the
// rings of the pairs, and frees each source that ended. It says if a step
// waits for something that no word of the wait says (a record pending on
// a store that refused, a source whose space another link feeds, a source
// that ended and whose pair is not settled): the loop then tries again
// after PENDING_RETRY_MILLISECONDS.
sources_pass :: proc "contextless" () -> (pending: bool) {
	link_tables_follow_the_ends() // link_tables.odin
	act_sources_of_ended_grant_close()
	count := system.input_tags(&sources, source_tags[:])
	for tag in source_tags[:count] {
		link := wide_grants.link_of(&source_links, tag)
		if link == nil {
			held: bool
			link, held = source_open(tag)
			pending ||= held
		}
		if link != nil {
			source_read(link)
		}
	}
	// A source that ended keeps its pending record until its space keeps
	// it: its pair ends after it.
	for &link in source_links.links {
		if link.active && link.state == .Ended && link.pending {
			_, _ = wide_grants.link_retry(&space_service.store, &link)
		}
	}
	port := forward_port()
	wide_grants.forward_pass(&space_service.store, &source_links, port)
	wide_grants.links_settle(&space_service.store, &source_links, port)
	pairs_orphaned_close()
	for &link in source_links.links {
		pending ||= link.active && (link.pending || link.state == .Ended)
	}
	return pending
}

// act_sources_of_ended_grant_close closes the rings of the act records of
// a grant that ended, before any read: a record that a full space held, or
// one that came after the end, is kept nowhere
// (wide_grants.act_links_close_ended).
act_sources_of_ended_grant_close :: proc "contextless" () {
	closed_count := wide_grants.act_links_close_ended(&grant_act_router, &source_links, closed_tags)
	for tag in closed_tags[:closed_count] {
		system.input_close(&sources, tag)
	}
}

// act_sources_of_replaced_grant_close closes each ring of the act records
// of a grant that a newer one replaces (wide_grants.act_links_close_replaced).
act_sources_of_replaced_grant_close :: proc "contextless" () {
	closed_count := wide_grants.act_links_close_replaced(&grant_act_router, &source_links, closed_tags)
	for tag in closed_tags[:closed_count] {
		system.input_close(&sources, tag)
	}
}

// act_link_ended ends the grant that holds when a ring of its act records
// ended (main.odin, act_ring_closed).
@(private = "file")
act_link_ended :: proc "contextless" (link: ^wide_grants.Source_Link) {
	if space := wide_grants.space_of(&space_service.store, link.space); space != nil && wide_grants_space_is_acts(space) {
		act_ring_closed(system.time())
	}
}

// The pairs that forward holds, as output_pairs lists them, and the rings
// of sources read after them: pair_tags and pair_source_tags, in
// link_tables.odin.

// pairs_orphaned_close closes each end of forward whose pair has no source
// that this collector keeps: no link and no ring of sources of that
// wiring (a source that it refused or closed, or that ended and settled),
// or a link whose space does not forward. Such an end would else hold a
// place of the ends of the process for ever, and its reader would wait
// for records that never come. A source that waits for its space
// (Space_Held) keeps its ring, so its pair stays.
//
// The pairs are listed first, then the rings of sources: the library takes
// the ends of the wiring ring in their order, and the root service gives
// the end of a source before the end of its pair, so a pair in the first
// list has its source ring in the second one, unless that ring ended. A
// list of sources from before the pairs could miss a source and its pair
// that came between the two, and close a pair that is new.
@(private = "file")
pairs_orphaned_close :: proc "contextless" () {
	count := system.output_pairs(&forward, pair_tags[:])
	source_count := system.input_tags(&sources, pair_source_tags[:])
	for pair in pair_tags[:count] {
		if wide_grants.pair_orphaned(&source_links, pair, pair_source_tags[:source_count]) {
			_ = system.output_pair_close(&forward, pair)
		}
	}
}

// The words of the wait of the loop: the words that the loop adds besides
// the rings, and the rings of each end of the sources and of the pairs that
// a process holds (system.STREAM_END_CAPACITY each), so each ring fits.
// The words before the rings: the event word, the export service and its
// connections with their flags, and the ring of the delegated commands with
// its flag.
COLLECTOR_WAIT_WORDS_BEFORE_RINGS :: 1 + 2 * (1 + isolated.SERVICE_CONNECTION_CAPACITY) + 2
COLLECTOR_WAIT_WORDS :: COLLECTOR_WAIT_WORDS_KEPT + COLLECTOR_WAIT_WORDS_BEFORE_RINGS + 2 * system.STREAM_END_CAPACITY * system.INPUT_RECORDS_WAIT_WORDS
#assert(COLLECTOR_WAIT_WORDS <= op.WORD_WAIT_MOST)
// The places of the wait of the loop: the rings of the sources and the
// pairs take more than a wait on the stack holds. The set is made at the
// start of entry.
collector_wait_words: [COLLECTOR_WAIT_WORDS]op.Word
collector_wait_parts: [COLLECTOR_WAIT_WORDS]system.Wait_Part
collector_wait_set: system.Wait_Set

// sources_wait adds the rings of the sources and the full rings of the
// pairs to the wait of the loop, in the room that its other words leave.
// It says if a ring found no room in the list: the loop then wakes after
// PENDING_RETRY_MILLISECONDS.
sources_wait :: proc "contextless" (waiting: ^system.Wait) -> (not_waited: bool) {
	system.wait_wiring(waiting)
	room := system.wait_room_left(waiting) - COLLECTOR_WAIT_WORDS_KEPT
	rings := max(room, 0) / system.INPUT_RECORDS_WAIT_WORDS
	source_rings := rings / 2
	pair_rings := rings - source_rings
	not_waited = system.wait_input_records(waiting, &sources, source_rings) > 0
	not_waited ||= system.wait_output_room(waiting, &forward, pair_rings) > 0
	return not_waited
}

// The wakes of the loop at its retry period to read rings that its wait
// could not hold: a measure of the poll that the wait room of the kernel
// removes (ROADMAP.md, "A reader waits on each of its rings").
poll_wakes: u64

// poll_wakes_count counts one wake of the poll, and writes the count, with
// the wakes of the reads of the library, at each power of two: a bounded
// line of what the poll costs.
poll_wakes_count :: proc "contextless" () {
	poll_wakes += 1
	if poll_wakes & (poll_wakes - 1) == 0 {
		system.log_fact(.Info, Poll_Wakes_Counted{wakes = poll_wakes, read_wakes = system.stream_read_poll_wakes()})
	}
}

@(private = "file")
wide_grants_name_slice :: proc "contextless" (field: ^[wide_grants.SPACE_NAME_BYTES]u8) -> []u8 {
	length := 0
	for length < len(field) && field[length] != 0 {
		length += 1
	}
	return field[:length]
}

@(private = "file")
wide_grants_space_is_acts :: proc "contextless" (space: ^wide_grants.Collector_Space) -> bool {
	return string(wide_grants_name_slice(&space.output)) == wide_grants.ACT_OUTPUT_NAME
}

#assert(system.INPUT_RECORDS_WAIT_WORDS == system.OUTPUT_ROOM_WAIT_WORDS)
#assert(output.SOURCE_NAME_BYTES == wide_grants.SPACE_NAME_BYTES)
