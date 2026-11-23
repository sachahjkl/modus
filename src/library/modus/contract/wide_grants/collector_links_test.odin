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

// expect_step checks the step of a source and drops its refusal.
@(private = "file")
expect_step :: proc(t: ^testing.T, step: Link_Step, refusal: Space_Refusal, expected: Link_Step, expected_refusal := Space_Refusal.None, loc := #caller_location) {
	testing.expectf(t, step == expected && refusal == expected_refusal, "the step is %v with %v, not %v with %v", step, refusal, expected, expected_refusal, loc = loc)
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
	// A budget of 16 windows: 13 beside the three of the act spaces.
	port, _ := space_memory_heap(16)
	space_store_init(&fixture.store, LINK_PRINCIPAL, pr.memory_private_store_port(&fixture.memory), port)
	fixture.links, _ = source_links_heap()
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
	// The windows of the budget, less the three of the act spaces, hold
	// the space above and twelve more; the next one is refused.
	names := [?]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}
	#assert(len(names) + 1 + ACT_SPACES_RESERVED == 16)
	for name, index in names {
		_, each := link_open(&fixture.links, &fixture.store, u32(10 + index), bytes_of(name), bytes_of("log"), link_terms(.Keep, 4, .Keeps), LINK_RECORD_SIZE)
		testing.expect_value(t, each, Space_Refusal.None)
	}
	_, refusal = link_open(&fixture.links, &fixture.store, 30, bytes_of("m"), bytes_of("log"), link_terms(.Keep, 4, .Keeps), LINK_RECORD_SIZE)
	testing.expect_value(t, refusal, Space_Refusal.Memory_Refused)
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
	{step, refusal := link_keep(&fixture.store, link, short[:], 1); expect_step(t, step, refusal, .Refused, .Wrong_Size)}
	testing.expect(t, !link.pending)
	testing.expect_value(t, space_of(&fixture.store, link.space).count, u32(0))

	// The store refuses the write: Held, and nothing in the space.
	fixture.memory.writes_allowed = fixture.memory.writes
	first := link_record_of(0)
	{step, refusal := link_keep(&fixture.store, link, first[:], 100); expect_step(t, step, refusal, .Held, .Store_Failed)}
	testing.expect(t, link.pending)
	testing.expect_value(t, space_of(&fixture.store, link.space).count, u32(0))
	second := link_record_of(1)
	{step, refusal := link_keep(&fixture.store, link, second[:], 101); expect_step(t, step, refusal, .Held)}
	testing.expect_value(t, link.pending_bytes[0], first[0])
	fixture.memory.writes_allowed = -1
	{step, refusal := link_retry(&fixture.store, link); expect_step(t, step, refusal, .Kept)}
	testing.expect_value(t, fixture.store.spaces[link.space - 1].ring.times[0], u64(100))

	{step, refusal := link_keep(&fixture.store, link, second[:], 102); expect_step(t, step, refusal, .Kept)}
	third := link_record_of(2)
	{step, refusal := link_keep(&fixture.store, link, third[:], 103); expect_step(t, step, refusal, .Held, .Space_Full)}
	space := space_of(&fixture.store, link.space)
	testing.expect_value(t, space.count, u32(2))
	testing.expect_value(t, space.refused_full, u64(1))
	{step, refusal := link_retry(&fixture.store, link); expect_step(t, step, refusal, .Held, .Space_Full)}
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
		step, _ := link_keep(&fixture.store, link, record[:], 1000 + serial)
		for step == .Held {
			forward_pass(&fixture.store, &fixture.links, port)
			// The consumer reads one record: room for one more.
			if consumer.held > 0 {
				consumer.held -= 1
			}
			step, _ = link_retry(&fixture.store, link)
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
	{step, refusal := link_keep(&fixture.store, link, first[:], 1000); expect_step(t, step, refusal, .Kept)}
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
	// The part of the queue of one space: 4 records, 2 of which the
	// consumer takes.
	for serial in u64(0) ..< FORWARD_QUEUE_PER_SPACE_LIMIT {
		record := link_record_of(serial)
		{step, refusal := link_keep(&fixture.store, link, record[:], serial); expect_step(t, step, refusal, .Kept)}
	}
	testing.expect_value(t, forward_pass(&fixture.store, &fixture.links, consumer_port(&consumer)), Forward_Step.Moved)
	testing.expect_value(t, forward_pass(&fixture.store, &fixture.links, consumer_port(&consumer)), Forward_Step.Full)
	testing.expect_value(t, consumer.taken_count, 2)
	consumer.gone = true
	testing.expect_value(t, forward_pass(&fixture.store, &fixture.links, consumer_port(&consumer)), Forward_Step.Empty)
	testing.expect_value(t, link.pair, Pair_State.Gone)
	space := space_of(&fixture.store, link.space)
	testing.expect_value(t, space.unforwarded, u64(FORWARD_QUEUE_PER_SPACE_LIMIT - 2))
	testing.expect_value(t, space.forwarded, u64(2))
	testing.expect_value(t, space.count, u32(FORWARD_QUEUE_PER_SPACE_LIMIT))
	later := link_record_of(FORWARD_QUEUE_PER_SPACE_LIMIT)
	{step, refusal := link_keep(&fixture.store, link, later[:], FORWARD_QUEUE_PER_SPACE_LIMIT); expect_step(t, step, refusal, .Kept)}
	testing.expect_value(t, forward_pass(&fixture.store, &fixture.links, consumer_port(&consumer)), Forward_Step.Empty)
	testing.expect_value(t, space.unforwarded, u64(FORWARD_QUEUE_PER_SPACE_LIMIT - 1))
	testing.expect_value(t, space.count, u32(FORWARD_QUEUE_PER_SPACE_LIMIT + 1))
	// The end of a source whose pair is Gone ends no ring.
	link_close(link, errors.error_make(.Bad_Value, .Records))
	links_settle(&fixture.store, &fixture.links, consumer_port(&consumer))
	testing.expect_value(t, consumer.finished, 0)
	testing.expect(t, link_of(&fixture.links, 3) == nil)

	keep, _ := link_open(&fixture.links, &fixture.store, 5, bytes_of("server"), bytes_of("log"), link_terms(.Keep, 2, .Keeps), LINK_RECORD_SIZE)
	for serial in u64(0) ..< 40 {
		record := link_record_of(serial)
		{step, refusal := link_keep(&fixture.store, keep, record[:], serial); expect_step(t, step, refusal, .Kept)}
	}
	testing.expect_value(t, fixture.store.forward_count, u32(0))
	testing.expect_value(t, space_of(&fixture.store, keep.space).removed, u64(38))
}

// The rings of two pairs, each with its consumer.
@(private = "file")
Two_Pairs :: struct {
	first:  ^Consumer_Ring,
	second: ^Consumer_Ring,
}

@(private = "file")
two_pairs_write :: proc "contextless" (user: rawptr, pair: u32, bytes: []u8) -> Forward_Write {
	pairs := (^Two_Pairs)(user)
	consumer := pair == pairs.first.pair ? pairs.first : pairs.second
	return consumer_write(consumer, pair, bytes)
}

@(private = "file")
two_pairs_finish :: proc "contextless" (user: rawptr, pair: u32, record_size: u32, error: errors.Error_Record) {
	pairs := (^Two_Pairs)(user)
	consumer_finish(pair == pairs.first.pair ? pairs.first : pairs.second, pair, record_size, error)
}

// A source that asks to forward and whose pair never comes holds only its
// own space: the records of a second source with a live pair go on, in
// order. When the first source ends, its pair that never came is Gone:
// its record is dropped and counted, the space keeps it, the link is
// freed, and a new wiring of the same source opens its space again.
@(test)
a_pair_that_never_comes_holds_only_its_own_space :: proc(t: ^testing.T) {
	fixture := new(Link_Fixture)
	defer free(fixture)
	link_fixture_start(fixture)
	lonely, _ := link_open(&fixture.links, &fixture.store, 1, bytes_of("shop"), bytes_of("orders"), link_terms(.Audit, 8, .Forward), LINK_RECORD_SIZE)
	live, _ := link_open(&fixture.links, &fixture.store, 2, bytes_of("bank"), bytes_of("payments"), link_terms(.Audit, 8, .Forward), LINK_RECORD_SIZE)
	missing := Consumer_Ring{store = &fixture.store, space = lonely.space, pair = 1, capacity = 8, missing = true}
	reader := Consumer_Ring{store = &fixture.store, space = live.space, pair = 2, capacity = 8}
	pairs := Two_Pairs{&missing, &reader}
	port := Forward_Port{user = &pairs, write = two_pairs_write, finish = two_pairs_finish}
	first := link_record_of(0)
	{step, refusal := link_keep(&fixture.store, lonely, first[:], 1); expect_step(t, step, refusal, .Kept)}
	for serial in u64(0) ..< 3 {
		record := link_record_of(10 + serial)
		{step, refusal := link_keep(&fixture.store, live, record[:], 2 + serial); expect_step(t, step, refusal, .Kept)}
	}
	testing.expect_value(t, forward_pass(&fixture.store, &fixture.links, port), Forward_Step.Moved)
	testing.expect_value(t, reader.taken_count, 3)
	for serial in 0 ..< 3 {
		testing.expect_value(t, reader.taken[serial], link_record_of(u64(10 + serial)))
	}
	testing.expect_value(t, fixture.store.forward_count, u32(1))
	testing.expect_value(t, forward_pass(&fixture.store, &fixture.links, port), Forward_Step.Waiting)
	testing.expect_value(t, lonely.pair, Pair_State.Waiting)

	lonely_space := lonely.space
	link_end(lonely, {})
	testing.expect_value(t, forward_pass(&fixture.store, &fixture.links, port), Forward_Step.Empty)
	testing.expect_value(t, lonely.pair, Pair_State.Gone)
	testing.expect_value(t, space_of(&fixture.store, lonely_space).unforwarded, u64(1))
	testing.expect_value(t, space_of(&fixture.store, lonely_space).count, u32(1))
	links_settle(&fixture.store, &fixture.links, port)
	testing.expect(t, link_of(&fixture.links, 1) == nil)
	testing.expect_value(t, missing.finished, 0)
	again, refusal := link_open(&fixture.links, &fixture.store, 3, bytes_of("shop"), bytes_of("orders"), link_terms(.Audit, 8, .Forward), LINK_RECORD_SIZE)
	testing.expect_value(t, refusal, Space_Refusal.None)
	testing.expect_value(t, again.space, lonely_space)
}

// A consumer that never reads holds only its own pair: its ring takes one
// record and is full, the records of the other pair go on, and the
// records of the full pair stay in the queue in their order. A pass that
// moves nothing says Full; once the consumer reads, its records come in
// order.
@(test)
a_full_ring_of_a_pair_holds_only_its_own_space :: proc(t: ^testing.T) {
	fixture := new(Link_Fixture)
	defer free(fixture)
	link_fixture_start(fixture)
	slow, _ := link_open(&fixture.links, &fixture.store, 1, bytes_of("shop"), bytes_of("orders"), link_terms(.Audit, 8, .Forward), LINK_RECORD_SIZE)
	fast, _ := link_open(&fixture.links, &fixture.store, 2, bytes_of("bank"), bytes_of("payments"), link_terms(.Audit, 8, .Forward), LINK_RECORD_SIZE)
	stalled := Consumer_Ring{store = &fixture.store, space = slow.space, pair = 1, capacity = 1}
	reader := Consumer_Ring{store = &fixture.store, space = fast.space, pair = 2, capacity = 8}
	pairs := Two_Pairs{&stalled, &reader}
	port := Forward_Port{user = &pairs, write = two_pairs_write, finish = two_pairs_finish}
	for serial in u64(0) ..< 3 {
		slow_record := link_record_of(serial)
		{step, refusal := link_keep(&fixture.store, slow, slow_record[:], serial); expect_step(t, step, refusal, .Kept)}
		fast_record := link_record_of(20 + serial)
		{step, refusal := link_keep(&fixture.store, fast, fast_record[:], serial); expect_step(t, step, refusal, .Kept)}
	}
	testing.expect_value(t, forward_pass(&fixture.store, &fixture.links, port), Forward_Step.Moved)
	testing.expect_value(t, stalled.taken_count, 1)
	testing.expect_value(t, reader.taken_count, 3)
	testing.expect_value(t, fixture.store.forward_count, u32(2))
	testing.expect_value(t, forward_pass(&fixture.store, &fixture.links, port), Forward_Step.Full)
	stalled.held = 0
	stalled.capacity = 8
	testing.expect_value(t, forward_pass(&fixture.store, &fixture.links, port), Forward_Step.Empty)
	testing.expect_value(t, stalled.taken_count, 3)
	for serial in 0 ..< 3 {
		testing.expect_value(t, stalled.taken[serial], link_record_of(u64(serial)))
	}
	testing.expect_value(t, space_of(&fixture.store, slow.space).forwarded, u64(3))
}

// A space that does not forward ends the ring of a pair that its asker
// wired anyway, when its source ends.
@(test)
a_pair_of_a_space_that_does_not_forward_ends_with_its_source :: proc(t: ^testing.T) {
	fixture := new(Link_Fixture)
	defer free(fixture)
	link_fixture_start(fixture)
	link, _ := link_open(&fixture.links, &fixture.store, 4, bytes_of("server"), bytes_of("log"), link_terms(.Keep, 4, .Keeps), LINK_RECORD_SIZE)
	testing.expect_value(t, link.pair, Pair_State.None)
	consumer := Consumer_Ring{store = &fixture.store, space = link.space, pair = 4, capacity = 2}
	end := errors.error_make(.State, .Wirings, 0, 1, 0, 4)
	link_end(link, end)
	links_settle(&fixture.store, &fixture.links, consumer_port(&consumer))
	testing.expect_value(t, consumer.finished, 1)
	testing.expect_value(t, consumer.end_error, end)
	testing.expect(t, link_of(&fixture.links, 4) == nil)
}

// A source that forwards and whose pair never comes fills its own part of
// the forward queue only: past FORWARD_QUEUE_PER_SPACE_LIMIT its record
// stays pending (Forward_Full), its link stays open and its ring holds its
// writer. A second source with a live pair still forwards every record,
// in order, through the queue that the first one cannot fill.
@(test)
a_space_whose_pair_never_comes_fills_its_own_part_of_the_queue :: proc(t: ^testing.T) {
	fixture := new(Link_Fixture)
	defer free(fixture)
	link_fixture_start(fixture)
	lonely, _ := link_open(&fixture.links, &fixture.store, 1, bytes_of("shop"), bytes_of("orders"), link_terms(.Audit, 32, .Forward), LINK_RECORD_SIZE)
	live, _ := link_open(&fixture.links, &fixture.store, 2, bytes_of("bank"), bytes_of("payments"), link_terms(.Audit, 32, .Forward), LINK_RECORD_SIZE)
	missing := Consumer_Ring{store = &fixture.store, space = lonely.space, pair = 1, capacity = 64, missing = true}
	reader := Consumer_Ring{store = &fixture.store, space = live.space, pair = 2, capacity = 64}
	pairs := Two_Pairs{&missing, &reader}
	port := Forward_Port{user = &pairs, write = two_pairs_write, finish = two_pairs_finish}
	kept := 0
	for serial in u64(0) ..< 17 {
		record := link_record_of(serial)
		step, refusal := link_keep(&fixture.store, lonely, record[:], serial)
		forward_pass(&fixture.store, &fixture.links, port)
		if step == .Held {
			testing.expect_value(t, refusal, Space_Refusal.Forward_Full)
			break
		}
		kept += 1
	}
	testing.expect_value(t, kept, FORWARD_QUEUE_PER_SPACE_LIMIT)
	testing.expect(t, lonely.pending && lonely.state == .Open)
	testing.expect_value(t, forward_count_of(&fixture.store, lonely.space), u32(FORWARD_QUEUE_PER_SPACE_LIMIT))
	{step, _ := link_retry(&fixture.store, lonely); testing.expect_value(t, step, Link_Step.Held)}

	for serial in u64(0) ..< 20 {
		record := link_record_of(100 + serial)
		{step, refusal := link_keep(&fixture.store, live, record[:], serial); expect_step(t, step, refusal, .Kept)}
		forward_pass(&fixture.store, &fixture.links, port)
	}
	testing.expect_value(t, reader.taken_count, 20)
	for serial in 0 ..< 20 {
		testing.expect_value(t, reader.taken[serial], link_record_of(u64(100 + serial)))
	}
	testing.expect_value(t, reader.unkept_sent, 0)
	testing.expect_value(t, forward_count_of(&fixture.store, live.space), u32(0))
	testing.expect_value(t, fixture.store.forward_count, u32(FORWARD_QUEUE_PER_SPACE_LIMIT))
	testing.expect_value(t, missing.taken_count, 0)
}

// The end of a pair and its source: a source and its pair that came after
// an older list of the sources (empty here) look orphaned against that
// list, and the collector would close a new pair. Against the list read
// after the pairs, which holds the new source, the pair stays. A pair with
// no source in that list, and a pair of a link whose space does not
// forward, are orphaned; a pair of a link that forwards stays, even when
// its source ring ended.
@(test)
a_pair_that_comes_with_its_source_is_not_closed :: proc(t: ^testing.T) {
	fixture := new(Link_Fixture)
	defer free(fixture)
	link_fixture_start(fixture)
	stale: []u32
	fresh := [1]u32{9}
	testing.expect(t, pair_orphaned(&fixture.links, 9, stale))
	testing.expect(t, !pair_orphaned(&fixture.links, 9, fresh[:]))
	testing.expect(t, pair_orphaned(&fixture.links, 8, fresh[:]))
	testing.expect(t, pair_orphaned(&fixture.links, 0, fresh[:]))
	keeps, _ := link_open(&fixture.links, &fixture.store, 4, bytes_of("server"), bytes_of("log"), link_terms(.Keep, 4, .Keeps), LINK_RECORD_SIZE)
	testing.expect(t, pair_orphaned(&fixture.links, keeps.tag, fresh[:]))
	forwards, _ := link_open(&fixture.links, &fixture.store, 5, bytes_of("shop"), bytes_of("orders"), link_terms(.Audit, 4, .Forward), LINK_RECORD_SIZE)
	link_end(forwards, {})
	testing.expect(t, !pair_orphaned(&fixture.links, forwards.tag, stale))
}
