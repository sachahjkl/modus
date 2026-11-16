// The test device service of the IOMMU: a device service of the virtio
// block device of the disk of the measures that gives its device an
// address that it did not declare. The root service starts it in place of
// the block service for the one client `iommu` (src/programs/iommu); no
// other program can start it. The design is
// src/md/infrastructure/iommu.md, "The proof".
//
// **What it shows.** On a machine with the IOMMU, a device reaches only the
// pages that its service declared with `Memory_Physical`, and sends only
// the message interrupts that its service was given:
//
// 1. It declares its queue and a data object of two pages, writes a block
//    of the disk from the first page and reads it into the second: the
//    bytes arrive, and the message interrupt of the device arrives through
//    its entry.
// 2. It writes a block of zeros, then reads it into the interrupt
//    addresses: each write of the device there is a message that names an
//    entry that the kernel did not give it. On the IOMMU of Intel the kernel
//    writes the line of the refused interrupt; the emulated IOMMU of AMD
//    records no event for such a message, so no line comes there.
// 3. It declares a new page with a known pattern, then closes its handle
//    and keeps its mapping: the kernel takes the page out of the domain of
//    the device at the close, and the service can still read it.
// 4. It gives the address of that page to the device as the buffer of a
//    read of the same block.
// 5. It waits until the device needs a reset or used the request, and
//    checks that the page keeps its pattern. The kernel writes the line of
//    the DMA fault, with the device and the address.
//
// The forged messages come before the DMA fault: a virtio device of QEMU
// that needs a reset does no more requests.
//
// 6. Behind a conventional bridge, where the root service gives it the
//    registers of the other device there too, it starts its device again,
//    then closes those registers: its domain ends, its next declaration is
//    refused, with a line of the kernel, and a read of the device into a
//    page that it declared before does not arrive.
//
// Then it answers the commands of the block ring, so that its client
// sees that the machine goes on.
//
// **What a reader sees.** No window: the lines `iommu_device: ...` on the
// log, each one with "as it must" when the rule held. On a machine with no
// IOMMU the device writes the page, and the line says so. The writes go to
// the disk of the measures, which holds no data of a program.
package iommu_device_service

import "modus:contract/block"
import "modus:contract/ring"
import "modus:support/pci"
import "modus:support/system"
import "modus:support/virtio"

// The budget of a block service: it drives one disk through one ring.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 180, programs = 1, threads = 1}

REQUEST_READ :: 0
REQUEST_WRITE :: 1
SECTOR_SIZE :: 512
// The block of the disk that the test writes and reads.
TEST_BLOCK :: 0

// The bytes of the page that the device writes in step 1, and of the page
// that it must not write in step 3.
PATTERN_WRITTEN :: 0x5A
PATTERN_KEPT :: 0xC3

// The buffer of the forged messages, in the interrupt addresses
// (src/md/infrastructure/iommu.md, "Interrupt remapping"). Each write of 4
// bytes of the block is one message. A write whose bit 4 is set is in the
// remappable form, and names an entry from 0x7800 on, past the interrupt
// table of 16 entries. A write whose bit 4 is clear is in the compatible
// form, and names the processor 0xF0 (the bits 19:12), which does not
// exist: QEMU passes that form, which a unit of a real machine refuses.
FORGED_MESSAGE_ADDRESS :: 0xFEEF_0000

// The memory of the queue (pci.QUEUE_PAGES): pages 0 to 2 the virtqueue,
// page 3 the header and the status of the one request.
PAGE_REQUESTS :: virtio.QUEUE_PAGES
STATUS_PLACE :: 2048

Header :: struct {
	kind:     u32,
	reserved: u32,
	sector:   u64,
}

device: virtio.Device
queue: virtio.Queue
header: ^Header
status: ^u8
requests: u64 // The physical address of the page of the request.

fail :: proc "contextless" (text: string) -> ! {
	system.log_in("iommu", .Error, "iommu_device: ", text)
	system.stop(1)
}

// request gives the device one request for the test block: the header, a
// buffer of one block at a physical address, and the status byte.
request :: proc "contextless" (kind: u32, buffer: u64) {
	header^ = {kind = kind, sector = TEST_BLOCK * (block.BLOCK_SIZE / SECTOR_SIZE)}
	status^ = 0xFF
	descriptors := queue.descriptors
	descriptors[0] = {address = requests, length = size_of(Header), flags = virtio.DESCRIPTOR_NEXT, next = 1}
	descriptors[1] = {address = buffer, length = block.BLOCK_SIZE, flags = virtio.DESCRIPTOR_NEXT | (kind == REQUEST_READ ? virtio.DESCRIPTOR_DEVICE_WRITES : 0), next = 2}
	descriptors[2] = {address = requests + STATUS_PLACE, length = 1, flags = virtio.DESCRIPTOR_DEVICE_WRITES}
	virtio.give(&queue, 0)
	virtio.notify(&queue)
}

// How a request ended.
Outcome :: enum {
	Used, // The device gave the request back: the status byte says how it went.
	Needs_Reset, // The device stopped: it does no more requests.
	Hang, // Neither came before the hang bound.
}

// request_end waits for the condition that ends a request: the device
// used it, or it needs a reset. The configuration interrupt of a device
// that needs a reset and the interrupt of the queue are one message
// interrupt, so each wakes this thread. The hang bound only ends a hang.
// With no interrupt (the end of the domain clears the interrupt entries of
// its group), it reads the two conditions again with no wait.
request_end :: proc "contextless" (interrupt_arrives := true) -> Outcome {
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for {
		wait := system.wait_begin()
		if _, used := virtio.used(&queue); used {
			return .Used
		}
		if virtio.status_read(&device) & virtio.STATUS_NEEDS_RESET != 0 {
			return .Needs_Reset
		}
		if system.time() >= deadline {
			return .Hang
		}
		if interrupt_arrives {
			system.wait_end(&wait, deadline)
		}
	}
}

// page_holds says if each byte of one page is value.
page_holds :: proc "contextless" (bytes: [^]u8, value: u8) -> bool {
	for index in 0 ..< block.BLOCK_SIZE {
		if bytes[index] != value {
			return false
		}
	}
	return true
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	machine := ctx.handles[pci.GRANT_MACHINE]
	clients, ring_status := system.ring_open(ctx.handles[block.SERVICE_RING])
	if ring_status != .Ok {
		fail("no block ring")
	}
	configuration_address, configuration_status := system.memory_map(ctx.handles[pci.GRANT_CONFIGURATION], {})
	if configuration_status != .Ok {
		fail("no configuration of the device")
	}
	found: bool
	if device, found = virtio.find(ctx, ([^]u8)(configuration_address)[:pci.CONFIGURATION_SIZE]); !found {
		fail("the device has no virtio registers in the memory that it received")
	}
	if _, start_error := virtio.start(&device, 0); start_error != .None {
		fail("the device did not start")
	}
	// The configuration interrupt has the vector of the queue: a device that
	// needs a reset wakes the wait of request_end.
	virtio.store_16(device.common + virtio.COMMON_CONFIG_VECTOR, 0)
	queues := ctx.handles[pci.GRANT_QUEUES]
	queue_address, map_status := system.memory_map(queues, {.Write})
	queue_physical, physical_status := system.memory_physical(machine, queues)
	if map_status != .Ok || physical_status != .Ok || system.memory_size(queues) < pci.QUEUE_PAGES {
		fail("no memory for the queue")
	}
	queue_error: virtio.Queue_Error
	if queue, queue_error = virtio.queue_start(&device, 0, uintptr(queue_address), queue_physical, 3, 0); queue_error != .None {
		fail("the queue of the device did not start")
	}
	header = (^Header)(uintptr(queue_address) + PAGE_REQUESTS * system.PAGE_SIZE)
	status = (^u8)(uintptr(queue_address) + PAGE_REQUESTS * system.PAGE_SIZE + STATUS_PLACE)
	requests = queue_physical + PAGE_REQUESTS * system.PAGE_SIZE
	virtio.ready(&device)

	// 1. Two declared pages: the device reads the first and writes the
	// second.
	data, data_status := system.memory_create(2, 0, {.Contiguous})
	if data_status != .Ok {
		fail("no memory for the data")
	}
	data_address, data_map_status := system.memory_map(data, {.Write})
	data_physical, data_physical_status := system.memory_physical(machine, data)
	if data_map_status != .Ok || data_physical_status != .Ok {
		fail("no address for the data")
	}
	bytes := ([^]u8)(data_address)
	for index in 0 ..< block.BLOCK_SIZE {
		bytes[index] = PATTERN_WRITTEN
		bytes[block.BLOCK_SIZE + index] = 0
	}
	request(REQUEST_WRITE, data_physical)
	written := request_end()
	request(REQUEST_READ, data_physical + block.BLOCK_SIZE)
	read := request_end()
	if written != .Used || read != .Used || status^ != 0 || !page_holds(([^]u8)(uintptr(data_address) + block.BLOCK_SIZE), PATTERN_WRITTEN) {
		fail("a block written from a declared page and read into another declared page did not arrive")
	}
	system.log("iommu_device: a block written from a declared page and read into another declared page: the 4096 bytes arrived: as it must")
	// The message interrupt of each request: through its entry, which names
	// this device. Each interrupt wakes the wait; the hang bound only ends a
	// hang.
	interrupt := ctx.handles[pci.GRANT_INTERRUPT]
	interrupts: u64
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for {
		wait := system.wait_begin()
		counted, _ := system.call(.Interrupt_Read, u64(interrupt))
		interrupts += counted[0]
		if interrupts != 0 || system.time() >= deadline {
			break
		}
		system.wait_end(&wait, deadline)
	}
	if interrupts == 0 {
		fail("the device ended its requests, and no message interrupt arrived before the hang bound")
	}
	system.log("iommu_device: the message interrupt of the device arrived through its entry: as it must")

	// 2. Messages that no entry gives this device: a read of a block of
	// zeros into the interrupt addresses, so each message has the value 0.
	for index in 0 ..< block.BLOCK_SIZE {
		bytes[index] = 0
	}
	request(REQUEST_WRITE, data_physical)
	zeroed := request_end()
	request(REQUEST_READ, FORGED_MESSAGE_ADDRESS)
	forged := request_end()
	if zeroed != .Used || forged != .Used {
		fail("a read into the interrupt addresses: the device did not give the request back")
	}
	system.log("iommu_device: a read into the interrupt addresses, to entries that the kernel did not give this device: the device gave the request back: as it must")

	// 3. A page that this service declares, then no longer holds: it closes
	// its handle and keeps its mapping, so it can still read the page. The
	// kernel takes the page out of the domain of the device at the close.
	page, page_status := system.memory_create(1, 0, {.Contiguous})
	if page_status != .Ok {
		fail("no memory for the page that is not declared")
	}
	page_address, page_map_status := system.memory_map(page, {.Write})
	page_physical, page_physical_status := system.memory_physical(machine, page)
	if page_map_status != .Ok || page_physical_status != .Ok {
		fail("no address for the page that is not declared")
	}
	page_bytes := ([^]u8)(page_address)
	for index in 0 ..< block.BLOCK_SIZE {
		page_bytes[index] = PATTERN_KEPT
	}
	system.close(page)

	// 4. The address of that page in a descriptor of a read.
	request(REQUEST_READ, page_physical)
	outcome := request_end()

	// 5. The page keeps its bytes when the device did not reach it.
	kept := page_holds(page_bytes, PATTERN_KEPT)
	switch {
	case !kept:
		system.log("iommu_device: a read into a page that was not declared: the device wrote the page: no IOMMU keeps the device in the memory of its service on this machine")
	case outcome == .Needs_Reset:
		system.log("iommu_device: a read into a page that was not declared: the device needs a reset, and the page keeps its 4096 bytes: as it must")
	case outcome == .Used:
		system.log("iommu_device: a read into a page that was not declared: the device gave the request back with the status ", u64(status^), ", and the page keeps its 4096 bytes: as it must")
	case:
		system.log("iommu_device: a read into a page that was not declared: the device did not end the request before the hang bound")
	}

	// 6. Behind a conventional bridge only: the devices there share one
	// requester, and this service holds the registers of the other device
	// too. Without them, its domain ends, and a new declaration is refused:
	// the other device would reach what it declares.
	if other_device := ctx.handles[pci.GRANT_BRIDGE_DEVICE]; other_device != 0 {
		// The device needs a reset after the refused read of step 4: it
		// starts again while its domain lives, so that its next request
		// shows the end of the domain and not that state.
		if _, restart_error := virtio.start(&device, 0); restart_error != .None {
			fail("the device did not start again")
		}
		virtio.store_16(device.common + virtio.COMMON_CONFIG_VECTOR, 0)
		if queue, queue_error = virtio.queue_start(&device, 0, uintptr(queue_address), queue_physical, 3, 0); queue_error != .None {
			fail("the queue of the device did not start again")
		}
		virtio.ready(&device)
		system.close(other_device)
		refused, refused_status := system.memory_create(1, 0, {.Contiguous})
		if refused_status != .Ok {
			fail("no memory for the page of the refused declaration")
		}
		_, declare_status := system.memory_physical(machine, refused)
		if declare_status != .Bad_State {
			fail("without the registers of the other device behind the conventional bridge, a declaration was not refused")
		}
		system.close(refused)
		system.log("iommu_device: without the registers of the other device behind the conventional bridge, a declaration is refused: as it must")
		// The domain ended: a read into the second page of the data, which
		// this service declared in step 1 and still holds, does not arrive.
		second_page := ([^]u8)(uintptr(data_address) + block.BLOCK_SIZE)
		for index in 0 ..< block.BLOCK_SIZE {
			second_page[index] = PATTERN_KEPT
		}
		// The end of the domain cleared the interrupt entries of the group
		// and waited for each unit: no interrupt counted from now on came
		// through them. The count before is read and dropped.
		_, _ = system.call(.Interrupt_Read, u64(interrupt))
		request(REQUEST_READ, data_physical + block.BLOCK_SIZE)
		// A device of QEMU that cannot read its queue needs a reset, and
		// sends its configuration interrupt, which the unit refuses.
		ended_outcome := request_end(interrupt_arrives = false)
		if !page_holds(second_page, PATTERN_KEPT) || (ended_outcome == .Used && status^ == 0) {
			fail("after the end of its domain, the device read a block into a page that this service declared before")
		}
		if ended_outcome != .Needs_Reset {
			fail("after the end of its domain, the device did not stop on its queue before the hang bound")
		}
		after_end, _ := system.call(.Interrupt_Read, u64(interrupt))
		if after_end[0] != 0 {
			fail("after the end of its domain, the device sent an interrupt that arrived")
		}
		system.log("iommu_device: after the end of its domain, a read of the device into a page that this service declared before does not arrive, the device needs a reset, no interrupt of it arrives, and the page keeps its 4096 bytes: as it must")
	}

	// Then it answers its client: the machine goes on.
	for {
		wait := system.wait_begin()
		changed := false
		for {
			command, ok := system.receive(&clients.commands)
			if !ok {
				break
			}
			kind := block.Status.Unsupported
			if block.Command(command.kind) == .Info {
				kind = .Ok
			}
			ring.push(&clients.completions, ring.Record{kind = u32(kind), tag = command.tag})
			changed = true
		}
		if changed {
			system.wake_reader(&clients.completions)
		}
		system.wait_records(&wait, &clients.commands)
		system.wait_end(&wait)
	}
}

#assert(size_of(Header) == 16)
#assert(PAGE_REQUESTS < pci.QUEUE_PAGES)
