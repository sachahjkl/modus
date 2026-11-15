package system

import module "modus:contract/module"

// The budget that a module asks for, the record of the table Budget of its
// file. The source of a module states it as one constant with a comment of
// its reasons (docs/MODULE_CONTRACT.md, "The budget that a module asks for"):
//
// ```odin
// // Its loop, and the thread that makes the lists of the palette.
// MODULE_BUDGET :: system.Budget_Request{pages = 4096, programs = 1, threads = 2}
// ```
//
// The tool reads the constant from the source and writes the table: the
// numbers are integer literals.
Budget_Request :: module.Budget_Request

// One part of a budget request.
Budget_Part :: enum u8 {
	Pages    = 0,
	Programs = 1,
	Threads  = 2,
}
// The parts that a starter limited, or that are short.
Budget_Parts :: bit_set[Budget_Part;u8]

// The name of each part in a line of the log.
@(rodata)
budget_part_names := [Budget_Part]string {
	.Pages    = "pages",
	.Programs = "programs",
	.Threads  = "threads",
}

// budget_part gives one part of a request.
budget_part :: proc "contextless" (request: Budget_Request, part: Budget_Part) -> u64 {
	switch part {
	case .Pages:
		return request.pages
	case .Programs:
		return request.programs
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
// log. A starter widens a request with a larger `largest` for one program.
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
	granted.programs = decide(request.programs, least.programs, largest.programs, .Programs, &limited)
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
