package software_machine

// The decoded blocks of the software processor (src/md/features/browser_machine.md,
// "The decoded blocks" and "Coherence").
//
// A decoded block is a run of instructions inside one page that the
// processor fetched and decoded once. processor_run enters a block at each
// place where one starts: it translates the place for an execute, compares
// the bytes of the block with the memory, then runs each instruction from
// its opcode with its decoded prefixes, its fetches reading the bytes of
// the block. The one executor runs both paths, so a block changes no
// result: only the count of the translations and of the prefix loops.

import "base:intrinsics"

// The blocks of one processor. A power of two: the slot of a block is bits
// of the hash of its key.
BLOCK_CACHE_CAPACITY :: 1024
BLOCK_CACHE_SLOT_BITS :: 10
#assert(1 << BLOCK_CACHE_SLOT_BITS == BLOCK_CACHE_CAPACITY)

// The most instructions of one block: a run with no taken branch is at
// most this long, which bounds the time before a block sees a change that
// another processor wrote.
BLOCK_INSTRUCTION_CAPACITY :: 16

// The most bytes of one block: the compare at each entry reads them.
BLOCK_BYTE_CAPACITY :: 128
#assert(BLOCK_BYTE_CAPACITY <= int(max(u8)))

// One decoded block, keyed by the physical address of its first byte.
Decoded_Block :: struct {
	start_physical:    u64,
	valid:             bool,
	instruction_count: u8,
	byte_count:        u8,
	bytes:             [BLOCK_BYTE_CAPACITY]u8,
	instructions:      [BLOCK_INSTRUCTION_CAPACITY]Decoded_Instruction,
}

// The counts of a cache, for the measures and the tests.
Block_Cache_Counts :: struct {
	entries:  u64, // A block found whose bytes equal the memory.
	records:  u64, // A block recorded.
	changed:  u64, // A block found whose bytes no longer equal the memory: it is recorded again.
	replaced: u64, // A recorded block that took the slot of another block.
	written:  u64, // A block that ended after a write of its own frame, or after a port access.
}

// The cache of the decoded blocks of one processor. Its zero value is an
// empty cache.
Block_Cache :: struct {
	blocks: [BLOCK_CACHE_CAPACITY]Decoded_Block,
	counts: Block_Cache_Counts,
}

// block_slot is the slot of the block that starts at a physical address.
block_slot :: #force_inline proc "contextless" (start_physical: u64) -> int {
	return int((start_physical * 0x9E37_79B9_7F4A_7C15) >> (64 - BLOCK_CACHE_SLOT_BITS))
}

// block_cache_find gives the valid block that starts at a physical address,
// or nil. It does not compare the bytes. A block whose counts pass the
// arrays of a block is refused: the compare and the run index those arrays
// with them.
block_cache_find :: proc "contextless" (cache: ^Block_Cache, start_physical: u64) -> ^Decoded_Block {
	block := &cache.blocks[block_slot(start_physical)]
	if !block.valid || block.start_physical != start_physical {
		return nil
	}
	if int(block.byte_count) > BLOCK_BYTE_CAPACITY || int(block.instruction_count) > BLOCK_INSTRUCTION_CAPACITY {
		return nil
	}
	return block
}

// block_bytes_equal says whether the memory still holds the bytes of a
// block. The block is inside one frame that the translation of its entry
// found in the memory.
@(private)
block_bytes_equal :: proc "contextless" (block: ^Decoded_Block, physical_memory: []u8) -> bool {
	count := int(block.byte_count)
	memory := physical_memory[int(block.start_physical):][:count]
	index := 0
	for ; index + 8 <= count; index += 8 {
		if intrinsics.unaligned_load((^u64)(&memory[index])) != intrinsics.unaligned_load((^u64)(&block.bytes[index])) {
			return false
		}
	}
	for ; index < count; index += 1 {
		if memory[index] != block.bytes[index] {
			return false
		}
	}
	return true
}

// block_step runs the block that starts at the place of the processor, or
// records one there, within step_allowance steps.
@(private)
block_step :: proc "contextless" (cpu: ^Processor_State, physical_memory: []u8, step_allowance: u64) -> Step_Outcome {
	translated := mmu_fetch_translate(&cpu.tlb, physical_memory, cpu.cr3, cpu.rip, .User)
	if translated.status != .Ok {
		// The fault of the fetch of the first byte, as the step of one
		// instruction gives it, with no second walk: the counts of the
		// translation cache stay the ones of the steps one by one.
		cpu.rflags |= RFLAGS_RESERVED_ONE
		return record_translation_fault(cpu, cpu.rip, translated)
	}
	cache := cpu.blocks
	if block := block_cache_find(cache, translated.physical_address); block != nil {
		if block_bytes_equal(block, physical_memory) {
			cache.counts.entries += 1
			return block_run(cpu, physical_memory, block, step_allowance)
		}
		cache.counts.changed += 1
		block.valid = false
	}
	return block_record(cpu, physical_memory, translated.physical_address, step_allowance)
}

// block_run runs the instructions of a block whose bytes equal the memory,
// from the first, while each one goes on at the next and the budget allows
// a step.
@(private)
block_run :: proc "contextless" (cpu: ^Processor_State, physical_memory: []u8, block: ^Decoded_Block, step_allowance: u64) -> Step_Outcome {
	entry_rip := cpu.rip
	steps_at_entry := cpu.steps_executed
	cpu.tlb.code_frame = block.start_physical & ~PAGE_OFFSET_MASK
	cpu.tlb.code_frame_active = true
	cpu.tlb.code_frame_written = false
	defer cpu.tlb.code_frame_active = false
	for index in 0 ..< int(block.instruction_count) {
		steps_used := cpu.steps_executed - steps_at_entry
		if steps_used >= step_allowance {
			return .Running
		}
		instruction := &block.instructions[index]
		if cpu.rip != entry_rip + u64(instruction.offset) {
			return .Running
		}
		// No zero fill of the bytes of a record: a fetch past the bytes of
		// the block writes each one before a read.
		cursor: Instruction_Cursor = ---
		cursor.start_rip = cpu.rip
		cursor.current_rip = cpu.rip + u64(instruction.opcode_end)
		cursor.bytes_fetched = int(instruction.opcode_end)
		cursor.cached_bytes = &block.bytes[instruction.offset]
		cursor.cached_count = int(instruction.length)
		outcome := instruction_step(cpu, physical_memory, step_allowance - steps_used, &cursor, instruction, true)
		if outcome != .Running {
			return outcome
		}
		// The next instruction must see the bytes that this one wrote.
		if cpu.tlb.code_frame_written {
			cpu.blocks.counts.written += 1
			return .Running
		}
	}
	return .Running
}

// block_record runs the instructions from the place of the processor on
// the path of the bytes, and keeps each one that ends with no fault, inside
// the page of the first, as a block. A block of no instruction is not kept,
// and its slot keeps the block that it holds.
@(private)
block_record :: proc "contextless" (cpu: ^Processor_State, physical_memory: []u8, start_physical: u64, step_allowance: u64) -> Step_Outcome {
	record: Decoded_Block
	record.start_physical = start_physical
	entry_page := cpu.rip & ~PAGE_OFFSET_MASK
	steps_at_entry := cpu.steps_executed
	cpu.tlb.code_frame = start_physical & ~PAGE_OFFSET_MASK
	cpu.tlb.code_frame_active = true
	cpu.tlb.code_frame_written = false
	outcome := Step_Outcome.Running
	for int(record.instruction_count) < BLOCK_INSTRUCTION_CAPACITY {
		steps_used := cpu.steps_executed - steps_at_entry
		if steps_used >= step_allowance {
			break
		}
		start_rip := cpu.rip
		cursor: Instruction_Cursor
		decoded: Decoded_Instruction
		outcome = instruction_step(cpu, physical_memory, step_allowance - steps_used, &cursor, &decoded, false)
		length := cursor.bytes_fetched
		// A fault leaves no instruction to keep. An instruction that
		// crosses the end of the page needs the translation of the next
		// page at each run, so the path of the bytes keeps it.
		kept := false
		in_page := start_rip & ~PAGE_OFFSET_MASK == entry_page && (start_rip & PAGE_OFFSET_MASK) + u64(length) <= PAGE_SIZE
		if (outcome == .Running || outcome == .Syscall) && in_page && int(record.byte_count) + length <= BLOCK_BYTE_CAPACITY {
			decoded.offset = record.byte_count
			decoded.length = u8(length)
			intrinsics.mem_copy_non_overlapping(&record.bytes[record.byte_count], &cursor.fetched_bytes[0], length)
			record.instructions[record.instruction_count] = decoded
			record.instruction_count += 1
			record.byte_count += u8(length)
			kept = true
		}
		if outcome != .Running || !kept || cpu.rip != start_rip + u64(length) || cpu.tlb.code_frame_written {
			break
		}
	}
	cpu.tlb.code_frame_active = false
	if record.instruction_count > 0 {
		cache := cpu.blocks
		slot := &cache.blocks[block_slot(start_physical)]
		if slot.valid && slot.start_physical != start_physical {
			cache.counts.replaced += 1
		}
		record.valid = true
		slot^ = record
		cache.counts.records += 1
	}
	return outcome
}
