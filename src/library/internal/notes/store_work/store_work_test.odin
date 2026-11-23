#+build !freestanding
package store_work

import "core:strings"
import "core:testing"

@(test)
a_queue_gives_its_records_in_order_and_refuses_past_its_capacity :: proc(t: ^testing.T) {
	queue := new(Queue(Request))
	defer free(queue)
	request := new(Request)
	defer free(request)
	out := new(Request)
	defer free(out)
	testing.expect(t, !queue_pop(queue, out))
	for round in 0 ..< 3 {
		for index in 0 ..< QUEUE_CAPACITY {
			request.serial = u64(round * 100 + index)
			testing.expect(t, queue_push(queue, request))
		}
		testing.expect(t, queue_full(queue))
		request.serial = 999
		testing.expect(t, !queue_push(queue, request))
		for index in 0 ..< QUEUE_CAPACITY {
			testing.expect(t, queue_pop(queue, out))
			testing.expect_value(t, out.serial, u64(round * 100 + index))
		}
		out.serial = 7
		testing.expect(t, !queue_pop(queue, out))
		testing.expect_value(t, out.serial, u64(7))
		// The next round starts at another place of the ring.
		testing.expect(t, queue_push(queue, request))
		testing.expect(t, queue_pop(queue, out))
	}
}

@(test)
a_queue_with_a_damaged_count_or_place_refuses_each_act :: proc(t: ^testing.T) {
	queue := new(Queue(Result))
	defer free(queue)
	item := new(Result)
	defer free(item)
	for bad in ([?][2]int{{-1, 0}, {QUEUE_CAPACITY + 1, 0}, {1, -1}, {1, QUEUE_CAPACITY}, {max(int), 0}, {1, min(int)}}) {
		queue.count, queue.first = bad[0], bad[1]
		testing.expectf(t, !queue_push(queue, item), "a push into the queue %v is refused", bad)
		testing.expectf(t, !queue_pop(queue, item), "a pop from the queue %v is refused", bad)
		testing.expect_value(t, queue.count, bad[0])
	}
}

@(test)
a_name_and_the_bytes_past_their_bounds_are_refused :: proc(t: ^testing.T) {
	request := new(Request)
	defer free(request)
	testing.expect(t, !name_set("", &request.name, &request.name_count))
	testing.expect(t, !name_set(strings.repeat("n", NAME_BYTES + 1, context.temp_allocator), &request.name, &request.name_count))
	testing.expect_value(t, request.name_count, 0)
	testing.expect(t, name_set(strings.repeat("n", NAME_BYTES, context.temp_allocator), &request.name, &request.name_count))
	testing.expect_value(t, request.name_count, NAME_BYTES)
	long := make([]u8, len(request.bytes) + 1, context.temp_allocator)
	testing.expect(t, !bytes_set(request, long))
	testing.expect_value(t, request.byte_count, 0)
	testing.expect(t, bytes_set(request, long[:len(request.bytes)]))
	testing.expect_value(t, request.byte_count, len(request.bytes))
	testing.expect(t, bytes_set(request, nil))
	testing.expect_value(t, request.byte_count, 0)
}
