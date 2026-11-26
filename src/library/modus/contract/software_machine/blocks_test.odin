#+build !freestanding
package software_machine

import "core:slice"
import "core:testing"
import "modus:contract/byte_order"

// The places of the machine of the tests of the decoded blocks. The code
// pages follow each other from BLOCKS_CODE_ADDRESS; the same frames are
// writable, and not executable, from BLOCKS_ALIAS_ADDRESS, as two mappings
// of one frame in a process.
BLOCKS_CODE_ADDRESS :: u64(0x40_0000)
BLOCKS_ALIAS_ADDRESS :: u64(0x50_0000)
BLOCKS_DATA_ADDRESS :: u64(0x60_0000)
BLOCKS_UNMAPPED_ADDRESS :: u64(0x61_0000)
BLOCKS_STACK_TOP :: u64(0x70_1000)
BLOCKS_CODE_PAGE_CAPACITY :: 80

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
	twin.machine = test_machine_create(2 * 1024 * 1024)
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
	// Enough 4 KiB pages of 2-byte `inc eax` instructions to exceed BLOCK_CACHE_CAPACITY blocks.
	BLOCKS_PER_PAGE :: int(PAGE_SIZE) / (2 * BLOCK_INSTRUCTION_CAPACITY)
	PAGES :: (BLOCK_CACHE_CAPACITY / BLOCKS_PER_PAGE) + 8
	twin := blocks_twin_create(PAGES + 1)
	defer blocks_twin_destroy(twin)
	first_page, second_page := 0, 0
	first_offset, second_offset := u64(0), u64(0)
	first_phys, second_phys := u64(0), u64(0)
	search: for a in u64(0) ..< 64 {
		p1 := twin.code_frames[0] + a * 2
		s1 := block_slot(p1)
		for page in 0 ..< min(PAGES, 8) {
			for b := u64(0); b < PAGE_SIZE - 4; b += 2 {
				p2 := twin.code_frames[page] + b
				if p2 == p1 {
					continue
				}
				if block_slot(p2) == s1 {
					first_page, first_offset, first_phys = 0, a * 2, p1
					second_page, second_offset, second_phys = page, b, p2
					break search
				}
			}
		}
	}
	testing.expect(t, second_phys != 0, "two places with one slot")
	blocks_twin_write(twin, first_phys, {0xFF, 0xC0, 0x0F, 0x05}) // inc eax; syscall
	blocks_twin_write(twin, second_phys, {0xFF, 0xC8, 0x0F, 0x05}) // dec eax; syscall
	first_va := BLOCKS_CODE_ADDRESS + u64(first_page) * PAGE_SIZE + first_offset
	second_va := BLOCKS_CODE_ADDRESS + u64(second_page) * PAGE_SIZE + second_offset
	blocks_twin_start(twin, first_va)
	blocks_twin_run(t, twin, 10)
	blocks_twin_start(twin, second_va)
	blocks_twin_run(t, twin, 10)
	testing.expect_value(t, twin.cache.counts.replaced, u64(1))
	testing.expect(t, block_cache_find(twin.cache, first_phys) == nil)
	testing.expect(t, block_cache_find(twin.cache, second_phys) != nil)
	blocks_twin_start(twin, first_va)
	blocks_twin_run(t, twin, 10)
	testing.expect_value(t, twin.cache.counts.replaced, u64(2))
	testing.expect_value(t, twin.cache.counts.records, u64(3))

	// PAGES pages of inc eax produce more blocks than BLOCK_CACHE_CAPACITY,
	// then a system call: two runs give the steps one by one, and the cache
	// never holds more blocks than its capacity.
	twin.cache^ = {}
	increments := make([]u8, int(PAGE_SIZE))
	defer delete(increments)
	for index := 0; index < len(increments); index += 2 {
		increments[index], increments[index + 1] = 0xFF, 0xC0
	}
	for page in 0 ..< PAGES {
		blocks_twin_write(twin, twin.code_frames[page], increments)
	}
	blocks_twin_write(twin, twin.code_frames[PAGES], {0x0F, 0x05})
	for _ in 0 ..< 2 {
		blocks_twin_start(twin, BLOCKS_CODE_ADDRESS)
		testing.expect_value(t, blocks_twin_run(t, twin, u64(PAGES * 2048 + 16)), Step_Outcome.Syscall)
		testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], u64(PAGES * 2048))
	}
	valid := 0
	for block in twin.cache.blocks {
		if block.valid {
			valid += 1
			testing.expect(t, block.instruction_count <= BLOCK_INSTRUCTION_CAPACITY && int(block.byte_count) <= BLOCK_BYTE_CAPACITY)
		}
	}
	testing.expect(t, valid <= BLOCK_CACHE_CAPACITY)
	testing.expect(t, twin.cache.counts.replaced > 0, "more than BLOCK_CACHE_CAPACITY blocks trigger replacements")
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

// blocks_leaf_entry_place gives the physical place of the entry of the last
// level that maps a virtual address through the tables of a root. The
// tables of the tests have no large page.
blocks_leaf_entry_place :: proc(ram: []u8, root: u64, virtual_address: u64) -> u64 {
	table := root
	for level := uint(3); level >= 1; level -= 1 {
		index := (virtual_address >> (12 + 9 * level)) & PAGE_TABLE_INDEX_MASK
		table = byte_order.read_u64_little_endian(ram, int(table + index * 8)) & PAGE_ADDRESS_MASK
	}
	return table + ((virtual_address >> 12) & PAGE_TABLE_INDEX_MASK) * 8
}

// blocks_twin_entry_write changes the entry of the last level of a virtual
// address in both memories, as the kernel changes a mapping.
blocks_twin_entry_write :: proc(twin: ^Blocks_Twin, root: u64, virtual_address: u64, set_bits: u64, clear_bits: u64) {
	place := blocks_leaf_entry_place(twin.machine.ram, root, virtual_address)
	entry := byte_order.read_u64_little_endian(twin.machine.ram, int(place))
	entry = (entry | set_bits) & ~clear_bits
	bytes: [8]u8
	byte_order.write_u64_little_endian(bytes[:], 0, entry)
	blocks_twin_write(twin, place, bytes[:])
}

// The code of the tests of a refused entry: inc eax; inc eax; syscall.
BLOCKS_TWO_INCREMENTS := [?]u8{0xFF, 0xC0, 0xFF, 0xC0, 0x0F, 0x05}

// blocks_entry_refused runs both processors at a place whose translation
// for an execute must fault, and checks the refusal: a page fault at the
// place with its error code, no step, no register, no entry of a block, no
// record, no byte of the memory, and one walk of the translation cache, as
// the steps one by one.
blocks_entry_refused :: proc(t: ^testing.T, twin: ^Blocks_Twin, error_code: u64, location := #caller_location) {
	place := twin.with.rip
	registers := twin.with.registers
	steps := twin.with.steps_executed
	counts := twin.cache.counts
	memory := slice.clone(twin.machine.ram)
	defer delete(memory)
	testing.expect_value(t, blocks_twin_run(t, twin, 100), Step_Outcome.Page_Fault, loc = location)
	testing.expect_value(t, twin.with.fault_error_code, error_code, loc = location)
	testing.expect_value(t, twin.with.fault_address, place, loc = location)
	testing.expect_value(t, twin.with.rip, place, loc = location)
	testing.expect_value(t, twin.with.registers, registers, loc = location)
	testing.expect_value(t, twin.with.steps_executed, steps, loc = location)
	testing.expect_value(t, twin.cache.counts, counts, loc = location)
	testing.expect(t, slice.equal(twin.machine.ram, memory), "a refused entry changed the memory", loc = location)
	testing.expect_value(t, twin.with.tlb.misses, twin.without.tlb.misses, loc = location)
}

// blocks_twin_recorded writes the code of the refused entries, runs it
// twice from the code place, and expects one block, entered once.
blocks_twin_recorded :: proc(t: ^testing.T, twin: ^Blocks_Twin, location := #caller_location) {
	blocks_twin_write(twin, twin.code_frames[0], BLOCKS_TWO_INCREMENTS[:])
	for _ in 0 ..< 2 {
		blocks_twin_start(twin, BLOCKS_CODE_ADDRESS)
		testing.expect_value(t, blocks_twin_run(t, twin, 100), Step_Outcome.Syscall, loc = location)
	}
	testing.expect(t, block_cache_find(twin.cache, twin.code_frames[0]) != nil, "the block is recorded", loc = location)
	testing.expect_value(t, twin.cache.counts.entries, u64(1), loc = location)
}

// blocks_twin_again sets both processors back at the code place, with
// their translation caches, and flushes the translation of that place.
blocks_twin_again :: proc(twin: ^Blocks_Twin) {
	twin.with.rip = BLOCKS_CODE_ADDRESS
	twin.without.rip = BLOCKS_CODE_ADDRESS
	processor_invlpg(&twin.with, BLOCKS_CODE_ADDRESS)
	processor_invlpg(&twin.without, BLOCKS_CODE_ADDRESS)
}

// A cached block is found by the physical address, so each entry must
// translate its place for an execute: a mapping of its frame that is not
// executable, not for the user or not present faults as the fetch of its
// first byte, and runs nothing of the block.
@(test)
blocks_an_entry_that_the_mapping_refuses_faults_and_runs_nothing :: proc(t: ^testing.T) {
	// The writable alias of the frame of the block is not executable.
	{
		twin := blocks_twin_create(1)
		defer blocks_twin_destroy(twin)
		blocks_twin_recorded(t, twin)
		blocks_twin_start(twin, BLOCKS_ALIAS_ADDRESS)
		blocks_entry_refused(t, twin, PAGE_FAULT_PRESENT | PAGE_FAULT_USER | PAGE_FAULT_INSTRUCTION)
	}
	// The mapping of the block becomes not executable, not for the user,
	// then not present, each with an invlpg of its place.
	cases := [?]struct {
		clear_bits: u64,
		set_bits:   u64,
		error_code: u64,
	} {
		{set_bits = PAGE_NO_EXECUTE, error_code = PAGE_FAULT_PRESENT | PAGE_FAULT_USER | PAGE_FAULT_INSTRUCTION},
		{clear_bits = PAGE_USER, error_code = PAGE_FAULT_PRESENT | PAGE_FAULT_USER | PAGE_FAULT_INSTRUCTION},
		{clear_bits = PAGE_PRESENT, error_code = PAGE_FAULT_USER | PAGE_FAULT_INSTRUCTION},
	}
	for refusal in cases {
		twin := blocks_twin_create(1)
		defer blocks_twin_destroy(twin)
		blocks_twin_recorded(t, twin)
		blocks_twin_entry_write(twin, twin.machine.cr3, BLOCKS_CODE_ADDRESS, refusal.set_bits, refusal.clear_bits)
		blocks_twin_again(twin)
		blocks_entry_refused(t, twin, refusal.error_code)
	}
	// A second root whose mapping of the frame of the block is not
	// executable: the block of the first root does not run through it.
	{
		twin := blocks_twin_create(1)
		defer blocks_twin_destroy(twin)
		first_root := twin.machine.cr3
		second_root := test_alloc_frame(&twin.machine)
		twin.machine.cr3 = second_root
		test_map_4k_page(&twin.machine, BLOCKS_CODE_ADDRESS, twin.code_frames[0], PAGE_PRESENT | PAGE_USER | PAGE_NO_EXECUTE)
		twin.machine.cr3 = first_root
		blocks_twin_recorded(t, twin)
		processor_set_cr3(&twin.with, second_root)
		processor_set_cr3(&twin.without, second_root)
		blocks_twin_again(twin)
		blocks_entry_refused(t, twin, PAGE_FAULT_PRESENT | PAGE_FAULT_USER | PAGE_FAULT_INSTRUCTION)
		// The first root runs the block again.
		processor_set_cr3(&twin.with, first_root)
		processor_set_cr3(&twin.without, first_root)
		blocks_twin_again(twin)
		testing.expect_value(t, blocks_twin_run(t, twin, 100), Step_Outcome.Syscall)
		testing.expect_value(t, twin.cache.counts.entries, u64(2))
	}
}

// A block whose counts pass the arrays of a block is not found: the compare
// and the run would read past them. The record at the next entry replaces
// it, with the result of the steps one by one.
@(test)
blocks_a_block_whose_counts_pass_its_arrays_is_not_found :: proc(t: ^testing.T) {
	twin := blocks_twin_create(1)
	defer blocks_twin_destroy(twin)
	blocks_twin_recorded(t, twin)
	block := block_cache_find(twin.cache, twin.code_frames[0])
	testing.expect(t, block != nil)
	if block == nil {
		return
	}
	cases := [?]struct {
		byte_count:        u8,
		instruction_count: u8,
		found:             bool,
	} {
		{byte_count = BLOCK_BYTE_CAPACITY + 1, instruction_count = 3, found = false},
		{byte_count = max(u8), instruction_count = 3, found = false},
		{byte_count = 6, instruction_count = BLOCK_INSTRUCTION_CAPACITY + 1, found = false},
		{byte_count = 6, instruction_count = max(u8), found = false},
		{byte_count = BLOCK_BYTE_CAPACITY, instruction_count = BLOCK_INSTRUCTION_CAPACITY, found = true},
	}
	saved := block^
	for damage in cases {
		block^ = saved
		block.byte_count = damage.byte_count
		block.instruction_count = damage.instruction_count
		testing.expect_value(t, block_cache_find(twin.cache, twin.code_frames[0]) != nil, damage.found)
	}
	block^ = saved
	block.byte_count = BLOCK_BYTE_CAPACITY + 1
	entries, records := twin.cache.counts.entries, twin.cache.counts.records
	blocks_twin_start(twin, BLOCKS_CODE_ADDRESS)
	testing.expect_value(t, blocks_twin_run(t, twin, 100), Step_Outcome.Syscall)
	testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], u64(2))
	testing.expect_value(t, twin.cache.counts.entries, entries)
	testing.expect_value(t, twin.cache.counts.records, records + 1)
	found := block_cache_find(twin.cache, twin.code_frames[0])
	testing.expect(t, found != nil && found.byte_count == 6 && found.instruction_count == 3)
}

// A cached rep stosb and rep movsb whose destination is the frame of their
// own block, cut by each budget: each run gives the state of the steps one
// by one, and the write into the frame ends the block.
@(test)
blocks_a_cached_repeated_string_form_into_its_own_frame_stops_at_each_budget :: proc(t: ^testing.T) {
	twin := blocks_twin_create(1)
	defer blocks_twin_destroy(twin)
	STORE_OFFSET :: 0x00
	MOVE_OFFSET :: 0x10
	blocks_twin_write(twin, twin.code_frames[0] + STORE_OFFSET, {0xF3, 0xAA, 0x0F, 0x05}) // rep stosb; syscall
	blocks_twin_write(twin, twin.code_frames[0] + MOVE_OFFSET, {0xF3, 0xA4, 0x0F, 0x05}) // rep movsb; syscall
	source := [?]u8{0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88}
	blocks_twin_write(twin, twin.code_frames[0] + 0x200, source[:])
	ITERATIONS :: 40
	for offset in ([?]u64{STORE_OFFSET, MOVE_OFFSET}) {
		registers: [16]u64
		registers[int(General_Register.Rax)] = 0x90
		registers[int(General_Register.Rcx)] = ITERATIONS
		registers[int(General_Register.Rsi)] = BLOCKS_ALIAS_ADDRESS + 0x200
		registers[int(General_Register.Rdi)] = BLOCKS_ALIAS_ADDRESS + 0x100
		// The first run records the block.
		blocks_twin_start(twin, BLOCKS_CODE_ADDRESS + offset, registers)
		testing.expect_value(t, blocks_twin_run(t, twin, 1000), Step_Outcome.Syscall)
		block := block_cache_find(twin.cache, twin.code_frames[0] + offset)
		testing.expect(t, block != nil && block.instruction_count == 1, "the write into its frame ends the block after the string form")
		entries := twin.cache.counts.entries
		for budget in u64(1) ..= ITERATIONS + 2 {
			blocks_twin_start(twin, BLOCKS_CODE_ADDRESS + offset, registers)
			outcome := blocks_twin_run(t, twin, budget)
			if budget <= ITERATIONS {
				testing.expect_value(t, outcome, Step_Outcome.Step_Budget_Exhausted)
				testing.expect_value(t, twin.with.registers[int(General_Register.Rcx)], ITERATIONS - budget)
				// The last iteration moves past the instruction.
				testing.expect_value(t, twin.with.rip, BLOCKS_CODE_ADDRESS + offset + (budget == ITERATIONS ? 2 : 0))
			} else {
				testing.expect_value(t, outcome, Step_Outcome.Syscall)
			}
		}
		testing.expect(t, twin.cache.counts.entries > entries, "the budgets enter the cached block")
	}
}

// add ax, 1 with redundant operand size prefixes: 15 bytes, the longest
// instruction.
BLOCKS_LONGEST_ADD := [15]u8{0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x05, 0x01, 0x00}
// add ax, 1 in 8 bytes, and in 4.
BLOCKS_EIGHT_BYTE_ADD := [8]u8{0x66, 0x66, 0x66, 0x66, 0x66, 0x05, 0x01, 0x00}
BLOCKS_FOUR_BYTE_ADD := [4]u8{0x66, 0x05, 0x01, 0x00}

// A block of instructions of 15 bytes stops at BLOCK_BYTE_CAPACITY bytes:
// exactly at the bound when the instructions fill it, and before an
// instruction that would pass it. The instruction past the bound starts
// the next block.
@(test)
blocks_a_block_stops_at_its_byte_capacity :: proc(t: ^testing.T) {
	twin := blocks_twin_create(1)
	defer blocks_twin_destroy(twin)
	// Eight instructions of 15 bytes and one of 8 are 128 bytes; then one
	// of 4 and a system call.
	EXACT_OFFSET :: u64(0)
	place := twin.code_frames[0] + EXACT_OFFSET
	// Sixteen 15-byte instructions (240) + 8-byte + 4-byte = 252 (BLOCK_BYTE_CAPACITY),
	// followed by one more 4-byte addition that starts the next block.
	for _ in 0 ..< 16 {
		blocks_twin_write(twin, place, BLOCKS_LONGEST_ADD[:])
		place += 15
	}
	blocks_twin_write(twin, place, BLOCKS_EIGHT_BYTE_ADD[:])
	place += 8
	blocks_twin_write(twin, place, BLOCKS_FOUR_BYTE_ADD[:])
	place += 4
	blocks_twin_write(twin, place, BLOCKS_FOUR_BYTE_ADD[:])
	place += 4
	blocks_twin_write(twin, place, {0x0F, 0x05})
	// Seventeen instructions of 15 bytes are 255 (> 252): the seventeenth starts
	// the next block at byte 240.
	PAST_OFFSET :: u64(0x200)
	place = twin.code_frames[0] + PAST_OFFSET
	for _ in 0 ..< 17 {
		blocks_twin_write(twin, place, BLOCKS_LONGEST_ADD[:])
		place += 15
	}
	blocks_twin_write(twin, place, {0x0F, 0x05})

	for test_case in ([?]struct {
			offset:            u64,
			additions:         u64,
			byte_count:        u8,
			instruction_count: u8,
			next_offset:       u64,
		} {
			{EXACT_OFFSET, 19, BLOCK_BYTE_CAPACITY, 18, BLOCK_BYTE_CAPACITY},
			{PAST_OFFSET, 17, 240, 16, 240},
		}) {
		for _ in 0 ..< 2 {
			blocks_twin_start(twin, BLOCKS_CODE_ADDRESS + test_case.offset)
			testing.expect_value(t, blocks_twin_run(t, twin, 100), Step_Outcome.Syscall)
			testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], test_case.additions)
		}
		block := block_cache_find(twin.cache, twin.code_frames[0] + test_case.offset)
		testing.expect(t, block != nil)
		if block != nil {
			testing.expect_value(t, block.byte_count, test_case.byte_count)
			testing.expect_value(t, block.instruction_count, test_case.instruction_count)
		}
		testing.expect(t, block_cache_find(twin.cache, twin.code_frames[0] + test_case.offset + test_case.next_offset) != nil, "the instruction past the bound starts a block")
		for budget in u64(1) ..= test_case.additions + 1 {
			blocks_twin_start(twin, BLOCKS_CODE_ADDRESS + test_case.offset)
			outcome := blocks_twin_run(t, twin, budget)
			if budget <= test_case.additions {
				testing.expect_value(t, outcome, Step_Outcome.Step_Budget_Exhausted)
				testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], budget)
			} else {
				testing.expect_value(t, outcome, Step_Outcome.Syscall)
			}
		}
	}
}

// A block whose last instruction ends at the last byte of its page holds
// that instruction: it does not cross the end. The next page starts a
// block of its own. The record of the first run runs the instruction of
// the next page and does not keep it, so the block of that page is recorded
// at the second run and entered at the third.
@(test)
blocks_a_block_that_ends_at_the_end_of_its_page_keeps_its_last_instruction :: proc(t: ^testing.T) {
	twin := blocks_twin_create(2)
	defer blocks_twin_destroy(twin)
	blocks_twin_write(twin, twin.code_frames[0] + PAGE_SIZE - 4, {0xFF, 0xC0, 0xFF, 0xC0}) // inc eax; inc eax
	blocks_twin_write(twin, twin.code_frames[1], {0x0F, 0x05}) // syscall
	for _ in 0 ..< 3 {
		blocks_twin_start(twin, BLOCKS_CODE_ADDRESS + PAGE_SIZE - 4)
		testing.expect_value(t, blocks_twin_run(t, twin, 100), Step_Outcome.Syscall)
		testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], u64(2))
	}
	block := block_cache_find(twin.cache, twin.code_frames[0] + PAGE_SIZE - 4)
	testing.expect(t, block != nil && block.instruction_count == 2 && block.byte_count == 4)
	testing.expect(t, block_cache_find(twin.cache, twin.code_frames[1]) != nil)
	testing.expect_value(t, twin.cache.counts.records, u64(2))
	testing.expect_value(t, twin.cache.counts.entries, u64(3))
}

// The places that the device of the test of a port access writes: the
// immediate of an instruction, in each memory of a twin. The test runner
// runs each test on its own thread, so they are thread-locals.
@(private = "file", thread_local)
blocks_device_targets: [2][]u8

// blocks_device_write is a device model that writes the memory at an out:
// the value goes into each target.
@(private = "file")
blocks_device_write :: proc "contextless" (port: u16, width: Operand_Width, value: u32) {
	for target in blocks_device_targets {
		target[0] = u8(value)
	}
}

@(private = "file")
blocks_device_read :: proc "contextless" (port: u16, width: Operand_Width) -> u32 {
	return 0
}

// A device model can write any frame at a port access, so an in or an out
// ends its block: the next instruction runs the bytes that the device
// wrote, as the steps one by one.
@(test)
blocks_a_port_access_ends_the_block :: proc(t: ^testing.T) {
	twin := blocks_twin_create(1)
	defer blocks_twin_destroy(twin)
	code := [?]u8 {
		0xE6, 0x80, // out 0x80, al
		0xB8, 0x01, 0x00, 0x00, 0x00, // mov eax, 1
		0x0F, 0x05, // syscall
	}
	blocks_twin_write(twin, twin.code_frames[0], code[:])
	permission_map := make([]u8, 8192 + 1)
	defer delete(permission_map)
	for &bits in permission_map {
		bits = 0xFF
	}
	permission_map[0x80 / 8] &~= u8(1) << (0x80 % 8)
	bus := Port_Bus {
		permission_map = permission_map,
		read           = blocks_device_read,
		write          = blocks_device_write,
	}
	for value in ([?]u64{1, 0x2A, 0x33}) {
		registers: [16]u64
		registers[int(General_Register.Rax)] = value
		blocks_twin_start(twin, BLOCKS_CODE_ADDRESS, registers)
		twin.with.ports = bus
		twin.without.ports = bus
		blocks_device_targets = {twin.machine.ram[int(twin.code_frames[0]) + 3:], twin.memory_without[int(twin.code_frames[0]) + 3:]}
		testing.expect_value(t, blocks_twin_run(t, twin, 100), Step_Outcome.Syscall)
		testing.expect_value(t, twin.with.registers[int(General_Register.Rax)], value)
	}
	block := block_cache_find(twin.cache, twin.code_frames[0])
	testing.expect(t, block != nil && block.instruction_count == 1, "the out ends its block")
	testing.expect(t, twin.cache.counts.written > 0, "the entries end after the out")
	blocks_device_targets = {}
}
