#+build !freestanding
package system

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:disk_process"
import "core:testing"

// The test that breaks the division on its first day
// (docs/research/budgets_as_policy_critique.md, section 12): a start list
// of the least machine whose floors fit and whose default sizes do not.
// The last process still gets its floor, no process gets less than its
// floor, the sizes do not pass the pages, and the order of the list
// changes no size. One page less than the floors refuses the whole list,
// and no size moves.
@(test)
the_floors_of_a_start_list_come_before_any_size :: proc(t: ^testing.T) {
	machine := u64(module.TEST_MACHINE_ROOT_PAGES)
	floors := [?]u64{40_000, 30_000, 20_000, 10_000, 5_000, 1_000, 1}
	floor_sum: u64
	list: [len(floors)]Start_Size
	for floor, index in floors {
		floor_sum += floor
		list[index] = {floor = floor, size = budget_size(floor, max(u64), module.DEFAULT_GROWTH_FACTOR)}
	}
	size_sum: u64
	for item in list {
		size_sum += item.size
	}
	testing.expect(t, floor_sum <= machine && size_sum > machine, "the floors fit and the default sizes do not")

	divided := list
	testing.expect(t, start_list_sizes(divided[:], machine, 0))
	divided_sum: u64
	for item, index in divided {
		testing.expectf(t, item.size >= floors[index], "the process %d gets its floor", index)
		testing.expectf(t, item.size <= list[index].size, "the process %d gets no more than its size", index)
		divided_sum += item.size
	}
	testing.expect(t, divided_sum <= machine, "the sizes fit in the pages of the starter")
	testing.expect_value(t, divided[len(divided) - 1].size, floors[len(floors) - 1])

	// The same list in the other order gives each process the same size.
	reversed: [len(floors)]Start_Size
	for item, index in list {
		reversed[len(list) - 1 - index] = item
	}
	testing.expect(t, start_list_sizes(reversed[:], machine, 0))
	for item, index in divided {
		testing.expectf(t, reversed[len(list) - 1 - index].size == item.size, "the process %d gets the same size in the other order", index)
	}

	// The floors at the pages exactly: each gets its floor and nothing more.
	exact := list
	testing.expect(t, start_list_sizes(exact[:], floor_sum, 0))
	for item, index in exact {
		testing.expect_value(t, item.size, floors[index])
	}
	// One page less: the list does not fit, and no size changes.
	short := list
	testing.expect(t, !start_list_sizes(short[:], floor_sum - 1, 0))
	testing.expect_value(t, short, list)
	// The pages that the starter keeps go before any growth: with all the
	// spare pages kept, each process gets its floor.
	kept := list
	testing.expect(t, start_list_sizes(kept[:], machine, machine - floor_sum))
	for item, index in kept {
		testing.expect_value(t, item.size, floors[index])
	}
	// Sizes that fit are not touched.
	roomy := list
	testing.expect(t, start_list_sizes(roomy[:], size_sum, 0))
	testing.expect_value(t, roomy, list)
	// An empty list fits in no page.
	testing.expect(t, start_list_sizes(nil, 0, 0))
	// Floors and sizes at the end of 64 bits do not wrap the sums.
	huge := [2]Start_Size{{floor = max(u64), size = max(u64)}, {floor = max(u64), size = max(u64)}}
	testing.expect(t, !start_list_sizes(huge[:], max(u64), 0))
}

// The size with no row: twice the floor, rounded up to a whole frame list
// page, at most the share, never below the floor. The edges first.
@(test)
the_size_is_twice_the_floor_within_the_share :: proc(t: ^testing.T) {
	factor := u64(module.DEFAULT_GROWTH_FACTOR)
	testing.expect_value(t, budget_size(0, 50_000, factor), u64(0))
	testing.expect_value(t, budget_size(1, 50_000, factor), u64(op.MEMORY_LIST_ENTRIES))
	testing.expect_value(t, budget_size(256, 50_000, factor), u64(512))
	testing.expect_value(t, budget_size(257, 50_000, factor), u64(1024))
	testing.expect_value(t, budget_size(1000, 50_000, factor), u64(2048))
	// The share bounds the size, and the floor wins over the share.
	testing.expect_value(t, budget_size(25_000, 50_000, factor), u64(50_000))
	testing.expect_value(t, budget_size(25_001, 50_000, factor), u64(50_000))
	testing.expect_value(t, budget_size(50_000, 50_000, factor), u64(50_000))
	testing.expect_value(t, budget_size(50_001, 50_000, factor), u64(50_001))
	// A factor of 1 gives the floor rounded; a factor of 0, which no border
	// passes, gives the same.
	testing.expect_value(t, budget_size(1000, 50_000, 1), u64(1024))
	testing.expect_value(t, budget_size(1000, 50_000, 0), u64(1024))
	// A product past 64 bits stops at the largest, and the floor stays.
	testing.expect_value(t, budget_size(max(u64), max(u64), factor), max(u64))
	testing.expect_value(t, budget_size(max(u64) / 2 + 1, max(u64), factor), max(u64))
	testing.expect_value(t, budget_size(max(u64) - 3, max(u64) - 1, 1), max(u64) - 1)
	// The border of the factor refuses 0 and takes 1 and the largest word.
	_, zero_ok := module.growth_factor_of_word(0)
	testing.expect(t, !zero_ok)
	one, one_ok := module.growth_factor_of_word(1)
	testing.expect(t, one_ok && one == 1)
	most, most_ok := module.growth_factor_of_word(max(u64))
	testing.expect(t, most_ok && most == max(u64))
}

// A floor of no page, no process or no thread starts nothing: the file is
// damaged. A floor of one of each starts.
@(test)
a_floor_of_no_slot_is_refused :: proc(t: ^testing.T) {
	testing.expect(t, !floor_usable({}))
	testing.expect(t, !floor_usable({pages = 1, processes = 0, threads = 1}))
	testing.expect(t, !floor_usable({pages = 1, processes = 1, threads = 0}))
	testing.expect(t, !floor_usable({pages = 0, processes = 1, threads = 1}))
	testing.expect(t, floor_usable({pages = 1, processes = 1, threads = 1}))
	testing.expect(t, floor_usable({pages = max(u64), processes = max(u64), threads = max(u64)}))
}

// The largest budget of a process of the boot image is one share of the
// pages and the threads of the machine, never below the least largest
// budget, never more threads than a process holds. The edges first: no
// page, one page, the pages where the share reaches the least, one more,
// and the largest count that a machine can name.
@(test)
the_largest_budget_is_a_share_of_the_machine :: proc(t: ^testing.T) {
	least := module.LARGEST_BUDGET_LEAST
	share := u64(module.LARGEST_BUDGET_SHARE_DEFAULT)
	of_pages :: proc(pages: u64, share: u64) -> Budget_Amounts {
		return module.largest_budget_of_machine({pages = pages}, share)
	}
	testing.expect_value(t, of_pages(0, share), least)
	testing.expect_value(t, of_pages(1, share), least)
	at_least := least.pages * share
	testing.expect_value(t, of_pages(at_least - 1, share).pages, least.pages)
	testing.expect_value(t, of_pages(at_least, share).pages, least.pages)
	testing.expect_value(t, of_pages(at_least + share, share).pages, least.pages + 1)
	most := module.largest_budget_of_machine({pages = max(u64), threads = max(u64)}, share)
	testing.expect_value(t, most.pages, max(u64) / share)
	testing.expect_value(t, most.threads, u64(op.THREAD_CAPACITY))
	testing.expect_value(t, most.processes, least.processes)
	machine := module.largest_budget_of_machine({pages = 200_000, threads = 1023}, share)
	testing.expect_value(t, machine.pages, 50_000)
	testing.expect_value(t, machine.threads, 255)
	// A floor at the share gets the share; a floor past it gets its floor.
	testing.expect_value(t, budget_size(machine.pages, machine.pages, module.DEFAULT_GROWTH_FACTOR), machine.pages)
	testing.expect_value(t, budget_size(machine.pages + 1, machine.pages, module.DEFAULT_GROWTH_FACTOR), machine.pages + 1)
}

// The share of the plan passes one border: a word below the least, 0, past
// the most and the largest word are refused; the least and the most pass,
// and a share of 1 gives one process the whole machine.
@(test)
the_share_of_a_plan_passes_its_border :: proc(t: ^testing.T) {
	for word in ([?]u64{0, module.LARGEST_BUDGET_SHARE_MOST + 1, max(u64)}) {
		_, ok := module.budget_share_of_word(word)
		testing.expectf(t, !ok, "the share %d is taken", word)
	}
	least, least_ok := module.budget_share_of_word(module.LARGEST_BUDGET_SHARE_LEAST)
	most, most_ok := module.budget_share_of_word(module.LARGEST_BUDGET_SHARE_MOST)
	testing.expect(t, least_ok && most_ok && least == 1 && most == 64)
	whole := module.largest_budget_of_machine({pages = 200_000, threads = 1023}, least)
	testing.expect_value(t, whole.pages, 200_000)
	testing.expect_value(t, whole.threads, u64(op.THREAD_CAPACITY))
	small := module.largest_budget_of_machine({pages = 200_000, threads = 1023}, most)
	testing.expect_value(t, small.pages, module.LARGEST_BUDGET_LEAST_PAGES)
	// A share of 0 that skipped the border still divides by one, never by 0.
	testing.expect_value(t, module.largest_budget_of_machine({pages = 8}, 0).pages, module.LARGEST_BUDGET_LEAST_PAGES)
}

// The budget of the disk processes is stated, not a share: it never
// returns to the root service, so it covers their need and no more, and
// one disk process gets half of it at most.
@(test)
the_disk_budgets_are_stated :: proc(t: ^testing.T) {
	testing.expect_value(t, disk_process.PROCESSES_BUDGET, Budget_Amounts{pages = 32768, processes = 4, threads = 16})
	testing.expect_value(t, disk_process.LARGEST_BUDGET, Budget_Amounts{pages = 16384, processes = 1, threads = 4})
	largest := disk_process.LARGEST_BUDGET
	shared := disk_process.PROCESSES_BUDGET
	testing.expect(t, largest.pages < shared.pages && largest.processes <= shared.processes && largest.threads <= shared.threads)
	// The disk processes that the shared budget pays at one time, each at its
	// largest: as many as its process slots, or fewer.
	held := shared
	count := 0
	for {
		if _, short := budget_first_short_part(largest, held); short {
			break
		}
		held.pages -= largest.pages
		held.processes -= largest.processes
		held.threads -= largest.threads
		count += 1
	}
	testing.expect(t, count >= 1 && u64(count) <= shared.processes, "a bounded count of disk processes runs at one time")
}

// The first part that a holder cannot pay: the part that a refusal names.
@(test)
budget_first_short_part_names_the_part :: proc(t: ^testing.T) {
	needed := Budget_Amounts{pages = 4096, processes = 2, threads = 6}
	part, short := budget_first_short_part(needed, {pages = 4096, processes = 2, threads = 6})
	testing.expect(t, !short, "a holder of exactly the amounts can pay")
	part, short = budget_first_short_part(needed, {pages = 9000, processes = 1, threads = 2})
	testing.expect(t, short)
	testing.expect_value(t, part, Budget_Part.Processes)
	part, short = budget_first_short_part(needed, {pages = 100, processes = 0, threads = 0})
	testing.expect_value(t, part, Budget_Part.Pages)
	testing.expect_value(t, budget_part_names[part], "pages")
	part, short = budget_first_short_part(needed, {pages = 4095, processes = 2, threads = 6})
	testing.expect(t, short && part == .Pages, "one page short is short")
}

// The wiring budget of an asker is a stated amount: its wiring pages, the
// pages when it states more, half of its pages when it states none.
@(test)
the_wiring_pages_are_a_stated_amount :: proc(t: ^testing.T) {
	testing.expect_value(t, wiring_pages_of_floor({pages = 200, wiring_pages = 28}), u64(28))
	testing.expect_value(t, wiring_pages_of_floor({pages = 200, wiring_pages = 200}), u64(200))
	testing.expect_value(t, wiring_pages_of_floor({pages = 200, wiring_pages = 201}), u64(200))
	testing.expect_value(t, wiring_pages_of_floor({pages = 200}), u64(100))
	testing.expect_value(t, wiring_pages_of_floor({pages = 1}), u64(0))
	testing.expect_value(t, wiring_pages_of_floor({}), u64(0))
}

// The tables of a mapping at any address: one at each level for a page,
// two at each level for a range that can cross a border there, and none
// for no page.
@(test)
the_tables_of_a_mapping_are_its_worst_case :: proc(t: ^testing.T) {
	testing.expect_value(t, op.mapping_table_pages_most(0), u64(0))
	testing.expect_value(t, op.mapping_table_pages_most(1), u64(3))
	testing.expect_value(t, op.mapping_table_pages_most(2), u64(6))
	testing.expect_value(t, op.mapping_table_pages_most(512), u64(6))
	testing.expect_value(t, op.mapping_table_pages_most(513), u64(6))
	testing.expect_value(t, op.mapping_table_pages_most(514), u64(7))
	testing.expect_value(t, op.mapping_table_pages_most(1025), u64(7))
	testing.expect_value(t, op.mapping_table_pages_most(1026), u64(8))
	testing.expect(t, op.mapping_table_pages_most(max(u64)) > op.mapping_table_pages_most(max(u64) / 2))
}
