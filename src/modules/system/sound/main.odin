// The sound service: the device service of the sound device of the machine
// (virtio-snd, virtio 1.x over PCI). It serves a timed stream to its one
// client: each record of frames plays at the time that it names
// (src/md/features/timed_stream.md).
//
// It has one device and nothing else: the registers of the device, one
// message interrupt, memory for the queues, the machine with the right
// Physical only, a copy of the configuration of the device, and the stream
// ring. The root service found the device, enabled it and set its
// interrupt (src/library/support/pci), when the process with the grant
// **Sound_Device** started; it stops this service when that process stops.
//
// **What it is for.** A process plays sound at a time of the system clock,
// and never sees the device, its queues or its clock.
//
// **The commands of the stream ring** (`src/library/contract/timed_stream`):
// `Attach` with the sample region, `Start`, then `Play` for each record.
// The completion of a `Play` comes when the device took the period that
// holds its last frame. A refusal gives a status and the values of an
// [error record](term:error-record), and no frame of the record plays.
//
// **What a reader sees.** No window: the line `sound: ok, the output
// stream <n> of <count>, ...` on the log when the device is ready, the line
// `sound: the stream started, ...` at `Start`, and one line at the first
// underrun and at the first hold of a period. A failure writes a line at
// the level error and stops the service.
//
// **What it does not prove.** It does not know the delay of the device
// after it took a period: QEMU reports none. It corrects no drift of the
// clock of the device; it only holds the periods of a device that takes
// them faster than their time.
package sound_device_service

import "base:intrinsics"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/timed_stream"
import "modus:private/sound/sound_device"
import "modus:support/pci"
import "modus:support/system"
import "modus:support/virtio"

// The working memory: the rest of the pages that the root service gave it
// by its name, once the tool counts its module and its thread. As for the
// entropy service, the tables of the domain of the device under the IOMMU
// are paid from it; the periods and their list take PERIOD_PAGES + 1 more,
// and the map of the sample region of the client its page tables.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 190, processes = 1, threads = 1}

// The memory of the queues (pci.QUEUE_PAGES): pages 0 to 2 the control
// queue, pages 3 to 5 the transmit queue, page 6 the messages that the
// device reads and writes. The device reaches no other memory of this
// process but the periods.
PAGE_CONTROL_QUEUE :: 0
PAGE_TRANSMIT_QUEUE :: PAGE_CONTROL_QUEUE + virtio.QUEUE_PAGES
PAGE_MESSAGES :: PAGE_TRANSMIT_QUEUE + virtio.QUEUE_PAGES
#assert(PAGE_MESSAGES < pci.QUEUE_PAGES)

// The places in the page of the messages.
MESSAGE_REQUEST :: 0 // The control request that the device reads.
MESSAGE_RESPONSE :: 64 // The control response that the device writes.
MESSAGE_RESPONSE_BYTES :: sound_device.ANSWER_CODE_BYTES + sound_device.STREAM_LIMIT * sound_device.PCM_INFO_BYTES
MESSAGE_HEADERS :: 1024 // The header of the request of each period: the stream.
MESSAGE_STATUSES :: 2048 // The status of each period, which the device writes.
MESSAGE_SLOT_BYTES :: 16
#assert(MESSAGE_RESPONSE + MESSAGE_RESPONSE_BYTES <= MESSAGE_HEADERS)
#assert(MESSAGE_STATUSES + timed_stream.PERIODS_GIVEN * MESSAGE_SLOT_BYTES <= system.PAGE_SIZE)

// The periods that the device reads: one memory object of this process.
PERIOD_PAGES :: (timed_stream.PERIODS_GIVEN * timed_stream.PERIOD_BYTES + system.PAGE_SIZE - 1) / system.PAGE_SIZE

// The queues of a virtio sound device (virtio 1.2, 5.14.2).
QUEUE_CONTROL :: 0
QUEUE_TRANSMIT :: 2

// The codes of the requests (virtio 1.2, 5.14.6).
REQUEST_PCM_INFO :: 0x0100
REQUEST_PCM_SET_PARAMS :: 0x0101
REQUEST_PCM_PREPARE :: 0x0102
REQUEST_PCM_START :: 0x0104
// The device configuration: jacks, streams and channel maps, 4 bytes each.
CONFIGURATION_BYTES :: 12
CONFIGURATION_STREAMS :: 4

// A device answers a control request in microseconds. The bound only ends
// a hang of the device, and it is the one hang bound of a process, so the
// line of this service comes before the bound of a step of a machine test.
DEVICE_ANSWER_BOUND_MILLISECONDS :: system.TEST_HANG_BOUND_MILLISECONDS

device: virtio.Device
control_queue: virtio.Queue
transmit_queue: virtio.Queue
messages: [^]u8
messages_physical: u64
periods_memory: [^]u8
periods_physical: u64
machine: system.Handle
clients: ring.Ring
clients_memory: system.Handle
stream_number: u32

// The sample region of the client, mapped read-only. 0: no region.
region_memory: system.Handle
region: [^]u8
region_size: u64

// The stream.
started: bool
anchor: timed_stream.Anchor
periods: sound_device.Periods
underruns: u64
holds: u64 // The times that the service held a period of a device that took them faster than their time.
holding: bool
// A reason to stop once the completion that holds it is in the ring.
stop_reason: string

// A record that the service accepted and that did not end.
Pending :: struct {
	tag:         u32,
	first_frame: u64,
	end_frame:   u64,
	place:       u64,
	played_time: u64, // The time of its first frame, by the anchor at the fill of the period that holds it.
}
pending: [timed_stream.RING_CAPACITY]Pending
pending_head: u32
pending_count: u32

fail :: proc "contextless" (text: string) -> ! {
	system.log(.Error, "sound: ", text)
	system.stop(.Failed)
}

// control_call gives the device one control request of `request_bytes`
// bytes, written at MESSAGE_REQUEST, and waits for its answer, of at most
// `response_bytes` bytes, until DEVICE_ANSWER_BOUND_MILLISECONDS. It gives
// a copy of the answer and its length, which the device wrote and which is
// never above response_bytes. answered false: the device did not answer.
// Only the start and Start call it, when no period is in flight: no other
// used entry can come.
control_call :: proc "contextless" (request_bytes: u32, response_bytes: u32) -> (response: [MESSAGE_RESPONSE_BYTES]u8, length: u32, answered: bool) {
	control_queue.descriptors[0] = {address = messages_physical + MESSAGE_REQUEST, length = request_bytes, flags = virtio.DESCRIPTOR_NEXT, next = 1}
	control_queue.descriptors[1] = {address = messages_physical + MESSAGE_RESPONSE, length = response_bytes, flags = virtio.DESCRIPTOR_DEVICE_WRITES}
	virtio.give(&control_queue, 0)
	virtio.notify(&control_queue)
	deadline := system.time() + DEVICE_ANSWER_BOUND_MILLISECONDS
	for {
		wait := system.wait_begin() // An interrupt of the device is an event.
		if used, ok := virtio.used(&control_queue); ok {
			if used.id != 0 {
				fail("the device answered a control request that was not given")
			}
			length = min(used.length, response_bytes)
			intrinsics.mem_copy_non_overlapping(&response, &messages[MESSAGE_RESPONSE], int(length))
			return response, length, true
		}
		if virtio.used_ready(&transmit_queue) {
			fail("the device used a period that was not given")
		}
		if virtio.status_read(&device) & virtio.STATUS_NEEDS_RESET != 0 {
			fail("the device needs a reset")
		}
		if system.time() >= deadline {
			return response, 0, false
		}
		system.wait_end(&wait, deadline)
	}
}

// control_answered gives the answer of a control request of the start, or
// stops the service with a line that names the request.
control_answered :: proc "contextless" (name: string, request_bytes: u32, response_bytes: u32) -> (response: [MESSAGE_RESPONSE_BYTES]u8, length: u32) {
	answered: bool
	response, length, answered = control_call(request_bytes, response_bytes)
	if !answered {
		system.log_fact(.Error, Device_Silent{bound = DEVICE_ANSWER_BOUND_MILLISECONDS, request = request_field(name)})
		fail("the device does not answer")
	}
	return response, length
}

// control_ok stops the service with a line when a control answer is not Ok.
control_ok :: proc "contextless" (name: string, response: []u8, length: u32) {
	answer, code := sound_device.answer_of(response, length)
	switch answer {
	case .Ok:
		return
	case .Short:
		system.log_fact(.Error, Answer_Too_Short{answer_length = bytes_field(length), request = request_field(name)})
	case .Refused:
		system.log_fact(.Error, Request_Refused{answer_code = u64(code), request = request_field(name)})
	}
	fail("the device refused a control request")
}

// stream_choose asks the device for its streams and takes the first output
// stream that plays the one format.
stream_choose :: proc "contextless" () -> (count: u32) {
	if device.device_config_length < CONFIGURATION_BYTES {
		fail("the configuration of the device is too short")
	}
	count = virtio.load_32(device.device_config + CONFIGURATION_STREAMS)
	asked := min(count, sound_device.STREAM_LIMIT)
	if asked == 0 {
		fail("the device has no stream")
	}
	request := ([^]u32)(&messages[MESSAGE_REQUEST])
	request[0] = REQUEST_PCM_INFO
	request[1] = 0 // The first stream.
	request[2] = asked
	request[3] = sound_device.PCM_INFO_BYTES
	response, length := control_answered("PCM_INFO", 16, sound_device.ANSWER_CODE_BYTES + asked * sound_device.PCM_INFO_BYTES)
	choice: sound_device.Stream_Choice
	code: u32
	stream_number, choice, code = sound_device.stream_of_answer(response[:], length, asked)
	switch choice {
	case .Chosen:
		return count
	case .Short:
		system.log_fact(.Error, Stream_Information_Too_Short{streams = u64(asked), answer_length = bytes_field(length)})
	case .Refused:
		system.log_fact(.Error, Stream_Information_Refused{answer_code = u64(code)})
	case .None_Of_The_Format:
		system.log_fact(.Error, No_Stream_Of_The_Format{streams = u64(count)})
	}
	fail("no output stream of the format")
}

// stream_prepare sets the one format on the stream and prepares it.
stream_prepare :: proc "contextless" () {
	request := ([^]u32)(&messages[MESSAGE_REQUEST])
	request[0] = REQUEST_PCM_SET_PARAMS
	request[1] = stream_number
	request[2] = timed_stream.PERIODS_GIVEN * timed_stream.PERIOD_BYTES // The buffer_bytes of the device.
	request[3] = timed_stream.PERIOD_BYTES
	request[4] = 0 // No feature.
	messages[MESSAGE_REQUEST + 20] = timed_stream.CHANNELS
	messages[MESSAGE_REQUEST + 21] = sound_device.FORMAT_SIGNED_16
	messages[MESSAGE_REQUEST + 22] = sound_device.RATE_48000
	messages[MESSAGE_REQUEST + 23] = 0
	response, length := control_answered("PCM_SET_PARAMS", 24, sound_device.ANSWER_CODE_BYTES)
	control_ok("PCM_SET_PARAMS", response[:], length)
	request[0] = REQUEST_PCM_PREPARE
	request[1] = stream_number
	response, length = control_answered("PCM_PREPARE", 8, sound_device.ANSWER_CODE_BYTES)
	control_ok("PCM_PREPARE", response[:], length)
}

// start resets the device, agrees on the features (the device has none
// that this service needs), gives it the control queue and the transmit
// queue, and prepares the stream.
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
	if queue_pages, queue_status := system.memory_size(queues); queue_status != .Ok || queue_pages < pci.QUEUE_PAGES {
		fail("the memory of the queues is too small")
	}
	address, map_status := system.memory_map(queues, {.Write})
	physical, physical_status := system.memory_physical(machine, queues)
	if map_status != .Ok || physical_status != .Ok {
		system.log(.Error, "sound: the map of the queues gave the status ", map_status, ", their device address the status ", physical_status)
		fail("no physical address for the queues")
	}
	base := uintptr(address)
	errors_of_queues: [2]virtio.Queue_Error
	control_queue, errors_of_queues[0] = virtio.queue_start(&device, QUEUE_CONTROL, base + PAGE_CONTROL_QUEUE * system.PAGE_SIZE, physical + PAGE_CONTROL_QUEUE * system.PAGE_SIZE, 2, 0)
	transmit_queue, errors_of_queues[1] = virtio.queue_start(&device, QUEUE_TRANSMIT, base + PAGE_TRANSMIT_QUEUE * system.PAGE_SIZE, physical + PAGE_TRANSMIT_QUEUE * system.PAGE_SIZE, timed_stream.PERIODS_GIVEN * sound_device.DESCRIPTORS_OF_A_PERIOD, 0)
	for queue_error in errors_of_queues {
		switch queue_error {
		case .None:
		case .Too_Small:
			fail("a queue of the device is too small")
		case .No_Vector:
			fail("the device has no message interrupt for its queues")
		case .Bad_Notify:
			fail("the notify register of a queue is outside the registers of the device")
		}
	}
	messages = ([^]u8)(base + PAGE_MESSAGES * system.PAGE_SIZE)
	messages_physical = physical + PAGE_MESSAGES * system.PAGE_SIZE

	// The periods: memory of this budget, which the device reads.
	period_memory, period_status := system.memory_create(PERIOD_PAGES, 0, {.Contiguous})
	if period_status != .Ok {
		system.log(.Error, "sound: the memory of the periods gave the status ", period_status)
		fail("no memory for the periods")
	}
	period_address, period_map_status := system.memory_map(period_memory, {.Write})
	period_physical, period_physical_status := system.memory_physical(machine, period_memory)
	if period_map_status != .Ok || period_physical_status != .Ok {
		system.log(.Error, "sound: the map of the periods gave the status ", period_map_status, ", their device address the status ", period_physical_status)
		fail("no physical address for the periods")
	}
	periods_memory = ([^]u8)(period_address)
	periods_physical = period_physical
	virtio.ready(&device)

	count := stream_choose()
	stream_prepare()
	system.log_fact(.Info, Device_Ready{stream = u64(stream_number), streams = u64(count), periods = u64(timed_stream.PERIODS_GIVEN), period_frames = u64(timed_stream.PERIOD_FRAMES), transmit_queue = u64(transmit_queue.size)})
}

// attach takes the sample region of the client, once. A handle that came
// through the ring and that the service refuses is closed: the service
// keeps no handle that it does not use.
attach :: proc "contextless" (command: ring.Record) -> (timed_stream.Status, [7]u64) {
	ATTACH :: u32(timed_stream.Command.Attach)
	handle := system.Handle(command.values[0])
	kind, rights, through := system.handle_state(handle, clients_memory)
	refusal, close := sound_device.attach_decision(kind, .Read in rights, through, region_memory != 0)
	if close {
		system.close(handle)
	}
	switch refusal {
	case .None:
	case .Not_Through_The_Ring:
		return .No_Region, errors.ring_fail(ATTACH, .Absent, .Region, 1)
	case .Attached_Already:
		return .Bad_Command, errors.ring_fail(ATTACH, .State, .None, 0)
	case .Not_Memory:
		return .No_Region, errors.ring_fail(ATTACH, .Handle_Kind, .None, 1, i64(handle), i64(op.Object_Kind.Memory), i64(kind))
	case .No_Read:
		needed := system.Rights{.Read}
		return .No_Region, errors.ring_fail(ATTACH, .Handle_Rights, .None, 1, i64(handle), i64(transmute(u32)needed), i64(transmute(u32)rights))
	}
	// The damage is checked after the handle: a damaged Attach with a
	// handle that came through the ring still closes it.
	if index, damaged := timed_stream.damaged_value(.Attach, command.values); damaged {
		system.close(handle)
		return .Bad_Command, timed_stream.damaged_values(.Attach, index, command.values)
	}
	pages, size_status := system.memory_size(handle)
	if size_status != .Ok {
		system.close(handle)
		return .No_Region, errors.ring_fail(ATTACH, .Refused, .None, 1, i64(handle), 0, i64(size_status))
	}
	address, map_status := system.memory_map(handle, {})
	if map_status != .Ok {
		system.close(handle)
		return .No_Region, errors.ring_fail(ATTACH, .Refused, .None, 1, i64(handle), 0, i64(map_status))
	}
	region_memory = handle
	region = ([^]u8)(address)
	region_size = pages * system.PAGE_SIZE
	return .Ok, {}
}

// period_fill writes the frames of one period from the pending records,
// with zeros where no record has a frame. The records are in the order of
// their frames, so the fill stops at the first record after the period.
// It copies each sample once from the region; the client can change those
// bytes, and any bytes are samples.
period_fill :: proc "contextless" (slot: u32, first_frame: u64) {
	bytes := periods_memory[slot * timed_stream.PERIOD_BYTES:][:timed_stream.PERIOD_BYTES]
	intrinsics.mem_zero(&bytes[0], timed_stream.PERIOD_BYTES)
	for index in 0 ..< pending_count {
		record := &pending[(pending_head + index) % timed_stream.RING_CAPACITY]
		if record.first_frame >= first_frame + timed_stream.PERIOD_FRAMES {
			break
		}
		share := timed_stream.period_share(first_frame, record.first_frame, record.end_frame)
		if share.count == 0 {
			continue
		}
		if share.record_offset == 0 {
			record.played_time, _ = timed_stream.time_of_frame(anchor, record.first_frame)
		}
		source := record.place + share.record_offset * timed_stream.FRAME_BYTES
		intrinsics.mem_copy_non_overlapping(&bytes[share.period_offset * timed_stream.FRAME_BYTES], &region[source], int(share.count * timed_stream.FRAME_BYTES))
	}
}

// period_give fills the period of a free slot with the next frames and
// gives it to the device: the header, the frames, the status. false: each
// slot is in flight.
period_give :: proc "contextless" () -> bool {
	slot, first_frame := sound_device.period_take(&periods) or_return
	header_place := MESSAGE_HEADERS + slot * MESSAGE_SLOT_BYTES
	status_place := MESSAGE_STATUSES + slot * MESSAGE_SLOT_BYTES
	(^u32)(&messages[header_place])^ = stream_number
	// A device that does not write the status then gives no Ok of an
	// earlier period.
	(^u32)(&messages[status_place])^ = 0
	period_fill(slot, first_frame)
	head := u16(slot * sound_device.DESCRIPTORS_OF_A_PERIOD)
	transmit_queue.descriptors[head] = {address = messages_physical + u64(header_place), length = 4, flags = virtio.DESCRIPTOR_NEXT, next = head + 1}
	transmit_queue.descriptors[head + 1] = {address = periods_physical + u64(slot * timed_stream.PERIOD_BYTES), length = timed_stream.PERIOD_BYTES, flags = virtio.DESCRIPTOR_NEXT, next = head + 2}
	transmit_queue.descriptors[head + 2] = {address = messages_physical + u64(status_place), length = 8, flags = virtio.DESCRIPTOR_DEVICE_WRITES}
	virtio.give(&transmit_queue, head)
	return true
}

// periods_give gives a period for each free slot, unless the device took
// them faster than their time: it then holds the next one, counts the
// hold, and gives the time in milliseconds at which to look again.
periods_give :: proc "contextless" () -> (wake_at: u64) {
	for {
		held, until := sound_device.refill_hold(&periods, anchor, system.nanoseconds())
		if held {
			if !holding {
				holding = true
				holds += 1
				if holds == 1 {
					system.log(.Warning, "sound: the first hold: the device took the periods faster than their time; the service gives the next one when the time comes, and counts each hold")
				}
			}
			// The milliseconds of the system clock have the time 0 of its
			// nanoseconds: the wake comes at or after the time.
			return until / 1_000_000 + 1
		}
		holding = false
		if !period_give() {
			return system.WAIT_FOREVER
		}
	}
}

// stream_start starts the device, sets the anchor at its answer, and gives
// it the first periods: silence until the first record.
stream_start :: proc "contextless" (command: ring.Record) -> (timed_stream.Status, [7]u64) {
	START :: u32(timed_stream.Command.Start)
	if index, damaged := timed_stream.damaged_value(.Start, command.values); damaged {
		return .Bad_Command, timed_stream.damaged_values(.Start, index, command.values)
	}
	if started {
		return .Bad_Command, errors.ring_fail(START, .State, .None, 0)
	}
	if region_memory == 0 {
		return .No_Region, errors.ring_fail(START, .Absent, .Region, 0)
	}
	request := ([^]u32)(&messages[MESSAGE_REQUEST])
	request[0] = REQUEST_PCM_START
	request[1] = stream_number
	response, length, answered := control_call(8, sound_device.ANSWER_CODE_BYTES)
	if !answered {
		stop_reason = "the device did not answer PCM_START"
		return .Device_Error, errors.ring_fail(START, .No_Answer, .Milliseconds, 0, 0, DEVICE_ANSWER_BOUND_MILLISECONDS, i64(errors.Unanswered.Device))
	}
	if answer, code := sound_device.answer_of(response[:], length); answer != .Ok {
		return .Device_Error, errors.ring_fail(START, .Device, .None, 0, 0, 0, i64(code))
	}
	started = true
	anchor = {frame = 0, time = system.nanoseconds()}
	periods = {}
	periods_give()
	virtio.notify(&transmit_queue)
	latency, _ := timed_stream.time_of_frame({}, timed_stream.PERIODS_GIVEN * timed_stream.PERIOD_FRAMES)
	system.log(.Info, "sound: the stream started: the frame 0 plays at ", anchor.time, " ns of the system clock; the service holds ", latency, " ns")
	return .Ok, {0 = anchor.time, 1 = latency, 2 = u64(timed_stream.Format.Signed_16_Stereo_48000)}
}

// play takes one record: the border, the region, then its place in time.
play :: proc "contextless" (command: ring.Record) -> (status: timed_stream.Status, values: [7]u64, accepted: bool) {
	PLAY :: u32(timed_stream.Command.Play)
	if !started {
		return .Not_Started, errors.ring_fail(PLAY, .State, .None, 0), false
	}
	record, refusal := timed_stream.play_of_record(command.values)
	if refusal != .None {
		return .Bad_Command, timed_stream.play_refusal_values(refusal, command.values), false
	}
	if !timed_stream.play_in_region(record, region_size) {
		return .Out_Of_Range, errors.ring_fail(PLAY, .Out_Of_Range, .Bytes, 4, i64(min(record.place, 1 << 62) + record.frame_count * timed_stream.FRAME_BYTES), i64(region_size)), false
	}
	pending_end := periods.next_frame
	if pending_count > 0 {
		pending_end = pending[(pending_head + pending_count - 1) % timed_stream.RING_CAPACITY].end_frame
	}
	placement, decision := timed_stream.play_place(record, anchor, periods.next_frame, pending_end)
	if decision != .Accepted {
		status, values = timed_stream.placement_refusal_values(decision, record, placement, pending_end)
		return status, values, false
	}
	pending[(pending_head + pending_count) % timed_stream.RING_CAPACITY] = {
		tag         = command.tag,
		first_frame = placement.first_frame,
		end_frame   = placement.end_frame,
		place       = record.place,
	}
	pending_count += 1
	return .Ok, {}, true
}

// taken completes each pending record whose last frame is before the end
// of the frames that the device took. The periods end in order, so each
// frame before that end is taken.
taken :: proc "contextless" (taken_end: u64) -> (answered: bool) {
	for pending_count > 0 {
		record := pending[pending_head]
		if record.end_frame > taken_end {
			break
		}
		ring.push(&clients.completions, ring.Record{kind = u32(timed_stream.Status.Ok), tag = record.tag, values = {0 = record.played_time, 1 = record.first_frame, 2 = underruns}})
		pending_head = (pending_head + 1) % timed_stream.RING_CAPACITY
		pending_count -= 1
		answered = true
	}
	return answered
}

// device_failed answers each pending record with Device_Error, and stops.
device_failed :: proc "contextless" (text: string) -> ! {
	for pending_count > 0 {
		record := pending[pending_head]
		ring.push(&clients.completions, ring.Record{kind = u32(timed_stream.Status.Device_Error), tag = record.tag, values = errors.ring_fail(u32(timed_stream.Command.Play), .Device, .None, 0, 0, 0, i64(virtio.status_read(&device)))})
		pending_head = (pending_head + 1) % timed_stream.RING_CAPACITY
		pending_count -= 1
	}
	system.wake_reader(&clients.completions)
	fail(text)
}

// room says if the completion queue has a place for the completion of each
// pending record and of one more command.
room :: proc "contextless" () -> bool {
	return ring.count(&clients.completions) + pending_count < ring.capacity(&clients.completions)
}

// USED_PROBLEM_TEXTS gives the reason of a stop for each refused used entry.
@(rodata)
USED_PROBLEM_TEXTS := [sound_device.Used_Problem]string {
	.None         = "",
	.Not_A_Head   = "the device used a descriptor that starts no period",
	.Not_Given    = "the device used a period that was not given",
	.Out_Of_Order = "the device ended the periods out of the order in which they were given",
	.Refused      = "the device refused a period",
}

// entry starts the device and then serves the stream ring, until the root
// service stops it.
//
// **What it sets up**: the machine handle with the right Physical, the
// stream ring, and the configuration of the device that the root service
// copied. It finds the virtio registers, resets the device, gives it the
// control queue and the transmit queue, makes the periods, finds the
// output stream and sets the one format (`start`). It then writes
// `sound: ok, the output stream ...`.
//
// **The loop.** After each wake:
//
// 1. It reads the used ring of the transmit queue. Each period that the
//    device took frees its slot, in the order of the periods; each pending
//    record whose last frame was taken gets its completion.
// 2. When the device holds no period and the time is past the end of the
//    frames given, the service was late: an underrun. It moves the anchor,
//    so the next frame plays now.
// 3. It gives a new period for each free slot, unless the frames given end
//    too far ahead of now: it then holds the period until its time.
// 4. While the completion queue has room, it takes the next command
//    through its border: `Attach`, `Start` or `Play`; any other word
//    completes at once with its refusal.
// 5. It tells the device of the new periods, wakes the client when a
//    completion came, and waits for the interrupt of the device, a new
//    command, or the end of a hold.
//
// **The stop**: with no ring, a ring larger than the contract, no
// configuration, no virtio registers, no output stream of the format, a
// device that does not answer, needs a reset, or uses a period out of
// order or that was not given, it writes the reason at the level error and
// stops with `Failed`. Else it never returns.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	machine = ctx.handles[pci.GRANT_MACHINE]
	clients_memory = ctx.handles[timed_stream.SERVICE_RING]
	status: system.Status
	if clients, status = system.ring_open(clients_memory); status != .Ok {
		fail("no stream ring")
	}
	// The table of the pending records has one place for each place of
	// the ring of the contract.
	if ring.capacity(&clients.completions) > timed_stream.RING_CAPACITY || ring.capacity(&clients.commands) > timed_stream.RING_CAPACITY {
		fail("the stream ring is larger than the ring of the contract")
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

	for {
		wait := system.wait_begin() // An interrupt of the device is an event.
		answered := false
		wake_at := system.WAIT_FOREVER
		// The used ring is read at each wake: an entry that no period asked
		// for is a fault of the device, as a reset is.
		for {
			used := virtio.used(&transmit_queue) or_break
			answer: u32
			if slot, named := sound_device.period_status_slot(used.id); named {
				answer = (^u32)(&messages[MESSAGE_STATUSES + slot * MESSAGE_SLOT_BYTES])^
			}
			taken_end, problem := sound_device.period_used(&periods, used.id, answer)
			if problem != .None {
				if problem == .Refused {
					system.log_fact(.Error, Period_Refused{answer_code = u64(answer)})
				}
				device_failed(USED_PROBLEM_TEXTS[problem])
			}
			answered = taken(taken_end) || answered
		}
		if virtio.used_ready(&control_queue) {
			device_failed("the device answered a control request that was not given")
		}
		if started {
			if virtio.status_read(&device) & virtio.STATUS_NEEDS_RESET != 0 {
				device_failed("the device needs a reset")
			}
			now := system.nanoseconds()
			if sound_device.underrun(&periods, anchor, now) {
				underruns += 1
				if underruns == 1 {
					system.log(.Warning, "sound: the first underrun: the device took each period before the next one came; the next frame plays now, and each completion counts the underruns")
				}
				anchor = {frame = periods.next_frame, time = now}
			}
			wake_at = periods_give()
		}

		for room() {
			command := system.receive(&clients.commands) or_break
			answered = true
			member, known := timed_stream.command_of_ring_word(command.kind)
			if !known {
				ring.push(&clients.completions, ring.Record{kind = u32(timed_stream.Status.Bad_Command), tag = command.tag, values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind))})
				continue
			}
			switch member {
			case .None:
				// The border never gives None: a word 0 is refused above.
				ring.push(&clients.completions, ring.Record{kind = u32(timed_stream.Status.Bad_Command), tag = command.tag, values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind))})
			case .Attach:
				attach_status, values := attach(command)
				ring.push(&clients.completions, ring.Record{kind = u32(attach_status), tag = command.tag, values = values})
			case .Start:
				start_status, values := stream_start(command)
				ring.push(&clients.completions, ring.Record{kind = u32(start_status), tag = command.tag, values = values})
				if stop_reason != "" {
					device_failed(stop_reason)
				}
			case .Play:
				play_status, values, accepted := play(command)
				if !accepted {
					ring.push(&clients.completions, ring.Record{kind = u32(play_status), tag = command.tag, values = values})
				}
			}
		}
		virtio.notify(&transmit_queue)
		if answered {
			system.wake_reader(&clients.completions)
		}
		if virtio.used_ready(&transmit_queue) {
			continue
		}
		// With no room because each place waits for a record that plays,
		// the next period of the device frees one: the wait is for its
		// interrupt only, else the wait for room would end at once.
		if room() {
			system.wait_records(&wait, &clients.commands)
		} else if ring.count(&clients.completions) == ring.capacity(&clients.completions) {
			system.wait_room(&wait, &clients.completions)
		}
		system.wait_end(&wait, wake_at)
	}
}

#assert(timed_stream.PERIODS_GIVEN * sound_device.DESCRIPTORS_OF_A_PERIOD <= virtio.QUEUE_SIZE_LIMIT)
#assert(timed_stream.PERIOD_BYTES % timed_stream.FRAME_BYTES == 0)
