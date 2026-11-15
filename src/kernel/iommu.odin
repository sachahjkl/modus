package kernel

import info "modus:contract/boot_info"
import "modus:contract/iommu"
import op "modus:contract/operation"
import "base:intrinsics"

// The IOMMU (src/md/infrastructure/iommu.md): the kernel owns the tables of
// the remapping unit, and a device reaches only the pages that its service
// declared with Memory_Physical, and writes only those that the handle of
// the declaration could write. The kernel holds no code of a device: it
// reads the base address registers of the functions of bus 0 only to know
// which device the registers of a memory object belong to.
//
// The slots of the devices, the bits `declared` and `declared_writable` of
// each memory object and the tables of the domains change under the frame
// lock: a declaration ends in region_release under that lock, before the
// frames of its object return (docs/ARCHITECTURE.md, "K5. Device grant and
// interrupts"). The fault handler reads `owner` and the counts of the
// faults with atomic loads and no lock.

// The devices that have a domain at one time. A slot is free again when
// its service stops.
IOMMU_DEVICE_CAPACITY :: 32
// The devices whose registers one service can hold and declare memory to:
// a declaration from a program that holds the registers of more gives
// No_Slot. A device service holds one.
IOMMU_DEVICES_OF_A_SERVICE :: 4

// The domain of one device: its requester, the program that owns it, and
// its second-level tables. A slot whose owner is 0 is free.
Iommu_Device :: struct {
	requester:    u16,
	present:      bool, // Its context entry is present.
	owner:        u32, // The program slot of the service that owns the domain. 0: a free slot. Atomic.
	owner_serial: u32, // The serial of that program, when it took the domain.
	top:          u64, // The top table of the domain.
}

iommu_in_use: bool // Translation is on. Written once at the start.
iommu_register_base: u64 // The physical address of the registers of the unit.
iommu_registers: uintptr // The same registers, in the direct map.
iommu_capability: u64
iommu_extended: u64
iommu_levels: u32
iommu_coherent: bool
iommu_context_table: u64 // The context table of bus 0.
iommu_configuration: u64 // The physical address of the configuration of bus 0.
iommu_dmar: iommu.Dmar // The table DMAR as read at the start: the functions that the unit covers.
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
register_read_32 :: proc "contextless" (offset: u64) -> u32 {
	return intrinsics.volatile_load((^u32)(iommu_registers + uintptr(offset)))
}

@(private = "file")
register_write_32 :: proc "contextless" (offset: u64, value: u32) {
	intrinsics.volatile_store((^u32)(iommu_registers + uintptr(offset)), value)
}

@(private = "file")
register_read_64 :: proc "contextless" (offset: u64) -> u64 {
	return intrinsics.volatile_load((^u64)(iommu_registers + uintptr(offset)))
}

@(private = "file")
register_write_64 :: proc "contextless" (offset: u64, value: u64) {
	intrinsics.volatile_store((^u64)(iommu_registers + uintptr(offset)), value)
}

// write_back writes the cache lines of a part of a table to memory when
// the unit does not snoop the caches: it reads memory, not the cache.
@(private = "file")
write_back :: proc "contextless" (physical: u64, size: u64) {
	if iommu_coherent {
		return
	}
	for line := physical &~ 63; line < physical + size; line += 64 {
		cache_line_write_back(direct(line, u8))
	}
}

// The wait for a command of the unit: one second of the cycle counter. A
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

// global_set sets one bit of the global command and waits until the
// status shows it. false: the unit did not.
@(private = "file")
global_set :: proc "contextless" (bit: u32) -> bool {
	register_write_32(iommu.REGISTER_GLOBAL_COMMAND, iommu.global_command(register_read_32(iommu.REGISTER_GLOBAL_STATUS), bit))
	bound := wait_bound()
	for register_read_32(iommu.REGISTER_GLOBAL_STATUS) & bit == 0 {
		if !wait_turn(bound) {
			return false
		}
	}
	return true
}

// invalidate makes the unit forget each context entry and each
// translation that it keeps, with the drain of the reads and writes in
// flight, and waits until it did: after it, no device uses an entry that
// the kernel cleared. The flush of the write buffer comes first when the
// unit needs it. A unit that does not end the command, or that ends it
// with no invalidation made (the granularity 0), stops the machine: a page
// that a device can still reach must not become free.
@(private = "file")
invalidate :: proc "contextless" () {
	done := true
	if iommu.capability_write_buffer(iommu_capability) {
		register_write_32(iommu.REGISTER_GLOBAL_COMMAND, iommu.global_command(register_read_32(iommu.REGISTER_GLOBAL_STATUS), iommu.GLOBAL_WRITE_BUFFER))
		bound := wait_bound()
		for done && register_read_32(iommu.REGISTER_GLOBAL_STATUS) & iommu.GLOBAL_WRITE_BUFFER != 0 {
			done = wait_turn(bound)
		}
	}
	if done {
		register_write_64(iommu.REGISTER_CONTEXT_COMMAND, iommu.CONTEXT_INVALIDATE | iommu.CONTEXT_GLOBAL)
		bound := wait_bound()
		for {
			finished, made := iommu.context_invalidation_done(register_read_64(iommu.REGISTER_CONTEXT_COMMAND))
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
		iotlb := iommu.extended_iotlb_offset(iommu_extended) + 8
		register_write_64(iotlb, iommu.IOTLB_INVALIDATE | iommu.IOTLB_GLOBAL | iommu.IOTLB_DRAIN_READS | iommu.IOTLB_DRAIN_WRITES)
		bound := wait_bound()
		for {
			finished, made := iommu.iotlb_invalidation_done(register_read_64(iotlb))
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

// iommu_start finds the remapping unit in the ACPI tables and turns
// translation on, with no device in a domain: from then on, a device with
// no declared page reaches no memory. The first processor runs it once,
// before the root service starts and after processors_start, which
// receives the size of the direct map and the frequency of the cycle
// counter. A machine with no unit, or with a form that the kernel does not
// program, runs as before, with one line.
iommu_start :: proc "contextless" (boot: ^info.Boot_Info) {
	table, size := acpi_table(boot.acpi_root, "DMAR")
	if table == nil {
		log("kernel: no IOMMU: the firmware lists no DMA remapping table; each device reaches all memory")
		return
	}
	dmar, problem := iommu.dmar_read(table[:size])
	log("kernel: IOMMU: a DMA remapping table, ", u64(dmar.host_address_width), " bits of address, ", u64(dmar.unit_count), " units, the first at ", Hex(dmar.register_base), ", ", u64(iommu.covered_count(dmar)), " functions of bus 0 covered")
	if problem != .None {
		log("kernel: no IOMMU in use: ", iommu.DMAR_PROBLEM_TEXTS[problem], "; each device reaches all memory")
		return
	}
	iommu_dmar = dmar
	configuration_table, configuration_size := acpi_table(boot.acpi_root, "MCFG")
	configuration: iommu.Configuration_Memory
	found := false
	if configuration_table != nil {
		configuration, found = iommu.mcfg_read(configuration_table[:configuration_size])
	}
	// The registers of the unit (64 KiB) and the configuration of bus 0
	// (1 MiB) must be device ranges in the direct map, never memory that
	// the firmware gave as free or as loaded: the kernel writes the
	// registers, and a table that lies must not make it write a frame.
	configuration_pages :: (1 << 20) / PAGE_SIZE
	register_pages :: iommu.REGISTER_SPACE / PAGE_SIZE
	if !found || configuration.base == 0 || dmar.register_base == 0 || configuration.base > direct_map_size - (1 << 20) || dmar.register_base > direct_map_size - iommu.REGISTER_SPACE || !device_range(configuration.base, configuration_pages) || !device_range(dmar.register_base, register_pages) {
		log("kernel: no IOMMU in use: the configuration memory of bus 0 or the registers of the unit are not a device range of the direct map; each device reaches all memory")
		return
	}
	iommu_registers = info.DIRECT_MAP_BASE + uintptr(dmar.register_base)
	// A mode that the firmware left on: the kernel would take over a unit
	// that it does not know.
	if status_problem := iommu.global_status_problem(register_read_32(iommu.REGISTER_GLOBAL_STATUS)); status_problem != .None {
		log("kernel: no IOMMU in use: ", iommu.GLOBAL_STATUS_PROBLEM_TEXTS[status_problem], "; each device reaches all memory")
		return
	}
	iommu_capability = register_read_64(iommu.REGISTER_CAPABILITY)
	iommu_extended = register_read_64(iommu.REGISTER_EXTENDED_CAPABILITY)
	iommu_levels = iommu.capability_levels(iommu_capability)
	iommu_coherent = iommu.extended_coherent(iommu_extended)
	fault_offset, fault_count := iommu.capability_fault_records(iommu_capability)
	// Domain identifiers 1 to 32: the unit must have more than 32, and the
	// identifier 0 stays unused, as the caching mode needs.
	if iommu_levels == 0 || fault_offset + fault_count * 16 > iommu.REGISTER_SPACE || iommu.extended_iotlb_offset(iommu_extended) + 16 > iommu.REGISTER_SPACE || iommu.capability_domain_count(iommu_capability) <= IOMMU_DEVICE_CAPACITY {
		log("kernel: no IOMMU in use: the unit has no table form of 39 or 48 bits, too few domains, or a register outside its space; each device reaches all memory")
		return
	}
	if !iommu.capability_drains(iommu_capability) {
		log("kernel: no IOMMU in use: the unit does not drain the reads and the writes in flight at an invalidation; each device reaches all memory")
		return
	}
	// The fault event is a message in the compatible form, which names an
	// interrupt controller by 8 bits.
	if processors[0].apic_id > 255 {
		log("kernel: no IOMMU in use: the fault event cannot name the first processor; each device reaches all memory")
		return
	}
	root := frames_allocate(1)
	context_table := frames_allocate(1)
	if root == 0 || context_table == 0 {
		log("kernel: no IOMMU in use: no memory for its root table")
		if root != 0 {
			frames_free(root, 1)
		}
		if context_table != 0 {
			frames_free(context_table, 1)
		}
		return
	}
	// The root table and the context table are memory of the kernel, as
	// the page table of the kernel: no budget pays for them.
	direct(root, [2]u64)^ = iommu.root_entry(context_table) // Bus 0.
	write_back(root, PAGE_SIZE)
	write_back(context_table, PAGE_SIZE)
	// Each record of a fault before the start is free again, and the next
	// fault sends the fault event to the first processor.
	for index in 0 ..< fault_count {
		register_write_32(fault_offset + index * 16 + 12, iommu.FAULT_CLEAR)
	}
	register_write_32(iommu.REGISTER_FAULT_STATUS, iommu.FAULT_STATUS_OVERFLOW)
	register_write_32(iommu.REGISTER_FAULT_EVENT_DATA, VECTOR_IOMMU_FAULT)
	register_write_32(iommu.REGISTER_FAULT_EVENT_ADDRESS, 0xFEE0_0000 | (processors[0].apic_id & 0xFF) << 12)
	register_write_32(iommu.REGISTER_FAULT_EVENT_UPPER_ADDRESS, 0)
	register_write_32(iommu.REGISTER_FAULT_EVENT_CONTROL, 0)
	register_write_64(iommu.REGISTER_ROOT_TABLE, root)
	if !global_set(iommu.GLOBAL_ROOT_TABLE) {
		// Translation is off, so the unit reads no table: the two frames
		// return.
		log("kernel: no IOMMU in use: the unit did not take its root table; each device reaches all memory")
		frames_free(root, 1)
		frames_free(context_table, 1)
		return
	}
	invalidate()
	if !global_set(iommu.GLOBAL_TRANSLATION) {
		log("kernel: no IOMMU in use: the unit did not turn translation on; each device reaches all memory")
		frames_free(root, 1)
		frames_free(context_table, 1)
		return
	}
	iommu_register_base = dmar.register_base
	iommu_context_table = context_table
	iommu_configuration = configuration.base
	iommu_in_use = true
	log("kernel: IOMMU: translation on, ", u64(iommu_levels), " levels of tables: a device reaches only the memory that its service declared")
}

// iommu_owns_range says if a range of physical addresses meets the
// registers of the unit or the configuration of bus 0: the kernel owns
// both while the IOMMU is in use, so Device_Create gives neither to a
// program, which could turn translation off.
iommu_owns_range :: proc "contextless" (start: u64, page_count: u64) -> bool {
	if !iommu_in_use {
		return false
	}
	end := start + page_count * PAGE_SIZE // device_range checked that it does not wrap.
	meets :: proc "contextless" (start, end, first, size: u64) -> bool {
		return start < first + size && first < end
	}
	return meets(start, end, iommu_register_base, iommu.REGISTER_SPACE) || meets(start, end, iommu_configuration, 1 << 20)
}

// iommu_requester_of gives 1 + the requester of the function of bus 0
// whose memory base address register starts at this physical address: the
// device of a memory object that Device_Create makes over its registers.
// 0: none, or no IOMMU in use. It reads the configuration of each
// function, and writes nothing: the root service owns the bus.
iommu_requester_of :: proc "contextless" (physical: u64) -> u32 {
	if !iommu_in_use {
		return 0
	}
	for device in u32(0) ..< 32 {
		for function in u32(0) ..< 8 {
			// The words that the bases need: the identity, the header type
			// and the six registers. Each read of the configuration can be
			// an exit to the hypervisor.
			header: [iommu.HEADER_WORDS]u32
			for index in u32(0) ..< 10 {
				if index == 1 || index == 2 {
					continue
				}
				header[index] = intrinsics.volatile_load(direct(iommu_configuration + iommu.configuration_offset(0, device, function, index * 4), u32))
				if index == 0 && header[0] & 0xFFFF == 0xFFFF {
					break
				}
			}
			if header[0] & 0xFFFF == 0xFFFF {
				if function == 0 {
					break // No device at this place.
				}
				continue
			}
			bases, count := iommu.header_memory_bases(header)
			for base in bases[:count] {
				if base == physical {
					// A function that the unit does not cover gives its
					// accesses past the unit: a domain would isolate nothing.
					// Such a device can write every page, the tables of the
					// unit too, so it ends the isolation of each device: the
					// log says so.
					if !iommu.dmar_covers(iommu_dmar, device, function) {
						log("kernel: IOMMU: the device at bus 0, device ", u64(device), ", function ", u64(function), " is not behind the unit: it reaches all memory, the tables of the unit too, and no device is isolated from it")
						return 0
					}
					return 1 + u32(iommu.requester(0, device, function))
				}
			}
			if function == 0 && !iommu.header_is_multi_function(header) {
				break
			}
		}
	}
	return 0
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

// table_take takes a zero page for a table of a domain, paid by a budget.
// 0: the budget has no page. The caller holds the frame lock.
@(private = "file")
table_take :: proc "contextless" (budget: ^u32) -> u64 {
	table := frame_paid_held(budget)
	if table != 0 {
		frames_zero(table, 1)
		write_back(table, PAGE_SIZE)
	}
	return table
}

// leaf_table gives the table of the last level for an address in the
// tables of a domain. With a budget, it makes each missing table on the
// way; with none, it makes none. nil: a table is missing, or the budget has
// no page. The caller holds the frame lock.
@(private = "file")
leaf_table :: proc "contextless" (top: u64, address: u64, budget: ^u32) -> ^[512]u64 {
	table := top
	for level := iommu_levels; level > 1; level -= 1 {
		entry := &direct(table, [512]u64)[iommu.level_index(address, level)]
		if !iommu.entry_present(entry^) {
			if budget == nil {
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

// pages_change changes the entries of count pages from first in the tables
// of a domain, one table of the last level at a time: one walk of the
// upper levels for each 2 MiB, not for each page. Map makes the missing
// tables, paid by budget; false: the budget had no page. The tables stay
// until the domain ends. The caller holds the frame lock, and invalidates
// after a Clear, an Allow_Write or a Deny_Write.
@(private = "file")
pages_change :: proc "contextless" (top: u64, first: u64, count: u64, change: Page_Change, writable: bool = false, budget: ^u32 = nil) -> bool {
	page := u64(0)
	for page < count {
		address := first + page * PAGE_SIZE
		index := iommu.level_index(address, 1)
		run := min(512 - index, count - page)
		leaf := leaf_table(top, address, change == .Map ? budget : nil)
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
				entry^ = iommu.page_entry(address + offset * PAGE_SIZE, writable)
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

// context_entry_write makes the context entry of a domain present, or
// clears it. The second word is written first and cleared last: the unit
// reads an entry whose first word is present as whole.
@(private = "file")
context_entry_write :: proc "contextless" (device: ^Iommu_Device, slot: u32, present: bool) {
	entry := direct(iommu_context_table + u64(device.requester & 0xFF) * iommu.ENTRY_SIZE, [2]u64)
	if present {
		words := iommu.context_entry(device.top, iommu_levels, u16(slot + 1))
		intrinsics.volatile_store(&entry[1], words[1])
		intrinsics.volatile_store(&entry[0], words[0])
	} else {
		intrinsics.volatile_store(&entry[0], 0)
		intrinsics.volatile_store(&entry[1], 0)
	}
	write_back(physical_of(entry), iommu.ENTRY_SIZE)
	device.present = present
}

// What declare_to_device changed in one domain.
Declaration_Change :: enum {
	None, // The domain already had the object with this write: nothing to invalidate.
	Mapped, // The object is new in the domain: an invalidation only for a unit with the caching mode.
	Write_Allowed, // The pages became writable: an invalidation, and an undo takes the write back.
	Write_Denied, // The pages became read-only: an invalidation.
	Undone, // A failed map was cleared from a domain that had entries before: an invalidation.
}

// declare_to_device declares one memory object to one device slot.
// writable: the handle of the call has Write; write_held: the program
// still holds a handle to the object with Write after this call, so a
// device keeps the write only while it holds one. The caller holds the
// frame lock, and invalidates after it by what changed.
@(private = "file")
declare_to_device :: proc "contextless" (program_index: u32, requester: u16, slot: u32, region_index: u32, writable: bool, write_held: bool) -> (change: Declaration_Change, status: op.Status) {
	device := &iommu_devices[slot]
	region := &regions[region_index]
	bit := u32(1) << slot
	if region.declared & bit != 0 {
		switch {
		case writable && region.declared_writable & bit == 0:
			pages_change(device.top, region.physical, region.page_count, .Allow_Write)
			region.declared_writable |= bit
			return .Write_Allowed, .Ok
		case !write_held && region.declared_writable & bit != 0:
			pages_change(device.top, region.physical, region.page_count, .Deny_Write)
			region.declared_writable &~= bit
			return .Write_Denied, .Ok
		}
		return .None, .Ok
	}
	budget := &programs[program_index].budget
	new_domain := device.owner == 0
	if new_domain {
		device^ = {requester = requester}
		device.top = table_take(budget)
		if device.top == 0 {
			device^ = {}
			return .None, .No_Budget
		}
	}
	if !pages_change(device.top, region.physical, region.page_count, .Map, writable, budget) {
		if new_domain {
			// No unit reads a domain with no context entry: its tables
			// return at once, and nothing was visible to the device.
			budgets[budget^].amounts.pages += tables_free(device.top, iommu_levels)
			device^ = {}
			return .None, .No_Budget
		}
		pages_change(device.top, region.physical, region.page_count, .Clear)
		return .Undone, .No_Budget
	}
	region.declared |= bit
	if writable {
		region.declared_writable |= bit
	}
	if new_domain {
		device.owner_serial = programs[program_index].serial
		intrinsics.atomic_store(&device.owner, program_index)
		context_entry_write(device, slot, true)
	}
	return .Mapped, .Ok
}

// write_deny_for takes the write out of the pages of a memory object in
// the domains of the device slots of a mask. It gives whether it changed a
// domain. The caller holds the frame lock, and invalidates after it.
@(private = "file")
write_deny_for :: proc "contextless" (region_index: u32, mask: u32) -> bool {
	region := &regions[region_index]
	denied := region.declared_writable & mask
	for slot in u32(0) ..< IOMMU_DEVICE_CAPACITY {
		if denied & (1 << slot) != 0 {
			pages_change(iommu_devices[slot].top, region.physical, region.page_count, .Deny_Write)
		}
	}
	region.declared_writable &~= denied
	return denied != 0
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

// region_end_for takes the pages of a memory object out of the domains of
// the device slots of a mask. It gives whether it changed a domain. The
// caller holds the frame lock, and invalidates after it.
@(private = "file")
region_end_for :: proc "contextless" (region_index: u32, mask: u32) -> bool {
	region := &regions[region_index]
	ended := region.declared & mask
	for slot in u32(0) ..< IOMMU_DEVICE_CAPACITY {
		if ended & (1 << slot) != 0 {
			pages_change(iommu_devices[slot].top, region.physical, region.page_count, .Clear)
		}
	}
	region.declared &~= ended
	region.declared_writable &~= ended
	return ended != 0
}

// iommu_declare maps each page of a contiguous memory object in the domain
// of each device whose registers the program holds by a handle:
// Memory_Physical by a device service. The device writes the pages only
// when writable: the handle of the call has the right Write. A program that
// holds no such handle declares nothing. Device memory is not declared: a
// device reaches no registers of a device. Either every device of the call
// gets the object, or none that did not have it before, and none gets a
// write that it did not have. A device keeps the write only while the
// program holds a handle with Write. The invalidation runs only when a
// domain changed. The caller holds the program lock.
iommu_declare :: proc "contextless" (program_index: u32, region_index: u32, writable: bool) -> op.Status {
	if !iommu_in_use || regions[region_index].device {
		return .Ok
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
			return .No_Slot
		}
		requesters[count] = requester
		count += 1
	}
	if count == 0 {
		return .Ok
	}
	region := &regions[region_index]
	// The tables of a domain map the addresses below this end only.
	if region.physical + region.page_count * PAGE_SIZE > iommu.domain_address_end(iommu_levels) {
		return .Bad_Operation
	}
	_, write_held := holds_with(program, region_index, nil)
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	added, write_allowed: u32
	needs_invalidation := false
	status := op.Status.Ok
	for requester in requesters[:count] {
		slot: u32
		slot, status = device_slot(u16(requester - 1), program_index)
		if status != .Ok {
			break
		}
		change: Declaration_Change
		change, status = declare_to_device(program_index, u16(requester - 1), slot, region_index, writable, write_held)
		switch change {
		case .None:
		case .Mapped:
			added |= 1 << slot
			// A unit with the caching mode can keep an entry that was not
			// present; another unit keeps only present entries. A unit that
			// asks for a flush of its write buffer needs it after an entry
			// becomes present, and the invalidation makes that flush first.
			needs_invalidation ||= iommu.capability_caching_mode(iommu_capability) || iommu.capability_write_buffer(iommu_capability)
		case .Write_Allowed:
			write_allowed |= 1 << slot
			needs_invalidation = true
		case .Write_Denied, .Undone:
			needs_invalidation = true
		}
		if status != .Ok {
			break
		}
	}
	if status != .Ok {
		// The device could use a new entry before the undo: the undo
		// invalidates.
		ended := region_end_for(region_index, added)
		denied := write_deny_for(region_index, write_allowed)
		needs_invalidation = needs_invalidation || ended || denied
	}
	if needs_invalidation {
		invalidate()
	}
	return status
}

// iommu_region_end_held takes the pages of a memory object out of each
// domain that has them, before its frames return: region_release calls it
// under the frame lock. After it, no device reaches the pages.
iommu_region_end_held :: proc "contextless" (region_index: u32) {
	if iommu_in_use && region_end_for(region_index, max(u32)) {
		invalidate()
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
// - the last handle to the registers of a device: the domain of that device
//   ends, so a device given to another service reaches nothing of this one.
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
	registers_held := false
	if requester != 0 {
		for &other in program.handles {
			if &other != closed && other.kind == .Memory && regions[other.object].requester == requester {
				registers_held = true
			}
		}
	}
	program_index := index_of_program(program)
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	owned := owned_devices(program_index)
	changed := false
	switch {
	case !holds:
		changed = region_end_for(closed.object, owned)
	case !writes:
		changed = write_deny_for(closed.object, owned)
	}
	if requester != 0 && !registers_held {
		ended: u32
		for slot in u32(0) ..< IOMMU_DEVICE_CAPACITY {
			if owned & (1 << slot) != 0 && u32(iommu_devices[slot].requester) + 1 == requester {
				ended |= 1 << slot
			}
		}
		if ended != 0 {
			domains_end(program_index, ended) // It invalidates, also for the changes above.
			return
		}
	}
	if changed {
		invalidate()
	}
}

// iommu_program_end ends each domain that a program owns.
// program_cleanup calls it before the handles of the program close.
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
// the invalidation, then their tables, whose pages return to the budget of
// the program, and the slots are free. The caller holds the frame lock.
@(private = "file")
domains_end :: proc "contextless" (program_index: u32, owned: u32) {
	for slot in u32(0) ..< IOMMU_DEVICE_CAPACITY {
		if owned & (1 << slot) != 0 && iommu_devices[slot].present {
			context_entry_write(&iommu_devices[slot], slot, false)
		}
	}
	// One pass over the table of the memory objects, at the end of a
	// domain only: the stop of a service, or the close of its registers.
	for &region in regions {
		region.declared &~= owned
		region.declared_writable &~= owned
	}
	// No unit reads a table of these domains after this.
	invalidate()
	budget := programs[program_index].budget
	for slot in u32(0) ..< IOMMU_DEVICE_CAPACITY {
		if owned & (1 << slot) == 0 {
			continue
		}
		device := &iommu_devices[slot]
		budgets[budget].amounts.pages += tables_free(device.top, iommu_levels)
		intrinsics.atomic_store(&device.owner, 0)
		device^ = {}
	}
}

// fault_count_of gives the place of the count of the faults of a requester.
@(private = "file")
fault_count_of :: proc "contextless" (requester: u16) -> ^u64 {
	return iommu.requester_bus(requester) == 0 ? &iommu_faults[requester & 0xFF] : &iommu_faults_of_other_buses
}

// iommu_faults_take reads each fault that the unit recorded, frees its
// record, counts it for its device, and writes the lines of the log that
// iommu.fault_line gives: a device that faults in a loop does not flood
// the log. It runs at the fault event, and at a tick of the first
// processor while records were left (iommu_faults_left), with no lock
// held: a DMA fault stops nothing. While a record holds a fault the unit
// sends no new fault event, so the handler reads the status again after
// each pass, and passes again while a record is pending, at most
// IOMMU_FAULT_PASSES times: with interrupts off, one call reads at most
// that many passes over the records (2 x 256 records for the largest
// unit). A record that is still pending after the last pass waits for the
// next tick, not for an event that would never come. The name of the
// service is read with no lock: in a race with the end of the service, the
// line can name the program of the slot before or after.
iommu_faults_take :: proc "contextless" () {
	if !iommu_in_use {
		return
	}
	offset, count := iommu.capability_fault_records(iommu_capability)
	pending := true
	for _ in 0 ..< IOMMU_FAULT_PASSES {
		for index in 0 ..< count {
			place := offset + index * 16
			// The word with the bit F first: the words read after it are
			// those of the fault that set it.
			last := register_read_32(place + 12)
			high := u64(register_read_32(place + 8)) | u64(last) << 32
			fault, recorded := iommu.fault_read(register_read_64(place), high)
			if !recorded {
				continue
			}
			register_write_32(place + 12, iommu.FAULT_CLEAR)
			faults := intrinsics.atomic_add(fault_count_of(fault.requester), 1) + 1
			line := iommu.fault_line(faults)
			if line == .None {
				continue
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
		if register_read_32(iommu.REGISTER_FAULT_STATUS) & iommu.FAULT_STATUS_PENDING == 0 {
			pending = false
			break
		}
	}
	register_write_32(iommu.REGISTER_FAULT_STATUS, iommu.FAULT_STATUS_OVERFLOW)
	intrinsics.atomic_store(&iommu_faults_left, pending)
}

// iommu_tick reads the records that the last fault event left, at a tick
// of the first processor. A tick with no record left reads one word.
iommu_tick :: proc "contextless" () {
	if intrinsics.atomic_load(&iommu_faults_left) {
		iommu_faults_take()
	}
}
