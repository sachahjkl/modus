package kernel

import info "modus:contract/boot_info"
import "modus:contract/iommu"
import op "modus:contract/operation"
import "base:intrinsics"

// The IOMMU (src/md/infrastructure/iommu.md): the kernel owns the tables of
// the remapping units, and a device reaches only the pages that its service
// declared with Memory_Physical, and writes only those that the handle of
// the declaration could write. The kernel holds no code of a device: it
// reads the base address registers and the bridges of the bus only to know
// which device the registers of a memory object belong to, and which unit
// translates its accesses.
//
// The slots of the devices, the bits `declared` and `declared_writable` of
// each memory object and the tables of the domains change under the frame
// lock: a declaration ends in region_release under that lock, before the
// frames of its object return (docs/ARCHITECTURE.md, "K5. Device grant and
// interrupts"). The fault handler reads `owner` and the counts of the
// faults with atomic loads and no lock. The units, the context tables and
// the standing domains are written once, at the start.

// The devices that have a domain at one time. A slot is free again when
// its domain ends. The domain identifier of a slot is the slot + 1: the
// identifier 0 stays unused, as the caching mode needs.
IOMMU_DEVICE_CAPACITY :: 32
// The devices whose registers one service can hold and declare memory to:
// a declaration from a program that holds the registers of more gives
// No_Slot. A device service holds one.
IOMMU_DEVICES_OF_A_SERVICE :: 4
// The devices that a reserved memory range names, each with a standing
// domain, whose identifiers follow those of the slots.
IOMMU_STANDING_CAPACITY :: 8
IOMMU_STANDING_DOMAIN_FIRST :: IOMMU_DEVICE_CAPACITY + 1

// Every window of a memory object ends where a domain of 39 bits ends, so
// the slot of an object always names a window that the tables can map.
#assert(REGION_CAPACITY * iommu.WINDOW_SIZE <= iommu.WINDOW_BASE)

// One remapping unit that the kernel programs.
Iommu_Unit :: struct {
	register_base:  u64, // The physical address of its registers.
	registers:      uintptr, // The same registers, in the direct map.
	capability:     u64,
	extended:       u64,
	levels:         u32, // The levels of the tables of a domain of this unit.
	address_end:    u64, // The first device address that the unit blocks: 2^MGAW.
	windows:        bool, // The unit translates the addresses of the device windows (iommu.WINDOW_ADDRESS_WIDTH bits).
	fault_offset:   u64, // The first fault recording register.
	fault_count:    u64,
	root:           u64, // The root table: a root entry for each bus.
	context_tables: [256]u64, // The context table of each bus that the walk at the start found. 0: none.
}

// The domain of one device: its requester, its unit, the program that
// owns it, and its second-level tables. A slot whose owner is 0 is free.
Iommu_Device :: struct {
	requester:    u16,
	unit:         u32,
	present:      bool, // Its context entry is present.
	owner:        u32, // The program slot of the service that owns the domain. 0: a free slot. Atomic.
	owner_serial: u32, // The serial of that program, when it took the domain.
	top:          u64, // The top table of the domain.
}

// The standing domain of a device that a reserved memory range names: its
// ranges, mapped at their own addresses in tables of the kernel. Its
// context entry is present while no service owns the device.
Iommu_Standing :: struct {
	used:      bool,
	requester: u16,
	unit:      u32,
	top:       u64,
}

iommu_in_use: bool // Translation is on. Written once at the start.
iommu_units: [iommu.UNIT_CAPACITY]Iommu_Unit
iommu_unit_count: u32
iommu_coherent: bool // Every unit snoops the caches when it reads a table.
iommu_configuration: u64 // The physical address of the configuration memory of bus 0.
iommu_configuration_size: u64 // The configuration memory that the kernel reads and owns: 1 MiB for each bus.
iommu_last_bus: u32 // The last bus of that memory.
iommu_dmar: iommu.Dmar // The table DMAR as read at the start.
iommu_scopes: [iommu.SCOPE_CAPACITY]iommu.Resolved_Scope // Each scope of iommu_dmar, resolved at the start.
iommu_reserved_mapped: [iommu.RESERVED_RANGE_CAPACITY]bool // The reserved ranges that the domains map.
iommu_standing: [IOMMU_STANDING_CAPACITY]Iommu_Standing
iommu_devices: [IOMMU_DEVICE_CAPACITY]Iommu_Device
// The DMA faults of each function of bus 0, by the low byte of its
// requester, and of all the functions of the other buses. Atomic: they
// outlive the domain of a device.
iommu_faults: [256]u64
iommu_faults_of_other_buses: u64
// The passes of one call of iommu_faults_take over the fault records.
IOMMU_FAULT_PASSES :: 2
// A record was still pending at the end of the last call: the next tick of
// the first processor reads the records again. Atomic.
iommu_faults_left: bool

@(private = "file")
register_read_32 :: proc "contextless" (unit: ^Iommu_Unit, offset: u64) -> u32 {
	return intrinsics.volatile_load((^u32)(unit.registers + uintptr(offset)))
}

@(private = "file")
register_write_32 :: proc "contextless" (unit: ^Iommu_Unit, offset: u64, value: u32) {
	intrinsics.volatile_store((^u32)(unit.registers + uintptr(offset)), value)
}

@(private = "file")
register_read_64 :: proc "contextless" (unit: ^Iommu_Unit, offset: u64) -> u64 {
	return intrinsics.volatile_load((^u64)(unit.registers + uintptr(offset)))
}

@(private = "file")
register_write_64 :: proc "contextless" (unit: ^Iommu_Unit, offset: u64, value: u64) {
	intrinsics.volatile_store((^u64)(unit.registers + uintptr(offset)), value)
}

// write_back writes the cache lines of a part of a table to memory when a
// unit does not snoop the caches: it reads memory, not the cache.
@(private = "file")
write_back :: proc "contextless" (physical: u64, size: u64) {
	if iommu_coherent {
		return
	}
	for line := physical &~ 63; line < physical + size; line += 64 {
		cache_line_write_back(direct(line, u8))
	}
}

// The wait for a command of a unit: one second of the cycle counter. A
// unit that has not ended a command by then is broken. The waiter answers
// processor_sync in each turn, as a waiter for a lock does, so another
// processor that waits for it is not stalled for the whole wait.
@(private = "file")
wait_bound :: proc "contextless" () -> u64 {
	return cycles_now() + cycle_frequency
}

// wait_turn ends one turn of a wait. false: the bound passed.
@(private = "file")
wait_turn :: proc "contextless" (bound: u64) -> bool {
	if cycles_now() > bound {
		return false
	}
	sync_acknowledge(processor_self())
	intrinsics.cpu_relax()
	return true
}

// global_set sets one bit of the global command of a unit and waits until
// the status shows it. false: the unit did not.
@(private = "file")
global_set :: proc "contextless" (unit: ^Iommu_Unit, bit: u32) -> bool {
	register_write_32(unit, iommu.REGISTER_GLOBAL_COMMAND, iommu.global_command(register_read_32(unit, iommu.REGISTER_GLOBAL_STATUS), bit))
	bound := wait_bound()
	for register_read_32(unit, iommu.REGISTER_GLOBAL_STATUS) & bit == 0 {
		if !wait_turn(bound) {
			return false
		}
	}
	return true
}

// translation_off turns the translation of a unit off, and waits until
// the status shows it: a unit that the start turned on before another unit
// failed.
@(private = "file")
translation_off :: proc "contextless" (unit: ^Iommu_Unit) {
	status := register_read_32(unit, iommu.REGISTER_GLOBAL_STATUS)
	register_write_32(unit, iommu.REGISTER_GLOBAL_COMMAND, iommu.global_command(status, 0) &~ iommu.GLOBAL_TRANSLATION)
	bound := wait_bound()
	for register_read_32(unit, iommu.REGISTER_GLOBAL_STATUS) & iommu.GLOBAL_TRANSLATION != 0 {
		if !wait_turn(bound) {
			// The unit still translates with the standing domains only: its
			// devices fault, and the kernel no longer owns its registers.
			log("kernel: IOMMU: a unit did not turn translation off: its devices reach only the reserved memory ranges, and Device_Create can give its registers")
			return
		}
	}
}

// invalidate_unit makes a unit forget the context entries and the
// translations that the two commands name, with the drain of the reads and
// writes in flight, and waits until it did: after it, no device of the
// unit uses an entry that the kernel cleared. The flush of the write
// buffer comes first when the unit needs it. A context command of 0 is
// none. A unit that does not end a command, or that ends it with no
// invalidation made (the granularity 0), stops the machine: a page that a
// device can still reach must not become free.
@(private = "file")
invalidate_unit :: proc "contextless" (unit: ^Iommu_Unit, context_command: u64, iotlb_command: u64) {
	done := true
	if iommu.capability_write_buffer(unit.capability) {
		register_write_32(unit, iommu.REGISTER_GLOBAL_COMMAND, iommu.global_command(register_read_32(unit, iommu.REGISTER_GLOBAL_STATUS), iommu.GLOBAL_WRITE_BUFFER))
		bound := wait_bound()
		for done && register_read_32(unit, iommu.REGISTER_GLOBAL_STATUS) & iommu.GLOBAL_WRITE_BUFFER != 0 {
			done = wait_turn(bound)
		}
	}
	if done && context_command != 0 {
		register_write_64(unit, iommu.REGISTER_CONTEXT_COMMAND, context_command)
		bound := wait_bound()
		for {
			finished, made := iommu.context_invalidation_done(register_read_64(unit, iommu.REGISTER_CONTEXT_COMMAND))
			if finished {
				done = made
				break
			}
			if !wait_turn(bound) {
				done = false
				break
			}
		}
	}
	if done {
		iotlb := iommu.extended_iotlb_offset(unit.extended) + 8
		register_write_64(unit, iotlb, iotlb_command)
		bound := wait_bound()
		for {
			finished, made := iommu.iotlb_invalidation_done(register_read_64(unit, iotlb))
			if finished {
				done = made
				break
			}
			if !wait_turn(bound) {
				done = false
				break
			}
		}
	}
	if !done {
		fault_report_begin()
		log("kernel: the IOMMU did not finish an invalidation, or made none: the machine stops")
		machine_stop(2)
	}
}

// How the context entry of a domain changed, for its invalidation.
Context_Change :: enum {
	None, // Only the pages of the domain changed.
	Made, // The entry became present: a unit with the caching mode can keep it as not present, under the identifier 0.
	Cleared, // The entry is not present any more.
}

// invalidate_slot makes the unit of a device slot forget its domain only:
// a service pays for its own domain, and drops no translation of another
// device. The caller holds the frame lock.
@(private = "file")
invalidate_slot :: proc "contextless" (slot: u32, change: Context_Change) {
	domain := u16(slot + 1)
	context_command: u64
	switch change {
	case .None:
	case .Made:
		context_command = iommu.context_command_domain(0)
	case .Cleared:
		context_command = iommu.context_command_domain(domain)
	}
	invalidate_unit(&iommu_units[iommu_devices[slot].unit], context_command, iommu.iotlb_command_domain(domain))
}

// invalidate_slots invalidates the domain of each device slot of a mask;
// made: the slots whose context entry became present.
@(private = "file")
invalidate_slots :: proc "contextless" (mask: u32, made: u32) {
	for slot in u32(0) ..< IOMMU_DEVICE_CAPACITY {
		if mask & (1 << slot) != 0 {
			invalidate_slot(slot, made & (1 << slot) != 0 ? .Made : .None)
		}
	}
}

// configuration_read reads a word of the configuration memory of a
// function. Each read can be an exit to the hypervisor.
@(private = "file")
configuration_read :: proc "contextless" (bus, device, function, register: u32) -> u32 {
	return intrinsics.volatile_load(direct(iommu_configuration + iommu.configuration_offset(bus, device, function, register), u32))
}

// header_read reads the words of the header of a function that the walk
// needs: the identity, the header type and the six registers, which hold
// the bus numbers of a bridge. A place with no function gives the identity
// 0xFFFF and no other word.
@(private = "file")
header_read :: proc "contextless" (bus, device, function: u32) -> (header: [iommu.HEADER_WORDS]u32) {
	header[0] = configuration_read(bus, device, function, 0)
	if header[0] & 0xFFFF == 0xFFFF {
		return header
	}
	for index in u32(3) ..< 10 {
		header[index] = configuration_read(bus, device, function, index * 4)
	}
	return header
}

// bridge_read gives the buses of the bridge at a place: the resolution of
// the paths of the scopes of the table DMAR reads it.
@(private = "file")
bridge_read :: proc "contextless" (bus, device, function: u32) -> (secondary: u32, subordinate: u32, found: bool) {
	if bus > iommu_last_bus {
		return 0, 0, false
	}
	header := header_read(bus, device, function)
	if header[0] & 0xFFFF == 0xFFFF || !iommu.header_is_bridge(header) {
		return 0, 0, false
	}
	secondary, subordinate = iommu.bridge_buses(header)
	return secondary, subordinate, true
}

// bridge_passes reads the first 256 bytes of the configuration of a
// bridge and says if it gives each device behind it its own requester.
@(private = "file")
bridge_passes :: proc "contextless" (bus, device, function: u32) -> bool {
	configuration: [iommu.CONFIGURATION_WORDS]u32
	for &word, index in configuration {
		word = configuration_read(bus, device, function, u32(index) * 4)
	}
	return iommu.bridge_passes_requesters(&configuration)
}

// A walk of the buses: bus 0, then the secondary bus of each bridge, each
// bus once. With `physical`, it stops at the function whose memory
// register starts there; with make_tables, it makes the context table of
// the bus of each function that a unit covers.
Bus_Walk :: struct {
	physical:                   u64,
	make_tables:                bool,
	found:                      bool,
	requester:                  u16, // The function that was found.
	behind_conventional_bridge: bool, // A conventional bridge is on its way from bus 0: it shares its requester.
	no_memory:                  bool, // A context table had no frame.
	bus_count:                  u32,
}

@(private = "file")
buses_walk :: proc "contextless" (walk: ^Bus_Walk) {
	// A bus is queued at most once, so the queue holds at most 256 buses.
	// A bus is behind a conventional bridge when one bridge on its way is.
	queue: [256]u8
	queued: [256]bool
	conventional: [256]bool
	count := 1
	queued[0] = true
	for next := 0; next < count; next += 1 {
		bus := u32(queue[next])
		walk.bus_count += 1
		for device in u32(0) ..< 32 {
			for function in u32(0) ..< 8 {
				header := header_read(bus, device, function)
				if header[0] & 0xFFFF == 0xFFFF {
					if function == 0 {
						break // No device at this place.
					}
					continue
				}
				identifier := iommu.requester(bus, device, function)
				if walk.make_tables && !conventional[bus] && !context_table_make(identifier) {
					walk.no_memory = true
					return
				}
				if iommu.header_is_bridge(header) {
					secondary, _ := iommu.bridge_buses(header)
					if secondary > bus && secondary <= iommu_last_bus && !queued[secondary] {
						queued[secondary] = true
						conventional[secondary] = conventional[bus] || !bridge_passes(bus, device, function)
						queue[count] = u8(secondary)
						count += 1
					}
				} else if walk.physical != 0 {
					bases, base_count := iommu.header_memory_bases(header)
					for base in bases[:base_count] {
						if base == walk.physical {
							walk.found = true
							walk.requester = identifier
							walk.behind_conventional_bridge = conventional[bus]
							return
						}
					}
				}
				if function == 0 && !iommu.header_is_multi_function(header) {
					break
				}
			}
		}
	}
}

// unit_of gives the unit that translates the accesses of a requester.
@(private = "file")
unit_of :: proc "contextless" (requester: u16) -> (unit: u32, covered: bool) {
	return iommu.unit_of(&iommu_dmar, &iommu_scopes, requester)
}

// context_table_make makes the context table of the bus of a requester on
// its unit, at the start: memory of the kernel, as the root table, which
// lives as long as the machine. false: no frame.
@(private = "file")
context_table_make :: proc "contextless" (requester: u16) -> bool {
	unit_index, covered := unit_of(requester)
	if !covered {
		// The line at the start, also for a function whose registers no
		// service ever gets: the firmware can have started its DMA.
		log("kernel: IOMMU: the device at bus ", u64(iommu.requester_bus(requester)), ", device ", u64(iommu.requester_device(requester)), ", function ", u64(iommu.requester_function(requester)), " is not behind a unit: it reaches all memory, the tables of the units too")
		return true
	}
	unit := &iommu_units[unit_index]
	bus := iommu.requester_bus(requester)
	if unit.context_tables[bus] != 0 {
		return true
	}
	table := frames_allocate(1)
	if table == 0 {
		return false
	}
	write_back(table, PAGE_SIZE)
	unit.context_tables[bus] = table
	entry := direct(unit.root + u64(bus) * iommu.ENTRY_SIZE, [2]u64)
	entry^ = iommu.root_entry(table)
	write_back(physical_of(entry), iommu.ENTRY_SIZE)
	return true
}

// context_entry_write makes the context entry of a requester on a unit
// present, with the tables from top in a domain identifier, or clears it.
// The second word is written first and cleared last: the unit reads an
// entry whose first word is present as whole.
@(private = "file")
context_entry_write :: proc "contextless" (unit_index: u32, requester: u16, present: bool, top: u64 = 0, domain: u16 = 0) {
	unit := &iommu_units[unit_index]
	entry := direct(unit.context_tables[iommu.requester_bus(requester)] + u64(requester & 0xFF) * iommu.ENTRY_SIZE, [2]u64)
	if present {
		words := iommu.context_entry(top, unit.levels, domain)
		intrinsics.volatile_store(&entry[1], words[1])
		intrinsics.volatile_store(&entry[0], words[0])
	} else {
		intrinsics.volatile_store(&entry[0], 0)
		intrinsics.volatile_store(&entry[1], 0)
	}
	write_back(physical_of(entry), iommu.ENTRY_SIZE)
}

// standing_of gives the standing domain of a requester, or nil.
@(private = "file")
standing_of :: proc "contextless" (requester: u16) -> (standing: ^Iommu_Standing, domain: u16) {
	for &item, index in iommu_standing {
		if item.used && item.requester == requester {
			return &item, u16(IOMMU_STANDING_DOMAIN_FIRST + index)
		}
	}
	return nil, 0
}

// reserved_ranges_map maps each reserved range of a requester at its own
// address, readable and writable, in the tables of a domain: the firmware
// keeps using it through the device. A budget pays the tables; with no
// budget, at the start, the kernel does. The caller holds the frame lock.
// false: no page for a table.
@(private = "file")
reserved_ranges_map :: proc "contextless" (requester: u16, top: u64, levels: u32, budget: ^u32) -> bool {
	for index in 0 ..< int(iommu_dmar.scope_count) {
		scope := &iommu_dmar.scopes[index]
		resolved := &iommu_scopes[index]
		if !scope.reserved || scope.bridge || !resolved.found || resolved.requester != requester || !iommu_reserved_mapped[scope.owner] {
			continue
		}
		reserved := iommu_dmar.reserved_ranges[scope.owner]
		if !pages_change(top, levels, reserved.start, (reserved.end - reserved.start) / PAGE_SIZE, .Map, nil, true, budget) {
			return false
		}
	}
	return true
}

// standing_domains_make gives each device that a reserved range names its
// standing domain, at the start, before translation is on. It writes one
// line for each range or scope that it does not map. false: more devices
// than IOMMU_STANDING_CAPACITY, or no memory for a table.
@(private = "file")
standing_domains_make :: proc "contextless" () -> bool {
	for index in 0 ..< int(iommu_dmar.reserved_range_count) {
		reserved := iommu_dmar.reserved_ranges[index]
		pages := (reserved.end - reserved.start) / PAGE_SIZE
		// A range of free or loaded memory would give a device a frame of a
		// program; a range at or above the windows would meet the window of
		// an object.
		if reserved.end > iommu.WINDOW_BASE || pages > iommu.RESERVED_RANGE_PAGE_LIMIT || !device_range(reserved.start, pages) {
			log("kernel: IOMMU: the reserved memory range ", Hex(reserved.start), " to ", Hex(reserved.end), " is not mapped: it meets memory that the firmware gave as free or loaded, ends past 256 GiB, or is larger than 1 GiB; its devices fault there")
			continue
		}
		iommu_reserved_mapped[index] = true
	}
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	for index in 0 ..< int(iommu_dmar.scope_count) {
		scope := &iommu_dmar.scopes[index]
		if !scope.reserved || !iommu_reserved_mapped[scope.owner] {
			continue
		}
		resolved := &iommu_scopes[index]
		if scope.bridge || !resolved.found {
			log("kernel: IOMMU: a device scope of a reserved memory range is a bridge, or names no device on the bus: the range is not mapped for it")
			continue
		}
		unit_index, covered := unit_of(resolved.requester)
		if !covered {
			continue // Its accesses pass every unit: the firmware keeps its range with no table.
		}
		if iommu_units[unit_index].context_tables[iommu.requester_bus(resolved.requester)] == 0 {
			// A bus that the walk from bus 0 did not reach: another root bus,
			// or a bus behind a conventional bridge. The device faults on its
			// range, as on every access.
			log("kernel: IOMMU: the device at bus ", u64(iommu.requester_bus(resolved.requester)), ", device ", u64(iommu.requester_device(resolved.requester)), ", function ", u64(iommu.requester_function(resolved.requester)), " of a reserved memory range is on a bus with no context table: the range is not mapped for it, and its accesses are refused")
			continue
		}
		if existing, _ := standing_of(resolved.requester); existing != nil {
			continue // The first scope of the device mapped each of its ranges.
		}
		place := -1
		for &item, slot in iommu_standing {
			if !item.used {
				place = slot
				break
			}
		}
		if place < 0 {
			log("kernel: no IOMMU in use: more than 8 devices need a reserved memory range; each device reaches all memory")
			return false
		}
		standing := &iommu_standing[place]
		levels := iommu_units[unit_index].levels
		standing^ = {used = true, requester = resolved.requester, unit = unit_index, top = table_take(nil)}
		if standing.top == 0 || !reserved_ranges_map(resolved.requester, standing.top, levels, nil) {
			log("kernel: no IOMMU in use: no memory for the tables of a reserved memory range; each device reaches all memory")
			return false
		}
		context_entry_write(unit_index, resolved.requester, true, standing.top, u16(IOMMU_STANDING_DOMAIN_FIRST + place))
	}
	return true
}

// iommu_start finds the remapping units in the ACPI tables and turns
// translation on, with no device in a domain but those of the reserved
// ranges: from then on, a device with no declared page reaches no memory.
// The first processor runs it once, before the root service starts and
// after processors_start, which receives the size of the direct map and the
// frequency of the cycle counter. Each unit is checked before any is
// turned on. A machine with no unit, or with a form that the kernel does not
// program, runs as before, with one line. The tables of the start are
// memory of the kernel; when a unit fails to start they stay, a few pages.
iommu_start :: proc "contextless" (boot: ^info.Boot_Info) {
	table, size := acpi_table(boot.acpi_root, "DMAR")
	if table == nil {
		log("kernel: no IOMMU: the firmware lists no DMA remapping table; each device reaches all memory")
		return
	}
	problem: iommu.Dmar_Problem
	iommu_dmar, problem = iommu.dmar_read(table[:size])
	dmar := &iommu_dmar
	log("kernel: IOMMU: a DMA remapping table, ", u64(dmar.host_address_width), " bits of address, ", u64(dmar.unit_count), " units, ", u64(dmar.reserved_range_count), " reserved memory ranges, ", u64(dmar.scope_count), " device scopes")
	if problem != .None {
		log("kernel: no IOMMU in use: ", iommu.DMAR_PROBLEM_TEXTS[problem], "; each device reaches all memory")
		return
	}
	configuration_table, configuration_table_size := acpi_table(boot.acpi_root, "MCFG")
	configuration: iommu.Configuration_Memory
	found := false
	if configuration_table != nil {
		configuration, found = iommu.mcfg_read(configuration_table[:configuration_table_size])
	}
	// The configuration memory of the buses (1 MiB each) and the registers
	// of each unit (64 KiB) must be device ranges in the direct map, never
	// memory that the firmware gave as free or as loaded: the kernel writes
	// the registers, and a table that lies must not make it write a frame.
	// The buses past the direct map are not read: a device there gets no
	// domain.
	bus_count: u64
	if found && configuration.base != 0 && configuration.base < direct_map_size {
		bus_count = min(u64(configuration.last_bus) + 1, (direct_map_size - configuration.base) / iommu.CONFIGURATION_BUS_SIZE)
	}
	if bus_count == 0 || !device_range(configuration.base, bus_count * iommu.CONFIGURATION_BUS_SIZE / PAGE_SIZE) {
		log("kernel: no IOMMU in use: the configuration memory of the buses is not a device range of the direct map; each device reaches all memory")
		return
	}
	register_pages :: iommu.REGISTER_SPACE / PAGE_SIZE
	for index in 0 ..< dmar.unit_count {
		unit := &iommu_units[index]
		base := dmar.units[index].register_base
		if base == 0 || base > direct_map_size - iommu.REGISTER_SPACE || !device_range(base, register_pages) {
			log("kernel: no IOMMU in use: the registers of a unit are not a device range of the direct map; each device reaches all memory")
			return
		}
		unit.register_base = base
		unit.registers = info.DIRECT_MAP_BASE + uintptr(base)
		// A mode that the firmware left on: the kernel would take over a
		// unit that it does not know.
		if status_problem := iommu.global_status_problem(register_read_32(unit, iommu.REGISTER_GLOBAL_STATUS)); status_problem != .None {
			log("kernel: no IOMMU in use: ", iommu.GLOBAL_STATUS_PROBLEM_TEXTS[status_problem], "; each device reaches all memory")
			return
		}
		unit.capability = register_read_64(unit, iommu.REGISTER_CAPABILITY)
		unit.extended = register_read_64(unit, iommu.REGISTER_EXTENDED_CAPABILITY)
		unit.levels = iommu.capability_levels(unit.capability)
		unit.fault_offset, unit.fault_count = iommu.capability_fault_records(unit.capability)
		// The domain identifiers of the slots and of the standing domains,
		// from 1: the identifier 0 stays unused, as the caching mode needs.
		if unit.levels == 0 || unit.fault_offset + unit.fault_count * 16 > iommu.REGISTER_SPACE || iommu.extended_iotlb_offset(unit.extended) + 16 > iommu.REGISTER_SPACE || iommu.capability_domain_count(unit.capability) <= IOMMU_DEVICE_CAPACITY + IOMMU_STANDING_CAPACITY {
			log("kernel: no IOMMU in use: a unit has no table form of 39 or 48 bits, too few domains, or a register outside its space; each device reaches all memory")
			return
		}
		if !iommu.capability_drains(unit.capability) {
			log("kernel: no IOMMU in use: a unit does not drain the reads and the writes in flight at an invalidation; each device reaches all memory")
			return
		}
		// A unit blocks each request above its width, whatever its tables
		// map: with fewer bits than the windows need, its devices get
		// contiguous objects only, below the width.
		width := iommu.capability_address_width(unit.capability)
		unit.address_end = u64(1) << min(width, 63)
		unit.windows = width >= iommu.WINDOW_ADDRESS_WIDTH
		if !unit.windows {
			log("kernel: IOMMU: a unit translates ", u64(width), " bits of address, fewer than the ", u64(iommu.WINDOW_ADDRESS_WIDTH), " of the device windows: its devices get contiguous objects only")
		}
	}
	// The fault event is a message in the compatible form, which names an
	// interrupt controller by 8 bits.
	if processors[0].apic_id > 255 {
		log("kernel: no IOMMU in use: the fault event cannot name the first processor; each device reaches all memory")
		return
	}
	iommu_unit_count = dmar.unit_count
	iommu_coherent = true
	for &unit in iommu_units[:iommu_unit_count] {
		iommu_coherent &&= iommu.extended_coherent(unit.extended)
	}
	iommu_configuration = configuration.base
	iommu_configuration_size = bus_count * iommu.CONFIGURATION_BUS_SIZE
	iommu_last_bus = u32(bus_count - 1)
	for index in 0 ..< int(dmar.scope_count) {
		iommu_scopes[index] = iommu.scope_resolve(dmar.scopes[index], bridge_read)
	}
	// The root tables, the context tables of the buses and the standing
	// domains are memory of the kernel, as the page table of the kernel: no
	// budget pays for them.
	for &unit in iommu_units[:iommu_unit_count] {
		unit.root = frames_allocate(1)
		if unit.root == 0 {
			log("kernel: no IOMMU in use: no memory for its root tables")
			return
		}
		write_back(unit.root, PAGE_SIZE)
	}
	walk := Bus_Walk{make_tables = true}
	buses_walk(&walk)
	if walk.no_memory {
		log("kernel: no IOMMU in use: no memory for its context tables")
		return
	}
	if !standing_domains_make() {
		return
	}
	for index in 0 ..< iommu_unit_count {
		unit := &iommu_units[index]
		// Each record of a fault before the start is free again, and the
		// next fault sends the fault event to the first processor.
		for record in 0 ..< unit.fault_count {
			register_write_32(unit, unit.fault_offset + record * 16 + 12, iommu.FAULT_CLEAR)
		}
		register_write_32(unit, iommu.REGISTER_FAULT_STATUS, iommu.FAULT_STATUS_OVERFLOW)
		register_write_32(unit, iommu.REGISTER_FAULT_EVENT_DATA, VECTOR_IOMMU_FAULT)
		register_write_32(unit, iommu.REGISTER_FAULT_EVENT_ADDRESS, 0xFEE0_0000 | (processors[0].apic_id & 0xFF) << 12)
		register_write_32(unit, iommu.REGISTER_FAULT_EVENT_UPPER_ADDRESS, 0)
		register_write_32(unit, iommu.REGISTER_FAULT_EVENT_CONTROL, 0)
		register_write_64(unit, iommu.REGISTER_ROOT_TABLE, unit.root)
		started := global_set(unit, iommu.GLOBAL_ROOT_TABLE)
		if started {
			invalidate_unit(unit, iommu.CONTEXT_COMMAND_GLOBAL, iommu.IOTLB_COMMAND_GLOBAL)
			started = global_set(unit, iommu.GLOBAL_TRANSLATION)
		}
		if !started {
			// A machine with a part of its units on would let a device of
			// a unit that is off write the tables of the others.
			for &before in iommu_units[:index + 1] {
				translation_off(&before)
			}
			log("kernel: no IOMMU in use: a unit did not take its root table or did not turn translation on; each device reaches all memory")
			return
		}
	}
	standing_count: u64
	for item in iommu_standing {
		standing_count += item.used ? 1 : 0
	}
	iommu_in_use = true
	log("kernel: IOMMU: translation on, ", u64(iommu_unit_count), " units, ", u64(walk.bus_count), " buses, ", standing_count, " devices with a reserved memory range: a device reaches only the memory that its service declared")
}

// iommu_owns_range says if a range of physical addresses meets the
// registers of a unit, the configuration memory of the buses, or a
// reserved memory range: the kernel owns the first two while the IOMMU is
// in use, so Device_Create gives neither to a program, which could turn
// translation off; the third is memory that a device of the firmware
// writes.
iommu_owns_range :: proc "contextless" (start: u64, page_count: u64) -> bool {
	if !iommu_in_use {
		return false
	}
	end := start + page_count * PAGE_SIZE // device_range checked that it does not wrap.
	meets :: proc "contextless" (start, end, first, size: u64) -> bool {
		return start < first + size && first < end
	}
	for &unit in iommu_units[:iommu_unit_count] {
		if meets(start, end, unit.register_base, iommu.REGISTER_SPACE) {
			return true
		}
	}
	for reserved in iommu_dmar.reserved_ranges[:iommu_dmar.reserved_range_count] {
		if meets(start, end, reserved.start, reserved.end - reserved.start) {
			return true
		}
	}
	return meets(start, end, iommu_configuration, iommu_configuration_size)
}

// iommu_requester_of gives 1 + the requester of the function whose memory
// base address register starts at this physical address: the device of a
// memory object that Device_Create makes over its registers. 0: none, no
// IOMMU in use, or a device that gets no domain, with one line that says
// why. It walks the buses through bridges, and writes nothing: the root
// service owns the bus.
iommu_requester_of :: proc "contextless" (physical: u64) -> u32 {
	if !iommu_in_use {
		return 0
	}
	walk := Bus_Walk{physical = physical}
	buses_walk(&walk)
	if !walk.found {
		return 0
	}
	requester := walk.requester
	bus, device, function := u64(iommu.requester_bus(requester)), u64(iommu.requester_device(requester)), u64(iommu.requester_function(requester))
	// Every device behind a conventional bridge gives the requester of the
	// bridge: one domain of it would let each of them reach what the service
	// of another declared.
	if walk.behind_conventional_bridge {
		log("kernel: IOMMU: the device at bus ", bus, ", device ", device, ", function ", function, " is behind a conventional bridge, whose requester each device behind it shares: it gets no domain, and each of its accesses is refused")
		return 0
	}
	unit, covered := unit_of(requester)
	// A function that no unit covers gives its accesses past the units: a
	// domain would isolate nothing. Such a device can write every page, the
	// tables of the units too, so it ends the isolation of each device: the
	// log says so.
	if !covered {
		log("kernel: IOMMU: the device at bus ", bus, ", device ", device, ", function ", function, " is not behind a unit: it reaches all memory, the tables of the units too, and no device is isolated from it")
		return 0
	}
	if iommu_units[unit].context_tables[bus] == 0 {
		log("kernel: IOMMU: the device at bus ", bus, ", device ", device, ", function ", function, " is on a bus that the kernel did not find at its start: it gets no domain, and each of its accesses is refused")
		return 0
	}
	return 1 + u32(requester)
}

// iommu_device_facts gives what Device_Create of registers says of their
// device (1 + its requester, as iommu_requester_of gave it): whether it has
// a domain, and whether its unit gives device windows. The root service
// chooses the memory of the device with it.
iommu_device_facts :: proc "contextless" (requester: u32) -> (facts: op.Device_Memory_Facts) {
	if !iommu_in_use || requester == 0 {
		return {}
	}
	facts += {.Domain}
	if unit, _ := unit_of(u16(requester - 1)); iommu_units[unit].windows {
		facts += {.Windows}
	}
	return facts
}

// owned_devices gives a bit for each device slot whose domain this
// program owns. The caller holds the frame lock, or the program lock of
// this program: only its own declarations, under that lock, make it an
// owner.
@(private = "file")
owned_devices :: proc "contextless" (program_index: u32) -> (owned: u32) {
	serial := programs[program_index].serial
	for &device, slot in iommu_devices {
		if intrinsics.atomic_load(&device.owner) == program_index && device.owner_serial == serial {
			owned |= 1 << u32(slot)
		}
	}
	return owned
}

// owned_of gives the slots that a program owns for one requester (1 + the
// identifier, as a memory object keeps it). The caller holds the frame
// lock.
@(private = "file")
owned_of :: proc "contextless" (program_index: u32, requester: u32) -> (owned: u32) {
	all := owned_devices(program_index)
	for slot in u32(0) ..< IOMMU_DEVICE_CAPACITY {
		if all & (1 << slot) != 0 && u32(iommu_devices[slot].requester) + 1 == requester {
			owned |= 1 << slot
		}
	}
	return owned
}

// device_slot gives the slot of the domain of a requester for a program:
// the slot that the program owns, or a free slot, which the program owns
// only after its first declaration. Bad_State: another program owns it.
// The caller holds the frame lock.
@(private = "file")
device_slot :: proc "contextless" (requester: u16, program_index: u32) -> (slot: u32, status: op.Status) {
	free := u32(IOMMU_DEVICE_CAPACITY)
	for &device, index in iommu_devices {
		if device.owner == 0 {
			if free == IOMMU_DEVICE_CAPACITY {
				free = u32(index)
			}
			continue
		}
		if device.requester == requester {
			if device.owner != program_index || device.owner_serial != programs[program_index].serial {
				return 0, .Bad_State
			}
			return u32(index), .Ok
		}
	}
	if free == IOMMU_DEVICE_CAPACITY {
		return 0, .No_Slot
	}
	return free, .Ok
}

// table_take takes a zero page for a table of a domain, paid by a budget;
// with no budget, at the start only, memory of the kernel. 0: no page. The
// caller holds the frame lock.
@(private = "file")
table_take :: proc "contextless" (budget: ^u32) -> u64 {
	table := budget != nil ? frame_paid_held(budget) : frames_take(1)
	if table != 0 {
		frames_zero(table, 1)
		write_back(table, PAGE_SIZE)
	}
	return table
}

// leaf_table gives the table of the last level for a device address in
// the tables of a domain. With create_missing, it makes each missing table
// on the way (table_take); without, it makes none. nil: a table is missing,
// or no page. The caller holds the frame lock.
@(private = "file")
leaf_table :: proc "contextless" (top: u64, levels: u32, address: u64, create_missing: bool, budget: ^u32) -> ^[512]u64 {
	table := top
	for level := levels; level > 1; level -= 1 {
		entry := &direct(table, [512]u64)[iommu.level_index(address, level)]
		if !iommu.entry_present(entry^) {
			if !create_missing {
				return nil
			}
			child := table_take(budget)
			if child == 0 {
				return nil
			}
			entry^ = iommu.table_entry(child)
			write_back(physical_of(entry), 8)
		}
		table = entry^ & iommu.ENTRY_ADDRESS
	}
	return direct(table, [512]u64)
}

Page_Change :: enum {
	Map, // Map each page, writable or not.
	Clear, // Clear each entry.
	Allow_Write, // Add the write bit to each present entry.
	Deny_Write, // Take the write bit out of each present entry.
}

// pages_change changes the entries of count pages from the device address
// first in the tables of a domain, one table of the last level at a time:
// one walk of the upper levels for each 2 MiB, not for each page. Map
// gives the page n the frame n of a memory object, or with no object the
// frame at its own address (a reserved range), and makes the missing
// tables (table_take); false: no page for a table. The tables stay until
// the domain ends. The caller holds the frame lock, and invalidates after
// a Clear, an Allow_Write or a Deny_Write.
@(private = "file")
pages_change :: proc "contextless" (top: u64, levels: u32, first: u64, count: u64, change: Page_Change, frames: ^Region = nil, writable: bool = false, budget: ^u32 = nil) -> bool {
	page := u64(0)
	for page < count {
		address := first + page * PAGE_SIZE
		index := iommu.level_index(address, 1)
		run := min(512 - index, count - page)
		leaf := leaf_table(top, levels, address, change == .Map, budget)
		if leaf == nil {
			if change == .Map {
				return false
			}
			page += run // No table: no entry to change.
			continue
		}
		for offset in 0 ..< run {
			entry := &leaf[index + offset]
			switch change {
			case .Map:
				// Each page of the object has its frame: the declaration gave
				// it before the frame lock.
				frame := frames != nil ? region_frame(frames, page + offset, false) : address + offset * PAGE_SIZE
				entry^ = iommu.page_entry(frame, writable)
			case .Clear:
				entry^ = 0
			case .Allow_Write:
				if iommu.entry_present(entry^) {
					entry^ |= iommu.ENTRY_WRITE
				}
			case .Deny_Write:
				entry^ &~= iommu.ENTRY_WRITE // An entry that is not present stays 0.
			}
		}
		write_back(physical_of(&leaf[index]), run * 8)
		page += run
	}
	return true
}

// tables_free frees the tables of a domain from one table and its level,
// and gives their count.
@(private = "file")
tables_free :: proc "contextless" (table: u64, level: u32) -> (count: u64) {
	if level > 1 {
		for entry in direct(table, [512]u64) {
			if iommu.entry_present(entry) {
				count += tables_free(entry & iommu.ENTRY_ADDRESS, level - 1)
			}
		}
	}
	frames_free_held(table, 1)
	return count + 1
}

// device_address gives the device address of the first page of a memory
// object: its physical address when it is contiguous, else its window.
@(private = "file")
device_address :: proc "contextless" (region_index: u32) -> u64 {
	region := &regions[region_index]
	return region.contiguous ? region.physical : iommu.window_address(region_index)
}

// object_pages_change changes the entries of the pages of a memory object
// in the domain of a device slot. The caller holds the frame lock.
@(private = "file")
object_pages_change :: proc "contextless" (slot: u32, region_index: u32, change: Page_Change, writable: bool = false, budget: ^u32 = nil) -> bool {
	device := &iommu_devices[slot]
	region := &regions[region_index]
	return pages_change(device.top, iommu_units[device.unit].levels, device_address(region_index), region.page_count, change, region, writable, budget)
}

// What declare_to_device changed in one domain.
Declaration_Change :: enum {
	None, // The domain already had the object with this write: nothing to invalidate.
	Mapped, // The object is new in the domain: an invalidation only for a unit with the caching mode or a write buffer.
	Write_Allowed, // The pages became writable: an invalidation, and an undo takes the write back.
	Write_Denied, // The pages became read-only: an invalidation.
	Undone, // A failed map was cleared from a domain that had entries before: an invalidation.
}

// declare_to_device declares one memory object to one device slot.
// writable: the handle of the call has Write; write_held: the program
// still holds a handle to the object with Write after this call, so a
// device keeps the write only while it holds one. made: the context entry
// of the domain became present. The caller holds the frame lock, and
// invalidates after it by what changed.
@(private = "file")
declare_to_device :: proc "contextless" (program_index: u32, requester: u16, slot: u32, region_index: u32, writable: bool, write_held: bool) -> (change: Declaration_Change, made: bool, status: op.Status) {
	device := &iommu_devices[slot]
	region := &regions[region_index]
	bit := u32(1) << slot
	if region.declared & bit != 0 {
		switch {
		case writable && region.declared_writable & bit == 0:
			object_pages_change(slot, region_index, .Allow_Write)
			region.declared_writable |= bit
			return .Write_Allowed, false, .Ok
		case !write_held && region.declared_writable & bit != 0:
			object_pages_change(slot, region_index, .Deny_Write)
			region.declared_writable &~= bit
			return .Write_Denied, false, .Ok
		}
		return .None, false, .Ok
	}
	budget := &programs[program_index].budget
	new_domain := device.owner == 0
	if new_domain {
		// Device_Create gave the requester only for a device that a unit
		// covers, on a bus with a context table.
		unit, covered := unit_of(requester)
		if !covered || iommu_units[unit].context_tables[iommu.requester_bus(requester)] == 0 {
			return .None, false, .Bad_State
		}
		device^ = {requester = requester, unit = unit}
		device.top = table_take(budget)
		if device.top == 0 {
			device^ = {}
			return .None, false, .No_Budget
		}
		// The firmware keeps using the reserved ranges of the device while
		// the service drives it.
		if !reserved_ranges_map(requester, device.top, iommu_units[unit].levels, budget) {
			budgets[budget^].amounts.pages += tables_free(device.top, iommu_units[unit].levels)
			device^ = {}
			return .None, false, .No_Budget
		}
	}
	if !object_pages_change(slot, region_index, .Map, writable, budget) {
		if new_domain {
			// No unit reads a domain with no context entry: its tables
			// return at once, and nothing was visible to the device.
			budgets[budget^].amounts.pages += tables_free(device.top, iommu_units[device.unit].levels)
			device^ = {}
			return .None, false, .No_Budget
		}
		object_pages_change(slot, region_index, .Clear)
		return .Undone, false, .No_Budget
	}
	region.declared |= bit
	if writable {
		region.declared_writable |= bit
	}
	if new_domain {
		device.owner_serial = programs[program_index].serial
		intrinsics.atomic_store(&device.owner, program_index)
		// A device of a reserved range moves from its standing domain: the
		// entry is cleared and the standing domain forgotten first, so the
		// unit never reads an entry with half of each.
		if standing, standing_domain := standing_of(requester); standing != nil {
			context_entry_write(device.unit, requester, false)
			invalidate_unit(&iommu_units[device.unit], iommu.context_command_domain(standing_domain), iommu.iotlb_command_domain(standing_domain))
		}
		context_entry_write(device.unit, requester, true, device.top, u16(slot + 1))
		device.present = true
		return .Mapped, true, .Ok
	}
	return .Mapped, false, .Ok
}

// write_deny_for takes the write out of the pages of a memory object in
// the domains of the device slots of a mask. It gives the slots whose
// domain changed. The caller holds the frame lock, and invalidates them
// after it.
@(private = "file")
write_deny_for :: proc "contextless" (region_index: u32, mask: u32) -> u32 {
	region := &regions[region_index]
	denied := region.declared_writable & mask
	for slot in u32(0) ..< IOMMU_DEVICE_CAPACITY {
		if denied & (1 << slot) != 0 {
			object_pages_change(slot, region_index, .Deny_Write)
		}
	}
	region.declared_writable &~= denied
	return denied
}

// holds_with gives whether the program holds another handle to a memory
// object than except (nil: any), and whether one of those has Write. The
// caller holds the program lock.
@(private = "file")
holds_with :: proc "contextless" (program: ^Program, region_index: u32, except: ^Handle_Slot) -> (holds: bool, writes: bool) {
	for &other in program.handles {
		if &other != except && other.kind == .Memory && other.object == region_index {
			holds = true
			writes ||= .Write in other.rights
		}
	}
	return holds, writes
}

// registers_held says if a program holds a handle or a mapping of the
// registers of a device (1 + its requester), other than the handle and the
// mapping that end. A mapping of the registers drives the device as a
// handle does, so it keeps the domain. The caller holds the program lock.
@(private = "file")
registers_held :: proc "contextless" (program: ^Program, requester: u32, closed: ^Handle_Slot, unmapped: ^Mapping) -> bool {
	for &other in program.handles {
		if &other != closed && other.kind == .Memory && regions[other.object].requester == requester {
			return true
		}
	}
	for &mapping in program.mappings {
		if &mapping != unmapped && mapping.page_count != 0 && regions[mapping.region].requester == requester {
			return true
		}
	}
	return false
}

// region_end_for takes the pages of a memory object out of the domains of
// the device slots of a mask. It gives the slots whose domain changed. The
// caller holds the frame lock, and invalidates them after it.
@(private = "file")
region_end_for :: proc "contextless" (region_index: u32, mask: u32) -> u32 {
	region := &regions[region_index]
	ended := region.declared & mask
	for slot in u32(0) ..< IOMMU_DEVICE_CAPACITY {
		if ended & (1 << slot) != 0 {
			object_pages_change(slot, region_index, .Clear)
		}
	}
	region.declared &~= ended
	region.declared_writable &~= ended
	return ended
}

// iommu_declare maps each page of a memory object in the domain of each
// device whose registers the program holds by a handle, and gives the
// device address of the object: Memory_Physical. A contiguous object has
// its physical address; another one has its window, where its pages follow
// each other, and each of its pages gets its frame now. The device writes
// the pages only when writable: the handle of the call has the right
// Write. A program that holds no such handle declares nothing, and gets the
// physical address of a contiguous object only. Device memory is not
// declared: a device reaches no registers of a device. Either every device
// of the call gets the object, or none that did not have it before, and
// none gets a write that it did not have. A device keeps the write only
// while the program holds a handle with Write. The invalidation runs only
// when a domain changed, for that domain. The caller holds the program
// lock.
iommu_declare :: proc "contextless" (program_index: u32, region_index: u32, writable: bool) -> (address: u64, status: op.Status) {
	region := &regions[region_index]
	if !iommu_in_use || region.device {
		if !region.contiguous {
			return 0, .Bad_Operation // Its frames come at first use, from anywhere: no one address names them.
		}
		return region.physical, .Ok
	}
	program := &programs[program_index]
	requesters: [IOMMU_DEVICES_OF_A_SERVICE]u32
	count := 0
	for slot in program.handles {
		if slot.kind != .Memory {
			continue
		}
		requester := regions[slot.object].requester
		if requester == 0 {
			continue
		}
		seen := false
		for known in requesters[:count] {
			seen ||= known == requester
		}
		if seen {
			continue
		}
		if count == len(requesters) {
			return 0, .No_Slot
		}
		requesters[count] = requester
		count += 1
	}
	if count == 0 {
		if !region.contiguous {
			return 0, .Bad_Operation // No device of the caller has a window for it.
		}
		return region.physical, .Ok
	}
	// Each unit of the call translates the whole object: the identity pages
	// end below the windows and below the width of the unit, and a window
	// needs a unit that translates its addresses.
	for requester in requesters[:count] {
		unit, _ := unit_of(u16(requester - 1))
		beyond := region.contiguous ? (region.physical + region.page_count * PAGE_SIZE > iommu_units[unit].address_end) : !iommu_units[unit].windows
		if beyond {
			return 0, .Bad_Operation
		}
	}
	if region.contiguous {
		if region.physical + region.page_count * PAGE_SIZE > iommu.WINDOW_BASE {
			return 0, .Bad_Operation
		}
	} else {
		// A decommit would take a frame from under the device; an object
		// larger than its window would reach the window of the next slot.
		if region.uncommitted || region.page_count > iommu.WINDOW_PAGES {
			return 0, .Bad_Operation
		}
		// Each page gets its frame before the frame lock: the region lock
		// comes first in the lock order. The frames do not move until the
		// object ends, and region_release takes the pages out of each
		// domain first.
		for page in 0 ..< region.page_count {
			region_frame(region, page, true)
		}
	}
	_, write_held := holds_with(program, region_index, nil)
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	added, write_allowed, changed, made: u32
	status = .Ok
	for requester in requesters[:count] {
		slot: u32
		slot, status = device_slot(u16(requester - 1), program_index)
		if status != .Ok {
			break
		}
		change: Declaration_Change
		entry_made: bool
		change, entry_made, status = declare_to_device(program_index, u16(requester - 1), slot, region_index, writable, write_held)
		if entry_made {
			made |= 1 << slot
		}
		unit := &iommu_units[iommu_devices[slot].unit]
		switch change {
		case .None:
		case .Mapped:
			added |= 1 << slot
			// A unit with the caching mode can keep an entry that was not
			// present; another unit keeps only present entries. A unit that
			// asks for a flush of its write buffer needs it after an entry
			// becomes present, and the invalidation makes that flush first.
			if iommu.capability_caching_mode(unit.capability) || iommu.capability_write_buffer(unit.capability) {
				changed |= 1 << slot
			}
		case .Write_Allowed:
			write_allowed |= 1 << slot
			changed |= 1 << slot
		case .Write_Denied, .Undone:
			changed |= 1 << slot
		}
		if status != .Ok {
			break
		}
	}
	if status != .Ok {
		// The device could use a new entry before the undo: the undo
		// invalidates.
		changed |= region_end_for(region_index, added)
		changed |= write_deny_for(region_index, write_allowed)
	}
	// A new context entry on a unit with the caching mode is forgotten
	// under the identifier 0 too.
	invalidate_slots(changed, made)
	if status != .Ok {
		return 0, status
	}
	return device_address(region_index), .Ok
}

// iommu_region_end_held takes the pages of a memory object out of each
// domain that has them, before its frames return: region_release calls it
// under the frame lock. After it, no device reaches the pages.
iommu_region_end_held :: proc "contextless" (region_index: u32) {
	if iommu_in_use {
		invalidate_slots(region_end_for(region_index, max(u32)), 0)
	}
}

// iommu_handle_closed follows a close or a revocation of a memory handle
// of a service, so that the device of a service reaches only what the
// service holds, and writes only what it can write:
//
// - the last handle of the program to a declared object: the object leaves
//   each domain of the program;
// - the last handle with Write: the pages of the object become read-only in
//   each domain of the program;
// - the last handle to the registers of a device, with no mapping of them
//   left: the domain of that device ends, so a device given to another
//   service reaches nothing of this one.
//
// Each change is invalidated before the close returns. handle_close calls
// it with the program lock of the program, before the release of the
// object. A handle of an object that is not declared and is no registers
// costs two loads.
iommu_handle_closed :: proc "contextless" (program: ^Program, closed: ^Handle_Slot) {
	if !iommu_in_use {
		return
	}
	region := &regions[closed.object]
	requester := region.requester
	if intrinsics.atomic_load(&region.declared) == 0 && requester == 0 {
		return
	}
	holds, writes := holds_with(program, closed.object, closed)
	held := requester == 0 || registers_held(program, requester, closed, nil)
	program_index := index_of_program(program)
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	owned := owned_devices(program_index)
	changed: u32
	switch {
	case !holds:
		changed = region_end_for(closed.object, owned)
	case !writes:
		changed = write_deny_for(closed.object, owned)
	}
	if !held {
		if ended := owned_of(program_index, requester); ended != 0 {
			// It invalidates each ended domain; the others changed above.
			domains_end(program_index, ended)
			changed &~= ended
		}
	}
	invalidate_slots(changed, 0)
}

// iommu_mapping_ended follows the end of a mapping: the last mapping of the
// registers of a device, when the program holds no handle of them either,
// ends the domain of that device. unmap calls it with the program lock,
// before the release of the object. A mapping of an object that is no
// registers costs two loads.
iommu_mapping_ended :: proc "contextless" (program: ^Program, mapping: ^Mapping) {
	if !iommu_in_use {
		return
	}
	requester := regions[mapping.region].requester
	if requester == 0 || registers_held(program, requester, nil, mapping) {
		return
	}
	program_index := index_of_program(program)
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	if ended := owned_of(program_index, requester); ended != 0 {
		domains_end(program_index, ended)
	}
}

// iommu_program_end ends each domain that a program owns.
// program_cleanup calls it before the handles and the mappings of the
// program end.
iommu_program_end :: proc "contextless" (program_index: u32) {
	if !iommu_in_use {
		return
	}
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	if owned := owned_devices(program_index); owned != 0 {
		domains_end(program_index, owned)
	}
}

// domains_end ends the domains of the device slots of a mask, which a
// program owns: their context entries, their bits in each memory object,
// the invalidation of each domain, then their tables, whose pages return
// to the budget of the program, and the slots are free. A device of a
// reserved range goes back to its standing domain. The caller holds the
// frame lock.
@(private = "file")
domains_end :: proc "contextless" (program_index: u32, owned: u32) {
	for slot in u32(0) ..< IOMMU_DEVICE_CAPACITY {
		if owned & (1 << slot) != 0 && iommu_devices[slot].present {
			context_entry_write(iommu_devices[slot].unit, iommu_devices[slot].requester, false)
			iommu_devices[slot].present = false
		}
	}
	// One pass over the table of the memory objects, at the end of a
	// domain only: the stop of a service, or the end of its registers.
	for &region in regions {
		region.declared &~= owned
		region.declared_writable &~= owned
	}
	// No unit reads a table of these domains after this.
	for slot in u32(0) ..< IOMMU_DEVICE_CAPACITY {
		if owned & (1 << slot) != 0 {
			invalidate_slot(slot, .Cleared)
		}
	}
	budget := programs[program_index].budget
	for slot in u32(0) ..< IOMMU_DEVICE_CAPACITY {
		if owned & (1 << slot) == 0 {
			continue
		}
		device := &iommu_devices[slot]
		unit := &iommu_units[device.unit]
		if standing, standing_domain := standing_of(device.requester); standing != nil {
			context_entry_write(device.unit, device.requester, true, standing.top, standing_domain)
			if iommu.capability_caching_mode(unit.capability) || iommu.capability_write_buffer(unit.capability) {
				invalidate_unit(unit, iommu.context_command_domain(0), iommu.iotlb_command_domain(standing_domain))
			}
		}
		budgets[budget].amounts.pages += tables_free(device.top, unit.levels)
		intrinsics.atomic_store(&device.owner, 0)
		device^ = {}
	}
}

// fault_count_of gives the place of the count of the faults of a requester.
@(private = "file")
fault_count_of :: proc "contextless" (requester: u16) -> ^u64 {
	return iommu.requester_bus(requester) == 0 ? &iommu_faults[requester & 0xFF] : &iommu_faults_of_other_buses
}

// iommu_faults_take reads each fault that the units recorded, frees its
// record, counts it for its device, and writes the lines of the log that
// iommu.fault_line gives: a device that faults in a loop does not flood
// the log. It runs at the fault event, and at a tick of the first
// processor while records were left (iommu_faults_left), with no lock
// held: a DMA fault stops nothing. While a record holds a fault a unit
// sends no new fault event, so the handler reads the status of each unit
// again after each pass, and passes again while a record is pending, at
// most IOMMU_FAULT_PASSES times: with interrupts off, one call reads at
// most that many passes over the records of each unit (2 x 256 records for
// the largest unit). A record that is still pending after the last pass
// waits for the next tick, not for an event that would never come. The
// name of the service is read with no lock: in a race with the end of the
// service, the line can name the program of the slot before or after.
iommu_faults_take :: proc "contextless" () {
	if !iommu_in_use {
		return
	}
	left := false
	for index in 0 ..< iommu_unit_count {
		unit := &iommu_units[index]
		pending := true
		for _ in 0 ..< IOMMU_FAULT_PASSES {
			for record in 0 ..< unit.fault_count {
				place := unit.fault_offset + record * 16
				// The word with the bit F first: the words read after it are
				// those of the fault that set it.
				last := register_read_32(unit, place + 12)
				high := u64(register_read_32(unit, place + 8)) | u64(last) << 32
				fault, recorded := iommu.fault_read(register_read_64(unit, place), high)
				if !recorded {
					continue
				}
				register_write_32(unit, place + 12, iommu.FAULT_CLEAR)
				fault_line_write(fault)
			}
			if register_read_32(unit, iommu.REGISTER_FAULT_STATUS) & iommu.FAULT_STATUS_PENDING == 0 {
				pending = false
				break
			}
		}
		register_write_32(unit, iommu.REGISTER_FAULT_STATUS, iommu.FAULT_STATUS_OVERFLOW)
		left ||= pending
	}
	intrinsics.atomic_store(&iommu_faults_left, left)
}

// fault_line_write counts one fault for its device and writes its line of
// the log, when iommu.fault_line gives one.
@(private = "file")
fault_line_write :: proc "contextless" (fault: iommu.Fault) {
	faults := intrinsics.atomic_add(fault_count_of(fault.requester), 1) + 1
	line := iommu.fault_line(faults)
	if line == .None {
		return
	}
	service := "no service"
	for &device in iommu_devices {
		if owner := intrinsics.atomic_load(&device.owner); owner != 0 && device.requester == fault.requester {
			service = program_name(&programs[owner])
		}
	}
	bus, device_number, function := u64(iommu.requester_bus(fault.requester)), u64(iommu.requester_device(fault.requester)), u64(iommu.requester_function(fault.requester))
	if line == .Whole {
		log("kernel: a DMA fault of the device at bus ", bus, ", device ", device_number, ", function ", function, " (service ", service, "): a ", fault.read ? string("read") : string("write"), " of ", Hex(fault.address), "; reason ", Hex(u64(fault.reason)), "; faults of this device: ", faults)
	} else {
		log("kernel: DMA faults of the device at bus ", bus, ", device ", device_number, ", function ", function, " (service ", service, "): ", faults, " in all; the log has the line of each of the first ", u64(iommu.FAULT_LINES), ", then this count at each power of two")
	}
}

// iommu_tick reads the records that the last fault event left, at a tick
// of the first processor. A tick with no record left reads one word.
iommu_tick :: proc "contextless" () {
	if intrinsics.atomic_load(&iommu_faults_left) {
		iommu_faults_take()
	}
}
