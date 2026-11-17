package iommu

import "modus:contract/bridge_requester"

// The formats of the IOMMU of AMD (AMD-Vi) that the kernel reads and
// writes: the ACPI table IVRS, the registers of a unit, the entry of the
// device table, the entries of the page tables, the commands of the queue
// of invalidations, the records of the event log, the entry of an interrupt table, and
// the message interrupt of the function of a unit. The formats are those of
// the "AMD I/O Virtualization Technology (IOMMU) Specification". The design
// is src/md/infrastructure/iommu.md, "Two vendors behind one kernel side".
//
// The names of this file start with AMD or amd: the formats of VT-d in
// iommu.odin have the same parts, with other bits.

// The table IVRS: the ACPI header, the information of 4 bytes, 8 reserved
// bytes, then the blocks. Each block starts with its kind (1 byte), its
// flags (1 byte) and its length (2 bytes).
AMD_IVRS_BLOCKS_START :: 48

// The kinds of a block of the table IVRS.
AMD_BLOCK_UNIT_FIRST_FORM :: 0x10 // A unit (IVHD), with a header of 24 bytes.
AMD_BLOCK_UNIT_SECOND_FORM :: 0x11 // A unit, with a header of 40 bytes.
AMD_BLOCK_UNIT_THIRD_FORM :: 0x40 // A unit, with a header of 40 bytes and the entries of ACPI devices.
AMD_BLOCK_RESERVED_EVERY_DEVICE :: 0x20 // A reserved memory range (IVMD) of every device.
AMD_BLOCK_RESERVED_ONE_DEVICE :: 0x21 // A reserved memory range of one device.
AMD_BLOCK_RESERVED_DEVICE_RANGE :: 0x22 // A reserved memory range of a range of devices.
AMD_BLOCK_UNIT_FIRST_FORM_HEADER :: 24
AMD_BLOCK_UNIT_HEADER :: 40
// A reserved memory range: the kind, the flags, the length, the device, 2
// bytes, 8 reserved bytes, the first byte and the size, of 8 bytes each.
AMD_BLOCK_RESERVED_SIZE :: 32

// The kinds of a device entry of a unit block. The bits 7:6 of the kind
// give the size of the entry: 4, 8, 16 or 32 bytes. The kind 0xF0 has its
// own size. The requester of an entry is in its bytes 1 and 2.
AMD_ENTRY_EVERY_DEVICE :: 0x01
AMD_ENTRY_SELECT :: 0x02
AMD_ENTRY_RANGE_START :: 0x03
AMD_ENTRY_RANGE_END :: 0x04
AMD_ENTRY_ALIAS_SELECT :: 0x42 // A device whose accesses carry the requester of the bytes 5 and 6.
AMD_ENTRY_ALIAS_RANGE_START :: 0x43
AMD_ENTRY_EXTENDED_SELECT :: 0x46
AMD_ENTRY_EXTENDED_RANGE_START :: 0x47
AMD_ENTRY_SPECIAL :: 0x48 // An IOAPIC or a timer: its variety in the byte 7.
AMD_ENTRY_ACPI_DEVICE :: 0xF0 // A device of ACPI: 22 bytes, then the length of its identifier (the byte 21).
AMD_ACPI_DEVICE_ENTRY_HEADER :: 22
AMD_SPECIAL_VARIETY_INTERRUPT_CONTROLLER :: 1 // The IOAPIC.

// The ranges of requesters that the blocks of the units name. Adjacent
// entries of one unit are one range: a block names each device of bus 0 by
// one entry.
AMD_REQUESTER_RANGE_CAPACITY :: 256

// A range of requesters that one unit translates.
Requester_Range :: struct {
	first:        u16,
	last:         u16,
	unit:         u8,
	aliased:      bool, // The devices of the range share a requester with another device: the source of an alias, or its target.
	settings:     u8, // The byte 3 of the entry: the messages that the unit passes for the device (amd_pass_bits).
	alias_target: u16, // An aliased range: the requester that the unit sees for its devices. The target of an alias names itself.
}

// A unit of AMD as the table gives it.
Amd_Unit :: struct {
	register_base:     u64,
	requester:         u16, // The function of PCI of the unit itself.
	capability_offset: u16, // The place of its capability header in the configuration of that function.
}

// What the kernel found in the table IVRS.
Ivrs :: struct {
	unit_kind:                  u8, // The kind of the unit blocks that the kernel read.
	unit_count:                 u32,
	units:                      [UNIT_CAPACITY]Amd_Unit,
	range_count:                u32,
	ranges:                     [AMD_REQUESTER_RANGE_CAPACITY]Requester_Range,
	reserved_range_count:       u32,
	reserved_ranges:            [RESERVED_RANGE_CAPACITY]Reserved_Range,
	reserved_requesters:        [RESERVED_RANGE_CAPACITY]u16, // The one device of each reserved range.
	names_interrupt_controller: bool, // A unit names an IOAPIC: the platform remaps interrupts.
}

// Why the kernel does not use the units of a table IVRS.
Ivrs_Problem :: enum u8 {
	None,
	Too_Short, // The table ends before its first block.
	Bad_Structure, // A block or a device entry has a wrong length, a range has no end, or a reserved range is not whole pages.
	No_Unit, // No unit block.
	Too_Many_Units, // More than UNIT_CAPACITY units.
	Other_Segment, // A unit of a segment of PCI other than 0.
	Too_Many_Ranges, // More than RESERVED_RANGE_CAPACITY reserved ranges.
	Too_Many_Device_Entries, // More than AMD_REQUESTER_RANGE_CAPACITY ranges of requesters.
	Reserved_Range_Of_Several_Devices, // A reserved range of every device, or of a range of devices.
	Units_Overlap, // Two units name one requester.
}

// The text of each problem, after "no IOMMU in use: " on the log.
@(rodata)
IVRS_PROBLEM_TEXTS := [Ivrs_Problem]string {
	.None                              = "none",
	.Too_Short                         = "the I/O virtualization table is too short",
	.Bad_Structure                     = "a block or a device entry of the I/O virtualization table has a wrong length, a range of devices has no end, or a reserved range is not whole pages",
	.No_Unit                           = "the I/O virtualization table has no unit",
	.Too_Many_Units                    = "the I/O virtualization table has more than 4 units",
	.Other_Segment                     = "a unit is of a segment of PCI other than 0",
	.Too_Many_Ranges                   = "the I/O virtualization table has more than 8 reserved memory ranges",
	.Too_Many_Device_Entries           = "the I/O virtualization table names more than 256 ranges of devices",
	.Reserved_Range_Of_Several_Devices = "a reserved memory range of the I/O virtualization table is for every device or for a range of devices",
	.Units_Overlap                     = "two units of the I/O virtualization table name one device",
}

// amd_unit_block_kind says if a block kind is a unit block that the kernel
// reads.
amd_unit_block_kind :: proc "contextless" (kind: u8) -> bool {
	return kind == AMD_BLOCK_UNIT_FIRST_FORM || kind == AMD_BLOCK_UNIT_SECOND_FORM || kind == AMD_BLOCK_UNIT_THIRD_FORM
}

// ivrs_read reads the table IVRS: its bytes, with the size of its header.
// The firmware can describe one unit in blocks of several kinds: the
// kernel reads the blocks of the highest kind that it knows, as the
// specification asks, and skips the others. The values are copied.
ivrs_read :: proc "contextless" (table: []u8) -> (ivrs: Ivrs, problem: Ivrs_Problem) {
	if len(table) < AMD_IVRS_BLOCKS_START {
		return {}, .Too_Short
	}
	scan := AMD_IVRS_BLOCKS_START
	for scan + 4 <= len(table) {
		kind := table[scan]
		length := int(load_16(table, scan + 2))
		if length < 4 || length > len(table) - scan {
			return {}, .Bad_Structure
		}
		if amd_unit_block_kind(kind) && kind > ivrs.unit_kind {
			ivrs.unit_kind = kind
		}
		scan += length
	}
	offset := AMD_IVRS_BLOCKS_START
	for offset + 4 <= len(table) {
		kind := table[offset]
		length := int(load_16(table, offset + 2))
		block := table[offset:offset + length]
		switch {
		case ivrs.unit_kind != 0 && kind == ivrs.unit_kind:
			header := kind == AMD_BLOCK_UNIT_FIRST_FORM ? AMD_BLOCK_UNIT_FIRST_FORM_HEADER : AMD_BLOCK_UNIT_HEADER
			if length < header {
				return ivrs, .Bad_Structure
			}
			if ivrs.unit_count == UNIT_CAPACITY {
				return ivrs, .Too_Many_Units
			}
			if load_16(block, 16) != 0 {
				return ivrs, .Other_Segment
			}
			ivrs.units[ivrs.unit_count] = {register_base = load_64(block, 8), requester = load_16(block, 4), capability_offset = load_16(block, 6)}
			if entry_problem := device_entries_read(&ivrs, block[header:], u8(ivrs.unit_count)); entry_problem != .None {
				return ivrs, entry_problem
			}
			ivrs.unit_count += 1
		case kind == AMD_BLOCK_RESERVED_EVERY_DEVICE || kind == AMD_BLOCK_RESERVED_DEVICE_RANGE:
			return ivrs, .Reserved_Range_Of_Several_Devices
		case kind == AMD_BLOCK_RESERVED_ONE_DEVICE:
			if length < AMD_BLOCK_RESERVED_SIZE {
				return ivrs, .Bad_Structure
			}
			if ivrs.reserved_range_count == RESERVED_RANGE_CAPACITY {
				return ivrs, .Too_Many_Ranges
			}
			// The table gives the first byte and the size: the range must be
			// whole pages, and its end must not wrap.
			start, size := load_64(block, 16), load_64(block, 24)
			if start % 4096 != 0 || size == 0 || size % 4096 != 0 || size > max(u64) - start {
				return ivrs, .Bad_Structure
			}
			ivrs.reserved_ranges[ivrs.reserved_range_count] = {start = start, end = start + size}
			ivrs.reserved_requesters[ivrs.reserved_range_count] = load_16(block, 4)
			ivrs.reserved_range_count += 1
		}
		offset += length
	}
	if ivrs.unit_count == 0 {
		return ivrs, .No_Unit
	}
	// One unit for each requester, whatever the order of the blocks: an
	// invalidation sent to the wrong unit would leave the translations of
	// the right one in place after the end of a grant.
	count := min(int(ivrs.range_count), AMD_REQUESTER_RANGE_CAPACITY)
	for first in 0 ..< count {
		for second in first + 1 ..< count {
			a, b := ivrs.ranges[first], ivrs.ranges[second]
			if a.unit != b.unit && a.first <= b.last && b.first <= a.last {
				return ivrs, .Units_Overlap
			}
		}
	}
	return ivrs, .None
}

// device_entries_read reads the device entries of one unit block, and
// keeps each range of requesters that they name with the settings byte of
// its entry, and whether an entry names an IOAPIC. An alias makes two
// requesters one: the kernel keeps its source and its target as aliased,
// and the target with the settings of the alias, as the messages of the
// source arrive with the requester of the target. A special entry (an
// IOAPIC, a timer) is kept with its requester (the bytes 5 and 6) and its
// settings.
@(private = "file")
device_entries_read :: proc "contextless" (ivrs: ^Ivrs, entries: []u8, unit: u8) -> Ivrs_Problem {
	range_open := false
	range_first: u16
	range_aliased := false
	range_settings: u8
	range_target: u16
	offset := 0
	for offset < len(entries) {
		kind := entries[offset]
		size := int(4) << uint(kind >> 6)
		if kind == AMD_ENTRY_ACPI_DEVICE {
			if len(entries) - offset < AMD_ACPI_DEVICE_ENTRY_HEADER {
				return .Bad_Structure
			}
			size = AMD_ACPI_DEVICE_ENTRY_HEADER + int(entries[offset + 21])
		}
		if size > len(entries) - offset {
			return .Bad_Structure
		}
		requester := load_16(entries, offset + 1)
		settings := entries[offset + 3]
		problem := Ivrs_Problem.None
		switch kind {
		case AMD_ENTRY_EVERY_DEVICE:
			problem = requester_range_add(ivrs, 0, max(u16), unit, false, settings)
		case AMD_ENTRY_SELECT, AMD_ENTRY_EXTENDED_SELECT:
			problem = requester_range_add(ivrs, requester, requester, unit, false, settings)
		case AMD_ENTRY_ALIAS_SELECT:
			target := load_16(entries, offset + 5)
			problem = requester_range_add(ivrs, target, target, unit, true, settings, target)
			if problem == .None {
				problem = requester_range_add(ivrs, requester, requester, unit, true, settings, target)
			}
		case AMD_ENTRY_RANGE_START, AMD_ENTRY_EXTENDED_RANGE_START, AMD_ENTRY_ALIAS_RANGE_START:
			if range_open {
				return .Bad_Structure
			}
			range_open, range_first, range_aliased, range_settings, range_target = true, requester, kind == AMD_ENTRY_ALIAS_RANGE_START, settings, 0
			if kind == AMD_ENTRY_ALIAS_RANGE_START {
				range_target = load_16(entries, offset + 5)
				problem = requester_range_add(ivrs, range_target, range_target, unit, true, settings, range_target)
			}
		case AMD_ENTRY_RANGE_END:
			if !range_open || requester < range_first {
				return .Bad_Structure
			}
			problem = requester_range_add(ivrs, range_first, requester, unit, range_aliased, range_settings, range_target)
			range_open = false
		case AMD_ENTRY_SPECIAL:
			if entries[offset + 7] == AMD_SPECIAL_VARIETY_INTERRUPT_CONTROLLER {
				ivrs.names_interrupt_controller = true
			}
			special := load_16(entries, offset + 5)
			problem = requester_range_add(ivrs, special, special, unit, false, settings)
		}
		if problem != .None {
			return problem
		}
		offset += size
	}
	if range_open {
		return .Bad_Structure
	}
	return .None
}

// requester_range_add keeps one range of requesters, or makes the last
// range longer when this one follows it with the same unit, alias, alias
// target and settings.
@(private = "file")
requester_range_add :: proc "contextless" (ivrs: ^Ivrs, first, last: u16, unit: u8, aliased: bool, settings: u8, alias_target: u16 = 0) -> Ivrs_Problem {
	if ivrs.range_count > 0 {
		previous := &ivrs.ranges[ivrs.range_count - 1]
		if previous.unit == unit && previous.aliased == aliased && previous.settings == settings && previous.alias_target == alias_target && u32(previous.last) + 1 == u32(first) {
			previous.last = last
			return .None
		}
	}
	if ivrs.range_count == AMD_REQUESTER_RANGE_CAPACITY {
		return .Too_Many_Device_Entries
	}
	ivrs.ranges[ivrs.range_count] = {first = first, last = last, unit = unit, aliased = aliased, settings = settings, alias_target = alias_target}
	ivrs.range_count += 1
	return .None
}

// amd_unit_of gives the unit that translates the accesses of a requester.
// ivrs_read refused a table where two units name one requester, so each
// range that names it gives the same unit, whatever their order. covered
// is false when no unit translates them: the device reaches all memory.
// aliased: one range that names it is an alias, as its source or as its
// target, so its requester is shared with another device.
amd_unit_of :: proc "contextless" (ivrs: ^Ivrs, requester: u16) -> (unit: u32, covered: bool, aliased: bool) {
	for index in 0 ..< min(int(ivrs.range_count), AMD_REQUESTER_RANGE_CAPACITY) {
		item := &ivrs.ranges[index]
		if requester >= item.first && requester <= item.last {
			unit, covered = u32(item.unit), true
			aliased ||= item.aliased
		}
	}
	return unit, covered, aliased
}

// amd_alias_sources_behind says if every alias whose target is a shared
// requester has its sources on buses behind the conventional bridge of that
// requester: shared_of_bus gives, for each bus, 1 + the shared requester of
// its devices, as the walk of the bus found it, or 0. An alias from a device
// outside the bridge would make the unit translate the accesses of that
// device with the domain of the group. The target itself is not a source.
// It reads each bus of each range once: at most 256 for a range.
amd_alias_sources_behind :: proc "contextless" (ivrs: ^Ivrs, shared: u16, shared_of_bus: ^[256]u32) -> bool {
	for index in 0 ..< min(int(ivrs.range_count), AMD_REQUESTER_RANGE_CAPACITY) {
		item := &ivrs.ranges[index]
		if !item.aliased || item.alias_target != shared {
			continue
		}
		for bus in u32(item.first >> 8) ..= u32(item.last >> 8) {
			low := max(u32(item.first), bus << 8)
			high := min(u32(item.last), bus << 8 | 0xFF)
			if low == u32(shared) && high == u32(shared) {
				continue // The target of the alias, alone on this bus in the range.
			}
			if shared_of_bus[bus] != 1 + u32(shared) {
				return false
			}
		}
	}
	return true
}

// amd_alias_agrees says if every alias that names a requester, as its
// source or as its target, gives its accesses the requester shared: the
// table then says what the walk of the bus found behind a conventional
// bridge. A requester that no alias names agrees: the bus alone decides.
amd_alias_agrees :: proc "contextless" (ivrs: ^Ivrs, requester: u16, shared: u16) -> bool {
	for index in 0 ..< min(int(ivrs.range_count), AMD_REQUESTER_RANGE_CAPACITY) {
		item := &ivrs.ranges[index]
		if item.aliased && requester >= item.first && requester <= item.last && item.alias_target != shared {
			return false
		}
	}
	return true
}

// amd_pass_bits gives the bits of the third word of a device entry that
// let the unit pass the messages that the settings byte of an IVHD entry
// names: INIT (bit 0), ExtINT (bit 1), NMI (bit 2), LINT0 (bit 6) and
// LINT1 (bit 7). On an AMD platform the 8259 virtual wire and the NMI
// arrive as such messages of a device of the chipset: without these bits a
// unit with remapping refuses them.
amd_pass_bits :: proc "contextless" (settings: u8) -> (bits: u64) {
	if settings & 1 != 0 {
		bits |= AMD_PASS_INIT
	}
	if settings & 2 != 0 {
		bits |= AMD_PASS_EXTERNAL_INTERRUPT
	}
	if settings & 4 != 0 {
		bits |= AMD_PASS_NMI
	}
	if settings & 0x40 != 0 {
		bits |= AMD_PASS_LINT0
	}
	if settings & 0x80 != 0 {
		bits |= AMD_PASS_LINT1
	}
	return bits
}

// The pass bits in the third word of a device entry.
AMD_PASS_INIT :: u64(1) << 56
AMD_PASS_EXTERNAL_INTERRUPT :: u64(1) << 57
AMD_PASS_NMI :: u64(1) << 58
AMD_PASS_LINT0 :: u64(1) << 62
AMD_PASS_LINT1 :: u64(1) << 63
AMD_PASS_BITS :: AMD_PASS_INIT | AMD_PASS_EXTERNAL_INTERRUPT | AMD_PASS_NMI | AMD_PASS_LINT0 | AMD_PASS_LINT1

// The registers of a unit of AMD: offsets from its base.
AMD_REGISTER_DEVICE_TABLE :: 0x0000 // u64: the device table, as amd_device_table_register gives it.
AMD_REGISTER_INVALIDATION_QUEUE :: 0x0008 // u64: the queue of invalidations, as amd_ring_register gives it.
AMD_REGISTER_EVENT_LOG :: 0x0010 // u64: the event log, as amd_ring_register gives it.
AMD_REGISTER_CONTROL :: 0x0018 // u64
// u64: the exclusion range, its base with ExEn (bit 0) and ExAllow (bit 1),
// and its limit. A range that the firmware left on passes each device
// there with no translation: the kernel writes 0 in both at the start.
AMD_REGISTER_EXCLUSION_BASE :: 0x0020
AMD_REGISTER_EXCLUSION_LIMIT :: 0x0028
// The registers of the apertures of memory access routing (MARC): 4
// apertures of a base, a relocation and a length of 8 bytes each. An
// aperture that the firmware left on routes a range past the tables: the
// kernel writes 0 in each at the start. On a unit with no apertures they
// are reserved registers, which a write of 0 leaves as they are.
AMD_REGISTER_MARC_FIRST :: 0x0300
AMD_MARC_REGISTER_COUNT :: 12
AMD_REGISTER_EXTENDED_FEATURES :: 0x0030 // u64
AMD_REGISTER_COMMAND_HEAD :: 0x2000 // u64: the byte of the next command that the unit reads.
AMD_REGISTER_COMMAND_TAIL :: 0x2008 // u64: the byte after the last command that the kernel wrote.
AMD_REGISTER_EVENT_HEAD :: 0x2010 // u64: the byte of the next record that the kernel reads.
AMD_REGISTER_EVENT_TAIL :: 0x2018 // u64: the byte after the last record that the unit wrote.
AMD_REGISTER_STATUS :: 0x2020 // u32
// The registers that the kernel uses fit in this many bytes; the kernel
// owns them while the IOMMU is in use.
AMD_REGISTER_SPACE :: 0x4000

// The bits of the control register.
AMD_CONTROL_ENABLE :: u64(1) // The unit translates and remaps (IommuEn).
AMD_CONTROL_EVENT_LOG :: u64(1) << 2 // The unit writes its events in the event log.
AMD_CONTROL_EVENT_INTERRUPT :: u64(1) << 3 // A new record sends the message interrupt of the unit.
AMD_CONTROL_COHERENT :: u64(1) << 10 // The reads of the tables snoop the caches of the processors.
AMD_CONTROL_INVALIDATION_QUEUE :: u64(1) << 12 // The unit runs the commands of its queue of invalidations.
// The control of a unit that the kernel starts.
AMD_CONTROL_STARTED :: AMD_CONTROL_ENABLE | AMD_CONTROL_EVENT_LOG | AMD_CONTROL_EVENT_INTERRUPT | AMD_CONTROL_COHERENT | AMD_CONTROL_INVALIDATION_QUEUE
// The modes that the firmware can leave on: the kernel does not take over a
// unit that translates now, or runs a queue of invalidations that the
// kernel did not write.
AMD_CONTROL_LEFT_ON :: AMD_CONTROL_ENABLE | AMD_CONTROL_EVENT_LOG | AMD_CONTROL_INVALIDATION_QUEUE

// The bits of the status register.
AMD_STATUS_EVENT_OVERFLOW :: u32(1) // The event log was full: the unit dropped a record. Written 1 to clear.
AMD_STATUS_EVENT_INTERRUPT :: u32(1) << 1 // A record came: the unit sent its message interrupt. Written 1 to clear.
AMD_STATUS_WAIT_INTERRUPT :: u32(1) << 2 // Written 1 to clear.
AMD_STATUS_EVENT_LOG_RUNS :: u32(1) << 3
AMD_STATUS_INVALIDATION_QUEUE_RUNS :: u32(1) << 4 // Cleared when the unit refuses a command: it reads no more of the queue.
AMD_STATUS_RUNS :: AMD_STATUS_EVENT_LOG_RUNS | AMD_STATUS_INVALIDATION_QUEUE_RUNS
// The bits that the firmware can leave set, cleared at the start.
AMD_STATUS_CLEARED_AT_START :: AMD_STATUS_EVENT_OVERFLOW | AMD_STATUS_EVENT_INTERRUPT | AMD_STATUS_WAIT_INTERRUPT

// amd_extended_host_translation says if the unit translates through the
// page tables of the host: the field HATS (bits 11:10) of the extended
// features is not 3. The values 0 to 2 each allow the 4 levels that the
// kernel uses.
amd_extended_host_translation :: proc "contextless" (extended: u64) -> bool {
	return extended >> 10 & 3 != 3
}

// amd_extended_invalidate_all says if the unit has the command that
// forgets each cached entry (IASup, bit 6).
amd_extended_invalidate_all :: proc "contextless" (extended: u64) -> bool {
	return extended >> 6 & 1 != 0
}

// The levels of the page tables of a domain on a unit of AMD: 48 bits of
// address, as a unit of VT-d of 48 bits.
AMD_LEVELS :: 4

// The queue of invalidations and the event log: rings of records of 16
// bytes, one page each. The register gives the count of records as 2^8.
// The kernel waits for each batch of commands, which has at most
// QUEUE_LARGEST_BATCH commands, so the queue never holds more than one.
AMD_RING_SIZE_FIELD :: 8
AMD_RING_RECORDS :: 256
AMD_RECORD_SIZE :: 16
AMD_RING_BYTES :: AMD_RING_RECORDS * AMD_RECORD_SIZE
#assert(1 << AMD_RING_SIZE_FIELD == AMD_RING_RECORDS)
#assert(AMD_RING_BYTES == 4096)
#assert(AMD_RING_RECORDS == QUEUE_DESCRIPTORS)

// amd_ring_register gives the value of the register of the queue of
// invalidations or of the event log: its page, and its size in the bits
// 59:56.
amd_ring_register :: proc "contextless" (page: u64) -> u64 {
	return page & ENTRY_ADDRESS | u64(AMD_RING_SIZE_FIELD) << 56
}

// amd_ring_offset gives the byte of a record that a head or a tail register
// names: the bits 18:4.
amd_ring_offset :: proc "contextless" (register: u64) -> u32 {
	return u32(register & 0x7_FFF0)
}

// amd_ring_register_of gives the value of a head or a tail register for a
// record index: the index in the bits 18:4.
amd_ring_register_of :: proc "contextless" (index: u32) -> u64 {
	return u64(index % AMD_RING_RECORDS) << 4
}

// The device table: one entry of 32 bytes for each of the 65536
// requesters, 2 MiB, whatever buses the table MCFG gives: a requester past
// a shorter table is read past its end by QEMU 10. An entry of zeros passes
// every access with no translation, so the kernel writes each entry.
AMD_DEVICE_ENTRY_SIZE :: 32
AMD_DEVICE_TABLE_ENTRIES :: 65536
AMD_DEVICE_TABLE_PAGES :: AMD_DEVICE_TABLE_ENTRIES * AMD_DEVICE_ENTRY_SIZE / 4096
#assert(AMD_DEVICE_TABLE_PAGES == 512)

// amd_device_table_register gives the value of the register of the device
// table: its first page, and its size in pages minus 1 in the bits 8:0.
amd_device_table_register :: proc "contextless" (table: u64, pages: u64) -> u64 {
	return table & ENTRY_ADDRESS | (pages - 1) & 0x1FF
}

AMD_DEVICE_ENTRY_VALID :: u64(1)
AMD_DEVICE_ENTRY_TRANSLATION_VALID :: u64(1) << 1
AMD_DEVICE_ENTRY_READ :: u64(1) << 61
AMD_DEVICE_ENTRY_WRITE :: u64(1) << 62

// amd_translation_words gives the first two words of the entry of a device:
// valid, with translation through the tables from top of levels levels, in
// the domain identifier domain. allowed gives read and write, so that the
// entries of the pages decide; without it the entry refuses every access.
// The mode is never 0: the specification passes each access of the mode 0
// with the rights of the entry only, and QEMU 10 then gives the device all
// memory. A refusing entry names the top of an empty table instead.
amd_translation_words :: proc "contextless" (top: u64, levels: u32, domain: u16, allowed: bool) -> [2]u64 {
	first := AMD_DEVICE_ENTRY_VALID | AMD_DEVICE_ENTRY_TRANSLATION_VALID | u64(levels & 7) << 9 | top & ENTRY_ADDRESS
	if allowed {
		first |= AMD_DEVICE_ENTRY_READ | AMD_DEVICE_ENTRY_WRITE
	}
	return {first, u64(domain)}
}

AMD_INTERRUPT_MAP_VALID :: u64(1) // The bits of the interrupts of the entry are valid (IV).
AMD_INTERRUPT_REMAPPED :: u64(2) << 60 // IntCtl 2: each message of the device goes through its interrupt table. IntCtl 0 refuses each one.
AMD_INTERRUPT_TABLE_ADDRESS :: u64(0x000F_FFFF_FFFF_FFC0)

// The interrupt table of a device: one entry of 4 bytes for each message
// interrupt of op.MESSAGE_CAPACITY, at its index. The value that the device
// writes is the index. The tables are 128 bytes apart, the alignment that
// the specification asks.
AMD_INTERRUPT_TABLE_ENTRIES :: 16
AMD_INTERRUPT_TABLE_LENGTH_FIELD :: 4
AMD_INTERRUPT_ENTRY_SIZE :: 4
AMD_INTERRUPT_TABLE_SPACING :: 128
#assert(1 << AMD_INTERRUPT_TABLE_LENGTH_FIELD == AMD_INTERRUPT_TABLE_ENTRIES)
#assert(AMD_INTERRUPT_TABLE_ENTRIES * AMD_INTERRUPT_ENTRY_SIZE <= AMD_INTERRUPT_TABLE_SPACING)

// amd_interrupt_word gives the third word of the entry of a device. With
// no remapping: 0, and each message passes. With remapping and no table:
// valid, and each fixed message refused. With a table: each fixed message
// goes through it, and an entry that is not valid refuses it. pass holds
// the pass bits of the device (amd_pass_bits): the INIT, ExtINT, NMI and
// LINT messages that the firmware names for it pass, and the others are
// refused.
amd_interrupt_word :: proc "contextless" (remapping: bool, table: u64, pass: u64) -> u64 {
	if !remapping {
		return 0
	}
	word := AMD_INTERRUPT_MAP_VALID | pass & AMD_PASS_BITS
	if table != 0 {
		word |= u64(AMD_INTERRUPT_TABLE_LENGTH_FIELD) << 1 | table & AMD_INTERRUPT_TABLE_ADDRESS | AMD_INTERRUPT_REMAPPED
	}
	return word
}

// amd_interrupt_entry gives an entry of an interrupt table: valid, fixed
// delivery of the vector to the processor of the interrupt controller
// identifier processor in the physical mode. The faults of the entry are
// recorded (SupIOPF 0).
amd_interrupt_entry :: proc "contextless" (vector: u8, processor: u8) -> u32 {
	return 1 | u32(processor) << 8 | u32(vector) << 16
}

// amd_message_address gives the address that a device writes for each of
// its message interrupts: the unit reads the entry from the value, and the
// address only says that the write is a message.
amd_message_address :: proc "contextless" (processor: u8) -> u64 {
	return 0xFEE0_0000 | u64(processor) << 12
}

// The entries of the page tables of AMD: present in bit 0, the level of
// the table that an entry names in the bits 11:9 (0 for a page), the
// address in the bits 51:12, read and write in bits 61 and 62. The unit
// takes the rights of each level of the walk together, so an entry that
// names a table has both.
AMD_ENTRY_PRESENT :: u64(1)
AMD_ENTRY_READ :: u64(1) << 61
AMD_ENTRY_WRITE :: u64(1) << 62

// amd_table_entry gives an entry that names the table of the level level.
amd_table_entry :: proc "contextless" (table: u64, level: u32) -> u64 {
	return table & ENTRY_ADDRESS | AMD_ENTRY_PRESENT | u64(level & 7) << 9 | AMD_ENTRY_READ | AMD_ENTRY_WRITE
}

// amd_page_entry gives an entry of the last level: a page of 4096 bytes
// that a device reads, and writes only when writable.
amd_page_entry :: proc "contextless" (address: u64, writable: bool) -> u64 {
	return address & ENTRY_ADDRESS | AMD_ENTRY_PRESENT | AMD_ENTRY_READ | (writable ? AMD_ENTRY_WRITE : 0)
}

amd_entry_present :: proc "contextless" (entry: u64) -> bool {
	return entry & AMD_ENTRY_PRESENT != 0
}

// The commands of the queue of invalidations: the kind in the bits 63:60
// of the first word.
AMD_COMMAND_COMPLETION_WAIT :: u64(1)
AMD_COMMAND_INVALIDATE_DEVICE_ENTRY :: u64(2)
AMD_COMMAND_INVALIDATE_PAGES :: u64(3)
AMD_COMMAND_INVALIDATE_INTERRUPT_TABLE :: u64(5)
AMD_COMMAND_INVALIDATE_ALL :: u64(8)
// The address of an invalidation of the pages that names every page of a
// domain, with the flags S (a size from the address) and PDE (the entries
// of the tables too).
AMD_ALL_PAGES :: u64(0x7FFF_FFFF_FFFF_F000) | 3

// amd_command_wait gives the command that writes number (8 bytes) at the
// physical address status (aligned to 8) when the unit has done every
// command before it.
amd_command_wait :: proc "contextless" (status: u64, number: u32) -> [2]u64 {
	return {AMD_COMMAND_COMPLETION_WAIT << 60 | status & 0x000F_FFFF_FFFF_FFF8 | 1, u64(number)}
}

// amd_command_device_entry gives the command that forgets the entry of a
// requester in the device table.
amd_command_device_entry :: proc "contextless" (requester: u16) -> [2]u64 {
	return {AMD_COMMAND_INVALIDATE_DEVICE_ENTRY << 60 | u64(requester), 0}
}

// amd_command_pages gives the command that forgets every translation of a
// domain identifier.
amd_command_pages :: proc "contextless" (domain: u16) -> [2]u64 {
	return {AMD_COMMAND_INVALIDATE_PAGES << 60 | u64(domain) << 32, AMD_ALL_PAGES}
}

// amd_command_interrupt_table gives the command that forgets the entries of
// the interrupt table of a requester.
amd_command_interrupt_table :: proc "contextless" (requester: u16) -> [2]u64 {
	return {AMD_COMMAND_INVALIDATE_INTERRUPT_TABLE << 60 | u64(requester), 0}
}

// amd_command_all gives the command that forgets each cached entry of the
// unit.
amd_command_all :: proc "contextless" () -> [2]u64 {
	return {AMD_COMMAND_INVALIDATE_ALL << 60, 0}
}

// The kinds of a record of the event log, in the bits 63:60 of its first
// word: 16 kinds. The kind 0 is no record: a unit can move its tail before
// the record is in memory, so the kernel reads a record of the kind 0 as
// not written yet, and writes 0 in each record after it read it.
AMD_EVENT_KINDS :: 16
AMD_EVENT_NOT_WRITTEN :: 0
AMD_EVENT_PAGE_FAULT :: 2 // IO_PAGE_FAULT: the unit refused an access, or a message interrupt.
// The flags of a page fault, in the bits 59:48 of the first word.
AMD_EVENT_FLAG_INTERRUPT :: u16(1) << 3 // The request was a message interrupt (I).
AMD_EVENT_FLAG_WRITE :: u16(1) << 5 // The request was a write (RW).
AMD_INTERRUPT_ADDRESSES_FIRST :: u64(0xFEE0_0000)
AMD_INTERRUPT_ADDRESSES_LAST :: u64(0xFEEF_FFFF)

// One record of the event log.
Amd_Event :: struct {
	kind:      u8,
	requester: u16,
	flags:     u16,
	address:   u64,
}

// amd_event_read reads one record of the event log from its two words.
amd_event_read :: proc "contextless" (low: u64, high: u64) -> Amd_Event {
	return {kind = u8(low >> 60), requester = u16(low), flags = u16(low >> 48 & 0xFFF), address = high}
}

// amd_event_fault gives the fault of a page fault record. A record with the
// flag I and an address of the interrupts is a refused message interrupt,
// and keeps its whole address; another one is a DMA fault, with its page.
// The flags are the reason. QEMU 10 sets the flag I on each page fault, and
// gives the access in the flags 0 and 1, not in the flag RW: the address
// tells the interrupt, and the line of the kernel names each fault of QEMU
// a read.
amd_event_fault :: proc "contextless" (event: Amd_Event) -> Fault {
	interrupt := event.flags & AMD_EVENT_FLAG_INTERRUPT != 0 && event.address >= AMD_INTERRUPT_ADDRESSES_FIRST && event.address <= AMD_INTERRUPT_ADDRESSES_LAST
	if interrupt {
		return {address = event.address, requester = event.requester, reason = event.flags, interrupt = true}
	}
	return {address = event.address & ENTRY_ADDRESS, requester = event.requester, reason = event.flags, read = event.flags & AMD_EVENT_FLAG_WRITE == 0}
}

// The capability of the message interrupt of a function, which the
// function of a unit of AMD has: its interrupt sends the fault event.
CAPABILITY_MESSAGE :: 0x05
MESSAGE_CONTROL_ENABLE :: u16(1)
MESSAGE_CONTROL_COUNT :: u16(7) << 4 // The count of messages that the function sends: the kernel gives 1.
MESSAGE_CONTROL_64_BITS :: u16(1) << 7
COMMAND_BUS_MASTER :: u16(1) << 2 // The function writes memory: its message too.
OFFSET_COMMAND :: 4

// capability_offset gives the place of the first capability of a kind in
// the first 256 bytes of the configuration of a function, or 0. The walk
// stops after 48, as a list that loops would never end.
capability_offset :: proc "contextless" (configuration: ^[bridge_requester.CONFIGURATION_WORDS]u32, kind: u32) -> u32 {
	if configuration[1] & bridge_requester.STATUS_CAPABILITIES == 0 {
		return 0
	}
	offset := configuration[0x34 / 4] & 0xFC
	for _ in 0 ..< 48 {
		if offset < 0x40 || offset > 0xFC {
			return 0
		}
		word := configuration[offset / 4]
		if word & 0xFF == kind {
			return offset
		}
		offset = word >> 8 & 0xFC
	}
	return 0
}

// message_registers gives the places of the registers of a capability of
// the message interrupt at offset: the low address, the high address (0
// when the function gives 32 bits only) and the value.
message_registers :: proc "contextless" (offset: u32, control: u16) -> (address_low: u32, address_high: u32, value: u32) {
	if control & MESSAGE_CONTROL_64_BITS != 0 {
		return offset + 4, offset + 8, offset + 12
	}
	return offset + 4, 0, offset + 8
}

// message_control_enabled gives the control of a message interrupt that is
// on, with one message.
message_control_enabled :: proc "contextless" (control: u16) -> u16 {
	return control &~ MESSAGE_CONTROL_COUNT | MESSAGE_CONTROL_ENABLE
}

MESSAGE_CONTROL_MASKS :: u16(1) << 8 // The capability has a mask bit for each message.

// message_mask_register gives the place of the register of the mask bits
// of a capability of the message interrupt at offset, or 0 when it has
// none. A mask bit that the firmware left set would stop each message of
// the function.
message_mask_register :: proc "contextless" (offset: u32, control: u16) -> u32 {
	if control & MESSAGE_CONTROL_MASKS == 0 {
		return 0
	}
	return control & MESSAGE_CONTROL_64_BITS != 0 ? offset + 16 : offset + 12
}

// The class of the function of a unit of AMD, in the bits 31:16 of the
// word 2 of its configuration: a system peripheral (0x08), an IOMMU (0x06).
// The kernel writes the message interrupt and the bus master bit of this
// function only, so a table that names another function is refused.
AMD_UNIT_FUNCTION_CLASS :: 0x0806

amd_function_is_unit :: proc "contextless" (class_word: u32) -> bool {
	return class_word >> 16 == AMD_UNIT_FUNCTION_CLASS
}

// The capability header of a unit of AMD, at the place that its block of
// the table gives: the kind 0x0F, and the flag NpCache (bit 26): the unit
// can keep an entry that was not present.
AMD_CAPABILITY_UNIT :: 0x0F
AMD_CAPABILITY_NOT_PRESENT_CACHE :: u32(1) << 26

// amd_caches_not_present says if a unit keeps entries that were not
// present, from its capability header. A header of another kind gives
// true: the kernel then invalidates each new entry, which is always right.
amd_caches_not_present :: proc "contextless" (header: u32) -> bool {
	return header & 0xFF != AMD_CAPABILITY_UNIT || header & AMD_CAPABILITY_NOT_PRESENT_CACHE != 0
}
