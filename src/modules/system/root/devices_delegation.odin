package root

// The bridge of the core to the delegated devices service
// (src/md/api/root_service_split.md, "The order of the start").
//
// The devices service holds the table of the PCI identities: which device
// class role each pair of vendor and device identifiers has. The core
// starts it first, before any device service, and asks it once for the
// class of each device of the bus (Lookup_Identity). The core keeps the
// answers, by place of the bus: it then arms a device only at a place that
// the devices service classified with the role of the device service, and
// never asks again on the path of a start. A wait of the loop never waits
// for the devices service: the classification runs before the loop, with a
// bound, and the notices of each binding (Bind_Device, Release_Device) are
// sent without a wait, their answers read by the loop.
//
// The core still holds the ports of the configuration and arms each device
// itself: moving them into the devices service is the next step of the
// split. A devices service that does not classify the bus within its bound
// of three starts leaves the machine with no device service, with one
// line: no data disk, no network device, no sound device, no entropy
// device.

import "base:intrinsics"
import "modus:contract/ring"
import rd "modus:contract/root_delegation"
import op "modus:contract/operation"
import "modus:pci"
import "modus:random"
import "modus:system"

// The bound of the starts of the devices service, as for each delegated
// service of the start.
DEVICES_RESTART_LIMIT :: 3

// The bound of the wait for one answer of the devices service during the
// classification of the bus: only a service that hangs meets it.
DEVICES_ANSWER_BOUND_MILLISECONDS :: system.TEST_HANG_BOUND_MILLISECONDS

// The most answers of notices that one wait of a lookup, or one pass of the
// loop, reads: each bind place has at most a Bind_Device and a
// Release_Device in flight, so a service that writes more floods the core.
DEVICES_ANSWERS_PER_PASS :: 2 * rd.DEVICES_BIND_PLACE_COUNT

// The most devices of the bus that the core keeps a class of.
CLASSIFIED_DEVICE_CAPACITY :: 64

// The buses of PCI: a bus number is one byte.
PCI_BUS_COUNT :: 256

#assert(STARTED_CAPACITY <= rd.DEVICES_BIND_PLACE_COUNT, "each place of the table of processes has its bind place in the region of the devices service")

// One device of the bus that the devices service classified.
Classified_Device :: struct {
	place:     pci.Place,
	vendor_id: u16,
	device_id: u16,
	role:      rd.Device_Class_Role,
}

devices_process: ^Started
devices_ring_memory: system.Handle
devices_ring: ring.Ring
devices_region_memory: system.Handle
devices_region: []u8
devices_starts: int
devices_next_tag: u32 = 1

classified_devices: [CLASSIFIED_DEVICE_CAPACITY]Classified_Device
classified_device_count: int
// The devices service answered for each device of the bus. false: no
// device service starts.
bus_classified: bool

// The discovered record of the device of each device service, at the place
// of the service in the table of processes: a devices service that starts
// again gets each binding again.
bound_devices: []rd.Pci_Discovered_Device // One for each place: root_tables_start.
bound_device_present: []bool

// devices_service_start starts the devices service with its ring, its
// region and its log, and nothing else. It gives false past
// DEVICES_RESTART_LIMIT starts or on a failure. A service that starts again
// gets the binding of each device service that runs.
devices_service_start :: proc "contextless" () -> bool {
	if devices_process != nil {
		return true
	}
	if devices_starts >= DEVICES_RESTART_LIMIT {
		return false
	}
	devices_starts += 1
	slot := part_place_take()
	file := image_file_checked("devices")
	if slot == nil {
		system.log_fact(.Warning, Devices_Service_Start_Failed{status = .No_Slot})
		return false
	}
	if len(file) == 0 {
		system.log_fact(.Warning, Devices_Service_Start_Failed{status = .Bad_Handle})
		return false
	}
	ring_memory, ring_opened, status := system.ring_create()
	region_memory: system.Handle
	region_address: rawptr
	if status == .Ok {
		region_memory, status = system.memory_create(rd.devices_region_pages(len(started)))
	}
	if status == .Ok {
		region_address, status = system.memory_map(region_memory, {.Write})
	}
	process: system.Handle
	devices_budget: Start_Budget
	if status == .Ok {
		grants: system.Context_Grants
		values: system.Context_Values
		system.grant_put(&grants, rd.DEVICES_RING_SLOT, {ring_memory, {.Read, .Write}})
		system.grant_put(&grants, rd.DEVICES_REGION_SLOT, {region_memory, {.Read, .Write}})
		system.grant_put(&grants, op.CONTEXT_LOG, log_grant(start_grant_set_of("devices")))
		budget_ok: bool
		if context_refused("devices", &grants, &values) {
			status = .Bad_State
		} else if devices_budget, budget_ok = budget_of(file, "devices"); !budget_ok {
			status = .No_Budget
		} else {
			process, status = system.process_start(file, "devices", grants.grants, random.values_with_seed(&process_generator, values.values), devices_budget.amounts, nil, &prepared, load_source(), ready = &slot.ready)
		}
	}
	if status != .Ok {
		if region_address != nil {
			system.memory_unmap(region_address)
		}
		if ring_opened.head != nil {
			system.ring_close(&ring_opened)
		}
		for handle in ([2]system.Handle{ring_memory, region_memory}) {
			if handle != 0 {
				system.close(handle)
			}
		}
		system.log_fact(.Warning, Devices_Service_Start_Failed{status = status})
		return false
	}
	part_place_fill(slot, "devices", process)
	start_budget_note(slot, devices_budget)
	devices_process = slot
	devices_ring_memory, devices_ring = ring_memory, ring_opened
	devices_region_memory = region_memory
	devices_region = ([^]u8)(region_address)[:rd.devices_region_pages(len(started)) * system.PAGE_SIZE]
	system.log_fact(.Info, Devices_Service_Started{starts = u64(devices_starts), start_limit = u64(DEVICES_RESTART_LIMIT)})
	for present, index in bound_device_present {
		if present {
			devices_bind_send(index)
		}
	}
	return true
}

// devices_service_end forgets the devices service when it stopped: the
// next notice of a binding starts it again, within its bound.
devices_service_end :: proc "contextless" (item: ^Started) {
	if item != devices_process {
		return
	}
	if raw_data(devices_region) != nil {
		system.memory_unmap(raw_data(devices_region))
		devices_region = nil
	}
	if devices_ring.head != nil {
		system.ring_close(&devices_ring)
	}
	for handle in ([2]system.Handle{devices_ring_memory, devices_region_memory}) {
		if handle != 0 {
			system.close(handle)
		}
	}
	devices_ring_memory, devices_region_memory = 0, 0
	devices_process = nil
	system.log_fact(.Warning, Devices_Service_Stopped{})
}

@(private = "file")
devices_tag_next :: proc "contextless" () -> u32 {
	tag := devices_next_tag
	devices_next_tag = devices_next_tag == max(u32) ? 1 : devices_next_tag + 1
	return tag
}

// devices_lookup asks the devices service for the class of one PCI
// identity and waits for its answer, within its bound. answered is false
// when the service stopped, took no command, gave no answer or gave an
// answer that the border refuses.
@(private = "file")
devices_lookup :: proc "contextless" (vendor_id, device_id: u16) -> (entry: rd.Device_Identity_Entry, known, answered: bool) {
	tag := devices_tag_next()
	if !system.send(&devices_ring.commands, ring.Record{kind = u32(rd.Devices_Ring_Command.Lookup_Identity), tag = tag, values = {0 = u64(vendor_id), 1 = u64(device_id)}}) {
		return {}, false, false
	}
	limit := system.time() + DEVICES_ANSWER_BOUND_MILLISECONDS
	foreign_answers := 0
	for {
		wait := system.wait_begin()
		for record in system.receive(&devices_ring.completions) {
			if record.tag != tag {
				// The answer of a notice of a binding: nothing waits for it.
				// A service that writes such answers with no end would hold
				// this wait past its bound, so their count and the clock
				// both end it.
				foreign_answers += 1
				if foreign_answers > DEVICES_ANSWERS_PER_PASS || system.time() >= limit {
					return {}, false, false
				}
				continue
			}
			status, status_known := rd.devices_ring_status_from_word(record.kind)
			if !status_known {
				return {}, false, false
			}
			switch status {
			case .Ok:
				entry, known = rd.device_identity_answer_of_values(record.values, vendor_id, device_id)
				return entry, known, known
			case .Refused:
				// Only a refusal that says the identity has no class is an
				// answer; another one says the table of the service is
				// damaged, and the service is started again.
				_, refusal_answered := rd.device_identity_refusal_of_values(record.values)
				return {}, false, refusal_answered
			case .Bad_Command:
				return {}, false, false
			}
		}
		if state, _, _ := system.process_state(devices_process.process); state == .Stopped {
			return {}, false, false
		}
		system.wait_records(&wait, &devices_ring.completions)
		if system.wait_end(&wait, limit) >= limit {
			return {}, false, false
		}
	}
}

// bus_classify_pass asks the devices service for the class of each device
// of type 0 on bus 0 and on each bus behind a bridge. ok is false when the
// service did not answer for one of them.
@(private = "file")
bus_classify_pass :: proc "contextless" () -> (looked_up: int, ok: bool) {
	classified_device_count = 0
	buses_seen: [PCI_BUS_COUNT]bool
	buses: [PCI_BUS_COUNT]u32
	bus_count := 1
	buses_seen[0] = true
	capacity_told := false
	for next := 0; next < bus_count; next += 1 {
		bus := buses[next]
		for device in u32(0) ..< 32 {
			for function in u32(0) ..< 8 {
				place := pci.Place{bus = bus, device = device, function = function}
				identity := pci.read_32(place, 0)
				if identity & 0xFFFF == 0xFFFF {
					if function == 0 {
						break // No device at this place.
					}
					continue
				}
				header_type := pci.read_32(place, pci.OFFSET_HEADER_TYPE) >> 16 & 0xFF
				switch header_type & 0x7F {
				case 0:
					entry, known, answered := devices_lookup(u16(identity & 0xFFFF), u16(identity >> 16))
					if !answered {
						return looked_up, false
					}
					looked_up += 1
					if !known {
						break
					}
					if classified_device_count == CLASSIFIED_DEVICE_CAPACITY {
						if !capacity_told {
							capacity_told = true
							system.log_fact(.Warning, Classified_Devices_Full{capacity = CLASSIFIED_DEVICE_CAPACITY})
						}
						break
					}
					classified_devices[classified_device_count] = {place = place, vendor_id = entry.pci_vendor_id, device_id = entry.pci_device_id, role = entry.role}
					classified_device_count += 1
				case 1:
					secondary := pci.read_32(place, pci.OFFSET_BUS_NUMBERS) >> 8 & 0xFF
					// A secondary bus at or below its own bus is a fault of the
					// numbers of the firmware: a walk would not end.
					if secondary > bus && !buses_seen[secondary] {
						buses_seen[secondary] = true
						buses[bus_count] = secondary
						bus_count += 1
					}
				}
				if function == 0 && header_type & 0x80 == 0 {
					break // One function only.
				}
			}
		}
	}
	return looked_up, true
}

// bus_classify starts the devices service and has it classify the bus,
// before any device service starts. A service that stops or does not
// answer is stopped and started again, within DEVICES_RESTART_LIMIT
// starts; past it, the machine starts with no device service, with one
// line.
bus_classify :: proc "contextless" () {
	if status := configuration_open(); status != .Ok {
		system.log_fact(.Warning, Bus_Configuration_Unread{status = status})
		return
	}
	for devices_starts < DEVICES_RESTART_LIMIT {
		if !devices_service_start() {
			continue
		}
		looked_up, ok := bus_classify_pass()
		if ok {
			bus_classified = true
			system.log_fact(.Info, Bus_Classified{classified = u64(classified_device_count), looked_up = u64(looked_up)})
			return
		}
		system.log_fact(.Warning, Devices_Service_Silent{starts = u64(devices_starts)})
		classified_device_count = 0
		// The reap of the loop frees its place: this service forgets it
		// now, so the next start makes a new ring.
		stopped := devices_process
		root_stop_ask(stopped)
		devices_service_end(stopped)
	}
	system.log_fact(.Error, Devices_Service_Absent{start_limit = DEVICES_RESTART_LIMIT})
}

// classified_device_at gives the device that the devices service
// classified at a place of the bus.
classified_device_at :: proc "contextless" (place: pci.Place) -> (device: Classified_Device, found: bool) {
	for item in classified_devices[:classified_device_count] {
		if item.place == place {
			return item, true
		}
	}
	return {}, false
}

// classified_device_of_role gives the first device of the bus that the
// devices service classified with a role.
classified_device_of_role :: proc "contextless" (role: rd.Device_Class_Role) -> (device: Classified_Device, found: bool) {
	for item in classified_devices[:classified_device_count] {
		if item.role == role {
			return item, true
		}
	}
	return {}, false
}

@(private = "file")
started_index_of :: proc "contextless" (item: ^Started) -> (index: int, ok: bool) {
	if len(started) == 0 {
		return 0, false
	}
	first := uintptr(&started[0])
	address := uintptr(item)
	if address < first || address >= first + uintptr(len(started)) * size_of(Started) || (address - first) % size_of(Started) != 0 {
		return 0, false
	}
	return int((address - first) / size_of(Started)), true
}

// devices_bind_send sends the Bind_Device of the device service at one
// place of the table of processes, with no wait: the loop reads its
// answer (devices_answers).
@(private = "file")
devices_bind_send :: proc "contextless" (index: int) {
	discovered_offset, spec_offset, ok := rd.devices_bind_place_offsets(index, len(started))
	if !ok || devices_ring.head == nil || started[index].process == 0 {
		return
	}
	// A device service records no process slot in its place: the kernel
	// gives it, and the devices service refuses a slot of 0.
	service_slot, _, place_status := system.process_place(started[index].process)
	if place_status != .Ok || service_slot == 0 {
		return
	}
	intrinsics.mem_copy_non_overlapping(&devices_region[discovered_offset], &bound_devices[index], size_of(rd.Pci_Discovered_Device))
	_ = system.send(&devices_ring.commands, ring.Record{kind = u32(rd.Devices_Ring_Command.Bind_Device), tag = devices_tag_next(), values = {0 = discovered_offset, 1 = service_slot, 2 = spec_offset, 3 = rd.device_bind_identity_word(&bound_devices[index])}})
}

// devices_bind_tell records the device of a device service that started,
// and tells the devices service of the binding. table_bar and pending_bar
// name the BARs of the MSI-X table and of its pending bits, which the core
// keeps out of the grant of the device service: the record leaves them out
// too, so the grant that the devices service records is the grant given.
devices_bind_tell :: proc "contextless" (driver: ^Started, place: pci.Place, identity: u32, bars: [pci.BAR_COUNT]pci.Bar, interrupt_vector: u32, table_bar, pending_bar: u32) {
	index, ok := started_index_of(driver)
	if !ok {
		return
	}
	discovered := rd.Pci_Discovered_Device{
		location         = {bus = u8(place.bus), device = u8(place.device), function = u8(place.function)},
		pci_vendor_id    = u16(identity & 0xFFFF),
		pci_device_id    = u16(identity >> 16),
		interrupt_vector = interrupt_vector,
		has_interrupt    = true,
	}
	for bar, bar_index in bars {
		if bar.size == 0 || bar.address == 0 || rd.device_bar_withheld(u32(bar_index), table_bar, pending_bar) {
			continue
		}
		// A count of pages past the limit is written as max(u32), which
		// the devices service refuses whole: a cut count would record a
		// grant smaller than the window of a 64-bit BAR.
		discovered.bars[discovered.bar_count] = {base_address = bar.address, page_count = rd.device_bar_page_count_word(bar.size)}
		discovered.bar_count += 1
	}
	bound_devices[index] = discovered
	bound_device_present[index] = true
	if devices_process == nil {
		// Started again within its bound, it gets each binding.
		_ = devices_service_start()
		return
	}
	devices_bind_send(index)
}

// devices_release_tell tells the devices service that the device service
// of a device stopped, with no wait.
devices_release_tell :: proc "contextless" (driver: ^Started) {
	index, ok := started_index_of(driver)
	if !ok || !bound_device_present[index] {
		return
	}
	location := bound_devices[index].location
	bound_device_present[index] = false
	bound_devices[index] = {}
	if devices_ring.head == nil {
		return
	}
	_ = system.send(&devices_ring.commands, ring.Record{kind = u32(rd.Devices_Ring_Command.Release_Device), tag = devices_tag_next(), values = {0 = u64(location.bus), 1 = u64(location.device), 2 = u64(location.function)}})
}

// devices_answers reads the answers of the notices of the bindings, and
// adds the completions of the devices service to the wait of the loop. A
// notice that the devices service refuses is one line and changes nothing:
// the core armed the device at a place that the service classified, so a
// refusal says that the two disagree on its registers.
devices_answers :: proc "contextless" (wait: ^system.Wait) {
	if devices_ring.head == nil {
		return
	}
	// A bounded count of answers in one pass: the records past it stay in
	// the ring, and the wait below ends at once while the ring holds one.
	read := 0
	for record in system.receive(&devices_ring.completions) {
		read += 1
		status, known := rd.devices_ring_status_from_word(record.kind)
		if !known {
			system.log_fact(.Warning, Devices_Answer_Refused{status_word = u64(record.kind)})
			continue
		}
		switch status {
		case .Ok:
		case .Refused, .Bad_Command:
			system.log_fact(.Warning, Devices_Notice_Refused{status_word = u64(record.kind), first_value = record.values[0], second_value = record.values[1]})
		}
		if read >= DEVICES_ANSWERS_PER_PASS {
			break
		}
	}
	system.wait_records(wait, &devices_ring.completions)
}
