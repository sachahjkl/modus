package kernel

import "modus:contract/bridge_requester"
import "kernel:iommu"
import op "modus:contract/operation"
import "base:intrinsics"

// The IOMMU of AMD (AMD-Vi): the procedures of this vendor behind the side
// of the kernel that does not know the vendor (iommu.odin;
// src/md/infrastructure/iommu.md, "Two vendors behind one kernel side").
//
// One device table serves every unit: an entry of 32 bytes for each of the
// 65536 requesters. An entry of zeros passes every access, so the start
// writes each entry as valid, with translation through the empty table and
// neither read nor write: the empty domain refuses every access, as a
// context entry that is not present does on VT-d. The words of translation
// of an entry change under the frame lock, as the domains do; its word of
// interrupts changes under the control lock, as the message interrupts do:
// each is a store of 8 bytes, so the two never mix.

iommu_ivrs: iommu.Ivrs // The table IVRS as read at the start.
// The device table, and the empty table that the entry of each device with
// no domain names. Memory of the kernel, written at the start.
amd_device_table: u64
amd_empty_table: u64
// The buses that the walk at the start found: a device of another bus gets
// no domain, as on VT-d a bus with no context table.
amd_buses_found: [256]bool
// The interrupt tables: one page that holds one table for each device with
// a message interrupt. A device has a table while it has at least one
// message interrupt, so op.MESSAGE_CAPACITY tables are enough. They change
// under the control lock.
amd_interrupt_tables: u64
Amd_Interrupt_Table :: struct {
	requester: u16,
	entries:   u32, // The message interrupts of the device in the table. 0: a free table.
}
amd_interrupt_table_owners: [op.MESSAGE_CAPACITY]Amd_Interrupt_Table
// 1 + the table of each message interrupt. 0: none.
amd_message_tables: [op.MESSAGE_CAPACITY]u8
// The events of the units that are not a page fault, one count for each
// kind, so a storm of one kind that a device causes does not hide the line
// of an error of the unit; and the event logs that were full. Atomic.
amd_unit_events: [iommu.AMD_EVENT_KINDS]u64
amd_event_log_overflows: u64
// The reads of a record of the kind 0 before the kernel leaves it to the
// next tick: a unit can move its tail before the record is in memory.
AMD_EVENT_RECORD_READS :: 64

// Each message interrupt has its entry in the table of its device, and the
// value of a message is its index, whose bits 10:8 the unit reads as the
// kind of the delivery: 0, a fixed delivery.
#assert(op.MESSAGE_CAPACITY <= iommu.AMD_INTERRUPT_TABLE_ENTRIES)
#assert(op.MESSAGE_CAPACITY <= 256)
#assert(op.MESSAGE_CAPACITY * iommu.AMD_INTERRUPT_TABLE_SPACING <= PAGE_SIZE)

// amd_unit_check reads the registers of a unit of AMD-Vi, and refuses a
// unit that the kernel does not program, with one line.
amd_unit_check :: proc "contextless" (unit: ^Iommu_Unit, block: iommu.Amd_Unit) -> bool {
	requester := block.requester
	// A mode that the firmware left on: the kernel would take over a unit
	// that translates now, or that runs commands that the kernel did not
	// write.
	if register_read_64(unit, iommu.AMD_REGISTER_CONTROL) & iommu.AMD_CONTROL_LEFT_ON != 0 {
		log("kernel: no IOMMU in use: the firmware left a unit on; each device reaches all memory")
		return false
	}
	unit.extended = register_read_64(unit, iommu.AMD_REGISTER_EXTENDED_FEATURES)
	if !iommu.amd_extended_host_translation(unit.extended) {
		log("kernel: no IOMMU in use: a unit translates no address through the tables of the host; each device reaches all memory")
		return false
	}
	// The events of the unit come by the message interrupt of its own
	// function: a unit with none would hide each DMA fault until a tick.
	if iommu.requester_bus(requester) > iommu_last_bus || amd_message_capability(requester) == 0 {
		log("kernel: no IOMMU in use: the function of a unit has no message interrupt in the configuration memory; each device reaches all memory")
		return false
	}
	// The kernel turns on the message interrupt and the bus master bit of
	// this function: a table that names another function would make it
	// turn on a device of a service.
	bus, device, function := iommu.requester_bus(requester), iommu.requester_device(requester), iommu.requester_function(requester)
	if !iommu.amd_function_is_unit(configuration_read(bus, device, function, 8)) {
		log("kernel: no IOMMU in use: the I/O virtualization table names a function that is not an IOMMU as a unit; each device reaches all memory")
		return false
	}
	// A header at a place that is not one of the configuration words gives
	// true: each new entry is then invalidated, which is always right.
	unit.caches_not_present = true
	if place := u32(block.capability_offset); place >= 0x40 && place <= 0xFC && place % 4 == 0 {
		unit.caches_not_present = iommu.amd_caches_not_present(configuration_read(bus, device, function, place))
	}
	unit.requester = requester
	unit.levels = iommu.AMD_LEVELS
	unit.address_end = iommu.domain_address_end(iommu.AMD_LEVELS)
	unit.windows = true
	return true
}

// amd_message_capability gives the place of the capability of the message
// interrupt in the configuration of a function, or 0.
@(private = "file")
amd_message_capability :: proc "contextless" (requester: u16) -> u32 {
	bus, device, function := iommu.requester_bus(requester), iommu.requester_device(requester), iommu.requester_function(requester)
	configuration: [bridge_requester.CONFIGURATION_WORDS]u32
	for &word, index in configuration {
		word = configuration_read(bus, device, function, u32(index) * 4)
	}
	return iommu.capability_offset(&configuration, iommu.CAPABILITY_MESSAGE)
}

@(private = "file")
configuration_read_16 :: proc "contextless" (requester: u16, register: u32) -> u16 {
	offset := iommu.configuration_offset(iommu.requester_bus(requester), iommu.requester_device(requester), iommu.requester_function(requester), register)
	return intrinsics.volatile_load(direct(iommu_configuration + offset, u16))
}

@(private = "file")
configuration_write_16 :: proc "contextless" (requester: u16, register: u32, value: u16) {
	offset := iommu.configuration_offset(iommu.requester_bus(requester), iommu.requester_device(requester), iommu.requester_function(requester), register)
	intrinsics.volatile_store(direct(iommu_configuration + offset, u16), value)
}

@(private = "file")
configuration_write_32 :: proc "contextless" (requester: u16, register: u32, value: u32) {
	offset := iommu.configuration_offset(iommu.requester_bus(requester), iommu.requester_device(requester), iommu.requester_function(requester), register)
	intrinsics.volatile_store(direct(iommu_configuration + offset, u32), value)
}

// amd_tables_make makes the device table, the empty table and, with
// remapping, the page of the interrupt tables, and writes each entry of the
// device table: translation through the empty table, no read, no write,
// and with remapping each fixed message refused. With remapping, the
// entry of each requester that the table IVRS names gets the pass bits of
// its settings: the 8259 virtual wire and the NMI of an AMD platform come
// as messages of a device of the chipset. Memory of the kernel, at the
// start. false: no frame.
amd_tables_make :: proc "contextless" (remapping: bool) -> bool {
	// The table covers each of the 65536 requesters, so a requester on a
	// bus that the root service numbers later, or past the buses of the
	// table MCFG, has an entry that refuses it too.
	amd_device_table = frames_allocate(iommu.AMD_DEVICE_TABLE_PAGES)
	amd_empty_table = frames_allocate(1)
	if remapping {
		amd_interrupt_tables = frames_allocate(1)
	}
	if amd_device_table == 0 || amd_empty_table == 0 || (remapping && amd_interrupt_tables == 0) {
		return false
	}
	empty := iommu.amd_translation_words(amd_empty_table, iommu.AMD_LEVELS, 0, false)
	interrupts := iommu.amd_interrupt_word(remapping, 0, 0)
	for requester in u64(0) ..< iommu.AMD_DEVICE_TABLE_ENTRIES {
		entry := direct(amd_device_table + requester * iommu.AMD_DEVICE_ENTRY_SIZE, [4]u64)
		entry^ = {empty[0], empty[1], interrupts, 0}
	}
	if remapping {
		// The settings of each range that names a requester add up: the
		// table names a device of the chipset in one entry, often with the
		// alias of the devices behind it.
		for item in iommu_ivrs.ranges[:min(iommu_ivrs.range_count, iommu.AMD_REQUESTER_RANGE_CAPACITY)] {
			pass := iommu.amd_pass_bits(item.settings)
			if pass == 0 {
				continue
			}
			for requester in u64(item.first) ..= u64(item.last) {
				entry := direct(amd_device_table + requester * iommu.AMD_DEVICE_ENTRY_SIZE, [4]u64)
				entry[2] |= pass
			}
		}
	}
	write_back(amd_device_table, iommu.AMD_DEVICE_TABLE_PAGES * PAGE_SIZE)
	write_back(amd_empty_table, PAGE_SIZE)
	if remapping {
		write_back(amd_interrupt_tables, PAGE_SIZE)
	}
	return true
}

// amd_device_entry gives the entry of a requester in the device table,
// which has an entry for each requester.
@(private = "file")
amd_device_entry :: proc "contextless" (requester: u16) -> ^[4]u64 {
	return direct(amd_device_table + u64(requester) * iommu.AMD_DEVICE_ENTRY_SIZE, [4]u64)
}

// amd_translation_write makes the entry of a requester translate through
// the tables from top, in a domain identifier, or makes it refuse every
// access through the empty table. A unit can read the entry between two
// stores: the domain is written before the tables, and the refusal before
// the domain is cleared, so each mixed entry that it reads refuses every
// access. The caller holds the frame lock, or runs at the start, and
// invalidates the entry after it.
amd_translation_write :: proc "contextless" (requester: u16, present: bool, top: u64, levels: u32, domain: u16) {
	entry := amd_device_entry(requester)
	if present {
		words := iommu.amd_translation_words(top, levels, domain, true)
		intrinsics.volatile_store(&entry[1], words[1])
		intrinsics.volatile_store(&entry[0], words[0])
	} else {
		words := iommu.amd_translation_words(amd_empty_table, levels, 0, false)
		intrinsics.volatile_store(&entry[0], words[0])
		intrinsics.volatile_store(&entry[1], words[1])
	}
	write_back(physical_of(entry), 16)
}

// amd_units_start gives each unit the device table, its queue of
// invalidations and its event log, the message interrupt of its function,
// then turns it on, and makes it forget each cached entry. A unit that does
// not start turns each unit before it off again, with one line. The
// exclusion range and the
// apertures of memory access routing are cleared before the unit is on:
// either passes a range of memory past the tables, whatever the device
// entry holds. Then each unit forgets the entry of each of the 65536
// requesters: QEMU 10 translates the accesses of a device only after the
// invalidation of its entry, and passes them all before it, so a function
// that no walk finds (a virtual function, a bus numbered later) is refused
// there too. round_trip_cycles: the first invalidation of the first unit.
amd_units_start :: proc "contextless" () -> (started: bool, round_trip_cycles: u64) {
	for index in 0 ..< iommu_unit_count {
		unit := &iommu_units[index]
		register_write_64(unit, iommu.AMD_REGISTER_EXCLUSION_BASE, 0)
		register_write_64(unit, iommu.AMD_REGISTER_EXCLUSION_LIMIT, 0)
		for register in u64(0) ..< iommu.AMD_MARC_REGISTER_COUNT {
			register_write_64(unit, iommu.AMD_REGISTER_MARC_FIRST + register * 8, 0)
		}
		register_write_64(unit, iommu.AMD_REGISTER_DEVICE_TABLE, iommu.amd_device_table_register(amd_device_table, iommu.AMD_DEVICE_TABLE_PAGES))
		register_write_64(unit, iommu.AMD_REGISTER_INVALIDATION_QUEUE, iommu.amd_ring_register(unit.queue))
		register_write_64(unit, iommu.AMD_REGISTER_COMMAND_HEAD, 0)
		register_write_64(unit, iommu.AMD_REGISTER_COMMAND_TAIL, 0)
		register_write_64(unit, iommu.AMD_REGISTER_EVENT_LOG, iommu.amd_ring_register(unit.event_log))
		register_write_64(unit, iommu.AMD_REGISTER_EVENT_HEAD, 0)
		register_write_64(unit, iommu.AMD_REGISTER_EVENT_TAIL, 0)
		register_write_32(unit, iommu.AMD_REGISTER_STATUS, iommu.AMD_STATUS_CLEARED_AT_START)
		unit.queue_tail = 0
		unit.event_head = 0
		amd_message_interrupt_start(unit)
		register_write_64(unit, iommu.AMD_REGISTER_CONTROL, iommu.AMD_CONTROL_STARTED)
		unit_started := amd_status_wait(unit, iommu.AMD_STATUS_RUNS, true)
		invalidated := true
		if unit_started {
			forget: Descriptor_Batch
			if iommu.amd_extended_invalidate_all(unit.extended) {
				batch_add(&forget, iommu.amd_command_all())
			}
			before := cycles_now()
			invalidated = invalidate_unit_at_start(unit, forget)
			if index == 0 {
				round_trip_cycles = cycles_now() - before
			}
			unit_started = invalidated
		}
		if !unit_started {
			// A machine with a part of its units on would let a device of a
			// unit that is off write the tables of the others.
			for &earlier in iommu_units[:index + 1] {
				amd_unit_off(&earlier)
			}
			if !invalidated {
				log(IOMMU_FIRST_INVALIDATION_LINE)
			} else {
				log("kernel: no IOMMU in use: a unit did not start its queue of invalidations and its event log; each device reaches all memory")
			}
			return false, 0
		}
	}
	// Every unit, for every requester: an invalidation on a unit that does
	// not translate a requester changes nothing, and the table IVRS of
	// QEMU does not name each function that QEMU sends through its unit.
	// A batch holds the most commands that one wait allows: about 9400
	// waits for each unit, at the start only. These are still the first
	// invalidations of the entries: a unit that does not finish one turns
	// every unit off, as above.
	for &unit in iommu_units[:iommu_unit_count] {
		batch: Descriptor_Batch
		for requester in u32(0) ..< iommu.AMD_DEVICE_TABLE_ENTRIES {
			batch_add(&batch, iommu.amd_command_device_entry(u16(requester)))
			if int(batch.count) == len(batch.descriptors) || requester == iommu.AMD_DEVICE_TABLE_ENTRIES - 1 {
				if !invalidate_unit_at_start(&unit, batch) {
					for &each_unit in iommu_units[:iommu_unit_count] {
						amd_unit_off(&each_unit)
					}
					log(IOMMU_FIRST_INVALIDATION_LINE)
					return false, 0
				}
				batch = {}
			}
		}
	}
	return true, round_trip_cycles
}

// amd_message_interrupt_start gives the message interrupt of the function
// of a unit the vector of the fault event on the first processor, and lets
// the function write memory, which its message is. The function of a unit
// is of the kernel, as its registers: the root service starts no service
// for it.
@(private = "file")
amd_message_interrupt_start :: proc "contextless" (unit: ^Iommu_Unit) {
	capability := amd_message_capability(unit.requester)
	control := configuration_read_16(unit.requester, capability + 2)
	address_low, address_high, value := iommu.message_registers(capability, control)
	configuration_write_32(unit.requester, address_low, u32(iommu.amd_message_address(u8(processors[0].apic_id & 0xFF))))
	if address_high != 0 {
		configuration_write_32(unit.requester, address_high, 0)
	}
	configuration_write_16(unit.requester, value, VECTOR_IOMMU_FAULT)
	// A mask bit that the firmware left set would stop each event
	// interrupt, and the log would fill with no line.
	if mask := iommu.message_mask_register(capability, control); mask != 0 {
		configuration_write_32(unit.requester, mask, 0)
	}
	configuration_write_16(unit.requester, capability + 2, iommu.message_control_enabled(control))
	command := configuration_read_16(unit.requester, iommu.OFFSET_COMMAND)
	configuration_write_16(unit.requester, iommu.OFFSET_COMMAND, command | iommu.COMMAND_BUS_MASTER)
}

// amd_status_wait waits until the bits of the status of a unit are all set,
// or all clear, for one second. false: they were not.
@(private = "file")
amd_status_wait :: proc "contextless" (unit: ^Iommu_Unit, bits: u32, set: bool) -> bool {
	bound := wait_bound()
	for {
		status := register_read_32(unit, iommu.AMD_REGISTER_STATUS) & bits
		if (set && status == bits) || (!set && status == 0) {
			return true
		}
		if !wait_turn(bound) {
			return false
		}
	}
}

// amd_unit_off turns a unit off, and waits until its queue of invalidations
// and its event log stop: a unit that the start turned on before another unit
// failed.
@(private = "file")
amd_unit_off :: proc "contextless" (unit: ^Iommu_Unit) {
	register_write_64(unit, iommu.AMD_REGISTER_CONTROL, 0)
	if !amd_status_wait(unit, iommu.AMD_STATUS_RUNS, false) {
		// The unit still runs: the kernel no longer owns its registers.
		log("kernel: IOMMU: a unit did not turn off: its devices reach only the reserved memory ranges, and Device_Create can give its registers")
	}
}

// amd_commands_run gives a batch of commands to the queue of invalidations
// of a unit of AMD-Vi, then a completion wait that writes a number in a
// word of the kernel, and waits for the number. false: the unit did not
// reach the wait in one second, or stopped its queue, which it does when it
// refuses a command.
amd_commands_run :: proc "contextless" (unit: ^Iommu_Unit, batch: Descriptor_Batch) -> bool {
	buffer := direct(unit.queue, [iommu.AMD_RING_RECORDS][2]u64)
	unit.wait_number += 1
	number := unit.wait_number
	wait := iommu.amd_command_wait(unit.wait_status, number)
	tail := unit.queue_tail
	// The unit reads the commands only after the write of the tail
	// register: each word is a volatile store before it.
	for index in u32(0) ..= batch.count {
		command := wait
		if index < batch.count {
			command = batch.descriptors[index]
		}
		intrinsics.volatile_store(&buffer[tail][0], command[0])
		intrinsics.volatile_store(&buffer[tail][1], command[1])
		write_back(unit.queue + u64(tail) * iommu.AMD_RECORD_SIZE, iommu.AMD_RECORD_SIZE)
		tail = (tail + 1) % iommu.AMD_RING_RECORDS
	}
	unit.queue_tail = tail
	register_write_64(unit, iommu.AMD_REGISTER_COMMAND_TAIL, iommu.amd_ring_register_of(tail))
	status := direct(unit.wait_status, u32)
	bound := wait_bound()
	for intrinsics.volatile_load(status) != number {
		if register_read_32(unit, iommu.AMD_REGISTER_STATUS) & iommu.AMD_STATUS_INVALIDATION_QUEUE_RUNS == 0 || !wait_turn(bound) {
			return false
		}
	}
	return true
}

// amd_message_bind gives a message interrupt (its index) to a device: the
// entry of the index in the interrupt table of the device holds the vector
// of the index, for the first processor. A device with no table takes a
// free one, and its entry in the device table names it. The caller holds
// the control lock. false: no free table, which the count of the message
// interrupts excludes.
amd_message_bind :: proc "contextless" (index: u32, requester: u16) -> bool {
	table := -1
	free := -1
	for &owner, place in amd_interrupt_table_owners {
		if owner.entries != 0 && owner.requester == requester {
			table = place
			break
		}
		if owner.entries == 0 && free < 0 {
			free = place
		}
	}
	made := table < 0
	if made {
		if free < 0 {
			return false
		}
		table = free
		amd_interrupt_table_owners[table].requester = requester
	}
	amd_interrupt_table_owners[table].entries += 1
	amd_message_tables[index] = u8(table + 1)
	table_address := amd_interrupt_tables + u64(table) * iommu.AMD_INTERRUPT_TABLE_SPACING
	entry := direct(table_address + u64(index) * iommu.AMD_INTERRUPT_ENTRY_SIZE, u32)
	intrinsics.volatile_store(entry, iommu.amd_interrupt_entry(u8(VECTOR_MESSAGE_BASE + index), u8(processors[0].apic_id & 0xFF)))
	write_back(physical_of(entry), iommu.AMD_INTERRUPT_ENTRY_SIZE)
	if made {
		amd_interrupt_word_write(requester, table_address)
	}
	amd_interrupts_invalidate(requester, made)
	return true
}

// amd_message_end clears the entry of a message interrupt whose last handle
// closed, before the index can be given again. A table with no entry left
// is free again, and the entry of its device in the device table refuses
// each message. handle_close calls it with the control lock.
amd_message_end :: proc "contextless" (index: u32) {
	place := amd_message_tables[index]
	if place == 0 {
		return // The index was never bound: a device with no requester.
	}
	amd_message_tables[index] = 0
	table := u64(place - 1)
	owner := &amd_interrupt_table_owners[table]
	entry := direct(amd_interrupt_tables + table * iommu.AMD_INTERRUPT_TABLE_SPACING + u64(index) * iommu.AMD_INTERRUPT_ENTRY_SIZE, u32)
	intrinsics.volatile_store(entry, 0)
	write_back(physical_of(entry), iommu.AMD_INTERRUPT_ENTRY_SIZE)
	owner.entries -= 1
	emptied := owner.entries == 0
	if emptied {
		amd_interrupt_word_write(owner.requester, 0)
	}
	amd_interrupts_invalidate(owner.requester, emptied)
}

// amd_interrupt_word_write writes the word of interrupts of the entry of a
// requester: its interrupt table, or with 0 the refusal of each fixed
// message. It keeps the pass bits that the start wrote: only this
// procedure writes the word after the start, under the control lock.
@(private = "file")
amd_interrupt_word_write :: proc "contextless" (requester: u16, table: u64) {
	entry := amd_device_entry(requester)
	pass := intrinsics.volatile_load(&entry[2]) & iommu.AMD_PASS_BITS
	intrinsics.volatile_store(&entry[2], iommu.amd_interrupt_word(true, table, pass))
	write_back(physical_of(&entry[2]), 8)
}

// amd_interrupts_invalidate makes the unit of a requester forget its
// interrupt table, and with entry_changed its entry in the device table,
// before the caller returns: a unit that kept an old entry would let the
// old device send the vector of the next owner. It takes the frame lock,
// which orders the queues of invalidations.
@(private = "file")
amd_interrupts_invalidate :: proc "contextless" (requester: u16, entry_changed: bool) {
	unit_index, _ := unit_of(requester)
	batch: Descriptor_Batch
	if entry_changed {
		batch_add(&batch, iommu.amd_command_device_entry(requester))
	}
	batch_add(&batch, iommu.amd_command_interrupt_table(requester))
	lock_take(&frame_lock, .Frame)
	defer lock_free(&frame_lock, .Frame)
	invalidate_unit(&iommu_units[unit_index], batch)
}

// amd_events_take reads the event log of each unit: each page fault is a
// DMA fault or a refused interrupt for fault_line_write, and each other
// event a line with its own count. The bit of the interrupt of the status is
// cleared before the tail is read: a record that comes after the read sets
// it again, and sends a new interrupt. One call reads at most the records of
// one log of each unit, with interrupts off. A unit can move its tail before
// the record is in memory: a record of the kind 0 is read again
// AMD_EVENT_RECORD_READS times, then left, with the head on it, to the next
// tick. Each record is written 0 after it is read, so a record of the last
// lap of the ring is never read again. A full log stops the records: the
// kernel starts it again, and counts it. left: a record came during the
// read, or was not written yet, for the next tick.
amd_events_take :: proc "contextless" () -> (left: bool) {
	for index in 0 ..< iommu_unit_count {
		unit := &iommu_units[index]
		status := register_read_32(unit, iommu.AMD_REGISTER_STATUS)
		register_write_32(unit, iommu.AMD_REGISTER_STATUS, iommu.AMD_STATUS_EVENT_INTERRUPT)
		// The unit writes the tail: a value past the log is cut, and the
		// count of the reads ends the pass whatever it holds.
		tail := iommu.amd_ring_offset(register_read_64(unit, iommu.AMD_REGISTER_EVENT_TAIL)) % iommu.AMD_RING_BYTES
		head := unit.event_head
		not_written := false
		for read := 0; head != tail && read < iommu.AMD_RING_RECORDS; read += 1 {
			record := direct(unit.event_log + u64(head), [2]u64)
			low := intrinsics.volatile_load(&record[0])
			for _ in 0 ..< AMD_EVENT_RECORD_READS {
				if iommu.amd_event_read(low, 0).kind != iommu.AMD_EVENT_NOT_WRITTEN {
					break
				}
				intrinsics.cpu_relax()
				low = intrinsics.volatile_load(&record[0])
			}
			if iommu.amd_event_read(low, 0).kind == iommu.AMD_EVENT_NOT_WRITTEN {
				not_written = true
				break
			}
			high := intrinsics.volatile_load(&record[1])
			intrinsics.volatile_store(&record[0], 0)
			intrinsics.volatile_store(&record[1], 0)
			amd_event_write(low, high)
			head = (head + iommu.AMD_RECORD_SIZE) % iommu.AMD_RING_BYTES
		}
		left ||= not_written
		unit.event_head = head
		register_write_64(unit, iommu.AMD_REGISTER_EVENT_HEAD, u64(head))
		if status & iommu.AMD_STATUS_EVENT_OVERFLOW != 0 {
			amd_event_log_restart(unit)
		}
		left ||= iommu.amd_ring_offset(register_read_64(unit, iommu.AMD_REGISTER_EVENT_TAIL)) % iommu.AMD_RING_BYTES != unit.event_head
	}
	return left
}

// amd_event_write writes the line of one record of the event log.
@(private = "file")
amd_event_write :: proc "contextless" (low: u64, high: u64) {
	event := iommu.amd_event_read(low, high)
	if event.kind == iommu.AMD_EVENT_PAGE_FAULT {
		fault_line_write(iommu.amd_event_fault(event))
		return
	}
	events := intrinsics.atomic_add(&amd_unit_events[event.kind % iommu.AMD_EVENT_KINDS], 1) + 1
	if iommu.fault_line(events) == .None {
		return
	}
	log("kernel: IOMMU: an event of a unit of the kind ", u64(event.kind), " for the device at bus ", u64(iommu.requester_bus(event.requester)), ", device ", u64(iommu.requester_device(event.requester)), ", function ", u64(iommu.requester_function(event.requester)), ": the words ", Hex(low), " and ", Hex(high), "; events of this kind: ", events)
}

// amd_event_log_restart starts the event log of a unit again after it was
// full, as the specification asks: the log stops, the overflow is cleared,
// the log is empty, and it starts.
@(private = "file")
amd_event_log_restart :: proc "contextless" (unit: ^Iommu_Unit) {
	control := register_read_64(unit, iommu.AMD_REGISTER_CONTROL)
	register_write_64(unit, iommu.AMD_REGISTER_CONTROL, control &~ (iommu.AMD_CONTROL_EVENT_LOG | iommu.AMD_CONTROL_EVENT_INTERRUPT))
	if !amd_status_wait(unit, iommu.AMD_STATUS_EVENT_LOG_RUNS, false) {
		log("kernel: IOMMU: the event log of a unit did not stop after it was full: the unit records no more DMA faults")
		return
	}
	register_write_32(unit, iommu.AMD_REGISTER_STATUS, iommu.AMD_STATUS_EVENT_OVERFLOW | iommu.AMD_STATUS_EVENT_INTERRUPT)
	register_write_64(unit, iommu.AMD_REGISTER_EVENT_HEAD, 0)
	register_write_64(unit, iommu.AMD_REGISTER_EVENT_TAIL, 0)
	unit.event_head = 0
	register_write_64(unit, iommu.AMD_REGISTER_CONTROL, control)
	overflows := intrinsics.atomic_add(&amd_event_log_overflows, 1) + 1
	if iommu.fault_line(overflows) != .None {
		log("kernel: IOMMU: the event log of a unit was full: the unit dropped records; full logs: ", overflows)
	}
}
