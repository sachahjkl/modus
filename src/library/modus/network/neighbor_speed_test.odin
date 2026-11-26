#+build !freestanding
#+build !modus
// The cost of the table of neighbors when it is full: a find of an address
// that it does not hold, the worst find, and a learn that replaces the
// oldest entry while requests wait for other addresses. It prints the least
// time of one call over its batches, and checks no speed. For a measure,
// run it alone, optimized, on a quiet host:
//   odin test src/library/modus/network -o:speed -define:ODIN_TEST_NAMES=network.the_cost_of_a_full_table_of_neighbors
package network

import "core:fmt"
import "core:testing"
import "core:time"

@(test)
the_cost_of_a_full_table_of_neighbors :: proc(t: ^testing.T) {
	BATCHES :: 7
	CALLS :: 2000
	BUSY :: 32
	table: Neighbors
	for index in 0 ..< ARP_CAPACITY {
		neighbor_learn(&table, u32(0x0A00_0000 + index), {}, u64(index), true, nil)
	}
	busy: [BUSY]u32
	for &item, index in busy {
		item = u32(0x0A00_0000 + index)
	}
	find_least, learn_least := max(i64), max(i64)
	now := u64(ARP_CAPACITY)
	for _ in 0 ..< BATCHES {
		start := time.tick_now()
		for call in 0 ..< CALLS {
			_, found := neighbor_find(&table, u32(0x0B00_0000 + call))
			testing.expect(t, !found)
		}
		find_least = min(find_least, i64(time.tick_since(start)) / CALLS)
		start = time.tick_now()
		for _ in 0 ..< CALLS {
			now += 1
			testing.expect_value(t, neighbor_learn(&table, u32(0x0C00_0000 + int(now)), {}, now, true, busy[:]), Learned.Replaced)
		}
		learn_least = min(learn_least, i64(time.tick_since(start)) / CALLS)
	}
	fmt.printfln("measure: a full table of %d neighbors: a find that misses %d ns, a learn that replaces with %d requests that wait %d ns", ARP_CAPACITY, find_least, BUSY, learn_least)
}
