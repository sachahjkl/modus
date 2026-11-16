#+build !freestanding
package iommu

import "core:testing"

// A table IVRS that a test builds, block after block.
Ivrs_Builder :: struct {
	bytes:  [4096]u8,
	length: int,
}

ivrs_builder_start :: proc(builder: ^Ivrs_Builder) {
	builder.length = AMD_IVRS_BLOCKS_START
}

// ivrs_unit_add writes the header of a unit block of a kind and gives its
// offset: its device entries follow, then ivrs_block_end writes its length.
ivrs_unit_add :: proc(builder: ^Ivrs_Builder, kind: u8, requester: u16, base: u64, segment: u16 = 0) -> int {
	start := builder.length
	builder.bytes[start] = kind
	store_16(builder.bytes[:], start + 4, requester)
	store_64(builder.bytes[:], start + 8, base)
	store_16(builder.bytes[:], start + 16, segment)
	builder.length += kind == AMD_BLOCK_UNIT_FIRST_FORM ? AMD_BLOCK_UNIT_FIRST_FORM_HEADER : AMD_BLOCK_UNIT_HEADER
	ivrs_block_end(builder, start)
	return start
}

// ivrs_entry_add writes a device entry of 4 or 8 bytes at the end of the
// last block: the kind, the requester in the bytes 1 and 2, and for an
// entry of 8 bytes the byte 4, a second requester in the bytes 5 and 6, and
// the byte 7. The settings byte is the byte 3.
ivrs_entry_add :: proc(builder: ^Ivrs_Builder, block: int, kind: u8, requester: u16, second: u16 = 0, last_byte: u8 = 0, settings: u8 = 0) {
	start := builder.length
	builder.bytes[start] = kind
	store_16(builder.bytes[:], start + 1, requester)
	builder.bytes[start + 3] = settings
	size := 4
	if kind >= 0x40 {
		size = 8
		store_16(builder.bytes[:], start + 5, second)
		builder.bytes[start + 7] = last_byte
	}
	builder.length += size
	ivrs_block_end(builder, block)
}

// ivrs_reserved_add writes a reserved memory range block of a kind.
ivrs_reserved_add :: proc(builder: ^Ivrs_Builder, kind: u8, requester: u16, start_address, size: u64) {
	start := builder.length
	builder.bytes[start] = kind
	store_16(builder.bytes[:], start + 4, requester)
	store_64(builder.bytes[:], start + 16, start_address)
	store_64(builder.bytes[:], start + 24, size)
	builder.length += AMD_BLOCK_RESERVED_SIZE
	ivrs_block_end(builder, start)
}

ivrs_block_end :: proc(builder: ^Ivrs_Builder, block: int) {
	store_16(builder.bytes[:], block + 2, u16(builder.length - block))
}

ivrs_table :: proc(builder: ^Ivrs_Builder) -> []u8 {
	return builder.bytes[:builder.length]
}

// The device entries that QEMU 10 gives for the machine of the test with a
// root port at 0:1C.0 and bus 1 behind it: a select entry for each function
// of bus 0, the range of the leaf bus 1, and the IOAPIC.
ivrs_entries_of_qemu :: proc(builder: ^Ivrs_Builder, block: int) {
	functions := [?]u16{requester(0, 0, 0), requester(0, 1, 0), requester(0, 2, 0), requester(0, 0x10, 0), requester(0, 0x12, 0), requester(0, 0x1C, 0), requester(0, 0x1F, 0), requester(0, 0x1F, 2), requester(0, 0x1F, 3)}
	for function in functions {
		ivrs_entry_add(builder, block, AMD_ENTRY_SELECT, function)
		if function == requester(0, 0x1C, 0) {
			ivrs_entry_add(builder, block, AMD_ENTRY_RANGE_START, requester(1, 0, 0))
			ivrs_entry_add(builder, block, AMD_ENTRY_RANGE_END, requester(1, 31, 7))
		}
	}
	ivrs_entry_add(builder, block, AMD_ENTRY_SPECIAL, 0, requester(0, 0x14, 0), AMD_SPECIAL_VARIETY_INTERRUPT_CONTROLLER)
}

// The table of QEMU 10 with -device amd-iommu,intremap=on: one unit at
// 0xFED80000, the function 0:2.0, described twice, by a block of the kind
// 0x10 and by a block of the kind 0x11. The kernel reads the blocks of the
// kind 0x11 only: one unit, not two.
@(test)
the_table_of_qemu :: proc(t: ^testing.T) {
	builder: Ivrs_Builder
	ivrs_builder_start(&builder)
	first := ivrs_unit_add(&builder, AMD_BLOCK_UNIT_FIRST_FORM, requester(0, 2, 0), 0xFED8_0000)
	ivrs_entries_of_qemu(&builder, first)
	second := ivrs_unit_add(&builder, AMD_BLOCK_UNIT_SECOND_FORM, requester(0, 2, 0), 0xFED8_0000)
	ivrs_entries_of_qemu(&builder, second)
	ivrs, problem := ivrs_read(ivrs_table(&builder))
	testing.expect_value(t, problem, Ivrs_Problem.None)
	testing.expect_value(t, ivrs.unit_kind, u8(AMD_BLOCK_UNIT_SECOND_FORM))
	testing.expect_value(t, ivrs.unit_count, u32(1))
	testing.expect_value(t, ivrs.units[0].register_base, u64(0xFED8_0000))
	testing.expect_value(t, ivrs.units[0].requester, requester(0, 2, 0))
	testing.expect(t, ivrs.names_interrupt_controller)
	testing.expect_value(t, ivrs.reserved_range_count, u32(0))
	// The functions 0:0.0 and 0:1.0 are the requesters 0 and 8, which do
	// not follow each other: two ranges.
	testing.expect_value(t, ivrs.ranges[0], Requester_Range{first = requester(0, 0, 0), last = requester(0, 0, 0)})
	testing.expect_value(t, ivrs.ranges[1], Requester_Range{first = requester(0, 1, 0), last = requester(0, 1, 0)})
	covered := [?]u16{requester(0, 0x10, 0), requester(0, 0x12, 0), requester(1, 0, 0), requester(1, 31, 7), requester(0, 0x1F, 3)}
	for identifier in covered {
		unit, is_covered, aliased := amd_unit_of(&ivrs, identifier)
		testing.expect(t, is_covered)
		testing.expect(t, !aliased)
		testing.expect_value(t, unit, u32(0))
	}
	// A function that no entry names: bus 2, a place of bus 0 with no
	// device.
	not_covered := [?]u16{requester(2, 0, 0), requester(0, 0x11, 0)}
	for identifier in not_covered {
		_, is_covered, _ := amd_unit_of(&ivrs, identifier)
		testing.expect(t, !is_covered)
	}
	// The IOAPIC of the special entry is kept with its requester.
	_, ioapic_covered, _ := amd_unit_of(&ivrs, requester(0, 0x14, 0))
	testing.expect(t, ioapic_covered)
	testing.expect_value(t, ivrs.units[0].capability_offset, u16(0))
}

// Adjacent select entries of one unit are one range.
@(test)
adjacent_entries_are_one_range :: proc(t: ^testing.T) {
	builder: Ivrs_Builder
	ivrs_builder_start(&builder)
	block := ivrs_unit_add(&builder, AMD_BLOCK_UNIT_SECOND_FORM, requester(0, 0, 2), 0xFED8_0000)
	for function in u32(0) ..< 8 {
		ivrs_entry_add(&builder, block, AMD_ENTRY_SELECT, requester(0, 3, function))
	}
	ivrs, problem := ivrs_read(ivrs_table(&builder))
	testing.expect_value(t, problem, Ivrs_Problem.None)
	testing.expect_value(t, ivrs.range_count, u32(1))
	testing.expect_value(t, ivrs.ranges[0], Requester_Range{first = requester(0, 3, 0), last = requester(0, 3, 7)})
}

// Two units with buses of their own. An alias range names its devices as
// aliased, and the target of the alias too: two requesters are one, so
// neither gets a domain. The target keeps the settings of the alias.
@(test)
two_units_and_an_alias :: proc(t: ^testing.T) {
	builder: Ivrs_Builder
	ivrs_builder_start(&builder)
	first := ivrs_unit_add(&builder, AMD_BLOCK_UNIT_FIRST_FORM, requester(0, 0, 2), 0xFEB8_0000)
	ivrs_entry_add(&builder, first, AMD_ENTRY_RANGE_START, requester(0, 0, 0))
	ivrs_entry_add(&builder, first, AMD_ENTRY_RANGE_END, requester(0x3F, 31, 7))
	second := ivrs_unit_add(&builder, AMD_BLOCK_UNIT_FIRST_FORM, requester(0x40, 0, 2), 0xFEA8_0000)
	ivrs_entry_add(&builder, second, AMD_ENTRY_RANGE_START, requester(0x41, 0, 0))
	ivrs_entry_add(&builder, second, AMD_ENTRY_RANGE_END, requester(0x41, 31, 7))
	ivrs_entry_add(&builder, second, AMD_ENTRY_ALIAS_RANGE_START, requester(0x42, 0, 0), requester(0x40, 8, 0), 0, 0xD7)
	ivrs_entry_add(&builder, second, AMD_ENTRY_RANGE_END, requester(0x42, 31, 7))
	ivrs_entry_add(&builder, second, AMD_ENTRY_ALIAS_SELECT, requester(0x43, 0, 1), requester(0x43, 0, 0))
	ivrs, problem := ivrs_read(ivrs_table(&builder))
	testing.expect_value(t, problem, Ivrs_Problem.None)
	testing.expect_value(t, ivrs.unit_count, u32(2))
	testing.expect(t, !ivrs.names_interrupt_controller)
	unit, covered, aliased := amd_unit_of(&ivrs, requester(0, 5, 0))
	testing.expect(t, covered && !aliased)
	testing.expect_value(t, unit, u32(0))
	unit, covered, aliased = amd_unit_of(&ivrs, requester(0x41, 2, 1))
	testing.expect(t, covered && !aliased)
	testing.expect_value(t, unit, u32(1))
	unit, covered, aliased = amd_unit_of(&ivrs, requester(0x42, 4, 0))
	testing.expect(t, covered && aliased)
	testing.expect_value(t, unit, u32(1))
	// The targets of the two aliases, and the source of the select alias.
	aliased_requesters := [?]u16{requester(0x40, 8, 0), requester(0x43, 0, 0), requester(0x43, 0, 1)}
	for identifier in aliased_requesters {
		_, covered, aliased = amd_unit_of(&ivrs, identifier)
		testing.expect(t, covered && aliased)
	}
	// The target of the alias range keeps its settings.
	target_settings: u8
	for item in ivrs.ranges[:ivrs.range_count] {
		if item.first == requester(0x40, 8, 0) {
			target_settings = item.settings
		}
	}
	testing.expect_value(t, target_settings, u8(0xD7))
	// Each alias names its target: the source of the range and its target
	// agree with the target only.
	testing.expect(t, amd_alias_agrees(&ivrs, requester(0x42, 4, 0), requester(0x40, 8, 0)))
	testing.expect(t, amd_alias_agrees(&ivrs, requester(0x40, 8, 0), requester(0x40, 8, 0)))
	testing.expect(t, !amd_alias_agrees(&ivrs, requester(0x42, 4, 0), requester(0x42, 0, 0)))
	testing.expect(t, amd_alias_agrees(&ivrs, requester(0x43, 0, 1), requester(0x43, 0, 0)))
	testing.expect(t, !amd_alias_agrees(&ivrs, requester(0x43, 0, 1), requester(0x40, 8, 0)))
	// A requester that no alias names agrees with any shared requester.
	testing.expect(t, amd_alias_agrees(&ivrs, requester(0x41, 2, 1), requester(0x40, 8, 0)))
}

// The table of QEMU 10 for the machine of the part iommu_amd: a bridge
// with no capability of PCI Express at 0:1C.0 (i82801b11-bridge), with bus
// 1 behind it. QEMU gives a select entry for the bridge, then an alias
// range from 1:0.0 to the last function of its subordinate bus, whose
// target is the bridge: what the walk of the bus finds as the shared
// requester of the devices behind it.
@(test)
the_alias_of_a_conventional_bridge_of_qemu :: proc(t: ^testing.T) {
	builder: Ivrs_Builder
	ivrs_builder_start(&builder)
	block := ivrs_unit_add(&builder, AMD_BLOCK_UNIT_SECOND_FORM, requester(0, 2, 0), 0xFED8_0000)
	ivrs_entry_add(&builder, block, AMD_ENTRY_SELECT, requester(0, 0x10, 0))
	ivrs_entry_add(&builder, block, AMD_ENTRY_SELECT, requester(0, 0x1C, 0))
	ivrs_entry_add(&builder, block, AMD_ENTRY_ALIAS_RANGE_START, requester(1, 0, 0), requester(0, 0x1C, 0))
	ivrs_entry_add(&builder, block, AMD_ENTRY_RANGE_END, requester(1, 31, 7))
	ivrs, problem := ivrs_read(ivrs_table(&builder))
	testing.expect_value(t, problem, Ivrs_Problem.None)
	bridge := requester(0, 0x1C, 0)
	members := [?]u16{requester(1, 0, 0), requester(1, 1, 0)}
	for member in members {
		_, covered, aliased := amd_unit_of(&ivrs, member)
		testing.expect(t, covered && aliased)
		testing.expect(t, amd_alias_agrees(&ivrs, member, bridge))
		testing.expect(t, !amd_alias_agrees(&ivrs, member, requester(1, 0, 0)))
	}
	// The bridge is the target of the alias and names itself.
	_, covered, aliased := amd_unit_of(&ivrs, bridge)
	testing.expect(t, covered && aliased)
	testing.expect(t, amd_alias_agrees(&ivrs, bridge, bridge))
	// A device of bus 0 is not aliased.
	_, covered, aliased = amd_unit_of(&ivrs, requester(0, 0x10, 0))
	testing.expect(t, covered && !aliased)
	// The walk of the bus found bus 1 behind the bridge: each source of the
	// alias is there.
	shared_of_bus: [256]u32
	shared_of_bus[1] = 1 + u32(bridge)
	testing.expect(t, amd_alias_sources_behind(&ivrs, bridge, &shared_of_bus))
	// With no bus behind the bridge, the source range is outside it.
	no_bus: [256]u32
	testing.expect(t, !amd_alias_sources_behind(&ivrs, bridge, &no_bus))
}

// The table of QEMU 10 behind a conventional bridge, and an alias from the
// device 0:10.0, which is not behind the bridge, to the requester of the
// bridge: the unit would translate the accesses of 0:10.0 with the domain
// of the group, so the group gets no domain.
@(test)
an_alias_from_outside_the_bridge_is_refused :: proc(t: ^testing.T) {
	builder: Ivrs_Builder
	ivrs_builder_start(&builder)
	block := ivrs_unit_add(&builder, AMD_BLOCK_UNIT_SECOND_FORM, requester(0, 2, 0), 0xFED8_0000)
	ivrs_entry_add(&builder, block, AMD_ENTRY_SELECT, requester(0, 0x10, 0))
	ivrs_entry_add(&builder, block, AMD_ENTRY_SELECT, requester(0, 0x1C, 0))
	ivrs_entry_add(&builder, block, AMD_ENTRY_ALIAS_RANGE_START, requester(1, 0, 0), requester(0, 0x1C, 0))
	ivrs_entry_add(&builder, block, AMD_ENTRY_RANGE_END, requester(1, 31, 7))
	ivrs_entry_add(&builder, block, AMD_ENTRY_ALIAS_SELECT, requester(0, 0x10, 0), requester(0, 0x1C, 0))
	ivrs, problem := ivrs_read(ivrs_table(&builder))
	testing.expect_value(t, problem, Ivrs_Problem.None)
	bridge := requester(0, 0x1C, 0)
	shared_of_bus: [256]u32
	shared_of_bus[1] = 1 + u32(bridge)
	// The member and the target still agree on the target of their own
	// alias: only the check of the sources refuses.
	testing.expect(t, amd_alias_agrees(&ivrs, requester(1, 0, 0), bridge))
	testing.expect(t, amd_alias_agrees(&ivrs, bridge, bridge))
	testing.expect(t, !amd_alias_sources_behind(&ivrs, bridge, &shared_of_bus))
}

// Two units that name one requester leave the IOMMU off, whatever the
// order of their blocks: an invalidation sent to one unit would leave the
// translations of the other.
@(test)
two_units_that_name_one_device :: proc(t: ^testing.T) {
	orders := [2]bool{true, false}
	for every_device_first in orders {
		builder: Ivrs_Builder
		ivrs_builder_start(&builder)
		first := ivrs_unit_add(&builder, AMD_BLOCK_UNIT_SECOND_FORM, requester(0, 0, 2), 0xFEB8_0000)
		second := 0
		if every_device_first {
			ivrs_entry_add(&builder, first, AMD_ENTRY_EVERY_DEVICE, 0)
			second = ivrs_unit_add(&builder, AMD_BLOCK_UNIT_SECOND_FORM, requester(0x40, 0, 2), 0xFEA8_0000)
			ivrs_entry_add(&builder, second, AMD_ENTRY_SELECT, requester(0x41, 0, 0))
		} else {
			ivrs_entry_add(&builder, first, AMD_ENTRY_SELECT, requester(0x41, 0, 0))
			second = ivrs_unit_add(&builder, AMD_BLOCK_UNIT_SECOND_FORM, requester(0x40, 0, 2), 0xFEA8_0000)
			ivrs_entry_add(&builder, second, AMD_ENTRY_EVERY_DEVICE, 0)
		}
		_, problem := ivrs_read(ivrs_table(&builder))
		testing.expect_value(t, problem, Ivrs_Problem.Units_Overlap)
	}
}

// The settings byte of an entry gives the pass bits of the device entry:
// the setting 0xD7 that firmware gives the device of the 8259 virtual wire
// passes INIT, ExtINT, NMI, LINT0 and LINT1.
@(test)
the_pass_bits :: proc(t: ^testing.T) {
	testing.expect_value(t, amd_pass_bits(0xD7), AMD_PASS_BITS)
	testing.expect_value(t, amd_pass_bits(0), u64(0))
	testing.expect_value(t, amd_pass_bits(0x40), AMD_PASS_LINT0)
	// The bits 3 to 5 (a reserved bit, SysMgt) give no pass bit.
	testing.expect_value(t, amd_pass_bits(0x38), u64(0))
	testing.expect_value(t, AMD_PASS_BITS, u64(1) << 56 | u64(1) << 57 | u64(1) << 58 | u64(1) << 62 | u64(1) << 63)
	// The interrupt word keeps the pass bits, with a table and without, and
	// with no remapping it is 0.
	testing.expect_value(t, amd_interrupt_word(true, 0, AMD_PASS_BITS), AMD_INTERRUPT_MAP_VALID | AMD_PASS_BITS)
	with_table := amd_interrupt_word(true, 0x0009_8080, AMD_PASS_LINT0)
	testing.expect_value(t, with_table & AMD_PASS_BITS, AMD_PASS_LINT0)
	testing.expect_value(t, with_table & AMD_INTERRUPT_REMAPPED, AMD_INTERRUPT_REMAPPED)
	testing.expect_value(t, amd_interrupt_word(false, 0x0009_8080, AMD_PASS_BITS), u64(0))
	// A pass value with other bits keeps the pass bits only.
	testing.expect_value(t, amd_interrupt_word(true, 0, max(u64)), AMD_INTERRUPT_MAP_VALID | AMD_PASS_BITS)
}

// The settings of entries that follow each other but differ stay apart.
@(test)
settings_keep_ranges_apart :: proc(t: ^testing.T) {
	builder: Ivrs_Builder
	ivrs_builder_start(&builder)
	block := ivrs_unit_add(&builder, AMD_BLOCK_UNIT_SECOND_FORM, requester(0, 0, 2), 0xFED8_0000)
	ivrs_entry_add(&builder, block, AMD_ENTRY_SELECT, requester(0, 0x14, 0), 0, 0, 0xD7)
	ivrs_entry_add(&builder, block, AMD_ENTRY_SELECT, requester(0, 0x14, 1))
	ivrs, problem := ivrs_read(ivrs_table(&builder))
	testing.expect_value(t, problem, Ivrs_Problem.None)
	testing.expect_value(t, ivrs.range_count, u32(2))
	testing.expect_value(t, ivrs.ranges[0].settings, u8(0xD7))
	testing.expect_value(t, ivrs.ranges[1].settings, u8(0))
}

// A reserved memory range of one device is kept with its device; a range
// of every device or of a range of devices leaves the IOMMU off.
@(test)
reserved_memory_ranges :: proc(t: ^testing.T) {
	builder: Ivrs_Builder
	ivrs_builder_start(&builder)
	block := ivrs_unit_add(&builder, AMD_BLOCK_UNIT_SECOND_FORM, requester(0, 0, 2), 0xFED8_0000)
	ivrs_entry_add(&builder, block, AMD_ENTRY_EVERY_DEVICE, 0)
	ivrs_reserved_add(&builder, AMD_BLOCK_RESERVED_ONE_DEVICE, requester(0, 0x14, 0), 0x7D00_0000, 0x10_0000)
	ivrs, problem := ivrs_read(ivrs_table(&builder))
	testing.expect_value(t, problem, Ivrs_Problem.None)
	testing.expect_value(t, ivrs.reserved_range_count, u32(1))
	testing.expect_value(t, ivrs.reserved_ranges[0], Reserved_Range{start = 0x7D00_0000, end = 0x7D10_0000})
	testing.expect_value(t, ivrs.reserved_requesters[0], requester(0, 0x14, 0))

	several_kinds := [?]u8{AMD_BLOCK_RESERVED_EVERY_DEVICE, AMD_BLOCK_RESERVED_DEVICE_RANGE}
	for kind in several_kinds {
		several: Ivrs_Builder
		ivrs_builder_start(&several)
		unit_block := ivrs_unit_add(&several, AMD_BLOCK_UNIT_SECOND_FORM, requester(0, 0, 2), 0xFED8_0000)
		ivrs_entry_add(&several, unit_block, AMD_ENTRY_EVERY_DEVICE, 0)
		ivrs_reserved_add(&several, kind, 0, 0x7D00_0000, 0x1000)
		_, problem = ivrs_read(ivrs_table(&several))
		testing.expect_value(t, problem, Ivrs_Problem.Reserved_Range_Of_Several_Devices)
	}

	// A range that is not whole pages, and a range that wraps.
	broken_sizes := [?]u64{0x800, max(u64) - 0xFFF}
	for size in broken_sizes {
		broken: Ivrs_Builder
		ivrs_builder_start(&broken)
		unit_block := ivrs_unit_add(&broken, AMD_BLOCK_UNIT_SECOND_FORM, requester(0, 0, 2), 0xFED8_0000)
		ivrs_entry_add(&broken, unit_block, AMD_ENTRY_EVERY_DEVICE, 0)
		ivrs_reserved_add(&broken, AMD_BLOCK_RESERVED_ONE_DEVICE, 0, 0x7D00_0000, size)
		_, problem = ivrs_read(ivrs_table(&broken))
		testing.expect_value(t, problem, Ivrs_Problem.Bad_Structure)
	}
}

// The tables that the kernel refuses.
@(test)
tables_that_the_kernel_refuses :: proc(t: ^testing.T) {
	short: [AMD_IVRS_BLOCKS_START - 1]u8
	_, problem := ivrs_read(short[:])
	testing.expect_value(t, problem, Ivrs_Problem.Too_Short)

	// No unit block: only a reserved range of one device.
	no_unit: Ivrs_Builder
	ivrs_builder_start(&no_unit)
	ivrs_reserved_add(&no_unit, AMD_BLOCK_RESERVED_ONE_DEVICE, 0, 0x7D00_0000, 0x1000)
	_, problem = ivrs_read(ivrs_table(&no_unit))
	testing.expect_value(t, problem, Ivrs_Problem.No_Unit)

	// A unit of segment 1.
	segment: Ivrs_Builder
	ivrs_builder_start(&segment)
	ivrs_unit_add(&segment, AMD_BLOCK_UNIT_SECOND_FORM, 0, 0xFED8_0000, 1)
	_, problem = ivrs_read(ivrs_table(&segment))
	testing.expect_value(t, problem, Ivrs_Problem.Other_Segment)

	// Five units.
	many: Ivrs_Builder
	ivrs_builder_start(&many)
	for index in 0 ..< UNIT_CAPACITY + 1 {
		ivrs_unit_add(&many, AMD_BLOCK_UNIT_SECOND_FORM, u16(index), 0xFED8_0000 + u64(index) * 0x8_0000)
	}
	_, problem = ivrs_read(ivrs_table(&many))
	testing.expect_value(t, problem, Ivrs_Problem.Too_Many_Units)

	// A range with no end, and an end with no range.
	open_range: Ivrs_Builder
	ivrs_builder_start(&open_range)
	open_block := ivrs_unit_add(&open_range, AMD_BLOCK_UNIT_SECOND_FORM, 0, 0xFED8_0000)
	ivrs_entry_add(&open_range, open_block, AMD_ENTRY_RANGE_START, requester(1, 0, 0))
	_, problem = ivrs_read(ivrs_table(&open_range))
	testing.expect_value(t, problem, Ivrs_Problem.Bad_Structure)
	lone_end: Ivrs_Builder
	ivrs_builder_start(&lone_end)
	end_block := ivrs_unit_add(&lone_end, AMD_BLOCK_UNIT_SECOND_FORM, 0, 0xFED8_0000)
	ivrs_entry_add(&lone_end, end_block, AMD_ENTRY_RANGE_END, requester(1, 0, 0))
	_, problem = ivrs_read(ivrs_table(&lone_end))
	testing.expect_value(t, problem, Ivrs_Problem.Bad_Structure)

	// A block whose length runs past the table.
	long_block: Ivrs_Builder
	ivrs_builder_start(&long_block)
	long_start := ivrs_unit_add(&long_block, AMD_BLOCK_UNIT_SECOND_FORM, 0, 0xFED8_0000)
	store_16(long_block.bytes[:], long_start + 2, 200)
	_, problem = ivrs_read(ivrs_table(&long_block))
	testing.expect_value(t, problem, Ivrs_Problem.Bad_Structure)

	// A device entry cut by the end of its block: an entry of 8 bytes with
	// 4 bytes left.
	cut: Ivrs_Builder
	ivrs_builder_start(&cut)
	cut_block := ivrs_unit_add(&cut, AMD_BLOCK_UNIT_SECOND_FORM, 0, 0xFED8_0000)
	ivrs_entry_add(&cut, cut_block, AMD_ENTRY_SELECT, 0)
	cut.bytes[cut.length - 4] = AMD_ENTRY_ALIAS_SELECT
	_, problem = ivrs_read(ivrs_table(&cut))
	testing.expect_value(t, problem, Ivrs_Problem.Bad_Structure)

	// More ranges than the kernel keeps: one select entry of each second
	// function, so that no two follow each other.
	full: Ivrs_Builder
	ivrs_builder_start(&full)
	full_block := ivrs_unit_add(&full, AMD_BLOCK_UNIT_SECOND_FORM, 0, 0xFED8_0000)
	for index in 0 ..< AMD_REQUESTER_RANGE_CAPACITY + 1 {
		ivrs_entry_add(&full, full_block, AMD_ENTRY_SELECT, u16(index * 2))
	}
	_, problem = ivrs_read(ivrs_table(&full))
	testing.expect_value(t, problem, Ivrs_Problem.Too_Many_Device_Entries)
}

// The entry of a device table: the empty domain refuses every access with
// a mode that is not 0, and a domain names its tables and its identifier.
@(test)
the_entry_of_a_device :: proc(t: ^testing.T) {
	empty := amd_translation_words(0x0123_4000, AMD_LEVELS, 0, false)
	testing.expect_value(t, empty[0], u64(0x0123_4000) | AMD_DEVICE_ENTRY_VALID | AMD_DEVICE_ENTRY_TRANSLATION_VALID | 4 << 9)
	testing.expect_value(t, empty[0] & (AMD_DEVICE_ENTRY_READ | AMD_DEVICE_ENTRY_WRITE), u64(0))
	testing.expect(t, empty[0] >> 9 & 7 != 0)
	testing.expect_value(t, empty[1], u64(0))
	domain := amd_translation_words(0x0567_8000, AMD_LEVELS, 33, true)
	testing.expect_value(t, domain[0], u64(0x0567_8000) | AMD_DEVICE_ENTRY_VALID | AMD_DEVICE_ENTRY_TRANSLATION_VALID | 4 << 9 | AMD_DEVICE_ENTRY_READ | AMD_DEVICE_ENTRY_WRITE)
	testing.expect_value(t, domain[1], u64(33))
	// The bits that QEMU 10 checks as reserved stay 0: 6:2 and 63.
	testing.expect_value(t, domain[0] & (0x7C | u64(1) << 63), u64(0))

	testing.expect_value(t, amd_interrupt_word(false, 0x1000, 0), u64(0))
	testing.expect_value(t, amd_interrupt_word(true, 0, 0), AMD_INTERRUPT_MAP_VALID)
	word := amd_interrupt_word(true, 0x0009_8080, 0)
	testing.expect_value(t, word, AMD_INTERRUPT_MAP_VALID | 4 << 1 | u64(0x0009_8080) | u64(2) << 60)
	// The bits 53:52, which QEMU 10 checks as reserved, stay 0.
	testing.expect_value(t, word & (u64(3) << 52), u64(0))
	testing.expect_value(t, amd_device_table_register(0x0040_0000, AMD_DEVICE_TABLE_PAGES), u64(0x0040_0000) | 511)
}

// The function of a unit: its class, its capability header with NpCache,
// and the mask register of its message interrupt.
@(test)
the_function_of_a_unit :: proc(t: ^testing.T) {
	// QEMU 10: the class 0x0806, the revision 0 in the low byte.
	testing.expect(t, amd_function_is_unit(0x0806_0000))
	testing.expect(t, !amd_function_is_unit(0x0100_0000)) // A disk.
	// QEMU 10: the kind 0x0F with NpCache.
	testing.expect(t, amd_caches_not_present(0x0F | AMD_CAPABILITY_NOT_PRESENT_CACHE))
	testing.expect(t, !amd_caches_not_present(0x0F))
	testing.expect(t, amd_caches_not_present(0x05)) // Another kind: invalidate each entry.
	testing.expect_value(t, message_mask_register(0x54, 0), u32(0))
	testing.expect_value(t, message_mask_register(0x54, MESSAGE_CONTROL_MASKS), u32(0x54 + 12))
	testing.expect_value(t, message_mask_register(0x54, MESSAGE_CONTROL_MASKS | MESSAGE_CONTROL_64_BITS), u32(0x54 + 16))
}

// The entries of the page tables of AMD.
@(test)
the_entries_of_the_page_tables :: proc(t: ^testing.T) {
	table := amd_table_entry(0x0012_3000, 3)
	testing.expect(t, amd_entry_present(table))
	testing.expect_value(t, table >> 9 & 7, u64(3))
	testing.expect_value(t, table & ENTRY_ADDRESS, u64(0x0012_3000))
	testing.expect_value(t, table & (AMD_ENTRY_READ | AMD_ENTRY_WRITE), AMD_ENTRY_READ | AMD_ENTRY_WRITE)
	page := amd_page_entry(0x0045_6000, false)
	testing.expect(t, amd_entry_present(page))
	testing.expect_value(t, page >> 9 & 7, u64(0))
	testing.expect_value(t, page & AMD_ENTRY_WRITE, u64(0))
	testing.expect_value(t, page & AMD_ENTRY_READ, AMD_ENTRY_READ)
	testing.expect_value(t, amd_page_entry(0x0045_6000, true) & AMD_ENTRY_WRITE, AMD_ENTRY_WRITE)
	testing.expect(t, !amd_entry_present(0))
	// A page entry with the write taken out is still present.
	testing.expect(t, amd_entry_present(amd_page_entry(0x0045_6000, true) &~ AMD_ENTRY_WRITE))
}

// The commands, with the reserved bits that QEMU 10 checks at 0.
@(test)
the_commands :: proc(t: ^testing.T) {
	wait := amd_command_wait(0x0010_0040, 7)
	testing.expect_value(t, wait[0] >> 60, AMD_COMMAND_COMPLETION_WAIT)
	testing.expect_value(t, wait[0] & 1, u64(1)) // The store of the number.
	testing.expect_value(t, wait[0] & 2, u64(0)) // No interrupt.
	testing.expect_value(t, wait[0] >> 3 & (u64(1) << 49 - 1) << 3, u64(0x0010_0040))
	testing.expect_value(t, wait[0] >> 52 & 0xFF, u64(0))
	testing.expect_value(t, wait[1], u64(7))

	entry := amd_command_device_entry(requester(1, 0, 0))
	testing.expect_value(t, entry[0], AMD_COMMAND_INVALIDATE_DEVICE_ENTRY << 60 | 0x100)
	testing.expect_value(t, entry[1], u64(0))

	pages := amd_command_pages(33)
	testing.expect_value(t, pages[0] >> 60, AMD_COMMAND_INVALIDATE_PAGES)
	testing.expect_value(t, pages[0] >> 32 & 0xFFFF, u64(33))
	testing.expect_value(t, pages[0] >> 20 & 0xFFF, u64(0))
	testing.expect_value(t, pages[0] >> 48 & 0xFFF, u64(0))
	testing.expect_value(t, pages[1] & 7, u64(3)) // S and PDE.
	testing.expect_value(t, pages[1] >> 3 & 0x1FF, u64(0))

	table := amd_command_interrupt_table(requester(0, 0x11, 0))
	testing.expect_value(t, table[0], AMD_COMMAND_INVALIDATE_INTERRUPT_TABLE << 60 | 0x88)
	testing.expect_value(t, amd_command_all(), [2]u64{AMD_COMMAND_INVALIDATE_ALL << 60, 0})

	testing.expect_value(t, amd_ring_register(0x0020_0000), u64(0x0020_0000) | u64(8) << 56)
	testing.expect_value(t, amd_device_table_register(0x0040_0000, 512), u64(0x0040_0000) | 511)
	testing.expect_value(t, amd_ring_offset(amd_ring_register_of(255)), u32(255 * 16))
	testing.expect_value(t, amd_ring_register_of(256), u64(0))
}

// The records of the event log: a page fault of QEMU 10, which sets the
// flag I on each one and gives the access in the flags 0 and 1, and a
// refused message interrupt of the specification.
@(test)
the_records_of_the_event_log :: proc(t: ^testing.T) {
	// QEMU: the device 0:11.0, a write of 0x3f2a5123: the flags 0x8 | 0x2.
	low := u64(AMD_EVENT_PAGE_FAULT) << 60 | u64(0x0A) << 48 | u64(requester(0, 0x11, 0))
	event := amd_event_read(low, 0x3F2A_5123)
	testing.expect_value(t, event.kind, u8(AMD_EVENT_PAGE_FAULT))
	testing.expect_value(t, event.requester, requester(0, 0x11, 0))
	fault := amd_event_fault(event)
	testing.expect(t, !fault.interrupt)
	testing.expect_value(t, fault.address, u64(0x3F2A_5000))
	testing.expect_value(t, fault.reason, u16(0x0A))
	testing.expect(t, fault.read)
	// The specification: a write (RW).
	write := amd_event_fault(amd_event_read(u64(AMD_EVENT_PAGE_FAULT) << 60 | u64(AMD_EVENT_FLAG_WRITE) << 48, 0x1000))
	testing.expect(t, !write.read)
	// A message interrupt that the unit refused: the flag I and an address
	// of the interrupts.
	refused := amd_event_fault(amd_event_read(u64(AMD_EVENT_PAGE_FAULT) << 60 | u64(AMD_EVENT_FLAG_INTERRUPT | AMD_EVENT_FLAG_WRITE) << 48 | 0x100, 0xFEE0_0000))
	testing.expect(t, refused.interrupt)
	testing.expect_value(t, refused.address, u64(0xFEE0_0000))
	testing.expect_value(t, refused.requester, u16(0x100))
}

// The entry of an interrupt table, and the message of a device.
@(test)
the_interrupt_entry :: proc(t: ^testing.T) {
	entry := amd_interrupt_entry(52, 3)
	testing.expect_value(t, entry & 1, u32(1)) // RemapEn.
	testing.expect_value(t, entry >> 1 & 1, u32(0)) // Faults recorded.
	testing.expect_value(t, entry >> 2 & 7, u32(0)) // Fixed delivery.
	testing.expect_value(t, entry >> 6 & 3, u32(0)) // Physical mode, not a guest.
	testing.expect_value(t, entry >> 8 & 0xFF, u32(3))
	testing.expect_value(t, entry >> 16 & 0xFF, u32(52))
	testing.expect_value(t, amd_message_address(3), u64(0xFEE0_3000))
}

// The capability of the message interrupt of a function, after another
// capability, and its registers of 32 and of 64 bits.
@(test)
the_message_interrupt_of_a_unit :: proc(t: ^testing.T) {
	configuration: [CONFIGURATION_WORDS]u32
	configuration[1] = STATUS_CAPABILITIES
	configuration[0x34 / 4] = 0x40
	configuration[0x40 / 4] = 0x0F | 0x54 << 8 // The capability of a unit of AMD, then the next one.
	configuration[0x54 / 4] = CAPABILITY_MESSAGE | u32(MESSAGE_CONTROL_64_BITS) << 16
	testing.expect_value(t, capability_offset(&configuration, CAPABILITY_MESSAGE), u32(0x54))
	testing.expect_value(t, capability_offset(&configuration, 0x10), u32(0))
	low, high, value := message_registers(0x54, MESSAGE_CONTROL_64_BITS)
	testing.expect_value(t, [3]u32{low, high, value}, [3]u32{0x58, 0x5C, 0x60})
	low, high, value = message_registers(0x54, 0)
	testing.expect_value(t, [3]u32{low, high, value}, [3]u32{0x58, 0, 0x5C})
	testing.expect_value(t, message_control_enabled(MESSAGE_CONTROL_64_BITS | 3 << 4), MESSAGE_CONTROL_64_BITS | MESSAGE_CONTROL_ENABLE)
	// A list that loops ends.
	configuration[0x54 / 4] = 0x09 | 0x40 << 8
	testing.expect_value(t, capability_offset(&configuration, CAPABILITY_MESSAGE), u32(0))
}
