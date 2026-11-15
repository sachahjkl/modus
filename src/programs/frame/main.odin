// The frame service: the device service of one virtio network device
// (virtio 1.x over PCI, the "modern" interface). It serves the frame
// contract (src/library/contract/frame) to one client, through the frame ring that the
// root service gives to both.
//
// It has one device and nothing else: the registers of the device, one
// message interrupt, memory for the queues, the machine with the right
// Physical only, and a copy of the configuration of the device. The root
// service found the device, enabled it and set its interrupt. The kernel has
// no code for this device: the code that knows a device is a program or a
// library. The code of virtio that the block service also uses is in
// src/library/support/virtio.
//
// The device reads and writes the frame region of the client, and reads its
// read regions: the kernel is not on the path of the data, so data moves
// with no kernel entry. This service does not read a frame: the client
// builds and checks each one.
//
// **What it is for.** It shows that a network driver is a program, with no
// right beyond its one device, and that the frames move with no copy by
// the kernel: the client holds a [frame region](term:frame-region), lends
// it once with `Attach`, and the device reads and writes it directly.
//
// **Who uses it.** The root service starts it for the program with the
// grant **Network_Device**: the [network service](term:network-service),
// which builds and checks each frame. It gives the
// [frame ring](term:frame-ring) to that one client.
//
// **The commands of the frame ring** (`src/library/contract/frame`):
//
// - `Attach`: take the frame region of the client.
// - `Info`: the [hardware address](term:hardware-address), whether the
//   link is up, the most bytes of a frame, and the most `Receive` and
//   `Send` in flight.
// - `Send`: send the frame at a place of the frame region, with a second
//   part from a read region when the client names one; the completion
//   comes when the device read the frame.
// - `Receive`: give a place of the frame region for the next frame that
//   arrives; the completion comes with the frame.
// - `Read_Region_Add`, `Read_Region_Remove`: take, then end, a
//   [read region](term:read-region): memory that the device only reads,
//   where the network service lets the device read the data of a datagram
//   in the datagram region of the program that sends it.
// - `Statistics`: the frames and bytes sent and received, the kernel
//   entries and the interrupts of the service, for a measure.
//
// **What a reader sees.** No window: the line `frame: ok, the hardware
// address <address>, the link is up, queues of ...` on the log, then one
// line for each read region that it takes. A failure
// at the start writes a line at the level error on the channel `frame` and
// stops the service.
//
// **What it does not prove.** It drives virtio under QEMU only, and sends
// no offload. The design of the network is in docs/NETWORK.md.
package frame_service

import "modus:contract/errors"
import "modus:contract/frame"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:support/pci"
import "modus:support/system"
import "modus:support/virtio"

// The working memory: the rest of the pages that the root service gave it
// by its name, once the tool counts its module and its thread.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 179, programs = 1, threads = 1}

// The features of a virtio network device that this service takes.
FEATURE_MAC :: 5 // The configuration has the hardware address.
FEATURE_STATUS :: 16 // The configuration has the state of the link.

// The header of each frame in a virtio network queue, with the virtio 1
// interface and no merged buffers: 12 bytes. This service sends no offload:
// the header of a sent frame is all zero.
HEADER_SIZE :: 12

// The memory of the queues (pci.QUEUE_PAGES): pages 0 to 2 the receive
// queue (virtqueue 0), pages 3 to 5 the send queue (virtqueue 1), page 6 the
// header of each Receive, and one header for each Send.
PAGE_RECEIVE :: 0
PAGE_SEND :: virtio.QUEUE_PAGES
PAGE_HEADERS :: 2 * virtio.QUEUE_PAGES
SEND_HEADER_PLACE :: 2048 // In the page of the headers.
// Zero bytes after the header of a Send, never written: the end of a frame
// shorter than frame.FRAME_LEAST. A device of a real wire pads such a frame,
// but a virtual device sends it as it is, and the frame contract promises
// the least length. The bytes come from here, so that this service never
// copies the data of a read region to pad it.
SEND_PAD_PLACE :: SEND_HEADER_PLACE + 64
#assert(SEND_PAD_PLACE + frame.FRAME_LEAST <= system.PAGE_SIZE)

SLOT_CAPACITY :: virtio.QUEUE_SIZE_LIMIT / 2 // Two descriptors for each Receive.
// A Send has four descriptors: the header, the part in the frame region,
// the part in a read region, and the zero bytes of a short frame.
SEND_DESCRIPTORS :: 4

// A request in flight.
Slot :: struct {
	tag:               u32,
	busy:              bool,
	reads_region:      bool, // A Send with a part in a read region.
	read_region_place: u32,
}

// A read region of the client: memory that the device only reads.
Read_Region :: struct {
	memory:     system.Handle, // 0: the place is free.
	physical:   u64,
	size:       u64, // In bytes.
	sends:      u32, // The Send in flight that read it.
	removing:   bool, // A Read_Region_Remove waits for the end of those Send.
	remove_tag: u32,
}

device: virtio.Device
receive_queue: virtio.Queue
send_queue: virtio.Queue
receive_slots: [SLOT_CAPACITY]Slot
send_slots: [SLOT_CAPACITY]Slot
receive_slot_count: u32
send_slot_count: u32
in_flight: u32 // Receive and Send.
headers_physical: u64

hardware_address: u64
has_status: bool
machine: system.Handle
interrupt: system.Handle
clients: ring.Ring
ring_memory: system.Handle
region_memory: system.Handle
region_physical: u64
region_size: u64
read_regions: [frame.READ_REGION_CAPACITY]Read_Region

frames_sent: u64
frames_received: u64
bytes_sent: u64
bytes_received: u64
interrupts: u64

fail :: proc "contextless" (text: string) -> ! {
	system.log_in("frame", .Error, "frame: ", text)
	system.stop(1)
}

// start resets the device, agrees on the features, and gives it the queues.
start :: proc "contextless" (queues: system.Handle) {
	offered, start_error := virtio.start(&device, 1 << FEATURE_MAC | 1 << FEATURE_STATUS)
	switch start_error {
	case .None:
	case .No_Version_1:
		fail("the device has no virtio 1 interface")
	case .Features_Refused:
		fail("the device refused the features")
	case .Reset_Not_Done:
		fail("the device did not finish its reset")
	}
	if offered & (1 << FEATURE_MAC) != 0 {
		for index in 0 ..< 6 {
			hardware_address |= u64(virtio.load_8(device.device_config + uintptr(index))) << (8 * uint(index))
		}
	}
	has_status = offered & (1 << FEATURE_STATUS) != 0

	if system.memory_size(queues) < pci.QUEUE_PAGES {
		fail("the memory of the queues is too small")
	}
	address, map_status := system.memory_map(queues, {.Write})
	physical, physical_status := system.memory_physical(machine, queues)
	if map_status != .Ok || physical_status != .Ok {
		fail("no physical address for the queues")
	}
	base := uintptr(address)
	errors: [2]virtio.Queue_Error
	receive_queue, errors[0] = virtio.queue_start(&device, 0, base + PAGE_RECEIVE * system.PAGE_SIZE, physical + PAGE_RECEIVE * system.PAGE_SIZE, 2, 0)
	send_queue, errors[1] = virtio.queue_start(&device, 1, base + PAGE_SEND * system.PAGE_SIZE, physical + PAGE_SEND * system.PAGE_SIZE, 2, 0)
	for error in errors {
		switch error {
		case .None:
		case .Too_Small:
			fail("a queue of the device is too small")
		case .No_Vector:
			fail("the device has no message interrupt for its queues")
		}
	}
	headers_physical = physical + PAGE_HEADERS * system.PAGE_SIZE
	virtio.ready(&device)

	// Each place of a Receive has its two descriptors: the header, the
	// frame. Each place of a Send has four: the header, the part in the
	// frame region, the part in a read region, the zero bytes of a short
	// frame; submit links the third and the fourth when a frame needs them.
	receive_slot_count = min(receive_queue.size / 2, SLOT_CAPACITY)
	for slot in 0 ..< receive_slot_count {
		first := slot * 2
		receive_queue.descriptors[first] = {address = headers_physical + u64(slot) * HEADER_SIZE, length = HEADER_SIZE, flags = virtio.DESCRIPTOR_NEXT | virtio.DESCRIPTOR_DEVICE_WRITES, next = u16(first + 1)}
	}
	send_slot_count = min(send_queue.size / SEND_DESCRIPTORS, SLOT_CAPACITY)
	for slot in 0 ..< send_slot_count {
		first := slot * SEND_DESCRIPTORS
		send_queue.descriptors[first] = {address = headers_physical + SEND_HEADER_PLACE, length = HEADER_SIZE, flags = virtio.DESCRIPTOR_NEXT, next = u16(first + 1)}
	}
}

link_up :: proc "contextless" () -> bool {
	return !has_status || virtio.load_16(device.device_config + 6) & 1 != 0
}

complete :: proc "contextless" (tag: u32, status: frame.Status, values: [7]u64 = {}) {
	ring.push(&clients.completions, ring.Record{kind = u32(status), tag = tag, values = values})
}

// room says if the completion queue keeps a place for one more completion,
// with the places of the requests in flight.
room :: proc "contextless" () -> bool {
	return ring.count(&clients.completions) + in_flight < ring.capacity(&clients.completions)
}

// attach takes the frame region of the client. The handle must have come
// through the frame ring.
// A refusal gives the values of its error record.
attach :: proc "contextless" (handle: system.Handle) -> (frame.Status, [7]u64) {
	ATTACH :: u32(frame.Command.Attach)
	if in_flight != 0 {
		return .Bad_Command, errors.ring_fail(ATTACH, .Busy, .Requests, 0, i64(in_flight), 0)
	}
	if values, refused := system.region_refusal(handle, ring_memory, ATTACH); refused {
		return .No_Region, values
	}
	physical, status := system.memory_physical(machine, handle)
	if status != .Ok {
		return .No_Region, errors.ring_fail(ATTACH, .Refused, .None, 1, i64(handle), 0, i64(status))
	}
	if region_memory != 0 {
		system.close(region_memory)
	}
	region_memory = handle
	region_physical = physical
	region_size = system.memory_size(handle) * system.PAGE_SIZE
	return .Ok, {}
}

// read_region_add takes a read region of the client at a place. The handle
// must have come through the frame ring, with Read and without Write: the
// device then only reads the region, and with the IOMMU the kernel maps
// its pages with no write bit (src/md/infrastructure/iommu.md).
read_region_add :: proc "contextless" (command: ring.Record) -> (status: frame.Status, outcome: Outcome, values: [7]u64) {
	ADD :: u32(frame.Command.Read_Region_Add)
	handle, place := system.Handle(command.values[0]), command.values[1]
	kind, rights, through := system.handle_state(handle, ring_memory)
	// Only a handle that came through the ring is closed on a refusal: a
	// number of the client can name a handle of this service.
	switch {
	case kind != .Memory:
		return .No_Region, .Done, errors.ring_fail(ADD, .Handle_Kind, .None, 1, i64(handle), i64(op.Object_Kind.Memory), i64(kind))
	case !through:
		return .No_Region, .Done, errors.ring_fail(ADD, .Absent, .Region, 1)
	case .Read not_in rights || .Write in rights:
		system.close(handle)
		return .No_Region, .Done, errors.ring_fail(ADD, .Handle_Rights, .None, 1, i64(handle), i64(transmute(u32)system.Rights{.Read}), i64(transmute(u32)rights))
	case place >= frame.READ_REGION_CAPACITY:
		system.close(handle)
		return .Bad_Command, .Done, errors.ring_fail(ADD, .Out_Of_Range, .None, 2, i64(min(place, 1 << 62)), frame.READ_REGION_CAPACITY)
	}
	region := &read_regions[place]
	if region.memory != 0 {
		if region.removing {
			// The sends of the region before are still in flight: the
			// command waits for them, as a Send waits for a free slot.
			return .Ok, .Full, {}
		}
		system.close(handle)
		return .Bad_Command, .Done, errors.ring_fail(ADD, .Busy, .None, 2, i64(place))
	}
	physical, physical_status := system.memory_physical(machine, handle)
	if physical_status != .Ok {
		system.close(handle)
		return .No_Region, .Done, errors.ring_fail(ADD, .Refused, .None, 1, i64(handle), 0, i64(physical_status))
	}
	pages := system.memory_size(handle)
	region^ = {memory = handle, physical = physical, size = pages * system.PAGE_SIZE}
	system.log("frame: a read region of ", pages, " pages at the place ", place, ", held with the right Read only: the device reads the data of the frames to send there")
	return .Ok, .Done, {}
}

// read_region_close ends a read region with no Send in flight: the close
// of the handle takes its pages out of the device.
read_region_close :: proc "contextless" (region: ^Read_Region) {
	system.close(region.memory)
	region^ = {}
}

// read_region_remove ends a read region now, or when its last Send is
// complete: the device must not read memory that the client no longer
// lends, and the object must stay while the device reads it.
read_region_remove :: proc "contextless" (command: ring.Record) -> (status: frame.Status, outcome: Outcome, values: [7]u64) {
	REMOVE :: u32(frame.Command.Read_Region_Remove)
	place := command.values[0]
	if place >= frame.READ_REGION_CAPACITY || read_regions[place].memory == 0 || read_regions[place].removing {
		return .No_Region, .Done, errors.ring_fail(REMOVE, .Absent, .Region, 1, i64(min(place, 1 << 62)))
	}
	region := &read_regions[place]
	if region.sends == 0 {
		read_region_close(region)
		return .Ok, .Done, {}
	}
	region.removing, region.remove_tag = true, command.tag
	in_flight += 1 // Its completion comes with the last Send: keep its room.
	return .Ok, .Sent, {}
}

Outcome :: enum {
	Done, // The command has its status: no request goes to the device.
	Sent, // The device has the request.
	Full, // No place is free: the command waits for a completion.
}

// submit gives one request to the device. A refusal gives the values of
// its error record.
submit :: proc "contextless" (command: ring.Record) -> (status: frame.Status, outcome: Outcome, values: [7]u64) {
	kind := frame.Command(command.kind)
	place, count := command.values[0], command.values[1]
	if region_memory == 0 {
		return .No_Region, .Done, errors.ring_fail(command.kind, .Absent, .Region)
	}
	if place > region_size || count > region_size - place {
		return .Out_Of_Range, .Done, errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 1, i64(min(place, 1 << 62) + min(count, 1 << 62)), i64(region_size))
	}
	if kind == .Send {
		if count < 14 {
			return .Too_Large, .Done, errors.ring_fail(command.kind, .Too_Small, .Bytes, 2, i64(count), 14)
		}
		if count > frame.FRAME_LIMIT {
			return .Too_Large, .Done, errors.ring_fail(command.kind, .Too_Long, .Bytes, 2, i64(count), frame.FRAME_LIMIT)
		}
		// The second part, in a read region: the data that the client did
		// not copy. Each value is a copy in this record, checked once.
		data_offset, data_count, region_place := command.values[2], command.values[3], command.values[4]
		if data_count > frame.FRAME_LIMIT - count {
			return .Too_Large, .Done, errors.ring_fail(command.kind, .Too_Long, .Bytes, 4, i64(min(data_count, 1 << 62) + count), frame.FRAME_LIMIT)
		}
		read_region: ^Read_Region
		if data_count != 0 {
			if region_place >= frame.READ_REGION_CAPACITY || read_regions[region_place].memory == 0 || read_regions[region_place].removing {
				return .No_Region, .Done, errors.ring_fail(command.kind, .Absent, .Region, 5, i64(min(region_place, 1 << 62)))
			}
			read_region = &read_regions[region_place]
			if data_offset > read_region.size || data_count > read_region.size - data_offset {
				return .Out_Of_Range, .Done, errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 3, i64(min(data_offset, 1 << 62) + data_count), i64(read_region.size))
			}
		}
		slot: u32 = SLOT_CAPACITY
		for candidate in 0 ..< send_slot_count {
			if !send_slots[candidate].busy {
				slot = candidate
				break
			}
		}
		if slot == SLOT_CAPACITY {
			return .Ok, .Full, {}
		}
		head := slot * SEND_DESCRIPTORS
		// The parts of the frame, linked in order: the part in the frame
		// region, the part in a read region, the zero bytes of a short frame.
		last := head + 1
		send_queue.descriptors[last] = {address = region_physical + place, length = u32(count)}
		if read_region == nil {
			send_slots[slot] = {tag = command.tag, busy = true}
		} else {
			send_queue.descriptors[last].flags = virtio.DESCRIPTOR_NEXT
			send_queue.descriptors[last].next = u16(head + 2)
			last = head + 2
			send_queue.descriptors[last] = {address = read_region.physical + data_offset, length = u32(data_count)}
			send_slots[slot] = {tag = command.tag, busy = true, reads_region = true, read_region_place = u32(region_place)}
			read_region.sends += 1
		}
		if count + data_count < frame.FRAME_LEAST {
			send_queue.descriptors[last].flags = virtio.DESCRIPTOR_NEXT
			send_queue.descriptors[last].next = u16(head + 3)
			send_queue.descriptors[head + 3] = {address = headers_physical + SEND_PAD_PLACE, length = u32(frame.FRAME_LEAST - (count + data_count))}
		}
		in_flight += 1
		bytes_sent += count + data_count
		virtio.give(&send_queue, u16(head))
		return .Ok, .Sent, {}
	}
	// A Receive: room for a header of Ethernet at least.
	if count < 14 {
		return .Bad_Command, .Done, errors.ring_fail(command.kind, .Too_Small, .Bytes, 2, i64(count), 14)
	}
	if count > 1 << 16 {
		return .Bad_Command, .Done, errors.ring_fail(command.kind, .Too_Long, .Bytes, 2, i64(count), 1 << 16)
	}
	slot: u32 = SLOT_CAPACITY
	for candidate in 0 ..< receive_slot_count {
		if !receive_slots[candidate].busy {
			slot = candidate
			break
		}
	}
	if slot == SLOT_CAPACITY {
		return .Too_Many, .Done, errors.ring_fail(command.kind, .Busy, .Requests, 0, i64(receive_slot_count), i64(receive_slot_count))
	}
	head := slot * 2
	receive_queue.descriptors[head + 1] = {address = region_physical + place, length = u32(count), flags = virtio.DESCRIPTOR_DEVICE_WRITES}
	receive_slots[slot] = {tag = command.tag, busy = true}
	in_flight += 1
	virtio.give(&receive_queue, u16(head))
	return .Ok, .Sent, {}
}

// harvest gives a completion to the client for each request that the device used.
harvest :: proc "contextless" () -> (count: int) {
	for used in virtio.used(&send_queue) {
		slot := used.id / SEND_DESCRIPTORS
		if slot >= send_slot_count || !send_slots[slot].busy {
			continue
		}
		complete(send_slots[slot].tag, .Ok)
		frames_sent += 1
		if send_slots[slot].reads_region {
			region := &read_regions[send_slots[slot].read_region_place]
			region.sends -= 1
			// The last Send of a region that ends: the device no longer
			// reads it, so the handle closes and the removal completes.
			if region.removing && region.sends == 0 {
				tag := region.remove_tag
				read_region_close(region)
				complete(tag, .Ok)
				in_flight -= 1
				count += 1
			}
		}
		send_slots[slot] = {}
		in_flight -= 1
		count += 1
	}
	for used in virtio.used(&receive_queue) {
		slot := used.id / 2
		if slot >= receive_slot_count || !receive_slots[slot].busy {
			continue
		}
		if used.length < HEADER_SIZE {
			complete(receive_slots[slot].tag, .Device_Error, errors.ring_fail(u32(frame.Command.Receive), .Device, .Bytes, 0, i64(used.length), HEADER_SIZE))
		} else {
			length := u64(used.length) - HEADER_SIZE
			complete(receive_slots[slot].tag, .Ok, {0 = length})
			frames_received += 1
			bytes_received += length
		}
		receive_slots[slot] = {}
		in_flight -= 1
		count += 1
	}
	return count
}

// entry starts the device and then serves the frame ring, until the
// machine stops. It finds the virtio registers in the configuration that
// the root service copied, agrees on the features, gives the device its
// receive queue and its send queue, and writes `frame: ok, ...`. Its loop
// completes the frames that the device sent or received, gives the device
// each new command of the client, and waits for the interrupt of the
// device or a new command. With no ring, no configuration, or a device
// that refuses its setup, it writes the reason at the level error and
// stops with the code 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	machine = ctx.handles[pci.GRANT_MACHINE]
	interrupt = ctx.handles[pci.GRANT_INTERRUPT]
	ring_memory = ctx.handles[frame.SERVICE_RING]
	status: system.Status
	if clients, status = system.ring_open(ring_memory); status != .Ok {
		fail("no frame ring")
	}
	configuration_address, configuration_status := system.memory_map(ctx.handles[pci.GRANT_CONFIGURATION], {})
	if configuration_status != .Ok {
		fail("no configuration of the device")
	}
	found: bool
	if device, found = virtio.find(ctx, ([^]u8)(configuration_address)[:pci.CONFIGURATION_SIZE]); !found {
		fail("the device has no virtio registers in the memory that it received")
	}
	start(ctx.handles[pci.GRANT_QUEUES])
	text: [24]u8
	system.log("frame: ok, the hardware address ", hardware_text(text[:]), ", the link is ", link_up() ? "up" : "down", ", queues of ", u64(receive_queue.size), " and ", u64(send_queue.size), ", ", u64(receive_slot_count), " places for frames that arrive")

	waiting: ring.Record
	has_waiting := false // A Send that waits for a place in the queue of the device.
	for {
		wait := system.wait_begin() // An interrupt of the device is an event.
		changed := harvest()
		for room() {
			command: ring.Record
			if has_waiting {
				command, has_waiting = waiting, false
			} else {
				ok: bool
				if command, ok = system.receive(&clients.commands); !ok {
					break
				}
			}
			result := frame.Status.Ok
			values: [7]u64
			#partial switch frame.Command(command.kind) {
			case .Attach:
				result, values = attach(system.Handle(command.values[0]))
			case .Info:
				values = {0 = hardware_address, 1 = u64(link_up()), 2 = frame.FRAME_LIMIT, 3 = u64(receive_slot_count), 4 = u64(send_slot_count)}
			case .Statistics:
				results, _ := system.call(.Interrupt_Read, u64(interrupt))
				interrupts += results[0]
				values = {0 = frames_sent, 1 = frames_received, 2 = system.kernel_entries(), 3 = interrupts, 4 = bytes_sent, 5 = bytes_received}
			case .Send, .Receive, .Read_Region_Add, .Read_Region_Remove:
				outcome: Outcome
				#partial switch frame.Command(command.kind) {
				case .Read_Region_Add:
					result, outcome, values = read_region_add(command)
				case .Read_Region_Remove:
					result, outcome, values = read_region_remove(command)
				case:
					result, outcome, values = submit(command)
				}
				if outcome == .Sent {
					continue
				}
				if outcome == .Full {
					waiting, has_waiting = command, true
				}
			case:
				result = .Bad_Command
				values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind))
			}
			if has_waiting {
				break
			}
			complete(command.tag, result, values)
			changed += 1
		}
		virtio.notify(&receive_queue)
		virtio.notify(&send_queue)
		if changed != 0 {
			system.wake_reader(&clients.completions)
		}
		if virtio.used_ready(&send_queue) || virtio.used_ready(&receive_queue) {
			continue
		}
		if room() && !has_waiting {
			system.wait_records(&wait, &clients.commands)
		}
		system.wait_end(&wait)
	}
}

// hardware_text writes a hardware address as six hexadecimal pairs.
hardware_text :: proc "contextless" (buffer: []u8) -> string {
	digits := "0123456789abcdef"
	count := 0
	for index in 0 ..< 6 {
		byte := u8(hardware_address >> (8 * uint(index)))
		if index != 0 {
			buffer[count] = ':'
			count += 1
		}
		buffer[count] = digits[byte >> 4]
		buffer[count + 1] = digits[byte & 15]
		count += 2
	}
	return string(buffer[:count])
}

#assert(SLOT_CAPACITY * HEADER_SIZE <= SEND_HEADER_PLACE)
#assert(PAGE_HEADERS < pci.QUEUE_PAGES)
#assert(2 * SLOT_CAPACITY <= frame.RING_CAPACITY)
