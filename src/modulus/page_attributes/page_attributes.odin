// The cache types of the pages of the kernel (the AMD manual, volume 2,
// "Page-Attribute Table Mechanism"; the Intel manual, volume 3, "Page
// Attribute Table"): the page attribute table that the kernel writes on each
// processor, and the bits of a page table entry that select a type of it.
// The design is src/md/features/gpu_access.md, "Write-combining device
// memory".
//
// A page table entry selects one of the eight entries of the table with
// three bits: PWT (bit 3), PCD (bit 4) and PAT (bit 7 of a small page, bit
// 12 of a large page). The kernel never sets the bit PAT, so the entries 4
// to 7 repeat the entries 0 to 3.
//
// This package holds no state and runs no instruction of the processor, so
// a host test checks each encoding.
package page_attributes

import "modus:contract/enum_word"
import op "modus:contract/operation"

// The register of the page attribute table (IA32_PAT).
MODEL_SPECIFIC_REGISTER_PAGE_ATTRIBUTE_TABLE :: u32(0x277)

// A cache type, as an entry of the table encodes it. The values 2 and 3 are
// reserved: the processor faults on a write of the table with one of them.
Memory_Type :: enum u8 {
	Uncacheable       = 0, // UC: each read and each write reaches the device, in order.
	Write_Combining   = 1, // WC: writes gather in a buffer and reach the device in bursts; reads are not cached.
	Write_Through     = 4, // WT
	Write_Protected   = 5, // WP
	Write_Back        = 6, // WB: the cache of normal memory.
	Uncacheable_Minus = 7, // UC-: uncacheable, unless a memory type range (MTRR) says write-combining.
}

PAGE_WRITE_THROUGH :: u64(1) << 3 // PWT
PAGE_CACHE_DISABLE :: u64(1) << 4 // PCD
// The bits of an entry that the kernel uses to select a cache type.
PAGE_CACHE_TYPE_BITS :: PAGE_WRITE_THROUGH | PAGE_CACHE_DISABLE

// The bits of an entry for each cache type that the kernel maps. No bit:
// the entry 0, write-back, which a memory type range of the firmware can
// still make uncacheable or write-combining (the framebuffer of the
// firmware).
PAGE_WRITE_BACK :: u64(0) // Entry 0.
PAGE_WRITE_COMBINING :: PAGE_WRITE_THROUGH // Entry 1.
PAGE_UNCACHEABLE :: PAGE_WRITE_THROUGH | PAGE_CACHE_DISABLE // Entry 3: the registers of a device.

// The table of the kernel, entry by entry. The table at reset has
// write-through at the entry 1; the kernel maps no page with it, and puts
// write-combining there. The entry 2 keeps the uncacheable type that a
// memory type range can weaken, as at reset.
KERNEL_TABLE :: [8]Memory_Type{.Write_Back, .Write_Combining, .Uncacheable_Minus, .Uncacheable, .Write_Back, .Write_Combining, .Uncacheable_Minus, .Uncacheable}
// The word of KERNEL_TABLE, which the kernel writes in the register. A
// host test checks that table_word gives it.
KERNEL_TABLE_WORD :: u64(0x0007_0106_0007_0106)
// The table at reset (the AMD manual, volume 2, "PAT Register").
RESET_TABLE_WORD :: u64(0x0007_0406_0007_0406)

// table_word gives the word of the register for a table: the entry n in
// bits 8n to 8n + 2.
table_word :: proc "contextless" (table: [8]Memory_Type) -> u64 {
	word: u64
	for type, index in table {
		word |= u64(type) << (u64(index) * 8)
	}
	return word
}

// table_of_word reads the word of the register, or false when an entry
// holds a reserved value or a bit above its three bits.
table_of_word :: proc "contextless" (word: u64) -> (table: [8]Memory_Type, ok: bool) {
	for index in 0 ..< 8 {
		type, known := enum_word.member_of_word(Memory_Type, word >> (u64(index) * 8) & 0xFF)
		if !known {
			return {}, false
		}
		table[index] = type
	}
	return table, true
}

// The cache type of a mapping of device memory, as the bits of its entry
// select it.
Mapping_Cache_Type :: enum u8 {
	Default         = 0, // No bit: the entry 0, which the memory type ranges of the firmware decide (Display_Memory, the framebuffer of the firmware).
	Write_Combining = 1, // PWT: the entry 1.
	Uncacheable     = 2, // PWT and PCD: the entry 3, the registers of a device.
}

// The count of the live mappings of each cache type of one memory object.
Mapping_Cache_Counts :: [Mapping_Cache_Type]u32

// mapping_cache_type_of_bits gives the cache type that the bits of an entry
// of the kernel select, or false for a combination that the kernel never
// writes (PCD alone).
mapping_cache_type_of_bits :: proc "contextless" (bits: u64) -> (type: Mapping_Cache_Type, ok: bool) {
	entry_bits := MAPPING_CACHE_TYPE_BITS
	for candidate in Mapping_Cache_Type {
		if bits & PAGE_CACHE_TYPE_BITS == entry_bits[candidate] {
			return candidate, true
		}
	}
	return .Default, false
}

// The bits of an entry for each cache type of a mapping.
MAPPING_CACHE_TYPE_BITS :: [Mapping_Cache_Type]u64 {
	.Default         = PAGE_WRITE_BACK,
	.Write_Combining = PAGE_WRITE_COMBINING,
	.Uncacheable     = PAGE_UNCACHEABLE,
}

// report_flag_of_bits gives the flag of the report of a mapping that names
// its cache type, or false for the entry 0, which names none: the
// registers of a device are Uncached, a write-combining mapping
// Write_Combining.
report_flag_of_bits :: proc "contextless" (bits: u64) -> (flag: op.Process_Mapping_Flag, named: bool) {
	type := mapping_cache_type_of_bits(bits) or_return
	switch type {
	case .Default:
		return .Uncached, false
	case .Write_Combining:
		return .Write_Combining, true
	case .Uncacheable:
		return .Uncached, true
	}
	return .Uncached, false
}

// cache_type_joins says if a new mapping of a cache type can join the live
// mappings of one memory object: only when none of them has another type.
// Two cache types over one frame break the coherence of the caches: a
// write that one mapping combines can pass a read of the other.
cache_type_joins :: proc "contextless" (counts: Mapping_Cache_Counts, type: Mapping_Cache_Type) -> bool {
	for count, other in counts {
		if other != type && count != 0 {
			return false
		}
	}
	return true
}

// ranges_overlap says if two ranges of physical pages share a page. The
// ranges of device memory end below 2^52, so no sum overflows.
ranges_overlap :: proc "contextless" (first_start: u64, first_pages: u64, second_start: u64, second_pages: u64) -> bool {
	PAGE_BYTES :: 4096
	return first_start < second_start + second_pages * PAGE_BYTES && second_start < first_start + first_pages * PAGE_BYTES
}

// type_of_entry gives the cache type that a small page with the bits of
// an entry has under a table: PWT, PCD and PAT (bit 7) name the entry.
type_of_entry :: proc "contextless" (table: [8]Memory_Type, entry: u64) -> Memory_Type {
	PAGE_ATTRIBUTE_SMALL :: u64(1) << 7
	index := (entry >> 3 & 1) | (entry >> 4 & 1) << 1 | (entry & PAGE_ATTRIBUTE_SMALL != 0 ? 4 : 0)
	return table[index]
}
