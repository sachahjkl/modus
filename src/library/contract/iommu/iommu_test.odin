#+build !freestanding
package iommu

import "core:testing"

store_16 :: proc(bytes: []u8, offset: int, value: u16) {
	bytes[offset] = u8(value)
	bytes[offset + 1] = u8(value >> 8)
}

store_64 :: proc(bytes: []u8, offset: int, value: u64) {
	for index in 0 ..< 8 {
		bytes[offset + index] = u8(value >> (8 * uint(index)))
	}
}

// unit_write writes a remapping unit of UNIT_SIZE bytes at offset.
unit_write :: proc(bytes: []u8, offset: int, flags: u8, segment: u16, base: u64) {
	store_16(bytes, offset, STRUCTURE_UNIT)
	store_16(bytes, offset + 2, UNIT_SIZE)
	bytes[offset + 4] = flags
	store_16(bytes, offset + 6, segment)
	store_64(bytes, offset + 8, base)
}

// The table that QEMU gives with -device intel-iommu: a width of 39 bits
// and one unit at 0xFED90000 that covers every device of segment 0.
@(test)
one_unit_that_covers_every_device :: proc(t: ^testing.T) {
	table: [DMAR_STRUCTURES_START + UNIT_SIZE]u8
	table[DMAR_HOST_ADDRESS_WIDTH] = 38
	unit_write(table[:], DMAR_STRUCTURES_START, UNIT_INCLUDES_EVERY_DEVICE, 0, 0xFED9_0000)
	dmar, problem := dmar_read(table[:])
	testing.expect_value(t, problem, Dmar_Problem.None)
	testing.expect_value(t, dmar.host_address_width, u32(39))
	testing.expect_value(t, dmar.register_base, u64(0xFED9_0000))
	testing.expect_value(t, dmar.unit_count, u32(1))
	testing.expect_value(t, covered_count(dmar), u32(FUNCTIONS_OF_BUS_0))
}

// The table that QEMU 10 gives: no flag, a scope of the interrupt
// controller, then one scope for each function of bus 0. A function that
// the list does not name, or names behind a bridge, is not covered.
@(test)
one_unit_that_lists_its_functions :: proc(t: ^testing.T) {
	SCOPE :: SCOPE_HEADER_SIZE + 2
	table: [DMAR_STRUCTURES_START + UNIT_SIZE + 4 * SCOPE + SCOPE_HEADER_SIZE + 4]u8
	table[DMAR_HOST_ADDRESS_WIDTH] = 47
	unit_write(table[:], DMAR_STRUCTURES_START, 0, 0, 0xFED9_0000)
	store_16(table[:], DMAR_STRUCTURES_START + 2, u16(len(table) - DMAR_STRUCTURES_START))
	scope_write :: proc(bytes: []u8, offset: int, kind, length, bus, device, function: u8) {
		bytes[offset] = kind
		bytes[offset + 1] = length
		bytes[offset + 5] = bus
		bytes[offset + 6] = device
		bytes[offset + 7] = function
	}
	scope := DMAR_STRUCTURES_START + UNIT_SIZE
	scope_write(table[:], scope, 3, SCOPE, 0xFF, 0, 0) // The interrupt controller.
	scope_write(table[:], scope + SCOPE, SCOPE_ENDPOINT, SCOPE, 0, 2, 0)
	scope_write(table[:], scope + 2 * SCOPE, SCOPE_BRIDGE, SCOPE, 0, 0x1E, 0)
	scope_write(table[:], scope + 3 * SCOPE, SCOPE_ENDPOINT, SCOPE, 1, 3, 0) // Behind a bridge.
	scope_write(table[:], scope + 4 * SCOPE, SCOPE_ENDPOINT, SCOPE_HEADER_SIZE + 4, 0, 0x1E, 0) // A path of two pairs.
	dmar, problem := dmar_read(table[:])
	testing.expect_value(t, problem, Dmar_Problem.None)
	testing.expect_value(t, covered_count(dmar), u32(2))
	testing.expect(t, dmar_covers(dmar, 2, 0))
	testing.expect(t, dmar_covers(dmar, 0x1E, 0))
	testing.expect(t, !dmar_covers(dmar, 3, 0))
	testing.expect(t, !dmar_covers(dmar, 2, 1))
	// A scope that passes the end of its unit.
	table[scope + 4 * SCOPE + 1] = SCOPE_HEADER_SIZE + 5
	_, problem = dmar_read(table[:])
	testing.expect_value(t, problem, Dmar_Problem.Bad_Structure)
	// A scope shorter than its header, which would never move the reader.
	table[scope + 4 * SCOPE + 1] = 0
	_, problem = dmar_read(table[:])
	testing.expect_value(t, problem, Dmar_Problem.Bad_Structure)
	// A unit that ends with too few bytes for the header of a scope.
	table[scope + 4 * SCOPE + 1] = SCOPE_HEADER_SIZE + 4
	store_16(table[:], DMAR_STRUCTURES_START + 2, u16(len(table) - DMAR_STRUCTURES_START - 6))
	_, problem = dmar_read(table[:])
	testing.expect_value(t, problem, Dmar_Problem.Bad_Structure)
}

// Each form that the kernel does not program gives its problem, and the
// IOMMU stays off.
@(test)
the_forms_that_the_kernel_refuses :: proc(t: ^testing.T) {
	{
		table: [DMAR_STRUCTURES_START - 1]u8
		_, problem := dmar_read(table[:])
		testing.expect_value(t, problem, Dmar_Problem.Too_Short)
	}
	{
		table: [DMAR_STRUCTURES_START]u8
		_, problem := dmar_read(table[:])
		testing.expect_value(t, problem, Dmar_Problem.No_Unit)
	}
	{
		table: [DMAR_STRUCTURES_START + 2 * UNIT_SIZE]u8
		unit_write(table[:], DMAR_STRUCTURES_START, UNIT_INCLUDES_EVERY_DEVICE, 0, 0xFED9_0000)
		unit_write(table[:], DMAR_STRUCTURES_START + UNIT_SIZE, 0, 0, 0xFED9_1000)
		_, problem := dmar_read(table[:])
		testing.expect_value(t, problem, Dmar_Problem.Several_Units)
	}
	{
		table: [DMAR_STRUCTURES_START + UNIT_SIZE]u8
		unit_write(table[:], DMAR_STRUCTURES_START, UNIT_INCLUDES_EVERY_DEVICE, 1, 0xFED9_0000)
		_, problem := dmar_read(table[:])
		testing.expect_value(t, problem, Dmar_Problem.Other_Segment)
	}
	{
		// A unit, then a reserved range of 24 bytes.
		table: [DMAR_STRUCTURES_START + UNIT_SIZE + 24]u8
		unit_write(table[:], DMAR_STRUCTURES_START, UNIT_INCLUDES_EVERY_DEVICE, 0, 0xFED9_0000)
		store_16(table[:], DMAR_STRUCTURES_START + UNIT_SIZE, STRUCTURE_RESERVED_MEMORY)
		store_16(table[:], DMAR_STRUCTURES_START + UNIT_SIZE + 2, 24)
		_, problem := dmar_read(table[:])
		testing.expect_value(t, problem, Dmar_Problem.Reserved_Memory)
	}
	{
		// A length that passes the end of the table, and a length of 0,
		// which would never move the reader.
		table: [DMAR_STRUCTURES_START + UNIT_SIZE]u8
		unit_write(table[:], DMAR_STRUCTURES_START, UNIT_INCLUDES_EVERY_DEVICE, 0, 0xFED9_0000)
		store_16(table[:], DMAR_STRUCTURES_START + 2, UNIT_SIZE + 1)
		_, problem := dmar_read(table[:])
		testing.expect_value(t, problem, Dmar_Problem.Bad_Structure)
		store_16(table[:], DMAR_STRUCTURES_START + 2, 0)
		_, problem = dmar_read(table[:])
		testing.expect_value(t, problem, Dmar_Problem.Bad_Structure)
	}
}

// The range of segment 0 that holds bus 0, as QEMU q35 gives it.
@(test)
the_configuration_memory_of_bus_0 :: proc(t: ^testing.T) {
	table: [MCFG_ENTRIES_START + 2 * MCFG_ENTRY_SIZE]u8
	// First a range of another segment, then the range of segment 0.
	store_64(table[:], MCFG_ENTRIES_START, 0xC000_0000)
	store_16(table[:], MCFG_ENTRIES_START + 8, 1)
	store_64(table[:], MCFG_ENTRIES_START + MCFG_ENTRY_SIZE, 0xB000_0000)
	table[MCFG_ENTRIES_START + MCFG_ENTRY_SIZE + 11] = 0xFF
	memory, found := mcfg_read(table[:])
	testing.expect(t, found)
	testing.expect_value(t, memory.base, u64(0xB000_0000))
	testing.expect_value(t, memory.last_bus, u8(0xFF))
	_, found = mcfg_read(table[:MCFG_ENTRIES_START + MCFG_ENTRY_SIZE])
	testing.expect(t, !found)
	testing.expect_value(t, configuration_offset(0, 17, 0, 0x10), u64(17 << 15 | 0x10))
}

// A device with a register of ports, a memory register of 32 bits and one
// of 64 bits: two bases. A bridge gives no base.
@(test)
the_memory_bases_of_a_function :: proc(t: ^testing.T) {
	header: [HEADER_WORDS]u32
	header[0] = 0x1042_1AF4
	header[4] = 0xC041 // Ports.
	header[5] = 0xFEB1_1000 // Memory, 32 bits.
	header[8] = 0xFE00_000C // Memory, 64 bits, prefetchable: the low half.
	header[9] = 0x0000_0001 // The high half.
	bases, count := header_memory_bases(header)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, bases[0], u64(0xFEB1_1000))
	testing.expect_value(t, bases[1], u64(0x1_FE00_0000))
	testing.expect(t, !header_is_multi_function(header))

	header[3] = 0x0081_0000 // A bridge, with several functions.
	bases, count = header_memory_bases(header)
	testing.expect_value(t, count, 0)
	testing.expect(t, header_is_multi_function(header))

	identifier := requester(0, 17, 0)
	testing.expect_value(t, identifier, u16(0x88))
	testing.expect_value(t, requester_device(identifier), u32(17))
	testing.expect_value(t, requester_function(requester(0, 31, 7)), u32(7))
	testing.expect_value(t, requester_bus(requester(3, 0, 0)), u32(3))
}

// The bits of each entry, from the specification.
@(test)
the_entries_of_the_tables :: proc(t: ^testing.T) {
	root := root_entry(0x1234_5000)
	testing.expect_value(t, root[0], u64(0x1234_5001))
	testing.expect_value(t, root[1], u64(0))

	entry := context_entry(0x7_6543_2000, 4, 9)
	testing.expect_value(t, entry[0], u64(0x7_6543_2001)) // Present; FPD and the type 0.
	testing.expect_value(t, entry[1], u64(2 | 9 << 8)) // 48 bits; the domain 9.
	testing.expect_value(t, context_entry(0x2000, 3, 1)[1], u64(1 | 1 << 8)) // 39 bits.

	table := table_entry(0xABC_DEF0_1FFF)
	testing.expect_value(t, table, u64(0xABC_DEF0_1003))
	// A page that the service can write, and one that it can only read:
	// the device gets no right that the handle did not carry.
	testing.expect_value(t, page_entry(0xABC_DEF0_1FFF, true), u64(0xABC_DEF0_1003))
	read_only := page_entry(0xABC_DEF0_1FFF, false)
	testing.expect_value(t, read_only, u64(0xABC_DEF0_1001))
	testing.expect(t, read_only & ENTRY_WRITE == 0)
	testing.expect(t, entry_present(read_only))
	testing.expect(t, !entry_present(0))
	testing.expect_value(t, domain_address_end(3), u64(1) << 39)
	testing.expect_value(t, domain_address_end(4), u64(1) << 48)

	address := u64(3) << 39 | u64(5) << 30 | u64(7) << 21 | u64(11) << 12 | 0x123
	testing.expect_value(t, level_index(address, 4), u64(3))
	testing.expect_value(t, level_index(address, 3), u64(5))
	testing.expect_value(t, level_index(address, 2), u64(7))
	testing.expect_value(t, level_index(address, 1), u64(11))
}

// The fields of the capability that the kernel reads, with the values of
// the unit of QEMU: 48 and 39 bits, the fault records at 0x220, the IOTLB
// at 0x200.
@(test)
the_capability_of_a_unit :: proc(t: ^testing.T) {
	capability := u64(6) << 8 | u64(0x22) << 24 | u64(1) << 55 | u64(1) << 54 | 2
	testing.expect_value(t, capability_levels(capability), u32(4))
	testing.expect_value(t, capability_levels(u64(2) << 8), u32(3))
	testing.expect_value(t, capability_levels(u64(1) << 8), u32(0))
	offset, count := capability_fault_records(capability)
	testing.expect_value(t, offset, u64(0x220))
	testing.expect_value(t, count, u64(1))
	testing.expect(t, capability_drains(capability))
	testing.expect(t, !capability_drains(capability &~ (1 << 54)))
	testing.expect(t, !capability_drains(capability &~ (1 << 55)))
	testing.expect_value(t, capability_domain_count(capability), u64(256))
	testing.expect(t, !capability_caching_mode(capability))
	testing.expect(t, capability_caching_mode(capability | 1 << 7))
	testing.expect_value(t, extended_iotlb_offset(u64(0x20) << 8), u64(0x200))
	testing.expect(t, !extended_coherent(0))

	// A command keeps translation on and drops the one-shot bits.
	status := GLOBAL_TRANSLATION | GLOBAL_ROOT_TABLE | GLOBAL_WRITE_BUFFER
	testing.expect_value(t, global_command(status, GLOBAL_ROOT_TABLE), GLOBAL_TRANSLATION | GLOBAL_ROOT_TABLE)
}

// A mode that the firmware left on refuses the unit, in this order.
@(test)
the_modes_that_the_firmware_left_on :: proc(t: ^testing.T) {
	testing.expect_value(t, global_status_problem(0), Global_Status_Problem.None)
	testing.expect_value(t, global_status_problem(GLOBAL_ROOT_TABLE), Global_Status_Problem.None)
	testing.expect_value(t, global_status_problem(GLOBAL_TRANSLATION | GLOBAL_QUEUED_INVALIDATION), Global_Status_Problem.Translation_On)
	testing.expect_value(t, global_status_problem(GLOBAL_QUEUED_INVALIDATION), Global_Status_Problem.Queued_Invalidation_On)
	testing.expect_value(t, global_status_problem(GLOBAL_INTERRUPT_REMAPPING), Global_Status_Problem.Interrupt_Remapping_On)
}

// An invalidation is done when its bit is clear, and made when the unit
// gives a granularity that is not 0.
@(test)
the_end_of_an_invalidation :: proc(t: ^testing.T) {
	finished, made := context_invalidation_done(CONTEXT_INVALIDATE | CONTEXT_GLOBAL)
	testing.expect(t, !finished)
	finished, made = context_invalidation_done(u64(1) << 59)
	testing.expect(t, finished && made)
	finished, made = context_invalidation_done(CONTEXT_GLOBAL)
	testing.expect(t, finished && !made)
	finished, made = iotlb_invalidation_done(IOTLB_GLOBAL | u64(1) << 57)
	testing.expect(t, finished && made)
	finished, made = iotlb_invalidation_done(IOTLB_INVALIDATE)
	testing.expect(t, !finished && !made)
}

// The first faults of a device are whole lines, then one line at each
// power of two.
@(test)
the_lines_of_a_fault_storm :: proc(t: ^testing.T) {
	testing.expect_value(t, fault_line(0), Fault_Line.None)
	for count in u64(1) ..= FAULT_LINES {
		testing.expect_value(t, fault_line(count), Fault_Line.Whole)
	}
	testing.expect_value(t, fault_line(5), Fault_Line.None)
	testing.expect_value(t, fault_line(8), Fault_Line.Count)
	testing.expect_value(t, fault_line(9), Fault_Line.None)
	testing.expect_value(t, fault_line(1 << 20), Fault_Line.Count)
	lines := 0
	for count in u64(1) ..= 1_000_000 {
		if fault_line(count) != .None {
			lines += 1
		}
	}
	testing.expect_value(t, lines, FAULT_LINES + 17) // The powers of two from 8 to 524 288.
}

// A record of a write of the device 0:17.0 to the page 0x3F2A000, with the
// reason 6, and a free record.
@(test)
a_fault_record :: proc(t: ^testing.T) {
	high := u64(1) << 63 | u64(6) << 32 | u64(requester(0, 17, 0))
	fault, recorded := fault_read(0x3F2_A123, high)
	testing.expect(t, recorded)
	testing.expect_value(t, fault.address, u64(0x3F2_A000))
	testing.expect_value(t, fault.requester, u16(0x88))
	testing.expect_value(t, fault.reason, u8(6))
	testing.expect(t, !fault.read)
	fault, recorded = fault_read(0, high | 1 << 62)
	testing.expect(t, fault.read)
	_, recorded = fault_read(0x3F2_A000, high &~ (1 << 63))
	testing.expect(t, !recorded)
}
