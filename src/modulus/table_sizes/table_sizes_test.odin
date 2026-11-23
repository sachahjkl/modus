#+build !freestanding
package table_sizes

import "core:testing"
import op "modus:contract/operation"

// The edges first: no memory, one page, the pages of the least, the pages
// just past one step, the pages of the most and past them, and the largest
// count of the type. A count never leaves the range, and the other tables
// follow the slots.
@(test)
the_sizes_stay_between_the_least_and_the_most :: proc(t: ^testing.T) {
	least := Table_Sizes{op.PROCESS_SLOTS_LEAST, op.PROCESS_SLOTS_LEAST * THREADS_OF_A_PROCESS_SLOT, op.PROCESS_SLOTS_LEAST * REGIONS_OF_A_PROCESS_SLOT}
	most := Table_Sizes{op.PROCESS_SLOTS_MOST, THREADS_MOST, REGIONS_MOST}
	testing.expect_value(t, sizes_of_memory(0), least)
	testing.expect_value(t, sizes_of_memory(1), least)
	testing.expect_value(t, sizes_of_memory(op.PROCESS_SLOTS_LEAST * PAGES_OF_A_PROCESS_SLOT), least)
	// One slot past the least is a whole step more.
	testing.expect_value(t, sizes_of_memory((op.PROCESS_SLOTS_LEAST + 1) * PAGES_OF_A_PROCESS_SLOT).process_slots, u32(op.PROCESS_SLOTS_LEAST + PROCESS_SLOTS_STEP))
	testing.expect_value(t, sizes_of_memory(op.PROCESS_SLOTS_MOST * PAGES_OF_A_PROCESS_SLOT), most)
	testing.expect_value(t, sizes_of_memory(op.PROCESS_SLOTS_MOST * PAGES_OF_A_PROCESS_SLOT + 1), most)
	testing.expect_value(t, sizes_of_memory(max(u64)), most)
}

// The machines that the system runs on: the browser machine of 256 MiB, the
// test machine of 1 GiB less the firmware, and a machine of 4 GiB.
@(test)
the_sizes_of_the_known_machines :: proc(t: ^testing.T) {
	testing.expect_value(t, sizes_of_memory(60_000).process_slots, u32(64))
	testing.expect_value(t, sizes_of_memory(252_000), Table_Sizes{256, 1024, 16384})
	testing.expect_value(t, sizes_of_memory(262_144).process_slots, u32(256))
	testing.expect_value(t, sizes_of_memory(1_000_000).process_slots, u32(1024))
	// Each count is a multiple of the step, so a set of slots is whole words.
	for pages in ([?]u64{0, 70_000, 131_071, 252_000, 600_001}) {
		testing.expect_value(t, sizes_of_memory(pages).process_slots % PROCESS_SLOTS_STEP, u32(0))
	}
}
