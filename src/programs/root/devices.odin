package root

import "modus:contract/block"
import "modus:support/bochs_display"
import "modus:contract/entropy_service"
import "modus:contract/frame"
import "modus:contract/iommu"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:support/pci"
import "modus:support/random"
import "modus:support/system"

// The devices of the bus. This service holds the two ports of the
// configuration of all devices: no other program has them. It gives a
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

// A device service, by the class of its device: the program, and the ring
// that it serves to its one client.
Driver :: struct {
	name:          string,
	device:        u32, // The device number of the class on the bus (src/library/support/pci).
	ring_capacity: u32,
	ring_role:     int, // The role of the ring in the context of the device service.
}

DRIVER_BLOCK :: Driver{"block", pci.DEVICE_VIRTIO_BLOCK, block.RING_CAPACITY, block.SERVICE_RING}
DRIVER_FRAME :: Driver{"frame", pci.DEVICE_VIRTIO_NETWORK, frame.RING_CAPACITY, frame.SERVICE_RING}
// The test device service of the IOMMU, for its one client `iommu`, on the
// disk of the measures (src/md/infrastructure/iommu.md, "The proof").
DRIVER_IOMMU_DEVICE :: Driver{"iommu_device", pci.DEVICE_VIRTIO_BLOCK, block.RING_CAPACITY, block.SERVICE_RING}
// The entropy service, whose one client is this service (entropy.odin).
DRIVER_ENTROPY :: Driver{"entropy", pci.DEVICE_VIRTIO_ENTROPY, entropy_service.RING_CAPACITY, entropy_service.SERVICE_RING}

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
						configuration: [iommu.CONFIGURATION_WORDS]u32
						for &word, index in configuration {
							word = pci.read_32(place, u32(index * 4))
						}
						if !iommu.bridge_passes_requesters(&configuration) {
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
						system.log_in("devices", .Error, "root: more than ", u64(pci.BRIDGE_DEVICE_COUNT + 1), " devices behind the conventional bridge in front of the bus ", u64(group.first_bus), ": no service for them")
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
	identity := pci.read_32(place, 0)
	if identity & 0xFFFF != pci.VENDOR_VIRTIO || identity >> 16 != kind.device {
		if place.bus == 0 {
			system.log_in("devices", .Error, "root: no virtio device for ", system.Module_Name{kind.name}, " at the place ", u64(place.device), " of the bus")
		} else {
			system.log_in("devices", .Error, "root: no virtio device for ", system.Module_Name{kind.name}, " at the place ", u64(place.device), " of the bus ", u64(place.bus), ", behind a bridge")
		}
		return nil, 0, .Bad_Handle
	}
	group, behind_conventional_bridge := bridge_group_of(place.bus)
	for &item in started {
		if item.program != 0 && item.is_driver && (item.device == place || (behind_conventional_bridge && item.bridge_group == group)) {
			return nil, 0, .Bad_State // One service for one device, and for all the devices behind one conventional bridge.
		}
	}
	for &item in started {
		if item.program == 0 {
			driver = &item
			break
		}
	}
	if driver == nil {
		return nil, 0, .No_Slot
	}
	driver^ = {}

	// What this service creates here and does not keep.
	made: [2 + pci.BAR_COUNT]system.Handle
	defer for handle in made {
		if handle != 0 {
			system.close(handle)
		}
	}
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[op.CONTEXT_LOG] = log_grant(kind.name)
	grants[pci.GRANT_MACHINE] = {machine, {.Physical}}

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
				grants[pci.GRANT_BRIDGE_DEVICE + index] = {handle, {.Read, .Write}}
			}
		}
	}

	// The device: no line interrupt, its memory, and its message interrupt.
	command := pci.read_16(place, pci.OFFSET_COMMAND)
	pci.write_16(place, pci.OFFSET_COMMAND, command &~ pci.COMMAND_BUS_MASTER | pci.COMMAND_MEMORY | pci.COMMAND_NO_LINE_INTERRUPT)
	bars := pci.bars(place)
	configuration: [pci.CONFIGURATION_SIZE / 4]u32
	for &word, index in configuration {
		word = pci.read_32(place, u32(index * 4))
	}
	bytes := transmute([pci.CONFIGURATION_SIZE]u8)configuration
	table := pci.capability(bytes[:], pci.CAPABILITY_MSI_X)
	if table == 0 {
		return nil, 0, .Bad_Operation
	}
	table_place := configuration[(table + 4) / 4]
	pending_place := configuration[(table + 8) / 4]
	table_bar := table_place & 7
	if table_bar >= pci.BAR_COUNT || bars[table_bar].size == 0 {
		return nil, 0, .Bad_Operation
	}
	// The message interrupt of this device: the kernel names the device by
	// the base of the register that holds the table, so with interrupt
	// remapping no other device can send it.
	interrupt: system.Handle
	message: [7]u64
	interrupt, message, status = device_handle(.Message, bars[table_bar].address, 0)
	if status != .Ok {
		return nil, 0, status
	}
	made[0] = interrupt
	grants[pci.GRANT_INTERRUPT] = {interrupt, {.Read}}
	{
		// Entry 0 of the table of the device: the address, the value, not masked.
		page := (bars[table_bar].address + u64(table_place &~ 7)) &~ (system.PAGE_SIZE - 1)
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

	// The memory of each BAR, except the BARs of the table of the
	// interrupts: the device service does not change its interrupt.
	// The kernel says of each range whether the IOMMU gives the device
	// device windows; every range of one device names the same device.
	// No range read: no fact, so the region of the network stays contiguous.
	windows, read_a_range := true, false
	for bar, index in bars {
		if bar.size == 0 || u32(index) == table_bar || u32(index) == pending_place & 7 {
			continue
		}
		memory: system.Handle
		facts: [7]u64
		memory, facts, status = device_handle(.Memory, bar.address, (bar.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE)
		if status != .Ok {
			return nil, 0, status
		}
		windows &&= .Windows in transmute(op.Device_Memory_Facts)facts[1]
		read_a_range = true
		made[2 + index] = memory
		grants[pci.GRANT_BAR + index] = {memory, {.Read, .Write}}
	}
	if kind.device == pci.DEVICE_VIRTIO_NETWORK {
		network_device_windows = windows && read_a_range
	}
	copied := system.memory_create(1) or_return
	made[1] = copied
	{
		address := system.memory_map(copied, {.Write}) or_return
		([^][pci.CONFIGURATION_SIZE]u8)(address)[0] = bytes
		system.memory_unmap(address)
	}
	grants[pci.GRANT_CONFIGURATION] = {copied, {.Read}}
	// The queues: this service keeps the memory until the device stops
	// using it (driver_end).
	driver.queues = system.memory_create(pci.QUEUE_PAGES, 0, {.Contiguous}) or_return // The device reads and writes it.
	grants[pci.GRANT_QUEUES] = {driver.queues, {.Read, .Write}}
	ring_memory, status = system.memory_create(ring.pages(kind.ring_capacity))
	if status == .Ok {
		grants[kind.ring_role] = {ring_memory, {.Read, .Write}}
		driver.program, status = system.program_start(system.image_find(image, kind.name), kind.name, grants, random.values_with_seed(&program_generator, {}), budget_of(system.image_find(image, kind.name), kind.name))
	}
	if status != .Ok {
		pci.write_16(place, pci.OFFSET_COMMAND, command &~ pci.COMMAND_BUS_MASTER)
		system.close(driver.queues)
		if ring_memory != 0 {
			system.close(ring_memory)
		}
		driver^ = {}
		return nil, 0, status
	}
	driver.is_driver = true
	driver.device = place
	if behind_conventional_bridge {
		driver.bridge_group = group
	}
	driver.role = {.System_Part}
	driver.granted = {.Log}
	copy(driver.name[:len(driver.name) - 1], kind.name)
	if place.bus == 0 {
		system.log_in("devices", .Info, "root: started ", system.Module_Name{kind.name}, " for the device at the place ", u64(place.device), " of the bus")
	} else {
		system.log_in("devices", .Info, "root: started ", system.Module_Name{kind.name}, " for the device at the place ", u64(place.device), " of the bus ", u64(place.bus), ", behind a bridge")
	}
	if behind_conventional_bridge {
		system.log_in("devices", .Info, "root: ", system.Module_Name{kind.name}, " also holds the registers of each other device behind the conventional bridge in front of the bus ", u64(group.first_bus), ", which shares its requester; other devices: ", u64(bridge_device_count))
	}
	return driver, ring_memory, .Ok
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
		system.log_in("devices", .Info, "root: no standard VGA at the place ", u64(bochs_display.PLACE_DEVICE), " of the bus: the compositor writes the screen page that the display shows")
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
		system.log_in("devices", .Info, "root: the standard VGA does not hold the framebuffer of the firmware and its display registers: the compositor writes the screen page that the display shows")
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
		system.log_in("devices", .Info, "root: the display registers of the standard VGA do not say the mode of the framebuffer of the firmware with two screen pages: the compositor writes the screen page that the display shows")
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

// driver_end takes the device back from a block service that stopped: the
// device does not use memory after this, and the memory of its queue can
// return to the budget.
driver_end :: proc "contextless" (driver: ^Started) {
	command := pci.read_16(driver.device, pci.OFFSET_COMMAND)
	pci.write_16(driver.device, pci.OFFSET_COMMAND, command &~ pci.COMMAND_BUS_MASTER)
	system.close(driver.queues)
}
