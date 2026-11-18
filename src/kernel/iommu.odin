package kernel

import info "modus:contract/boot_info"
import "modus:contract/bridge_requester"
import "kernel:iommu"
import op "modus:contract/operation"
import "base:intrinsics"

// The IOMMU (src/md/infrastructure/iommu.md): the kernel owns the tables of
// the remapping units, and a device reaches only the pages that its service
// declared with Memory_Physical, and writes only those that the handle of
// the declaration could write. With interrupt remapping, a device sends
// only the message interrupts whose entry names it. The kernel holds no
// code of a device: it reads the base address registers and the bridges of
// the bus only to know which device the registers of a memory object, or a
// message interrupt, belong to, and which unit translates its accesses.
//
// This file is the side of the kernel that does not know the vendor, with
// the procedures of Intel (VT-d). Each place where the two vendors differ
// reads iommu_vendor, in a switch or in a test of one vendor, with no
// indirect call; iommu_amd_vi.odin holds the procedures of
// AMD (src/md/infrastructure/iommu.md, "Two vendors behind one kernel
// side").
//
// The slots of the devices, the bits `declared` and `declared_writable` of
// each memory object, the tables of the domains and the queue of
// invalidations of each unit change under the frame lock: a declaration
// ends in region_release under that lock, before the frames of its object
// return (docs/ARCHITECTURE.md, "K5. Device grant and interrupts"). The
// entries of the interrupt table change under the control lock, as the
// message interrupts do, and their invalidation takes the frame lock for
// the queue. The fault handler reads `owner` and the counts of the faults
// with atomic loads and no lock. The units, the context tables and the
// standing domains are written once, at the start.

// The devices that have a domain at one time. A slot is free again when
// its domain ends. The domain identifier of a slot is the slot + 1: the
// identifier 0 stays unused, as the caching mode needs.
IOMMU_DEVICE_CAPACITY :: 32
// The devices whose registers one service can hold and declare memory to:
// a declaration from a process that holds the registers of more gives
// No_Slot. A device service holds one.
IOMMU_DEVICES_OF_A_SERVICE :: 4
// The devices that a reserved memory range names, each with a standing
// domain, whose identifiers follow those of the slots.
IOMMU_STANDING_CAPACITY :: 8
IOMMU_STANDING_DOMAIN_FIRST :: IOMMU_DEVICE_CAPACITY + 1

// Every window of a memory object ends where a domain of 39 bits ends, so
// the slot of an object always names a window that the tables can map.
#assert(REGION_CAPACITY * iommu.WINDOW_SIZE <= iommu.WINDOW_BASE)

// The vendor of the units: two vendors are a closed set. Each place where
// they differ reads it, in a switch or in a test of one vendor, with no
// indirect call on the path of a declaration.
Iommu_Vendor :: enum u8 {
	Intel, // VT-d: the table DMAR.
	Amd, // AMD-Vi: the table IVRS.
}

// One remapping unit that the kernel processes. The fields of the context
// tables and of the fault records are of VT-d; the requester and the event
// log are of AMD-Vi. The queue is the queue of invalidations of either
// vendor: a ring of records of 16 bytes that the kernel waits for.
Iommu_Unit :: struct {
	register_base:  u64, // The physical address of its registers.
	register_size:  u64, // The bytes of its registers that the kernel owns.
	registers:      uintptr, // The same registers, in the direct map.
	requester:      u16, // AMD-Vi: the function of PCI of the unit, whose message interrupt sends its events.
	event_log:      u64, // AMD-Vi: the event log, one page of records.
	event_head:     u32, // AMD-Vi: the byte of the next record that the kernel reads.
	caches_not_present: bool, // AMD-Vi: the unit can keep an entry that was not present (NpCache).
	capability:     u64,
	extended:       u64, // The extended capability of VT-d, or the extended features of AMD-Vi.
	levels:         u32, // The levels of the tables of a domain of this unit.
	address_end:    u64, // The first device address that the unit blocks: 2^MGAW.
	windows:        bool, // The unit translates the addresses of the device windows (iommu.WINDOW_ADDRESS_WIDTH bits).
	fault_offset:   u64, // The first fault recording register.
	fault_count:    u64,
	root:           u64, // The root table: a root entry for each bus.
	context_tables: [256]u64, // The context table of each bus that the walk at the start found. 0: none.
	queue:          u64, // The queue of invalidations: one page of descriptors.
	queue_tail:     u32, // The descriptor after the last that the kernel wrote.
	wait_number:    u32, // The number of the last wait descriptor.
	wait_status:    u64, // The physical address of the word where the unit writes the number of a wait descriptor that it reached.
}

// The domain of one device: its requester, its unit, the process that
// owns it, and its second-level tables. A slot whose owner is 0 is free.
Iommu_Device :: struct {
	requester:    u16,
	unit:         u32,
	present:      bool, // Its context entry is present.
	owner:        u32, // The process slot of the service that owns the domain. 0: a free slot. Atomic.
	owner_serial: u32, // The serial of that process, when it took the domain.
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
iommu_vendor: Iommu_Vendor // Written once at the start, from the table of the firmware.
iommu_units: [iommu.UNIT_CAPACITY]Iommu_Unit
iommu_unit_count: u32
iommu_coherent: bool // Every unit snoops the caches when it reads a table.
iommu_configuration: u64 // The physical address of the configuration memory of bus 0.
iommu_configuration_size: u64 // The configuration memory that the kernel reads and owns: 1 MiB for each bus.
iommu_last_bus: u32 // The last bus of that memory.
iommu_dmar: iommu.Dmar // The table DMAR as read at the start.
iommu_scopes: [iommu.SCOPE_CAPACITY]iommu.Resolved_Scope // Each scope of iommu_dmar, resolved at the start.
// The reserved memory ranges of the table of either vendor, and the devices
// that they name. Written once at the start.
iommu_reserved_ranges: [iommu.RESERVED_RANGE_CAPACITY]iommu.Reserved_Range
iommu_reserved_range_count: u32
Reserved_Device :: struct {
	range_index: u8, // The index of its reserved range.
	requester:   u16,
	named:       bool, // The table names one device that the bus has: not a bridge, not a path to no device.
}
iommu_reserved_devices: [iommu.SCOPE_CAPACITY]Reserved_Device
iommu_reserved_device_count: u32
iommu_reserved_mapped: [iommu.RESERVED_RANGE_CAPACITY]bool // The reserved ranges that the domains map.
iommu_standing: [IOMMU_STANDING_CAPACITY]Iommu_Standing
iommu_devices: [IOMMU_DEVICE_CAPACITY]Iommu_Device
// Interrupt remapping is on in every unit. Written once at the start.
iommu_interrupt_remapping: bool
// The interrupt table that every unit reads: one entry for each message
// interrupt, at its index. Memory of the kernel.
iommu_interrupt_table: u64
// The page of the words where each unit writes the number of its wait
// descriptors, one line of 64 bytes for each unit.
iommu_wait_page: u64
// The faults of each function of bus 0, by the low byte of its requester,
// and of all the functions of the other buses: the DMA faults, and apart
// the refused interrupts, so a storm of one kind does not hide the first
// line of the other. Atomic: they outlive the domain of a device.
Fault_Counts :: struct {
	of_bus_0:       [256]u64,
	of_other_buses: u64,
}
iommu_dma_faults: Fault_Counts
iommu_interrupt_faults: Fault_Counts
// The passes of one call of iommu_faults_take over the fault records.
IOMMU_FAULT_PASSES :: 2
// A record was still pending at the end of the last call: the next tick of
// the first processor reads the records again. Atomic.
iommu_faults_left: bool

@(private)
register_read_32 :: proc "contextless" (unit: ^Iommu_Unit, offset: u64) -> u32 {
	return intrinsics.volatile_load((^u32)(unit.registers + uintptr(offset)))
}

@(private)
register_write_32 :: proc "contextless" (unit: ^Iommu_Unit, offset: u64, value: u32) {
	intrinsics.volatile_store((^u32)(unit.registers + uintptr(offset)), value)
}

@(private)
register_read_64 :: proc "contextless" (unit: ^Iommu_Unit, offset: u64) -> u64 {
	return intrinsics.volatile_load((^u64)(unit.registers + uintptr(offset)))
}

@(private)
register_write_64 :: proc "contextless" (unit: ^Iommu_Unit, offset: u64, value: u64) {
	intrinsics.volatile_store((^u64)(unit.registers + uintptr(offset)), value)
}

// write_back writes the cache lines of a part of a table to memory when a
// unit does not snoop the caches: it reads memory, not the cache.
@(private)
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
@(private)
wait_bound :: proc "contextless" () -> u64 {
	return cycles_now() + cycle_frequency
}

// wait_turn ends one turn of a wait. false: the bound passed.
@(private)
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

// The descriptors of one invalidation of a unit, before the wait
// descriptor that invalidate_unit adds at its end: the descriptors of the
// queue of VT-d, or the commands of AMD-Vi, both of 16 bytes.
Descriptor_Batch :: struct {
	descriptors: [iommu.QUEUE_LARGEST_BATCH - 1][2]u64,
	count:       u32,
}

@(private)
batch_add :: proc "contextless" (batch: ^Descriptor_Batch, descriptor: [2]u64) {
	batch.descriptors[batch.count] = descriptor
	batch.count += 1
}

// domain_batch gives the descriptors that make a unit forget the
// translations of one domain identifier, with the drain of the reads and
// writes in flight, and with context_changed also the entry of the device
// requester: on VT-d the context entries that carry the identifier
// context_domain, on AMD-Vi the entry of the requester in the device table.
@(private = "file")
domain_batch :: proc "contextless" (domain: u16, context_changed: bool, context_domain: u16, requester: u16) -> (batch: Descriptor_Batch) {
	switch iommu_vendor {
	case .Intel:
		if context_changed {
			batch_add(&batch, iommu.descriptor_context(context_domain))
		}
		batch_add(&batch, iommu.descriptor_iotlb(domain))
	case .Amd:
		// Each refusing entry carries the domain identifier 0. A unit that
		// reads the two words of an entry in two reads, during a change, can
		// walk the tables of a domain under the identifier 0: the domain 0 is
		// forgotten too, before the tables or the frames return.
		if context_changed {
			batch_add(&batch, iommu.amd_command_device_entry(requester))
			batch_add(&batch, iommu.amd_command_pages(0))
		}
		batch_add(&batch, iommu.amd_command_pages(domain))
	}
	return batch
}

// invalidate_unit gives a batch to the queue of a unit, then a wait, and
// waits until the unit wrote the number of the wait: the unit then did each
// descriptor before it, and no device of the unit uses an entry that the
// kernel cleared. The caller holds the frame lock, or runs at the start:
// one writer of the queue at a time. Each batch waits for its end, so the
// queue holds one batch at most and never fills. A unit that does not
// reach the wait, or that refuses a descriptor, stops the machine: a page
// that a device can still reach must not become free.
@(private)
invalidate_unit :: proc "contextless" (unit: ^Iommu_Unit, batch: Descriptor_Batch) {
	done: bool
	switch iommu_vendor {
	case .Intel:
		done = invalidation_queue_run(unit, batch)
	case .Amd:
		done = amd_commands_run(unit, batch)
	}
	if !done {
		fault_report_begin()
		log("kernel: the IOMMU did not finish an invalidation, or refused one: the machine stops")
		machine_stop(.Fault)
	}
}

// invalidation_queue_run gives a batch of descriptors to the queue of
// invalidations of a unit of VT-d, then a wait descriptor, and waits for
// it, with the drains that the descriptors ask. The flush of the write
// buffer comes first when the unit needs it: the queue does not replace
// it. false: the unit did not reach the wait in one second, or refused a
// descriptor (the error of the queue).
@(private = "file")
invalidation_queue_run :: proc "contextless" (unit: ^Iommu_Unit, batch: Descriptor_Batch) -> bool {
	done := true
	if iommu.capability_write_buffer(unit.capability) {
		register_write_32(unit, iommu.REGISTER_GLOBAL_COMMAND, iommu.global_command(register_read_32(unit, iommu.REGISTER_GLOBAL_STATUS), iommu.GLOBAL_WRITE_BUFFER))
		bound := wait_bound()
		for done && register_read_32(unit, iommu.REGISTER_GLOBAL_STATUS) & iommu.GLOBAL_WRITE_BUFFER != 0 {
			done = wait_turn(bound)
		}
	}
	if done {
		queue := direct(unit.queue, [iommu.QUEUE_DESCRIPTORS][2]u64)
		unit.wait_number += 1
		number := unit.wait_number
		wait := iommu.descriptor_wait(unit.wait_status, number)
		tail := unit.queue_tail
		// The unit reads the descriptors only after the write of the tail
		// register: each word is a volatile store before it.
		for index in u32(0) ..= batch.count {
			descriptor := wait
			if index < batch.count {
				descriptor = batch.descriptors[index]
			}
			intrinsics.volatile_store(&queue[tail][0], descriptor[0])
			intrinsics.volatile_store(&queue[tail][1], descriptor[1])
			write_back(unit.queue + u64(tail) * iommu.DESCRIPTOR_SIZE, iommu.DESCRIPTOR_SIZE)
			tail = (tail + 1) % iommu.QUEUE_DESCRIPTORS
		}
		unit.queue_tail = tail
		register_write_64(unit, iommu.REGISTER_QUEUE_TAIL, iommu.queue_tail_register(tail))
		status := direct(unit.wait_status, u32)
		bound := wait_bound()
		for intrinsics.volatile_load(status) != number {
			if register_read_32(unit, iommu.REGISTER_FAULT_STATUS) & iommu.FAULT_STATUS_QUEUE_ERROR != 0 || !wait_turn(bound) {
				done = false
				break
			}
		}
	}
	return done
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
	requester := iommu_devices[slot].requester
	batch: Descriptor_Batch
	switch change {
	case .None:
		batch = domain_batch(domain, false, 0, requester)
	case .Made:
		batch = domain_batch(domain, true, 0, requester)
	case .Cleared:
		batch = domain_batch(domain, true, domain, requester)
	}
	invalidate_unit(&iommu_units[iommu_devices[slot].unit], batch)
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
@(private)
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

// bridge_kind reads the first 256 bytes of the configuration of a bridge
// and says if it gives each device behind it its own requester; if not,
// shared is the requester that it gives each of them.
@(private = "file")
bridge_kind :: proc "contextless" (bus, device, function, secondary: u32) -> (passes: bool, shared: u16) {
	configuration: [bridge_requester.CONFIGURATION_WORDS]u32
	for &word, index in configuration {
		word = configuration_read(bus, device, function, u32(index) * 4)
	}
	if bridge_requester.bridge_passes_requesters(&configuration) {
		return true, 0
	}
	return false, iommu.bridge_shared_requester(&configuration, bus, device, function, secondary)
}

// A walk of the buses: bus 0, then the secondary bus of each bridge, each
// bus once. With `physical`, it stops at the function whose memory
// register starts there; with make_tables, it makes the entries of the bus
// of each function that a unit covers (function_found_at_start), and of
// each shared requester; with `group`, it counts the functions that share
// that requester, and checks that `holder` holds the registers of each.
Bus_Walk :: struct {
	physical:                   u64,
	make_tables:                bool,
	found:                      bool,
	requester:                  u16, // The function that was found.
	behind_conventional_bridge: bool, // A conventional bridge is on its way from bus 0: it shares its requester.
	shared_requester:           u16, // Behind a conventional bridge: the requester that the function shares with each device there.
	group:                      u32, // 1 + a shared requester whose functions the walk checks. 0: none.
	holder:                     ^Process, // The process that must hold the registers of each function of the group.
	member_count:               u32, // The functions of the group, bridges excepted.
	unheld:                     bool, // A function of the group whose registers the holder does not hold, or that has no memory registers, or a bridge that the walk cannot follow.
	unheld_requester:           u16, // The first such function.
	odd_bridge:                 bool, // The first such function is a bridge of the group whose secondary bus the walk cannot follow.
	no_memory:                  bool, // A context table had no frame.
	bus_count:                  u32,
}

// The shared requester of the devices of each bus, 1 + it, as the walk at
// the start found it: 0 for a bus that no conventional bridge is in front
// of. A reserved memory range of a device on such a bus is not mapped for
// the requester of the device, which the unit never sees; an alias of
// AMD-Vi to a shared requester must have its sources on its buses.
iommu_shared_of_bus: [256]u32

@(private)
buses_walk :: proc "contextless" (walk: ^Bus_Walk) {
	// A bus is queued at most once, so the queue holds at most 256 buses.
	// A bus is behind a conventional bridge when one bridge on its way is.
	// Its devices share the requester that the conventional bridge nearest
	// to bus 0 gives them: that bridge makes their requests on PCI Express.
	queue: [256]u8
	queued: [256]bool
	conventional: [256]bool
	shared: [256]u16
	count := 1
	queued[0] = true
	for next := 0; next < count; next += 1 {
		bus := u32(queue[next])
		walk.bus_count += 1
		if walk.make_tables && conventional[bus] {
			iommu_shared_of_bus[bus] = 1 + u32(shared[bus])
		}
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
				if walk.make_tables && !conventional[bus] && !function_found_at_start(identifier) {
					walk.no_memory = true
					return
				}
				if iommu.header_is_bridge(header) {
					secondary, _ := iommu.bridge_buses(header)
					followed := secondary > bus && secondary <= iommu_last_bus && !queued[secondary]
					// A bridge of the group whose secondary bus the walk does
					// not follow can route devices that share the requester and
					// that the check does not count.
					if !followed && walk.group != 0 && conventional[bus] && u32(shared[bus]) + 1 == walk.group && !walk.unheld {
						walk.unheld, walk.unheld_requester, walk.odd_bridge = true, identifier, true
					}
					if followed {
						queued[secondary] = true
						if conventional[bus] {
							conventional[secondary], shared[secondary] = true, shared[bus]
						} else if passes, shared_requester := bridge_kind(bus, device, function, secondary); !passes {
							conventional[secondary], shared[secondary] = true, shared_requester
							// A bridge from PCI Express to PCI shares the requester of
							// its secondary bus: the entries of that bus serve it.
							if walk.make_tables && shared_requester != identifier && !function_found_at_start(shared_requester) {
								walk.no_memory = true
								return
							}
						}
						queue[count] = u8(secondary)
						count += 1
					}
				} else if walk.group != 0 {
					if conventional[bus] && u32(shared[bus]) + 1 == walk.group {
						group_member_check(walk, header, identifier)
					}
				} else if walk.physical != 0 {
					bases, base_count := iommu.header_memory_bases(header)
					for base in bases[:base_count] {
						if base == walk.physical {
							walk.found = true
							walk.requester = identifier
							walk.behind_conventional_bridge = conventional[bus]
							walk.shared_requester = shared[bus]
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

// group_member_check counts one function that shares the requester of a
// group walk, and notes the first one whose registers the holder does not
// hold. A function with no memory base address register cannot be held:
// it can still read and write memory, through its ports.
@(private = "file")
group_member_check :: proc "contextless" (walk: ^Bus_Walk, header: [iommu.HEADER_WORDS]u32, identifier: u16) {
	walk.member_count += 1
	_, base_count := iommu.header_memory_bases(header)
	if !walk.unheld && (base_count == 0 || !registers_held(walk.holder, walk.group, 1 + u32(identifier), nil, nil)) {
		walk.unheld, walk.unheld_requester = true, identifier
	}
}

// unit_of gives the unit that translates the accesses of a requester.
@(private)
unit_of :: proc "contextless" (requester: u16) -> (unit: u32, covered: bool) {
	switch iommu_vendor {
	case .Intel:
		unit, covered = iommu.unit_of(&iommu_dmar, &iommu_scopes, requester)
	case .Amd:
		unit, covered, _ = iommu.amd_unit_of(&iommu_ivrs, requester)
	}
	return unit, covered
}

// requester_aliased says if the table of the firmware gives the accesses of
// a requester another requester: an alias of AMD-Vi. VT-d has no alias in
// its table; the walk finds the conventional bridges of both.
@(private = "file")
requester_aliased :: proc "contextless" (requester: u16) -> bool {
	if iommu_vendor != .Amd {
		return false
	}
	_, _, aliased := iommu.amd_unit_of(&iommu_ivrs, requester)
	return aliased
}

// requester_alias_agrees says if the table of the firmware gives the
// accesses of a requester the shared requester that the walk found behind
// a conventional bridge, or no other one: an alias of AMD-Vi must name it.
// VT-d has no alias in its table.
@(private = "file")
requester_alias_agrees :: proc "contextless" (requester: u16, shared: u16) -> bool {
	if iommu_vendor != .Amd {
		return true
	}
	return iommu.amd_alias_agrees(&iommu_ivrs, requester, shared)
}

// shared_alias_sources_behind says if every alias of AMD-Vi whose target is
// a shared requester has its sources on the buses behind its bridge, as the
// walk at the start found them: a device outside the group would else reach
// the domain of the group, and the check of the group never counts it.
@(private = "file")
shared_alias_sources_behind :: proc "contextless" (shared: u16) -> bool {
	if iommu_vendor != .Amd {
		return true
	}
	return iommu.amd_alias_sources_behind(&iommu_ivrs, shared, &iommu_shared_of_bus)
}

// bus_translated says if the unit has the entries of a bus, so that a
// device of it can get a domain: a context table of VT-d, or a bus of the
// device table of AMD-Vi that the walk at the start found.
@(private = "file")
bus_translated :: proc "contextless" (unit_index: u32, bus: u32) -> bool {
	translated: bool
	switch iommu_vendor {
	case .Intel:
		translated = iommu_units[unit_index].context_tables[bus & 0xFF] != 0
	case .Amd:
		translated = amd_buses_found[bus & 0xFF]
	}
	return translated
}

// function_found_at_start makes the entries of the bus of a function that
// the walk at the start found. false: no frame.
@(private = "file")
function_found_at_start :: proc "contextless" (requester: u16) -> bool {
	if _, covered := unit_of(requester); !covered {
		// The line at the start, also for a function whose registers no
		// service ever gets: the firmware can have started its DMA.
		log("kernel: IOMMU: the device at bus ", u64(iommu.requester_bus(requester)), ", device ", u64(iommu.requester_device(requester)), ", function ", u64(iommu.requester_function(requester)), " is not behind a unit: it reaches all memory, the tables of the units too")
		return true
	}
	made := true
	switch iommu_vendor {
	case .Intel:
		made = context_table_make(requester)
	case .Amd:
		// The device table holds an entry for each bus of the configuration
		// memory: the walk only marks the bus.
		amd_buses_found[iommu.requester_bus(requester) & 0xFF] = true
	}
	return made
}

// context_table_make makes the context table of the bus of a requester
// that a unit covers on its unit, at the start: memory of the kernel, as
// the root table, which lives as long as the machine. false: no frame.
@(private = "file")
context_table_make :: proc "contextless" (requester: u16) -> bool {
	unit_index, _ := unit_of(requester)
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

// device_entry_write makes the entry of a requester on a unit present,
// with the tables from top in a domain identifier, or clears it: the
// context entry of VT-d, or the entry of the device table of AMD-Vi, which
// a clear makes refuse every access.
@(private = "file")
device_entry_write :: proc "contextless" (unit_index: u32, requester: u16, present: bool, top: u64 = 0, domain: u16 = 0) {
	switch iommu_vendor {
	case .Intel:
		context_entry_write(unit_index, requester, present, top, domain)
	case .Amd:
		amd_translation_write(requester, present, top, iommu_units[unit_index].levels, domain)
	}
}

// context_entry_write makes the context entry of a requester on a unit
// present, with the tables from top in a domain identifier, or clears it.
// The second word is written first and cleared last: the unit reads an
// entry whose first word is present as whole.
@(private = "file")
context_entry_write :: proc "contextless" (unit_index: u32, requester: u16, present: bool, top: u64, domain: u16) {
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
	for item in iommu_reserved_devices[:iommu_reserved_device_count] {
		if !item.named || item.requester != requester || !iommu_reserved_mapped[item.range_index] {
			continue
		}
		reserved := iommu_reserved_ranges[item.range_index]
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
	for index in 0 ..< int(iommu_reserved_range_count) {
		reserved := iommu_reserved_ranges[index]
		pages := (reserved.end - reserved.start) / PAGE_SIZE
		// A range of free or loaded memory would give a device a frame of a
		// process; a range at or above the windows would meet the window of
		// an object.
		if reserved.end > iommu.WINDOW_BASE || pages > iommu.RESERVED_RANGE_PAGE_LIMIT || !device_range(reserved.start, pages) {
			log("kernel: IOMMU: the reserved memory range ", Hex(reserved.start), " to ", Hex(reserved.end), " is not mapped: it meets memory that the firmware gave as free or loaded, ends past 256 GiB, or is larger than 1 GiB; its devices fault there")
			continue
		}
		iommu_reserved_mapped[index] = true
	}
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	for item in iommu_reserved_devices[:iommu_reserved_device_count] {
		if !iommu_reserved_mapped[item.range_index] {
			continue
		}
		if !item.named {
			log("kernel: IOMMU: a device scope of a reserved memory range is a bridge, or names no device on the bus: the range is not mapped for it")
			continue
		}
		unit_index, covered := unit_of(item.requester)
		if !covered {
			continue // Its accesses pass every unit: the firmware keeps its range with no table.
		}
		item_bus := iommu.requester_bus(item.requester)
		if !bus_translated(unit_index, item_bus) || iommu_shared_of_bus[item_bus & 0xFF] != 0 || requester_aliased(item.requester) {
			// A bus that the walk from bus 0 did not reach: another root bus;
			// a bus behind a conventional bridge, whose devices carry the
			// requester of the bridge; or a device whose accesses carry
			// another requester. The device faults on its range, as on every
			// access.
			log("kernel: IOMMU: the device at bus ", u64(item_bus), ", device ", u64(iommu.requester_device(item.requester)), ", function ", u64(iommu.requester_function(item.requester)), " of a reserved memory range is on a bus with no entries of the unit, is behind a conventional bridge, or has an alias: the range is not mapped for it, and its accesses are refused")
			continue
		}
		if existing, _ := standing_of(item.requester); existing != nil {
			continue // The first scope of the device mapped each of its ranges.
		}
		place := -1
		for &candidate, slot in iommu_standing {
			if !candidate.used {
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
		standing^ = {used = true, requester = item.requester, unit = unit_index, top = table_take(nil)}
		if standing.top == 0 || !reserved_ranges_map(item.requester, standing.top, levels, nil) {
			log("kernel: no IOMMU in use: no memory for the tables of a reserved memory range; each device reaches all memory")
			return false
		}
		device_entry_write(unit_index, item.requester, true, standing.top, u16(IOMMU_STANDING_DOMAIN_FIRST + place))
	}
	return true
}

// reserved_devices_read keeps the reserved memory ranges of the table of
// the vendor, and the device of each, in the form that the standing domains
// read. On VT-d a scope names its device by a path through the bridges,
// which this resolves; on AMD-Vi a range names one requester.
@(private = "file")
reserved_devices_read :: proc "contextless" () {
	switch iommu_vendor {
	case .Intel:
		for index in 0 ..< int(iommu_dmar.scope_count) {
			iommu_scopes[index] = iommu.scope_resolve(iommu_dmar.scopes[index], bridge_read)
		}
		iommu_reserved_ranges = iommu_dmar.reserved_ranges
		iommu_reserved_range_count = iommu_dmar.reserved_range_count
		for index in 0 ..< int(iommu_dmar.scope_count) {
			scope := &iommu_dmar.scopes[index]
			if !scope.reserved {
				continue
			}
			resolved := &iommu_scopes[index]
			iommu_reserved_devices[iommu_reserved_device_count] = {range_index = scope.owner, requester = resolved.requester, named = !scope.bridge && resolved.found}
			iommu_reserved_device_count += 1
		}
	case .Amd:
		iommu_reserved_ranges = iommu_ivrs.reserved_ranges
		iommu_reserved_range_count = iommu_ivrs.reserved_range_count
		for index in 0 ..< iommu_ivrs.reserved_range_count {
			iommu_reserved_devices[index] = {range_index = u8(index), requester = iommu_ivrs.reserved_requesters[index], named = true}
		}
		iommu_reserved_device_count = iommu_ivrs.reserved_range_count
	}
}

// iommu_start finds the remapping units in the ACPI tables and turns
// translation on, with no device in a domain but those of the reserved
// ranges: from then on, a device with no declared page reaches no memory.
// The first processor runs it once, before the root service starts and
// after processors_start, which receives the size of the direct map and the
// frequency of the cycle counter. Each unit is checked before any is
// turned on. A machine with no unit, or with a form that the kernel does not
// process, runs as before, with one line. The tables of the start are
// memory of the kernel; when a unit fails to start they stay, a few pages.
// The machine says its vendor by the table of its firmware: DMAR for
// VT-d, else IVRS for AMD-Vi, so one boot image runs on both.
iommu_start :: proc "contextless" (boot: ^info.Boot_Info) {
	dmar_table, dmar_size := acpi_table(boot.acpi_root, "DMAR")
	ivrs_table, ivrs_size := acpi_table(boot.acpi_root, "IVRS")
	unit_count: u32
	register_bases: [iommu.UNIT_CAPACITY]u64
	switch {
	case dmar_table != nil:
		iommu_vendor = .Intel
		problem: iommu.Dmar_Problem
		iommu_dmar, problem = iommu.dmar_read(dmar_table[:dmar_size])
		dmar := &iommu_dmar
		log("kernel: IOMMU: a DMA remapping table, ", u64(dmar.host_address_width), " bits of address, ", u64(dmar.unit_count), " units, ", u64(dmar.reserved_range_count), " reserved memory ranges, ", u64(dmar.scope_count), " device scopes")
		if problem != .None {
			log("kernel: no IOMMU in use: ", iommu.DMAR_PROBLEM_TEXTS[problem], "; each device reaches all memory")
			return
		}
		unit_count = dmar.unit_count
		for index in 0 ..< unit_count {
			register_bases[index] = dmar.units[index].register_base
		}
	case ivrs_table != nil:
		iommu_vendor = .Amd
		problem: iommu.Ivrs_Problem
		iommu_ivrs, problem = iommu.ivrs_read(ivrs_table[:ivrs_size])
		ivrs := &iommu_ivrs
		log("kernel: IOMMU: an I/O virtualization table of AMD, ", u64(ivrs.unit_count), " units, ", u64(ivrs.reserved_range_count), " reserved memory ranges, ", u64(ivrs.range_count), " ranges of devices")
		if problem != .None {
			log("kernel: no IOMMU in use: ", iommu.IVRS_PROBLEM_TEXTS[problem], "; each device reaches all memory")
			return
		}
		unit_count = ivrs.unit_count
		for index in 0 ..< unit_count {
			register_bases[index] = ivrs.units[index].register_base
		}
	case:
		log("kernel: no IOMMU: the firmware lists no DMA remapping table and no I/O virtualization table; each device reaches all memory")
		return
	}
	configuration_table, configuration_table_size := acpi_table(boot.acpi_root, "MCFG")
	configuration: iommu.Configuration_Memory
	found := false
	if configuration_table != nil {
		configuration, found = iommu.mcfg_read(configuration_table[:configuration_table_size])
	}
	// The configuration memory of the buses (1 MiB each) and the registers
	// of each unit (64 KiB on VT-d, 16 KiB on AMD-Vi) must be device ranges
	// in the direct map, never memory that the firmware gave as free or as
	// loaded: the kernel writes the registers, and a table that lies must
	// not make it write a frame.
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
	// The unit of AMD-Vi is a function of the bus, whose configuration the
	// check of the unit reads.
	iommu_configuration = configuration.base
	iommu_configuration_size = bus_count * iommu.CONFIGURATION_BUS_SIZE
	iommu_last_bus = u32(bus_count - 1)
	register_size := iommu_vendor == .Intel ? u64(iommu.REGISTER_SPACE) : u64(iommu.AMD_REGISTER_SPACE)
	for index in 0 ..< unit_count {
		unit := &iommu_units[index]
		base := register_bases[index]
		if base == 0 || base > direct_map_size - register_size || !device_range(base, register_size / PAGE_SIZE) {
			log("kernel: no IOMMU in use: the registers of a unit are not a device range of the direct map; each device reaches all memory")
			return
		}
		unit.register_base = base
		unit.register_size = register_size
		unit.registers = info.DIRECT_MAP_BASE + uintptr(base)
		checked: bool
		switch iommu_vendor {
		case .Intel:
			checked = remapping_unit_check(unit)
		case .Amd:
			checked = amd_unit_check(unit, iommu_ivrs.units[index])
		}
		if !checked {
			return
		}
	}
	// The fault event is a message in the compatible form, which names an
	// interrupt controller by 8 bits.
	if processors[0].apic_id > 255 {
		log("kernel: no IOMMU in use: the fault event cannot name the first processor; each device reaches all memory")
		return
	}
	iommu_unit_count = unit_count
	// A unit of AMD-Vi snoops the caches when the kernel sets its control
	// bit Coherent (iommu.AMD_CONTROL_STARTED).
	iommu_coherent = true
	if iommu_vendor == .Intel {
		for &unit in iommu_units[:iommu_unit_count] {
			iommu_coherent &&= iommu.extended_coherent(unit.extended)
		}
	}
	reserved_devices_read()
	// The root tables, the queues of invalidations, the event logs, the
	// words of the waits, the interrupt tables, the context tables of the
	// buses, the device table and the standing domains are memory of the
	// kernel, as the page table of the kernel: no budget pays for them. The
	// words of the waits start at 0, and the first wait number is 1.
	iommu_wait_page = frames_allocate(1)
	if iommu_wait_page == 0 {
		log("kernel: no IOMMU in use: no memory for its queues")
		return
	}
	#assert(iommu.UNIT_CAPACITY * 64 <= PAGE_SIZE)
	for &unit, index in iommu_units[:iommu_unit_count] {
		unit.queue = frames_allocate(1)
		// The root table of VT-d, or the event log of AMD-Vi.
		second := frames_allocate(1)
		if unit.queue == 0 || second == 0 {
			log("kernel: no IOMMU in use: no memory for its root tables, its queues or its event logs")
			return
		}
		switch iommu_vendor {
		case .Intel:
			unit.root = second
		case .Amd:
			unit.event_log = second
		}
		write_back(second, PAGE_SIZE)
		write_back(unit.queue, PAGE_SIZE)
		unit.wait_status = iommu_wait_page + u64(index) * 64
	}
	// Interrupt remapping on every unit or on none: a device of a unit with
	// no remapping could send any vector, and the line would not name it.
	remapping: bool
	switch iommu_vendor {
	case .Intel:
		// The flag of the table comes first: a firmware clears it on a
		// platform whose remapping has a fault, even when each unit offers
		// it.
		remapping = iommu_dmar.interrupt_remapping
		for &unit in iommu_units[:iommu_unit_count] {
			remapping &&= iommu.extended_interrupt_remapping(unit.extended)
		}
		if remapping {
			iommu_interrupt_table = frames_allocate(1)
			if iommu_interrupt_table == 0 {
				log("kernel: no IOMMU in use: no memory for its interrupt table")
				return
			}
			write_back(iommu_interrupt_table, PAGE_SIZE)
		}
	case .Amd:
		// Every unit of AMD-Vi remaps; a table that names no IOAPIC is a
		// platform whose firmware does not give remapping.
		remapping = iommu_ivrs.names_interrupt_controller
		if !amd_tables_make(remapping) {
			log("kernel: no IOMMU in use: no memory for its device table or its interrupt tables")
			return
		}
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
	// The cycles of one round trip of the queue of the first unit: the time
	// that a holder of the frame lock waits for at each invalidation. A
	// measure on the log, not a check.
	started: bool
	round_trip_cycles: u64
	switch iommu_vendor {
	case .Intel:
		started, round_trip_cycles = remapping_units_start()
	case .Amd:
		started, round_trip_cycles = amd_units_start()
	}
	if !started {
		return
	}
	standing_count: u64
	for item in iommu_standing {
		standing_count += item.used ? 1 : 0
	}
	iommu_in_use = true
	log("kernel: IOMMU: translation on, ", u64(iommu_unit_count), " units, ", u64(walk.bus_count), " buses, ", standing_count, " devices with a reserved memory range: a device reaches only the memory that its service declared")
	per_microsecond := cycle_frequency / 1_000_000
	round_trip_nanoseconds := per_microsecond == 0 ? 0 : round_trip_cycles * 1000 / per_microsecond
	log("kernel: IOMMU: measure: one round trip of the queue of invalidations (the global invalidation of the first unit at the start), which a holder of the frame lock waits for at each invalidation: ", round_trip_cycles, " cycles, ", round_trip_nanoseconds, " ns")
	switch iommu_vendor {
	case .Intel:
		if !iommu_dmar.interrupt_remapping {
			log("kernel: IOMMU: no interrupt remapping: the DMA remapping table does not allow it; a device can send any interrupt")
			return
		}
		if !remapping {
			log("kernel: IOMMU: no interrupt remapping: a unit does not offer it; a device can send any interrupt")
			return
		}
		interrupt_remapping_start()
	case .Amd:
		// The entry of each device in the device table refuses each message
		// from the moment the unit is on: remapping started with translation.
		if !remapping {
			log("kernel: IOMMU: no interrupt remapping: the I/O virtualization table names no IOAPIC; a device can send any interrupt")
			return
		}
		iommu_interrupt_remapping = true
		log("kernel: IOMMU: interrupt remapping on: a device sends only the message interrupts that its service was given")
	}
}

// remapping_unit_check reads the capabilities of a unit of VT-d, and
// refuses a unit that the kernel does not process, with one line.
@(private = "file")
remapping_unit_check :: proc "contextless" (unit: ^Iommu_Unit) -> bool {
	// A mode that the firmware left on: the kernel would take over a unit
	// that it does not know.
	if status_problem := iommu.global_status_problem(register_read_32(unit, iommu.REGISTER_GLOBAL_STATUS)); status_problem != .None {
		log("kernel: no IOMMU in use: ", iommu.GLOBAL_STATUS_PROBLEM_TEXTS[status_problem], "; each device reaches all memory")
		return false
	}
	unit.capability = register_read_64(unit, iommu.REGISTER_CAPABILITY)
	unit.extended = register_read_64(unit, iommu.REGISTER_EXTENDED_CAPABILITY)
	unit.levels = iommu.capability_levels(unit.capability)
	unit.fault_offset, unit.fault_count = iommu.capability_fault_records(unit.capability)
	// The domain identifiers of the slots and of the standing domains, from
	// 1: the identifier 0 stays unused, as the caching mode needs.
	if unit.levels == 0 || unit.fault_offset + unit.fault_count * 16 > iommu.REGISTER_SPACE || iommu.capability_domain_count(unit.capability) <= IOMMU_DEVICE_CAPACITY + IOMMU_STANDING_CAPACITY {
		log("kernel: no IOMMU in use: a unit has no table form of 39 or 48 bits, too few domains, or a register outside its space; each device reaches all memory")
		return false
	}
	// Every invalidation goes through the queue: the one path that
	// interrupt remapping allows.
	if !iommu.extended_queue(unit.extended) {
		log("kernel: no IOMMU in use: a unit has no queue of invalidations; each device reaches all memory")
		return false
	}
	if !iommu.capability_drains(unit.capability) {
		log("kernel: no IOMMU in use: a unit does not drain the reads and the writes in flight at an invalidation; each device reaches all memory")
		return false
	}
	// A unit blocks each request above its width, whatever its tables map:
	// with fewer bits than the windows need, its devices get contiguous
	// objects only, below the width.
	width := iommu.capability_address_width(unit.capability)
	unit.address_end = u64(1) << min(width, 63)
	unit.windows = width >= iommu.WINDOW_ADDRESS_WIDTH
	if !unit.windows {
		log("kernel: IOMMU: a unit translates ", u64(width), " bits of address, fewer than the ", u64(iommu.WINDOW_ADDRESS_WIDTH), " of the device windows: its devices get contiguous objects only")
	}
	return true
}

// remapping_units_start gives each unit of VT-d its queue of invalidations
// and its root table, forgets every cached entry, and turns translation on.
// A unit that does not turns each unit before it off again, with one line.
// round_trip_cycles: the global invalidation of the first unit.
@(private = "file")
remapping_units_start :: proc "contextless" () -> (started: bool, round_trip_cycles: u64) {
	for index in 0 ..< iommu_unit_count {
		unit := &iommu_units[index]
		// Each record of a fault before the start is free again, and the
		// next fault sends the fault event to the first processor.
		for record in 0 ..< unit.fault_count {
			register_write_32(unit, unit.fault_offset + record * 16 + 12, iommu.FAULT_CLEAR)
		}
		register_write_32(unit, iommu.REGISTER_FAULT_STATUS, iommu.FAULT_STATUS_CLEARED_AT_START)
		register_write_32(unit, iommu.REGISTER_FAULT_EVENT_DATA, VECTOR_IOMMU_FAULT)
		register_write_32(unit, iommu.REGISTER_FAULT_EVENT_ADDRESS, 0xFEE0_0000 | (processors[0].apic_id & 0xFF) << 12)
		register_write_32(unit, iommu.REGISTER_FAULT_EVENT_UPPER_ADDRESS, 0)
		register_write_32(unit, iommu.REGISTER_FAULT_EVENT_CONTROL, 0)
		// The queue first: the global invalidation below goes through it.
		register_write_64(unit, iommu.REGISTER_QUEUE_TAIL, iommu.queue_tail_register(0))
		register_write_64(unit, iommu.REGISTER_QUEUE_ADDRESS, iommu.queue_address_register(unit.queue))
		unit_started := global_set(unit, iommu.GLOBAL_QUEUED_INVALIDATION)
		if unit_started {
			register_write_64(unit, iommu.REGISTER_ROOT_TABLE, unit.root)
			unit_started = global_set(unit, iommu.GLOBAL_ROOT_TABLE)
		}
		if unit_started {
			global: Descriptor_Batch
			batch_add(&global, iommu.descriptor_context(0, true))
			batch_add(&global, iommu.descriptor_iotlb(0, true))
			before := cycles_now()
			invalidate_unit(unit, global)
			if index == 0 {
				round_trip_cycles = cycles_now() - before
			}
			unit_started = global_set(unit, iommu.GLOBAL_TRANSLATION)
		}
		if !unit_started {
			// A machine with a part of its units on would let a device of
			// a unit that is off write the tables of the others.
			for &before in iommu_units[:index + 1] {
				translation_off(&before)
			}
			log("kernel: no IOMMU in use: a unit did not take its queue or its root table, or did not turn translation on; each device reaches all memory")
			return false, 0
		}
	}
	return true, round_trip_cycles
}

// interrupt_remapping_start turns interrupt remapping on in each unit,
// with the empty interrupt table: from then on, a device sends only the
// message interrupts whose entry names it, and the units block each message
// in the compatible form (the bit CFI stays 0). A unit that does not take
// the table or does not turn remapping on turns it off again in each unit
// before it: remapping is on in every unit or in none. Translation stays
// on.
@(private = "file")
interrupt_remapping_start :: proc "contextless" () {
	for index in 0 ..< iommu_unit_count {
		unit := &iommu_units[index]
		register_write_64(unit, iommu.REGISTER_INTERRUPT_TABLE, iommu.interrupt_table_register(iommu_interrupt_table))
		started := global_set(unit, iommu.GLOBAL_INTERRUPT_TABLE)
		if started {
			global: Descriptor_Batch
			batch_add(&global, iommu.descriptor_interrupt_entry(0, true))
			invalidate_unit(unit, global)
			started = global_set(unit, iommu.GLOBAL_INTERRUPT_REMAPPING)
		}
		if !started {
			for &before in iommu_units[:index + 1] {
				interrupt_remapping_off(&before)
			}
			log("kernel: IOMMU: no interrupt remapping: a unit did not take its interrupt table or did not turn remapping on; a device can send any interrupt")
			return
		}
	}
	iommu_interrupt_remapping = true
	log("kernel: IOMMU: interrupt remapping on: a device sends only the message interrupts that its service was given")
}

// interrupt_remapping_off turns the interrupt remapping of a unit off, and
// waits until the status shows it.
@(private = "file")
interrupt_remapping_off :: proc "contextless" (unit: ^Iommu_Unit) {
	status := register_read_32(unit, iommu.REGISTER_GLOBAL_STATUS)
	register_write_32(unit, iommu.REGISTER_GLOBAL_COMMAND, iommu.global_command(status, 0) &~ iommu.GLOBAL_INTERRUPT_REMAPPING)
	bound := wait_bound()
	for register_read_32(unit, iommu.REGISTER_GLOBAL_STATUS) & iommu.GLOBAL_INTERRUPT_REMAPPING != 0 {
		if !wait_turn(bound) {
			// The unit still remaps with the empty table: every message
			// interrupt of its devices is refused.
			log("kernel: IOMMU: a unit did not turn interrupt remapping off: the message interrupts of its devices are refused")
			return
		}
	}
}

// iommu_owns_range says if a range of physical addresses meets the
// registers of a unit, the configuration memory of the buses, or a
// reserved memory range: the kernel owns the first two while the IOMMU is
// in use, so Device_Create gives neither to a process, which could turn
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
		if meets(start, end, unit.register_base, unit.register_size) {
			return true
		}
	}
	for reserved in iommu_reserved_ranges[:iommu_reserved_range_count] {
		if meets(start, end, reserved.start, reserved.end - reserved.start) {
			return true
		}
	}
	return meets(start, end, iommu_configuration, iommu_configuration_size)
}

// iommu_requester_of gives 1 + the requester that the unit sees for the
// accesses of the function whose memory base address register starts at
// this physical address: the device of a memory object that Device_Create
// makes over its registers. 0: none, no IOMMU in use, or a device that gets
// no domain, with one line that says why. Behind a conventional bridge it is
// the shared requester of the bridge, and bridge_function is 1 + the
// requester of the function itself: the domain of the shared requester is
// made only for a service that holds the registers of each function that
// shares it (iommu_declare). It walks the buses through bridges, and writes
// nothing: the root service owns the bus.
iommu_requester_of :: proc "contextless" (physical: u64) -> (requester: u32, bridge_function: u32) {
	if !iommu_in_use {
		return 0, 0
	}
	walk := Bus_Walk{physical = physical}
	buses_walk(&walk)
	if !walk.found {
		return 0, 0
	}
	function_requester := walk.requester
	bus, device, function := u64(iommu.requester_bus(function_requester)), u64(iommu.requester_device(function_requester)), u64(iommu.requester_function(function_requester))
	// The requester that the unit sees: behind a conventional bridge, the
	// one that each device there shares.
	seen := walk.behind_conventional_bridge ? walk.shared_requester : function_requester
	unit, covered := unit_of(seen)
	// A function that no unit covers gives its accesses past the units: a
	// domain would isolate nothing. Such a device can write every page, the
	// tables of the units too, so it ends the isolation of each device: the
	// log says so.
	if !covered {
		log("kernel: IOMMU: the device at bus ", bus, ", device ", device, ", function ", function, " is not behind a unit: it reaches all memory, the tables of the units too, and no device is isolated from it")
		return 0, 0
	}
	if walk.behind_conventional_bridge {
		// The table of AMD-Vi names the devices behind such a bridge by an
		// alias to the shared requester. An alias to another requester
		// means that the table and the bus disagree on what the unit sees.
		if !requester_alias_agrees(function_requester, seen) || !requester_alias_agrees(seen, seen) {
			log("kernel: IOMMU: the device at bus ", bus, ", device ", device, ", function ", function, " is behind a conventional bridge, and the I/O virtualization table gives its accesses another requester than the bridge does: it gets no domain, and each of its accesses is refused")
			return 0, 0
		}
		// An alias to the shared requester from a device outside the bridge
		// would put that device in the domain of the group.
		if !shared_alias_sources_behind(seen) {
			log("kernel: IOMMU: the device at bus ", bus, ", device ", device, ", function ", function, " is behind a conventional bridge, and the I/O virtualization table gives the requester of the bridge to a device outside it: it gets no domain, and each of its accesses is refused")
			return 0, 0
		}
	} else if requester_aliased(function_requester) {
		// An alias of the table of AMD-Vi that no conventional bridge
		// explains makes two requesters one: a domain of the source or of
		// the target would let the other device reach what its service
		// declared.
		log("kernel: IOMMU: the device at bus ", bus, ", device ", device, ", function ", function, " shares its requester with another device through an alias of the I/O virtualization table: it gets no domain, and each of its accesses is refused")
		return 0, 0
	}
	if !bus_translated(unit, iommu.requester_bus(seen)) {
		log("kernel: IOMMU: the device at bus ", bus, ", device ", device, ", function ", function, " is on a bus that the kernel did not find at its start: it gets no domain, and each of its accesses is refused")
		return 0, 0
	}
	if walk.behind_conventional_bridge {
		return 1 + u32(seen), 1 + u32(function_requester)
	}
	return 1 + u32(seen), 0
}

// iommu_bridge_function_made follows Device_Create of the registers of a
// function behind a conventional bridge, after the handle is in the caller.
// When a domain of its shared requester lives and the owner does not hold
// that function, the check of the group did not count it: it appeared
// behind the bridge after the check, and it would reach what the owner
// declared, so the domain ends. A process gets the registers of a function
// only through Device_Create, so each function of a group passes here
// before a process can drive it. The caller holds the control lock, under
// which no hold of a function of a group ends and no domain of a shared
// requester is made or ends. A hold can still be added without it (the
// owner maps its own handle, or gives it to itself), and that only makes the
// owner hold what it held: the read of the holds of the owner with no lock
// of the owner is then right. The frame lock orders the end of the domain
// with the declarations of the owner, which make it again only after a
// check.
iommu_bridge_function_made :: proc "contextless" (region_index: u32) {
	region := &regions[region_index]
	if !iommu_in_use || region.bridge_function == 0 {
		return
	}
	ended: u32
	{
		lock_take(&frame_lock, .Frame)
		defer lock_free(&frame_lock, .Frame)
		for &device, slot in iommu_devices {
			owner := intrinsics.atomic_load(&device.owner)
			if owner == 0 || u32(device.requester) + 1 != region.requester || device.owner_serial != processes[owner].serial {
				continue
			}
			if registers_held(&processes[owner], region.requester, region.bridge_function, nil, nil) {
				continue
			}
			function := u16(region.bridge_function - 1)
			shared := device.requester
			log("kernel: IOMMU: the device at bus ", u64(iommu.requester_bus(function)), ", device ", u64(iommu.requester_device(function)), ", function ", u64(iommu.requester_function(function)), " behind the conventional bridge of the requester at bus ", u64(iommu.requester_bus(shared)), ", device ", u64(iommu.requester_device(shared)), ", function ", u64(iommu.requester_function(shared)), " was not counted when its domain was made: the domain of the service ", process_name(&processes[owner]), " ends")
			domains_end(owner, 1 << u32(slot))
			ended |= 1 << u32(slot)
		}
	}
	domains_ended(ended)
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

// Each message interrupt has its entry in the table: an index past the
// table would be refused by the unit for every device.
#assert(op.MESSAGE_CAPACITY <= iommu.INTERRUPT_TABLE_ENTRIES)

// iommu_message_bind gives a message interrupt (its index from 0 among the
// message interrupts) to the device whose memory base address register
// starts at physical: Device_Create of the kind Message. It gives the
// address and the value that the device writes. With remapping in use, the
// interrupt entry of the index names that device: on VT-d the entry of the
// one table, with the requester, and the address is the remappable form of
// the index; on AMD-Vi an entry of the table of the device, and the value
// is the index. With no remapping in use, or for a device that gets no
// requester (iommu_requester_of writes why), it gives the compatible form
// of the first processor: a unit that covers such a device refuses it, as
// it refuses its memory accesses, and a device that no unit covers sends it
// past the units. The caller holds the control lock, which orders the
// message interrupts and their entries.
//
// Behind a conventional bridge, the entry names the shared requester, which
// each device of the group can send: it is present only while a domain of
// that requester lives, which the check of the group made, and while its
// owner holds the interrupt (group_messages_follow). Device_Create records
// the binding, and writes the entry only when that holds already.
iommu_message_bind :: proc "contextless" (index: u32, physical: u64) -> (address: u64, value: u64) {
	vector := u64(VECTOR_MESSAGE_BASE) + u64(index)
	compatible := 0xFEE0_0000 | u64(processors[0].apic_id & 0xFF) << 12
	if !iommu_interrupt_remapping {
		return compatible, vector
	}
	requester, bridge_function := iommu_requester_of(physical)
	if requester == 0 {
		return compatible, vector
	}
	if bridge_function != 0 {
		iommu_message_shared[index] = requester
		iommu_message_live[index] = message_entry_due(index) && message_entry_write(index, u16(requester - 1))
	} else if !message_entry_write(index, u16(requester - 1)) {
		return compatible, vector
	}
	if iommu_vendor == .Amd {
		return iommu.amd_message_address(u8(processors[0].apic_id & 0xFF)), u64(index)
	}
	return iommu.message_address(u16(index)), 0
}

// The message interrupts bound to a shared requester, by index: 1 + that
// requester, or 0 for a message interrupt of another device. Control lock.
iommu_message_shared: [op.MESSAGE_CAPACITY]u32
// The entry of such a message interrupt is present: a domain of its shared
// requester lives. Control lock.
iommu_message_live: [op.MESSAGE_CAPACITY]bool

// message_entry_write makes the interrupt entry of a message interrupt
// present for a requester, and invalidates it: on VT-d the entry of the one
// table, on AMD-Vi an entry of the table of the requester. false: no free
// table of AMD-Vi, which the count of the message interrupts excludes. The
// caller holds the control lock, and not the frame lock, which the
// invalidation takes.
@(private = "file")
message_entry_write :: proc "contextless" (index: u32, requester: u16) -> bool {
	if iommu_vendor == .Amd {
		return amd_message_bind(index, requester)
	}
	vector := u64(VECTOR_MESSAGE_BASE) + u64(index)
	entry := direct(iommu_interrupt_table + u64(index) * iommu.INTERRUPT_ENTRY_SIZE, [2]u64)
	words := iommu.interrupt_entry(u8(vector), u8(processors[0].apic_id & 0xFF), requester)
	// The second word first: a unit reads an entry whose first word is
	// present as whole.
	intrinsics.volatile_store(&entry[1], words[1])
	intrinsics.volatile_store(&entry[0], words[0])
	write_back(physical_of(entry), iommu.INTERRUPT_ENTRY_SIZE)
	interrupt_entry_invalidate(index)
	return true
}

// message_entry_clear clears the interrupt entry of a message interrupt,
// and invalidates it. An entry that was never written stays as it is. The
// caller holds the control lock, and not the frame lock.
@(private = "file")
message_entry_clear :: proc "contextless" (index: u32) {
	if iommu_vendor == .Amd {
		amd_message_end(index)
		return
	}
	entry := direct(iommu_interrupt_table + u64(index) * iommu.INTERRUPT_ENTRY_SIZE, [2]u64)
	if intrinsics.volatile_load(&entry[0]) == 0 {
		return // The entry was never bound: a device with no requester.
	}
	intrinsics.volatile_store(&entry[0], 0)
	intrinsics.volatile_store(&entry[1], 0)
	write_back(physical_of(entry), iommu.INTERRUPT_ENTRY_SIZE)
	interrupt_entry_invalidate(index)
}

// iommu_message_end clears the interrupt entry of a message interrupt
// whose last handle closed, before the index can be given again: the old
// device then sends nothing at that index. handle_close calls it with the
// control lock.
iommu_message_end :: proc "contextless" (index: u32) {
	if !iommu_interrupt_remapping {
		return
	}
	group, live := iommu_message_shared[index] != 0, iommu_message_live[index]
	iommu_message_shared[index], iommu_message_live[index] = 0, false
	if group && !live {
		return // The entry of a group with no domain was never written.
	}
	message_entry_clear(index)
}

// shared_domain_owner gives the process that owns the domain of a shared
// requester (1 + it), or 0 when none lives: the check of its group made
// it, and its owner still holds each function of the group. The caller
// holds the control lock, under which the domain of a shared requester is
// made and ends.
@(private = "file")
shared_domain_owner :: proc "contextless" (requester: u32) -> u32 {
	for &device in iommu_devices {
		owner := intrinsics.atomic_load(&device.owner)
		if owner != 0 && device.present && u32(device.requester) + 1 == requester && device.owner_serial == processes[owner].serial {
			return owner
		}
	}
	return 0
}

// message_entry_due says if the entry of a message interrupt of a shared
// requester must be present: a domain of that requester lives, and its
// owner is the process that holds the interrupt (interrupt_owner). Else a
// service that let one device of the group go, and kept its interrupts,
// would get them back when another service takes the group. The caller
// holds the control lock, under which interrupt_owner changes.
@(private = "file")
message_entry_due :: proc "contextless" (index: u32) -> bool {
	owner := shared_domain_owner(iommu_message_shared[index])
	return owner != 0 && owner == intrinsics.atomic_load(&interrupt_owner[INTERRUPT_LINES + index])
}

// iommu_interrupt_owner_changed follows a change of the process that holds
// a message interrupt (handle_insert, handle_close, handle_insert_undo):
// the entry of a message interrupt of a shared requester follows that
// process (message_entry_due). The caller holds the control lock, as for
// each handle of an interrupt, and not the frame lock.
iommu_interrupt_owner_changed :: proc "contextless" (object: u32) {
	if !iommu_in_use || object < INTERRUPT_LINES || iommu_message_shared[object - INTERRUPT_LINES] == 0 {
		return
	}
	group_messages_follow()
}

// group_messages_follow makes the interrupt entry of each message
// interrupt of a shared requester present while message_entry_due holds,
// and clears it when it does not: a device of the group then sends the
// message interrupts of the group only to the service that holds each
// function of the group. The caller holds the control lock, and not the
// frame lock, which each invalidation takes.
@(private = "file")
group_messages_follow :: proc "contextless" () {
	if !iommu_interrupt_remapping {
		return
	}
	for index in u32(0) ..< op.MESSAGE_CAPACITY {
		requester := iommu_message_shared[index]
		if requester == 0 {
			continue
		}
		lives := message_entry_due(index)
		switch {
		case lives && !iommu_message_live[index]:
			iommu_message_live[index] = message_entry_write(index, u16(requester - 1))
		case !lives && iommu_message_live[index]:
			message_entry_clear(index)
			iommu_message_live[index] = false
		}
	}
}

// interrupt_entry_invalidate makes each unit forget the interrupt entry of
// an index. Each unit, because one table serves all: a unit that kept the
// old entry would let the old device send the vector of the next owner.
// It takes the frame lock, which orders the queues.
@(private = "file")
interrupt_entry_invalidate :: proc "contextless" (index: u32) {
	batch: Descriptor_Batch
	batch_add(&batch, iommu.descriptor_interrupt_entry(u16(index)))
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	for &unit in iommu_units[:iommu_unit_count] {
		invalidate_unit(&unit, batch)
	}
}

// owned_devices gives a bit for each device slot whose domain this
// process owns. The caller holds the frame lock, or the process lock of
// this process: only its own declarations, under that lock, make it an
// owner, and its own paths end its domains, except one: a function behind
// a conventional bridge that appears after the check ends the domain of
// its group under the control and the frame locks only
// (iommu_bridge_function_made). The frame loop of declare checks the
// owner of each slot again for that.
@(private = "file")
owned_devices :: proc "contextless" (process_index: u32) -> (owned: u32) {
	serial := processes[process_index].serial
	for &device, slot in iommu_devices {
		if intrinsics.atomic_load(&device.owner) == process_index && device.owner_serial == serial {
			owned |= 1 << u32(slot)
		}
	}
	return owned
}

// owned_of gives the slots that a process owns for one requester (1 + the
// identifier, as a memory object keeps it). The caller holds the frame
// lock, or the process lock of this process, as for owned_devices: under
// that lock the slots of the process change only by the one exception that
// owned_devices names (iommu_bridge_function_made, under the control and
// the frame locks), which the frame loop of declare checks again.
@(private = "file")
owned_of :: proc "contextless" (process_index: u32, requester: u32) -> (owned: u32) {
	all := owned_devices(process_index)
	for slot in u32(0) ..< IOMMU_DEVICE_CAPACITY {
		if all & (1 << slot) != 0 && u32(iommu_devices[slot].requester) + 1 == requester {
			owned |= 1 << slot
		}
	}
	return owned
}

// device_slot gives the slot of the domain of a requester for a process:
// the slot that the process owns, or a free slot, which the process owns
// only after its first declaration. Bad_State: another process owns it.
// The caller holds the frame lock.
@(private = "file")
device_slot :: proc "contextless" (requester: u16, process_index: u32) -> (slot: u32, status: Operation_Outcome) {
	free := u32(IOMMU_DEVICE_CAPACITY)
	for &device, index in iommu_devices {
		if device.owner == 0 {
			if free == IOMMU_DEVICE_CAPACITY {
				free = u32(index)
			}
			continue
		}
		if device.requester == requester {
			if device.owner != process_index || device.owner_serial != processes[process_index].serial {
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

// The entries of the page tables of a domain, in the format of the vendor.
// The walk of the levels is the same for both: 3 or 4 levels of 512
// entries, with the address in the bits 51:12.

// entry_present says if an entry of a table of a domain names a page or a
// table.
@(private = "file")
entry_present :: proc "contextless" (entry: u64) -> bool {
	present: bool
	switch iommu_vendor {
	case .Intel:
		present = iommu.entry_present(entry)
	case .Amd:
		present = iommu.amd_entry_present(entry)
	}
	return present
}

// table_entry_of gives the entry that names a table of a level.
@(private = "file")
table_entry_of :: proc "contextless" (table: u64, level: u32) -> u64 {
	entry: u64
	switch iommu_vendor {
	case .Intel:
		entry = iommu.table_entry(table)
	case .Amd:
		entry = iommu.amd_table_entry(table, level)
	}
	return entry
}

// page_entry_of gives the entry of a page that a device reads, and writes
// only when writable.
@(private = "file")
page_entry_of :: proc "contextless" (address: u64, writable: bool) -> u64 {
	entry: u64
	switch iommu_vendor {
	case .Intel:
		entry = iommu.page_entry(address, writable)
	case .Amd:
		entry = iommu.amd_page_entry(address, writable)
	}
	return entry
}

// entry_write_bit gives the bit of the write in the entry of a page.
@(private = "file")
entry_write_bit :: proc "contextless" () -> u64 {
	return iommu_vendor == .Amd ? iommu.AMD_ENTRY_WRITE : iommu.ENTRY_WRITE
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
		if !entry_present(entry^) {
			if !create_missing {
				return nil
			}
			child := table_take(budget)
			if child == 0 {
				return nil
			}
			entry^ = table_entry_of(child, level - 1)
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
		write_bit := entry_write_bit()
		for offset in 0 ..< run {
			entry := &leaf[index + offset]
			switch change {
			case .Map:
				// Each page of the object has its frame: the declaration gave
				// it before the frame lock.
				frame := frames != nil ? region_frame(frames, page + offset, false) : address + offset * PAGE_SIZE
				entry^ = page_entry_of(frame, writable)
			case .Clear:
				entry^ = 0
			case .Allow_Write:
				if entry_present(entry^) {
					entry^ |= write_bit
				}
			case .Deny_Write:
				entry^ &~= write_bit // An entry that is not present stays 0.
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
			if entry_present(entry) {
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
// writable: the handle of the call has Write; write_held: the process
// still holds a handle to the object with Write after this call, so a
// device keeps the write only while it holds one. made: the context entry
// of the domain became present. The caller holds the frame lock, and
// invalidates after it by what changed.
@(private = "file")
declare_to_device :: proc "contextless" (process_index: u32, requester: u16, slot: u32, region_index: u32, writable: bool, write_held: bool) -> (change: Declaration_Change, made: bool, status: Operation_Outcome) {
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
	budget := &processes[process_index].budget
	new_domain := device.owner == 0
	if new_domain {
		// Device_Create gave the requester only for a device that a unit
		// covers, on a bus with the entries of the unit.
		unit, covered := unit_of(requester)
		if !covered || !bus_translated(unit, iommu.requester_bus(requester)) {
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
		device.owner_serial = processes[process_index].serial
		intrinsics.atomic_store(&device.owner, process_index)
		// A device of a reserved range moves from its standing domain: the
		// entry is cleared and the standing domain forgotten first, so the
		// unit never reads an entry with half of each.
		if standing, standing_domain := standing_of(requester); standing != nil {
			device_entry_write(device.unit, requester, false)
			invalidate_unit(&iommu_units[device.unit], domain_batch(standing_domain, true, standing_domain, requester))
		}
		device_entry_write(device.unit, requester, true, device.top, u16(slot + 1))
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

// holds_with gives whether the process holds another handle to a memory
// object than except (nil: any), and whether one of those has Write. The
// caller holds the process lock.
@(private = "file")
holds_with :: proc "contextless" (process: ^Process, region_index: u32, except: ^Handle_Slot) -> (holds: bool, writes: bool) {
	for &other in process.handles {
		if &other != except && other.kind == .Memory && other.object == region_index {
			holds = true
			writes ||= .Write in other.rights
		}
	}
	return holds, writes
}

// registers_held says if a process holds a handle or a mapping of the
// registers of a function (1 + the requester of its domain, and its
// bridge_function as a memory object keeps it), other than the handle and
// the mapping that end. A mapping of the registers drives the device as a
// handle does, so it keeps the domain. Behind a conventional bridge, each
// function that shares the requester counts apart: the domain lives only
// while its owner holds every one of them. The caller holds the process
// lock.
@(private = "file")
registers_held :: proc "contextless" (process: ^Process, requester: u32, bridge_function: u32, closed: ^Handle_Slot, unmapped: ^Mapping) -> bool {
	for &other in process.handles {
		if &other != closed && other.kind == .Memory && regions[other.object].requester == requester && regions[other.object].bridge_function == bridge_function {
			return true
		}
	}
	for &mapping in process.mappings {
		if &mapping != unmapped && mapping.page_count != 0 && regions[mapping.region].requester == requester && regions[mapping.region].bridge_function == bridge_function {
			return true
		}
	}
	return false
}

// shares_requester says if a process holds registers behind a conventional
// bridge whose shared requester is this one (1 + it). The caller holds the
// process lock.
@(private = "file")
shares_requester :: proc "contextless" (process: ^Process, requester: u32) -> bool {
	for &other in process.handles {
		if other.kind == .Memory && regions[other.object].requester == requester && regions[other.object].bridge_function != 0 {
			return true
		}
	}
	return false
}

// The last device whose refusal of a domain behind a conventional bridge
// the log has (1 + its requester): a service that declares in a loop with
// the same missing device writes one line. Atomic.
iommu_bridge_refusal_last: u32

// bridge_domain_check walks the bus to the functions that share a
// requester (1 + it) behind a conventional bridge, before the first
// declaration of its domain: a service that does not hold the registers of
// each of them gets Bad_State, with one line, as the device that it misses
// would reach what it declares. member_count: the functions of the group.
// The caller holds the process lock; the walk reads the bus with no lock.
@(private = "file")
bridge_domain_check :: proc "contextless" (process: ^Process, requester: u32) -> (member_count: u32, status: Operation_Outcome) {
	walk := Bus_Walk{group = requester, holder = process}
	buses_walk(&walk)
	if !walk.unheld && walk.member_count != 0 {
		return walk.member_count, .Ok
	}
	if !walk.unheld {
		return 0, .Bad_State // The root service numbered the bus again: no function shares it now.
	}
	if intrinsics.atomic_exchange(&iommu_bridge_refusal_last, 1 + u32(walk.unheld_requester)) == 1 + u32(walk.unheld_requester) {
		return 0, .Bad_State
	}
	shared := u16(requester - 1)
	if walk.odd_bridge {
		log("kernel: IOMMU: the bridge at bus ", u64(iommu.requester_bus(walk.unheld_requester)), ", device ", u64(iommu.requester_device(walk.unheld_requester)), ", function ", u64(iommu.requester_function(walk.unheld_requester)), ", behind the conventional bridge of the requester at bus ", u64(iommu.requester_bus(shared)), ", device ", u64(iommu.requester_device(shared)), ", function ", u64(iommu.requester_function(shared)), ", has a secondary bus that the walk cannot follow: the declaration is refused, and the devices behind it get no domain")
	} else {
		log("kernel: IOMMU: the service ", process_name(process), " does not hold the registers of the device at bus ", u64(iommu.requester_bus(walk.unheld_requester)), ", device ", u64(iommu.requester_device(walk.unheld_requester)), ", function ", u64(iommu.requester_function(walk.unheld_requester)), ", which shares the requester at bus ", u64(iommu.requester_bus(shared)), ", device ", u64(iommu.requester_device(shared)), ", function ", u64(iommu.requester_function(shared)), " behind a conventional bridge: the declaration is refused, and they get no domain")
	}
	return 0, .Bad_State
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

// new_entry_needs_invalidation says if a unit must forget an entry that
// became present: a page, or the entry of a device. A unit of VT-d with the
// caching mode can keep an entry that was not present, and another one
// keeps only present entries; a unit that asks for a flush of its write
// buffer needs it after an entry becomes present, and the invalidation
// makes that flush first. A unit of AMD-Vi keeps the device entries that it
// read, also an entry that refused: a new device entry (device_entry_made)
// is always invalidated. It keeps a page that was not present only with the
// flag NpCache of its capability header, which QEMU 10 sets.
@(private = "file")
new_entry_needs_invalidation :: proc "contextless" (unit: ^Iommu_Unit, device_entry_made: bool) -> bool {
	needed: bool
	switch iommu_vendor {
	case .Intel:
		needed = iommu.capability_caching_mode(unit.capability) || iommu.capability_write_buffer(unit.capability)
	case .Amd:
		needed = device_entry_made || unit.caches_not_present
	}
	return needed
}

// iommu_declare maps each page of a memory object in the domain of each
// device whose registers the process holds by a handle, and gives the
// device address of the object: Memory_Physical. A contiguous object has
// its physical address; another one has its window, where its pages follow
// each other, and each of its pages gets its frame now. The device writes
// the pages only when writable: the handle of the call has the right
// Write. A process that holds no such handle declares nothing, and gets the
// physical address of a contiguous object only. Device memory is not
// declared: a device reaches no registers of a device. Either every device
// of the call gets the object, or none that did not have it before, and
// none gets a write that it did not have. A device keeps the write only
// while the process holds a handle with Write. The invalidation runs only
// when a domain changed, for that domain. The caller holds the process
// lock. The domain of a shared requester is made under the control lock:
// the call asks for it (Needs_Control), and after the frame lock the message
// interrupts of the groups follow their domains (group_messages_follow).
// They follow whatever the status: a call that fails after it made the
// domain of a shared requester for an earlier device of the call keeps that
// domain, and its interrupts then come with it.
iommu_declare :: proc "contextless" (process_index: u32, region_index: u32, writable: bool) -> (address: u64, status: Operation_Outcome) {
	address, status = declare(process_index, region_index, writable)
	if lock_held(.Control) {
		group_messages_follow()
	}
	return address, status
}

// declare is iommu_declare up to the end of the frame lock.
@(private = "file")
declare :: proc "contextless" (process_index: u32, region_index: u32, writable: bool) -> (address: u64, status: Operation_Outcome) {
	region := &regions[region_index]
	if !iommu_in_use || region.device {
		if !region.contiguous {
			return 0, .Bad_Operation // Its frames come at first use, from anywhere: no one address names them.
		}
		return region.physical, .Ok
	}
	process := &processes[process_index]
	requesters: [IOMMU_DEVICES_OF_A_SERVICE]u32
	count := 0
	for slot in process.handles {
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
	// The devices behind a conventional bridge share one requester, so one
	// domain: it is made only for a service that holds the registers of
	// each of them. The walk of the bus runs before the first declaration of
	// the domain only: the end of the domain at the end of any one hold
	// keeps the rule true after it. The domain is made under the control
	// lock, under which no hold of a function of the group and no domain of
	// a shared requester changes.
	member_counts: [IOMMU_DEVICES_OF_A_SERVICE]u32
	shared_requesters: u32 // A bit for each requester of the call that is shared.
	for requester, index in requesters[:count] {
		if !shares_requester(process, requester) {
			continue
		}
		shared_requesters |= 1 << u32(index)
		if owned_of(process_index, requester) != 0 {
			continue
		}
		if require_control() == .Needs_Control {
			return 0, .Needs_Control
		}
		members, check_status := bridge_domain_check(process, requester)
		if check_status != .Ok {
			return 0, check_status
		}
		member_counts[index] = members
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
	_, write_held := holds_with(process, region_index, nil)
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	added, write_allowed, changed, made: u32
	status = .Ok
	for requester, index in requesters[:count] {
		slot: u32
		slot, status = device_slot(u16(requester - 1), process_index)
		if status != .Ok {
			break
		}
		// A domain of a shared requester that this call did not check: its
		// owner held it at the check above, and another path ended it since
		// (a function that appeared behind the bridge). It is made again
		// only after a check, under the control lock.
		if iommu_devices[slot].owner == 0 && shared_requesters & (1 << u32(index)) != 0 && member_counts[index] == 0 {
			// With the control lock the domain is gone: a state that the
			// call cannot change.
			status = require_control()
			if status == .Ok {
				status = .Bad_State
			}
			break
		}
		change: Declaration_Change
		entry_made: bool
		change, entry_made, status = declare_to_device(process_index, u16(requester - 1), slot, region_index, writable, write_held)
		if entry_made {
			made |= 1 << slot
		}
		unit := &iommu_units[iommu_devices[slot].unit]
		switch change {
		case .None:
		case .Mapped:
			added |= 1 << slot
			if new_entry_needs_invalidation(unit, entry_made) {
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
	for members, index in member_counts[:count] {
		if members == 0 {
			continue
		}
		// The next refusal of a device behind a bridge has its line again.
		intrinsics.atomic_store(&iommu_bridge_refusal_last, 0)
		shared := u16(requesters[index] - 1)
		log("kernel: IOMMU: the service ", process_name(process), " holds the registers of each of the ", u64(members), " devices that share the requester at bus ", u64(iommu.requester_bus(shared)), ", device ", u64(iommu.requester_device(shared)), ", function ", u64(iommu.requester_function(shared)), " behind a conventional bridge: they have one domain")
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
// - the last handle of the process to a declared object: the object leaves
//   each domain of the process;
// - the last handle with Write: the pages of the object become read-only in
//   each domain of the process;
// - the last handle to the registers of a device, with no mapping of them
//   left: the domain of that device ends, so a device given to another
//   service reaches nothing of this one. Behind a conventional bridge, the
//   last hold of any one device that shares the requester ends the domain
//   of all of them.
//
// Each change is invalidated before the close returns. handle_close calls
// it with the process lock of the process, before the release of the
// object. A handle of an object that is not declared and is no registers
// costs two loads.
iommu_handle_closed :: proc "contextless" (process: ^Process, closed: ^Handle_Slot) {
	if !iommu_in_use {
		return
	}
	region := &regions[closed.object]
	requester := region.requester
	if intrinsics.atomic_load(&region.declared) == 0 && requester == 0 {
		return
	}
	if region.bridge_function != 0 && !lock_held(.Control) {
		bridge_control_missing()
	}
	holds, writes := holds_with(process, closed.object, closed)
	held := requester == 0 || registers_held(process, requester, region.bridge_function, closed, nil)
	process_index := index_of_process(process)
	ended: u32
	{
		lock_take(&frame_lock, .Frame)
		defer lock_free(&frame_lock, .Frame)
		owned := owned_devices(process_index)
		changed: u32
		switch {
		case !holds:
			changed = region_end_for(closed.object, owned)
		case !writes:
			changed = write_deny_for(closed.object, owned)
		}
		if !held {
			ended = owned_of(process_index, requester)
			if ended != 0 {
				// It invalidates each ended domain; the others changed above.
				domains_end(process_index, ended)
				changed &~= ended
			}
		}
		invalidate_slots(changed, 0)
	}
	domains_ended(ended)
}

// iommu_mapping_ended follows the end of a mapping: the last mapping of the
// registers of a device, when the process holds no handle of them either,
// ends the domain of that device. unmap calls it with the process lock,
// before the release of the object. A mapping of an object that is no
// registers costs two loads.
iommu_mapping_ended :: proc "contextless" (process: ^Process, mapping: ^Mapping) {
	if !iommu_in_use {
		return
	}
	requester := regions[mapping.region].requester
	if regions[mapping.region].bridge_function != 0 && !lock_held(.Control) {
		bridge_control_missing()
	}
	if requester == 0 || registers_held(process, requester, regions[mapping.region].bridge_function, nil, mapping) {
		return
	}
	process_index := index_of_process(process)
	ended: u32
	{
		lock_take(&frame_lock, .Frame)
		defer lock_free(&frame_lock, .Frame)
		ended = owned_of(process_index, requester)
		if ended != 0 {
			domains_end(process_index, ended)
		}
	}
	domains_ended(ended)
}

// iommu_process_end ends each domain that a process owns.
// process_cleanup calls it before the handles and the mappings of the
// process end, with the control lock.
iommu_process_end :: proc "contextless" (process_index: u32) {
	if !iommu_in_use {
		return
	}
	ended: u32
	{
		lock_take(&frame_lock, .Frame)
		defer lock_free(&frame_lock, .Frame)
		ended = owned_devices(process_index)
		if ended != 0 {
			domains_end(process_index, ended)
		}
	}
	domains_ended(ended)
}

// domains_ended follows the end of the domains of a mask of slots, after
// the frame lock: the message interrupts of a shared requester whose
// domain ended lose their entries (group_messages_follow). The end of the
// domain of a shared requester holds the control lock: the close of a
// handle and the unmap of a mapping of the registers of a function behind a
// conventional bridge ask for it (enter.odin), and the revocation and the
// end of a process hold it. The end of the domain of another device needs
// no follow, and may come with no control lock: then no present entry of a
// group may have lost its domain, else the kernel has a fault
// (bridge_control_missing).
@(private = "file")
domains_ended :: proc "contextless" (ended: u32) {
	if ended == 0 {
		return
	}
	if lock_held(.Control) {
		group_messages_follow()
		return
	}
	for index in u32(0) ..< op.MESSAGE_CAPACITY {
		if iommu_message_live[index] && shared_domain_owner(iommu_message_shared[index]) == 0 {
			bridge_control_missing()
		}
	}
}

// bridge_control_missing stops the machine: a path of the kernel ends the
// hold of the registers of a function behind a conventional bridge, or the
// domain of its group, with no control lock. The interrupt entries of the
// group would then outlive its domain, with no line: a fault of the kernel,
// as a broken lock order.
@(private = "file")
bridge_control_missing :: proc "contextless" () -> ! {
	fault_report_begin()
	log("kernel: IOMMU: the hold of the registers of a function behind a conventional bridge, or the domain of its group, ends with no control lock: the machine stops")
	machine_stop(.Invariant_Broken)
}

// domains_end ends the domains of the device slots of a mask, which a
// process owns: their context entries, their bits in each memory object,
// the invalidation of each domain, then their tables, whose pages return
// to the budget of the process, and the slots are free. A device of a
// reserved range goes back to its standing domain. The caller holds the
// frame lock.
@(private = "file")
domains_end :: proc "contextless" (process_index: u32, owned: u32) {
	for slot in u32(0) ..< IOMMU_DEVICE_CAPACITY {
		if owned & (1 << slot) != 0 && iommu_devices[slot].present {
			device_entry_write(iommu_devices[slot].unit, iommu_devices[slot].requester, false)
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
	budget := processes[process_index].budget
	for slot in u32(0) ..< IOMMU_DEVICE_CAPACITY {
		if owned & (1 << slot) == 0 {
			continue
		}
		device := &iommu_devices[slot]
		unit := &iommu_units[device.unit]
		if standing, standing_domain := standing_of(device.requester); standing != nil {
			device_entry_write(device.unit, device.requester, true, standing.top, standing_domain)
			if new_entry_needs_invalidation(unit, true) {
				invalidate_unit(unit, domain_batch(standing_domain, true, 0, device.requester))
			}
		}
		budgets[budget].amounts.pages += tables_free(device.top, unit.levels)
		intrinsics.atomic_store(&device.owner, 0)
		device^ = {}
	}
}

// fault_count_of gives the place of the count of the faults of a requester:
// of its DMA faults, or of its refused interrupts.
@(private = "file")
fault_count_of :: proc "contextless" (requester: u16, interrupt: bool) -> ^u64 {
	counts := interrupt ? &iommu_interrupt_faults : &iommu_dma_faults
	return iommu.requester_bus(requester) == 0 ? &counts.of_bus_0[requester & 0xFF] : &counts.of_other_buses
}

// iommu_faults_take reads each fault that the units recorded, frees its
// record, counts it for its device, and writes the lines of the log that
// iommu.fault_line gives: a device that faults in a loop does not flood
// the log. It runs at the fault event, and at a tick of the first
// processor while records were left (iommu_faults_left), with no lock
// held: a DMA fault stops nothing. The records are the fault recording
// registers of VT-d, or the event log of AMD-Vi (amd_events_take). The
// name of the service is read with no lock: in a race with the end of the
// service, the line can name the process of the slot before or after.
iommu_faults_take :: proc "contextless" () {
	if !iommu_in_use {
		return
	}
	left: bool
	switch iommu_vendor {
	case .Intel:
		left = fault_records_take()
	case .Amd:
		left = amd_events_take()
	}
	intrinsics.atomic_store(&iommu_faults_left, left)
}

// fault_records_take reads the fault recording registers of each unit of
// VT-d. While a record holds a fault a unit sends no new fault event, so it
// reads the status of each unit again after each pass, and passes again
// while a record is pending, at most IOMMU_FAULT_PASSES times: with
// interrupts off, one call reads at most that many passes over the records
// of each unit (2 x 256 records for the largest unit). A record that is
// still pending after the last pass waits for the next tick, not for an
// event that would never come: left.
@(private = "file")
fault_records_take :: proc "contextless" () -> (left: bool) {
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
	return left
}

// fault_line_write counts one fault for its device and writes its line of
// the log, when iommu.fault_line gives one: a DMA fault, or a refused
// interrupt, each with its own count. A refused interrupt of VT-d names the
// entry; one of AMD-Vi names the address of the message, as its record has
// no entry.
@(private)
fault_line_write :: proc "contextless" (fault: iommu.Fault) {
	faults := intrinsics.atomic_add(fault_count_of(fault.requester, fault.interrupt), 1) + 1
	line := iommu.fault_line(faults)
	if line == .None {
		return
	}
	service := "no service"
	for &device in iommu_devices {
		if owner := intrinsics.atomic_load(&device.owner); owner != 0 && device.requester == fault.requester {
			service = process_name(&processes[owner])
		}
	}
	bus, device_number, function := u64(iommu.requester_bus(fault.requester)), u64(iommu.requester_device(fault.requester)), u64(iommu.requester_function(fault.requester))
	if fault.interrupt {
		if line == .Whole && iommu_vendor == .Amd {
			log("kernel: an interrupt of the device at bus ", bus, ", device ", device_number, ", function ", function, " (service ", service, ") is refused: a message to ", Hex(fault.address), "; reason ", Hex(u64(fault.reason)), "; refused interrupts of this device: ", faults)
		} else if line == .Whole {
			log("kernel: an interrupt of the device at bus ", bus, ", device ", device_number, ", function ", function, " (service ", service, ") is refused: entry ", u64(fault.index), "; reason ", Hex(u64(fault.reason)), "; refused interrupts of this device: ", faults)
		} else {
			log("kernel: refused interrupts of the device at bus ", bus, ", device ", device_number, ", function ", function, " (service ", service, "): ", faults, " in all; the log has the line of each of the first ", u64(iommu.FAULT_LINES), ", then this count at each power of two")
		}
		return
	}
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
