// The formats of the IOMMU of Intel (VT-d) that the kernel reads and
// writes: the ACPI tables DMAR and MCFG, the registers of a remapping unit,
// the root, context and second-level entries, and a fault record. The two
// parties are the kernel and the hardware; the formats are those of the
// "Intel Virtualization Technology for Directed I/O, Architecture
// Specification". The design is src/md/infrastructure/iommu.md.
//
// Each procedure here is pure: it reads bytes or values and gives values,
// so the host tests check each format with no machine.
//
// This package allocates no memory and calls no kernel operation.
package iommu

// The size of the header of every ACPI table.
ACPI_HEADER_SIZE :: 36

// The table DMAR: the ACPI header, the host address width minus 1, the
// flags, 10 reserved bytes, then the remapping structures.
DMAR_STRUCTURES_START :: 48
DMAR_HOST_ADDRESS_WIDTH :: 36

// The kinds of a remapping structure of the table DMAR.
STRUCTURE_UNIT :: 0 // A remapping unit (DRHD): its registers and its devices.
STRUCTURE_RESERVED_MEMORY :: 1 // A range of memory that a device uses for the firmware (RMRR).
UNIT_SIZE :: 16 // The bytes of a unit before its list of devices.
UNIT_INCLUDES_EVERY_DEVICE :: 1 // The flag INCLUDE_PCI_ALL of a unit: it covers each device of its segment that no other unit lists.

// A device scope of a unit: its kind, its length, 2 reserved bytes, the
// enumeration identifier, the start bus, then the path, one pair of the
// device and the function for each bridge down to the device.
SCOPE_HEADER_SIZE :: 6
SCOPE_ENDPOINT :: 1 // A function of PCI.
SCOPE_BRIDGE :: 2 // A bridge of PCI: the function of the bridge, and the buses behind it.

// The functions of bus 0: 32 devices of 8 functions, one bit each, at the
// index device * 8 + function.
FUNCTIONS_OF_BUS_0 :: 256

// What the kernel found in the table DMAR.
Dmar :: struct {
	host_address_width: u32, // The bits of a physical address that a device can give.
	register_base:      u64, // The physical address of the registers of the first unit.
	unit_count:         u32,
	reserved_memory_count: u32,
	// The functions of bus 0 whose accesses pass through the unit. Another
	// function reaches all memory: the unit does not see it.
	covered:            [FUNCTIONS_OF_BUS_0 / 32]u32,
}

// dmar_covers says whether the unit translates the accesses of this
// function of bus 0.
dmar_covers :: proc "contextless" (dmar: Dmar, device, function: u32) -> bool {
	index := (device & 31) * 8 + (function & 7)
	return dmar.covered[index / 32] & (1 << (index % 32)) != 0
}

// covered_count gives the number of functions of bus 0 that the unit covers.
covered_count :: proc "contextless" (dmar: Dmar) -> u32 {
	count: u32
	for word in dmar.covered {
		for bit in u32(0) ..< 32 {
			count += (word >> bit) & 1
		}
	}
	return count
}

// Why the kernel does not use the units of a table DMAR. The kernel uses
// one form: one unit of segment 0, that covers every device or lists the
// functions that it covers, with no range of memory reserved for a device.
Dmar_Problem :: enum u8 {
	None,
	Too_Short, // The table ends before its first structure.
	Bad_Structure, // A structure has a length below its own header, or passes the end of the table.
	No_Unit, // No remapping unit.
	Several_Units, // More than one unit: the kernel programs one.
	Other_Segment, // The unit covers a segment of PCI other than 0.
	Reserved_Memory, // A device needs a range of memory of the firmware: its domain would need it.
}

// The text of each problem, after "no IOMMU in use: " on the log.
@(rodata)
DMAR_PROBLEM_TEXTS := [Dmar_Problem]string {
	.None             = "none",
	.Too_Short        = "the DMA remapping table is too short",
	.Bad_Structure    = "a structure of the DMA remapping table has a wrong length",
	.No_Unit          = "the DMA remapping table has no unit",
	.Several_Units    = "the DMA remapping table has several units, and the kernel programs one",
	.Other_Segment    = "the unit covers a segment of PCI other than 0",
	.Reserved_Memory  = "a device needs a range of memory of the firmware",
}

load_16 :: proc "contextless" (bytes: []u8, offset: int) -> u16 {
	return u16(bytes[offset]) | u16(bytes[offset + 1]) << 8
}

load_32 :: proc "contextless" (bytes: []u8, offset: int) -> u32 {
	return u32(load_16(bytes, offset)) | u32(load_16(bytes, offset + 2)) << 16
}

load_64 :: proc "contextless" (bytes: []u8, offset: int) -> u64 {
	return u64(load_32(bytes, offset)) | u64(load_32(bytes, offset + 4)) << 32
}

// dmar_read reads the table DMAR: its bytes, with the size of its header.
// The values are copied: the caller gives a copy or memory of the
// firmware that nobody changes.
dmar_read :: proc "contextless" (table: []u8) -> (dmar: Dmar, problem: Dmar_Problem) {
	if len(table) < DMAR_STRUCTURES_START {
		return {}, .Too_Short
	}
	dmar.host_address_width = u32(table[DMAR_HOST_ADDRESS_WIDTH]) + 1
	first_problem := Dmar_Problem.None
	offset := DMAR_STRUCTURES_START
	for offset + 4 <= len(table) {
		kind := load_16(table, offset)
		length := int(load_16(table, offset + 2))
		if length < 4 || length > len(table) - offset {
			return dmar, .Bad_Structure
		}
		switch kind {
		case STRUCTURE_UNIT:
			if length < UNIT_SIZE {
				return dmar, .Bad_Structure
			}
			dmar.unit_count += 1
			if dmar.unit_count == 1 {
				flags := table[offset + 4]
				segment := load_16(table, offset + 6)
				dmar.register_base = load_64(table, offset + 8)
				if segment != 0 {
					first_problem = .Other_Segment
				}
				if flags & UNIT_INCLUDES_EVERY_DEVICE != 0 {
					for &word in dmar.covered {
						word = max(u32)
					}
				}
				// The scopes of the unit. A function of bus 0 named with a
				// path of one pair is covered; a function behind a bridge
				// has no domain in this form, and a scope of another kind
				// (an interrupt controller, a timer) names no requester.
				scope := offset + UNIT_SIZE
				for scope < offset + length {
					if offset + length - scope < SCOPE_HEADER_SIZE {
						return dmar, .Bad_Structure
					}
					scope_kind := table[scope]
					scope_length := int(table[scope + 1])
					if scope_length < SCOPE_HEADER_SIZE || scope_length > offset + length - scope {
						return dmar, .Bad_Structure
					}
					start_bus := table[scope + 5]
					if (scope_kind == SCOPE_ENDPOINT || scope_kind == SCOPE_BRIDGE) && start_bus == 0 && scope_length == SCOPE_HEADER_SIZE + 2 {
						index := u32(table[scope + 6] & 31) * 8 + u32(table[scope + 7] & 7)
						dmar.covered[index / 32] |= 1 << (index % 32)
					}
					scope += scope_length
				}
			}
		case STRUCTURE_RESERVED_MEMORY:
			dmar.reserved_memory_count += 1
		}
		offset += length
	}
	switch {
	case dmar.unit_count == 0:
		return dmar, .No_Unit
	case dmar.unit_count > 1:
		return dmar, .Several_Units
	case first_problem != .None:
		return dmar, first_problem
	case dmar.reserved_memory_count != 0:
		return dmar, .Reserved_Memory
	}
	return dmar, .None
}

// The table MCFG: the ACPI header, 8 reserved bytes, then one entry of 16
// bytes for each range of buses: the base address, the segment, the first
// and the last bus.
MCFG_ENTRIES_START :: 44
MCFG_ENTRY_SIZE :: 16

// The memory of the configuration of PCI of one range of buses of segment 0.
Configuration_Memory :: struct {
	base:      u64, // The physical address of the configuration of the first bus of the range.
	first_bus: u8,
	last_bus:  u8,
}

// mcfg_read gives the range of segment 0 that holds bus 0. found is false
// when the table names none.
mcfg_read :: proc "contextless" (table: []u8) -> (memory: Configuration_Memory, found: bool) {
	for offset := MCFG_ENTRIES_START; offset + MCFG_ENTRY_SIZE <= len(table); offset += MCFG_ENTRY_SIZE {
		segment := load_16(table, offset + 8)
		first, last := table[offset + 10], table[offset + 11]
		if segment == 0 && first == 0 && last >= first {
			return {base = load_64(table, offset), first_bus = first, last_bus = last}, true
		}
	}
	return {}, false
}

// configuration_offset gives the place of a register of the configuration
// of a function, from the base of bus 0.
configuration_offset :: proc "contextless" (bus, device, function, register: u32) -> u64 {
	return u64(bus) << 20 | u64(device & 31) << 15 | u64(function & 7) << 12 | u64(register & 0xFFF)
}

// The 16 words of the header of the configuration of a function: the
// first 64 bytes.
HEADER_WORDS :: 16

// header_memory_bases gives the base address of each memory base address
// register of a function: 6 for a device, 2 for a bridge. A register of
// ports, or a base of 0, gives no base. A register of 64 bits takes the
// next register as its high half.
header_memory_bases :: proc "contextless" (header: [HEADER_WORDS]u32) -> (bases: [6]u64, count: int) {
	register_count := 0
	switch header[3] >> 16 & 0x7F {
	case 0:
		register_count = 6
	case 1:
		register_count = 2
	}
	for index := 0; index < register_count; index += 1 {
		value := header[4 + index]
		if value & 1 != 0 {
			continue // Ports.
		}
		base := u64(value &~ 0xF)
		if value >> 1 & 3 == 2 && index + 1 < register_count {
			index += 1
			base |= u64(header[4 + index]) << 32
		}
		if base != 0 {
			bases[count] = base
			count += 1
		}
	}
	return bases, count
}

// header_is_multi_function says if a function 0 has other functions.
header_is_multi_function :: proc "contextless" (header: [HEADER_WORDS]u32) -> bool {
	return header[3] >> 16 & 0x80 != 0
}

// requester gives the requester identifier of a function: the name of a
// device in the context table and in a fault record.
requester :: proc "contextless" (bus, device, function: u32) -> u16 {
	return u16((bus & 0xFF) << 8 | (device & 31) << 3 | (function & 7))
}

requester_bus :: proc "contextless" (requester: u16) -> u32 {
	return u32(requester >> 8)
}

requester_device :: proc "contextless" (requester: u16) -> u32 {
	return u32(requester >> 3 & 31)
}

requester_function :: proc "contextless" (requester: u16) -> u32 {
	return u32(requester & 7)
}

// The registers of a remapping unit: offsets from its base.
REGISTER_CAPABILITY :: 0x08 // u64
REGISTER_EXTENDED_CAPABILITY :: 0x10 // u64
REGISTER_GLOBAL_COMMAND :: 0x18 // u32
REGISTER_GLOBAL_STATUS :: 0x1C // u32
REGISTER_ROOT_TABLE :: 0x20 // u64: the physical address of the root table.
REGISTER_CONTEXT_COMMAND :: 0x28 // u64
REGISTER_FAULT_STATUS :: 0x34 // u32
REGISTER_FAULT_EVENT_CONTROL :: 0x38 // u32
REGISTER_FAULT_EVENT_DATA :: 0x3C // u32: the vector of the fault event.
REGISTER_FAULT_EVENT_ADDRESS :: 0x40 // u32: the interrupt controller that receives it.
REGISTER_FAULT_EVENT_UPPER_ADDRESS :: 0x44 // u32
// The registers of a unit fit in this many bytes; a capability that places
// a register past it is refused.
REGISTER_SPACE :: 0x10000

// The bits of the global command, and of the global status at the same
// places.
GLOBAL_TRANSLATION :: u32(1) << 31 // Translation on (TE, TES).
GLOBAL_ROOT_TABLE :: u32(1) << 30 // Take the root table of the register (SRTP, RTPS).
GLOBAL_WRITE_BUFFER :: u32(1) << 27 // Flush the write buffer (WBF); the status bit is set while it runs.
GLOBAL_QUEUED_INVALIDATION :: u32(1) << 26 // The queue of invalidations is on (QIE, QIES): the registers of invalidation do not work then.
GLOBAL_INTERRUPT_REMAPPING :: u32(1) << 25 // Interrupt remapping is on (IRE, IRES): each message interrupt then needs an entry.

// Why the kernel does not take a unit in this global status at its start:
// a mode that the firmware left on.
Global_Status_Problem :: enum u8 {
	None,
	Translation_On, // The kernel would change the tables of a unit that translates now.
	Queued_Invalidation_On, // The kernel invalidates by the registers, which this mode refuses.
	Interrupt_Remapping_On, // The kernel writes no table of interrupts, and each interrupt would be refused.
}

@(rodata)
GLOBAL_STATUS_PROBLEM_TEXTS := [Global_Status_Problem]string {
	.None                   = "none",
	.Translation_On         = "the firmware left translation on",
	.Queued_Invalidation_On = "the firmware left the queue of invalidations on",
	.Interrupt_Remapping_On = "the firmware left interrupt remapping on",
}

// global_status_problem gives the first mode of the status that the kernel
// does not take over.
global_status_problem :: proc "contextless" (status: u32) -> Global_Status_Problem {
	switch {
	case status & GLOBAL_TRANSLATION != 0:
		return .Translation_On
	case status & GLOBAL_QUEUED_INVALIDATION != 0:
		return .Queued_Invalidation_On
	case status & GLOBAL_INTERRUPT_REMAPPING != 0:
		return .Interrupt_Remapping_On
	}
	return .None
}
// The bits of the status that keep a state: a command is the status with
// these, plus the one bit that changes. The other bits are one-shot.
GLOBAL_KEPT_BITS :: u32(0x96FF_FFFF)

// global_command gives the value of the global command that sets one bit
// and keeps each state of the status.
global_command :: proc "contextless" (status: u32, bit: u32) -> u32 {
	return status & GLOBAL_KEPT_BITS | bit
}

CONTEXT_INVALIDATE :: u64(1) << 63 // Set to start; the unit clears it when done.
CONTEXT_GLOBAL :: u64(1) << 61 // Each context entry of the unit.

IOTLB_INVALIDATE :: u64(1) << 63
IOTLB_GLOBAL :: u64(1) << 60 // Each translation of each domain.
IOTLB_DRAIN_READS :: u64(1) << 49
IOTLB_DRAIN_WRITES :: u64(1) << 48

// context_invalidation_done says if the context command register shows a
// finished invalidation that the unit made: the bit of the command is
// clear, and the granularity that it made (CAIG, bits 60:59) is not 0.
context_invalidation_done :: proc "contextless" (register: u64) -> (finished: bool, made: bool) {
	return register & CONTEXT_INVALIDATE == 0, register >> 59 & 3 != 0
}

// iotlb_invalidation_done says the same of the IOTLB register: the
// granularity that the unit made is IAIG, bits 58:57.
iotlb_invalidation_done :: proc "contextless" (register: u64) -> (finished: bool, made: bool) {
	return register & IOTLB_INVALIDATE == 0, register >> 57 & 3 != 0
}

FAULT_STATUS_OVERFLOW :: u32(1) // A fault came when no record was free; written 1 to clear.
FAULT_EVENT_MASKED :: u32(1) << 31

// capability_levels gives the levels of the second-level tables that the
// kernel uses: 4 for addresses of 48 bits, else 3 for 39 bits, else 0 (the
// unit offers neither).
capability_levels :: proc "contextless" (capability: u64) -> u32 {
	widths := capability >> 8 & 0x1F
	switch {
	case widths & 4 != 0:
		return 4
	case widths & 2 != 0:
		return 3
	}
	return 0
}

// capability_caching_mode says if the unit can keep an entry that is not
// present: then a new entry needs an invalidation too.
capability_caching_mode :: proc "contextless" (capability: u64) -> bool {
	return capability >> 7 & 1 != 0
}

// capability_write_buffer says if the unit needs a flush of its write
// buffer before an invalidation.
capability_write_buffer :: proc "contextless" (capability: u64) -> bool {
	return capability >> 4 & 1 != 0
}

// capability_drains says if the unit drains the reads and the writes in
// flight before an invalidation of the IOTLB ends (DRD, bit 55; DWD, bit
// 54). Without both, an access that the unit translated before the
// invalidation can still reach a page after it: the kernel refuses such a
// unit.
capability_drains :: proc "contextless" (capability: u64) -> bool {
	return capability >> 55 & 1 != 0 && capability >> 54 & 1 != 0
}

// domain_address_end gives the first physical address that the tables of
// a domain with these levels cannot map: 2^39 for 3 levels, 2^48 for 4.
domain_address_end :: proc "contextless" (levels: u32) -> u64 {
	return u64(1) << (12 + 9 * u64(levels))
}

// capability_fault_records gives the offset of the first fault recording
// register, and the count of them. Each one has 16 bytes.
capability_fault_records :: proc "contextless" (capability: u64) -> (offset: u64, count: u64) {
	return (capability >> 24 & 0x3FF) * 16, (capability >> 40 & 0xFF) + 1
}

// capability_domain_count gives the count of domain identifiers.
capability_domain_count :: proc "contextless" (capability: u64) -> u64 {
	return u64(1) << (4 + 2 * (capability & 7))
}

// extended_iotlb_offset gives the offset of the two registers of the
// IOTLB: the address register, then the command register 8 bytes after.
extended_iotlb_offset :: proc "contextless" (extended: u64) -> u64 {
	return (extended >> 8 & 0x3FF) * 16
}

// extended_coherent says if the unit snoops the caches of the processors
// when it reads a table: if not, the kernel writes each changed line of a
// table back to memory.
extended_coherent :: proc "contextless" (extended: u64) -> bool {
	return extended & 1 != 0
}

ENTRY_PRESENT :: u64(1)
ENTRY_READ :: u64(1)
ENTRY_WRITE :: u64(1) << 1
ENTRY_ADDRESS :: u64(0x000F_FFFF_FFFF_F000)
ENTRY_SIZE :: 16 // A root entry and a context entry: two words of 64 bits.

// root_entry gives the root entry of a bus: the context table of its 256
// functions.
root_entry :: proc "contextless" (context_table: u64) -> [2]u64 {
	return {context_table & ENTRY_ADDRESS | ENTRY_PRESENT, 0}
}

// context_entry gives the context entry of a function: its requests are
// translated by the second-level tables from top, with levels of tables,
// in the domain identifier domain. The faults are recorded (the bit FPD
// is 0), and the type of translation is 0: untranslated requests only.
context_entry :: proc "contextless" (top: u64, levels: u32, domain: u16) -> [2]u64 {
	return {top & ENTRY_ADDRESS | ENTRY_PRESENT, u64(levels - 2) | u64(domain) << 8}
}

// table_entry gives an entry of a second-level table that names the table
// of the next level. It has the read and the write bits: the bits of the
// page at the last level decide what a device can do.
table_entry :: proc "contextless" (table: u64) -> u64 {
	return table & ENTRY_ADDRESS | ENTRY_READ | ENTRY_WRITE
}

// page_entry gives an entry of the last level: a page of 4096 bytes that a
// device reads, and writes only when writable.
page_entry :: proc "contextless" (address: u64, writable: bool) -> u64 {
	return address & ENTRY_ADDRESS | ENTRY_READ | (writable ? ENTRY_WRITE : 0)
}

entry_present :: proc "contextless" (entry: u64) -> bool {
	return entry & (ENTRY_READ | ENTRY_WRITE) != 0
}

// level_index gives the index of an address in a table of a level: 1 is
// the last level, the table of the pages.
level_index :: proc "contextless" (address: u64, level: u32) -> u64 {
	return address >> (12 + 9 * u64(level - 1)) & 511
}

// One fault that the unit recorded.
Fault :: struct {
	address:   u64, // The page of the request.
	requester: u16,
	reason:    u8, // The fault reason of the specification.
	read:      bool, // A read; else a write.
}

// FAULT_CLEAR is written to the last 4 bytes of a fault recording register:
// it clears the bit F, and the record is free.
FAULT_CLEAR :: u32(1) << 31

FAULT_STATUS_PENDING :: u32(1) << 1 // A record holds a fault (PPF): the unit sends no new fault event while it is set.

// The lines of the log of the DMA faults of one device: one line for each
// of the first FAULT_LINES faults, then one line of the count when the
// count is a power of two. A device that faults in a loop then writes about
// one line for each doubling, and the log keeps the first faults whole.
FAULT_LINES :: 4

Fault_Line :: enum u8 {
	None, // No line for this fault: the count goes on.
	Whole, // The line of the fault, with its address.
	Count, // The line of the count of the faults of the device.
}

// fault_line gives the line of the log for the fault number count of a
// device, from 1.
fault_line :: proc "contextless" (count: u64) -> Fault_Line {
	switch {
	case count == 0:
		return .None
	case count <= FAULT_LINES:
		return .Whole
	case count & (count - 1) == 0:
		return .Count
	}
	return .None
}

// fault_read reads a fault recording register from its first 8 bytes and
// its last 8 bytes. recorded is false when the record is free.
fault_read :: proc "contextless" (low: u64, high: u64) -> (fault: Fault, recorded: bool) {
	return {address = low & ENTRY_ADDRESS, requester = u16(high), reason = u8(high >> 32), read = high >> 62 & 1 != 0}, high >> 63 != 0
}
