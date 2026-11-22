package guest_os

import "modus:contract/byte_order"
import op "modus:contract/operation"

// The memory of a guest as the process that runs it sees it: the bytes of
// the guest physical addresses 0 to len(bytes) - 1, mapped in the process.
// Each access checks its whole range first, with no overflow: a guest gives
// each address that a device reads, and a hostile guest gives any value.
Guest_Memory :: struct {
	bytes: []u8,
}

// guest_memory_range gives the bytes of a range of guest physical
// addresses, or false when a part of the range is past the memory.
guest_memory_range :: proc "contextless" (memory: Guest_Memory, address: u64, length: u64) -> (bytes: []u8, ok: bool) {
	size := u64(len(memory.bytes))
	if address > size || length > size - address {
		return nil, false
	}
	return memory.bytes[address:][:length], true
}

guest_memory_read_u16 :: proc "contextless" (memory: Guest_Memory, address: u64) -> (value: u16, ok: bool) {
	bytes := guest_memory_range(memory, address, 2) or_return
	return byte_order.read_u16_little_endian(bytes, 0), true
}

guest_memory_read_u32 :: proc "contextless" (memory: Guest_Memory, address: u64) -> (value: u32, ok: bool) {
	bytes := guest_memory_range(memory, address, 4) or_return
	return byte_order.read_u32_little_endian(bytes, 0), true
}

guest_memory_read_u64 :: proc "contextless" (memory: Guest_Memory, address: u64) -> (value: u64, ok: bool) {
	bytes := guest_memory_range(memory, address, 8) or_return
	return byte_order.read_u64_little_endian(bytes, 0), true
}

guest_memory_write_u16 :: proc "contextless" (memory: Guest_Memory, address: u64, value: u16) -> bool {
	bytes := guest_memory_range(memory, address, 2) or_return
	byte_order.write_u16_little_endian(bytes, 0, value)
	return true
}

guest_memory_write_u32 :: proc "contextless" (memory: Guest_Memory, address: u64, value: u32) -> bool {
	bytes := guest_memory_range(memory, address, 4) or_return
	byte_order.write_u32_little_endian(bytes, 0, value)
	return true
}

guest_memory_write_u64 :: proc "contextless" (memory: Guest_Memory, address: u64, value: u64) -> bool {
	bytes := guest_memory_range(memory, address, 8) or_return
	byte_order.write_u64_little_endian(bytes, 0, value)
	return true
}

// The bits of an entry of a long mode page table that a walk reads.
PAGE_ENTRY_PRESENT :: u64(1) << 0
PAGE_ENTRY_WRITE :: u64(1) << 1
PAGE_ENTRY_LARGE :: u64(1) << 7
PAGE_ENTRY_ADDRESS :: u64(0x000F_FFFF_FFFF_F000)

// guest_linear_to_physical gives the guest physical address of a linear
// address, through the page table of the guest in its memory. Paging off:
// the linear address is the physical address. Long mode: four or five
// levels, with pages of 4 KiB, 2 MiB and 1 GiB. Paging on outside long mode
// is not read: a Linux guest of 64 bits never drives a device there. A table
// past the memory, or an entry not present, gives false.
guest_linear_to_physical :: proc "contextless" (memory: Guest_Memory, registers: op.Guest_Registers, linear: u64) -> (physical: u64, ok: bool) {
	if registers.cr0 & op.GUEST_CONTROL_0_PAGING == 0 {
		return linear & 0xFFFF_FFFF, true
	}
	if registers.efer & op.GUEST_EFER_LONG_MODE_ACTIVE == 0 {
		return 0, false
	}
	levels := registers.cr4 & op.GUEST_CONTROL_4_FIVE_LEVEL_PAGING != 0 ? 5 : 4
	table := registers.cr3 & PAGE_ENTRY_ADDRESS
	for level := levels; level >= 1; level -= 1 {
		shift := u64(12 + 9 * (level - 1))
		index := linear >> shift & 0x1FF
		entry := guest_memory_read_u64(memory, table + index * 8) or_return
		if entry & PAGE_ENTRY_PRESENT == 0 {
			return 0, false
		}
		// A large page ends the walk at the level 2 (2 MiB) or 3 (1 GiB).
		if level == 1 || (level == 2 || level == 3) && entry & PAGE_ENTRY_LARGE != 0 {
			page_mask := (u64(1) << shift) - 1
			return (entry & PAGE_ENTRY_ADDRESS &~ page_mask) | (linear & page_mask), true
		}
		table = entry & PAGE_ENTRY_ADDRESS
	}
	return 0, false
}

// guest_instruction_fetch copies the bytes at a linear address into out,
// one byte at a time, so that an instruction across two pages is read
// through both. It gives the count of bytes that it read: an instruction at
// the end of the mapped memory gives fewer.
guest_instruction_fetch :: proc "contextless" (memory: Guest_Memory, registers: op.Guest_Registers, linear: u64, out: []u8) -> (count: int) {
	for index in 0 ..< len(out) {
		physical, mapped := guest_linear_to_physical(memory, registers, linear + u64(index))
		if !mapped {
			return index
		}
		bytes, inside := guest_memory_range(memory, physical, 1)
		if !inside {
			return index
		}
		out[index] = bytes[0]
	}
	return len(out)
}
