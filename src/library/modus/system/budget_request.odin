package system

import module "modus:contract/module"

// The budget that a module asks for, the record of the table Budget of its
// file. A starter reads it and decides (budget_decide). A source does not
// write it: it states a Stated_Budget, and the tool writes the sum.
Budget_Request :: module.Budget_Request

// The parts of the budget of a module that its source states: what the tool
// cannot count. The source states it as one constant with a comment of the
// reasons of its working memory (docs/MODULE_CONTRACT.md, "The budget that
// a module asks for"):
//
// ```odin
// // The tables of the rows that it shows.
// MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2536, window_width = WIDTH, window_height = HEIGHT}
// ```
//
// The tool reads the constant from the source, counts the pages of the
// module and of its imports, of each thread and of the two pictures of the
// window, and writes the table Budget: its pages are the working memory and
// the counted pages; its processes and its threads are the parts of this
// record. A part is an integer literal; a window part can also name a
// constant of the package whose value is one integer literal.
Stated_Budget :: struct {
	working_memory_pages: u64, // What the process chooses: its tables, its caches, the budgets of its children. Left out: none.
	processes:             u64, // The process itself and each child at one time. Left out: the least.
	threads:              u64, // Each thread at one time, the first one and the threads of the children. Left out: the least.
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
	// screen of the machine (module.budget_request_of_screen). Left out: none.
	screen_pictures:      u64,
}

// One part of a budget request.
Budget_Part :: enum u8 {
	Pages    = 0,
	Processes = 1,
	Threads  = 2,
}
// The parts that a starter limited, or that are short.
Budget_Parts :: bit_set[Budget_Part;u8]

// The name of each part in a line of the log.
@(rodata)
budget_part_names := [Budget_Part]string {
	.Pages    = "pages",
	.Processes = "processes",
	.Threads  = "threads",
}

// budget_part gives one part of a request.
budget_part :: proc "contextless" (request: Budget_Request, part: Budget_Part) -> u64 {
	switch part {
	case .Pages:
		return request.pages
	case .Processes:
		return request.processes
	case .Threads:
		return request.threads
	}
	return 0
}

// budget_decide is the rule of a starter: what it gives for a request. For
// each part, a request of 0 takes the part of the least budget; the starter
// accepts a part that is not above its largest budget, and gives the largest
// budget of a part that is above it. limited names each part that the
// starter gave less than the module asked for: the starter writes it on the
// log. A starter widens a request with a larger `largest` for one process.
//
// Example: the request {pages = 50000} with the least {2048, 1, 1} and the
// largest {16384, 8, 32} gives {16384, 1, 1}, and limited is {.Pages}.
budget_decide :: proc "contextless" (request, least, largest: Budget_Request) -> (granted: Budget_Request, limited: Budget_Parts) {
	decide :: proc "contextless" (asked, least, largest: u64, part: Budget_Part, limited: ^Budget_Parts) -> u64 {
		value := asked == 0 ? least : asked
		if value > largest {
			limited^ += {part}
			return largest
		}
		return value
	}
	granted.pages = decide(request.pages, least.pages, largest.pages, .Pages, &limited)
	granted.processes = decide(request.processes, least.processes, largest.processes, .Processes, &limited)
	granted.threads = decide(request.threads, least.threads, largest.threads, .Threads, &limited)
	return granted, limited
}

// budget_first_short_part gives the first part of a budget that a holder
// cannot pay: its part is below the part that the budget needs. short is
// false when the holder can pay each part.
budget_first_short_part :: proc "contextless" (needed, holds: Budget_Request) -> (part: Budget_Part, short: bool) {
	for candidate in Budget_Part {
		if budget_part(holds, candidate) < budget_part(needed, candidate) {
			return candidate, true
		}
	}
	return .Pages, false
}
