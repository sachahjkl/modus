#+build !freestanding
#+build !modus
package software_machine

import "core:testing"
import "modus:contract/byte_order"

// Test physical machine fixture with a bump frame allocator inside a flat RAM
// slice and exact x86-64 4-level page-table builders matching `modulus`.
Test_Machine :: struct {
	ram:        []u8,
	next_frame: u64,
	cr3:        u64,
}

test_machine_create :: proc(ram_bytes: int) -> Test_Machine {
	ram := make([]u8, ram_bytes)
	m := Test_Machine {
		ram        = ram,
		next_frame = PAGE_SIZE, // Keep frame 0 unused so 0 clearly means absent.
	}
	m.cr3 = test_alloc_frame(&m)
	return m
}

test_machine_destroy :: proc(m: ^Test_Machine) {
	delete(m.ram)
	m.ram = nil
}

test_alloc_frame :: proc(m: ^Test_Machine) -> u64 {
	frame := m.next_frame
	m.next_frame += PAGE_SIZE
	return frame
}

test_map_4k_page :: proc(
	m: ^Test_Machine,
	virtual_address: u64,
	physical_frame: u64,
	leaf_flags: u64,
	upper_flags: u64 = PAGE_PRESENT | PAGE_WRITE | PAGE_USER,
) {
	table := m.cr3
	for level := uint(3); level >= 1; level -= 1 {
		idx := (virtual_address >> (12 + 9 * level)) & PAGE_TABLE_INDEX_MASK
		entry_off := int(table + idx * 8)
		entry := byte_order.read_u64_little_endian(m.ram, entry_off)
		if (entry & PAGE_PRESENT) == 0 {
			child := test_alloc_frame(m)
			byte_order.write_u64_little_endian(m.ram, entry_off, child | upper_flags)
			table = child
		} else {
			table = entry & PAGE_ADDRESS_MASK
		}
	}
	pt_idx := (virtual_address >> 12) & PAGE_TABLE_INDEX_MASK
	pt_off := int(table + pt_idx * 8)
	byte_order.write_u64_little_endian(m.ram, pt_off, (physical_frame & PAGE_ADDRESS_MASK) | leaf_flags)
}

test_map_2m_page :: proc(
	m: ^Test_Machine,
	virtual_address: u64,
	physical_base: u64,
	leaf_flags: u64,
	upper_flags: u64 = PAGE_PRESENT | PAGE_WRITE | PAGE_USER,
) {
	table := m.cr3
	for level := uint(3); level >= 2; level -= 1 {
		idx := (virtual_address >> (12 + 9 * level)) & PAGE_TABLE_INDEX_MASK
		entry_off := int(table + idx * 8)
		entry := byte_order.read_u64_little_endian(m.ram, entry_off)
		if (entry & PAGE_PRESENT) == 0 {
			child := test_alloc_frame(m)
			byte_order.write_u64_little_endian(m.ram, entry_off, child | upper_flags)
			table = child
		} else {
			table = entry & PAGE_ADDRESS_MASK
		}
	}
	pd_idx := (virtual_address >> 21) & PAGE_TABLE_INDEX_MASK
	pd_off := int(table + pd_idx * 8)
	byte_order.write_u64_little_endian(m.ram, pd_off, (physical_base & LARGE_PAGE_ADDRESS_MASK) | leaf_flags | PAGE_LARGE)
}

test_read_pte :: proc(m: ^Test_Machine, virtual_address: u64) -> u64 {
	table := m.cr3
	for level := uint(3); level >= 1; level -= 1 {
		idx := (virtual_address >> (12 + 9 * level)) & PAGE_TABLE_INDEX_MASK
		entry := byte_order.read_u64_little_endian(m.ram, int(table + idx * 8))
		table = entry & PAGE_ADDRESS_MASK
	}
	pt_idx := (virtual_address >> 12) & PAGE_TABLE_INDEX_MASK
	return byte_order.read_u64_little_endian(m.ram, int(table + pt_idx * 8))
}

test_load_code :: proc(m: ^Test_Machine, code_frame: u64, code: []u8) {
	for byte, index in code {
		m.ram[int(code_frame) + index] = byte
	}
}

@(test)
test_mmu_4kib_page_walk_and_modulus_held_bits :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)

	data_frame := test_alloc_frame(&m)
	code_frame := test_alloc_frame(&m)
	upper_frame := test_alloc_frame(&m)

	// Set modulus held-entry counter bits (bits 52..62) on upper tables to
	// confirm the walker ignores them and preserves them on Accessed updates.
	held_count_bits := u64(7) << 52
	test_map_4k_page(&m, 0x0000_0000_0040_1000, data_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | held_count_bits)
	test_map_4k_page(&m, 0x0000_0000_0040_0000, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, 0xFFFF_8000_0000_2000, upper_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_NO_EXECUTE, PAGE_PRESENT | PAGE_WRITE)

	tlb: Software_Tlb

	// Read on RW NX user page succeeds, sets Accessed, leaves Dirty clear.
	r1 := translate_virtual_address(&tlb, m.ram, m.cr3, 0x0000_0000_0040_1234, .User, .Read)
	testing.expect_value(t, r1.status, Memory_Translation_Status.Ok)
	testing.expect_value(t, r1.physical_address, data_frame + 0x234)
	pte_after_read := test_read_pte(&m, 0x0000_0000_0040_1000)
	testing.expect(t, (pte_after_read & PAGE_ACCESSED) != 0, "Read must set Accessed bit")
	testing.expect(t, (pte_after_read & PAGE_DIRTY) == 0, "Read must not set Dirty bit")

	// Confirm PML4 held-entry bits in 52..62 survived atomic Accessed OR.
	pml4e := byte_order.read_u64_little_endian(m.ram, int(m.cr3))
	testing.expect_value(t, (pml4e >> 52) & 0x7FF, u64(7))
	testing.expect(t, (pml4e & PAGE_ACCESSED) != 0, "PML4E must have Accessed set")

	// Write sets Dirty bit.
	r2 := translate_virtual_address(&tlb, m.ram, m.cr3, 0x0000_0000_0040_1234, .User, .Write)
	testing.expect_value(t, r2.status, Memory_Translation_Status.Ok)
	pte_after_write := test_read_pte(&m, 0x0000_0000_0040_1000)
	testing.expect(t, (pte_after_write & PAGE_DIRTY) != 0, "Write must set Dirty bit")

	// Execute on RX user page succeeds.
	r3 := translate_virtual_address(&tlb, m.ram, m.cr3, 0x0000_0000_0040_0010, .User, .Execute)
	testing.expect_value(t, r3.status, Memory_Translation_Status.Ok)
	testing.expect_value(t, r3.physical_address, code_frame + 0x10)

	// Upper canonical supervisor mapping works in supervisor mode and faults in user mode.
	r4 := translate_virtual_address(&tlb, m.ram, m.cr3, 0xFFFF_8000_0000_2040, .Supervisor, .Write)
	testing.expect_value(t, r4.status, Memory_Translation_Status.Ok)
	testing.expect_value(t, r4.physical_address, upper_frame + 0x40)

	r5 := translate_virtual_address(&tlb, m.ram, m.cr3, 0xFFFF_8000_0000_2040, .User, .Read)
	testing.expect_value(t, r5.status, Memory_Translation_Status.Page_Fault)
	testing.expect_value(t, r5.fault_error_code, PAGE_FAULT_PRESENT | PAGE_FAULT_USER)
}

@(test)
test_mmu_2mib_large_page_and_reserved_bits :: proc(t: ^testing.T) {
	// 4 MiB RAM: 0..2 MiB for tables, 2 MiB..4 MiB for one 2 MiB large page frame.
	m := test_machine_create(4 * 1024 * 1024)
	defer test_machine_destroy(&m)

	large_phys := u64(2 * 1024 * 1024)
	large_virt := u64(0x0000_0000_2000_0000)
	test_map_2m_page(&m, large_virt, large_phys, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)

	tlb: Software_Tlb

	// Start, middle, and final byte of the 2 MiB page.
	r0 := translate_virtual_address(&tlb, m.ram, m.cr3, large_virt, .User, .Read)
	testing.expect_value(t, r0.status, Memory_Translation_Status.Ok)
	testing.expect_value(t, r0.physical_address, large_phys)

	r_mid := translate_virtual_address(&tlb, m.ram, m.cr3, large_virt + 0x12_3456, .User, .Write)
	testing.expect_value(t, r_mid.status, Memory_Translation_Status.Ok)
	testing.expect_value(t, r_mid.physical_address, large_phys + 0x12_3456)

	r_end := translate_virtual_address(&tlb, m.ram, m.cr3, large_virt + LARGE_PAGE_SIZE - 1, .User, .Read)
	testing.expect_value(t, r_end.status, Memory_Translation_Status.Ok)
	testing.expect_value(t, r_end.physical_address, large_phys + LARGE_PAGE_SIZE - 1)

	// Execute on NX large page must fault with P|U|I.
	r_nx := translate_virtual_address(&tlb, m.ram, m.cr3, large_virt + 0x100, .User, .Execute)
	testing.expect_value(t, r_nx.status, Memory_Translation_Status.Page_Fault)
	testing.expect_value(t, r_nx.fault_error_code, PAGE_FAULT_PRESENT | PAGE_FAULT_USER | PAGE_FAULT_INSTRUCTION)

	// Large page with reserved bit 13 set must fault with P|RSVD.
	bad_virt := u64(0x0000_0000_2020_0000)
	test_map_2m_page(&m, bad_virt, large_phys, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | (u64(1) << 13))
	// Re-write PDE with reserved bit intact (test_map_2m_page masks physical_base, not leaf_flags).
	r_rsvd := translate_virtual_address(&tlb, m.ram, m.cr3, bad_virt, .User, .Read)
	testing.expect_value(t, r_rsvd.status, Memory_Translation_Status.Page_Fault)
	testing.expect_value(t, r_rsvd.fault_error_code, PAGE_FAULT_PRESENT | PAGE_FAULT_USER | PAGE_FAULT_RESERVED)

	// Large page pointing past RAM end must be refused as out of bounds.
	oob_virt := u64(0x0000_0000_2040_0000)
	test_map_2m_page(&m, oob_virt, u64(4 * 1024 * 1024), PAGE_PRESENT | PAGE_WRITE | PAGE_USER)
	r_oob := translate_virtual_address(&tlb, m.ram, m.cr3, oob_virt, .User, .Read)
	testing.expect_value(t, r_oob.status, Memory_Translation_Status.Physical_Address_Out_Of_Bounds)
}

@(test)
test_mmu_canonical_fault_codes_and_ram_bounds :: proc(t: ^testing.T) {
	m := test_machine_create(128 * 1024)
	defer test_machine_destroy(&m)

	tlb: Software_Tlb

	// Canonical boundaries: non-canonical edges must be refused.
	testing.expect(t, is_canonical_virtual_address(0))
	testing.expect(t, is_canonical_virtual_address(CANONICAL_LOWER_MAX))
	testing.expect(t, !is_canonical_virtual_address(CANONICAL_LOWER_MAX + 1))
	testing.expect(t, !is_canonical_virtual_address(CANONICAL_UPPER_MIN - 1))
	testing.expect(t, is_canonical_virtual_address(CANONICAL_UPPER_MIN))
	testing.expect(t, is_canonical_virtual_address(max(u64)))

	r_nc1 := translate_virtual_address(&tlb, m.ram, m.cr3, 0x0000_8000_0000_0000, .User, .Read)
	testing.expect_value(t, r_nc1.status, Memory_Translation_Status.Non_Canonical_Address)
	testing.expect_value(t, r_nc1.fault_address, u64(0x0000_8000_0000_0000))

	r_nc2 := translate_virtual_address(&tlb, m.ram, m.cr3, 0xFFFF_7FFF_FFFF_FFFF, .User, .Execute)
	testing.expect_value(t, r_nc2.status, Memory_Translation_Status.Non_Canonical_Address)

	// Missing PML4E -> P=0.
	r_pml4 := translate_virtual_address(&tlb, m.ram, m.cr3, 0x0000_0080_0000_0000, .User, .Read)
	testing.expect_value(t, r_pml4.status, Memory_Translation_Status.Page_Fault)
	testing.expect_value(t, r_pml4.fault_error_code, PAGE_FAULT_USER)

	// Map one page at 0x1000 so PML4/PDPT/PD/PT exist at index 0.
	f1 := test_alloc_frame(&m)
	test_map_4k_page(&m, 0x1000, f1, PAGE_PRESENT | PAGE_USER | PAGE_NO_EXECUTE)

	// Missing PDPTE (1 GiB offset) on Write -> P=0|W|U.
	r_pdpt := translate_virtual_address(&tlb, m.ram, m.cr3, 0x4000_0000, .User, .Write)
	testing.expect_value(t, r_pdpt.status, Memory_Translation_Status.Page_Fault)
	testing.expect_value(t, r_pdpt.fault_error_code, PAGE_FAULT_WRITE | PAGE_FAULT_USER)

	// Missing PDE (2 MiB offset) on Execute -> P=0|U|I.
	r_pd := translate_virtual_address(&tlb, m.ram, m.cr3, 0x20_0000, .User, .Execute)
	testing.expect_value(t, r_pd.status, Memory_Translation_Status.Page_Fault)
	testing.expect_value(t, r_pd.fault_error_code, PAGE_FAULT_USER | PAGE_FAULT_INSTRUCTION)

	// Missing PTE (0x2000) on Supervisor Read -> error code 0.
	r_pt := translate_virtual_address(&tlb, m.ram, m.cr3, 0x2000, .Supervisor, .Read)
	testing.expect_value(t, r_pt.status, Memory_Translation_Status.Page_Fault)
	testing.expect_value(t, r_pt.fault_error_code, u64(0))

	// Write to read-only user page -> P|W|U.
	r_ro := translate_virtual_address(&tlb, m.ram, m.cr3, 0x1000, .User, .Write)
	testing.expect_value(t, r_ro.status, Memory_Translation_Status.Page_Fault)
	testing.expect_value(t, r_ro.fault_error_code, PAGE_FAULT_PRESENT | PAGE_FAULT_WRITE | PAGE_FAULT_USER)

	// Execute on NX user page -> P|U|I.
	r_nx := translate_virtual_address(&tlb, m.ram, m.cr3, 0x1000, .User, .Execute)
	testing.expect_value(t, r_nx.status, Memory_Translation_Status.Page_Fault)
	testing.expect_value(t, r_nx.fault_error_code, PAGE_FAULT_PRESENT | PAGE_FAULT_USER | PAGE_FAULT_INSTRUCTION)

	// Unaligned CR3 and out-of-bounds CR3 refused.
	r_cr3_unaligned := translate_virtual_address(&tlb, m.ram, m.cr3 + 1, 0x1000, .User, .Read)
	testing.expect_value(t, r_cr3_unaligned.status, Memory_Translation_Status.Physical_Address_Out_Of_Bounds)
	r_cr3_oob := translate_virtual_address(&tlb, m.ram, u64(len(m.ram)), 0x1000, .User, .Read)
	testing.expect_value(t, r_cr3_oob.status, Memory_Translation_Status.Physical_Address_Out_Of_Bounds)

	// PTE pointing past RAM end refused.
	test_map_4k_page(&m, 0x5000, u64(len(m.ram)), PAGE_PRESENT | PAGE_WRITE | PAGE_USER)
	r_frame_oob := translate_virtual_address(&tlb, m.ram, m.cr3, 0x5000, .User, .Read)
	testing.expect_value(t, r_frame_oob.status, Memory_Translation_Status.Physical_Address_Out_Of_Bounds)

	// Wrap-around past max(u64) refused.
	buf: [8]u8
	r_wrap := mmu_write_bytes(&tlb, m.ram, m.cr3, max(u64) - 3, .User, buf[:])
	testing.expect_value(t, r_wrap.status, Memory_Translation_Status.Non_Canonical_Address)
}

@(test)
test_mmu_page_straddling_write_is_atomic :: proc(t: ^testing.T) {
	m := test_machine_create(128 * 1024)
	defer test_machine_destroy(&m)

	frame_a := test_alloc_frame(&m)
	frame_b := test_alloc_frame(&m)
	test_map_4k_page(&m, 0x2000, frame_a, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	test_map_4k_page(&m, 0x3000, frame_b, PAGE_PRESENT | PAGE_USER | PAGE_NO_EXECUTE) // Read-only!

	// Fill tail of page A with sentinel 0xAA and start of page B with 0xBB.
	for i in 0xFF0 ..< 0x1000 {
		m.ram[int(frame_a) + i] = 0xAA
	}
	for i in 0 ..< 16 {
		m.ram[int(frame_b) + i] = 0xBB
	}

	tlb: Software_Tlb

	// Straddling 8-byte write at 0x2FFC (4 bytes in RW page A, 4 bytes in RO page B).
	res_fail := mmu_write_u64(&tlb, m.ram, m.cr3, 0x2FFC, .User, 0x1122_3344_5566_7788)
	testing.expect_value(t, res_fail.status, Memory_Translation_Status.Page_Fault)
	testing.expect_value(t, res_fail.fault_address, u64(0x3000))
	testing.expect_value(t, res_fail.fault_error_code, PAGE_FAULT_PRESENT | PAGE_FAULT_WRITE | PAGE_FAULT_USER)

	// Zero bytes of page A (and page B) may have changed, and page A's Dirty bit stays 0.
	for i in 0xFF0 ..< 0x1000 {
		testing.expect_value(t, m.ram[int(frame_a) + i], u8(0xAA))
	}
	for i in 0 ..< 16 {
		testing.expect_value(t, m.ram[int(frame_b) + i], u8(0xBB))
	}
	testing.expect(t, (test_read_pte(&m, 0x2000) & PAGE_DIRTY) == 0, "Faulting straddling write must not set Dirty on page 1")

	// Now make page B writable and retry the straddling write.
	test_map_4k_page(&m, 0x3000, frame_b, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	res_ok := mmu_write_u64(&tlb, m.ram, m.cr3, 0x2FFC, .User, 0x1122_3344_5566_7788)
	testing.expect_value(t, res_ok.status, Memory_Translation_Status.Ok)

	readback, res_read := mmu_read_u64(&tlb, m.ram, m.cr3, 0x2FFC, .User)
	testing.expect_value(t, res_read.status, Memory_Translation_Status.Ok)
	testing.expect_value(t, readback, u64(0x1122_3344_5566_7788))
	testing.expect_value(t, m.ram[int(frame_a) + 0xFFC], u8(0x88))
	testing.expect_value(t, m.ram[int(frame_b) + 0x003], u8(0x11))
}

@(test)
test_mmu_tlb_hits_and_invlpg :: proc(t: ^testing.T) {
	m := test_machine_create(4 * 1024 * 1024)
	defer test_machine_destroy(&m)

	f1 := test_alloc_frame(&m)
	f2 := test_alloc_frame(&m)
	test_map_4k_page(&m, 0x8000, f1, PAGE_PRESENT | PAGE_WRITE | PAGE_USER)

	tlb: Software_Tlb

	// First read misses TLB, second read hits TLB.
	r1 := translate_virtual_address(&tlb, m.ram, m.cr3, 0x8010, .User, .Read)
	testing.expect_value(t, r1.status, Memory_Translation_Status.Ok)
	testing.expect_value(t, r1.physical_address, f1 + 0x10)
	testing.expect_value(t, tlb.misses, u64(1))
	testing.expect_value(t, tlb.hits, u64(0))

	r2 := translate_virtual_address(&tlb, m.ram, m.cr3, 0x8020, .User, .Read)
	testing.expect_value(t, r2.physical_address, f1 + 0x20)
	testing.expect_value(t, tlb.hits, u64(1))

	// Remap PTE to f2 without invlpg -> TLB still serves f1.
	test_map_4k_page(&m, 0x8000, f2, PAGE_PRESENT | PAGE_WRITE | PAGE_USER)
	r_stale := translate_virtual_address(&tlb, m.ram, m.cr3, 0x8030, .User, .Read)
	testing.expect_value(t, r_stale.physical_address, f1 + 0x30)
	testing.expect_value(t, tlb.hits, u64(2))

	// invlpg invalidates 0x8000 -> next walk sees f2.
	tlb_flush_page(&tlb, 0x8000)
	r_fresh := translate_virtual_address(&tlb, m.ram, m.cr3, 0x8030, .User, .Read)
	testing.expect_value(t, r_fresh.physical_address, f2 + 0x30)
	testing.expect_value(t, tlb.misses, u64(2))

	// Verify 2 MiB large-page invlpg clears cached subpages across the whole 2 MiB range.
	large_phys := u64(2 * 1024 * 1024)
	test_map_2m_page(&m, 0x4000_0000, large_phys, PAGE_PRESENT | PAGE_WRITE | PAGE_USER)
	_ = translate_virtual_address(&tlb, m.ram, m.cr3, 0x4000_0000, .User, .Read)
	_ = translate_virtual_address(&tlb, m.ram, m.cr3, 0x4000_5000, .User, .Read)
	testing.expect(t, tlb.has_large_page_entries)

	tlb_flush_page(&tlb, 0x4000_9000)
	testing.expect(t, !tlb.has_large_page_entries)

	// Full TLB flush clears all entries.
	_ = translate_virtual_address(&tlb, m.ram, m.cr3, 0x8000, .User, .Read)
	misses_before := tlb.misses
	tlb_flush_all(&tlb)
	_ = translate_virtual_address(&tlb, m.ram, m.cr3, 0x8000, .User, .Read)
	testing.expect_value(t, tlb.misses, misses_before + 1)
}

@(test)
test_cpu_factorial_loop :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)

	code_frame := test_alloc_frame(&m)
	stack_frame := test_alloc_frame(&m)
	code_va := u64(0x0000_0000_0040_0000)
	stack_va := u64(0x0000_0000_0050_0000)

	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, stack_va, stack_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)

	// Compute 10! = 3628800 in RAX:
	//   00: 48 C7 C0 01 00 00 00   mov rax, 1
	//   07: 48 C7 C1 0A 00 00 00   mov rcx, 10
	// loop (0E):
	//   0E: 48 0F AF C1            imul rax, rcx
	//   12: 48 FF C9               dec rcx
	//   15: 48 83 F9 01            cmp rcx, 1
	//   19: 7F F3                  jg loop (-13 -> 0E)
	//   1B: 0F 05                  syscall
	code := [?]u8 {
		0x48, 0xC7, 0xC0, 0x01, 0x00, 0x00, 0x00,
		0x48, 0xC7, 0xC1, 0x0A, 0x00, 0x00, 0x00,
		0x48, 0x0F, 0xAF, 0xC1,
		0x48, 0xFF, 0xC9,
		0x48, 0x83, 0xF9, 0x01,
		0x7F, 0xF3,
		0x0F, 0x05,
	}
	test_load_code(&m, code_frame, code[:])

	cpu: Processor_State
	processor_init(&cpu, m.cr3, code_va, stack_va + PAGE_SIZE)

	outcome := processor_run(&cpu, m.ram, 500)
	testing.expect_value(t, outcome, Step_Outcome.Syscall)
	testing.expect_value(t, cpu.registers[int(General_Register.Rax)], u64(3_628_800))
	testing.expect_value(t, cpu.rip, code_va + u64(len(code)))
	testing.expect_value(t, cpu.registers[int(General_Register.Rcx)], code_va + u64(len(code)))
}

@(test)
test_cpu_recursive_fibonacci_and_indirect_call :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)

	code_frame := test_alloc_frame(&m)
	stack_frame := test_alloc_frame(&m)
	code_va := u64(0x0000_0000_0040_0000)
	stack_va := u64(0x0000_0000_0050_0000)
	initial_rsp := stack_va + PAGE_SIZE

	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, stack_va, stack_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)

	// Entry (0x00):
	//   00: BF 0A 00 00 00         mov edi, 10
	//   05: 48 8D 05 04 00 00 00   lea rax, [rip + 4]   ; 0x0C + 4 = 0x10 (fib)
	//   0C: FF D0                  call rax             ; indirect call!
	//   0E: 0F 05                  syscall
	// fib (0x10):
	//   10: 55                     push rbp
	//   11: 48 89 E5               mov rbp, rsp
	//   14: 53                     push rbx
	//   15: 41 54                  push r12
	//   17: 48 83 FF 01            cmp rdi, 1
	//   1B: 7F 05                  jg recurse (+5 -> 0x22)
	//   1D: 48 89 F8               mov rax, rdi
	//   20: EB 19                  jmp done (+25 -> 0x3B)
	// recurse (0x22):
	//   22: 49 89 FC               mov r12, rdi
	//   25: 48 83 EF 01            sub rdi, 1
	//   29: E8 E2 FF FF FF         call fib (-30 -> 0x10)
	//   2E: 48 89 C3               mov rbx, rax
	//   31: 4C 8D 7C 24 00         ; unused, instead:
	//   31: 49 8D 7C 24 FE         ; wait: r12 - 2 -> lea rdi, [r12 - 2] = 49 8D 7C 24 FE? No, 49 8D 7C 24 is [r12+disp8]!
	// Let's use clean instructions with exact offsets:
	//   31: 4C 89 E7               mov rdi, r12
	//   34: 48 83 EF 02            sub rdi, 2
	//   38: E8 D3 FF FF FF         call fib (0x3D - 45 = 0x10)
	//   3D: 48 01 D8               add rax, rbx
	// done (0x40):
	//   40: 41 5C                  pop r12
	//   42: 5B                     pop rbx
	//   43: C9                     leave
	//   44: C3                     ret
	// Re-check jmp done at 0x20: next_rip = 0x22, target = 0x40 -> rel8 = +0x1E (30).
	code := [?]u8 {
		0xBF, 0x0A, 0x00, 0x00, 0x00,
		0x48, 0x8D, 0x05, 0x04, 0x00, 0x00, 0x00,
		0xFF, 0xD0,
		0x0F, 0x05,
		// 0x10: fib
		0x55,
		0x48, 0x89, 0xE5,
		0x53,
		0x41, 0x54,
		0x48, 0x83, 0xFF, 0x01,
		0x7F, 0x05,
		0x48, 0x89, 0xF8,
		0xEB, 0x1E,
		// 0x22: recurse
		0x49, 0x89, 0xFC,
		0x48, 0x83, 0xEF, 0x01,
		0xE8, 0xE2, 0xFF, 0xFF, 0xFF,
		0x48, 0x89, 0xC3,
		0x4C, 0x89, 0xE7,
		0x48, 0x83, 0xEF, 0x02,
		0xE8, 0xD3, 0xFF, 0xFF, 0xFF,
		0x48, 0x01, 0xD8,
		// 0x40: done
		0x41, 0x5C,
		0x5B,
		0xC9,
		0xC3,
	}
	test_load_code(&m, code_frame, code[:])

	cpu: Processor_State
	processor_init(&cpu, m.cr3, code_va, initial_rsp)

	outcome := processor_run(&cpu, m.ram, 50_000)
	testing.expect_value(t, outcome, Step_Outcome.Syscall)
	testing.expect_value(t, cpu.registers[int(General_Register.Rax)], u64(55))
	testing.expect_value(t, cpu.registers[int(General_Register.Rsp)], initial_rsp)
}

@(test)
test_cpu_gs_base_thread_record_and_rip_relative_immediate :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)

	code_frame := test_alloc_frame(&m)
	tls_frame := test_alloc_frame(&m)
	code_va := u64(0x0000_0000_0040_0000)
	tls_va := u64(0x0000_0000_0070_0000)

	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, tls_va, tls_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)

	// Populate thread record at gs_base + 0 and gs_base + 16.
	byte_order.write_u64_little_endian(m.ram, int(tls_frame), 0x1234_5678_9ABC_DEF0)
	byte_order.write_u64_little_endian(m.ram, int(tls_frame) + 16, 0x0FED_CBA9_8765_4321)

	// Store a constant qword 0x42 at code_va + 0x40 for RIP-relative cmp with imm8.
	byte_order.write_u64_little_endian(m.ram, int(code_frame) + 0x40, 0x42)

	// 00: 65 48 8B 04 25 00 00 00 00   mov rax, qword ptr [gs:0]
	// 09: 65 48 8B 1C 25 10 00 00 00   mov rbx, qword ptr [gs:16]
	// 12: 48 83 3D 26 00 00 00 42      cmp qword ptr [rip + 0x26], 0x42  (next_rip = 0x1A; 0x1A + 0x26 = 0x40!)
	// 1A: 0F 94 C1                     sete cl
	// 1D: 0F 05                        syscall
	code := [?]u8 {
		0x65, 0x48, 0x8B, 0x04, 0x25, 0x00, 0x00, 0x00, 0x00,
		0x65, 0x48, 0x8B, 0x1C, 0x25, 0x10, 0x00, 0x00, 0x00,
		0x48, 0x83, 0x3D, 0x26, 0x00, 0x00, 0x00, 0x42,
		0x0F, 0x94, 0xC1,
		0x0F, 0x05,
	}
	test_load_code(&m, code_frame, code[:])

	cpu: Processor_State
	processor_init(&cpu, m.cr3, code_va, 0, tls_va)

	outcome := processor_run(&cpu, m.ram, 50)
	testing.expect_value(t, outcome, Step_Outcome.Syscall)
	testing.expect_value(t, cpu.registers[int(General_Register.Rax)], u64(0x1234_5678_9ABC_DEF0))
	testing.expect_value(t, cpu.registers[int(General_Register.Rbx)], u64(0x0FED_CBA9_8765_4321))
	testing.expect(t, (cpu.rflags & RFLAGS_ZF) != 0, "RIP-relative CMP with trailing imm8 must resolve against post-immediate RIP")
}

@(test)
test_cpu_syscall_trap_and_resume :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)

	code_frame := test_alloc_frame(&m)
	code_va := u64(0x0000_0000_0040_0000)
	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)

	// 00: B8 07 00 00 00   mov eax, 7
	// 05: BF 2A 00 00 00   mov edi, 42
	// 0A: 0F 05            syscall
	// 0C: 48 83 C0 01      add rax, 1
	// 10: CC               int3
	code := [?]u8 {
		0xB8, 0x07, 0x00, 0x00, 0x00,
		0xBF, 0x2A, 0x00, 0x00, 0x00,
		0x0F, 0x05,
		0x48, 0x83, 0xC0, 0x01,
		0xCC,
	}
	test_load_code(&m, code_frame, code[:])

	cpu: Processor_State
	processor_init(&cpu, m.cr3, code_va, 0)

	// First run traps on syscall.
	o1 := processor_run(&cpu, m.ram, 20)
	testing.expect_value(t, o1, Step_Outcome.Syscall)
	testing.expect_value(t, cpu.registers[int(General_Register.Rax)], u64(7))
	testing.expect_value(t, cpu.registers[int(General_Register.Rdi)], u64(42))
	testing.expect_value(t, cpu.rip, code_va + 0x0C)
	testing.expect_value(t, cpu.syscall_return_rip, code_va + 0x0C)

	// Kernel services syscall, writes return value into RAX, and resumes thread.
	cpu.registers[int(General_Register.Rax)] = 0xCAFE
	o2 := processor_run(&cpu, m.ram, 20)
	testing.expect_value(t, o2, Step_Outcome.Breakpoint)
	testing.expect_value(t, cpu.registers[int(General_Register.Rax)], u64(0xCAFF))
	testing.expect_value(t, cpu.rip, code_va + 0x11)
}

@(test)
test_cpu_rep_stosb_movsb_and_step_budget :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)

	code_frame := test_alloc_frame(&m)
	buf_frame := test_alloc_frame(&m)
	code_va := u64(0x0000_0000_0040_0000)
	buf_va := u64(0x0000_0000_0060_0000)

	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, buf_va, buf_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)

	// 00: FC                     cld
	// 01: B0 5A                  mov al, 0x5A
	// 03: BF 00 00 60 00         mov edi, 0x600000
	// 08: B9 20 00 00 00         mov ecx, 32
	// 0D: F3 AA                  rep stosb
	// 0F: BE 00 00 60 00         mov esi, 0x600000
	// 14: BF 40 00 60 00         mov edi, 0x600040
	// 19: B9 20 00 00 00         mov ecx, 32
	// 1E: F3 A4                  rep movsb
	// 20: 0F 05                  syscall
	code := [?]u8 {
		0xFC,
		0xB0, 0x5A,
		0xBF, 0x00, 0x00, 0x60, 0x00,
		0xB9, 0x20, 0x00, 0x00, 0x00,
		0xF3, 0xAA,
		0xBE, 0x00, 0x00, 0x60, 0x00,
		0xBF, 0x40, 0x00, 0x60, 0x00,
		0xB9, 0x20, 0x00, 0x00, 0x00,
		0xF3, 0xA4,
		0x0F, 0x05,
	}
	test_load_code(&m, code_frame, code[:])

	cpu: Processor_State
	processor_init(&cpu, m.cr3, code_va, 0)

	outcome := processor_run(&cpu, m.ram, 200)
	testing.expect_value(t, outcome, Step_Outcome.Syscall)
	for i in 0 ..< 32 {
		testing.expect_value(t, m.ram[int(buf_frame) + i], u8(0x5A))
		testing.expect_value(t, m.ram[int(buf_frame) + 0x40 + i], u8(0x5A))
	}
	testing.expect_value(t, m.ram[int(buf_frame) + 0x40 + 32], u8(0x00))

	// Adversarial REP STOSB with huge RCX must be bounded strictly by max_steps.
	rep_code := [?]u8{0xF3, 0xAA}
	test_load_code(&m, code_frame, rep_code[:])
	processor_init(&cpu, m.cr3, code_va, 0)
	cpu.registers[int(General_Register.Rax)] = 0x77
	cpu.registers[int(General_Register.Rdi)] = buf_va + 0x100
	cpu.registers[int(General_Register.Rcx)] = 1_000_000

	o_budget := processor_run(&cpu, m.ram, 10)
	testing.expect_value(t, o_budget, Step_Outcome.Step_Budget_Exhausted)
	testing.expect_value(t, cpu.registers[int(General_Register.Rcx)], u64(999_990))
	testing.expect_value(t, cpu.rip, code_va)
	testing.expect_value(t, m.ram[int(buf_frame) + 0x109], u8(0x77))
	testing.expect_value(t, m.ram[int(buf_frame) + 0x10A], u8(0x00))
}

@(test)
test_cpu_sse2_pcmpeqb_pmovmskb_and_alignment :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)

	code_frame := test_alloc_frame(&m)
	data_frame := test_alloc_frame(&m)
	code_va := u64(0x0000_0000_0040_0000)
	data_va := u64(0x0000_0000_0080_0000)

	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, data_va, data_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)

	// Place two 16-byte vectors at data_va+0x00 and data_va+0x10 that match at
	// indices 0, 3, 7, 15 -> expected mask = (1<<0)|(1<<3)|(1<<7)|(1<<15) = 0x8089.
	vec_a := [16]u8{10, 1, 2, 30, 4, 5, 6, 70, 8, 9, 10, 11, 12, 13, 14, 99}
	vec_b := [16]u8{10, 9, 9, 30, 9, 9, 9, 70, 9, 99, 99, 99, 99, 99, 99, 99}
	for i in 0 ..< 16 {
		m.ram[int(data_frame) + i] = vec_a[i]
		m.ram[int(data_frame) + 16 + i] = vec_b[i]
	}

	// 00: F3 0F 6F 07       movdqu xmm0, [rdi]
	// 04: 66 0F 6F 4F 10    movdqa xmm1, [rdi + 16]
	// 09: 66 0F EF D2       pxor xmm2, xmm2
	// 0D: 66 0F 74 C1       pcmpeqb xmm0, xmm1
	// 11: 66 0F D7 C0       pmovmskb eax, xmm0
	// 15: F3 0F 7F 47 20    movdqu [rdi + 32], xmm0
	// 1A: 0F 05             syscall
	code := [?]u8 {
		0xF3, 0x0F, 0x6F, 0x07,
		0x66, 0x0F, 0x6F, 0x4F, 0x10,
		0x66, 0x0F, 0xEF, 0xD2,
		0x66, 0x0F, 0x74, 0xC1,
		0x66, 0x0F, 0xD7, 0xC0,
		0xF3, 0x0F, 0x7F, 0x47, 0x20,
		0x0F, 0x05,
	}
	test_load_code(&m, code_frame, code[:])

	cpu: Processor_State
	processor_init(&cpu, m.cr3, code_va, 0)
	cpu.registers[int(General_Register.Rdi)] = data_va
	cpu.registers[int(General_Register.Rax)] = max(u64) // Confirm pmovmskb clears upper 48 bits.
	for i in 0 ..< 16 {
		cpu.xmm[2][i] = 0xFF
	}

	outcome := processor_run(&cpu, m.ram, 50)
	testing.expect_value(t, outcome, Step_Outcome.Syscall)
	testing.expect_value(t, cpu.registers[int(General_Register.Rax)], u64(0x8089))
	for i in 0 ..< 16 {
		testing.expect_value(t, cpu.xmm[2][i], u8(0))
	}
	testing.expect_value(t, m.ram[int(data_frame) + 32 + 0], u8(0xFF))
	testing.expect_value(t, m.ram[int(data_frame) + 32 + 1], u8(0x00))
	testing.expect_value(t, m.ram[int(data_frame) + 32 + 15], u8(0xFF))

	// Unaligned movdqa must raise General_Protection without advancing RIP.
	unaligned_code := [?]u8{0x66, 0x0F, 0x6F, 0x07} // movdqa xmm0, [rdi]
	test_load_code(&m, code_frame, unaligned_code[:])
	processor_init(&cpu, m.cr3, code_va, 0)
	cpu.registers[int(General_Register.Rdi)] = data_va + 1
	o_unaligned := processor_step(&cpu, m.ram)
	testing.expect_value(t, o_unaligned, Step_Outcome.General_Protection)
	testing.expect_value(t, cpu.rip, code_va)
}

@(test)
test_cpu_arithmetic_shifts_div_cmov_and_partial_regs :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)

	code_frame := test_alloc_frame(&m)
	code_va := u64(0x0000_0000_0040_0000)
	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)

	// Test 64-bit signed division (-100 / 7 == -14 rem -2), sar, shl, cmovne, movsxd, movzx:
	//   00: 48 C7 C0 9C FF FF FF   mov rax, -100
	//   07: 48 99                  cqo
	//   09: 48 C7 C3 07 00 00 00   mov rbx, 7
	//   10: 48 F7 FB               idiv rbx            ; rax = -14, rdx = -2
	//   13: 48 89 C6               mov rsi, rax        ; rsi = -14
	//   16: 48 C1 FE 01            sar rsi, 1          ; rsi = -7
	//   1A: B1 03                  mov cl, 3
	//   1C: 48 D3 E6               shl rsi, cl         ; rsi = -56
	//   1F: 48 89 F7               mov rdi, rsi
	//   22: 48 F7 DF               neg rdi             ; rdi = 56
	//   25: 48 83 FF 38            cmp rdi, 56         ; ZF = 1
	//   29: 49 C7 C0 77 00 00 00   mov r8, 0x77
	//   30: 49 C7 C1 88 00 00 00   mov r9, 0x88
	//   37: 4D 0F 44 C1            cmove r8, r9        ; taken -> r8 = 0x88
	//   3B: 48 B9 80 00 00 00 00 00 00 00  movabs rcx, 0x80
	//   45: 48 0F BE D1            movsx rdx, cl       ; rdx = -128
	//   49: 4C 0F B6 D1            movzx r10, cl       ; r10 = 128
	//   4D: 0F 05                  syscall
	code := [?]u8 {
		0x48, 0xC7, 0xC0, 0x9C, 0xFF, 0xFF, 0xFF,
		0x48, 0x99,
		0x48, 0xC7, 0xC3, 0x07, 0x00, 0x00, 0x00,
		0x48, 0xF7, 0xFB,
		0x48, 0x89, 0xC6,
		0x48, 0xC1, 0xFE, 0x01,
		0xB1, 0x03,
		0x48, 0xD3, 0xE6,
		0x48, 0x89, 0xF7,
		0x48, 0xF7, 0xDF,
		0x48, 0x83, 0xFF, 0x38,
		0x49, 0xC7, 0xC0, 0x77, 0x00, 0x00, 0x00,
		0x49, 0xC7, 0xC1, 0x88, 0x00, 0x00, 0x00,
		0x4D, 0x0F, 0x44, 0xC1,
		0x48, 0xB9, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x48, 0x0F, 0xBE, 0xD1,
		0x4C, 0x0F, 0xB6, 0xD1,
		0x0F, 0x05,
	}
	test_load_code(&m, code_frame, code[:])

	cpu: Processor_State
	processor_init(&cpu, m.cr3, code_va, 0)

	outcome := processor_run(&cpu, m.ram, 100)
	testing.expect_value(t, outcome, Step_Outcome.Syscall)
	testing.expect_value(t, i64(cpu.registers[int(General_Register.Rax)]), i64(-14))
	testing.expect_value(t, i64(cpu.registers[int(General_Register.Rsi)]), i64(-56))
	testing.expect_value(t, cpu.registers[int(General_Register.Rdi)], u64(56))
	testing.expect_value(t, cpu.registers[int(General_Register.R8)], u64(0x88))
	testing.expect_value(t, i64(cpu.registers[int(General_Register.Rdx)]), i64(-128))
	testing.expect_value(t, cpu.registers[int(General_Register.R10)], u64(128))

	// Divide by zero must raise Divide_Error without advancing RIP.
	div_zero := [?]u8{0x48, 0xF7, 0xF3} // div rbx
	test_load_code(&m, code_frame, div_zero[:])
	processor_init(&cpu, m.cr3, code_va, 0)
	cpu.registers[int(General_Register.Rax)] = 10
	cpu.registers[int(General_Register.Rbx)] = 0
	testing.expect_value(t, processor_step(&cpu, m.ram), Step_Outcome.Divide_Error)
	testing.expect_value(t, cpu.rip, code_va)
}

@(test)
test_cpu_hostile_isolation_faults_and_budget :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)

	code_frame := test_alloc_frame(&m)
	nx_frame := test_alloc_frame(&m)
	ro_frame := test_alloc_frame(&m)
	kernel_frame := test_alloc_frame(&m)

	code_va := u64(0x0000_0000_0040_0000)
	nx_va := u64(0x0000_0000_0041_0000)
	ro_va := u64(0x0000_0000_0042_0000)
	kernel_va := u64(0xFFFF_8000_0000_0000)

	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, nx_va, nx_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	test_map_4k_page(&m, ro_va, ro_frame, PAGE_PRESENT | PAGE_USER | PAGE_NO_EXECUTE)
	test_map_4k_page(&m, kernel_va, kernel_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_NO_EXECUTE, PAGE_PRESENT | PAGE_WRITE)

	m.ram[int(nx_frame)] = 0x90 // nop inside NX page
	byte_order.write_u64_little_endian(m.ram, int(ro_frame), 0xDEAD_BEEF_CAFE_BABE)
	byte_order.write_u64_little_endian(m.ram, int(kernel_frame), 0x5EC4_E700_0000_0001)

	cpu: Processor_State

	// 1. Hostile jump to NX page -> exact Page_Fault (P | U | I) at nx_va.
	jump_nx := [?]u8{0xFF, 0xE0} // jmp rax
	test_load_code(&m, code_frame, jump_nx[:])
	processor_init(&cpu, m.cr3, code_va, 0)
	cpu.registers[int(General_Register.Rax)] = nx_va
	o_nx := processor_run(&cpu, m.ram, 10)
	testing.expect_value(t, o_nx, Step_Outcome.Page_Fault)
	testing.expect_value(t, cpu.rip, nx_va)
	testing.expect_value(t, cpu.fault_address, nx_va)
	testing.expect_value(t, cpu.fault_error_code, PAGE_FAULT_PRESENT | PAGE_FAULT_USER | PAGE_FAULT_INSTRUCTION)

	// 2. Hostile write to read-only page -> Page_Fault (P | W | U), RIP and RO page unchanged.
	write_ro := [?]u8{0x48, 0x89, 0x07} // mov [rdi], rax
	test_load_code(&m, code_frame, write_ro[:])
	processor_init(&cpu, m.cr3, code_va, 0)
	cpu.registers[int(General_Register.Rdi)] = ro_va
	cpu.registers[int(General_Register.Rax)] = 0x1111_2222_3333_4444
	o_ro := processor_step(&cpu, m.ram)
	testing.expect_value(t, o_ro, Step_Outcome.Page_Fault)
	testing.expect_value(t, cpu.rip, code_va)
	testing.expect_value(t, cpu.fault_address, ro_va)
	testing.expect_value(t, cpu.fault_error_code, PAGE_FAULT_PRESENT | PAGE_FAULT_WRITE | PAGE_FAULT_USER)
	testing.expect_value(t, byte_order.read_u64_little_endian(m.ram, int(ro_frame)), u64(0xDEAD_BEEF_CAFE_BABE))

	// 3. Unprivileged read of supervisor page -> Page_Fault (P | U), secret never loaded.
	read_kernel := [?]u8{0x48, 0x8B, 0x07} // mov rax, [rdi]
	test_load_code(&m, code_frame, read_kernel[:])
	processor_init(&cpu, m.cr3, code_va, 0)
	cpu.registers[int(General_Register.Rdi)] = kernel_va
	o_kern := processor_step(&cpu, m.ram)
	testing.expect_value(t, o_kern, Step_Outcome.Page_Fault)
	testing.expect_value(t, cpu.rip, code_va)
	testing.expect_value(t, cpu.fault_error_code, PAGE_FAULT_PRESENT | PAGE_FAULT_USER)
	testing.expect_value(t, cpu.registers[int(General_Register.Rax)], u64(0))

	// 4. Hostile push onto read-only stack -> Page_Fault, RSP unchanged.
	push_rax := [?]u8{0x50}
	test_load_code(&m, code_frame, push_rax[:])
	processor_init(&cpu, m.cr3, code_va, ro_va + 16)
	o_push := processor_step(&cpu, m.ram)
	testing.expect_value(t, o_push, Step_Outcome.Page_Fault)
	testing.expect_value(t, cpu.registers[int(General_Register.Rsp)], ro_va + 16)
	testing.expect_value(t, cpu.rip, code_va)

	// 5. Privileged and invalid opcodes (HLT, CLI, INSB, UD2) -> Invalid_Opcode.
	for bad_insn in ([][]u8{{0xF4}, {0xFA}, {0x6C}, {0x0F, 0x0B}}) {
		test_load_code(&m, code_frame, bad_insn)
		processor_init(&cpu, m.cr3, code_va, 0)
		testing.expect_value(t, processor_step(&cpu, m.ram), Step_Outcome.Invalid_Opcode)
		testing.expect_value(t, cpu.rip, code_va)
	}

	// 6. Infinite loop (`EB FE`) bounded by max_steps; max_steps == 0 runs zero steps.
	inf_loop := [?]u8{0xEB, 0xFE}
	test_load_code(&m, code_frame, inf_loop[:])
	processor_init(&cpu, m.cr3, code_va, 0)
	testing.expect_value(t, processor_run(&cpu, m.ram, 0), Step_Outcome.Step_Budget_Exhausted)
	testing.expect_value(t, cpu.steps_executed, u64(0))

	testing.expect_value(t, processor_run(&cpu, m.ram, 37), Step_Outcome.Step_Budget_Exhausted)
	testing.expect_value(t, cpu.steps_executed, u64(37))
	testing.expect_value(t, cpu.rip, code_va)

	// 7. Overlong instruction (>15 prefix bytes) -> General_Protection.
	long_prefixes: [16]u8
	for &b in long_prefixes {
		b = 0x66
	}
	test_load_code(&m, code_frame, long_prefixes[:])
	processor_init(&cpu, m.cr3, code_va, 0)
	testing.expect_value(t, processor_step(&cpu, m.ram), Step_Outcome.General_Protection)
	testing.expect_value(t, cpu.rip, code_va)
}

@(test)
test_browser_machine_config_border :: proc(t: ^testing.T) {
	// Enum border refusals on invalid transport words.
	_, ok_e0 := browser_engine_kind_from_word(0)
	testing.expect(t, !ok_e0)
	_, ok_e4 := browser_engine_kind_from_word(4)
	testing.expect(t, !ok_e4)
	_, ok_emax := browser_engine_kind_from_word(max(u64))
	testing.expect(t, !ok_emax)
	_, ok_m0 := execution_mode_from_word(0)
	testing.expect(t, !ok_m0)
	_, ok_r9 := relay_transport_kind_from_word(9)
	testing.expect(t, !ok_r9)

	// Non-isolated embed: automatic single-worker fallback, JSPI idle, no network by default.
	cfg := Browser_Machine_Config {
		cross_origin_isolated = false,
		engine_kind           = .Chromium_Desktop,
		hardware_threads      = 16,
		requested_processors  = 0,
		memory_bytes          = 64 << 20,
	}
	resolved, status := validate_browser_machine_config(cfg)
	testing.expect_value(t, status, Config_Validation_Status.Ok)
	testing.expect_value(t, resolved.execution_mode, Execution_Mode.Single_Worker_Fallback)
	testing.expect_value(t, resolved.processor_count, u32(1))
	testing.expect(t, !resolved.uses_shared_memory)
	testing.expect(t, resolved.uses_jspi_idle)
	testing.expect(t, !resolved.network_enabled)
	testing.expect_value(t, resolved.relay_transport, Relay_Transport_Kind.None)

	// Explicit multi-worker without cross-origin isolation is refused.
	cfg_bad_multi := cfg
	cfg_bad_multi.requested_processors = 2
	_, status_multi := validate_browser_machine_config(cfg_bad_multi)
	testing.expect_value(t, status_multi, Config_Validation_Status.Multi_Worker_Requires_Isolation)

	// Isolated Chromium, Firefox, Safari/Mobile default caps.
	cfg_iso := cfg
	cfg_iso.cross_origin_isolated = true
	res_chr, st_chr := validate_browser_machine_config(cfg_iso)
	testing.expect_value(t, st_chr, Config_Validation_Status.Ok)
	testing.expect_value(t, res_chr.execution_mode, Execution_Mode.Multi_Worker_Shared_Memory)
	testing.expect_value(t, res_chr.processor_count, u32(4))
	testing.expect(t, res_chr.uses_shared_memory)
	testing.expect(t, !res_chr.uses_jspi_idle)

	cfg_iso.engine_kind = .Firefox_Desktop
	res_ff, st_ff := validate_browser_machine_config(cfg_iso)
	testing.expect_value(t, st_ff, Config_Validation_Status.Ok)
	testing.expect_value(t, res_ff.processor_count, u32(2))

	cfg_iso.engine_kind = .Safari_Or_Mobile
	res_saf, st_saf := validate_browser_machine_config(cfg_iso)
	testing.expect_value(t, st_saf, Config_Validation_Status.Ok)
	testing.expect_value(t, res_saf.processor_count, u32(1))

	// Valid bring-your-own relay URLs (WebTransport https, secure wss, loopback ws).
	cfg_relay := cfg
	testing.expect(t, browser_machine_config_set_relay_url(&cfg_relay, "https://relay.example.org/link"))
	res_wt, st_wt := validate_browser_machine_config(cfg_relay)
	testing.expect_value(t, st_wt, Config_Validation_Status.Ok)
	testing.expect(t, res_wt.network_enabled)
	testing.expect_value(t, res_wt.relay_transport, Relay_Transport_Kind.WebTransport_Https)

	testing.expect(t, browser_machine_config_set_relay_url(&cfg_relay, "wss://relay.example.org:8443/v1"))
	res_wss, st_wss := validate_browser_machine_config(cfg_relay)
	testing.expect_value(t, st_wss, Config_Validation_Status.Ok)
	testing.expect_value(t, res_wss.relay_transport, Relay_Transport_Kind.WebSocket_Secure)

	testing.expect(t, browser_machine_config_set_relay_url(&cfg_relay, "ws://127.0.0.1:9000/test"))
	res_ws_lo, st_ws_lo := validate_browser_machine_config(cfg_relay)
	testing.expect_value(t, st_ws_lo, Config_Validation_Status.Ok)
	testing.expect_value(t, res_ws_lo.relay_transport, Relay_Transport_Kind.WebSocket_Loopback)

	// Adversarial relay URLs refused.
	testing.expect(t, browser_machine_config_set_relay_url(&cfg_relay, "ws://relay.example.org/link"))
	_, st_insec_ws := validate_browser_machine_config(cfg_relay)
	testing.expect_value(t, st_insec_ws, Config_Validation_Status.Insecure_Relay_Scheme)

	testing.expect(t, browser_machine_config_set_relay_url(&cfg_relay, "http://relay.example.org/link"))
	_, st_insec_http := validate_browser_machine_config(cfg_relay)
	testing.expect_value(t, st_insec_http, Config_Validation_Status.Insecure_Relay_Scheme)

	for bad_url in ([]string{"javascript:alert(1)", "https://user:pass@relay.example.org", "https://", "https://relay.example.org:0", "https://relay.example.org:99999", "https://relay.example.org/a b"}) {
		testing.expect(t, browser_machine_config_set_relay_url(&cfg_relay, bad_url))
		_, st_bad := validate_browser_machine_config(cfg_relay)
		testing.expect_value(t, st_bad, Config_Validation_Status.Invalid_Relay_Url)
	}

	// Relay URL past bound refused.
	cfg_over := cfg
	cfg_over.relay_url_length = MAX_RELAY_URL_BYTES + 1
	_, st_long := validate_browser_machine_config(cfg_over)
	testing.expect_value(t, st_long, Config_Validation_Status.Relay_Url_Too_Long)

	// Memory size edges: 0, below min, unaligned, >= 4 GiB, max(u64) refused; exact min/max accepted.
	for bad_mem in ([]u64{0, MIN_BROWSER_MEMORY_BYTES - PAGE_SIZE, MIN_BROWSER_MEMORY_BYTES + 1, u64(4) << 30, max(u64)}) {
		cfg_mem := cfg
		cfg_mem.memory_bytes = bad_mem
		_, st_mem := validate_browser_machine_config(cfg_mem)
		testing.expect_value(t, st_mem, Config_Validation_Status.Invalid_Memory_Size)
	}
	for good_mem in ([]u64{MIN_BROWSER_MEMORY_BYTES, MAX_BROWSER_MEMORY_BYTES}) {
		cfg_mem := cfg
		cfg_mem.memory_bytes = good_mem
		_, st_mem := validate_browser_machine_config(cfg_mem)
		testing.expect_value(t, st_mem, Config_Validation_Status.Ok)
	}

	// Zero hardware threads refused.
	cfg_hw0 := cfg
	cfg_hw0.hardware_threads = 0
	_, st_hw0 := validate_browser_machine_config(cfg_hw0)
	testing.expect_value(t, st_hw0, Config_Validation_Status.Invalid_Processor_Count)
}

@(test)
test_cpu_sib_partial_regs_inc_cf_and_cmov32_zero_extend :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)

	code_frame := test_alloc_frame(&m)
	data_frame := test_alloc_frame(&m)
	code_va := u64(0x0000_0000_0040_0000)
	data_va := u64(0x0000_0000_0090_0000)

	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, data_va, data_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)

	// Place u32 value -5 (0xFFFF_FFFB) at data_va + 3*4 + 8 = data_va + 20.
	byte_order.write_u32_little_endian(m.ram, int(data_frame) + 20, 0xFFFF_FFFB)

	// 00: 48 63 44 9F 08         movsxd rax, dword ptr [rdi + rbx*4 + 8]  ; rax = -5
	// 05: 48 C7 C1 01 00 00 00   mov rcx, 1
	// 0C: 48 83 E9 02            sub rcx, 2                               ; sets CF = 1, rcx = -1
	// 10: 48 FF C1               inc rcx                                  ; rcx = 0, ZF = 1, MUST preserve CF = 1!
	// 13: 0F 92 C2               setb dl                                  ; dl = 1 (from preserved CF)
	// 16: 0F 45 F0               cmovne esi, eax                          ; NOT taken (ZF=1), MUST still zero-extend upper 32 of rsi!
	// 19: B4 AB                  mov ah, 0xAB                             ; no REX -> writes AH (bits 8..15 of RAX)
	// 1B: 40 B7 34               mov dil, 0x34                            ; REX -> writes DIL (bits 0..7 of RDI), not BH
	// 1E: 48 87 C8               xchg rax, rcx                            ; swap rax and rcx
	// 21: CC                     int3
	code := [?]u8 {
		0x48, 0x63, 0x44, 0x9F, 0x08,
		0x48, 0xC7, 0xC1, 0x01, 0x00, 0x00, 0x00,
		0x48, 0x83, 0xE9, 0x02,
		0x48, 0xFF, 0xC1,
		0x0F, 0x92, 0xC2,
		0x0F, 0x45, 0xF0,
		0xB4, 0xAB,
		0x40, 0xB7, 0x34,
		0x48, 0x87, 0xC8,
		0xCC,
	}
	test_load_code(&m, code_frame, code[:])

	cpu: Processor_State
	processor_init(&cpu, m.cr3, code_va, 0)
	cpu.registers[int(General_Register.Rdi)] = data_va
	cpu.registers[int(General_Register.Rbx)] = 3
	cpu.registers[int(General_Register.Rsi)] = 0xDEAD_BEEF_1234_5678
	cpu.registers[int(General_Register.Rdx)] = 0

	outcome := processor_run(&cpu, m.ram, 50)
	testing.expect_value(t, outcome, Step_Outcome.Breakpoint)
	// Before xchg: rcx was 0, rax was (-5 with byte 1 replaced by 0xAB) = 0xFFFF_FFFF_FFFF_ABFB.
	testing.expect_value(t, cpu.registers[int(General_Register.Rax)], u64(0))
	testing.expect_value(t, cpu.registers[int(General_Register.Rcx)], u64(0xFFFF_FFFF_FFFF_ABFB))
	testing.expect_value(t, cpu.registers[int(General_Register.Rdx)], u64(1))
	testing.expect_value(t, cpu.registers[int(General_Register.Rsi)], u64(0x0000_0000_1234_5678))
	testing.expect_value(t, cpu.registers[int(General_Register.Rdi)], (data_va & ~u64(0xFF)) | 0x34)
	testing.expect_value(t, cpu.registers[int(General_Register.Rbx)], u64(3))
}

@(test)
test_cpu_straddling_sse2_atomic_store_fault :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)

	code_frame := test_alloc_frame(&m)
	rw_frame := test_alloc_frame(&m)
	ro_frame := test_alloc_frame(&m)
	code_va := u64(0x0000_0000_0040_0000)
	rw_va := u64(0x0000_0000_00A0_0000)
	ro_va := u64(0x0000_0000_00A0_1000)

	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, rw_va, rw_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	test_map_4k_page(&m, ro_va, ro_frame, PAGE_PRESENT | PAGE_USER | PAGE_NO_EXECUTE)

	for i in 0xFF0 ..< 0x1000 {
		m.ram[int(rw_frame) + i] = 0xCC
	}

	// F3 0F 7F 07: movdqu [rdi], xmm0
	code := [?]u8{0xF3, 0x0F, 0x7F, 0x07}
	test_load_code(&m, code_frame, code[:])

	cpu: Processor_State
	processor_init(&cpu, m.cr3, code_va, 0)
	cpu.registers[int(General_Register.Rdi)] = rw_va + 0xFF8 // Straddles 8 bytes in RW, 8 bytes in RO!
	for i in 0 ..< 16 {
		cpu.xmm[0][i] = u8(i + 1)
	}

	outcome := processor_step(&cpu, m.ram)
	testing.expect_value(t, outcome, Step_Outcome.Page_Fault)
	testing.expect_value(t, cpu.fault_address, ro_va)
	testing.expect_value(t, cpu.fault_error_code, PAGE_FAULT_PRESENT | PAGE_FAULT_WRITE | PAGE_FAULT_USER)
	testing.expect_value(t, cpu.rip, code_va)
	// Confirm zero bytes of rw_frame were touched.
	for i in 0xFF0 ..< 0x1000 {
		testing.expect_value(t, m.ram[int(rw_frame) + i], u8(0xCC))
	}
}

// A read-modify-write form whose memory write faults leaves the registers and
// the flags of before the instruction. The fuzz target software_machine found
// `add [rax-0x34], cl` into the code page changing the flags.
@(test)
test_cpu_read_modify_write_fault_keeps_registers_and_flags :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)

	code_frame := test_alloc_frame(&m)
	ro_frame := test_alloc_frame(&m)
	code_va := u64(0x0000_0000_0040_0000)
	ro_va := u64(0x0000_0000_00A0_0000)
	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, ro_va, ro_frame, PAGE_PRESENT | PAGE_USER | PAGE_NO_EXECUTE)
	for i in 0 ..< 16 {
		m.ram[int(ro_frame) + i] = 0x81
	}

	forms := [?][]u8 {
		{0x00, 0x08}, // add [rax], cl
		{0x48, 0x01, 0x08}, // add [rax], rcx
		{0x48, 0x83, 0x00, 0x01}, // add qword [rax], 1
		{0x48, 0xD1, 0x20}, // shl qword [rax], 1
		{0x48, 0xF7, 0x18}, // neg qword [rax]
		{0x48, 0xFF, 0x00}, // inc qword [rax]
		{0xFE, 0x08}, // dec byte [rax]
		{0x48, 0x0F, 0xC1, 0x08}, // xadd [rax], rcx
		{0x48, 0x0F, 0xB1, 0x08}, // cmpxchg [rax], rcx, with rax not equal to the memory: the write back faults
		{0x48, 0x87, 0x08}, // xchg [rax], rcx
	}
	flags_before := RFLAGS_RESERVED_ONE | RFLAGS_IF | RFLAGS_ZF | RFLAGS_PF
	for form in forms {
		test_load_code(&m, code_frame, form)
		cpu: Processor_State
		processor_init(&cpu, m.cr3, code_va, 0)
		cpu.registers[int(General_Register.Rax)] = ro_va
		cpu.registers[int(General_Register.Rcx)] = 0x7F
		cpu.rflags = flags_before
		registers_before := cpu.registers

		outcome := processor_step(&cpu, m.ram)
		testing.expectf(t, outcome == .Page_Fault, "%x: the outcome %v", form, outcome)
		testing.expectf(t, cpu.rflags == flags_before, "%x: the flags %x after the fault", form, cpu.rflags)
		testing.expectf(t, cpu.registers == registers_before, "%x: a register changed with the fault", form)
		testing.expectf(t, cpu.rip == code_va && cpu.steps_executed == 0, "%x: the place %x and %d steps after the fault", form, cpu.rip, cpu.steps_executed)
		testing.expect_value(t, cpu.fault_address, ro_va)
		testing.expect_value(t, cpu.fault_error_code, PAGE_FAULT_PRESENT | PAGE_FAULT_WRITE | PAGE_FAULT_USER)
		for i in 0 ..< 16 {
			testing.expect_value(t, m.ram[int(ro_frame) + i], u8(0x81))
		}
	}
}


// test_run_against_steps runs one machine twice from the same state: once
// in one call of processor_run, which moves the iterations of a repeated
// string form a page at a time, and once step by step, which moves one
// byte at each step. Both must give the same outcome, registers, place,
// count of steps, fault and memory. It gives the state of the run.
test_run_against_steps :: proc(t: ^testing.T, m: ^Test_Machine, start: Processor_State, budget: u64, location := #caller_location) -> (run: Processor_State, outcome: Step_Outcome) {
	stepped_memory := make([]u8, len(m.ram))
	defer delete(stepped_memory)
	copy(stepped_memory, m.ram)
	stepped := start
	stepped_outcome := Step_Outcome.Step_Budget_Exhausted
	for _ in 0 ..< budget {
		step_outcome := processor_step(&stepped, stepped_memory)
		if step_outcome != .Running {
			stepped_outcome = step_outcome
			break
		}
	}
	run = start
	outcome = processor_run(&run, m.ram, budget)
	testing.expect_value(t, outcome, stepped_outcome, loc = location)
	testing.expect(t, run.registers == stepped.registers, "the run and the steps leave other registers", loc = location)
	testing.expect_value(t, run.rip, stepped.rip, loc = location)
	testing.expect_value(t, run.rflags, stepped.rflags, loc = location)
	testing.expect_value(t, run.steps_executed, stepped.steps_executed, loc = location)
	testing.expect_value(t, run.fault_address, stepped.fault_address, loc = location)
	testing.expect_value(t, run.fault_error_code, stepped.fault_error_code, loc = location)
	first_difference := -1
	for byte, index in m.ram {
		if byte != stepped_memory[index] {
			first_difference = index
			break
		}
	}
	testing.expectf(t, first_difference == -1, "the run and the steps leave other memory at the physical address %x", first_difference, loc = location)
	return run, outcome
}

// The code of the tests of the repeated string forms: the form, then int3.
@(private = "file")
REP_MOVSB_CODE :: [?]u8{0xF3, 0xA4, 0xCC}
@(private = "file")
REP_STOSB_CODE :: [?]u8{0xF3, 0xAA, 0xCC}

// rep movsb that crosses a page of its destination, then faults on the
// third page, which is not present: the run stops at the exact iteration,
// with rcx, rsi and rdi of that iteration, and with no byte of the third
// page written.
@(test)
test_cpu_rep_movsb_crosses_pages_and_faults_at_the_exact_byte :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)
	code_frame := test_alloc_frame(&m)
	source_frame := test_alloc_frame(&m)
	destination_frames := [2]u64{test_alloc_frame(&m), test_alloc_frame(&m)}
	code_va := u64(0x40_0000)
	source_va := u64(0x60_0000)
	destination_va := u64(0x70_0000)
	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, source_va, source_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	test_map_4k_page(&m, destination_va, destination_frames[0], PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	test_map_4k_page(&m, destination_va + PAGE_SIZE, destination_frames[1], PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	// destination_va + 2 pages is not present.
	code := REP_MOVSB_CODE
	test_load_code(&m, code_frame, code[:])
	for i in 0 ..< int(PAGE_SIZE) {
		m.ram[int(source_frame) + i] = u8(i * 7 + 1)
	}

	// From 0x10 bytes before the end of the first destination page: 0x10
	// bytes, then a whole page, then the fault, with 0x30 iterations left.
	count := u64(0x10 + PAGE_SIZE + 0x30)
	start: Processor_State
	processor_init(&start, m.cr3, code_va, 0)
	start.registers[int(General_Register.Rsi)] = source_va
	start.registers[int(General_Register.Rdi)] = destination_va + PAGE_SIZE - 0x10
	start.registers[int(General_Register.Rcx)] = count
	// The source has one page: the fault of the destination comes first,
	// at the iteration whose source byte is 0x10 + PAGE_SIZE.
	test_map_4k_page(&m, source_va + PAGE_SIZE, source_frame, PAGE_PRESENT | PAGE_USER | PAGE_NO_EXECUTE)

	run, outcome := test_run_against_steps(t, &m, start, 100_000)
	testing.expect_value(t, outcome, Step_Outcome.Page_Fault)
	testing.expect_value(t, run.rip, code_va)
	testing.expect_value(t, run.registers[int(General_Register.Rcx)], u64(0x30))
	testing.expect_value(t, run.registers[int(General_Register.Rsi)], source_va + 0x10 + PAGE_SIZE)
	testing.expect_value(t, run.registers[int(General_Register.Rdi)], destination_va + 2 * PAGE_SIZE)
	testing.expect_value(t, run.steps_executed, 0x10 + PAGE_SIZE)
	testing.expect_value(t, run.fault_address, destination_va + 2 * PAGE_SIZE)
	testing.expect_value(t, run.fault_error_code, PAGE_FAULT_WRITE | PAGE_FAULT_USER)
	testing.expect_value(t, m.ram[int(destination_frames[0]) + int(PAGE_SIZE) - 0x10], u8(1))
	testing.expect_value(t, m.ram[int(destination_frames[0]) + int(PAGE_SIZE) - 0x11], u8(0))
	testing.expect_value(t, m.ram[int(destination_frames[1])], m.ram[int(source_frame) + 0x10])
	testing.expect(t, (test_read_pte(&m, destination_va + PAGE_SIZE) & PAGE_DIRTY) != 0, "the second destination page is dirty")

	// The budget ends inside a page: the run counts each iteration, and
	// stops at the budget with the instruction still to finish.
	budget_run, budget_outcome := test_run_against_steps(t, &m, start, 0x10 + 0x123)
	testing.expect_value(t, budget_outcome, Step_Outcome.Step_Budget_Exhausted)
	testing.expect_value(t, budget_run.steps_executed, 0x10 + 0x123)
	testing.expect_value(t, budget_run.registers[int(General_Register.Rcx)], count - 0x10 - 0x123)
	testing.expect_value(t, budget_run.rip, code_va)
}

// rep movsb whose source faults on its second page, which the user cannot
// read: the bytes of the first page move, and nothing after.
@(test)
test_cpu_rep_movsb_source_fault_on_the_second_page :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)
	code_frame := test_alloc_frame(&m)
	source_frames := [2]u64{test_alloc_frame(&m), test_alloc_frame(&m)}
	destination_frame := test_alloc_frame(&m)
	code_va := u64(0x40_0000)
	source_va := u64(0x60_0000)
	destination_va := u64(0x70_0000)
	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, source_va, source_frames[0], PAGE_PRESENT | PAGE_USER | PAGE_NO_EXECUTE)
	// A supervisor page: the user read faults with the present bit.
	test_map_4k_page(&m, source_va + PAGE_SIZE, source_frames[1], PAGE_PRESENT | PAGE_NO_EXECUTE)
	test_map_4k_page(&m, destination_va, destination_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	code := REP_MOVSB_CODE
	test_load_code(&m, code_frame, code[:])
	for i in 0 ..< 2 * int(PAGE_SIZE) {
		m.ram[int(source_frames[0]) + i] = 0xA0 | u8(i & 0x0F)
	}

	start: Processor_State
	processor_init(&start, m.cr3, code_va, 0)
	start.registers[int(General_Register.Rsi)] = source_va + PAGE_SIZE - 5
	start.registers[int(General_Register.Rdi)] = destination_va
	start.registers[int(General_Register.Rcx)] = 9
	run, outcome := test_run_against_steps(t, &m, start, 1000)
	testing.expect_value(t, outcome, Step_Outcome.Page_Fault)
	testing.expect_value(t, run.registers[int(General_Register.Rcx)], u64(4))
	testing.expect_value(t, run.registers[int(General_Register.Rsi)], source_va + PAGE_SIZE)
	testing.expect_value(t, run.registers[int(General_Register.Rdi)], destination_va + 5)
	testing.expect_value(t, run.fault_address, source_va + PAGE_SIZE)
	testing.expect_value(t, run.fault_error_code, PAGE_FAULT_PRESENT | PAGE_FAULT_USER)
	testing.expect_value(t, m.ram[int(destination_frame) + 4], 0xA0 | u8((int(PAGE_SIZE) - 1) & 0x0F))
	testing.expect_value(t, m.ram[int(destination_frame) + 5], u8(0))
}

// rep movsb whose destination starts inside its source, above it
// (rsi < rdi < rsi + rcx): each iteration reads a byte that an earlier one
// wrote, so the first bytes repeat. Then the destination below the source,
// and two virtual pages of one frame, where only the physical addresses
// show the overlap.
@(test)
test_cpu_rep_movsb_overlapping_ranges :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)
	code_frame := test_alloc_frame(&m)
	data_frame := test_alloc_frame(&m)
	code_va := u64(0x40_0000)
	data_va := u64(0x60_0000)
	alias_va := u64(0x80_0000)
	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, data_va, data_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	test_map_4k_page(&m, alias_va, data_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	code := REP_MOVSB_CODE
	test_load_code(&m, code_frame, code[:])
	fill :: proc(m: ^Test_Machine, frame: u64) {
		for i in 0 ..< int(PAGE_SIZE) {
			m.ram[int(frame) + i] = u8(i % 251)
		}
	}

	// The destination 3 bytes above the source: the 3 first bytes repeat.
	fill(&m, data_frame)
	start: Processor_State
	processor_init(&start, m.cr3, code_va, 0)
	start.registers[int(General_Register.Rsi)] = data_va + 0x100
	start.registers[int(General_Register.Rdi)] = data_va + 0x103
	start.registers[int(General_Register.Rcx)] = 0x400
	run, outcome := test_run_against_steps(t, &m, start, 100_000)
	testing.expect_value(t, outcome, Step_Outcome.Breakpoint)
	testing.expect_value(t, run.registers[int(General_Register.Rcx)], u64(0))
	for i in 0 ..< 0x403 {
		testing.expect_value(t, m.ram[int(data_frame) + 0x100 + i], u8((0x100 + i % 3) % 251))
	}
	testing.expect_value(t, m.ram[int(data_frame) + 0x503], u8(0x503 % 251))

	// The destination 0x40 bytes below the source: a move down.
	fill(&m, data_frame)
	start.registers[int(General_Register.Rsi)] = data_va + 0x240
	start.registers[int(General_Register.Rdi)] = data_va + 0x200
	start.registers[int(General_Register.Rcx)] = 0x300
	_, outcome = test_run_against_steps(t, &m, start, 100_000)
	testing.expect_value(t, outcome, Step_Outcome.Breakpoint)
	for i in 0 ..< 0x300 {
		testing.expect_value(t, m.ram[int(data_frame) + 0x200 + i], u8((0x240 + i) % 251))
	}

	// The source through one virtual page, the destination through the
	// other, one byte above it in the same frame: the virtual addresses are
	// 2 MiB apart, the physical ones overlap.
	fill(&m, data_frame)
	start.registers[int(General_Register.Rsi)] = alias_va + 0x10
	start.registers[int(General_Register.Rdi)] = data_va + 0x11
	start.registers[int(General_Register.Rcx)] = 0x80
	_, outcome = test_run_against_steps(t, &m, start, 100_000)
	testing.expect_value(t, outcome, Step_Outcome.Breakpoint)
	for i in 0 ..< 0x81 {
		testing.expect_value(t, m.ram[int(data_frame) + 0x10 + i], u8(0x10))
	}
}

// rep movsb and rep stosb with the direction flag set move down, one byte
// at each step, across a page border and into a fault.
@(test)
test_cpu_rep_string_forms_backward :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)
	code_frame := test_alloc_frame(&m)
	data_frames := [2]u64{test_alloc_frame(&m), test_alloc_frame(&m)}
	code_va := u64(0x40_0000)
	data_va := u64(0x60_1000)
	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, data_va, data_frames[0], PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	test_map_4k_page(&m, data_va + PAGE_SIZE, data_frames[1], PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	// data_va - PAGE_SIZE is not present.
	for i in 0 ..< 2 * int(PAGE_SIZE) {
		m.ram[int(data_frames[0]) + i] = u8(i % 239)
	}

	code := REP_MOVSB_CODE
	test_load_code(&m, code_frame, code[:])
	start: Processor_State
	processor_init(&start, m.cr3, code_va, 0)
	start.rflags |= RFLAGS_DF
	start.registers[int(General_Register.Rsi)] = data_va + PAGE_SIZE + 0x20
	start.registers[int(General_Register.Rdi)] = data_va + PAGE_SIZE + 0x40
	start.registers[int(General_Register.Rcx)] = 0x60
	run, outcome := test_run_against_steps(t, &m, start, 100_000)
	testing.expect_value(t, outcome, Step_Outcome.Breakpoint)
	testing.expect_value(t, run.registers[int(General_Register.Rsi)], data_va + PAGE_SIZE + 0x20 - 0x60)
	testing.expect_value(t, run.registers[int(General_Register.Rdi)], data_va + PAGE_SIZE + 0x40 - 0x60)
	// The iterations, then int3.
	testing.expect_value(t, run.steps_executed, u64(0x60 + 1))

	stores := REP_STOSB_CODE
	test_load_code(&m, code_frame, stores[:])
	processor_init(&start, m.cr3, code_va, 0)
	start.rflags |= RFLAGS_DF
	start.registers[int(General_Register.Rax)] = 0x3C
	start.registers[int(General_Register.Rdi)] = data_va + 0x8
	start.registers[int(General_Register.Rcx)] = 0x20
	run, outcome = test_run_against_steps(t, &m, start, 100_000)
	testing.expect_value(t, outcome, Step_Outcome.Page_Fault)
	testing.expect_value(t, run.registers[int(General_Register.Rcx)], u64(0x20 - 9))
	testing.expect_value(t, run.registers[int(General_Register.Rdi)], data_va - 1)
	testing.expect_value(t, run.fault_address, data_va - 1)
	testing.expect_value(t, m.ram[int(data_frames[0])], u8(0x3C))
}

// rep stosb across a page into a page that the user cannot write: the run
// fills up to the border, then faults with the exact rcx and rdi.
@(test)
test_cpu_rep_stosb_faults_on_a_read_only_second_page :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)
	code_frame := test_alloc_frame(&m)
	data_frames := [2]u64{test_alloc_frame(&m), test_alloc_frame(&m)}
	code_va := u64(0x40_0000)
	data_va := u64(0x60_0000)
	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, data_va, data_frames[0], PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	test_map_4k_page(&m, data_va + PAGE_SIZE, data_frames[1], PAGE_PRESENT | PAGE_USER | PAGE_NO_EXECUTE)
	code := REP_STOSB_CODE
	test_load_code(&m, code_frame, code[:])

	start: Processor_State
	processor_init(&start, m.cr3, code_va, 0)
	start.registers[int(General_Register.Rax)] = 0x1234_5678_9ABC_DE5A
	start.registers[int(General_Register.Rdi)] = data_va + 0x10
	start.registers[int(General_Register.Rcx)] = max(u64)
	run, outcome := test_run_against_steps(t, &m, start, 1_000_000)
	testing.expect_value(t, outcome, Step_Outcome.Page_Fault)
	testing.expect_value(t, run.rip, code_va)
	testing.expect_value(t, run.registers[int(General_Register.Rcx)], max(u64) - (PAGE_SIZE - 0x10))
	testing.expect_value(t, run.registers[int(General_Register.Rdi)], data_va + PAGE_SIZE)
	testing.expect_value(t, run.fault_error_code, PAGE_FAULT_PRESENT | PAGE_FAULT_WRITE | PAGE_FAULT_USER)
	testing.expect_value(t, m.ram[int(data_frames[0]) + 0xF], u8(0))
	testing.expect_value(t, m.ram[int(data_frames[0]) + 0x10], u8(0x5A))
	testing.expect_value(t, m.ram[int(data_frames[0]) + int(PAGE_SIZE) - 1], u8(0x5A))
	testing.expect_value(t, m.ram[int(data_frames[1])], u8(0))

	// A count of 1 and a budget of 1: the edges of the chunk.
	start.registers[int(General_Register.Rcx)] = 1
	run, outcome = test_run_against_steps(t, &m, start, 1)
	testing.expect_value(t, outcome, Step_Outcome.Step_Budget_Exhausted)
	testing.expect_value(t, run.registers[int(General_Register.Rcx)], u64(0))
	testing.expect_value(t, run.rip, code_va + 2)
	start.registers[int(General_Register.Rcx)] = 0
	run, outcome = test_run_against_steps(t, &m, start, 2)
	testing.expect_value(t, outcome, Step_Outcome.Breakpoint)
	testing.expect_value(t, run.steps_executed, u64(2))
}

// A repeated string form that writes the frame of its own instruction
// through a second, writable mapping of that frame: each iteration of the
// steps one by one fetches the bytes that the iterations before wrote, so
// the run takes the path of one iteration there too. rep stosb writes int3
// over its own prefix: the next fetch is the breakpoint, with 4 iterations
// left.
@(test)
test_cpu_rep_string_forms_that_write_their_own_instruction :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)
	code_frame := test_alloc_frame(&m)
	source_frame := test_alloc_frame(&m)
	code_va := u64(0x40_0000)
	alias_va := u64(0x60_0000)
	source_va := u64(0x70_0000)
	test_map_4k_page(&m, code_va, code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&m, alias_va, code_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	test_map_4k_page(&m, source_va, source_frame, PAGE_PRESENT | PAGE_USER | PAGE_NO_EXECUTE)
	for i in 0 ..< 16 {
		m.ram[int(source_frame) + i] = 0xCC
	}

	stores := REP_STOSB_CODE
	test_load_code(&m, code_frame, stores[:])
	start: Processor_State
	processor_init(&start, m.cr3, code_va, 0)
	start.registers[int(General_Register.Rax)] = 0xCC
	start.registers[int(General_Register.Rdi)] = alias_va
	start.registers[int(General_Register.Rcx)] = 5
	run, outcome := test_run_against_steps(t, &m, start, 1000)
	testing.expect_value(t, outcome, Step_Outcome.Breakpoint)
	testing.expect_value(t, run.registers[int(General_Register.Rcx)], u64(4))
	testing.expect_value(t, run.rip, code_va + 1)
	testing.expect_value(t, m.ram[int(code_frame) + 1], u8(0xAA))

	// rep movsb that copies int3 over its own prefix from another page.
	moves := REP_MOVSB_CODE
	test_load_code(&m, code_frame, moves[:])
	start.registers[int(General_Register.Rsi)] = source_va
	start.registers[int(General_Register.Rdi)] = alias_va
	start.registers[int(General_Register.Rcx)] = 8
	run, outcome = test_run_against_steps(t, &m, start, 1000)
	testing.expect_value(t, outcome, Step_Outcome.Breakpoint)
	testing.expect_value(t, run.registers[int(General_Register.Rcx)], u64(7))
	testing.expect_value(t, m.ram[int(code_frame) + 1], u8(0xA4))
}

// The page of the last instruction fetch serves the next fetches until a
// flush: a new mapping of the page of the code is seen after invlpg of
// that page, after a write of cr3, and after a flush of the whole TLB, as
// the TLB of a processor gives it.
@(test)
test_cpu_fetch_page_is_flushed_by_invlpg_and_cr3 :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)
	code_frames := [2]u64{test_alloc_frame(&m), test_alloc_frame(&m)}
	code_va := u64(0x40_0000)
	test_map_4k_page(&m, code_va, code_frames[0], PAGE_PRESENT | PAGE_USER)
	// mov eax, 1; int3 in the first frame, mov eax, 2; int3 in the second.
	first := [?]u8{0xB8, 0x01, 0x00, 0x00, 0x00, 0xCC}
	second := [?]u8{0xB8, 0x02, 0x00, 0x00, 0x00, 0xCC}
	test_load_code(&m, code_frames[0], first[:])
	test_load_code(&m, code_frames[1], second[:])

	cpu: Processor_State
	processor_init(&cpu, m.cr3, code_va, 0)
	run_from_start :: proc(cpu: ^Processor_State, m: ^Test_Machine) -> u64 {
		cpu.rip = 0x40_0000
		_ = processor_run(cpu, m.ram, 10)
		return cpu.registers[int(General_Register.Rax)]
	}
	testing.expect_value(t, run_from_start(&cpu, &m), u64(1))
	testing.expect(t, cpu.tlb.fetch_page.valid, "the fetch keeps its page")

	// The new mapping, with no flush: the old translation serves.
	test_map_4k_page(&m, code_va, code_frames[1], PAGE_PRESENT | PAGE_USER)
	testing.expect_value(t, run_from_start(&cpu, &m), u64(1))
	// invlpg of another page keeps no stale fetch page either.
	processor_invlpg(&cpu, code_va + 0x10_0000)
	testing.expect(t, !cpu.tlb.fetch_page.valid, "invlpg empties the fetch page")
	processor_invlpg(&cpu, code_va)
	testing.expect_value(t, run_from_start(&cpu, &m), u64(2))

	test_map_4k_page(&m, code_va, code_frames[0], PAGE_PRESENT | PAGE_USER)
	processor_set_cr3(&cpu, m.cr3)
	testing.expect_value(t, run_from_start(&cpu, &m), u64(1))

	test_map_4k_page(&m, code_va, code_frames[1], PAGE_PRESENT | PAGE_USER)
	tlb_flush_all(&cpu.tlb)
	testing.expect_value(t, run_from_start(&cpu, &m), u64(2))

	// A page that loses its execute right faults after the flush: the fetch
	// page never holds a translation that the walk refuses.
	test_map_4k_page(&m, code_va, code_frames[1], PAGE_PRESENT | PAGE_USER | PAGE_NO_EXECUTE)
	processor_invlpg(&cpu, code_va)
	cpu.rip = code_va
	testing.expect_value(t, processor_run(&cpu, m.ram, 10), Step_Outcome.Page_Fault)
	testing.expect_value(t, cpu.fault_error_code, PAGE_FAULT_PRESENT | PAGE_FAULT_USER | PAGE_FAULT_INSTRUCTION)
	testing.expect(t, !cpu.tlb.fetch_page.valid, "a refused fetch keeps no page")
}

// mmu_read_bytes and mmu_write_bytes copy whole page chunks: a range that
// straddles two pages reads and writes each byte at its place, and a write
// whose second page faults writes no byte of the first.
@(test)
test_mmu_chunk_copies_straddle_pages :: proc(t: ^testing.T) {
	m := test_machine_create(256 * 1024)
	defer test_machine_destroy(&m)
	frames := [3]u64{test_alloc_frame(&m), test_alloc_frame(&m), test_alloc_frame(&m)}
	data_va := u64(0x60_0000)
	// Two pages in the opposite order of their frames, then a read-only one.
	test_map_4k_page(&m, data_va, frames[1], PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	test_map_4k_page(&m, data_va + PAGE_SIZE, frames[0], PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	test_map_4k_page(&m, data_va + 2 * PAGE_SIZE, frames[2], PAGE_PRESENT | PAGE_USER | PAGE_NO_EXECUTE)
	tlb: Software_Tlb

	source: [64]u8
	for &byte, index in source {
		byte = u8(index + 1)
	}
	written := mmu_write_bytes(&tlb, m.ram, m.cr3, data_va + PAGE_SIZE - 20, .User, source[:])
	testing.expect_value(t, written.status, Memory_Translation_Status.Ok)
	testing.expect_value(t, m.ram[int(frames[1]) + int(PAGE_SIZE) - 20], u8(1))
	testing.expect_value(t, m.ram[int(frames[1]) + int(PAGE_SIZE) - 1], u8(20))
	testing.expect_value(t, m.ram[int(frames[0])], u8(21))
	testing.expect_value(t, m.ram[int(frames[0]) + 43], u8(64))
	testing.expect_value(t, m.ram[int(frames[0]) + 44], u8(0))

	destination: [64]u8
	read := mmu_read_bytes(&tlb, m.ram, m.cr3, data_va + PAGE_SIZE - 20, .User, .Read, destination[:])
	testing.expect_value(t, read.status, Memory_Translation_Status.Ok)
	testing.expect(t, destination == source, "the read gives the bytes that the write wrote")

	refused := mmu_write_bytes(&tlb, m.ram, m.cr3, data_va + 2 * PAGE_SIZE - 8, .User, source[:16])
	testing.expect_value(t, refused.status, Memory_Translation_Status.Page_Fault)
	testing.expect_value(t, refused.fault_address, data_va + 2 * PAGE_SIZE)
	for i in 1 ..= 8 {
		testing.expect_value(t, m.ram[int(frames[0]) + int(PAGE_SIZE) - i], u8(0))
	}
}
