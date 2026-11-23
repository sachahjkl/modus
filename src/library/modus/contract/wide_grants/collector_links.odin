// The live sources of a collector and the pairs of their forward
// (src/md/features/module_outputs.md, "The collector"): the rules that
// move each record from the ring of a source into its space, and from the
// forward queue into the ring of its pair.
//
// The collector keeps a record before it forwards it: a record leaves a
// source ring into the space first (record_append, which writes the audit
// segment into the private store), and only the forward queue gives it to
// the ring of its pair. A record that the space cannot keep yet stays with
// its link (pending), and the link reads no more of its ring until the
// space keeps it: the ring fills and holds its writer, and no record is
// lost. A ring of a pair that is full keeps the record in the queue. A
// ring of a pair that ended drops what the queue holds for it: the space
// keeps those records, and counts them as unforwarded.
//
// These rules call no kernel operation: the collector gives them the bytes
// that it read, and a Forward_Port that writes and ends the rings of the
// pairs. The host tests drive them with a port in memory.
package wide_grants

import "modus:contract/errors"

// The sources that a collector reads at once: the ends of one process.
SOURCE_LINKS_MOST :: 16

// Where a source is.
Source_Link_State :: enum u8 {
	Open  = 0, // Its ring is read into its space.
	Ended = 1, // Its ring ended, or the collector closed it: the queue still gives its records, then its pair ends.
}

// Where the pair of a source is.
Pair_State :: enum u8 {
	None    = 0, // The space does not forward: no ring pairs with it.
	Waiting = 1, // The space forwards, and no ring of its pair took a record yet.
	Live    = 2, // A ring of its pair took a record.
	Gone    = 3, // The ring of its pair ended: the records of the queue for it are dropped.
}

// One source of the collector: one wiring of its record input sources.
Source_Link :: struct {
	active:        bool,
	tag:           u32, // The number of the wiring of the source: the pair of its ring of forward.
	space:         u32,
	record_size:   u32,
	state:         Source_Link_State,
	pair:          Pair_State,
	pending:       bool, // A record read from the ring that the space did not keep yet.
	pending_size:  u32,
	pending_time:  u64,
	pending_bytes: [SPACE_RECORD_BYTES_MOST]u8,
	end_error:     errors.Error_Record, // The error record of the end of the source, for the end of its pair.
}

// The sources of a collector.
Source_Links :: struct {
	links: [SOURCE_LINKS_MOST]Source_Link,
}

// What a step of a source did with a record.
Link_Step :: enum u8 {
	Kept    = 0, // The space kept the record.
	Held    = 1, // The space cannot keep it now (full, or its store refused): it stays pending, and the ring of the source waits.
	Refused = 2, // The record breaks the terms of its space: the collector closes the ring of the source.
}

// What a write into the ring of a pair did.
Forward_Write :: enum u8 {
	Taken   = 0, // The ring took the record.
	Full    = 1, // The ring has no room now.
	No_Ring = 2, // The pair has no ring.
}

// What one pass of the forward did.
Forward_Step :: enum u8 {
	Empty   = 0, // The queue holds no record.
	Full    = 1, // No record moved, and a full ring of a pair holds a record.
	Waiting = 2, // No record moved, and each record left waits for the first ring of its pair.
	Moved   = 3, // Records moved, and others still wait for their pairs.
}

// The rings of the pairs, as the collector writes them. write writes the
// bytes of a record into the rings of the pair; finish ends them with an
// error record, zero for a clean end.
Forward_Port :: struct {
	user:   rawptr,
	write:  proc "contextless" (user: rawptr, pair: u32, bytes: []u8) -> Forward_Write,
	finish: proc "contextless" (user: rawptr, pair: u32, record_size: u32, error: errors.Error_Record),
}

// link_of gives the active link of tag, or nil.
link_of :: proc "contextless" (links: ^Source_Links, tag: u32) -> ^Source_Link {
	if tag == 0 {
		return nil
	}
	for &link in links.links {
		if link.active && link.tag == tag {
			return &link
		}
	}
	return nil
}

// link_of_space gives the active link that feeds space_number, or nil.
@(private = "file")
link_of_space :: proc "contextless" (links: ^Source_Links, space_number: u32) -> ^Source_Link {
	for &link in links.links {
		if link.active && link.space == space_number {
			return &link
		}
	}
	return nil
}

// link_open opens the space of a new source: the names that the root
// service wrote, the terms that its asker gave, and the size of its record
// from the description of its wiring. It refuses a tag of 0 or of a link
// (Space_Held), terms whose record size is not the size of the record
// (Wrong_Size), no place for one more link (Space_Limit_Reached), each
// refusal of space_open, and a space that another link feeds (Space_Held):
// its forward queue names the space, so one space has one pair at a time.
// A refusal adds no link. A space that forwards starts with its pair
// Waiting.
link_open :: proc "contextless" (links: ^Source_Links, store: ^Space_Store, tag: u32, source: []u8, output: []u8, terms: Space_Terms, record_size: u32) -> (link: ^Source_Link, refusal: Space_Refusal) {
	if tag == 0 || link_of(links, tag) != nil {
		return nil, .Space_Held
	}
	if record_size == 0 || terms.record_size != i64(record_size) {
		return nil, .Wrong_Size
	}
	free: ^Source_Link
	for &place in links.links {
		if !place.active {
			free = &place
			break
		}
	}
	if free == nil {
		return nil, .Space_Limit_Reached
	}
	space_number, opened := space_open(store, source, output, terms)
	if opened != .None {
		return nil, opened
	}
	if link_of_space(links, space_number) != nil {
		return nil, .Space_Held
	}
	free^ = {active = true, tag = tag, space = space_number, record_size = record_size, state = .Open}
	if space := space_of(store, space_number); space != nil && space.forwarding == .Forward {
		free.pair = .Waiting
	}
	return free, .None
}

// link_keep gives one record of the ring of a source to its space. A link
// with a pending record takes no other one: the caller retries the pending
// one first (link_retry), and reads no more of its ring meanwhile. A
// record of another size is Refused and kept nowhere; a full space, a full
// forward queue and a store that refuses or holds damage keep the record
// pending, as Held. refusal is the refusal of the space (Wrong_Size for a
// record of another size), None when it kept the record or when another
// record is pending.
link_keep :: proc "contextless" (store: ^Space_Store, link: ^Source_Link, record: []u8, time_ms: u64) -> (step: Link_Step, refusal: Space_Refusal) {
	if link.pending {
		return .Held, .None
	}
	if u32(len(record)) != link.record_size || len(record) > SPACE_RECORD_BYTES_MOST {
		return .Refused, .Wrong_Size
	}
	link.pending = true
	link.pending_size = u32(len(record))
	link.pending_time = time_ms
	copy(link.pending_bytes[:], record)
	return link_retry(store, link)
}

// link_retry gives the pending record of a link to its space again, with
// the time of its first read. Kept clears it; Held and Refused give the
// refusal of the space.
link_retry :: proc "contextless" (store: ^Space_Store, link: ^Source_Link) -> (step: Link_Step, refusal: Space_Refusal) {
	if !link.pending {
		return .Kept, .None
	}
	_, refusal = record_append(store, link.space, link.pending_bytes[:link.pending_size], link.pending_time)
	switch refusal {
	case .None:
		link.pending = false
		link.pending_size = 0
		return .Kept, .None
	case .Space_Full, .Forward_Full, .Store_Failed, .Store_Damaged:
		return .Held, refusal
	case .Bad_Kind, .Bad_Forwarding, .Bad_Bound, .Space_Limit_Reached, .Bad_Name, .Bad_Record_Size, .Unknown_Space, .Wrong_Size, .Not_Principal, .Own_Space, .Chain_Broken, .Forward_Empty, .Bad_Limit, .Space_Held, .Memory_Refused, .Space_Closed:
		return .Refused, refusal
	}
	return .Refused, refusal
}

// link_end marks the end of the ring of a source: its end record, or the
// end word of its wiring as an error record. A record that is still
// pending stays: the space keeps it at a retry, and the pair ends after
// the queue gave it.
link_end :: proc "contextless" (link: ^Source_Link, error: errors.Error_Record) {
	if link.state == .Ended {
		return
	}
	link.state = .Ended
	link.end_error = error
}

// link_close ends a source whose ring the collector closed: its pending
// record, which its space refused, is kept nowhere, and its pair ends with
// error after the queue gave the records that the space kept.
link_close :: proc "contextless" (link: ^Source_Link, error: errors.Error_Record) {
	link.pending = false
	link.pending_size = 0
	link_end(link, error)
}

// forward_pass gives the records of the queue to the rings of their pairs,
// oldest first, while each ring takes them. The order matters within one
// pair only: a space whose pair cannot take its record now (a full ring,
// or a first ring that has not come) is skipped for the rest of the pass,
// and the records of the other spaces go on. So one consumer that does
// not read, or one pair that never comes, holds only its own space.
//
// A record is dropped and counted (forward_drop) when no link feeds its
// space, when its pair is None or Gone, when its pair was Live and has no
// ring now (the pair becomes Gone), and when its source ended while its
// pair never came (the pair becomes Gone, so links_settle frees the link
// and its space is no longer held).
forward_pass :: proc "contextless" (store: ^Space_Store, links: ^Source_Links, port: Forward_Port) -> Forward_Step {
	held: [SPACE_CAPACITY + 1]bool
	moved, full, waiting := false, false, false
	offset := u32(0)
	for {
		item := forward_item_at(store, offset)
		if item == nil {
			break
		}
		if item.space <= SPACE_CAPACITY && held[item.space] {
			offset += 1
			continue
		}
		link := link_of_space(links, item.space)
		if link == nil {
			forward_remove_at(store, offset, .Dropped)
			moved = true
			continue
		}
		switch link.pair {
		case .None, .Gone:
			forward_remove_at(store, offset, .Dropped)
			moved = true
			continue
		case .Waiting, .Live:
		}
		switch port.write(port.user, link.tag, item.bytes[:item.size]) {
		case .Taken:
			link.pair = .Live
			forward_remove_at(store, offset, .Forwarded)
			moved = true
		case .Full:
			held[item.space] = true
			full = true
			offset += 1
		case .No_Ring:
			if link.pair == .Waiting && link.state == .Open {
				held[item.space] = true
				waiting = true
				offset += 1
				continue
			}
			link.pair = .Gone
			forward_remove_at(store, offset, .Dropped)
			moved = true
		}
	}
	switch {
	case store.forward_count == 0:
		return .Empty
	case moved:
		return .Moved
	case full:
		return .Full
	case waiting:
		return .Waiting
	}
	return .Moved
}

// pair_orphaned says if the end of the pair tag has no source that the
// collector keeps: a link whose space does not forward, or no link and no
// ring of sources of that wiring (a source that it refused or closed, or
// that ended and settled). source_tags must be read after the list of the
// pairs (pairs_orphaned_close in the collector): a source and its pair
// that came between two older lists are then in both.
pair_orphaned :: proc "contextless" (links: ^Source_Links, pair: u32, source_tags: []u32) -> bool {
	if link := link_of(links, pair); link != nil {
		return link.pair == .None
	}
	for tag in source_tags {
		if tag == pair {
			return false
		}
	}
	return true
}

// links_settle frees each link whose source ended, whose pending record
// is settled, and whose records the queue gave: it ends the ring of its
// pair first, with the error record of the end of its source.
links_settle :: proc "contextless" (store: ^Space_Store, links: ^Source_Links, port: Forward_Port) {
	for &link in links.links {
		if !link.active || link.state != .Ended || link.pending || forward_waits_for(store, link.space) {
			continue
		}
		// A space that does not forward can still have a ring of a pair,
		// which its asker wired: it ends too, so its reader never waits
		// for a record that never comes. A Gone pair has no ring.
		switch link.pair {
		case .Waiting, .Live, .None:
			port.finish(port.user, link.tag, link.record_size, link.end_error)
		case .Gone:
		}
		link = {}
	}
}
