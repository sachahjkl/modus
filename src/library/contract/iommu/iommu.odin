// The formats of the IOMMU that the kernel reads and writes. This file
// holds those of Intel (VT-d): the ACPI tables DMAR and MCFG, the registers
// of a remapping unit, the root, context and second-level entries, the
// descriptors of the queue of invalidations, the entries of the interrupt
// table and the address of a remapped message, and a fault record. The
// formats are those of the "Intel Virtualization Technology for Directed
// I/O, Architecture Specification". amd_vi.odin holds those of AMD
// (AMD-Vi). The two parties are the kernel and the hardware. The design is
// src/md/infrastructure/iommu.md.
//
// Each procedure here is pure: it reads bytes or values and gives values,
// so the host tests check each format with no machine.
//
// This package allocates no memory and calls no kernel operation.
package iommu

// The table DMAR: the ACPI header, the host address width minus 1, the
// flags, 10 reserved bytes, then the remapping structures.
DMAR_STRUCTURES_START :: 48
DMAR_HOST_ADDRESS_WIDTH :: 36
DMAR_FLAGS :: 37
// The flag INTR_REMAP of the table: the platform supports interrupt
// remapping. A firmware clears it on a platform whose remapping has a fault,
// even when each unit offers remapping.
DMAR_FLAG_INTERRUPT_REMAPPING :: 1

// The kinds of a remapping structure of the table DMAR.
STRUCTURE_UNIT :: 0 // A remapping unit (DRHD): its registers and its devices.
STRUCTURE_RESERVED_MEMORY :: 1 // A reserved memory range (RMRR): memory that a device keeps using for the firmware.
UNIT_SIZE :: 16 // The bytes of a unit before its device scopes: the kind, the length, the flags, a reserved byte, the segment, the base of its registers.
UNIT_INCLUDES_EVERY_DEVICE :: 1 // The flag INCLUDE_PCI_ALL of a unit: it covers each device of its segment that no other unit lists.
// The bytes of a reserved memory range before its device scopes: the kind,
// the length, 2 reserved bytes, the segment, the first byte, the last byte.
RESERVED_MEMORY_SIZE :: 24

// A device scope: its kind, its length, 2 reserved bytes, the enumeration
// identifier, the start bus, then the path, one pair of the device and the
// function for each bridge down to the device.
SCOPE_HEADER_SIZE :: 6
SCOPE_ENDPOINT :: 1 // A function of PCI.
SCOPE_BRIDGE :: 2 // A bridge of PCI: the function of the bridge, and the buses behind it.

// The bounds of what the kernel keeps of a table DMAR. A table past one of
// them leaves the IOMMU off: the kernel would otherwise program a part of
// the units, and a device of a unit that is off can write the tables of the
// others.
UNIT_CAPACITY :: 4 // A machine of Intel has 2 or 3: one for its graphics device, one for every other device.
RESERVED_RANGE_CAPACITY :: 8
SCOPE_CAPACITY :: 64 // The scopes of the units and of the reserved ranges together.
PATH_CAPACITY :: 4 // The pairs of a path: the bridges down to a device, plus the device.

// A remapping unit as the table gives it.
Unit :: struct {
	register_base:         u64, // The physical address of its registers.
	segment:               u16,
	includes_every_device: bool, // INCLUDE_PCI_ALL: it covers each device of its segment that no other unit names.
}

// A reserved memory range: memory of the firmware that the devices of its
// scopes read and write.
Reserved_Range :: struct {
	start: u64, // The first byte: a multiple of 4096.
	end:   u64, // The byte after the last: a multiple of 4096.
}

// A device scope of a unit or of a reserved range, as the table gives it.
// Only an endpoint and a bridge are kept: the other kinds (an interrupt
// controller, a timer) name no requester of a DMA access.
Scope :: struct {
	owner:       u8, // The index of its unit, or of its reserved range.
	reserved:    bool, // A scope of a reserved range; else of a unit.
	bridge:      bool, // A bridge, and each bus behind it; else an endpoint.
	start_bus:   u8,
	path_length: u8, // 1 to PATH_CAPACITY.
	path:        [PATH_CAPACITY][2]u8, // The device and the function of each pair.
}

// What the kernel found in the table DMAR.
Dmar :: struct {
	host_address_width:   u32, // The bits of a physical address that a device can give.
	interrupt_remapping:  bool, // The flag INTR_REMAP: the platform supports interrupt remapping.
	unit_count:           u32,
	units:                [UNIT_CAPACITY]Unit,
	reserved_range_count: u32,
	reserved_ranges:      [RESERVED_RANGE_CAPACITY]Reserved_Range,
	scope_count:          u32,
	scopes:               [SCOPE_CAPACITY]Scope,
}

// Why the kernel does not use the units of a table DMAR.
Dmar_Problem :: enum u8 {
	None,
	Too_Short, // The table ends before its first structure.
	Bad_Structure, // A structure or a scope has a wrong length, or a reserved range is not whole pages.
	No_Unit, // No remapping unit.
	Too_Many_Units, // More than UNIT_CAPACITY units.
	Other_Segment, // A unit or a reserved range of a segment of PCI other than 0.
	Too_Many_Ranges, // More than RESERVED_RANGE_CAPACITY reserved ranges.
	Too_Many_Scopes, // More than SCOPE_CAPACITY scopes of an endpoint or a bridge.
	Long_Path, // A scope with more than PATH_CAPACITY pairs.
}

// The text of each problem, after "no IOMMU in use: " on the log.
@(rodata)
DMAR_PROBLEM_TEXTS := [Dmar_Problem]string {
	.None            = "none",
	.Too_Short       = "the DMA remapping table is too short",
	.Bad_Structure   = "a structure of the DMA remapping table has a wrong length, or a reserved range is not whole pages",
	.No_Unit         = "the DMA remapping table has no unit",
	.Too_Many_Units  = "the DMA remapping table has more than 4 units",
	.Other_Segment   = "a unit or a reserved range is of a segment of PCI other than 0",
	.Too_Many_Ranges = "the DMA remapping table has more than 8 reserved memory ranges",
	.Too_Many_Scopes = "the DMA remapping table has more than 64 device scopes",
	.Long_Path       = "a device scope has a path of more than 4 bridges and devices",
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
	dmar.interrupt_remapping = table[DMAR_FLAGS] & DMAR_FLAG_INTERRUPT_REMAPPING != 0
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
			if dmar.unit_count == UNIT_CAPACITY {
				return dmar, .Too_Many_Units
			}
			segment := load_16(table, offset + 6)
			if segment != 0 {
				return dmar, .Other_Segment
			}
			dmar.units[dmar.unit_count] = {
				register_base         = load_64(table, offset + 8),
				segment               = segment,
				includes_every_device = table[offset + 4] & UNIT_INCLUDES_EVERY_DEVICE != 0,
			}
			if scope_problem := scopes_read(&dmar, table[offset + UNIT_SIZE:offset + length], u8(dmar.unit_count), false); scope_problem != .None {
				return dmar, scope_problem
			}
			dmar.unit_count += 1
		case STRUCTURE_RESERVED_MEMORY:
			if length < RESERVED_MEMORY_SIZE {
				return dmar, .Bad_Structure
			}
			if dmar.reserved_range_count == RESERVED_RANGE_CAPACITY {
				return dmar, .Too_Many_Ranges
			}
			if load_16(table, offset + 6) != 0 {
				return dmar, .Other_Segment
			}
			// The table gives the last byte: the range must be whole pages,
			// and its end must not wrap.
			start, last := load_64(table, offset + 8), load_64(table, offset + 16)
			if start % 4096 != 0 || last < start || last == max(u64) || (last + 1) % 4096 != 0 {
				return dmar, .Bad_Structure
			}
			dmar.reserved_ranges[dmar.reserved_range_count] = {start = start, end = last + 1}
			if scope_problem := scopes_read(&dmar, table[offset + RESERVED_MEMORY_SIZE:offset + length], u8(dmar.reserved_range_count), true); scope_problem != .None {
				return dmar, scope_problem
			}
			dmar.reserved_range_count += 1
		}
		offset += length
	}
	if dmar.unit_count == 0 {
		return dmar, .No_Unit
	}
	return dmar, .None
}

// scopes_read reads the device scopes of one unit or one reserved range,
// and keeps each endpoint and each bridge.
@(private = "file")
scopes_read :: proc "contextless" (dmar: ^Dmar, bytes: []u8, owner: u8, reserved: bool) -> Dmar_Problem {
	scope := 0
	for scope < len(bytes) {
		if len(bytes) - scope < SCOPE_HEADER_SIZE {
			return .Bad_Structure
		}
		kind := bytes[scope]
		length := int(bytes[scope + 1])
		if length < SCOPE_HEADER_SIZE || length > len(bytes) - scope {
			return .Bad_Structure
		}
		if kind == SCOPE_ENDPOINT || kind == SCOPE_BRIDGE {
			path_bytes := length - SCOPE_HEADER_SIZE
			if path_bytes == 0 || path_bytes % 2 != 0 {
				return .Bad_Structure
			}
			if path_bytes / 2 > PATH_CAPACITY {
				return .Long_Path
			}
			if dmar.scope_count == SCOPE_CAPACITY {
				return .Too_Many_Scopes
			}
			item := &dmar.scopes[dmar.scope_count]
			item^ = {owner = owner, reserved = reserved, bridge = kind == SCOPE_BRIDGE, start_bus = bytes[scope + 5], path_length = u8(path_bytes / 2)}
			for pair in 0 ..< path_bytes / 2 {
				item.path[pair] = {bytes[scope + SCOPE_HEADER_SIZE + 2 * pair] & 31, bytes[scope + SCOPE_HEADER_SIZE + 2 * pair + 1] & 7}
			}
			dmar.scope_count += 1
		}
		scope += length
	}
	return .None
}

// Bridge_Read gives the secondary and the subordinate bus of the bridge at
// a place of the bus. found is false when the place holds no bridge. The
// kernel gives a procedure that reads the configuration memory; a host test
// gives a table.
Bridge_Read :: #type proc "contextless" (bus, device, function: u32) -> (secondary: u32, subordinate: u32, found: bool)

// A device scope with its path followed through the bridges of the bus.
Resolved_Scope :: struct {
	found:     bool, // Each bridge of the path is there: the scope names a requester.
	requester: u16, // The function that the scope names: the endpoint, or the bridge.
	first_bus: u8, // A bridge: its secondary bus.
	last_bus:  u8, // A bridge: its subordinate bus, the last bus behind it.
}

// scope_resolve follows the path of a scope: from its start bus, each pair
// but the last is a bridge, whose secondary bus holds the next pair. A
// secondary bus at or below the bus of its bridge is refused: the buses grow
// away from bus 0, and such a number would make a loop of the walk.
scope_resolve :: proc "contextless" (scope: Scope, bridge_read: Bridge_Read) -> (resolved: Resolved_Scope) {
	if scope.path_length == 0 || scope.path_length > PATH_CAPACITY {
		return {}
	}
	bus := u32(scope.start_bus)
	for pair in 0 ..< int(scope.path_length) - 1 {
		secondary, _, found := bridge_read(bus, u32(scope.path[pair][0]), u32(scope.path[pair][1]))
		if !found || secondary <= bus || secondary > 255 {
			return {}
		}
		bus = secondary
	}
	last := scope.path[scope.path_length - 1]
	resolved.requester = requester(bus, u32(last[0]), u32(last[1]))
	if scope.bridge {
		secondary, subordinate, found := bridge_read(bus, u32(last[0]), u32(last[1]))
		if !found || secondary <= bus || subordinate < secondary || subordinate > 255 {
			return {}
		}
		resolved.first_bus, resolved.last_bus = u8(secondary), u8(subordinate)
	}
	resolved.found = true
	return resolved
}

// unit_of gives the unit that translates the accesses of a requester: the
// first unit with a scope that names it (an endpoint with this requester,
// or a bridge with this requester or with its bus behind it), else the
// unit of segment 0 with INCLUDE_PCI_ALL. covered is false when no unit
// translates them: the device reaches all memory. resolved holds the
// resolved scope of each scope of the table, at the same index.
unit_of :: proc "contextless" (dmar: ^Dmar, resolved: ^[SCOPE_CAPACITY]Resolved_Scope, requester: u16) -> (unit: u32, covered: bool) {
	bus := requester_bus(requester)
	for index in 0 ..< min(int(dmar.scope_count), SCOPE_CAPACITY) {
		scope := &dmar.scopes[index]
		item := &resolved[index]
		if scope.reserved || !item.found {
			continue
		}
		if item.requester == requester || (scope.bridge && bus >= u32(item.first_bus) && bus <= u32(item.last_bus)) {
			return u32(scope.owner), true
		}
	}
	for index in 0 ..< min(int(dmar.unit_count), UNIT_CAPACITY) {
		if dmar.units[index].includes_every_device && dmar.units[index].segment == 0 {
			return u32(index), true
		}
	}
	return 0, false
}

// The table MCFG: the ACPI header, 8 reserved bytes, then one entry of 16
// bytes for each range of buses: the base address, the segment, the first
// and the last bus.
MCFG_ENTRIES_START :: 44
MCFG_ENTRY_SIZE :: 16

// The memory of the configuration of PCI of one range of buses of segment 0.
// Each bus has 1 MiB of it.
Configuration_Memory :: struct {
	base:      u64, // The physical address of the configuration of the first bus of the range.
	first_bus: u8,
	last_bus:  u8,
}

// CONFIGURATION_BUS_SIZE is the configuration memory of one bus: 32
// devices of 8 functions of 4096 bytes.
CONFIGURATION_BUS_SIZE :: u64(1) << 20

// mcfg_read gives the range of segment 0 that starts at bus 0. found is
// false when the table names none.
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
// register of a device: 6 registers. A bridge gives no base: a device of
// conventional PCI behind it sends its accesses with the requester of the
// bridge, so the registers of the bridge name no device of a service. A
// register of ports, or a base of 0, gives no base. A register of 64 bits
// takes the next register as its high half.
header_memory_bases :: proc "contextless" (header: [HEADER_WORDS]u32) -> (bases: [6]u64, count: int) {
	register_count := 0
	if header[3] >> 16 & 0x7F == 0 {
		register_count = 6
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

// header_is_bridge says if a function is a bridge of PCI: the header type 1.
header_is_bridge :: proc "contextless" (header: [HEADER_WORDS]u32) -> bool {
	return header[3] >> 16 & 0x7F == 1
}

// bridge_buses gives the secondary bus of a bridge, the bus just behind
// it, and its subordinate bus, the last bus behind it: the bytes 0x19 and
// 0x1A of its header.
bridge_buses :: proc "contextless" (header: [HEADER_WORDS]u32) -> (secondary: u32, subordinate: u32) {
	return header[6] >> 8 & 0xFF, header[6] >> 16 & 0xFF
}

// The words of the configuration of a function that the kernel reads to
// know the kind of a bridge: the first 256 bytes, the space of PCI before
// PCI Express, which holds the capability of PCI Express.
CONFIGURATION_WORDS :: 64
CAPABILITY_PCI_EXPRESS :: 0x10
STATUS_CAPABILITIES :: u32(1) << 20 // The bit of the status, in the word 1: the function has a list of capabilities.

// The port types of the capability of PCI Express (bits 7:4 of its
// capability register) whose bridge passes the requester of each device
// behind it unchanged: a root port, the upstream and the downstream port of
// a switch.
PORT_ROOT :: 4
PORT_SWITCH_UPSTREAM :: 5
PORT_SWITCH_DOWNSTREAM :: 6
// The port type of a bridge from PCI Express to PCI: a conventional bridge
// that gives the devices behind it the requester of its secondary bus.
PORT_PCI_EXPRESS_TO_PCI :: 7

// express_port_type gives the port type of the capability of PCI Express of
// a function. found: the function has that capability. The walk of the
// capabilities stops after 48, as a list that loops would never end.
express_port_type :: proc "contextless" (configuration: ^[CONFIGURATION_WORDS]u32) -> (port: u32, found: bool) {
	if configuration[1] & STATUS_CAPABILITIES == 0 {
		return 0, false
	}
	offset := configuration[0x34 / 4] & 0xFC
	for _ in 0 ..< 48 {
		if offset < 0x40 || offset > 0xFC {
			return 0, false
		}
		word := configuration[offset / 4]
		if word & 0xFF == CAPABILITY_PCI_EXPRESS {
			return word >> 20 & 0xF, true
		}
		offset = word >> 8 & 0xFC
	}
	return 0, false
}

// bridge_passes_requesters says if a bridge gives each device behind it
// its own requester. A bridge of PCI Express does. A conventional bridge (a
// bridge from PCI Express to PCI, or one with no capability of PCI Express)
// gives the accesses of the devices behind it one shared requester
// (bridge_shared_requester).
bridge_passes_requesters :: proc "contextless" (configuration: ^[CONFIGURATION_WORDS]u32) -> bool {
	port, found := express_port_type(configuration)
	return found && (port == PORT_ROOT || port == PORT_SWITCH_UPSTREAM || port == PORT_SWITCH_DOWNSTREAM)
}

// bridge_shared_requester gives the requester that a conventional bridge at
// a place, with its secondary bus, gives the accesses of each device behind
// it: the shared requester. A bridge from PCI Express to PCI makes each
// request with its secondary bus, the device 0 and the function 0; another
// conventional bridge makes it with its own requester. QEMU 10 and Linux
// take the same rule.
bridge_shared_requester :: proc "contextless" (configuration: ^[CONFIGURATION_WORDS]u32, bus, device, function, secondary: u32) -> u16 {
	if port, found := express_port_type(configuration); found && port == PORT_PCI_EXPRESS_TO_PCI {
		return requester(secondary, 0, 0)
	}
	return requester(bus, device, function)
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
REGISTER_FAULT_STATUS :: 0x34 // u32
REGISTER_FAULT_EVENT_CONTROL :: 0x38 // u32
REGISTER_FAULT_EVENT_DATA :: 0x3C // u32: the vector of the fault event.
REGISTER_FAULT_EVENT_ADDRESS :: 0x40 // u32: the interrupt controller that receives it.
REGISTER_FAULT_EVENT_UPPER_ADDRESS :: 0x44 // u32
REGISTER_QUEUE_TAIL :: 0x88 // u64: the descriptor after the last that the kernel wrote, as queue_tail_register gives it.
REGISTER_QUEUE_ADDRESS :: 0x90 // u64: the queue of invalidations, as queue_address_register gives it.
REGISTER_INTERRUPT_TABLE :: 0xB8 // u64: the interrupt table, as interrupt_table_register gives it.
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
GLOBAL_INTERRUPT_TABLE :: u32(1) << 24 // Take the interrupt table of the register (SIRTP, IRTPS).
// The bit CFI (23) stays 0: with remapping on, the unit then blocks every
// message in the compatible form, which names a vector with no entry.

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

// The queue of invalidations: a ring of descriptors of 16 bytes in memory
// that the unit reads from its head to the tail that the kernel writes. Its
// size is one page, the smallest that the register gives (QS 0): the kernel
// waits for each invalidation, which has at most QUEUE_LARGEST_BATCH
// descriptors, so the queue never holds more than one.
QUEUE_DESCRIPTORS :: 256
QUEUE_LARGEST_BATCH :: 8
DESCRIPTOR_SIZE :: 16

// The kinds of a descriptor, in its bits 3:0.
DESCRIPTOR_CONTEXT :: u64(1) // The context cache.
DESCRIPTOR_IOTLB :: u64(2) // The translations of the second-level tables.
DESCRIPTOR_INTERRUPT_ENTRY :: u64(4) // The interrupt entry cache.
DESCRIPTOR_WAIT :: u64(5) // The wait: the unit writes a number when it has done each descriptor before it.

// The granularity of a descriptor of the context cache or of the IOTLB, in
// its bits 5:4.
GRANULARITY_GLOBAL :: u64(1) << 4 // Each entry of each domain.
GRANULARITY_DOMAIN :: u64(2) << 4 // The entries of one domain identifier, in the bits 31:16.

IOTLB_DRAIN_WRITES :: u64(1) << 6
IOTLB_DRAIN_READS :: u64(1) << 7
INTERRUPT_ENTRY_ONE :: u64(1) << 4 // The interrupt entry of the index in the bits 47:32; with 0, each entry.
WAIT_STATUS_WRITE :: u64(1) << 5 // The unit writes the number of the bits 63:32 at the address of the second word.
WAIT_FENCE :: u64(1) << 6 // The descriptors after it wait until it is done.

// descriptor_context gives the descriptor that forgets the context entries
// of one domain identifier, or every context entry with global. A unit with
// the caching mode tags an entry that is not present with the identifier 0.
descriptor_context :: proc "contextless" (domain: u16, global: bool = false) -> [2]u64 {
	if global {
		return {DESCRIPTOR_CONTEXT | GRANULARITY_GLOBAL, 0}
	}
	return {DESCRIPTOR_CONTEXT | GRANULARITY_DOMAIN | u64(domain) << 16, 0}
}

// descriptor_iotlb gives the descriptor that forgets the translations of
// one domain identifier, or of each domain with global, with the drain of
// the reads and the writes in flight.
descriptor_iotlb :: proc "contextless" (domain: u16, global: bool = false) -> [2]u64 {
	drains := IOTLB_DRAIN_READS | IOTLB_DRAIN_WRITES
	if global {
		return {DESCRIPTOR_IOTLB | GRANULARITY_GLOBAL | drains, 0}
	}
	return {DESCRIPTOR_IOTLB | GRANULARITY_DOMAIN | drains | u64(domain) << 16, 0}
}

// descriptor_interrupt_entry gives the descriptor that forgets the interrupt
// entry of one index, or each interrupt entry with global.
descriptor_interrupt_entry :: proc "contextless" (index: u16, global: bool = false) -> [2]u64 {
	if global {
		return {DESCRIPTOR_INTERRUPT_ENTRY, 0}
	}
	return {DESCRIPTOR_INTERRUPT_ENTRY | INTERRUPT_ENTRY_ONE | u64(index) << 32, 0}
}

// descriptor_wait gives the wait descriptor that writes number at the
// physical address status (4 bytes, aligned to 4) when the unit has done
// every descriptor before it.
descriptor_wait :: proc "contextless" (status: u64, number: u32) -> [2]u64 {
	return {DESCRIPTOR_WAIT | WAIT_STATUS_WRITE | WAIT_FENCE | u64(number) << 32, status &~ 3}
}

// queue_address_register gives the value of the register of the queue: its
// page, the descriptors of 16 bytes (DW 0) and the size of one page (QS 0).
queue_address_register :: proc "contextless" (queue: u64) -> u64 {
	return queue &~ 0xFFF
}

// queue_tail_register gives the value of the tail register for a
// descriptor index: the index in the bits 18:4.
queue_tail_register :: proc "contextless" (index: u32) -> u64 {
	return u64(index % QUEUE_DESCRIPTORS) << 4
}

// The device addresses of the objects that are not contiguous
// (src/md/infrastructure/iommu.md, "Device addresses"): the window of the
// memory object of the slot n starts at WINDOW_BASE + n * WINDOW_SIZE, and
// maps its pages in their order. A contiguous object, and a reserved memory
// range, has its physical address as its device address, and must end at
// or below WINDOW_BASE.
WINDOW_BASE :: u64(1) << 38
WINDOW_SIZE :: u64(1) << 27 // 128 MiB: the largest object that is not contiguous that a device gets.
WINDOW_PAGES :: WINDOW_SIZE / 4096

// window_address gives the device address of the first page of the memory
// object of a slot that is not contiguous.
window_address :: proc "contextless" (slot: u32) -> u64 {
	return WINDOW_BASE + u64(slot) * WINDOW_SIZE
}

// The largest reserved memory range that the kernel maps: 1 GiB. Its
// tables are memory of the kernel, which no budget pays.
RESERVED_RANGE_PAGE_LIMIT :: (u64(1) << 30) / 4096

FAULT_STATUS_OVERFLOW :: u32(1) // A fault came when no record was free; written 1 to clear.
FAULT_STATUS_QUEUE_ERROR :: u32(1) << 4 // The unit refused a descriptor of the queue (IQE), and reads no more of it.
FAULT_STATUS_COMPLETION_ERROR :: u32(1) << 5 // A device gave no answer to an invalidation of its own cache (ICE).
FAULT_STATUS_TIME_OUT_ERROR :: u32(1) << 6 // An invalidation of the cache of a device took too long (ITE).
// The bits of the fault status that the firmware can leave set, each
// cleared by a write of 1: the start clears them all, so an error of the
// queue of the firmware does not stop the first invalidation of the kernel.
FAULT_STATUS_CLEARED_AT_START :: FAULT_STATUS_OVERFLOW | FAULT_STATUS_QUEUE_ERROR | FAULT_STATUS_COMPLETION_ERROR | FAULT_STATUS_TIME_OUT_ERROR

// The most levels of the tables of a domain, on each vendor: addresses of
// 48 bits. The kernel frees a table level by level, one frame of its
// stack for each level.
DOMAIN_TABLE_LEVELS_MOST :: 4
#assert(AMD_LEVELS <= DOMAIN_TABLE_LEVELS_MOST)

// capability_levels gives the levels of the second-level tables that the
// kernel uses: 4 for addresses of 48 bits, else 3 for 39 bits, else 0 (the
// unit offers neither).
capability_levels :: proc "contextless" (capability: u64) -> u32 {
	widths := capability >> 8 & 0x1F
	switch {
	case widths & 4 != 0:
		return DOMAIN_TABLE_LEVELS_MOST
	case widths & 2 != 0:
		return 3
	}
	return 0
}

// capability_address_width gives the widest device address that the unit
// translates (MGAW, bits 21:16, plus 1). The unit blocks a request above
// it, whatever its tables map.
capability_address_width :: proc "contextless" (capability: u64) -> u32 {
	return u32(capability >> 16 & 0x3F) + 1
}

// The address width that the device windows need: the last window ends at
// 2^39.
WINDOW_ADDRESS_WIDTH :: 39

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

// extended_queue says if the unit has a queue of invalidations (QI, bit
// 1): the kernel invalidates through it only.
extended_queue :: proc "contextless" (extended: u64) -> bool {
	return extended >> 1 & 1 != 0
}

// extended_interrupt_remapping says if the unit offers interrupt remapping
// (IR, bit 3).
extended_interrupt_remapping :: proc "contextless" (extended: u64) -> bool {
	return extended >> 3 & 1 != 0
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

// The interrupt table: one entry of 16 bytes for each message interrupt,
// at the index of the message interrupt. The register gives the count of
// its entries as 2^(size + 1).
INTERRUPT_TABLE_ENTRIES :: 16
INTERRUPT_TABLE_SIZE_FIELD :: 3
#assert(1 << (INTERRUPT_TABLE_SIZE_FIELD + 1) == INTERRUPT_TABLE_ENTRIES)
INTERRUPT_ENTRY_SIZE :: 16

// interrupt_table_register gives the value of the register of the interrupt
// table: its page, the size, and the destination of 8 bits (EIME 0), which
// names a processor whose identifier is below 256.
interrupt_table_register :: proc "contextless" (table: u64) -> u64 {
	return table &~ 0xFFF | INTERRUPT_TABLE_SIZE_FIELD
}

INTERRUPT_ENTRY_PRESENT :: u64(1)
INTERRUPT_ENTRY_VERIFY_REQUESTER :: u64(1) << 18 // SVT 1 with SQ 0: the requester of the message must be the requester of the entry, all 16 bits.

// interrupt_entry gives the entry of a message interrupt: present, fixed
// delivery of the vector to the processor of the interrupt controller
// identifier processor in the physical mode, at the edge; the unit refuses
// it to every requester but this one. The faults of the entry are recorded
// (FPD 0).
interrupt_entry :: proc "contextless" (vector: u8, processor: u8, requester: u16) -> [2]u64 {
	return {INTERRUPT_ENTRY_PRESENT | u64(vector) << 16 | u64(processor) << 40, u64(requester) | INTERRUPT_ENTRY_VERIFY_REQUESTER}
}

// message_address gives the address that a device writes for the message
// interrupt of an index of the interrupt table, in the remappable form:
// 0xFEE, the index in the bits 19:5 and its bit 15 in the bit 2, the bit 4
// that says the form, and no subhandle (SHV 0), so the value of the message
// is not read.
message_address :: proc "contextless" (index: u16) -> u64 {
	return 0xFEE0_0000 | u64(index & 0x7FFF) << 5 | u64(index >> 15) << 2 | 1 << 4
}

// One fault that the unit recorded.
Fault :: struct {
	address:   u64, // The page of the request; 0 for a refused interrupt.
	requester: u16,
	reason:    u16, // The fault reason of VT-d, or the flags of a page fault of AMD-Vi.
	read:      bool, // A read; else a write.
	interrupt: bool, // A refused message interrupt: a reason from 0x20 to 0x2F.
	index:     u16, // A refused interrupt: the index of the entry that the message named.
}

// The reasons of a refused interrupt: 0x20 (a reserved field of the
// message) to 0x26 (another requester); 0x2x is the group of the
// specification for interrupt remapping.
FAULT_REASON_INTERRUPT_FIRST :: 0x20
FAULT_REASON_INTERRUPT_LAST :: 0x2F

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
// its last 8 bytes. recorded is false when the record is free. The record of
// a refused interrupt holds the index of the entry in the bits 63:48 of its
// first word, and no address.
fault_read :: proc "contextless" (low: u64, high: u64) -> (fault: Fault, recorded: bool) {
	fault = {requester = u16(high), reason = u16(high >> 32 & 0xFF), read = high >> 62 & 1 != 0}
	if fault.reason >= FAULT_REASON_INTERRUPT_FIRST && fault.reason <= FAULT_REASON_INTERRUPT_LAST {
		fault.interrupt = true
		fault.index = u16(low >> 48)
		fault.read = false
	} else {
		fault.address = low & ENTRY_ADDRESS
	}
	return fault, high >> 63 != 0
}
