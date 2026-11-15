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

// A table DMAR that a test builds, structure after structure.
Table_Builder :: struct {
	bytes:  [4096]u8,
	length: int,
}

builder_start :: proc(builder: ^Table_Builder, width_minus_one: u8) {
	builder.bytes[DMAR_HOST_ADDRESS_WIDTH] = width_minus_one
	builder.length = DMAR_STRUCTURES_START
}

// unit_add writes the header of a remapping unit and gives its offset: its
// scopes follow, then structure_end writes its length.
unit_add :: proc(builder: ^Table_Builder, flags: u8, segment: u16, base: u64) -> int {
	start := builder.length
	store_16(builder.bytes[:], start, STRUCTURE_UNIT)
	builder.bytes[start + 4] = flags
	store_16(builder.bytes[:], start + 6, segment)
	store_64(builder.bytes[:], start + 8, base)
	builder.length += UNIT_SIZE
	structure_end(builder, start)
	return start
}

// reserved_add writes the header of a reserved memory range from its first
// and its last byte.
reserved_add :: proc(builder: ^Table_Builder, segment: u16, first, last: u64) -> int {
	start := builder.length
	store_16(builder.bytes[:], start, STRUCTURE_RESERVED_MEMORY)
	store_16(builder.bytes[:], start + 6, segment)
	store_64(builder.bytes[:], start + 8, first)
	store_64(builder.bytes[:], start + 16, last)
	builder.length += RESERVED_MEMORY_SIZE
	structure_end(builder, start)
	return start
}

// scope_add writes a device scope at the end of the last structure: path
// holds a device and a function for each pair.
scope_add :: proc(builder: ^Table_Builder, structure: int, kind: u8, bus: u8, path: []u8) {
	start := builder.length
	builder.bytes[start] = kind
	builder.bytes[start + 1] = u8(SCOPE_HEADER_SIZE + len(path))
	builder.bytes[start + 5] = bus
	copy(builder.bytes[start + SCOPE_HEADER_SIZE:], path)
	builder.length += SCOPE_HEADER_SIZE + len(path)
	structure_end(builder, structure)
}

structure_end :: proc(builder: ^Table_Builder, structure: int) {
	store_16(builder.bytes[:], structure + 2, u16(builder.length - structure))
}

builder_table :: proc(builder: ^Table_Builder) -> []u8 {
	return builder.bytes[:builder.length]
}

// The bridges of the bus of the tests: a root port at 0:1C.0 with bus 1
// behind it; a root port at 0:1E.0 with the buses 2 and 3, and a switch
// port at 2:0.0 with bus 3; a bridge at 0:1D.0 whose secondary bus is 0,
// which would make a loop.
Test_Bridge :: struct {
	bus, device, function, secondary, subordinate: u32,
}

@(rodata)
TEST_BRIDGES := [?]Test_Bridge{{0, 0x1C, 0, 1, 1}, {0, 0x1E, 0, 2, 3}, {2, 0, 0, 3, 3}, {0, 0x1D, 0, 0, 0}}

test_bridge_read :: proc "contextless" (bus, device, function: u32) -> (secondary: u32, subordinate: u32, found: bool) {
	for bridge in TEST_BRIDGES {
		if bridge.bus == bus && bridge.device == device && bridge.function == function {
			return bridge.secondary, bridge.subordinate, true
		}
	}
	return 0, 0, false
}

// resolve_all resolves each scope of a table, as the kernel does at its
// start.
resolve_all :: proc(dmar: ^Dmar) -> (resolved: [SCOPE_CAPACITY]Resolved_Scope) {
	for index in 0 ..< int(dmar.scope_count) {
		resolved[index] = scope_resolve(dmar.scopes[index], test_bridge_read)
	}
	return resolved
}

// The table that QEMU gives with -device intel-iommu: a width of 39 bits
// and one unit at 0xFED90000 that covers every device of segment 0, behind
// a bridge too.
@(test)
one_unit_that_covers_every_device :: proc(t: ^testing.T) {
	builder: Table_Builder
	builder_start(&builder, 38)
	unit_add(&builder, UNIT_INCLUDES_EVERY_DEVICE, 0, 0xFED9_0000)
	dmar, problem := dmar_read(builder_table(&builder))
	testing.expect_value(t, problem, Dmar_Problem.None)
	testing.expect_value(t, dmar.host_address_width, u32(39))
	testing.expect_value(t, dmar.unit_count, u32(1))
	testing.expect_value(t, dmar.units[0].register_base, u64(0xFED9_0000))
	testing.expect_value(t, dmar.reserved_range_count, u32(0))
	resolved := resolve_all(&dmar)
	identifiers := [?]u16{requester(0, 2, 0), requester(1, 0, 0), requester(200, 31, 7)}
	for identifier in identifiers {
		unit, covered := unit_of(&dmar, &resolved, identifier)
		testing.expect(t, covered)
		testing.expect_value(t, unit, u32(0))
	}
}

// The table that QEMU 10 gives: no flag, a scope of the interrupt
// controller, then one scope for each function of bus 0, with a bridge
// scope for a root port. A device behind the root port is covered through
// the buses of the bridge; a function that no scope names is not.
@(test)
one_unit_that_lists_its_functions :: proc(t: ^testing.T) {
	builder: Table_Builder
	builder_start(&builder, 47)
	unit := unit_add(&builder, 0, 0, 0xFED9_0000)
	scope_add(&builder, unit, 3, 0xFF, {0, 0}) // The interrupt controller: no requester.
	scope_add(&builder, unit, SCOPE_ENDPOINT, 0, {2, 0})
	scope_add(&builder, unit, SCOPE_BRIDGE, 0, {0x1E, 0}) // The buses 2 and 3.
	scope_add(&builder, unit, SCOPE_ENDPOINT, 0, {0x1C, 0, 0, 0}) // A path of two pairs: the device 0 of bus 1.
	scope_add(&builder, unit, SCOPE_ENDPOINT, 0, {0x1D, 0, 0, 0}) // Through the bridge that loops: not resolved.
	scope_add(&builder, unit, SCOPE_ENDPOINT, 0, {0x1F, 0, 0, 0}) // Through no bridge: not resolved.
	dmar, problem := dmar_read(builder_table(&builder))
	testing.expect_value(t, problem, Dmar_Problem.None)
	testing.expect_value(t, dmar.scope_count, u32(5))
	resolved := resolve_all(&dmar)
	testing.expect(t, resolved[0].found && resolved[0].requester == requester(0, 2, 0))
	testing.expect(t, resolved[1].found && resolved[1].first_bus == 2 && resolved[1].last_bus == 3)
	testing.expect(t, resolved[2].found && resolved[2].requester == requester(1, 0, 0))
	testing.expect(t, !resolved[3].found)
	testing.expect(t, !resolved[4].found)
	covered_requesters := [?]u16{requester(0, 2, 0), requester(0, 0x1E, 0), requester(2, 0, 0), requester(3, 4, 1), requester(1, 0, 0)}
	for identifier in covered_requesters {
		_, covered := unit_of(&dmar, &resolved, identifier)
		testing.expect(t, covered)
	}
	uncovered_requesters := [?]u16{requester(0, 3, 0), requester(0, 2, 1), requester(1, 3, 0), requester(4, 0, 0)}
	for identifier in uncovered_requesters {
		_, covered := unit_of(&dmar, &resolved, identifier)
		testing.expect(t, !covered)
	}
}

// A machine of Intel: a unit for the graphics device at 0:2.0, a unit with
// INCLUDE_PCI_ALL for every other device, a reserved range of the graphics
// device and one of the USB controller at 0:14.0, which the firmware uses
// for its keyboard.
@(test)
two_units_and_reserved_ranges :: proc(t: ^testing.T) {
	builder: Table_Builder
	builder_start(&builder, 38)
	graphics := unit_add(&builder, 0, 0, 0xFED9_0000)
	scope_add(&builder, graphics, SCOPE_ENDPOINT, 0, {2, 0})
	every := unit_add(&builder, UNIT_INCLUDES_EVERY_DEVICE, 0, 0xFED9_1000)
	scope_add(&builder, every, 3, 0xF0, {0x1F, 0}) // The interrupt controller.
	stolen := reserved_add(&builder, 0, 0x7C00_0000, 0x7C7F_FFFF)
	scope_add(&builder, stolen, SCOPE_ENDPOINT, 0, {2, 0})
	keyboard := reserved_add(&builder, 0, 0x7B80_0000, 0x7B81_FFFF)
	scope_add(&builder, keyboard, SCOPE_ENDPOINT, 0, {0x14, 0})
	dmar, problem := dmar_read(builder_table(&builder))
	testing.expect_value(t, problem, Dmar_Problem.None)
	testing.expect_value(t, dmar.unit_count, u32(2))
	testing.expect_value(t, dmar.units[1].register_base, u64(0xFED9_1000))
	testing.expect(t, !dmar.units[0].includes_every_device && dmar.units[1].includes_every_device)
	testing.expect_value(t, dmar.reserved_range_count, u32(2))
	testing.expect_value(t, dmar.reserved_ranges[0].start, u64(0x7C00_0000))
	testing.expect_value(t, dmar.reserved_ranges[0].end, u64(0x7C80_0000))
	testing.expect_value(t, dmar.reserved_ranges[1].end, u64(0x7B82_0000))
	testing.expect_value(t, dmar.scope_count, u32(3))
	testing.expect(t, dmar.scopes[1].reserved && dmar.scopes[1].owner == 0)
	testing.expect(t, dmar.scopes[2].reserved && dmar.scopes[2].owner == 1)
	resolved := resolve_all(&dmar)
	testing.expect(t, resolved[2].found && resolved[2].requester == requester(0, 0x14, 0))
	// The graphics device goes to its own unit; the USB controller, a device
	// behind a root port and any other device to the unit of every device. A
	// scope of a reserved range chooses no unit.
	unit, covered := unit_of(&dmar, &resolved, requester(0, 2, 0))
	testing.expect(t, covered)
	testing.expect_value(t, unit, u32(0))
	others := [?]u16{requester(0, 0x14, 0), requester(1, 0, 0), requester(0, 2, 1)}
	for identifier in others {
		unit, covered = unit_of(&dmar, &resolved, identifier)
		testing.expect(t, covered)
		testing.expect_value(t, unit, u32(1))
	}
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
		builder: Table_Builder
		builder_start(&builder, 38)
		for index in 0 ..< UNIT_CAPACITY + 1 {
			unit_add(&builder, 0, 0, 0xFED9_0000 + u64(index) * 0x1000)
		}
		_, problem := dmar_read(builder_table(&builder))
		testing.expect_value(t, problem, Dmar_Problem.Too_Many_Units)
	}
	{
		builder: Table_Builder
		builder_start(&builder, 38)
		unit_add(&builder, UNIT_INCLUDES_EVERY_DEVICE, 1, 0xFED9_0000)
		_, problem := dmar_read(builder_table(&builder))
		testing.expect_value(t, problem, Dmar_Problem.Other_Segment)
	}
	{
		// A reserved range that is not whole pages, and one whose end wraps.
		builder: Table_Builder
		builder_start(&builder, 38)
		unit_add(&builder, UNIT_INCLUDES_EVERY_DEVICE, 0, 0xFED9_0000)
		reserved := reserved_add(&builder, 0, 0x7B80_0000, 0x7B80_0FFE)
		_, problem := dmar_read(builder_table(&builder))
		testing.expect_value(t, problem, Dmar_Problem.Bad_Structure)
		store_64(builder.bytes[:], reserved + 16, max(u64))
		_, problem = dmar_read(builder_table(&builder))
		testing.expect_value(t, problem, Dmar_Problem.Bad_Structure)
		store_64(builder.bytes[:], reserved + 8, 0x7B80_1000)
		store_64(builder.bytes[:], reserved + 16, 0x7B80_0FFF) // The last byte before the first.
		_, problem = dmar_read(builder_table(&builder))
		testing.expect_value(t, problem, Dmar_Problem.Bad_Structure)
	}
	{
		builder: Table_Builder
		builder_start(&builder, 38)
		unit_add(&builder, UNIT_INCLUDES_EVERY_DEVICE, 0, 0xFED9_0000)
		for _ in 0 ..< RESERVED_RANGE_CAPACITY + 1 {
			reserved_add(&builder, 0, 0x7B80_0000, 0x7B80_0FFF)
		}
		_, problem := dmar_read(builder_table(&builder))
		testing.expect_value(t, problem, Dmar_Problem.Too_Many_Ranges)
	}
	{
		builder: Table_Builder
		builder_start(&builder, 38)
		unit := unit_add(&builder, 0, 0, 0xFED9_0000)
		scope_add(&builder, unit, SCOPE_ENDPOINT, 0, {0x1C, 0, 0, 0, 0, 0, 0, 0, 0, 0})
		_, problem := dmar_read(builder_table(&builder))
		testing.expect_value(t, problem, Dmar_Problem.Long_Path)
	}
	{
		builder: Table_Builder
		builder_start(&builder, 38)
		unit := unit_add(&builder, 0, 0, 0xFED9_0000)
		for index in 0 ..< SCOPE_CAPACITY + 1 {
			scope_add(&builder, unit, SCOPE_ENDPOINT, u8(index / 32), {u8(index % 32), 0})
		}
		_, problem := dmar_read(builder_table(&builder))
		testing.expect_value(t, problem, Dmar_Problem.Too_Many_Scopes)
	}
	{
		// A path with an odd count of bytes, and with none.
		builder: Table_Builder
		builder_start(&builder, 38)
		unit := unit_add(&builder, 0, 0, 0xFED9_0000)
		scope_add(&builder, unit, SCOPE_ENDPOINT, 0, {2, 0, 3})
		_, problem := dmar_read(builder_table(&builder))
		testing.expect_value(t, problem, Dmar_Problem.Bad_Structure)
		builder_start(&builder, 38)
		unit = unit_add(&builder, 0, 0, 0xFED9_0000)
		scope_add(&builder, unit, SCOPE_BRIDGE, 0, {})
		_, problem = dmar_read(builder_table(&builder))
		testing.expect_value(t, problem, Dmar_Problem.Bad_Structure)
	}
	{
		// A scope that passes the end of its unit, a scope shorter than its
		// header, which would never move the reader, and a unit that ends
		// with too few bytes for the header of a scope.
		builder: Table_Builder
		builder_start(&builder, 38)
		unit := unit_add(&builder, 0, 0, 0xFED9_0000)
		scope_add(&builder, unit, SCOPE_ENDPOINT, 0, {2, 0})
		scope := unit + UNIT_SIZE
		builder.bytes[scope + 1] = SCOPE_HEADER_SIZE + 3
		_, problem := dmar_read(builder_table(&builder))
		testing.expect_value(t, problem, Dmar_Problem.Bad_Structure)
		builder.bytes[scope + 1] = 0
		_, problem = dmar_read(builder_table(&builder))
		testing.expect_value(t, problem, Dmar_Problem.Bad_Structure)
		builder.bytes[scope + 1] = SCOPE_HEADER_SIZE + 2
		store_16(builder.bytes[:], unit + 2, UNIT_SIZE + SCOPE_HEADER_SIZE - 1)
		builder.length = unit + UNIT_SIZE + SCOPE_HEADER_SIZE - 1
		_, problem = dmar_read(builder_table(&builder))
		testing.expect_value(t, problem, Dmar_Problem.Bad_Structure)
	}
	{
		// A length that passes the end of the table, and a length of 0,
		// which would never move the reader.
		builder: Table_Builder
		builder_start(&builder, 38)
		unit := unit_add(&builder, UNIT_INCLUDES_EVERY_DEVICE, 0, 0xFED9_0000)
		store_16(builder.bytes[:], unit + 2, UNIT_SIZE + 1)
		_, problem := dmar_read(builder_table(&builder))
		testing.expect_value(t, problem, Dmar_Problem.Bad_Structure)
		store_16(builder.bytes[:], unit + 2, 0)
		_, problem = dmar_read(builder_table(&builder))
		testing.expect_value(t, problem, Dmar_Problem.Bad_Structure)
	}
}

// A bridge of PCI Express passes the requester of each device behind it; a
// conventional bridge does not, and neither does a list of capabilities
// that loops.
@(test)
the_kinds_of_a_bridge :: proc(t: ^testing.T) {
	header: [HEADER_WORDS]u32
	header[3] = 0x0001_0000 // The header type 1.
	header[6] = 0x0003_0200 // Primary 0, secondary 2, subordinate 3.
	testing.expect(t, header_is_bridge(header))
	secondary, subordinate := bridge_buses(header)
	testing.expect_value(t, secondary, u32(2))
	testing.expect_value(t, subordinate, u32(3))
	header[3] = 0
	testing.expect(t, !header_is_bridge(header))

	configuration: [CONFIGURATION_WORDS]u32
	testing.expect(t, !bridge_passes_requesters(&configuration)) // No list of capabilities.
	configuration[1] = STATUS_CAPABILITIES
	configuration[0x34 / 4] = 0x40
	configuration[0x40 / 4] = 0x0000_6005 // A capability of messages, then 0x60.
	configuration[0x60 / 4] = u32(PORT_ROOT) << 20 | 0x10 // PCI Express: a root port.
	testing.expect(t, bridge_passes_requesters(&configuration))
	configuration[0x60 / 4] = u32(PORT_SWITCH_DOWNSTREAM) << 20 | 0x10
	testing.expect(t, bridge_passes_requesters(&configuration))
	configuration[0x60 / 4] = u32(7) << 20 | 0x10 // A bridge from PCI Express to PCI.
	testing.expect(t, !bridge_passes_requesters(&configuration))
	configuration[0x60 / 4] = 0x0000_4005 // A list that comes back to 0x40.
	testing.expect(t, !bridge_passes_requesters(&configuration))
}

// The commands of the invalidation of one domain, and the device windows.
@(test)
the_invalidation_of_one_domain :: proc(t: ^testing.T) {
	testing.expect_value(t, context_command_domain(5), u64(1) << 63 | u64(2) << 61 | 5)
	testing.expect_value(t, context_command_domain(0) >> 61 & 3, u64(2))
	testing.expect_value(t, iotlb_command_domain(5), u64(1) << 63 | u64(2) << 60 | u64(1) << 49 | u64(1) << 48 | u64(5) << 32)
	testing.expect_value(t, CONTEXT_COMMAND_GLOBAL >> 61 & 3, u64(1))
	testing.expect_value(t, IOTLB_COMMAND_GLOBAL >> 60 & 3, u64(1))
	testing.expect_value(t, window_address(0), u64(1) << 38)
	testing.expect_value(t, window_address(1) - window_address(0), WINDOW_SIZE)
	// The windows of 2048 memory objects end where a domain of 39 bits ends.
	testing.expect_value(t, window_address(2047) + WINDOW_SIZE, domain_address_end(3))
	testing.expect_value(t, WINDOW_PAGES, u64(32768))
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
	testing.expect_value(t, configuration_offset(1, 0, 0, 0), CONFIGURATION_BUS_SIZE)
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
	// QEMU gives a width of 39 bits by default: MGAW 38 in the bits 21:16.
	testing.expect_value(t, capability_address_width(u64(38) << 16), u32(WINDOW_ADDRESS_WIDTH))
	testing.expect_value(t, capability_address_width(u64(35) << 16 | capability), u32(36))

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
