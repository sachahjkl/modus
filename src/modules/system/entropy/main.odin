// The entropy service: the device service of the entropy device of the
// machine (virtio-rng, virtio 1.x over PCI). It reads bytes from the device
// for its one client, the root service, which mixes them into its random
// generator (src/md/features/entropy_device.md).
//
// It has one device and nothing else: the registers of the device, one
// message interrupt, memory for the queue, the machine with the right
// Physical only, a copy of the configuration of the device, and the
// entropy ring. The root service found the device, enabled it and set its
// interrupt (src/library/modus/pci). The code that each virtio device
// service shares is in src/library/modus/virtio.
//
// **What it is for.** It gives the seed of the system a source that is not
// the processor. The root service mixes the bytes in: they add to the seed
// and never replace it, so a device that gives zeros or the same bytes
// again changes nothing (docs/RANDOMNESS.md, "3. The seed of the system,
// and what is claimed").
//
// **Who uses it.** The root service starts it at boot when the machine has
// an entropy device at the place `pci.ENTROPY_DEVICE`, and is its one
// client. No other process can name the device or the ring.
//
// **The commands of the entropy ring** (`src/library/modus/contract/entropy_service`):
// `Read`, with a count of 1 to 48 bytes. Its completion carries the bytes
// that the device gave, at most the count. A refusal gives a status and the
// values of an [error record](term:error-record).
//
// **What a reader sees.** No window: the line `entropy: ok, a queue of
// <size>` on the log. A failure at the start writes a line at the level
// error and stops the service.
//
// **What it does not prove.** It does not test the bytes of the device: the
// root service refuses a read with no byte, with one value only, or equal
// to the read before it, and claims nothing more of the others.
package entropy_device_service

import "base:intrinsics"
import "modus:contract/call_outcome"
import "modus:contract/entropy_service"
import "modus:contract/errors"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:pci"
import "modus:system"
import "modus:virtio"

// The memory of the queue (pci.QUEUE_PAGES): pages 0 to 2 the virtqueue,
// page 3 the buffer that the device writes. The device reaches no other
// memory of this process.
PAGE_BUFFER :: virtio.QUEUE_PAGES

device: virtio.Device
queue: virtio.Queue
buffer: [^]u8
buffer_physical: u64
machine: system.Handle
clients: ring.Ring

fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Error, Service_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

// start resets the device, agrees on the features (the device has none
// that this service needs), and gives it the queue.
start :: proc "contextless" (queues: system.Handle) {
	_, start_error := virtio.start(&device, 0)
	switch start_error {
	case .None:
	case .No_Version_1:
		fail("the device has no virtio 1 interface")
	case .Features_Refused:
		fail("the device refused the features")
	case .Reset_Not_Done:
		fail("the device did not finish its reset")
	}
	if queue_pages, queue_status := system.memory_size(queues); queue_status != .Succeeded || queue_pages < pci.QUEUE_PAGES {
		fail("the memory of the queue is too small")
	}
	address, map_status := system.memory_map(queues, {.Write})
	physical, physical_status := system.memory_physical(machine, queues)
	if map_status != .Succeeded || physical_status != .Succeeded {
		system.log_fact(.Error, Queue_Not_Mapped{map_status = map_status, address_status = physical_status})
		fail("no physical address for the queue")
	}
	base := uintptr(address)
	queue_error: virtio.Queue_Error
	queue, queue_error = virtio.queue_start(&device, 0, base, physical, 1, 0)
	switch queue_error {
	case .None:
	case .Too_Small:
		fail("the queue of the device is too small")
	case .No_Vector:
		fail("the device has no message interrupt for its queue")
	case .Bad_Notify:
		fail("the notify register of the queue is outside the registers of the device")
	}
	buffer = ([^]u8)(base + PAGE_BUFFER * system.PAGE_SIZE)
	buffer_physical = physical + PAGE_BUFFER * system.PAGE_SIZE
	virtio.ready(&device)
}

// submit gives the device one read of `count` bytes into the buffer, with
// the one descriptor of the queue.
submit :: proc "contextless" (count: u32) {
	queue.descriptors[0] = {address = buffer_physical, length = count, flags = virtio.DESCRIPTOR_DEVICE_WRITES}
	virtio.give(&queue, 0)
}

// answer gives the completion of the read in flight. The device says how
// many bytes it wrote; it is never trusted for more than it was asked. The
// bytes are copied once from the buffer, and the buffer and the copies are
// erased after the completion is written.
answer :: proc "contextless" (tag: u32, asked: u32, used: virtio.Used) {
	given := int(min(used.length, asked))
	bytes: [entropy_service.READ_BYTES_LIMIT]u8
	copy(bytes[:given], buffer[:given])
	intrinsics.mem_zero_volatile(rawptr(buffer), int(asked))
	values := entropy_service.bytes_pack(bytes[:given])
	ring.push(&clients.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = tag, values = values})
	intrinsics.mem_zero_volatile(&bytes, size_of(bytes))
	intrinsics.mem_zero_volatile(&values, size_of(values))
}

// entry starts the device and then serves the entropy ring, until the
// machine stops.
//
// **What it sets up**: the machine handle with the right Physical, the
// entropy ring, and the configuration of the device that the root service
// copied. It finds the virtio registers, resets the device, and gives it
// the queue (`start`). It then writes `entropy: ok, a queue of <size>`.
//
// **The loop.** After each wake:
//
// 1. It reads the used ring. When the device used the read in flight, it
//    gives its completion; a used entry with no read in flight stops it.
// 2. With no read in flight and a place in the completion queue, it takes
//    the next command: a `Read` with a good count goes to the device; any
//    other command completes at once with its refusal.
// 3. It tells the device of the new read, and wakes the client when a
//    completion came.
// 4. It waits for the interrupt of the device, and for a new command when
//    no read is in flight.
//
// **The stop**: with no ring, no configuration, no virtio registers, a
// device that needs a reset, or a device that uses a read that was not
// given (`entropy: the device used a read that was not given`), it writes
// the reason at the level error and stops with `Failed`. Else it never
// returns.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	machine = ctx.handles[pci.GRANT_MACHINE]
	status: call_outcome.Call_Outcome
	if clients, status = system.ring_open(ctx.handles[entropy_service.SERVICE_RING]); status != .Succeeded {
		fail("no entropy ring")
	}
	configuration_address, configuration_status := system.memory_map(ctx.handles[pci.GRANT_CONFIGURATION], {})
	if configuration_status != .Succeeded {
		fail("no configuration of the device")
	}
	found: bool
	if device, found = virtio.find(ctx, ([^]u8)(configuration_address)[:pci.CONFIGURATION_SIZE]); !found {
		fail("the device has no virtio registers in the memory that it received")
	}
	start(ctx.handles[pci.GRANT_QUEUES])
	system.log_fact(.Info, Device_Ready{queue_size = u64(queue.size)})

	in_flight := false
	in_flight_tag: u32
	in_flight_count: u32
	// The start is done: the first state of work of the process
	// (src/md/features/module_budget_request.md, "The first state of work").
	system.ready()
	for {
		wait := system.wait_begin() // An interrupt of the device is an event.
		answered := false
		// The used ring is read at each wake, with or without a read in
		// flight: the device moves its index, and an entry that no read
		// asked for would else stay ready for ever and keep this loop
		// awake. Such an entry is a fault of the device, as a reset is.
		if used, ok := virtio.used(&queue); ok {
			if !in_flight {
				fail("the device used a read that was not given")
			}
			in_flight = false
			answer(in_flight_tag, in_flight_count, used)
			answered = true
		} else if in_flight {
			if virtio.status_read(&device) & virtio.STATUS_NEEDS_RESET != 0 {
				ring.push(&clients.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Callee_Unavailable), tag = in_flight_tag, values = errors.ring_fail(u32(entropy_service.Command.Read), .Device, .None, 0, 0, 0, i64(virtio.status_read(&device)))})
				system.wake_reader(&clients.completions)
				fail("the device needs a reset")
			}
		}
		// The completion queue keeps a place for the completion of each
		// command that this loop takes.
		for !in_flight && ring.count(&clients.completions) < ring.capacity(&clients.completions) {
			command := system.receive(&clients.commands) or_break
			count := command.values[0]
			switch {
			case entropy_service.Command(command.kind) != .Read:
				ring.push(&clients.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Operation_Unsupported), tag = command.tag, values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind))})
				answered = true
			case count == 0:
				ring.push(&clients.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Argument_Refused), tag = command.tag, values = errors.ring_fail(command.kind, .Too_Small, .Bytes, 1, 0, 1)})
				answered = true
			case count > entropy_service.READ_BYTES_LIMIT:
				ring.push(&clients.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Argument_Refused), tag = command.tag, values = errors.ring_fail(command.kind, .Too_Long, .Bytes, 1, i64(min(count, 1 << 62)), entropy_service.READ_BYTES_LIMIT)})
				answered = true
			case:
				in_flight, in_flight_tag, in_flight_count = true, command.tag, u32(count)
				submit(in_flight_count)
			}
		}
		virtio.notify(&queue)
		if answered {
			system.wake_reader(&clients.completions)
		}
		if virtio.used_ready(&queue) {
			continue
		}
		if !in_flight && ring.count(&clients.completions) < ring.capacity(&clients.completions) {
			system.wait_records(&wait, &clients.commands)
		}
		system.wait_end(&wait)
	}
}

#assert(PAGE_BUFFER < pci.QUEUE_PAGES)
#assert(entropy_service.READ_BYTES_LIMIT <= system.PAGE_SIZE)
