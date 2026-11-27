#+build !freestanding
#+build !modus
package key_path

import "modus:contract/ring"
import "core:testing"

// The memory of the smallest ring: 32 records in each queue.
@(private = "file")
Ring_Memory :: struct #align (ring.PAGE_SIZE) {
	bytes: [ring.PAGE_COUNT * ring.PAGE_SIZE]u8,
}

@(private = "file")
window_ring :: proc(memory: ^Ring_Memory) -> ring.Ring {
	opened, _ := ring.open(memory, ring.PAGE_COUNT)
	return opened
}

@(private = "file")
key_record :: proc(number: int) -> ring.Record {
	return {kind = 1, values = {0 = u64(number)}}
}

@(private = "file")
pointer_record :: proc(x: int, buttons: u64) -> ring.Record {
	return {kind = 2, values = {0 = u64(x), 2 = buttons}}
}

// read_some takes at most count records from the ring, as the window does.
@(private = "file")
read_some :: proc(target: ^ring.Queue, count: int, read: ^[dynamic]ring.Record) {
	for _ in 0 ..< count {
		record, ok := ring.pop(target)
		if !ok {
			return
		}
		append(read, record)
	}
}

// 200 keys go to a window that reads nothing: 32 are in its ring, 168 wait.
// The window then reads a few records at a time, and a newer key arrives
// between two reads: each key arrives, in the order in which it was typed,
// and none is refused.
@(test)
keys_stay_in_order_across_a_full_ring :: proc(t: ^testing.T) {
	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	storage := make([]ring.Record, WINDOW_QUEUE_CAPACITY)
	defer delete(storage)
	queue := Window_Queue{records = storage}
	read: [dynamic]ring.Record
	defer delete(read)

	for number in 0 ..< 200 {
		result := window_queue_put(&queue, target, key_record(number), .Key)
		testing.expect(t, !result.loss_began)
		testing.expect_value(t, result.wrote, number < 32)
	}
	testing.expect_value(t, queue.delivered, 32)
	testing.expect_value(t, queue.count, 168)
	testing.expect_value(t, queue.waiting_keys, 168)
	testing.expect(t, window_queue_waits(&queue))
	testing.expect(t, queue_is_exactly_full(target))

	typed := 200
	for round := 0; len(read) < typed && round < 1000; round += 1 {
		read_some(target, 7, &read)
		if round == 3 {
			// A key typed while older keys wait goes after them.
			window_queue_put(&queue, target, key_record(typed), .Key)
			typed += 1
		}
		window_queue_send_waiting(&queue, target)
	}
	testing.expect_value(t, len(read), 201)
	for record, index in read {
		testing.expect_value(t, record.values[0], u64(index))
	}
	testing.expect_value(t, queue.refused[Record_Class.Key], 0)
	testing.expect_value(t, queue.keys_delivered, 201)
	testing.expect_value(t, queue.waiting_keys, 0)
	testing.expect(t, !window_queue_waits(&queue))
	testing.expect(t, !queue.loss.open)
}

// The moves of the pointer to a window with a full ring become one move,
// the newest. A change of a button waits in order, and takes the place of
// the move before it. No move takes a place of the queue of the keys.
@(test)
pointer_moves_merge_and_button_changes_wait :: proc(t: ^testing.T) {
	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	storage := make([]ring.Record, WINDOW_QUEUE_CAPACITY)
	defer delete(storage)
	queue := Window_Queue{records = storage}
	read: [dynamic]ring.Record
	defer delete(read)

	// A move goes to a ring that has room, with no wait.
	testing.expect(t, window_queue_put_pointer(&queue, target, pointer_record(1, 0), 0).wrote)
	read_some(target, 1, &read)
	clear(&read)
	for number in 0 ..< 32 {
		window_queue_put(&queue, target, key_record(number), .Key)
	}
	for x in 10 ..< 15 {
		result := window_queue_put_pointer(&queue, target, pointer_record(x, 0), 0)
		testing.expect(t, !result.wrote && !result.loss_began)
	}
	testing.expect(t, queue.move_waits)
	testing.expect_value(t, queue.count, 0)
	testing.expect_value(t, queue.moves_merged, 4)
	testing.expect_value(t, queue.move.values[0], 14)

	// A key, then a press at a new place, then a move with the button down.
	window_queue_put(&queue, target, key_record(32), .Key)
	window_queue_put_pointer(&queue, target, pointer_record(20, 1), 1)
	testing.expect(t, !queue.move_waits, "the press holds the newest place")
	testing.expect_value(t, queue.count, 2)
	testing.expect_value(t, queue.moves_merged, 5)
	window_queue_put_pointer(&queue, target, pointer_record(21, 1), 1)
	window_queue_put_pointer(&queue, target, pointer_record(22, 1), 1)
	testing.expect_value(t, queue.count, 2)
	testing.expect(t, queue.move_waits)
	// The release.
	window_queue_put_pointer(&queue, target, pointer_record(23, 0), 0)
	testing.expect_value(t, queue.count, 3)
	testing.expect(t, !queue.move_waits)

	for round := 0; window_queue_waits(&queue) && round < 100; round += 1 {
		read_some(target, 5, &read)
		window_queue_send_waiting(&queue, target)
	}
	read_some(target, 64, &read)
	// 33 keys, the press and the release: the release holds the newest
	// place, so no move waited after it.
	testing.expect_value(t, len(read), 35)
	testing.expect_value(t, queue.moves_merged, 7)
	if len(read) == 35 {
		for index in 0 ..< 33 {
			testing.expect_value(t, read[index].kind, 1)
			testing.expect_value(t, read[index].values[0], u64(index))
		}
		testing.expect_value(t, read[33].values[0], 20)
		testing.expect_value(t, read[33].values[2], 1)
		testing.expect_value(t, read[34].values[0], 23)
		testing.expect_value(t, read[34].values[2], 0)
	}
}

// Notches at a window that does not read: 300 records with notches join
// into one record, which holds their sum and the newest place, so they
// take one place of the queue. A change of a button and a key after them
// keep their places and their order, and a move waits after them. In the
// backlog of the input service, the notches of two packets with the same
// buttons add, cut to WHEEL_NOTCHES_LIMIT.
@(test)
wheel_notches_wait_in_order_and_add_in_the_backlog :: proc(t: ^testing.T) {
	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	storage := make([]ring.Record, WINDOW_QUEUE_CAPACITY)
	defer delete(storage)
	queue := Window_Queue{records = storage}
	read: [dynamic]ring.Record
	defer delete(read)

	NOTCH :: 1 // One notch toward the end of a content (display.WHEEL_TOWARD_THE_END).
	NOTCH_RECORDS :: 300 // More than the places of the queue.
	PRESS_X :: NOTCH_RECORDS + 100
	BUTTON_LEFT :: 1 // display.BUTTON_LEFT.
	RING_RECORDS :: 32 // The records of the smallest ring.
	for number in 0 ..< RING_RECORDS {
		window_queue_put(&queue, target, key_record(number), .Key)
	}
	for x in 0 ..< NOTCH_RECORDS {
		turned := pointer_record(x, 0)
		turned.values[POINTER_RECORD_WHEEL] = u64(i64(NOTCH))
		result := window_queue_put_pointer(&queue, target, turned, 0, NOTCH)
		testing.expect(t, !result.loss_began)
	}
	testing.expect_value(t, queue.count, 1)
	testing.expect_value(t, queue.wheel_records_merged, NOTCH_RECORDS - 1)
	window_queue_put_pointer(&queue, target, pointer_record(PRESS_X, BUTTON_LEFT), BUTTON_LEFT)
	window_queue_put(&queue, target, key_record(RING_RECORDS), .Key)
	window_queue_put_pointer(&queue, target, pointer_record(PRESS_X + 1, BUTTON_LEFT), BUTTON_LEFT)
	testing.expect_value(t, queue.count, 3)
	testing.expect(t, queue.move_waits, "the move after the key waits after it")
	testing.expect_value(t, queue.refused[Record_Class.Key], 0)
	testing.expect_value(t, queue.refused[Record_Class.Pointer], 0)
	for round := 0; window_queue_waits(&queue) && round < 100; round += 1 {
		read_some(target, 5, &read)
		window_queue_send_waiting(&queue, target)
	}
	read_some(target, 64, &read)
	testing.expect_value(t, len(read), RING_RECORDS + 4)
	if len(read) == RING_RECORDS + 4 {
		notches := read[RING_RECORDS]
		testing.expect_value(t, i64(notches.values[POINTER_RECORD_WHEEL]), NOTCH_RECORDS * NOTCH)
		testing.expect_value(t, notches.values[POINTER_RECORD_X], NOTCH_RECORDS - 1)
		press := read[RING_RECORDS + 1]
		testing.expect_value(t, press.values[POINTER_RECORD_X], PRESS_X)
		testing.expect_value(t, press.values[POINTER_RECORD_BUTTONS], BUTTON_LEFT)
		testing.expect_value(t, read[RING_RECORDS + 2].values[0], RING_RECORDS)
		testing.expect_value(t, read[RING_RECORDS + 3].values[POINTER_RECORD_X], PRESS_X + 1)
		testing.expect_value(t, read[RING_RECORDS + 3].values[POINTER_RECORD_WHEEL], 0)
	}
	testing.expect_value(t, wheel_notches_add(WHEEL_NOTCHES_LIMIT, NOTCH), WHEEL_NOTCHES_LIMIT)
	testing.expect_value(t, wheel_notches_add(-WHEEL_NOTCHES_LIMIT, -NOTCH), -WHEEL_NOTCHES_LIMIT)

	backlog: Pointer_Backlog
	testing.expect(t, pointer_backlog_add(&backlog, {motion_x = 1, wheel = NOTCH}))
	testing.expect(t, pointer_backlog_add(&backlog, {motion_x = 2, wheel = NOTCH}))
	testing.expect(t, pointer_backlog_add(&backlog, {wheel = -NOTCH}))
	testing.expect_value(t, backlog.count, 1)
	testing.expect_value(t, backlog.packets[0], Pointer_Packet{motion_x = 3, wheel = NOTCH})
}

// The packets of a mouse with a wheel: a whole packet gives its move, its
// buttons and its notches; a lost first byte whose next byte looks like a
// first byte gives a fourth byte that is not a count of notches, and the
// decoder starts again one byte later, with no false notches; a packet
// with an overflow bit is dropped; a mouse left in the Explorer protocol
// gives its notches in the low 4 bits.
@(test)
mouse_packets_start_again_after_a_lost_byte :: proc(t: ^testing.T) {
	feed :: proc(decoder: ^Mouse_Decoder, bytes: []u8, packets: ^[dynamic]Pointer_Packet) {
		for value in bytes {
			if packet, whole := mouse_decoder_byte(decoder, value); whole {
				append(packets, packet)
			}
		}
	}
	packets: [dynamic]Pointer_Packet
	defer delete(packets)
	testing.expect_value(t, mouse_protocol_of_identity(MOUSE_IDENTITY_WHEEL), Mouse_Protocol.Wheel)
	testing.expect_value(t, mouse_protocol_of_identity(MOUSE_IDENTITY_WHEEL_AND_BUTTONS), Mouse_Protocol.Wheel_And_Buttons)
	testing.expect_value(t, mouse_protocol_of_identity(0), Mouse_Protocol.Standard)

	START :: MOUSE_FIRST_BYTE_ALWAYS_SET
	LEFT_BUTTON :: 0x01 // display.BUTTON_LEFT, the low bit of MOUSE_FIRST_BYTE_BUTTONS.
	UP_ONE :: 0xFF // The fourth byte of one notch away from the principal: -1.
	decoder := Mouse_Decoder{protocol = .Wheel}
	// One packet: the left button, 5 to the right, 3 up, one notch away.
	feed(&decoder, []u8{START | LEFT_BUTTON, 5, 3, UP_ONE}, &packets)
	testing.expect_value(t, len(packets), 1)
	if len(packets) == 1 {
		testing.expect_value(t, packets[0], Pointer_Packet{motion_x = 5, motion_y = -3, buttons = LEFT_BUTTON, wheel = -1})
	}
	clear(&packets)

	// A packet whose first byte is lost: its second byte (72, which has
	// the bit of a first byte) is read as a first byte, and the first byte
	// of the next packet as a fourth byte: 8 is past MOUSE_WHEEL_MOST. The
	// decoder starts again, and the next packet is right.
	MOVE_THAT_LOOKS_LIKE_A_START :: 0x48
	feed(&decoder, []u8{MOVE_THAT_LOOKS_LIKE_A_START, 0x30, 0x00}, &packets)
	feed(&decoder, []u8{START, 2, 3, UP_ONE}, &packets)
	testing.expect_value(t, decoder.resyncs, 1)
	testing.expect_value(t, len(packets), 1)
	if len(packets) == 1 {
		testing.expect_value(t, packets[0], Pointer_Packet{motion_x = 2, motion_y = -3, wheel = -1})
	}
	clear(&packets)

	// An overflow of x: the packet is dropped, the next one is right.
	feed(&decoder, []u8{START | MOUSE_FIRST_BYTE_OVERFLOW_X, 1, 1, 0}, &packets)
	feed(&decoder, []u8{START, 1, 0, 1}, &packets)
	testing.expect_value(t, decoder.overflows, 1)
	testing.expect_value(t, len(packets), 1)
	if len(packets) == 1 {
		testing.expect_value(t, packets[0], Pointer_Packet{motion_x = 1, wheel = 1})
	}
	clear(&packets)

	// The Explorer protocol: the low 4 bits 0xF are -1, beside the bit of
	// a fifth button; a fourth byte with a bit that is always 0 starts the
	// packet again.
	FIFTH_BUTTON_AND_UP_ONE :: 0x2F
	explorer := Mouse_Decoder{protocol = .Wheel_And_Buttons}
	feed(&explorer, []u8{START, 0, 0, FIFTH_BUTTON_AND_UP_ONE}, &packets)
	feed(&explorer, []u8{START, 0, 0, MOUSE_EXPLORER_ZERO_BITS}, &packets)
	testing.expect_value(t, len(packets), 1)
	if len(packets) == 1 {
		testing.expect_value(t, packets[0].wheel, -1)
	}
	testing.expect_value(t, explorer.resyncs, 1)
}

// The move that waits goes to the window after the records that have an
// order.
@(test)
a_move_after_the_ordered_records :: proc(t: ^testing.T) {
	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	storage := make([]ring.Record, WINDOW_QUEUE_CAPACITY)
	defer delete(storage)
	queue := Window_Queue{records = storage}
	read: [dynamic]ring.Record
	defer delete(read)

	for number in 0 ..< 33 {
		window_queue_put(&queue, target, key_record(number), .Key)
	}
	window_queue_put_pointer(&queue, target, pointer_record(5, 0), 0)
	window_queue_put_pointer(&queue, target, pointer_record(6, 0), 0)
	testing.expect_value(t, queue.count, 1)
	testing.expect(t, queue.move_waits)
	read_some(target, 32, &read)
	testing.expect(t, window_queue_send_waiting(&queue, target))
	read_some(target, 32, &read)
	testing.expect_value(t, len(read), 34)
	if len(read) == 34 {
		testing.expect_value(t, read[32].values[0], 32)
		testing.expect_value(t, read[33].kind, 2)
		testing.expect_value(t, read[33].values[0], 6)
	}
	testing.expect_value(t, queue.delivered, 34)
	testing.expect_value(t, queue.keys_delivered, 33)
}

// With the ring full and 256 records waiting, a record is refused and
// counted. The loss period begins one time, ends when the window read each
// record that waited, and gives the counts of the period only.
@(test)
a_full_queue_refuses_and_counts :: proc(t: ^testing.T) {
	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	storage := make([]ring.Record, WINDOW_QUEUE_CAPACITY)
	defer delete(storage)
	queue := Window_Queue{records = storage}
	read: [dynamic]ring.Record
	defer delete(read)

	for period in 0 ..< 2 {
		clear(&read)
		kept := 32 + WINDOW_QUEUE_CAPACITY
		for number in 0 ..< kept {
			testing.expect(t, !window_queue_put(&queue, target, key_record(number), .Key).loss_began)
		}
		testing.expect_value(t, queue.count, WINDOW_QUEUE_CAPACITY)
		began := 0
		for number in 0 ..< 3 + period {
			if window_queue_put(&queue, target, key_record(1000 + number), .Key).loss_began {
				began += 1
			}
		}
		if window_queue_put(&queue, target, ring.Record{kind = 3}, .Other).loss_began {
			began += 1
		}
		// A change of a button is refused too; a move is not: it waits alone.
		if window_queue_put_pointer(&queue, target, pointer_record(1, u64(1 + period)), u64(1 + period)).loss_began {
			began += 1
		}
		window_queue_put_pointer(&queue, target, pointer_record(2, u64(1 + period)), u64(1 + period))
		testing.expect_value(t, began, 1)
		testing.expect(t, queue.loss.open)
		testing.expect(t, queue.move_waits)
		_, ended_early := window_queue_loss_ended(&queue)
		testing.expect(t, !ended_early, "records still wait")

		for round := 0; window_queue_waits(&queue) && round < 1000; round += 1 {
			read_some(target, 9, &read)
			window_queue_send_waiting(&queue, target)
		}
		read_some(target, 64, &read)
		lost, ended := window_queue_loss_ended(&queue)
		testing.expect(t, ended)
		testing.expect_value(t, lost[Record_Class.Key], u64(3 + period))
		testing.expect_value(t, lost[Record_Class.Other], 1)
		testing.expect_value(t, lost[Record_Class.Pointer], 1)
		_, again := window_queue_loss_ended(&queue)
		testing.expect(t, !again)
		// Each record that was kept arrived, in order; the move after them.
		testing.expect_value(t, len(read), kept + 1)
		for index in 0 ..< min(kept, len(read)) {
			testing.expect_value(t, read[index].values[0], u64(index))
		}
	}
	testing.expect_value(t, queue.refused[Record_Class.Key], 7)
	testing.expect_value(t, queue.loss.lost, 11)
}

// A queue with no memory keeps nothing: the ring is the only room.
@(test)
a_queue_with_no_memory_refuses_at_a_full_ring :: proc(t: ^testing.T) {
	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	queue: Window_Queue
	for number in 0 ..< 32 {
		testing.expect(t, window_queue_put(&queue, target, key_record(number), .Key).wrote)
	}
	result := window_queue_put(&queue, target, key_record(32), .Key)
	testing.expect(t, !result.wrote && result.loss_began)
	testing.expect_value(t, queue.refused[Record_Class.Key], 1)
	testing.expect_value(t, queue.count, 0)
}

// A reader that writes a false read count does not look like a full queue:
// the writer waits for room only on a queue that is exactly full.
@(test)
only_an_exactly_full_queue_is_waited_on :: proc(t: ^testing.T) {
	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	testing.expect(t, !queue_is_exactly_full(target))
	for number in 0 ..< 32 {
		ring.push(target, key_record(number))
	}
	testing.expect(t, queue_is_exactly_full(target))
	target.counters.read = target.counters.write - 40 // More records than the queue holds.
	testing.expect(t, !queue_is_exactly_full(target))
	testing.expect(t, !ring.push(target, key_record(0)), "the queue still takes nothing")
	target.counters.read = target.counters.write - 31
	testing.expect(t, !queue_is_exactly_full(target))
}

// The back pressure rule of the input service: a byte of the keyboard is
// read only when its record has a place in the ring, after each packet of
// the mouse that waits; a byte of the mouse also while the backlog has a
// free entry.
@(test)
the_input_service_reads_a_byte_only_with_a_place_for_its_record :: proc(t: ^testing.T) {
	testing.expect(t, input_byte_can_be_read(false, true, 0))
	testing.expect(t, input_byte_can_be_read(true, true, 0))
	testing.expect(t, !input_byte_can_be_read(false, false, 0), "a full ring holds the keyboard")
	testing.expect(t, !input_byte_can_be_read(false, true, 1), "a key does not pass a packet that waits")
	testing.expect(t, input_byte_can_be_read(true, false, 0))
	testing.expect(t, input_byte_can_be_read(true, false, POINTER_BACKLOG_CAPACITY - 1))
	testing.expect(t, !input_byte_can_be_read(true, false, POINTER_BACKLOG_CAPACITY), "a full backlog holds the mouse")
	testing.expect(t, !input_byte_can_be_read(true, true, POINTER_BACKLOG_CAPACITY))
}

// The moves that wait in the input service add up: the end place is the
// same. Each change of a button keeps its entry and its order.
@(test)
the_moves_of_the_backlog_add_up :: proc(t: ^testing.T) {
	backlog: Pointer_Backlog
	_, any := pointer_backlog_first(&backlog)
	testing.expect(t, !any)
	testing.expect(t, pointer_backlog_add(&backlog, {motion_x = 3, motion_y = -2}))
	testing.expect(t, pointer_backlog_add(&backlog, {motion_x = 4, motion_y = -1}))
	testing.expect(t, pointer_backlog_add(&backlog, {motion_x = -10, motion_y = 5}))
	testing.expect_value(t, backlog.count, 1)
	testing.expect_value(t, backlog.merged, 2)
	testing.expect_value(t, backlog.packets[0], Pointer_Packet{motion_x = -3, motion_y = 2})
	// A press, a move with the button down, a release.
	testing.expect(t, pointer_backlog_add(&backlog, {motion_x = 1, buttons = 1}))
	testing.expect(t, pointer_backlog_add(&backlog, {motion_x = 1, buttons = 1}))
	testing.expect(t, pointer_backlog_add(&backlog, {buttons = 0}))
	testing.expect_value(t, backlog.count, 3)
	first, _ := pointer_backlog_first(&backlog)
	testing.expect_value(t, first, Pointer_Packet{motion_x = -3, motion_y = 2})
	pointer_backlog_remove_first(&backlog)
	first, _ = pointer_backlog_first(&backlog)
	testing.expect_value(t, first, Pointer_Packet{motion_x = 2, buttons = 1})
	pointer_backlog_remove_first(&backlog)
	pointer_backlog_remove_first(&backlog)
	pointer_backlog_remove_first(&backlog) // None waits: nothing changes.
	testing.expect_value(t, backlog.count, 0)

	// Changes of a button fill the backlog; a move with the last buttons
	// still joins; one more change has no entry.
	for number in 0 ..< POINTER_BACKLOG_CAPACITY {
		testing.expect(t, pointer_backlog_add(&backlog, {buttons = u64(number % 2 + 1)}))
	}
	last_buttons := u64((POINTER_BACKLOG_CAPACITY - 1) % 2 + 1)
	testing.expect(t, pointer_backlog_add(&backlog, {motion_x = 9, buttons = last_buttons}))
	testing.expect(t, !pointer_backlog_add(&backlog, {buttons = 4}))
	testing.expect_value(t, backlog.count, POINTER_BACKLOG_CAPACITY)
}

// One line when a loss begins, the count when it ends, and a new period
// after that.
@(test)
a_loss_period_begins_one_time_and_gives_its_count :: proc(t: ^testing.T) {
	period: Loss_Period
	_, ended := loss_end(&period)
	testing.expect(t, !ended, "no period is open")
	testing.expect(t, loss_count(&period))
	testing.expect(t, !loss_count(&period))
	testing.expect(t, !loss_count(&period, 3))
	count: u64
	count, ended = loss_end(&period)
	testing.expect(t, ended)
	testing.expect_value(t, count, 5)
	_, ended = loss_end(&period)
	testing.expect(t, !ended)
	testing.expect(t, loss_count(&period))
	count, _ = loss_end(&period)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, period.lost, 6)
}

// Relative pointer deltas coalesce by summing dx and dy when the ring is full,
// clamp at +/-POINTER_DELTA_LIMIT, fold into button and wheel events without
// dropping motion, and drop cleanly when pointer lock ends.
@(test)
pointer_deltas_sum_when_coalesced_and_fold_into_buttons :: proc(t: ^testing.T) {
	DELTA_KIND :: u32(14)
	delta_record :: proc(dx, dy: i64, buttons: u64, wheel: i64 = 0) -> ring.Record {
		return {kind = DELTA_KIND, values = {0 = u64(dx), 1 = u64(dy), 2 = buttons, 3 = u64(wheel)}}
	}

	// Clamping edges of pointer_delta_add.
	testing.expect_value(t, pointer_delta_add(POINTER_DELTA_LIMIT, 1), i64(POINTER_DELTA_LIMIT))
	testing.expect_value(t, pointer_delta_add(-POINTER_DELTA_LIMIT, -1), i64(-POINTER_DELTA_LIMIT))
	testing.expect_value(t, pointer_delta_add(max(i64), max(i64)), i64(POINTER_DELTA_LIMIT))
	testing.expect_value(t, pointer_delta_add(min(i64), min(i64)), i64(-POINTER_DELTA_LIMIT))

	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	storage := make([]ring.Record, WINDOW_QUEUE_CAPACITY)
	defer delete(storage)
	queue := Window_Queue{records = storage}
	read: [dynamic]ring.Record
	defer delete(read)

	// Fill the ring with 32 keys so subsequent deltas wait in the queue.
	for number in 0 ..< 32 {
		window_queue_put(&queue, target, key_record(number), .Key)
	}
	// Three relative moves coalesce into their exact sum (+25, -15).
	window_queue_put_pointer_delta(&queue, target, delta_record(10, -5, 0), 0)
	window_queue_put_pointer_delta(&queue, target, delta_record(20, -12, 0), 0)
	window_queue_put_pointer_delta(&queue, target, delta_record(-5, 2, 0), 0)
	testing.expect(t, queue.move_waits)
	testing.expect_value(t, queue.count, 0)
	testing.expect_value(t, queue.moves_merged, 2)
	testing.expect_value(t, i64(queue.move.values[POINTER_RECORD_X]), i64(25))
	testing.expect_value(t, i64(queue.move.values[POINTER_RECORD_Y]), i64(-15))

	// A button press folds the pending (+25, -15) delta with (+3, +4) -> (+28, -11).
	window_queue_put_pointer_delta(&queue, target, delta_record(3, 4, 1), 1)
	testing.expect(t, !queue.move_waits)
	testing.expect_value(t, queue.count, 1)

	// Two wheel records merge both notches and deltas.
	window_queue_put_pointer_delta(&queue, target, delta_record(4, -2, 1, 1), 1, 1)
	window_queue_put_pointer_delta(&queue, target, delta_record(-1, 6, 1, 2), 1, 2)
	testing.expect_value(t, queue.count, 2)

	// Pending delta after ordered records can be dropped on lock release.
	window_queue_put_pointer_delta(&queue, target, delta_record(7, 8, 1), 1)
	testing.expect(t, queue.move_waits)
	window_queue_drop_pending_move(&queue, DELTA_KIND)
	testing.expect(t, !queue.move_waits)

	for round := 0; window_queue_waits(&queue) && round < 100; round += 1 {
		read_some(target, 8, &read)
		window_queue_send_waiting(&queue, target)
	}
	read_some(target, 64, &read)
	testing.expect_value(t, len(read), 34)
	if len(read) == 34 {
		testing.expect_value(t, i64(read[32].values[POINTER_RECORD_X]), i64(28))
		testing.expect_value(t, i64(read[32].values[POINTER_RECORD_Y]), i64(-11))
		testing.expect_value(t, read[32].values[POINTER_RECORD_BUTTONS], u64(1))
		testing.expect_value(t, i64(read[33].values[POINTER_RECORD_X]), i64(3))
		testing.expect_value(t, i64(read[33].values[POINTER_RECORD_Y]), i64(4))
		testing.expect_value(t, i64(read[33].values[POINTER_RECORD_WHEEL]), i64(3))
	}
}

// window_queue_wait_prepare and window_queue_wait_finish never strand waiting
// keys (including Enter at the end of a burst) when the window reads
// concurrently, wait for room when the ring is exactly full, and refuse to
// spin when a hostile reader writes a false read count.
@(test)
window_queue_wait_prepare_never_strands_keys_and_refuses_false_counts :: proc(t: ^testing.T) {
	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	storage := make([]ring.Record, WINDOW_QUEUE_CAPACITY)
	defer delete(storage)
	queue := Window_Queue{records = storage}

	// Empty queue: no wait action, nothing written.
	action, wrote := window_queue_wait_prepare(&queue, target, 4)
	testing.expect_value(t, action, Window_Wait_Action.None)
	testing.expect(t, !wrote)

	// Burst of 200 keys ending with Enter (record 199): 32 enter the ring and
	// 168 wait in queue.
	BURST :: 200
	for number in 0 ..< BURST {
		window_queue_put(&queue, target, key_record(number), .Key)
	}
	testing.expect_value(t, queue.count, BURST - 32)
	testing.expect(t, queue_is_exactly_full(target))

	// Ring is exactly full: wait for room.
	action, wrote = window_queue_wait_prepare(&queue, target, 4)
	testing.expect_value(t, action, Window_Wait_Action.Wait_Room)
	testing.expect(t, !wrote)

	// Zero tries edge: still reports Wait_Room when full.
	action, wrote = window_queue_wait_prepare(&queue, target, 0)
	testing.expect_value(t, action, Window_Wait_Action.Wait_Room)
	testing.expect(t, !wrote)

	// Reader pops 1 record after a pass made progress: target is no longer
	// full while records still wait. window_queue_wait_finish must return
	// Continue_Now so the compositor loops immediately without sleeping.
	read: [dynamic]ring.Record
	defer delete(read)
	read_some(target, 1, &read)
	action, wrote = window_queue_wait_prepare(&queue, target, 4)
	testing.expect_value(t, action, Window_Wait_Action.Wait_Room)
	testing.expect(t, wrote)
	read_some(target, 1, &read)
	testing.expect(t, !queue_is_exactly_full(target))
	testing.expect_value(t, window_queue_wait_finish(&queue, target, true), Window_Wait_Action.Continue_Now)
	testing.expect_value(t, window_queue_wait_finish(&queue, target, false), Window_Wait_Action.None)

	// Drain the whole burst in steps: every key including Enter (199) arrives
	// in exact order.
	for round := 0; window_queue_waits(&queue) && round < 100; round += 1 {
		read_some(target, 16, &read)
		action, wrote = window_queue_wait_prepare(&queue, target, 4)
		testing.expect(t, wrote)
		if window_queue_waits(&queue) {
			testing.expect(t, action == .Wait_Room || action == .Continue_Now)
		} else {
			testing.expect_value(t, action, Window_Wait_Action.None)
		}
	}
	read_some(target, 64, &read)
	testing.expect_value(t, len(read), BURST)
	if len(read) == BURST {
		for number in 0 ..< BURST {
			if read[number].values[0] != u64(number) {
				testing.expectf(t, false, "record %d was %d, expected %d", number, read[number].values[0], number)
				break
			}
		}
	}

	// Hostile client writes a false read count (write - read > capacity) while
	// records wait: prepare must return None and never spin.
	for number in 0 ..< 40 {
		window_queue_put(&queue, target, key_record(number), .Key)
	}
	testing.expect(t, window_queue_waits(&queue))
	target.counters.read = target.counters.write + 5
	testing.expect(t, !queue_is_exactly_full(target))
	action, wrote = window_queue_wait_prepare(&queue, target, 4)
	testing.expect_value(t, action, Window_Wait_Action.None)
	testing.expect(t, !wrote)
}

// A priority record (such as Surface_Answer) never stalls when room opens
// between a failed push and the full check, always precedes regular queued
// events when room opens, and refuses to spin on a false read counter.
@(test)
window_record_wait_prepare_handles_toctou_room_and_false_counts :: proc(t: ^testing.T) {
	memory := new(Ring_Memory)
	defer free(memory)
	opened := window_ring(memory)
	target := &opened.completions
	storage := make([]ring.Record, WINDOW_QUEUE_CAPACITY)
	defer delete(storage)
	queue := Window_Queue{records = storage}

	ANSWER_KIND :: u32(99)
	due := false
	answer := ring.Record{kind = ANSWER_KIND, values = {0 = 7}}

	// Not due: no action.
	action, wrote := window_record_wait_prepare(&due, &answer, target, 4)
	testing.expect_value(t, action, Window_Wait_Action.None)
	testing.expect(t, !wrote)

	// Fill the ring and queue two regular keys behind it.
	for number in 0 ..< 34 {
		window_queue_put(&queue, target, key_record(number), .Key)
	}
	testing.expect(t, queue_is_exactly_full(target))
	testing.expect_value(t, queue.count, 2)

	// Full ring: Wait_Room, due stays true, record untouched.
	due = true
	action, wrote = window_record_wait_prepare(&due, &answer, target, 4)
	testing.expect_value(t, action, Window_Wait_Action.Wait_Room)
	testing.expect(t, !wrote)
	testing.expect(t, due)
	testing.expect_value(t, answer.kind, ANSWER_KIND)

	// TOCTOU edge: window pops 1 slot after a failed push (modeled with
	// tries = 0 while due is still true and room exists): returns Continue_Now
	// instead of None so the compositor never sleeps until its next timer.
	read: [dynamic]ring.Record
	defer delete(read)
	read_some(target, 1, &read)
	testing.expect(t, queue_has_room(target))
	action, wrote = window_record_wait_prepare(&due, &answer, target, 0)
	testing.expect_value(t, action, Window_Wait_Action.Continue_Now)
	testing.expect(t, !wrote)
	testing.expect(t, due)

	// With tries > 0, the priority record pushes into the freed slot ahead of
	// the two queued regular keys.
	action, wrote = window_record_wait_prepare(&due, &answer, target, 4)
	testing.expect_value(t, action, Window_Wait_Action.None)
	testing.expect(t, wrote)
	testing.expect(t, !due)
	testing.expect_value(t, answer.kind, u32(0))
	// Ring is now full again; regular keys wait behind the priority record.
	q_action, q_wrote := window_queue_wait_prepare(&queue, target, 4)
	testing.expect_value(t, q_action, Window_Wait_Action.Wait_Room)
	testing.expect(t, !q_wrote)

	// Drain all remaining records: record 32 is the priority answer, followed by
	// queued keys 32 and 33.
	read_some(target, 32, &read)
	_, q_wrote = window_queue_wait_prepare(&queue, target, 4)
	testing.expect(t, q_wrote)
	read_some(target, 32, &read)
	testing.expect_value(t, len(read), 35)
	if len(read) == 35 {
		testing.expect_value(t, read[32].kind, ANSWER_KIND)
		testing.expect_value(t, read[32].values[0], u64(7))
		testing.expect_value(t, read[33].values[0], u64(32))
		testing.expect_value(t, read[34].values[0], u64(33))
	}

	// Hostile client writes a false read counter while a priority record is due:
	// returns None without spinning.
	due = true
	answer = ring.Record{kind = ANSWER_KIND, values = {0 = 8}}
	target.counters.read = target.counters.write + 5
	testing.expect(t, !queue_is_exactly_full(target))
	testing.expect(t, !queue_has_room(target))
	action, wrote = window_record_wait_prepare(&due, &answer, target, 4)
	testing.expect_value(t, action, Window_Wait_Action.None)
	testing.expect(t, !wrote)
	testing.expect(t, due)
}
