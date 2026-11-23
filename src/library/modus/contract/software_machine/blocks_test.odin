#+build !freestanding
package software_machine

import "core:slice"
import "core:testing"

// The places of the machine of the tests of the decoded blocks. The code
// pages follow each other from BLOCKS_CODE_ADDRESS; the same frames are
// writable, and not executable, from BLOCKS_ALIAS_ADDRESS, as two mappings
// of one frame in a process.
BLOCKS_CODE_ADDRESS :: u64(0x40_0000)
BLOCKS_ALIAS_ADDRESS :: u64(0x50_0000)
BLOCKS_DATA_ADDRESS :: u64(0x60_0000)
BLOCKS_UNMAPPED_ADDRESS :: u64(0x61_0000)
BLOCKS_STACK_TOP :: u64(0x70_1000)
BLOCKS_CODE_PAGE_CAPACITY :: 17

// Two machines with the same memory: one runs with a cache of decoded
// blocks, the other without. Each run of both must leave the same state
// and the same memory, page tables included.
Blocks_Twin :: struct {
	machine:       Test_Machine,
	memory_without: []u8,
	code_frames:   [BLOCKS_CODE_PAGE_CAPACITY]u64,
	data_frame:    u64,
	with:          Processor_State,
	without:       Processor_State,
	cache:         ^Block_Cache,
}

blocks_twin_create :: proc(code_pages: int) -> ^Blocks_Twin {
	twin := new(Blocks_Twin)
	twin.machine = test_machine_create(1024 * 1024)
	m := &twin.machine
	for page in 0 ..< code_pages {
		frame := test_alloc_frame(m)
		twin.code_frames[page] = frame
		test_map_4k_page(m, BLOCKS_CODE_ADDRESS + u64(page) * PAGE_SIZE, frame, PAGE_PRESENT | PAGE_USER)
		test_map_4k_page(m, BLOCKS_ALIAS_ADDRESS + u64(page) * PAGE_SIZE, frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	}
	twin.data_frame = test_alloc_frame(m)
	test_map_4k_page(m, BLOCKS_DATA_ADDRESS, twin.data_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	test_map_4k_page(m, BLOCKS_STACK_TOP - PAGE_SIZE, test_alloc_frame(m), PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	twin.cache = new(Block_Cache)
	return twin
}

blocks_twin_destroy :: proc(twin: ^Blocks_Twin) {
	delete(twin.memory_without)
	test_machine_destroy(&twin.machine)
	free(twin.cache)
	free(twin)
}

// blocks_twin_write writes bytes at a physical address of both memories,
// as the kernel or another processor writes.
blocks_twin_write :: proc(twin: ^Blocks_Twin, physical_address: u64, bytes: []u8) {
	copy(twin.machine.ram[int(physical_address):], bytes)
	if twin.memory_without != nil {
		copy(twin.memory_without[int(physical_address):], bytes)
	}
}

// blocks_twin_start sets both processors at a place, with the same
// registers, and keeps the counts of the cache. The first start copies the
// memory of the machine for the processor without a cache.
blocks_twin_start :: proc(twin: ^Blocks_Twin, rip: u64, registers: [16]u64 = {}) {
	if twin.memory_without == nil {
		twin.memory_without = slice.clone(twin.machine.ram)
	}
	processor_init(&twin.with, twin.machine.cr3, rip, BLOCKS_STACK_TOP)
	stack := twin.with.registers[int(General_Register.Rsp)]
	twin.with.registers = registers
	twin.with.registers[int(General_Register.Rsp)] = stack
	twin.without = twin.with
	twin.with.blocks = twin.cache
}

// blocks_twin_run runs both processors for max_steps and expects the same
// outcome, state and memory.
blocks_twin_run :: proc(t: ^testing.T, twin: ^Blocks_Twin, max_steps: u64, location := #caller_location) -> Step_Outcome {
	outcome_with := processor_run(&twin.with, twin.machine.ram, max_steps)
	outcome_without := processor_run(&twin.without, twin.memory_without, max_steps)
	testing.expect_value(t, outcome_with, outcome_without, loc = location)
	a, b := &twin.with, &twin.without
	testing.expect_value(t, a.registers, b.registers, loc = location)
	testing.expect_value(t, a.rip, b.rip, loc = location)
	testing.expect_value(t, a.rflags, b.rflags, loc = location)
	testing.expect_value(t, a.xmm, b.xmm, loc = location)
	testing.expect_value(t, a.mxcsr, b.mxcsr, loc = location)
	testing.expect_value(t, a.outcome, b.outcome, loc = location)
	testing.expect_value(t, a.fault_address, b.fault_address, loc = location)
	testing.expect_value(t, a.fault_error_code, b.fault_error_code, loc = location)
	testing.expect_value(t, a.steps_executed, b.steps_executed, loc = location)
	testing.expect_value(t, a.syscall_return_rip, b.syscall_return_rip, loc = location)
	testing.expect_value(t, a.syscall_saved_rflags, b.syscall_saved_rflags, loc = location)
	testing.expect(t, slice.equal(twin.machine.ram, twin.memory_without), "the memories differ after the run", loc = location)
	return outcome_with
}

// The loop of the tests: the sum of 100 down to 1 in eax, then a system
// call. The loop body is at offset 7.
BLOCKS_SUM_LOOP := [?]u8 {
	0x31, 0xC0, // xor eax, eax
	0xB9, 0x64, 0x00, 0x00, 0x00, // mov ecx, 100
	0x01, 0xC8, // add eax, ecx
	0xFF, 0xC9, // dec ecx
	0x75, 0xFA, // jnz -6
	0x0F, 0x05, // syscall
}

// A place with no block records one; the next entry finds it and runs it
// from its decoded form, with the result of the steps one by one.
@(test)
blocks_a_recorded_block_is_found_and_runs_as_the_steps :: proc(t: ^testing.T) {
	twin := blocks_twin_create(1)
	defer blocks_twin_destroy(twin)
	blocks_twin_write(twin, twin.code_frames[0], BLOCKS_SUM_LOOP[:])
	testing.expect(t, block_cache_find(twin.cache, twin.code_frames[0]) == nil)
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS)
	testing.expect_value(t, blocks_twin_run(t, twin, 1000), Step_Outcome.Syscall)
	testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], u64(5050))
	testing.expect_value(t, twin.with.steps_executed, u64(303))
	// The block at the start ends at the taken branch; the loop body is a
	// block of its own, entered at each turn after its record.
	first := block_cache_find(twin.cache, twin.code_frames[0])
	testing.expect(t, first != nil)
	if first != nil {
		testing.expect_value(t, first.instruction_count, u8(5))
		testing.expect_value(t, first.byte_count, u8(13))
	}
	body := block_cache_find(twin.cache, twin.code_frames[0] + 7)
	testing.expect(t, body != nil)
	if body != nil {
		testing.expect_value(t, body.instruction_count, u8(3))
	}
	testing.expect_value(t, twin.cache.counts.records, u64(3))
	testing.expect_value(t, twin.cache.counts.entries, u64(98))
	testing.expect_value(t, twin.cache.counts.changed, u64(0))
	// A second run finds each block and records none.
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS)
	testing.expect_value(t, blocks_twin_run(t, twin, 1000), Step_Outcome.Syscall)
	testing.expect_value(t, twin.cache.counts.records, u64(3))
	testing.expect_value(t, twin.cache.counts.entries, u64(98 + 101))
}

// A write into a page of decoded code, between two runs (the kernel, a
// device model or another processor), changes the next run: the entry
// compares the bytes and records the block again. A write into another
// page changes no block.
@(test)
blocks_a_write_into_a_page_of_decoded_code_is_seen_at_the_next_entry :: proc(t: ^testing.T) {
	twin := blocks_twin_create(1)
	defer blocks_twin_destroy(twin)
	blocks_twin_write(twin, twin.code_frames[0], BLOCKS_SUM_LOOP[:])
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS)
	blocks_twin_run(t, twin, 1000)
	records := twin.cache.counts.records

	// Another page: no block changes.
	blocks_twin_write(twin, twin.data_frame, {1, 2, 3, 4})
	blocks_twin_write(twin, twin.code_frames[0] + 0x800, {0xCC})
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS)
	blocks_twin_run(t, twin, 1000)
	testing.expect_value(t, twin.cache.counts.changed, u64(0))
	testing.expect_value(t, twin.cache.counts.records, records)

	// The count of the loop: mov ecx, 50.
	blocks_twin_write(twin, twin.code_frames[0] + 3, {50})
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS)
	testing.expect_value(t, blocks_twin_run(t, twin, 1000), Step_Outcome.Syscall)
	testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], u64(1275))
	testing.expect_value(t, twin.cache.counts.changed, u64(1))

	// The loop body: add becomes sub, inside a block that ran before.
	blocks_twin_write(twin, twin.code_frames[0] + 7, {0x29})
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS)
	testing.expect_value(t, blocks_twin_run(t, twin, 1000), Step_Outcome.Syscall)
	testing.expect_value(t, u32(twin.with.registers[int(General_Register.Rax)]), ~u32(1274))
	testing.expect_value(t, twin.cache.counts.changed, u64(3))
}

// An instruction of a block that writes the frame of the block, through a
// writable mapping of the same frame, ends the block: the next instruction
// runs the bytes that it wrote, as on x86-64.
@(test)
blocks_a_write_of_the_running_block_into_its_own_frame_ends_the_block :: proc(t: ^testing.T) {
	twin := blocks_twin_create(1)
	defer blocks_twin_destroy(twin)
	code := [?]u8 {
		0x88, 0x03, // mov [rbx], al
		0xB8, 0x01, 0x00, 0x00, 0x00, // mov eax, 1
		0x0F, 0x05, // syscall
	}
	blocks_twin_write(twin, twin.code_frames[0], code[:])
	// The first run writes the data page: the block holds the three.
	registers: [16]u64
	registers[int(General_Register.Rax)] = 0x2A
	registers[int(General_Register.Rbx)] = BLOCKS_DATA_ADDRESS
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS, registers)
	blocks_twin_run(t, twin, 100)
	block := block_cache_find(twin.cache, twin.code_frames[0])
	testing.expect(t, block != nil && block.instruction_count == 3)
	testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], u64(1))

	// The second run writes the immediate of the next instruction of the
	// same block, through the alias of its frame.
	registers[int(General_Register.Rbx)] = BLOCKS_ALIAS_ADDRESS + 3
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS, registers)
	testing.expect_value(t, blocks_twin_run(t, twin, 100), Step_Outcome.Syscall)
	testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], u64(0x2A))
	testing.expect_value(t, twin.cache.counts.written, u64(1))

	// A record ends at such a write too: the block at the start holds one
	// instruction, and the bytes after it run as they are now.
	twin.cache^ = {}
	blocks_twin_write(twin, twin.code_frames[0] + 3, {0x01})
	registers[int(General_Register.Rax)] = 0x33
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS, registers)
	testing.expect_value(t, blocks_twin_run(t, twin, 100), Step_Outcome.Syscall)
	testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], u64(0x33))
	first := block_cache_find(twin.cache, twin.code_frames[0])
	testing.expect(t, first != nil && first.instruction_count == 1)
}

// Two blocks whose keys have one slot: the second replaces the first, and
// the first is recorded again at its next entry. The cache holds at most
// BLOCK_CACHE_CAPACITY blocks, whatever the count of the places that run.
@(test)
blocks_a_block_replaces_the_block_of_its_slot_at_the_bound :: proc(t: ^testing.T) {
	twin := blocks_twin_create(16 + 1)
	defer blocks_twin_destroy(twin)
	frame := twin.code_frames[0]
	first_offset, second_offset := u64(0), u64(0)
	search: for a in u64(0) ..< 64 {
		for b in a + 2 ..< PAGE_SIZE - 2 {
			if block_slot(frame + a * 2) == block_slot(frame + b) && b % 2 == 0 {
				first_offset, second_offset = a * 2, b
				break search
			}
		}
	}
	testing.expect(t, second_offset != 0, "two places of one page with one slot")
	blocks_twin_write(twin, frame + first_offset, {0xFF, 0xC0, 0x0F, 0x05}) // inc eax; syscall
	blocks_twin_write(twin, frame + second_offset, {0xFF, 0xC8, 0x0F, 0x05}) // dec eax; syscall
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS + first_offset)
	blocks_twin_run(t, twin, 10)
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS + second_offset)
	blocks_twin_run(t, twin, 10)
	testing.expect_value(t, twin.cache.counts.replaced, u64(1))
	testing.expect(t, block_cache_find(twin.cache, frame + first_offset) == nil)
	testing.expect(t, block_cache_find(twin.cache, frame + second_offset) != nil)
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS + first_offset)
	blocks_twin_run(t, twin, 10)
	testing.expect_value(t, twin.cache.counts.replaced, u64(2))
	testing.expect_value(t, twin.cache.counts.records, u64(3))

	// Sixteen pages of inc eax are 2048 blocks of 16 instructions, twice
	// the capacity, then a system call: two runs give the steps one by
	// one, and the cache never holds more blocks than its capacity.
	twin.cache^ = {}
	increments := make([]u8, int(PAGE_SIZE))
	defer delete(increments)
	for index := 0; index < len(increments); index += 2 {
		increments[index], increments[index + 1] = 0xFF, 0xC0
	}
	for page in 0 ..< 16 {
		blocks_twin_write(twin, twin.code_frames[page], increments)
	}
	blocks_twin_write(twin, twin.code_frames[16], {0x0F, 0x05})
	for _ in 0 ..< 2 {
		blocks_twin_start(twin, BLOCKS_CODE_ADDRESS)
		testing.expect_value(t, blocks_twin_run(t, twin, 40_000), Step_Outcome.Syscall)
		testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], u64(16 * 2048))
	}
	valid := 0
	for block in twin.cache.blocks {
		if block.valid {
			valid += 1
			testing.expect(t, block.instruction_count <= BLOCK_INSTRUCTION_CAPACITY && int(block.byte_count) <= BLOCK_BYTE_CAPACITY)
		}
	}
	testing.expect(t, valid <= BLOCK_CACHE_CAPACITY)
	testing.expect(t, twin.cache.counts.replaced > 0, "2048 blocks replace blocks in a cache of 1024")
}

// An instruction that crosses the end of a page ends the block before it,
// and runs on the path of the bytes, which translates the next page at
// each run: a write into the next page changes it.
@(test)
blocks_an_instruction_across_two_pages_stays_out_of_the_block :: proc(t: ^testing.T) {
	twin := blocks_twin_create(2)
	defer blocks_twin_destroy(twin)
	blocks_twin_write(twin, twin.code_frames[0] + PAGE_SIZE - 6, {0xFF, 0xC3, 0xFF, 0xC3, 0xB8, 0x07}) // inc ebx; inc ebx; mov eax, ...
	blocks_twin_write(twin, twin.code_frames[1], {0x00, 0x00, 0x00, 0x0F, 0x05}) // ... 7; syscall
	for _ in 0 ..< 2 {
		blocks_twin_start(twin, BLOCKS_CODE_ADDRESS + PAGE_SIZE - 6)
		testing.expect_value(t, blocks_twin_run(t, twin, 100), Step_Outcome.Syscall)
		testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], u64(7))
	}
	block := block_cache_find(twin.cache, twin.code_frames[0] + PAGE_SIZE - 6)
	testing.expect(t, block != nil && block.instruction_count == 2 && block.byte_count == 4)
	testing.expect(t, block_cache_find(twin.cache, twin.code_frames[0] + PAGE_SIZE - 2) == nil)
	blocks_twin_write(twin, twin.code_frames[1], {0x01})
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS + PAGE_SIZE - 6)
	blocks_twin_run(t, twin, 100)
	testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], u64(0x0107))
	testing.expect_value(t, twin.cache.counts.changed, u64(0))
}

// Each budget from 1 step past the end of the loop gives the state of the
// steps one by one, with a cache that already holds the blocks: the end of
// a slice in the middle of a block is exact.
@(test)
blocks_each_budget_ends_a_block_at_the_exact_step :: proc(t: ^testing.T) {
	twin := blocks_twin_create(1)
	defer blocks_twin_destroy(twin)
	blocks_twin_write(twin, twin.code_frames[0], BLOCKS_SUM_LOOP[:])
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS)
	blocks_twin_run(t, twin, 1000)
	for budget in u64(1) ..= 305 {
		blocks_twin_start(twin, BLOCKS_CODE_ADDRESS)
		outcome := blocks_twin_run(t, twin, budget)
		if budget < 303 {
			testing.expect_value(t, outcome, Step_Outcome.Step_Budget_Exhausted)
			testing.expect_value(t, twin.with.steps_executed, budget)
		} else {
			testing.expect_value(t, outcome, Step_Outcome.Syscall)
		}
	}
	// A run that stops in a block and goes on in the next call.
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS)
	for _ in 0 ..< 100 {
		if blocks_twin_run(t, twin, 4) != .Step_Budget_Exhausted {
			break
		}
	}
	testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], u64(5050))
}

// A fault in the middle of a block leaves the state of before its
// instruction, as the steps one by one: the instructions before it in the
// block ran, and the fault names the place of its instruction.
@(test)
blocks_a_fault_in_a_block_is_precise :: proc(t: ^testing.T) {
	twin := blocks_twin_create(1)
	defer blocks_twin_destroy(twin)
	code := [?]u8 {
		0xFF, 0xC0, // inc eax
		0x8B, 0x03, // mov eax, [rbx]
		0x48, 0x89, 0x01, // mov [rcx], rax
		0x0F, 0x05, // syscall
	}
	blocks_twin_write(twin, twin.code_frames[0], code[:])
	registers: [16]u64
	registers[int(General_Register.Rbx)] = BLOCKS_DATA_ADDRESS
	registers[int(General_Register.Rcx)] = BLOCKS_DATA_ADDRESS + 8
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS, registers)
	testing.expect_value(t, blocks_twin_run(t, twin, 100), Step_Outcome.Syscall)
	block := block_cache_find(twin.cache, twin.code_frames[0])
	testing.expect(t, block != nil && block.instruction_count == 4)

	registers[int(General_Register.Rbx)] = BLOCKS_UNMAPPED_ADDRESS
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS, registers)
	testing.expect_value(t, blocks_twin_run(t, twin, 100), Step_Outcome.Page_Fault)
	testing.expect_value(t, twin.with.rip, BLOCKS_CODE_ADDRESS + 2)
	testing.expect_value(t, twin.with.fault_address, BLOCKS_UNMAPPED_ADDRESS)
	testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], u64(1))

	// A write that the page refuses: the code page is not writable.
	registers[int(General_Register.Rbx)] = BLOCKS_DATA_ADDRESS
	registers[int(General_Register.Rcx)] = BLOCKS_CODE_ADDRESS
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS, registers)
	testing.expect_value(t, blocks_twin_run(t, twin, 100), Step_Outcome.Page_Fault)
	testing.expect_value(t, twin.with.rip, BLOCKS_CODE_ADDRESS + 4)

	// A place that no page maps for an execute faults at the entry, as the
	// fetch of its first byte does, and records no block.
	records := twin.cache.counts.records
	blocks_twin_start(twin, BLOCKS_DATA_ADDRESS)
	testing.expect_value(t, blocks_twin_run(t, twin, 100), Step_Outcome.Page_Fault)
	testing.expect_value(t, twin.cache.counts.records, records)
}
