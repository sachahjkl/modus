// Freestanding Software MMU for the modus browser machine
// (src/md/features/browser_machine.md, "The software MMU").
//
// Walks x86-64 four-level page tables (PML4 -> PDPT -> PD -> PT, including
// 2 MiB large pages) directly inside a caller-provided physical RAM byte
// slice, matching the exact bit layout written by `modulus`
// (src/modulus/memory.odin and src/modulus/paging.odin).
//
// Enforces:
//   - canonical 48-bit virtual addresses;
//   - present, write, user, no-execute, and reserved bits across all levels;
//   - physical RAM bounds on every page-table read and leaf page access;
//   - atomic multi-byte and page-straddling reads and writes (a write that
//     faults on the second page modifies zero bytes of the first page);
//   - a per-processor direct-mapped software TLB with full and single-page
//     (`invlpg`) invalidation, and a cache of the page of the last
//     instruction fetch that each invalidation empties.
//
// This package is freestanding (`"contextless"`), allocates no memory, and
// imports only `base:` and `modus:contract/` packages.
package software_machine

import "base:intrinsics"
import "modus:contract/byte_order"

// Standard 4 KiB page geometry and 2 MiB large page geometry.
PAGE_SIZE :: u64(4096)
PAGE_OFFSET_MASK :: PAGE_SIZE - 1
LARGE_PAGE_SIZE :: u64(2) << 20
LARGE_PAGE_OFFSET_MASK :: LARGE_PAGE_SIZE - 1
PAGE_TABLE_ENTRY_COUNT :: u64(512)
PAGE_TABLE_INDEX_MASK :: u64(511)

// Architectural x86-64 4-level page-table entry flags matching `modulus`.
PAGE_PRESENT :: u64(1) << 0
PAGE_WRITE :: u64(1) << 1
PAGE_USER :: u64(1) << 2
PAGE_WRITE_THROUGH :: u64(1) << 3
PAGE_NO_CACHE :: u64(1) << 4
PAGE_ACCESSED :: u64(1) << 5
PAGE_DIRTY :: u64(1) << 6
PAGE_LARGE :: u64(1) << 7
PAGE_NO_EXECUTE :: u64(1) << 63

// Physical address masks for 4 KiB tables/pages and 2 MiB large pages.
// Bits 52..62 are ignored by x86-64 hardware and hold the held-entry count in
// `modulus`, so the walker never treats bits 52..62 as reserved.
PAGE_ADDRESS_MASK :: u64(0x000F_FFFF_FFFF_F000)
LARGE_PAGE_ADDRESS_MASK :: u64(0x000F_FFFF_FFE0_0000)
// Bits 13..20 in a 2 MiB large page directory entry are reserved (bit 12 is PAT).
LARGE_PAGE_RESERVED_MASK :: u64(0x0000_0000_001F_E000)

// Canonical 48-bit virtual address boundaries.
CANONICAL_LOWER_MAX :: u64(0x0000_7FFF_FFFF_FFFF)
CANONICAL_UPPER_MIN :: u64(0xFFFF_8000_0000_0000)

// Architectural x86-64 page-fault error code bits (P | W | U | RSVD | I).
PAGE_FAULT_PRESENT :: u64(1) << 0
PAGE_FAULT_WRITE :: u64(1) << 1
PAGE_FAULT_USER :: u64(1) << 2
PAGE_FAULT_RESERVED :: u64(1) << 3
PAGE_FAULT_INSTRUCTION :: u64(1) << 4

// Direct-mapped software TLB capacity (power of two).
// 2048 entries cover an 8 MiB working set across compositor, window surfaces,
// and vector font caches without 4-level page-table walks on every frame.
TLB_ENTRY_COUNT :: 2048
TLB_INDEX_MASK :: u64(TLB_ENTRY_COUNT - 1)

// Kind of memory access checked during address translation.
Memory_Access_Kind :: enum u8 {
	Read    = 0,
	Write   = 1,
	Execute = 2,
}

// Privilege level of the access being translated.
Privilege_Level :: enum u8 {
	Supervisor = 0,
	User       = 1,
}

// Outcome of translating or accessing a virtual address.
Memory_Translation_Status :: enum u8 {
	Ok                             = 0,
	Page_Fault                     = 1,
	Non_Canonical_Address          = 2,
	Physical_Address_Out_Of_Bounds = 3,
}

// One cached 4 KiB virtual-to-physical translation in the software TLB.
// A 2 MiB large page caches the resolved 4 KiB subpage and sets `large_page`
// so `tlb_flush_page` invalidates every cached subpage of that 2 MiB region.
Tlb_Entry :: struct {
	virtual_page:    u64,
	physical_page:   u64,
	page_table_root: u64,
	generation:      u32,
	valid:           bool,
	writable:        bool,
	user_accessible: bool,
	executable:      bool,
	dirty:           bool,
	large_page:      bool,
}

// Direct-mapped per-processor software TLB.
Software_Tlb :: struct {
	entries:                [TLB_ENTRY_COUNT]Tlb_Entry,
	generation:             u32,
	has_large_page_entries: bool,
	hits:                   u64,
	misses:                 u64,
	// The page of the last instruction fetch: the next byte of the same
	// page is one read of the frame, with no lookup. It holds only a
	// translation that the walk allowed for an execute, and every flush of
	// the TLB empties it, as the TLB of instructions of a processor.
	fetch_page:             Fetch_Page,
	// The frame of the decoded block that runs, while code_frame_active:
	// each write of this processor into it, and each accessed or dirty bit
	// that a walk sets in it, sets code_frame_written, and the block ends
	// after the instruction (blocks.odin). A port access sets it too: a
	// device model can write any frame.
	code_frame:             u64,
	code_frame_active:      bool,
	code_frame_written:     bool,
	// Active block cache for O(1) self-modifying-code epoch invalidation on
	// writes to any frame that holds cached decoded blocks.
	code_blocks:            ^Block_Cache,
}

// code_frame_write_note marks a write of this processor into the frame of
// the decoded block that runs, and advances the block cache epoch if any
// cached decoded block lives in that physical frame.
@(private = "file")
code_frame_write_note :: #force_inline proc "contextless" (tlb: ^Software_Tlb, physical_address: u64) {
	frame := physical_address & ~PAGE_OFFSET_MASK
	if tlb.code_frame_active && frame == tlb.code_frame {
		tlb.code_frame_written = true
	}
	if tlb.code_blocks != nil {
		block_cache_note_frame_write(tlb.code_blocks, frame)
	}
}

// The page of the last instruction fetch that the walk allowed.
Fetch_Page :: struct {
	virtual_page:    u64,
	physical_page:   u64,
	page_table_root: u64,
	privilege:       Privilege_Level,
	valid:           bool,
}

// Result of a virtual-to-physical translation or memory access.
Translation_Result :: struct {
	physical_address: u64,
	fault_error_code: u64,
	fault_address:    u64,
	status:           Memory_Translation_Status,
}

// is_canonical_virtual_address reports whether an address lies in the lower
// or upper canonical 48-bit half of the x86-64 virtual address space.
is_canonical_virtual_address :: #force_inline proc "contextless" (virtual_address: u64) -> bool {
	return virtual_address <= CANONICAL_LOWER_MAX || virtual_address >= CANONICAL_UPPER_MIN
}

// tlb_flush_all invalidates every entry in the software TLB (CR3 reload or
// full shoot-down) in O(1) by advancing the TLB generation.
tlb_flush_all :: proc "contextless" (tlb: ^Software_Tlb) {
	if tlb == nil {
		return
	}
	tlb.generation += 1
	if tlb.generation == 0 {
		for &entry in tlb.entries {
			entry.valid = false
		}
	}
	tlb.has_large_page_entries = false
	tlb.fetch_page.valid = false
}

// tlb_flush_page invalidates translations matching `virtual_address` (`invlpg`).
// When any 2 MiB large-page entry is cached, every cached subpage inside the
// same 2 MiB region is invalidated as well.
tlb_flush_page :: proc "contextless" (tlb: ^Software_Tlb, virtual_address: u64) {
	if tlb == nil {
		return
	}
	// The fetch page can be a subpage of the same large page: an invlpg
	// empties it whatever its address, which costs one walk at most.
	tlb.fetch_page.valid = false
	target_page := virtual_address & ~PAGE_OFFSET_MASK
	slot := (target_page >> 12) & TLB_INDEX_MASK
	if tlb.entries[slot].valid && tlb.entries[slot].generation == tlb.generation && tlb.entries[slot].virtual_page == target_page {
		tlb.entries[slot].valid = false
	}
	if !tlb.has_large_page_entries {
		return
	}
	target_large_page := virtual_address & ~LARGE_PAGE_OFFSET_MASK
	any_large_remaining := false
	for &entry in tlb.entries {
		if !entry.valid || entry.generation != tlb.generation || !entry.large_page {
			continue
		}
		if (entry.virtual_page & ~LARGE_PAGE_OFFSET_MASK) == target_large_page {
			entry.valid = false
		} else {
			any_large_remaining = true
		}
	}
	tlb.has_large_page_entries = any_large_remaining
}

// physical_range_in_bounds checks without overflow that `[address, address + size)`
// lies completely inside `physical_memory`.
@(private = "file")
physical_range_in_bounds :: #force_inline proc "contextless" (physical_memory: []u8, address: u64, size: u64) -> bool {
	ram_size := u64(len(physical_memory))
	return address <= ram_size && size <= ram_size - address
}

// page_table_entry_set_bits atomically ORs accessed/dirty bits into an entry
// when physical memory is 8-byte aligned, preserving concurrent atomic updates
// to the held-entry counter in bits 52..62.
@(private = "file")
page_table_entry_set_bits :: proc "contextless" (physical_memory: []u8, byte_offset: u64, bits: u64) {
	if bits == 0 || !physical_range_in_bounds(physical_memory, byte_offset, 8) {
		return
	}
	index := int(byte_offset)
	current := byte_order.read_u64_little_endian(physical_memory, index)
	if (current & bits) == bits {
		return
	}
	if (uintptr(raw_data(physical_memory)) & 7) == 0 && (byte_offset & 7) == 0 {
		entry_pointer := (^u64)(&physical_memory[index])
		intrinsics.atomic_or(entry_pointer, bits)
	} else {
		byte_order.write_u64_little_endian(physical_memory, index, current | bits)
	}
}

// fault_access_base_bits computes the access-kind and privilege bits of an
// x86-64 page-fault error code (W | U | I).
@(private = "file")
fault_access_base_bits :: #force_inline proc "contextless" (privilege: Privilege_Level, access: Memory_Access_Kind) -> u64 {
	bits := u64(0)
	if access == .Write {
		bits |= PAGE_FAULT_WRITE
	}
	if privilege == .User {
		bits |= PAGE_FAULT_USER
	}
	if access == .Execute {
		bits |= PAGE_FAULT_INSTRUCTION
	}
	return bits
}

// translate_virtual_address_internal walks the 4-level page table (with TLB
// acceleration when `commit_side_effects` is true). When `commit_side_effects`
// is false, it validates the mapping without mutating accessed/dirty bits or
// TLB state so straddling writes can prove both pages before touching RAM.
@(private = "file")
translate_virtual_address_internal :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
	access: Memory_Access_Kind,
	commit_side_effects: bool,
) -> Translation_Result {
	if !is_canonical_virtual_address(virtual_address) {
		return Translation_Result {
			fault_address = virtual_address,
			status        = .Non_Canonical_Address,
		}
	}

	virtual_page := virtual_address & ~PAGE_OFFSET_MASK
	page_offset := virtual_address & PAGE_OFFSET_MASK

	// Fast path: check the direct-mapped software TLB. On a permission or dirty
	// mismatch, fall through to the full page-table walk so upgraded permissions
	// work without requiring a prior invlpg, matching x86-64 hardware.
	if commit_side_effects && tlb != nil {
		slot := (virtual_page >> 12) & TLB_INDEX_MASK
		cached := &tlb.entries[slot]
		if cached.valid && cached.generation == tlb.generation && cached.page_table_root == page_table_root && cached.virtual_page == virtual_page {
			privilege_ok := privilege == .Supervisor || cached.user_accessible
			access_ok := true
			switch access {
			case .Read:
				access_ok = true
			case .Write:
				access_ok = cached.writable && cached.dirty
			case .Execute:
				access_ok = cached.executable
			}
			if privilege_ok && access_ok {
				tlb.hits += 1
				if access == .Write {
					code_frame_write_note(tlb, cached.physical_page)
				}
				return Translation_Result {
					physical_address = cached.physical_page | page_offset,
					status           = .Ok,
				}
			}
		}
		tlb.misses += 1
	}

	// Validate the PML4 root physical address before walking.
	if (page_table_root & PAGE_OFFSET_MASK) != 0 || !physical_range_in_bounds(physical_memory, page_table_root, PAGE_SIZE) {
		return Translation_Result {
			fault_address = virtual_address,
			status        = .Physical_Address_Out_Of_Bounds,
		}
	}

	base_fault_bits := fault_access_base_bits(privilege, access)

	effective_writable := true
	effective_user := true
	effective_no_execute := false

	walked_offsets: [4]u64
	walked_count := 0

	current_table := page_table_root
	resolved_frame := u64(0)
	resolved_large := false

	// Walk levels 3 (PML4), 2 (PDPT), 1 (PD), and 0 (PT).
	for level := uint(3); ; level -= 1 {
		entry_index := (virtual_address >> (12 + 9 * level)) & PAGE_TABLE_INDEX_MASK
		entry_offset := current_table + entry_index * 8
		entry := byte_order.read_u64_little_endian(physical_memory, int(entry_offset))

		if (entry & PAGE_PRESENT) == 0 {
			return Translation_Result {
				fault_error_code = base_fault_bits,
				fault_address    = virtual_address,
				status           = .Page_Fault,
			}
		}

		// Check architectural reserved bits on present entries.
		// Level 3 (PML4) forbids PAGE_LARGE.
		// Level 2 (PDPT) refuses 1 GiB pages (unused by modulus).
		// Level 1 (PD) with PAGE_LARGE forbids bits 13..20.
		if level == 3 && (entry & PAGE_LARGE) != 0 {
			return Translation_Result {
				fault_error_code = base_fault_bits | PAGE_FAULT_PRESENT | PAGE_FAULT_RESERVED,
				fault_address    = virtual_address,
				status           = .Page_Fault,
			}
		}
		if level == 2 && (entry & PAGE_LARGE) != 0 {
			return Translation_Result {
				fault_error_code = base_fault_bits | PAGE_FAULT_PRESENT | PAGE_FAULT_RESERVED,
				fault_address    = virtual_address,
				status           = .Page_Fault,
			}
		}
		if level == 1 && (entry & PAGE_LARGE) != 0 && (entry & LARGE_PAGE_RESERVED_MASK) != 0 {
			return Translation_Result {
				fault_error_code = base_fault_bits | PAGE_FAULT_PRESENT | PAGE_FAULT_RESERVED,
				fault_address    = virtual_address,
				status           = .Page_Fault,
			}
		}

		if (entry & PAGE_WRITE) == 0 {
			effective_writable = false
		}
		if (entry & PAGE_USER) == 0 {
			effective_user = false
		}
		if (entry & PAGE_NO_EXECUTE) != 0 {
			effective_no_execute = true
		}

		walked_offsets[walked_count] = entry_offset
		walked_count += 1

		if level == 1 && (entry & PAGE_LARGE) != 0 {
			large_base := entry & LARGE_PAGE_ADDRESS_MASK
			if !physical_range_in_bounds(physical_memory, large_base, LARGE_PAGE_SIZE) {
				return Translation_Result {
					fault_address = virtual_address,
					status        = .Physical_Address_Out_Of_Bounds,
				}
			}
			subpage_offset := (virtual_address & LARGE_PAGE_OFFSET_MASK) & ~PAGE_OFFSET_MASK
			resolved_frame = large_base + subpage_offset
			resolved_large = true
			break
		}

		if level == 0 {
			frame_base := entry & PAGE_ADDRESS_MASK
			if !physical_range_in_bounds(physical_memory, frame_base, PAGE_SIZE) {
				return Translation_Result {
					fault_address = virtual_address,
					status        = .Physical_Address_Out_Of_Bounds,
				}
			}
			resolved_frame = frame_base
			break
		}

		next_table := entry & PAGE_ADDRESS_MASK
		if !physical_range_in_bounds(physical_memory, next_table, PAGE_SIZE) {
			return Translation_Result {
				fault_address = virtual_address,
				status        = .Physical_Address_Out_Of_Bounds,
			}
		}
		current_table = next_table
	}

	// Enforce effective permissions across all walked levels.
	if privilege == .User && !effective_user {
		return Translation_Result {
			fault_error_code = base_fault_bits | PAGE_FAULT_PRESENT,
			fault_address    = virtual_address,
			status           = .Page_Fault,
		}
	}
	if access == .Write && !effective_writable {
		return Translation_Result {
			fault_error_code = base_fault_bits | PAGE_FAULT_PRESENT,
			fault_address    = virtual_address,
			status           = .Page_Fault,
		}
	}
	if access == .Execute && effective_no_execute {
		return Translation_Result {
			fault_error_code = base_fault_bits | PAGE_FAULT_PRESENT,
			fault_address    = virtual_address,
			status           = .Page_Fault,
		}
	}

	if commit_side_effects {
		// Set Accessed on every walked entry and Dirty on the leaf entry when writing.
		for index in 0 ..< walked_count {
			bits_to_set := PAGE_ACCESSED
			if access == .Write && index == walked_count - 1 {
				bits_to_set |= PAGE_DIRTY
			}
			page_table_entry_set_bits(physical_memory, walked_offsets[index], bits_to_set)
			if tlb != nil {
				code_frame_write_note(tlb, walked_offsets[index])
			}
		}

		if tlb != nil {
			if access == .Write {
				code_frame_write_note(tlb, resolved_frame)
			}
			leaf_entry := byte_order.read_u64_little_endian(physical_memory, int(walked_offsets[walked_count - 1]))
			slot := (virtual_page >> 12) & TLB_INDEX_MASK
			tlb.entries[slot] = Tlb_Entry {
				virtual_page    = virtual_page,
				physical_page   = resolved_frame,
				page_table_root = page_table_root,
				generation      = tlb.generation,
				valid           = true,
				writable        = effective_writable,
				user_accessible = effective_user,
				executable      = !effective_no_execute,
				dirty           = (leaf_entry & PAGE_DIRTY) != 0,
				large_page      = resolved_large,
			}
			if resolved_large {
				tlb.has_large_page_entries = true
			}
		}
	}

	return Translation_Result {
		physical_address = resolved_frame | page_offset,
		status           = .Ok,
	}
}

// translate_virtual_address resolves `virtual_address` through the 4-level
// page table at `page_table_root`, enforcing canonical form, permissions, and
// physical RAM bounds, and updating accessed/dirty bits and the software TLB.
translate_virtual_address :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
	access: Memory_Access_Kind,
) -> Translation_Result {
	return translate_virtual_address_internal(tlb, physical_memory, page_table_root, virtual_address, privilege, access, true)
}

// bytes_copy copies the bytes of one checked page chunk. The kernel of a
// browser machine copies between process memory and its own memory, and
// both are the one linear memory, so the two ranges can overlap: the copy
// keeps the order of a copy byte after byte from the lowest address only
// when the destination is below the source, which is the move of the
// intrinsic.
@(private = "file")
bytes_copy :: #force_inline proc "contextless" (destination, source: rawptr, count: int) {
	intrinsics.mem_copy(destination, source, count)
}

// mmu_read_bytes reads `len(destination)` bytes from virtual memory into
// `destination`. For page-straddling accesses, every spanned page is validated
// before copying so a fault on a later page leaves `destination` untouched.
mmu_read_bytes :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
	access: Memory_Access_Kind,
	destination: []u8,
) -> Translation_Result {
	total := u64(len(destination))
	if total == 0 {
		return Translation_Result{status = .Ok}
	}
	if virtual_address > max(u64) - (total - 1) {
		return Translation_Result {
			fault_address = virtual_address,
			status        = .Non_Canonical_Address,
		}
	}

	page_offset := virtual_address & PAGE_OFFSET_MASK
	// Fast path: access fits within a single 4 KiB page.
	if page_offset + total <= PAGE_SIZE {
		translated := translate_virtual_address_internal(tlb, physical_memory, page_table_root, virtual_address, privilege, access, true)
		if translated.status != .Ok {
			return translated
		}
		bytes_copy(raw_data(destination), &physical_memory[int(translated.physical_address)], len(destination))
		return translated
	}

	// Pass 1: prove every spanned page is mapped and permits `access`.
	cursor := u64(0)
	for cursor < total {
		current_virtual := virtual_address + cursor
		chunk := min(total - cursor, PAGE_SIZE - (current_virtual & PAGE_OFFSET_MASK))
		check := translate_virtual_address_internal(tlb, physical_memory, page_table_root, current_virtual, privilege, access, false)
		if check.status != .Ok {
			return check
		}
		cursor += chunk
	}

	// Pass 2: commit translations and copy bytes into `destination`.
	cursor = 0
	first_physical := u64(0)
	for cursor < total {
		current_virtual := virtual_address + cursor
		chunk := min(total - cursor, PAGE_SIZE - (current_virtual & PAGE_OFFSET_MASK))
		translated := translate_virtual_address_internal(tlb, physical_memory, page_table_root, current_virtual, privilege, access, true)
		if translated.status != .Ok {
			return translated
		}
		if cursor == 0 {
			first_physical = translated.physical_address
		}
		bytes_copy(&destination[int(cursor)], &physical_memory[int(translated.physical_address)], int(chunk))
		cursor += chunk
	}

	return Translation_Result {
		physical_address = first_physical,
		status           = .Ok,
	}
}

// mmu_write_bytes writes `source` into virtual memory atomically across page
// boundaries: if any spanned page faults, zero bytes of earlier pages (and
// zero page-table bits) are modified.
mmu_write_bytes :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
	source: []u8,
) -> Translation_Result {
	total := u64(len(source))
	if total == 0 {
		return Translation_Result{status = .Ok}
	}
	if virtual_address > max(u64) - (total - 1) {
		return Translation_Result {
			fault_address = virtual_address,
			status        = .Non_Canonical_Address,
		}
	}

	page_offset := virtual_address & PAGE_OFFSET_MASK
	// Fast path: write fits within a single 4 KiB page.
	if page_offset + total <= PAGE_SIZE {
		translated := translate_virtual_address_internal(tlb, physical_memory, page_table_root, virtual_address, privilege, .Write, true)
		if translated.status != .Ok {
			return translated
		}
		bytes_copy(&physical_memory[int(translated.physical_address)], raw_data(source), len(source))
		return translated
	}

	// Pass 1: prove every spanned page is writable before modifying any byte.
	cursor := u64(0)
	for cursor < total {
		current_virtual := virtual_address + cursor
		chunk := min(total - cursor, PAGE_SIZE - (current_virtual & PAGE_OFFSET_MASK))
		check := translate_virtual_address_internal(tlb, physical_memory, page_table_root, current_virtual, privilege, .Write, false)
		if check.status != .Ok {
			return check
		}
		cursor += chunk
	}

	// Pass 2: commit accessed/dirty bits and write every spanned chunk.
	cursor = 0
	first_physical := u64(0)
	for cursor < total {
		current_virtual := virtual_address + cursor
		chunk := min(total - cursor, PAGE_SIZE - (current_virtual & PAGE_OFFSET_MASK))
		translated := translate_virtual_address_internal(tlb, physical_memory, page_table_root, current_virtual, privilege, .Write, true)
		if translated.status != .Ok {
			return translated
		}
		if cursor == 0 {
			first_physical = translated.physical_address
		}
		bytes_copy(&physical_memory[int(translated.physical_address)], &source[int(cursor)], int(chunk))
		cursor += chunk
	}

	return Translation_Result {
		physical_address = first_physical,
		status           = .Ok,
	}
}

// mmu_fetch_u8 fetches one instruction byte with Execute permission.
mmu_fetch_u8 :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
) -> (value: u8, result: Translation_Result) {
	translated := mmu_fetch_translate(tlb, physical_memory, page_table_root, virtual_address, privilege)
	if translated.status != .Ok {
		return 0, translated
	}
	return physical_memory[int(translated.physical_address)], translated
}

// mmu_fetch_translate translates the place of an instruction fetch with
// Execute permission, through the page of the last fetch, and keeps the
// page that the walk allowed as that page. The entry of a decoded block
// calls it, so its walk, its bits and its faults are the ones of the fetch
// of the first byte.
mmu_fetch_translate :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
) -> Translation_Result {
	virtual_page := virtual_address & ~PAGE_OFFSET_MASK
	if tlb != nil {
		page := &tlb.fetch_page
		if page.valid && page.virtual_page == virtual_page && page.page_table_root == page_table_root && page.privilege == privilege {
			return Translation_Result{physical_address = page.physical_page | (virtual_address & PAGE_OFFSET_MASK), status = .Ok}
		}
	}
	translated := translate_virtual_address_internal(tlb, physical_memory, page_table_root, virtual_address, privilege, .Execute, true)
	if translated.status != .Ok {
		return translated
	}
	if tlb != nil {
		tlb.fetch_page = Fetch_Page {
			virtual_page    = virtual_page,
			physical_page   = translated.physical_address & ~PAGE_OFFSET_MASK,
			page_table_root = page_table_root,
			privilege       = privilege,
			valid           = true,
		}
	}
	return translated
}

// mmu_read_u8 reads one data byte from virtual memory.
mmu_read_u8 :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
) -> (value: u8, result: Translation_Result) {
	translated := translate_virtual_address_internal(tlb, physical_memory, page_table_root, virtual_address, privilege, .Read, true)
	if translated.status != .Ok {
		return 0, translated
	}
	return physical_memory[int(translated.physical_address)], translated
}

// mmu_read_u16 reads a little-endian 16-bit integer from virtual memory.
mmu_read_u16 :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
) -> (value: u16, result: Translation_Result) {
	buffer: [2]u8
	result = mmu_read_bytes(tlb, physical_memory, page_table_root, virtual_address, privilege, .Read, buffer[:])
	if result.status != .Ok {
		return 0, result
	}
	return byte_order.read_u16_little_endian(buffer[:], 0), result
}

// mmu_read_u32 reads a little-endian 32-bit integer from virtual memory.
mmu_read_u32 :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
) -> (value: u32, result: Translation_Result) {
	buffer: [4]u8
	result = mmu_read_bytes(tlb, physical_memory, page_table_root, virtual_address, privilege, .Read, buffer[:])
	if result.status != .Ok {
		return 0, result
	}
	return byte_order.read_u32_little_endian(buffer[:], 0), result
}

// mmu_read_u64 reads a little-endian 64-bit integer from virtual memory.
mmu_read_u64 :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
) -> (value: u64, result: Translation_Result) {
	buffer: [8]u8
	result = mmu_read_bytes(tlb, physical_memory, page_table_root, virtual_address, privilege, .Read, buffer[:])
	if result.status != .Ok {
		return 0, result
	}
	return byte_order.read_u64_little_endian(buffer[:], 0), result
}

// mmu_read_u128 reads 16 bytes for SSE2 vector loads.
mmu_read_u128 :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
) -> (value: [16]u8, result: Translation_Result) {
	result = mmu_read_bytes(tlb, physical_memory, page_table_root, virtual_address, privilege, .Read, value[:])
	if result.status != .Ok {
		return {}, result
	}
	return value, result
}

// mmu_write_u8 writes one data byte to virtual memory.
mmu_write_u8 :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
	value: u8,
) -> Translation_Result {
	translated := translate_virtual_address_internal(tlb, physical_memory, page_table_root, virtual_address, privilege, .Write, true)
	if translated.status != .Ok {
		return translated
	}
	physical_memory[int(translated.physical_address)] = value
	return translated
}

// mmu_write_u16 writes a little-endian 16-bit integer to virtual memory.
mmu_write_u16 :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
	value: u16,
) -> Translation_Result {
	buffer: [2]u8
	byte_order.write_u16_little_endian(buffer[:], 0, value)
	return mmu_write_bytes(tlb, physical_memory, page_table_root, virtual_address, privilege, buffer[:])
}

// mmu_write_u32 writes a little-endian 32-bit integer to virtual memory.
mmu_write_u32 :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
	value: u32,
) -> Translation_Result {
	buffer: [4]u8
	byte_order.write_u32_little_endian(buffer[:], 0, value)
	return mmu_write_bytes(tlb, physical_memory, page_table_root, virtual_address, privilege, buffer[:])
}

// mmu_write_u64 writes a little-endian 64-bit integer to virtual memory.
mmu_write_u64 :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
	value: u64,
) -> Translation_Result {
	buffer: [8]u8
	byte_order.write_u64_little_endian(buffer[:], 0, value)
	return mmu_write_bytes(tlb, physical_memory, page_table_root, virtual_address, privilege, buffer[:])
}

// mmu_write_u128 writes 16 bytes for SSE2 vector stores.
mmu_write_u128 :: proc "contextless" (
	tlb: ^Software_Tlb,
	physical_memory: []u8,
	page_table_root: u64,
	virtual_address: u64,
	privilege: Privilege_Level,
	value: [16]u8,
) -> Translation_Result {
	buffer := value
	return mmu_write_bytes(tlb, physical_memory, page_table_root, virtual_address, privilege, buffer[:])
}
