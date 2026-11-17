package modustool

import iommu "modus:contract/iommu"

// The fuzz target of the tables of the firmware
// (src/md/infrastructure/fuzzing.md, "The targets, in order of value"): the
// kernel reads the ACPI tables DMAR, IVRS and MCFG at its start with the
// readers of `contract/iommu`, which run on the host as they run in the
// kernel. The search of the processors in the ACPI tables reads raw
// addresses inside the kernel, and no host code calls it.

// The first byte of an input chooses the table; the bytes after it are the
// table, with its ACPI header.
@(private = "file")
Fuzz_Firmware_Table :: enum u8 {
	Dmar,
	Ivrs,
	Mcfg,
}

// fuzz_bridge_read is the bus of the target: a bridge at each even device,
// whose secondary bus follows its own bus by its function plus one.
@(private = "file")
fuzz_bridge_read :: proc "contextless" (bus, device, function: u32) -> (secondary: u32, subordinate: u32, found: bool) {
	if device % 2 != 0 {
		return 0, 0, false
	}
	secondary = bus + function + 1
	return secondary, secondary + device / 2, true
}

fuzz_firmware_tables_execute :: proc(input: []u8) -> Fuzz_Verdict {
	if len(input) == 0 {
		return FUZZ_PASSED
	}
	table := input[1:]
	switch enum_member_at(Fuzz_Firmware_Table, int(input[0]) % len(Fuzz_Firmware_Table)) {
	case .Dmar:
		return fuzz_dmar_check(table)
	case .Ivrs:
		return fuzz_ivrs_check(table)
	case .Mcfg:
		memory, found := iommu.mcfg_read(table)
		if found && (memory.first_bus != 0 || memory.last_bus < memory.first_bus) {
			return fuzz_broken(.Contract, "mcfg_read gives the buses %d to %d", memory.first_bus, memory.last_bus)
		}
	}
	return FUZZ_PASSED
}

// fuzz_dmar_check: a table that dmar_read accepts has its counts in their
// arrays, each scope a path of 1 to PATH_CAPACITY pairs of its owner, and
// whole pages in each reserved range; unit_of gives a unit of the table.
@(private = "file")
fuzz_dmar_check :: proc(table: []u8) -> Fuzz_Verdict {
	dmar, problem := iommu.dmar_read(table)
	if problem > max(iommu.Dmar_Problem) {
		return fuzz_broken(.Contract, "dmar_read gives a problem out of its enumeration: %d", u8(problem))
	}
	if problem != .None {
		return FUZZ_PASSED
	}
	if dmar.unit_count == 0 || dmar.unit_count > iommu.UNIT_CAPACITY || dmar.reserved_range_count > iommu.RESERVED_RANGE_CAPACITY || dmar.scope_count > iommu.SCOPE_CAPACITY {
		return fuzz_broken(.Contract, "dmar_read gives %d units, %d ranges, %d scopes", dmar.unit_count, dmar.reserved_range_count, dmar.scope_count)
	}
	for &scope, index in dmar.scopes[:dmar.scope_count] {
		owners := scope.reserved ? dmar.reserved_range_count : dmar.unit_count
		if scope.path_length == 0 || scope.path_length > iommu.PATH_CAPACITY || u32(scope.owner) >= owners {
			return fuzz_broken(.Contract, "the scope %d has %d pairs and the owner %d", index, scope.path_length, scope.owner)
		}
		for pair in scope.path[:scope.path_length] {
			if pair[0] > 31 || pair[1] > 7 {
				return fuzz_broken(.Contract, "the scope %d names the device %d, function %d", index, pair[0], pair[1])
			}
		}
	}
	for item, index in dmar.reserved_ranges[:dmar.reserved_range_count] {
		if item.start % 4096 != 0 || item.end % 4096 != 0 || item.end <= item.start {
			return fuzz_broken(.Contract, "the reserved range %d is %x to %x", index, item.start, item.end)
		}
	}
	resolved: [iommu.SCOPE_CAPACITY]iommu.Resolved_Scope
	requesters := make([dynamic]u16, context.temp_allocator)
	append(&requesters, 0, max(u16))
	for scope, index in dmar.scopes[:dmar.scope_count] {
		resolved[index] = iommu.scope_resolve(scope, fuzz_bridge_read)
		if resolved[index].found {
			append(&requesters, resolved[index].requester)
			if scope.bridge && resolved[index].last_bus < resolved[index].first_bus {
				return fuzz_broken(.Contract, "the bridge of the scope %d ends before it starts", index)
			}
		}
	}
	for requester in requesters {
		unit, covered := iommu.unit_of(&dmar, &resolved, requester)
		if covered && unit >= dmar.unit_count {
			return fuzz_broken(.Contract, "unit_of gives the unit %d of %d", unit, dmar.unit_count)
		}
	}
	return FUZZ_PASSED
}

// fuzz_ivrs_check: a table that ivrs_read accepts has its counts in their
// arrays, each range of requesters in order and of a unit of the table,
// no requester of two units, and whole pages in each reserved range.
@(private = "file")
fuzz_ivrs_check :: proc(table: []u8) -> Fuzz_Verdict {
	ivrs, problem := iommu.ivrs_read(table)
	if problem > max(iommu.Ivrs_Problem) {
		return fuzz_broken(.Contract, "ivrs_read gives a problem out of its enumeration: %d", u8(problem))
	}
	if problem != .None {
		return FUZZ_PASSED
	}
	if ivrs.unit_count == 0 || ivrs.unit_count > iommu.UNIT_CAPACITY || ivrs.range_count > iommu.AMD_REQUESTER_RANGE_CAPACITY || ivrs.reserved_range_count > iommu.RESERVED_RANGE_CAPACITY {
		return fuzz_broken(.Contract, "ivrs_read gives %d units, %d ranges, %d reserved ranges", ivrs.unit_count, ivrs.range_count, ivrs.reserved_range_count)
	}
	ranges := ivrs.ranges[:ivrs.range_count]
	for item, index in ranges {
		if item.first > item.last || u32(item.unit) >= ivrs.unit_count {
			return fuzz_broken(.Contract, "the range %d is %x to %x of the unit %d", index, item.first, item.last, item.unit)
		}
		for other in ranges[index + 1:] {
			if other.unit != item.unit && other.first <= item.last && item.first <= other.last {
				return fuzz_broken(.Contract, "two units name one requester")
			}
		}
		for requester in ([2]u16{item.first, item.last}) {
			unit, covered, _ := iommu.amd_unit_of(&ivrs, requester)
			if !covered || unit != u32(item.unit) {
				return fuzz_broken(.Two_Readers, "amd_unit_of gives the unit %d for a requester of the unit %d", unit, item.unit)
			}
			_ = iommu.amd_alias_agrees(&ivrs, requester, item.alias_target)
		}
		shared_of_bus: [256]u32
		_ = iommu.amd_alias_sources_behind(&ivrs, item.alias_target, &shared_of_bus)
	}
	for item, index in ivrs.reserved_ranges[:ivrs.reserved_range_count] {
		if item.start % 4096 != 0 || item.end % 4096 != 0 || item.end <= item.start {
			return fuzz_broken(.Contract, "the reserved range %d is %x to %x", index, item.start, item.end)
		}
	}
	return FUZZ_PASSED
}

// fuzz_firmware_table_start gives a table with its ACPI header: the
// signature, the length that the reader does not read, and zero bytes to
// the first structure.
@(private = "file")
fuzz_firmware_table_start :: proc(table: ^[dynamic]u8, kind: Fuzz_Firmware_Table, signature: string, size: int) {
	append(table, u8(kind))
	append(table, ..transmute([]u8)signature)
	for len(table) < 1 + size {
		append(table, 0)
	}
}

// fuzz_firmware_word appends a little-endian word of `size` bytes.
@(private = "file")
fuzz_firmware_word :: proc(table: ^[dynamic]u8, size: int, value: u64) {
	for index in 0 ..< size {
		append(table, u8(value >> (8 * u64(index))))
	}
}

fuzz_firmware_tables_seeds :: proc(seeds: ^[dynamic][]u8) {
	// DMAR: one unit of every device with an endpoint and a bridge, then
	// a reserved range of one page with an endpoint.
	dmar := make([dynamic]u8)
	fuzz_firmware_table_start(&dmar, .Dmar, "DMAR", iommu.DMAR_STRUCTURES_START)
	dmar[1 + iommu.DMAR_HOST_ADDRESS_WIDTH] = 38
	dmar[1 + iommu.DMAR_FLAGS] = iommu.DMAR_FLAG_INTERRUPT_REMAPPING
	scopes := [?]u8{iommu.SCOPE_ENDPOINT, 8, 0, 0, 0, 0, 2, 0, iommu.SCOPE_BRIDGE, 10, 0, 0, 0, 0, 0, 0, 4, 1}
	fuzz_firmware_word(&dmar, 2, iommu.STRUCTURE_UNIT)
	fuzz_firmware_word(&dmar, 2, u64(iommu.UNIT_SIZE + len(scopes)))
	append(&dmar, iommu.UNIT_INCLUDES_EVERY_DEVICE, 0)
	fuzz_firmware_word(&dmar, 2, 0)
	fuzz_firmware_word(&dmar, 8, 0xFED9_0000)
	append(&dmar, ..scopes[:])
	fuzz_firmware_word(&dmar, 2, iommu.STRUCTURE_RESERVED_MEMORY)
	fuzz_firmware_word(&dmar, 2, iommu.RESERVED_MEMORY_SIZE + 8)
	fuzz_firmware_word(&dmar, 4, 0)
	fuzz_firmware_word(&dmar, 8, 0x7000_0000)
	fuzz_firmware_word(&dmar, 8, 0x7000_0FFF)
	append(&dmar, ..scopes[:8])
	append(seeds, dmar[:])

	// IVRS: a unit block with a range, a device and an IOAPIC, then a
	// reserved range of one device.
	ivrs := make([dynamic]u8)
	fuzz_firmware_table_start(&ivrs, .Ivrs, "IVRS", iommu.AMD_IVRS_BLOCKS_START)
	entries := [?]u8{
		iommu.AMD_ENTRY_RANGE_START, 0x08, 0x00, 0,
		iommu.AMD_ENTRY_RANGE_END, 0xFF, 0x00, 0,
		iommu.AMD_ENTRY_SELECT, 0x00, 0x01, 0xD7,
		iommu.AMD_ENTRY_SPECIAL, 0, 0, 0xD7, 0, 0xA0, 0x00, iommu.AMD_SPECIAL_VARIETY_INTERRUPT_CONTROLLER,
	}
	append(&ivrs, iommu.AMD_BLOCK_UNIT_FIRST_FORM, 0)
	fuzz_firmware_word(&ivrs, 2, u64(iommu.AMD_BLOCK_UNIT_FIRST_FORM_HEADER + len(entries)))
	fuzz_firmware_word(&ivrs, 2, 0x0002)
	fuzz_firmware_word(&ivrs, 2, 0x40)
	fuzz_firmware_word(&ivrs, 8, 0xFEB8_0000)
	fuzz_firmware_word(&ivrs, 8, 0)
	append(&ivrs, ..entries[:])
	append(&ivrs, iommu.AMD_BLOCK_RESERVED_ONE_DEVICE, 0)
	fuzz_firmware_word(&ivrs, 2, iommu.AMD_BLOCK_RESERVED_SIZE)
	fuzz_firmware_word(&ivrs, 2, 0x0010)
	fuzz_firmware_word(&ivrs, 2, 0)
	fuzz_firmware_word(&ivrs, 8, 0)
	fuzz_firmware_word(&ivrs, 8, 0x7000_0000)
	fuzz_firmware_word(&ivrs, 8, 4096)
	append(seeds, ivrs[:])

	// MCFG: a range of another segment, then the range of bus 0.
	mcfg := make([dynamic]u8)
	fuzz_firmware_table_start(&mcfg, .Mcfg, "MCFG", iommu.MCFG_ENTRIES_START)
	for segment in ([?]u64{1, 0}) {
		fuzz_firmware_word(&mcfg, 8, 0xB000_0000)
		fuzz_firmware_word(&mcfg, 2, segment)
		append(&mcfg, 0, 0xFF)
		fuzz_firmware_word(&mcfg, 4, 0)
	}
	append(seeds, mcfg[:])
	// Each table one byte short of its first structure.
	for start, kind in ([Fuzz_Firmware_Table]int{.Dmar = iommu.DMAR_STRUCTURES_START, .Ivrs = iommu.AMD_IVRS_BLOCKS_START, .Mcfg = iommu.MCFG_ENTRIES_START}) {
		short := make([]u8, start)
		short[0] = u8(kind)
		append(seeds, short)
	}
}
