#+build !freestanding
package wide_grants

import "core:testing"
import "modus:contract/errors"
import pr "modus:contract/plans_recipes"

@(private = "file")
LINK_PRINCIPAL :: u64(9)

@(private = "file")
LINK_RECORD_SIZE :: 8

@(private = "file")
CONSUMER_RECORDS_MOST :: 64

// The ring of a consumer of a pair, in memory: it takes records while it
// has room, keeps what it took in order, and checks at each write that the
// private store holds the record before it leaves (keep before forward).
@(private = "file")
Consumer_Ring :: struct {
	store:       ^Space_Store,
	space:       u32,
	pair:        u32,
	capacity:    int,
	held:        int, // Records in the ring that the consumer did not read yet.
	gone:        bool, // The ring ended: each write finds no ring.
	missing:     bool, // No ring of the pair came yet.
	taken:       [CONSUMER_RECORDS_MOST][LINK_RECORD_SIZE]u8,
	taken_count: int,
	finished:    int,
	end_error:   errors.Error_Record,
	unkept_sent: int, // Records written while the store did not hold them.
	wrong_pair:  int,
}

@(private = "file")
consumer_write :: proc "contextless" (user: rawptr, pair: u32, bytes: []u8) -> Forward_Write {
	consumer := (^Consumer_Ring)(user)
	if pair != consumer.pair {
		consumer.wrong_pair += 1
		return .No_Ring
	}
	if consumer.gone || consumer.missing {
		return .No_Ring
	}
	if consumer.held >= consumer.capacity {
		return .Full
	}
	space := space_of(consumer.store, consumer.space)
	// A record leaves only when its space kept it: the serial that the
	// consumer takes now is below the next serial of the space.
	if space == nil || u64(consumer.taken_count) >= space.next_serial {
		consumer.unkept_sent += 1
	}
	if consumer.taken_count >= CONSUMER_RECORDS_MOST {
		return .Full
	}
	copy(consumer.taken[consumer.taken_count][:], bytes)
	consumer.taken_count += 1
	consumer.held += 1
	return .Taken
}

@(private = "file")
consumer_finish :: proc "contextless" (user: rawptr, pair: u32, record_size: u32, error: errors.Error_Record) {
	consumer := (^Consumer_Ring)(user)
	consumer.finished += 1
	consumer.end_error = error
}

@(private = "file")
consumer_port :: proc(consumer: ^Consumer_Ring) -> Forward_Port {
	return {user = consumer, write = consumer_write, finish = consumer_finish}
}

@(private = "file")
link_record_of :: proc(serial: u64) -> (record: [LINK_RECORD_SIZE]u8) {
	for &value, index in record {
		value = u8(serial * 3 + u64(index) + 7)
	}
	return record
}

@(private = "file")
link_terms :: proc(kind: Collector_Space_Kind, bound: i64, forwarding: Space_Forwarding, record_size: i64 = LINK_RECORD_SIZE) -> Space_Terms {
	return {kind_word = i64(kind), bound_records = bound, forwarding_word = i64(forwarding), record_size = record_size}
}

@(private = "file")
Link_Fixture :: struct {
	memory: pr.Memory_Private_Store,
	store:  Space_Store,
	links:  Source_Links,
}

@(private = "file")
link_fixture_start :: proc(fixture: ^Link_Fixture) {
	space_store_init(&fixture.store, LINK_PRINCIPAL, pr.memory_private_store_port(&fixture.memory))
	fixture.links = {}
}

@(private = "file")
bytes_of :: proc(value: string) -> []u8 {
	return transmute([]u8)value
}

// Each refusal of a new source, first, with no link added: the tag 0 and
// a tag that a link holds; terms of another size than the record; a name
// that the space refuses; a second source of a space that a link feeds;
// and a source past the spaces of the collector.
@(test)
a_source_that_breaks_a_rule_opens_no_link :: proc(t: ^testing.T) {
	fixture := new(Link_Fixture)
	defer free(fixture)
	link_fixture_start(fixture)
	terms := link_terms(.Audit, 4, .Forward)
	_, refusal := link_open(&fixture.links, &fixture.store, 0, bytes_of("shop"), bytes_of("orders"), terms, LINK_RECORD_SIZE)
	testing.expect_value(t, refusal, Space_Refusal.Space_Held)
	_, refusal = link_open(&fixture.links, &fixture.store, 1, bytes_of("shop"), bytes_of("orders"), terms, LINK_RECORD_SIZE + 1)
	testing.expect_value(t, refusal, Space_Refusal.Wrong_Size)
	_, refusal = link_open(&fixture.links, &fixture.store, 1, bytes_of("shop"), bytes_of("orders"), terms, 0)
	testing.expect_value(t, refusal, Space_Refusal.Wrong_Size)
	_, refusal = link_open(&fixture.links, &fixture.store, 1, bytes_of(""), bytes_of("orders"), terms, LINK_RECORD_SIZE)
	testing.expect_value(t, refusal, Space_Refusal.Bad_Name)
	for &link in fixture.links.links {
		testing.expect(t, !link.active)
	}
	first, opened := link_open(&fixture.links, &fixture.store, 1, bytes_of("shop"), bytes_of("orders"), terms, LINK_RECORD_SIZE)
	testing.expect_value(t, opened, Space_Refusal.None)
	testing.expect(t, first != nil && first.pair == .Waiting && first.state == .Open)
	_, refusal = link_open(&fixture.links, &fixture.store, 1, bytes_of("shop"), bytes_of("orders"), terms, LINK_RECORD_SIZE)
	testing.expect_value(t, refusal, Space_Refusal.Space_Held)
	_, refusal = link_open(&fixture.links, &fixture.store, 2, bytes_of("shop"), bytes_of("orders"), terms, LINK_RECORD_SIZE)
	testing.expect_value(t, refusal, Space_Refusal.Space_Held)
	names := [?]string{"a", "b", "c", "d", "e", "f", "g"}
	for name, index in names {
		_, each := link_open(&fixture.links, &fixture.store, u32(10 + index), bytes_of(name), bytes_of("log"), link_terms(.Keep, 4, .Keeps), LINK_RECORD_SIZE)
		testing.expect_value(t, each, Space_Refusal.None)
	}
	_, refusal = link_open(&fixture.links, &fixture.store, 30, bytes_of("h"), bytes_of("log"), link_terms(.Keep, 4, .Keeps), LINK_RECORD_SIZE)
	testing.expect_value(t, refusal, Space_Refusal.Space_Limit_Reached)
}

// A record of another size is refused and kept nowhere; a full audit space
// holds the record pending, keeps nothing more, and a second record is not
// taken while one is pending; a store that refuses the write holds it too,
// and the retry after the store works again keeps it with the time of its
// first read.
@(test)
a_record_that_the_space_cannot_keep_stays_pending :: proc(t: ^testing.T) {
	fixture := new(Link_Fixture)
	defer free(fixture)
	link_fixture_start(fixture)
	link, _ := link_open(&fixture.links, &fixture.store, 4, bytes_of("server"), bytes_of("log"), link_terms(.Audit, 2, .Keeps), LINK_RECORD_SIZE)
	short: [LINK_RECORD_SIZE - 1]u8
	testing.expect_value(t, link_keep(&fixture.store, link, short[:], 1), Link_Step.Refused)
	testing.expect(t, !link.pending)
	testing.expect_value(t, space_of(&fixture.store, link.space).count, u32(0))

	// The store refuses the write: Held, and nothing in the space.
	fixture.memory.writes_allowed = fixture.memory.writes
	first := link_record_of(0)
	testing.expect_value(t, link_keep(&fixture.store, link, first[:], 100), Link_Step.Held)
	testing.expect(t, link.pending)
	testing.expect_value(t, space_of(&fixture.store, link.space).count, u32(0))
	second := link_record_of(1)
	testing.expect_value(t, link_keep(&fixture.store, link, second[:], 101), Link_Step.Held)
	testing.expect_value(t, link.pending_bytes[0], first[0])
	fixture.memory.writes_allowed = -1
	testing.expect_value(t, link_retry(&fixture.store, link), Link_Step.Kept)
	testing.expect_value(t, fixture.store.spaces[link.space - 1].times[0], u64(100))

	testing.expect_value(t, link_keep(&fixture.store, link, second[:], 102), Link_Step.Kept)
	third := link_record_of(2)
	testing.expect_value(t, link_keep(&fixture.store, link, third[:], 103), Link_Step.Held)
	space := space_of(&fixture.store, link.space)
	testing.expect_value(t, space.count, u32(2))
	testing.expect_value(t, space.refused_full, u64(1))
	testing.expect_value(t, link_retry(&fixture.store, link), Link_Step.Held)
	testing.expect_value(t, space.count, u32(2))
}

// pump gives each record of a source to its space, and forwards; a record
// that the space holds pending waits for one pass of the forward and one
// read of the consumer.
@(private = "file")
pump :: proc(t: ^testing.T, fixture: ^Link_Fixture, link: ^Source_Link, consumer: ^Consumer_Ring, first, count: u64) {
	port := consumer_port(consumer)
	for serial in first ..< first + count {
		record := link_record_of(serial)
		step := link_keep(&fixture.store, link, record[:], 1000 + serial)
		for step == .Held {
			forward_pass(&fixture.store, &fixture.links, port)
			// The consumer reads one record: room for one more.
			if consumer.held > 0 {
				consumer.held -= 1
			}
			step = link_retry(&fixture.store, link)
		}
		testing.expect_value(t, step, Link_Step.Kept)
	}
	forward_pass(&fixture.store, &fixture.links, port)
}

// From a source through an audit space that forwards to the ring of its
// pair, with a consumer ring of 2 records that reads one record at each
// pass: each record reaches the consumer once, in order, with its bytes,
// after its audit segment is in the store; the queue holds the source when
// the consumer is slow. Then the source ends: its pair ends with the error
// record of the end once the queue gave each record, and the link is free.
// A start of the collector over the same store finds each record and an
// empty queue: a forward is at most once across a stop.
@(test)
a_source_reaches_its_pair_through_the_store_with_backpressure :: proc(t: ^testing.T) {
	fixture := new(Link_Fixture)
	defer free(fixture)
	link_fixture_start(fixture)
	link, _ := link_open(&fixture.links, &fixture.store, 7, bytes_of("shop"), bytes_of("orders"), link_terms(.Audit, 64, .Forward), LINK_RECORD_SIZE)
	space_number := link.space
	consumer := Consumer_Ring{store = &fixture.store, space = space_number, pair = 7, capacity = 2}
	// No ring of the pair yet: the first record waits in the queue.
	consumer.missing = true
	first := link_record_of(0)
	testing.expect_value(t, link_keep(&fixture.store, link, first[:], 1000), Link_Step.Kept)
	testing.expect_value(t, forward_pass(&fixture.store, &fixture.links, consumer_port(&consumer)), Forward_Step.Waiting)
	testing.expect_value(t, fixture.store.forward_count, u32(1))
	testing.expect_value(t, link.pair, Pair_State.Waiting)
	consumer.missing = false

	pump(t, fixture, link, &consumer, 1, 39)
	for consumer.held > 0 || fixture.store.forward_count > 0 {
		consumer.held = 0
		forward_pass(&fixture.store, &fixture.links, consumer_port(&consumer))
	}
	testing.expect_value(t, consumer.taken_count, 40)
	for serial in 0 ..< consumer.taken_count {
		testing.expect_value(t, consumer.taken[serial], link_record_of(u64(serial)))
	}
	testing.expect_value(t, consumer.unkept_sent, 0)
	testing.expect_value(t, consumer.wrong_pair, 0)
	testing.expect_value(t, link.pair, Pair_State.Live)
	space := space_of(&fixture.store, space_number)
	testing.expect_value(t, space.count, u32(40))
	testing.expect_value(t, space.forwarded, u64(40))
	testing.expect(t, space.refused_full > 0)

	end := errors.error_make(.State, .Wirings, 0, 1, 0, 7)
	link_end(link, end)
	links_settle(&fixture.store, &fixture.links, consumer_port(&consumer))
	testing.expect_value(t, consumer.finished, 1)
	testing.expect_value(t, consumer.end_error, end)
	testing.expect(t, link_of(&fixture.links, 7) == nil)

	// A start over the same store.
	link_fixture_start(fixture)
	testing.expect_value(t, space_store_ready(&fixture.store), Space_Refusal.None)
	reloaded := space_of(&fixture.store, space_number)
	testing.expect(t, reloaded != nil)
	testing.expect_value(t, reloaded.count, u32(40))
	testing.expect_value(t, reloaded.next_serial, u64(40))
	testing.expect_value(t, fixture.store.forward_count, u32(0))
	verified, _ := space_verify(&fixture.store, space_number)
	testing.expect_value(t, verified, Space_Refusal.None)
	// The source comes again with a new wiring: the same space, the next
	// serial, and its new pair takes only the new record.
	again, opened := link_open(&fixture.links, &fixture.store, 9, bytes_of("shop"), bytes_of("orders"), link_terms(.Audit, 64, .Forward), LINK_RECORD_SIZE)
	testing.expect_value(t, opened, Space_Refusal.None)
	testing.expect_value(t, again.space, space_number)
	// The serials before 40 went to the pair before the stop.
	consumer_after := Consumer_Ring{store = &fixture.store, space = space_number, pair = 9, capacity = 4, taken_count = 40}
	pump(t, fixture, again, &consumer_after, 40, 1)
	testing.expect_value(t, consumer_after.taken_count, 41)
	testing.expect_value(t, consumer_after.taken[40], link_record_of(40))
	testing.expect_value(t, consumer_after.unkept_sent, 0)
}

// A consumer whose ring ends while records wait: the pair is Gone, each
// record of the queue for it is dropped and counted as unforwarded, and
// the space keeps each one; the next records of the source are kept and
// never forwarded. A space that does not forward never fills the queue.
@(test)
a_pair_that_ends_drops_its_queue_and_the_space_keeps_each_record :: proc(t: ^testing.T) {
	fixture := new(Link_Fixture)
	defer free(fixture)
	link_fixture_start(fixture)
	link, _ := link_open(&fixture.links, &fixture.store, 3, bytes_of("shop"), bytes_of("orders"), link_terms(.Audit, 64, .Forward), LINK_RECORD_SIZE)
	consumer := Consumer_Ring{store = &fixture.store, space = link.space, pair = 3, capacity = 2}
	for serial in u64(0) ..< 6 {
		record := link_record_of(serial)
		testing.expect_value(t, link_keep(&fixture.store, link, record[:], serial), Link_Step.Kept)
	}
	testing.expect_value(t, forward_pass(&fixture.store, &fixture.links, consumer_port(&consumer)), Forward_Step.Full)
	testing.expect_value(t, consumer.taken_count, 2)
	consumer.gone = true
	testing.expect_value(t, forward_pass(&fixture.store, &fixture.links, consumer_port(&consumer)), Forward_Step.Empty)
	testing.expect_value(t, link.pair, Pair_State.Gone)
	space := space_of(&fixture.store, link.space)
	testing.expect_value(t, space.unforwarded, u64(4))
	testing.expect_value(t, space.forwarded, u64(2))
	testing.expect_value(t, space.count, u32(6))
	later := link_record_of(6)
	testing.expect_value(t, link_keep(&fixture.store, link, later[:], 6), Link_Step.Kept)
	testing.expect_value(t, forward_pass(&fixture.store, &fixture.links, consumer_port(&consumer)), Forward_Step.Empty)
	testing.expect_value(t, space.unforwarded, u64(5))
	testing.expect_value(t, space.count, u32(7))
	// The end of a source whose pair is Gone ends no ring.
	link_close(link, errors.error_make(.Bad_Value, .Records))
	links_settle(&fixture.store, &fixture.links, consumer_port(&consumer))
	testing.expect_value(t, consumer.finished, 0)
	testing.expect(t, link_of(&fixture.links, 3) == nil)

	keep, _ := link_open(&fixture.links, &fixture.store, 5, bytes_of("server"), bytes_of("log"), link_terms(.Keep, 2, .Keeps), LINK_RECORD_SIZE)
	for serial in u64(0) ..< 40 {
		record := link_record_of(serial)
		testing.expect_value(t, link_keep(&fixture.store, keep, record[:], serial), Link_Step.Kept)
	}
	testing.expect_value(t, fixture.store.forward_count, u32(0))
	testing.expect_value(t, space_of(&fixture.store, keep.space).removed, u64(38))
}
