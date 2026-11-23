package system

import "base:intrinsics"
import module "modus:contract/module"
import op "modus:contract/operation"

// The floor of a module and the size of its budget
// (src/md/features/module_budget_request.md). The floor is a fact of the
// module: the table Floor of its file, which the build writes. The size is
// a policy of the starter: budget_size, from the floor of the start.

// The floor of a module, the record of the table Floor of its file: what
// its process needs to reach its first state of work. A source does not
// write it: it states a Stated_Budget, its start objects and its children,
// and the tool writes the sum.
Floor :: module.Floor

// The parts of the floor of a module that its source states: what the tool
// cannot count. The source states it as one constant with a comment of the
// reasons of its parts (docs/MODULE_CONTRACT.md, "The floor of a module"):
//
// ```odin
// // Its loop and the tables of the rows that it shows.
// MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2536, window_width = WIDTH, window_height = HEIGHT}
// ```
//
// The tool reads the constant from the source, counts the pages of the
// module and of its imports, of their load, of each thread, of the two
// pictures of the window, of the start objects and of the floors of the
// children, and writes the table Floor. A part is an integer literal; a
// window part can also name a constant of the package whose value is one
// integer literal. A module with an entry and no constant has a floor too:
// the counted parts, one process and one thread.
Stated_Budget :: struct {
	// The pages that the counted floor does not hold yet: a table, a cache,
	// a budget of a child that the source does not name. It leaves module by
	// module, each checked by the peak of its budget at its first state of
	// work. Left out: none.
	working_memory_pages: u64,
	processes:             u64, // The process itself and each child at one time. Left out: 1.
	threads:              u64, // Each thread at one time, the first one and the threads of the children. Left out: 1.
	window_width:         u64, // The size of its window, in pixels, as it passes it to display.open. Left out: no window.
	window_height:        u64,
	// The least size of a resizable window, the names of the constants that
	// it passes to display.resizable_set. Stated and within the logical
	// screen at the largest scale: the tool cuts the window pages to the
	// screen (src/md/features/desktop_to_browser.md, "The budgets"). Left
	// out: no cut.
	window_least_width:   u64,
	window_least_height:  u64,
	// Pictures of the size of the screen in force that the process holds (a
	// copy of the screen, a frame): the starter adds their pages for the
	// screen of the machine (module.floor_of_screen). Left out: none.
	screen_pictures:      u64,
	// The pages of the rings of the wirings that the process asks for: the
	// root service carves its wiring budget to that measure, and the tool
	// adds them to its pages. Left out: half of its pages.
	wiring_pages:         u64,
}

// One memory object that a module or a package makes before the first
// state of work of its process, by its pages. A source lists them as a
// constant array, each element the name of a constant of the package whose
// value is one integer literal, the constant that the code passes to
// memory_create:
//
// ```odin
// // The two rings of its loop and the page that it lends.
// MODULE_START_OBJECTS :: [?]system.Start_Object{RING_PAGES, RING_PAGES, LENT_PAGES}
// // In a package: what it makes for each process that imports it.
// PACKAGE_START_OBJECTS :: [?]system.Start_Object{TEXT_MEMORY_PAGES}
// ```
//
// The tool prices each object as the kernel charges it: its pages, its
// frame list (op.memory_cost) and the tables of its mapping
// (op.mapping_table_pages_most). A list has no bound: only the type of its
// elements is fixed, so the compiler checks each name.
Start_Object :: distinct u64

// One part of a budget that slots or pages bound.
Budget_Part :: enum u8 {
	Pages    = 0,
	Processes = 1,
	Threads  = 2,
}

// The name of each part in a line of the log.
@(rodata)
budget_part_names := [Budget_Part]string {
	.Pages    = "pages",
	.Processes = "processes",
	.Threads  = "threads",
}

// budget_part gives one part of an amount.
budget_part :: proc "contextless" (amounts: Budget_Amounts, part: Budget_Part) -> u64 {
	switch part {
	case .Pages:
		return amounts.pages
	case .Processes:
		return amounts.processes
	case .Threads:
		return amounts.threads
	}
	return 0
}

// budget_first_short_part gives the first part of a budget that a holder
// cannot pay: its part is below the part that the budget needs. short is
// false when the holder can pay each part.
budget_first_short_part :: proc "contextless" (needed, holds: Budget_Amounts) -> (part: Budget_Part, short: bool) {
	for candidate in Budget_Part {
		if budget_part(holds, candidate) < budget_part(needed, candidate) {
			return candidate, true
		}
	}
	return .Pages, false
}

// wiring_pages_of_floor gives the pages that the root service carves as the
// wiring budget of an asker from its floor: the wiring pages that it states,
// never more than its pages, or half of its pages when it states none. A
// stated amount, whatever the asker spent before its first wiring
// (src/md/features/module_outputs.md, "The bounds of the wirings").
wiring_pages_of_floor :: proc "contextless" (floor: Floor) -> u64 {
	if floor.wiring_pages != 0 {
		return min(floor.wiring_pages, floor.pages)
	}
	return floor.pages / 2
}

// floor_usable says if a floor that a file gives can start a process: a
// page, and one process slot and one thread at least, the process itself
// and its first thread. Another floor is a damaged file, which a starter
// refuses as a file with no floor.
floor_usable :: proc "contextless" (floor: Floor) -> bool {
	return floor.pages != 0 && floor.processes != 0 && floor.threads != 0
}

// budget_size gives the pages of the budget of a process from the floor of
// its start, with no row of the plan: floor_pages times growth_factor,
// rounded up to a whole count of op.MEMORY_LIST_ENTRIES pages, at most
// largest_pages (the share of the machine), and never below the floor. The
// rounding is a fact of the frame list: an arena pays one list page for
// each 512 pages, so a size of another count leaves a last step that never
// fits. A floor above largest_pages is the size: the floor is what the
// process needs, and the share bounds a growth only. A product past 64 bits
// stops at the largest. A factor of 0 passed no border
// (module.growth_factor_of_word), and gives the floor.
//
// Example: a floor of 1000 pages with the factor 2 gives 2048; a floor of
// 40 000 with a largest of 50 000 gives 50 000.
budget_size :: proc "contextless" (floor_pages: u64, largest_pages: u64, growth_factor: u64) -> u64 {
	grown, overflowed := intrinsics.overflow_mul(floor_pages, max(growth_factor, 1))
	if overflowed {
		grown = max(u64)
	}
	rounded := grown
	if remainder := grown % op.MEMORY_LIST_ENTRIES; remainder != 0 {
		step := op.MEMORY_LIST_ENTRIES - remainder
		rounded = grown > max(u64) - step ? max(u64) : grown + step
	}
	return max(min(rounded, largest_pages), floor_pages)
}

// One process of a start list, for the division of the pages of its
// starter: the floor of its start and its size with no division
// (budget_size). start_list_sizes writes the size that it gets.
Start_Size :: struct {
	floor: u64,
	size:  u64, // Not below floor.
}

// start_list_sizes divides the pages of a starter among the processes of
// its start list, before the first of them starts, so that the start order
// decides nothing (src/md/features/module_budget_request.md, "The sum
// first"). The floors come first: fits is false, and no size changes, when
// their sum passes pages. Of the rest, kept pages stay with the starter for
// itself and for the starts after the list. What is left after them goes to
// the growth of each process, its size less its floor: each gets its whole
// growth when the sum fits, else the same part of its growth as each other,
// its size rounded down to a whole count of op.MEMORY_LIST_ENTRIES pages and
// never below its floor. The sum of the sizes then never passes the larger
// of pages less kept and the sum of the floors.
//
// Example: floors of 1000 and 3000 and sizes of 2048 and 6144 have a growth
// of 1048 and 3144. With 8192 pages and none kept, each keeps its size. With
// 6000 pages, 2000 pages go to a growth of 4192: the sizes become 1000 +
// 477 = 1477, rounded down to 1024, and 3000 + 1500 = 4500, rounded down
// to 4096.
start_list_sizes :: proc "contextless" (list: []Start_Size, pages: u64, kept: u64) -> (fits: bool) {
	floors, growth: u128
	for item in list {
		floors += u128(item.floor)
		growth += u128(item.size - min(item.size, item.floor))
	}
	if floors > u128(pages) {
		return false
	}
	spare := u128(pages) - floors
	for_growth := spare > u128(kept) ? spare - u128(kept) : 0
	if growth <= for_growth {
		return true
	}
	for &item in list {
		own := u128(item.size - min(item.size, item.floor))
		size := item.floor + u64(own * for_growth / growth)
		size -= size % op.MEMORY_LIST_ENTRIES
		item.size = max(size, item.floor)
	}
	return true
}
