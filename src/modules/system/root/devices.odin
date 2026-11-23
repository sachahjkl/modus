package root

import "internal:root/device_stop"
import "modus:contract/block"
import "modus:bochs_display"
import "modus:contract/bridge_requester"
import "modus:contract/entropy_service"
import "modus:contract/frame"
import op "modus:contract/operation"
import "modus:contract/ring"
import rd "modus:contract/root_delegation"
import "modus:pci"
import "modus:random"
import "modus:system"
import "modus:virtio"
import "modus:contract/timed_stream"
import "modus:contract/virtio_gpu"

// The devices of the bus. This service holds the two ports of the
// configuration of all devices: no other process has them. It gives a
// device service one device, and it takes the device back when the service
// stops.

configuration_ports: system.Handle

// The IOMMU gives the network device device windows: the datagram region of
// an endpoint then needs no contiguous memory (src/md/infrastructure/iommu.md,
// "Device addresses"). Written when the frame service starts, before the
// network service gives it a read region.
network_device_windows: bool

device_handle :: proc "contextless" (kind: op.Device_Kind, a, b: u64) -> (handle: system.Handle, values: [7]u64, status: system.Status) {
	values, status = system.call(.Device_Create, u64(machine), u64(kind), a, b)
	return system.Handle(values[0]), values, status
}

// A device service, by the class of its device: its device-class role, optional
// fixed test module override, and the ring that it serves to its one client.
Driver :: struct {
	name:          string, // Default or test-specific module name (used when fixed_module is true or role has no override).
	role:          rd.Device_Class_Role, // The class that the devices service must give the device (devices_delegation.odin).
	ring_capacity: u32,
	ring_role:     int, // The role of the ring in the context of the device service.
	fixed_module:  bool, // True for test-only drivers such as iommu_device.
}

DRIVER_BLOCK :: Driver{"block", .Block_Device, block.RING_CAPACITY, block.SERVICE_RING, false}
DRIVER_FRAME :: Driver{"frame", .Network_Device, frame.RING_CAPACITY, frame.SERVICE_RING, false}
// The test device service of the IOMMU, for its one client `iommu`, on the
// disk of the measures (src/md/infrastructure/iommu.md, "The proof").
DRIVER_IOMMU_DEVICE :: Driver{"iommu_device", .Block_Device, block.RING_CAPACITY, block.SERVICE_RING, true}
// The entropy service, whose one client is this service (entropy.odin).
DRIVER_ENTROPY :: Driver{"entropy", .Entropy_Device, entropy_service.RING_CAPACITY, entropy_service.SERVICE_RING, false}
// The sound service, whose one client is the process with the grant
// Sound_Device (src/md/features/timed_stream.md).
DRIVER_SOUND :: Driver{"sound", .Sound_Device, timed_stream.RING_CAPACITY, timed_stream.SERVICE_RING, false}
// The VirtIO-GPU 1.2 device service (PCI 0x1AF4:0x1050) for 2D scanout and
// Venus Vulkan capability discovery (src/md/features/gpu_access.md).
DRIVER_GPU :: Driver{"gpu_device", .Gpu_Device, virtio_gpu.RING_CAPACITY, virtio_gpu.SERVICE_RING, true}
gpu_client_ring_memory: system.Handle
#assert(timed_stream.GRANT_RING == system.GRANT_DEVICE_RING)

// gpu_device_place gives the place of the first device of bus 0 that the
// devices service classified as a GPU (devices_delegation.odin).
gpu_device_place :: proc "contextless" () -> (place: pci.Place, found: bool) {
	for item in classified_devices[:classified_device_count] {
		if item.role == .Gpu_Device && item.place.bus == 0 {
			return item.place, true
		}
	}
	return {}, false
}

// gpu_driver_start starts gpu_device automatically when a VirtIO-GPU PCI device
// is present on bus 0, retaining its client ring handle for the Display holder.
gpu_driver_start :: proc "contextless" () -> bool {
	if gpu_client_ring_memory != 0 {
		return true
	}
	place, found := gpu_device_place()
	if !found {
		return false
	}
	_, ring_mem, status := driver_start(place, DRIVER_GPU)
	if status != .Ok {
		system.log_fact(.Warning, Gpu_Driver_Failed{status = status, device = place.device})
		return false
	}
	system.log_fact(.Info, Gpu_Driver_Started{device = u64(place.device)})
	gpu_client_ring_memory = ring_mem
	return true
}

// configuration_open takes the ports of the configuration, once.
configuration_open :: proc "contextless" () -> system.Status {
	if configuration_ports != 0 {
		return .Ok
	}
	status: system.Status
	configuration_ports, _, status = device_handle(.Ports, pci.PORT_ADDRESS, pci.PORT_COUNT)
	return status
}

// scratch_disk_place gives the place of the disk of the measures: its place
// of bus 0, or, when that place holds no virtio device and a bridge is at
// pci.SCRATCH_BRIDGE_DEVICE, the place 0 of the secondary bus of the
// bridge, which the firmware numbered.
scratch_disk_place :: proc "contextless" () -> pci.Place {
	place := pci.Place{device = pci.SCRATCH_DISK_DEVICE}
	if configuration_open() != .Ok || pci.read_32(place, 0) & 0xFFFF == pci.VENDOR_VIRTIO {
		return place
	}
	bridge := pci.Place{device = pci.SCRATCH_BRIDGE_DEVICE}
	if pci.read_32(bridge, 0) & 0xFFFF == 0xFFFF || pci.read_32(bridge, pci.OFFSET_HEADER_TYPE) >> 16 & 0x7F != 1 {
		return place
	}
	return pci.Place{bus = pci.read_32(bridge, pci.OFFSET_BUS_NUMBERS) >> 8 & 0xFF, device = 0}
}

// The service of a device behind a conventional bridge holds the registers
// of each other device there in the grants after those of its own BARs.
#assert(pci.GRANT_BRIDGE_DEVICE + pci.BRIDGE_DEVICE_COUNT <= op.CONTEXT_LOG)

// The buses behind a conventional bridge. Every device there gives its
// accesses one shared requester, so the IOMMU cannot tell them apart: the
// kernel gives them one domain, and only for a service that holds the
// registers of each of them (src/md/infrastructure/iommu.md, "Bridges").
// This service gives them all to the service of the first one that it
// starts.
Bridge_Group :: struct {
	first_bus: u32,
	last_bus:  u32,
}

// bridge_group_of gives the buses behind the conventional bridge nearest to
// bus 0 on the way to a bus: the bridge that makes the requests of each
// device behind it. found: no conventional bridge is on that way.
bridge_group_of :: proc "contextless" (bus: u32) -> (group: Bridge_Group, found: bool) {
	current := u32(0)
	// Each level goes down at least one bus, so 256 levels end the walk.
	levels: for _ in 0 ..< 256 {
		if current == bus {
			return {}, false
		}
		for device in u32(0) ..< 32 {
			for function in u32(0) ..< 8 {
				place := pci.Place{bus = current, device = device, function = function}
				if pci.read_32(place, 0) & 0xFFFF == 0xFFFF {
					if function == 0 {
						break // No device at this place.
					}
					continue
				}
				header_type := pci.read_32(place, pci.OFFSET_HEADER_TYPE) >> 16 & 0xFF
				if header_type & 0x7F == 1 {
					numbers := pci.read_32(place, pci.OFFSET_BUS_NUMBERS)
					secondary, subordinate := numbers >> 8 & 0xFF, numbers >> 16 & 0xFF
					if secondary > current && secondary <= bus && bus <= subordinate {
						configuration: [bridge_requester.CONFIGURATION_WORDS]u32
						for &word, index in configuration {
							word = pci.read_32(place, u32(index * 4))
						}
						if !bridge_requester.bridge_passes_requesters(&configuration) {
							return {first_bus = secondary, last_bus = subordinate}, true
						}
						current = secondary
						continue levels
					}
				}
				if function == 0 && header_type & 0x80 == 0 {
					break // One function only.
				}
			}
		}
		return {}, false // No bridge leads to the bus.
	}
	return {}, false
}

// bridge_devices_hold makes a handle to the first page of the registers of
// the first memory BAR of each device behind a conventional bridge but the
// one at a place:
// the device service of that place holds them all. A device with no memory
// BAR gets no handle, and the kernel then refuses the domain of all of
// them. More than pci.BRIDGE_DEVICE_COUNT other devices give No_Slot, with
// one line.
bridge_devices_hold :: proc "contextless" (group: Bridge_Group, place: pci.Place) -> (handles: [pci.BRIDGE_DEVICE_COUNT]system.Handle, count: u32, status: system.Status) {
	for bus in group.first_bus ..= group.last_bus {
		for device in u32(0) ..< 32 {
			for function in u32(0) ..< 8 {
				member := pci.Place{bus = bus, device = device, function = function}
				if pci.read_32(member, 0) & 0xFFFF == 0xFFFF {
					if function == 0 {
						break
					}
					continue
				}
				header_type := pci.read_32(member, pci.OFFSET_HEADER_TYPE) >> 16 & 0xFF
				// A bridge behind the conventional bridge makes no request of
				// its own: only the devices behind it, which are on these buses.
				if header_type & 0x7F == 0 && member != place {
					if count == pci.BRIDGE_DEVICE_COUNT {
						system.log_fact(.Error, Bridge_Devices_Too_Many{device_limit = u64(pci.BRIDGE_DEVICE_COUNT + 1), bus = u64(group.first_bus)})
						return handles, count, .No_Slot
					}
					// The handle names the device for the IOMMU by the first
					// page of its register: the address is enough. A size
					// would turn the memory of a device off, which another
					// party can use at that time (pci.bar_address).
					for index in 0 ..< pci.BAR_COUNT {
						if address := pci.bar_address(member, index); address != 0 {
							handles[count], _, status = device_handle(.Memory, address &~ (system.PAGE_SIZE - 1), 1)
							if status != .Ok {
								return handles, count, status
							}
							break
						}
					}
					count += 1
				}
				if function == 0 && header_type & 0x80 == 0 {
					break
				}
			}
		}
	}
	return handles, count, .Ok
}

// driver_start starts the device service of the device at a place of the
// bus. It gives the ring of the device service: this service gives it to
// the client. The lines of the log name a device of bus 0 by its place
// only, and another one with its bus.
driver_start :: proc "contextless" (place: pci.Place, kind: Driver = DRIVER_BLOCK) -> (driver: ^Started, ring_memory: system.Handle, status: system.Status) {
	configuration_open() or_return
	service_name := kind.fixed_module ? kind.name : device_class_holder_name(kind.role, kind.name)
	// The devices service classified the bus before any device service:
	// a device that it did not give the class of the service is not armed.
	if !bus_classified {
		system.log_fact(.Error, Device_Unclassified{device = u64(place.device), bus = u64(place.bus), service = module_name_field(service_name)})
		return nil, 0, .Bad_State
	}
	identity, identity_found := classified_identity_at(place, kind.role)
	if !identity_found {
		if place.bus == 0 {
			system.log_fact(.Error, Virtio_Device_Absent{device = u64(place.device), service = module_name_field(service_name)})
		} else {
			system.log_fact(.Error, Virtio_Device_Absent_Behind_Bridge{device = u64(place.device), bus = u64(place.bus), service = module_name_field(service_name)})
		}
		return nil, 0, .Bad_Handle
	}
	group, behind_conventional_bridge := bridge_group_of(place.bus)
	for &item in started {
		if item.process != 0 && item.is_driver && (item.device == place || (behind_conventional_bridge && item.bridge_group == group)) {
			return nil, 0, .Bad_State // One service for one device, and for all the devices behind one conventional bridge.
		}
	}
	// The layout of the context first, before the device is armed: a
	// refusal then leaves the device as it was, with no bus master and no
	// message interrupt.
	trial := pci.service_context_trial(kind.ring_role)
	no_values: system.Context_Values
	if context_refused(kind.name, &trial, &no_values) {
		return nil, 0, .Bad_State
	}
	for &item in started {
		if place_is_free(&item) {
			driver = &item
			break
		}
	}
	if driver == nil {
		return nil, 0, .No_Slot
	}
	driver^ = {}

	// The slots of a device service are the layout of package pci and of
	// the ring of its contract: each handle takes its own slot, so a new
	// handle of the layout cannot take the slot of another in silence.
	start_grant_set := start_grant_set_of(kind.name)
	context_grants: system.Context_Grants
	values: system.Context_Values
	system.grant_put(&context_grants, op.CONTEXT_LOG, log_grant(start_grant_set))

	// Behind a conventional bridge, the registers of each other device
	// there: no other service can then drive a device that reaches what
	// this one declares.
	bridge_devices: [pci.BRIDGE_DEVICE_COUNT]system.Handle
	bridge_device_count: u32
	defer for handle in bridge_devices {
		if handle != 0 {
			system.close(handle)
		}
	}
	if behind_conventional_bridge {
		bridge_devices, bridge_device_count, status = bridge_devices_hold(group, place)
		if status != .Ok {
			return nil, 0, status
		}
		for handle, index in bridge_devices {
			if handle != 0 {
				system.grant_put(&context_grants, pci.GRANT_BRIDGE_DEVICE + index, {handle, {.Read, .Write}})
			}
		}
	}

	armed: Armed_Device
	armed, status = device_arm(place, identity, DEVICE_SERVICE_LAYOUT, &context_grants)
	if status != .Ok {
		return nil, 0, status
	}
	defer device_arm_handles_close(&armed)
	if kind.role == .Network_Device {
		network_device_windows = armed.windows
	}
	ring_memory, status = system.memory_create(ring.pages(kind.ring_capacity))
	if status == .Ok {
		system.grant_put(&context_grants, kind.ring_role, {ring_memory, {.Read, .Write}})
		driver_mappings: [1]system.Mapping
		driver_mapping_count := 0
		fresh_bytes_page_give(driver, driver_mappings[:], &driver_mapping_count, &values)
		if context_refused(service_name, &context_grants, &values) {
			status = .Bad_State
		} else {
			driver.process, status = system.process_start(image_file_checked(service_name), service_name, context_grants.grants, random.values_with_seed(&process_generator, values.values), budget_of(image_file_checked(service_name), service_name), driver_mappings[:driver_mapping_count], &prepared, load_source())
		}
	}
	if status != .Ok {
		fresh_bytes_forget(driver)
		device_arm_undo(&armed)
		if ring_memory != 0 {
			system.close(ring_memory)
		}
		driver^ = {}
		return nil, 0, status
	}
	if behind_conventional_bridge {
		driver.bridge_group = group
	}
	driver.start_grant_set = start_grant_set
	driver.granted = {.Log}
	copy(driver.name[:len(driver.name) - 1], kind.name)
	if place.bus == 0 {
		system.log_fact(.Info, Device_Service_Started{service = module_name_field(kind.name), device = u64(place.device)})
	} else {
		system.log_fact(.Info, Device_Service_Started_Behind_Bridge{service = module_name_field(kind.name), device = u64(place.device), bus = u64(place.bus)})
	}
	if behind_conventional_bridge {
		system.log_fact(.Info, Bridge_Registers_Held{bus = u64(group.first_bus), other_devices = u64(bridge_device_count), service = module_name_field(kind.name)})
	}
	device_arm_keep(driver, &armed)
	return driver, ring_memory, .Ok
}

// The slots of the context where this service puts a virtio device. A
// device service has the layout of package pci. The input service keeps the
// PS/2 controller in the slots of the interrupt, the queues and the machine
// of that layout, so its tablet takes those three in other slots.
Device_Context_Layout :: struct {
	interrupt:     int,
	queues:        int,
	machine:       int,
	configuration: int,
	first_bar:     int, // first_bar + n: the registers in BAR n.
}

DEVICE_SERVICE_LAYOUT :: Device_Context_Layout {
	interrupt     = pci.GRANT_INTERRUPT,
	queues        = pci.GRANT_QUEUES,
	machine       = pci.GRANT_MACHINE,
	configuration = pci.GRANT_CONFIGURATION,
	first_bar     = pci.GRANT_BAR,
}

// A device that device_arm armed for a process that is not started yet.
// Its bus master is on, its message interrupt is entry 0 of its table, and
// the handles of made are in the context grants of the process.
Armed_Device :: struct {
	place:            pci.Place,
	identity:         u32,
	bars:             [pci.BAR_COUNT]pci.Bar,
	interrupt_vector: u32,
	table_bar:        u32,
	pending_bar:      u32,
	// Each memory range of the device has device windows of the IOMMU, and
	// one range at least was read.
	windows:          bool,
	bus_master_on:    bool,
	// This service keeps the memory of the queues until the device stops
	// using it (driver_end).
	queues:           system.Handle,
	// What this service creates for the start and does not keep: the
	// interrupt, the copy of the configuration, and the memory of each BAR.
	made:             [2 + pci.BAR_COUNT]system.Handle,
}

// classified_identity_at reads the identifiers of the device at a place
// again, and gives them when the devices service classified that device
// with a role. A place whose device changed since the classification does
// not take the class of the device of before.
classified_identity_at :: proc "contextless" (place: pci.Place, role: rd.Device_Class_Role) -> (identity: u32, found: bool) {
	if !bus_classified || configuration_open() != .Ok {
		return 0, false
	}
	identity = pci.read_32(place, 0)
	classified, classified_found := classified_device_at(place)
	if !classified_found || classified.vendor_id != u16(identity & 0xFFFF) || classified.device_id != u16(identity >> 16) || classified.role != role {
		return 0, false
	}
	return identity, true
}

// device_arm gives the device at a place its memory and its message
// interrupt, turns its bus master on, and puts into the context grants of a
// process its interrupt, the memory of its queues, the machine, a copy of
// its configuration and the memory of each BAR, at the slots of a layout.
// On a failure, it leaves the device with no bus master, closes what it
// made, and puts no grant into the context.
device_arm :: proc "contextless" (place: pci.Place, identity: u32, layout: Device_Context_Layout, context_grants: ^system.Context_Grants) -> (armed: Armed_Device, status: system.Status) {
	armed.place = place
	armed.identity = identity
	succeeded := false
	defer if !succeeded {
		device_arm_undo(&armed)
	}
	// The device: no line interrupt, its memory, and its message interrupt.
	command := pci.read_16(place, pci.OFFSET_COMMAND)
	pci.write_16(place, pci.OFFSET_COMMAND, command &~ pci.COMMAND_BUS_MASTER | pci.COMMAND_MEMORY | pci.COMMAND_NO_LINE_INTERRUPT)
	armed.bars = pci.bars(place)
	configuration: [pci.CONFIGURATION_SIZE / 4]u32
	for &word, index in configuration {
		word = pci.read_32(place, u32(index * 4))
	}
	bytes := transmute([pci.CONFIGURATION_SIZE]u8)configuration
	table := pci.capability(bytes[:], pci.CAPABILITY_MSI_X)
	if table == 0 {
		return armed, .Bad_Operation
	}
	// A virtio device that a process held before keeps the addresses of
	// its queues in memory that is free now: it is reset before its bus
	// master goes on, so it writes nowhere until its new holder gives it
	// queues.
	if identity & 0xFFFF == pci.VENDOR_VIRTIO && !virtio_device_reset(armed.bars, bytes[:]) {
		return armed, .Bad_State
	}
	table_place := configuration[(table + 4) / 4]
	pending_place := configuration[(table + 8) / 4]
	armed.table_bar = table_place & 7
	armed.pending_bar = pending_place & 7
	if armed.table_bar >= pci.BAR_COUNT || armed.bars[armed.table_bar].size == 0 {
		return armed, .Bad_Operation
	}
	// The message interrupt of this device: the kernel names the device by
	// the base of the register that holds the table, so with interrupt
	// remapping no other device can send it.
	interrupt: system.Handle
	message: [7]u64
	interrupt, message, status = device_handle(.Message, armed.bars[armed.table_bar].address, 0)
	if status != .Ok {
		return armed, status
	}
	armed.made[0] = interrupt
	armed.interrupt_vector = u32(message[2])
	{
		// Entry 0 of the table of the device: the address, the value, not masked.
		page := (armed.bars[armed.table_bar].address + u64(table_place &~ 7)) &~ (system.PAGE_SIZE - 1)
		registers, _ := device_handle(.Memory, page, 1) or_return
		defer system.close(registers)
		address := system.memory_map(registers, {.Write}) or_return
		entry := ([^]u32)(uintptr(address) + uintptr((u64(table_place &~ 7)) & (system.PAGE_SIZE - 1)))
		entry[0] = u32(message[1])
		entry[1] = u32(message[1] >> 32)
		entry[2] = u32(message[2])
		entry[3] = 0
		system.memory_unmap(address)
	}
	control := pci.read_16(place, table + 2)
	pci.write_16(place, table + 2, control &~ (1 << 14) | 1 << 15) // Enabled, not masked.
	pci.write_16(place, pci.OFFSET_COMMAND, command | pci.COMMAND_MEMORY | pci.COMMAND_BUS_MASTER | pci.COMMAND_NO_LINE_INTERRUPT)
	armed.bus_master_on = true

	// The memory of each BAR, except the BARs of the table of the
	// interrupts: the process does not change its interrupt.
	// The kernel says of each range whether the IOMMU gives the device
	// device windows; every range of one device names the same device.
	// No range read: no fact, so the region of the network stays contiguous.
	windows, read_a_range := true, false
	for bar, index in armed.bars {
		if bar.size == 0 || u32(index) == armed.table_bar || u32(index) == armed.pending_bar {
			continue
		}
		memory: system.Handle
		facts: [7]u64
		memory, facts, status = device_handle(.Memory, bar.address, (bar.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE)
		if status != .Ok {
			return armed, status
		}
		windows &&= .Windows in transmute(op.Device_Memory_Facts)facts[1]
		read_a_range = true
		armed.made[2 + index] = memory
	}
	armed.windows = windows && read_a_range
	copied := system.memory_create(1) or_return
	armed.made[1] = copied
	{
		address := system.memory_map(copied, {.Write}) or_return
		([^][pci.CONFIGURATION_SIZE]u8)(address)[0] = bytes
		system.memory_unmap(address)
	}
	armed.queues = system.memory_create(pci.QUEUE_PAGES, 0, {.Contiguous}) or_return // The device reads and writes it.
	// The grants go into the context only once every handle exists: a
	// failure then leaves no closed handle in the context.
	system.grant_put(context_grants, layout.interrupt, {armed.made[0], {.Read}})
	for index in 0 ..< pci.BAR_COUNT {
		if armed.made[2 + index] != 0 {
			system.grant_put(context_grants, layout.first_bar + index, {armed.made[2 + index], {.Read, .Write}})
		}
	}
	system.grant_put(context_grants, layout.configuration, {armed.made[1], {.Read}})
	system.grant_put(context_grants, layout.queues, {armed.queues, {.Read, .Write}})
	system.grant_put(context_grants, layout.machine, {machine, {.Physical}})
	succeeded = true
	return armed, .Ok
}

// virtio_device_reset writes the device status 0 in the common
// configuration of a virtio device and waits, by a count of reads, until
// the device says 0: the device then forgets its queues and its features.
// false: the device has no common configuration inside a BAR, or does not
// finish its reset.
virtio_device_reset :: proc "contextless" (bars: [pci.BAR_COUNT]pci.Bar, configuration: []u8) -> bool {
	bar, place, found := virtio.common_place(configuration)
	if !found || bars[bar].size == 0 || !virtio.region_fits(u64(place), u64(virtio.COMMON_CONFIG_SIZE), bars[bar].size) {
		return false
	}
	start := bars[bar].address + u64(place)
	first_page := start &~ (system.PAGE_SIZE - 1)
	last_page := (start + u64(virtio.COMMON_CONFIG_SIZE) - 1) &~ (system.PAGE_SIZE - 1)
	registers, _, status := device_handle(.Memory, first_page, (last_page - first_page) / system.PAGE_SIZE + 1)
	if status != .Ok {
		return false
	}
	defer system.close(registers)
	address, map_status := system.memory_map(registers, {.Write})
	if map_status != .Ok {
		return false
	}
	defer system.memory_unmap(address)
	device := virtio.Device{common = uintptr(address) + uintptr(start - first_page)}
	virtio.status_write(&device, 0)
	return virtio.reset_done(&device)
}

// device_arm_handles_close closes the handles that device_arm made for the
// start: the process holds its own.
device_arm_handles_close :: proc "contextless" (armed: ^Armed_Device) {
	for &handle in armed.made {
		if handle != 0 {
			system.close(handle)
			handle = 0
		}
	}
}

// device_arm_undo takes the device back when its process did not start:
// the bus master goes off before the memory of the queues is freed, so the
// device never writes to a freed page.
device_arm_undo :: proc "contextless" (armed: ^Armed_Device) {
	if armed.bus_master_on {
		current := pci.read_16(armed.place, pci.OFFSET_COMMAND)
		pci.write_16(armed.place, pci.OFFSET_COMMAND, current &~ pci.COMMAND_BUS_MASTER)
		armed.bus_master_on = false
	}
	if armed.queues != 0 {
		system.close(armed.queues)
		armed.queues = 0
	}
	device_arm_handles_close(armed)
}

// device_arm_keep records the device in the place of its started process:
// the stop of the process then turns its bus master off and frees its
// queues (driver_end), and the devices service binds it to the process.
device_arm_keep :: proc "contextless" (slot: ^Started, armed: ^Armed_Device) {
	slot.is_driver = true
	slot.bus_master_active = true
	slot.device = armed.place
	slot.queues = armed.queues
	armed.bus_master_on = false
	armed.queues = 0
	devices_bind_tell(slot, armed.place, armed.identity, armed.bars, armed.interrupt_vector, armed.table_bar, armed.pending_bar)
}

// The display registers of the standard VGA, mapped while the compositor
// flips between two screen pages: a failure of the start shows the page 0
// again, where this service draws the boot display
// (src/md/infrastructure/whole_frame.md). nil: the compositor writes the
// framebuffer of the firmware, and the display always shows the page 0.
display_registers_address: rawptr
display_screen_height: int

// display_open finds the standard VGA of the machine and gives what the
// compositor needs to flip between two screen pages: the memory of the two
// pages, which starts with the framebuffer of the firmware, and the memory
// of the registers of the VGA. It gives 0 and 0, with one line, when the
// machine has no such device or when its mode holds no two pages: the
// compositor then gets the framebuffer of the firmware.
display_open :: proc "contextless" (framebuffer_address, width, height, pixels_per_line: u64) -> (pages_memory, registers: system.Handle) {
	if framebuffer_address == 0 || configuration_open() != .Ok {
		return 0, 0
	}
	place := pci.Place{device = bochs_display.PLACE_DEVICE}
	identity := pci.read_32(place, 0)
	if identity & 0xFFFF != bochs_display.VENDOR || identity >> 16 != bochs_display.DEVICE {
		system.log_fact(.Info, Standard_Vga_Absent{device = u64(bochs_display.PLACE_DEVICE)})
		return 0, 0
	}
	// The addresses only, with no size: a size turns the memory of the
	// device off while the display shows it, and under KVM it throws away
	// every nested page table of the machine
	// (src/md/infrastructure/whole_frame.md). The display registers give
	// the size of the video memory (bochs_display.screen_pages).
	video_address := pci.bar_address(place, bochs_display.VIDEO_MEMORY_BAR)
	registers_address := pci.bar_address(place, bochs_display.REGISTERS_BAR)
	page_bytes := pixels_per_line * height * size_of(u32)
	decodes_memory := pci.read_16(place, pci.OFFSET_COMMAND) & pci.COMMAND_MEMORY != 0
	if !decodes_memory || video_address != framebuffer_address || registers_address == 0 || registers_address % system.PAGE_SIZE != 0 {
		system.log_fact(.Info, Standard_Vga_Without_Framebuffer{})
		return 0, 0
	}
	status: system.Status
	registers, _, status = device_handle(.Memory, registers_address, 1)
	if status != .Ok {
		return 0, 0
	}
	address, map_status := system.memory_map(registers, {.Write})
	if map_status != .Ok {
		system.close(registers)
		return 0, 0
	}
	display_registers := rawptr(uintptr(address) + bochs_display.DISPLAY_REGISTERS_OFFSET)
	if bochs_display.screen_pages(display_registers, width, height, pixels_per_line) < bochs_display.PAGE_COUNT {
		system.log_fact(.Info, Standard_Vga_Mode_Unknown{})
		system.memory_unmap(address)
		system.close(registers)
		return 0, 0
	}
	pages_memory, _, status = device_handle(.Display_Memory, video_address, (bochs_display.PAGE_COUNT * page_bytes + system.PAGE_SIZE - 1) / system.PAGE_SIZE)
	if status != .Ok {
		system.memory_unmap(address)
		system.close(registers)
		return 0, 0
	}
	display_registers_address = display_registers
	display_screen_height = int(height)
	return pages_memory, registers
}

// driver_bus_master_disable clears PCI Bus Master on the device of driver,
// stopping DMA immediately.
driver_bus_master_disable :: proc "contextless" (driver: ^Started) {
	command := pci.read_16(driver.device, pci.OFFSET_COMMAND)
	pci.write_16(driver.device, pci.OFFSET_COMMAND, command &~ pci.COMMAND_BUS_MASTER)
}

// started_process_stop stops a started process. When the process is a
// device service, PCI Bus Master is turned off before Process_Stop so the
// device makes no memory access between the stop and the reap, also on a
// machine with no IOMMU.
started_process_stop :: proc "contextless" (item: ^Started) {
	if item == nil {
		return
	}
	actions := device_stop.stop_decide(item.process != 0, item.is_driver, &item.bus_master_active)
	if actions.disable_bus_master_before_stop {
		driver_bus_master_disable(item)
	}
	if actions.stop_process {
		system.process_stop(item.process)
	}
}

// driver_end takes the device back from a device service that stopped: turns
// PCI Bus Master off if the service stopped on its own, then closes the
// memory of its queue so it returns to the budget.
driver_end :: proc "contextless" (driver: ^Started) {
	devices_release_tell(driver)
	actions := device_stop.reap_decide(driver.is_driver, &driver.bus_master_active)
	if actions.disable_bus_master {
		driver_bus_master_disable(driver)
	}
	if actions.close_queues {
		system.close(driver.queues)
	}
}
