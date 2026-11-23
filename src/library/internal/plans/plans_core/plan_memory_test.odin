#+build !freestanding
package plans_core

import "base:runtime"
import pr "modus:contract/plans_recipes"

// The memory of the core in the tests: the heap, with a count of the
// blocks taken and given, and a bound of the bytes that a test lowers to
// play a budget that pays no more.
Test_Memory :: struct {
	blocks_out: int,
	bytes_left: int,
}

test_memory_port :: proc(memory: ^Test_Memory) -> Memory_Port {
	memory.bytes_left = max(int)
	return {user = memory, take = test_memory_take, give = test_memory_give}
}

@(private = "file")
test_memory_take :: proc "contextless" (user: rawptr, bytes: int) -> []u8 {
	context = runtime.default_context()
	memory := (^Test_Memory)(user)
	if bytes > memory.bytes_left {
		return nil
	}
	memory.bytes_left -= bytes
	memory.blocks_out += 1
	return make([]u8, bytes)
}

@(private = "file")
test_memory_give :: proc "contextless" (user: rawptr, block: []u8) {
	context = runtime.default_context()
	memory := (^Test_Memory)(user)
	if memory.bytes_left <= max(int) - len(block) {
		memory.bytes_left += len(block)
	}
	memory.blocks_out -= 1
	delete(block)
}

TEST_PLAN_CAPACITY :: 64

test_plan :: proc(principal: u64, count: u32, capacity := TEST_PLAN_CAPACITY) -> pr.Plan_Spec {
	bytes, _ := pr.plan_bytes_for(max(int(count), capacity))
	plan := pr.plan_of_memory(principal, make([]u8, bytes, context.temp_allocator))
	plan.entry_count = count
	return plan
}

test_plan_copy :: proc(plan: ^pr.Plan_Spec) -> pr.Plan_Spec {
	copied := test_plan(plan.principal, 0, max(len(plan.entries), 1))
	pr.plan_copy(&copied, plan)
	return copied
}
