// The memory of the plans of the service (plans_core.Memory_Port): a plan
// has any count of entries, so each plan, each difference and each list
// of the trusted display has a block of its size, which the budget of the
// service pays.
package plans_service

import "internal:plans/plans_core"
import "modus:system"

// The blocks have the sizes of the powers of two from one page: a block
// that comes back goes on the list of its size, and the next take of that
// size takes it again. A plan that grows and shrinks keeps at most the
// double of its bytes; the arena reserves the pages of the budget of the
// service, and commits a page at its first block.
PLAN_BLOCK_LEAST :: system.PAGE_SIZE
PLAN_BLOCK_SIZES :: 40 // From one page to 2^51 bytes: past any budget.

Plan_Blocks :: struct {
	arena: system.Arena,
	free:  [PLAN_BLOCK_SIZES]rawptr, // The first free block of each size; each free block holds the next.
}

plan_blocks: Plan_Blocks

// plan_memory_port reserves the arena of the blocks, as large as the
// budget of the service at its start, and gives the port.
plan_memory_port :: proc "contextless" () -> (port: plans_core.Memory_Port, ok: bool) {
	amounts, budget_status := system.budget_read()
	if budget_status != .Ok {
		return {}, false
	}
	arena, arena_status := system.arena_create(system.arena_reservation_pages(amounts.pages))
	if arena_status != .Ok {
		return {}, false
	}
	plan_blocks = {arena = arena}
	return {user = &plan_blocks, take = plan_block_take, give = plan_block_give}, true
}

// plan_block_size gives the size of the block of bytes, and its list.
@(private = "file")
plan_block_size :: proc "contextless" (bytes: int) -> (size: int, list: int, ok: bool) {
	size = PLAN_BLOCK_LEAST
	for place in 0 ..< PLAN_BLOCK_SIZES {
		if bytes <= size {
			return size, place, true
		}
		size *= 2
	}
	return 0, 0, false
}

@(private = "file")
plan_block_take :: proc "contextless" (user: rawptr, bytes: int) -> []u8 {
	blocks := (^Plan_Blocks)(user)
	size, list, ok := plan_block_size(bytes)
	if !ok || bytes <= 0 {
		return nil
	}
	if block := blocks.free[list]; block != nil {
		blocks.free[list] = (^rawptr)(block)^
		return ([^]u8)(block)[:size]
	}
	address, status := system.arena_push(&blocks.arena, u64(size), PLAN_BLOCK_LEAST)
	if status != .Ok {
		return nil
	}
	return ([^]u8)(address)[:size]
}

@(private = "file")
plan_block_give :: proc "contextless" (user: rawptr, memory: []u8) {
	blocks := (^Plan_Blocks)(user)
	size, list, ok := plan_block_size(len(memory))
	// A block comes back whole, with the size that take gave.
	if !ok || size != len(memory) {
		return
	}
	(^rawptr)(raw_data(memory))^ = blocks.free[list]
	blocks.free[list] = raw_data(memory)
}
