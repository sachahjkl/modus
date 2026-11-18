// The sound service: the device service of the sound device of the machine
// (virtio-snd, virtio 1.x over PCI). It serves a timed stream to its one
// client: each record of frames plays at the time that it names
// (src/md/features/timed_stream.md).
//
// It has one device and nothing else: the registers of the device, one
// message interrupt, memory for the queues, the machine with the right
// Physical only, a copy of the configuration of the device, and the stream
// ring. The root service found the device, enabled it and set its
// interrupt (src/library/support/pci), when the program with the grant
// **Sound_Device** started; it stops this service when that program stops.
//
// **What it is for.** A program plays sound at a time of the system clock,
// and never sees the device, its queues or its clock.
//
// **The commands of the stream ring** (`src/library/contract/timed_stream`):
// `Attach` with the sample region, `Start`, then `Play` for each record.
// The completion of a `Play` comes when the device played its last frame.
// A refusal gives a status and the values of an
// [error record](term:error-record), and no frame of the record plays.
//
// **What a reader sees.** No window: the line `sound: ok, the output
// stream <n> of <count>, ...` on the log when the device is ready, the line
// `sound: the stream started, ...` at `Start`, and one line at the first
// underrun. A failure writes a line at the level error on the channel
// `sound` and stops the service.
//
// **What it does not prove.** It does not know the delay of the device
// after a period: QEMU reports none. It corrects no drift of the clock of
// the device.
package sound_device_service

import "base:intrinsics"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/timed_stream"
import "modus:support/pci"
import "modus:support/system"
import "modus:support/virtio"

// The working memory: the rest of the pages that the root service gave it
// by its name, once the tool counts its module and its thread. As for the
// entropy service, the tables of the domain of the device under the IOMMU
// are paid from it; the periods and their list take PERIOD_PAGES + 1 more,
// and the map of the sample region of the client its page tables.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 190, programs = 1, threads = 1}

// The memory of the queues (pci.QUEUE_PAGES): pages 0 to 2 the control
// queue, pages 3 to 5 the transmit queue, page 6 the messages that the
// device reads and writes. The device reaches no other memory of this
// program but the periods.
PAGE_CONTROL_QUEUE :: 0
PAGE_TRANSMIT_QUEUE :: PAGE_CONTROL_QUEUE + virtio.QUEUE_PAGES
PAGE_MESSAGES :: PAGE_TRANSMIT_QUEUE + virtio.QUEUE_PAGES
#assert(PAGE_MESSAGES < pci.QUEUE_PAGES)

// The places in the page of the messages.
MESSAGE_REQUEST :: 0 // The control request that the device reads.
MESSAGE_RESPONSE :: 64 // The control response that the device writes.
MESSAGE_RESPONSE_BYTES :: 4 + STREAM_LIMIT * PCM_INFO_BYTES
MESSAGE_HEADERS :: 1024 // The header of the request of each period: the stream.
MESSAGE_STATUSES :: 2048 // The status of each period, which the device writes.
MESSAGE_SLOT_BYTES :: 16
#assert(MESSAGE_RESPONSE + MESSAGE_RESPONSE_BYTES <= MESSAGE_HEADERS)
#assert(MESSAGE_STATUSES + timed_stream.PERIODS_GIVEN * MESSAGE_SLOT_BYTES <= system.PAGE_SIZE)

// The periods that the device reads: one memory object of this program.
PERIOD_PAGES :: (timed_stream.PERIODS_GIVEN * timed_stream.PERIOD_BYTES + system.PAGE_SIZE - 1) / system.PAGE_SIZE

// The queues of a virtio sound device (virtio 1.2, 5.14.2).
QUEUE_CONTROL :: 0
QUEUE_TRANSMIT :: 2
// The descriptors of the request of one period: the header, the frames,
// the status.
DESCRIPTORS_OF_A_PERIOD :: 3

// The codes of the requests and of the answers (virtio 1.2, 5.14.6).
REQUEST_PCM_INFO :: 0x0100
REQUEST_PCM_SET_PARAMS :: 0x0101
REQUEST_PCM_PREPARE :: 0x0102
REQUEST_PCM_START :: 0x0104
ANSWER_OK :: 0x8000
// The device configuration: jacks, streams and channel maps, 4 bytes each.
CONFIGURATION_BYTES :: 12
CONFIGURATION_STREAMS :: 4
// One record of PCM_INFO, and its fields.
PCM_INFO_BYTES :: 32
PCM_INFO_FORMATS :: 8
PCM_INFO_RATES :: 16
PCM_INFO_DIRECTION :: 24
PCM_INFO_CHANNELS_LEAST :: 25
PCM_INFO_CHANNELS_MOST :: 26
DIRECTION_OUTPUT :: 0
// The one format: the bit of S16 in the formats, of 48000 in the rates.
FORMAT_SIGNED_16 :: 5
RATE_48000 :: 7
// The streams that this service reads: QEMU has at most 10.
STREAM_LIMIT :: 10

device: virtio.Device
control_queue: virtio.Queue
transmit_queue: virtio.Queue
messages: [^]u8
messages_physical: u64
periods: [^]u8
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
next_frame: u64 // The first frame not given to the device.
underruns: u64

// A period in the device.
Period_Slot :: struct {
	in_flight:   bool,
	first_frame: u64,
}
slots: [timed_stream.PERIODS_GIVEN]Period_Slot
in_flight: u32

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
	system.log_in("sound", .Error, "sound: ", text)
	system.stop(1)
}

load_u32 :: proc "contextless" (bytes: []u8, offset: int) -> u32 {
	return intrinsics.unaligned_load((^u32)(&bytes[offset]))
}

load_u64 :: proc "contextless" (bytes: []u8, offset: int) -> u64 {
	return intrinsics.unaligned_load((^u64)(&bytes[offset]))
}

// control_call gives the device one control request of `request_bytes`
// bytes, written at MESSAGE_REQUEST, and waits for its answer, of at most
// `response_bytes` bytes. It gives a copy of the answer and its length,
// which the device wrote and which is never above response_bytes. Only the
// start and Start call it, when no period is in flight: no other used
// entry can come.
control_call :: proc "contextless" (request_bytes: u32, response_bytes: u32) -> (response: [MESSAGE_RESPONSE_BYTES]u8, length: u32) {
	control_queue.descriptors[0] = {address = messages_physical + MESSAGE_REQUEST, length = request_bytes, flags = virtio.DESCRIPTOR_NEXT, next = 1}
	control_queue.descriptors[1] = {address = messages_physical + MESSAGE_RESPONSE, length = response_bytes, flags = virtio.DESCRIPTOR_DEVICE_WRITES}
	virtio.give(&control_queue, 0)
	virtio.notify(&control_queue)
	for {
		wait := system.wait_begin() // An interrupt of the device is an event.
		if used, ok := virtio.used(&control_queue); ok {
			if used.id != 0 {
				fail("the device answered a control request that was not given")
			}
			length = min(used.length, response_bytes)
			intrinsics.mem_copy_non_overlapping(&response, &messages[MESSAGE_RESPONSE], int(length))
			return response, length
		}
		if virtio.used_ready(&transmit_queue) {
			fail("the device used a period that was not given")
		}
		if virtio.status_read(&device) & virtio.STATUS_NEEDS_RESET != 0 {
			fail("the device needs a reset")
		}
		system.wait_end(&wait)
	}
}

// answer_code gives the code of a control answer, or 0 when the device
// wrote fewer bytes than the code.
answer_code :: proc "contextless" (response: []u8, length: u32) -> u32 {
	return length < 4 ? 0 : load_u32(response, 0)
}

// stream_choose asks the device for its streams and gives the first output
// stream that plays the one format. found false: no stream does.
stream_choose :: proc "contextless" () -> (stream: u32, count: u32, found: bool) {
	if device.device_config_length < CONFIGURATION_BYTES {
		fail("the configuration of the device is too short")
	}
	count = virtio.load_32(device.device_config + CONFIGURATION_STREAMS)
	asked := min(count, STREAM_LIMIT)
	if asked == 0 {
		return 0, count, false
	}
	request := ([^]u32)(&messages[MESSAGE_REQUEST])
	request[0] = REQUEST_PCM_INFO
	request[1] = 0 // The first stream.
	request[2] = asked
	request[3] = PCM_INFO_BYTES
	response, length := control_call(16, 4 + asked * PCM_INFO_BYTES)
	if answer_code(response[:], length) != ANSWER_OK {
		system.log_in("sound", .Error, "sound: the device refused PCM_INFO with the code ", u64(answer_code(response[:], length)))
		return 0, count, false
	}
	// The device says how many bytes it wrote: a record that it did not
	// write whole is not read.
	whole := (length - 4) / PCM_INFO_BYTES
	for index in 0 ..< min(whole, asked) {
		info := response[4 + index * PCM_INFO_BYTES:][:PCM_INFO_BYTES]
		formats := load_u64(info, PCM_INFO_FORMATS)
		rates := load_u64(info, PCM_INFO_RATES)
		plays_the_format := formats & (1 << FORMAT_SIGNED_16) != 0 && rates & (1 << RATE_48000) != 0
		holds_the_channels := info[PCM_INFO_CHANNELS_LEAST] <= timed_stream.CHANNELS && timed_stream.CHANNELS <= info[PCM_INFO_CHANNELS_MOST]
		if info[PCM_INFO_DIRECTION] == DIRECTION_OUTPUT && plays_the_format && holds_the_channels {
			return index, count, true
		}
	}
	return 0, count, false
}

// stream_prepare sets the one format on the stream and prepares it.
stream_prepare :: proc "contextless" () {
	request := ([^]u32)(&messages[MESSAGE_REQUEST])
	request[0] = REQUEST_PCM_SET_PARAMS
	request[1] = stream_number
	request[2] = timed_stream.PERIODS_GIVEN * timed_stream.PERIOD_BYTES // The buffer of the device.
	request[3] = timed_stream.PERIOD_BYTES
	request[4] = 0 // No feature.
	messages[MESSAGE_REQUEST + 20] = timed_stream.CHANNELS
	messages[MESSAGE_REQUEST + 21] = FORMAT_SIGNED_16
	messages[MESSAGE_REQUEST + 22] = RATE_48000
	messages[MESSAGE_REQUEST + 23] = 0
	response, length := control_call(24, 4)
	if code := answer_code(response[:], length); code != ANSWER_OK {
		system.log_in("sound", .Error, "sound: the device refused PCM_SET_PARAMS with the code ", u64(code))
		fail("the device does not take the format")
	}
	request[0] = REQUEST_PCM_PREPARE
	request[1] = stream_number
	response, length = control_call(8, 4)
	if code := answer_code(response[:], length); code != ANSWER_OK {
		system.log_in("sound", .Error, "sound: the device refused PCM_PREPARE with the code ", u64(code))
		fail("the device does not prepare the stream")
	}
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
		system.log_in("sound", .Error, "sound: the map of the queues gave the status ", map_status, ", their device address the status ", physical_status)
		fail("no physical address for the queues")
	}
	base := uintptr(address)
	errors_of_queues: [2]virtio.Queue_Error
	control_queue, errors_of_queues[0] = virtio.queue_start(&device, QUEUE_CONTROL, base + PAGE_CONTROL_QUEUE * system.PAGE_SIZE, physical + PAGE_CONTROL_QUEUE * system.PAGE_SIZE, 2, 0)
	transmit_queue, errors_of_queues[1] = virtio.queue_start(&device, QUEUE_TRANSMIT, base + PAGE_TRANSMIT_QUEUE * system.PAGE_SIZE, physical + PAGE_TRANSMIT_QUEUE * system.PAGE_SIZE, timed_stream.PERIODS_GIVEN * DESCRIPTORS_OF_A_PERIOD, 0)
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
		system.log_in("sound", .Error, "sound: the memory of the periods gave the status ", period_status)
		fail("no memory for the periods")
	}
	period_address, period_map_status := system.memory_map(period_memory, {.Write})
	period_physical, period_physical_status := system.memory_physical(machine, period_memory)
	if period_map_status != .Ok || period_physical_status != .Ok {
		system.log_in("sound", .Error, "sound: the map of the periods gave the status ", period_map_status, ", their device address the status ", period_physical_status)
		fail("no physical address for the periods")
	}
	periods = ([^]u8)(period_address)
	periods_physical = period_physical
	virtio.ready(&device)

	found: bool
	count: u32
	if stream_number, count, found = stream_choose(); !found {
		system.log_in("sound", .Error, "sound: the device has ", u64(count), " streams, and none plays 48000 frames in one second of 2 channels of signed 16-bit samples")
		fail("no output stream of the format")
	}
	stream_prepare()
	system.log("sound: ok, the output stream ", u64(stream_number), " of ", u64(count), ", 48000 frames in one second, 2 channels of signed 16-bit samples; ", u64(timed_stream.PERIODS_GIVEN), " periods of ", u64(timed_stream.PERIOD_FRAMES), " frames with the device; a transmit queue of ", u64(transmit_queue.size))
}

// region_refusal_of_a_stream checks the handle of a sample region that the
// client sent with Attach: memory, with Read, that came through the stream
// ring. The service never writes the region, so it asks for no Write.
region_refusal_of_a_stream :: proc "contextless" (handle: system.Handle) -> (values: [7]u64, refused: bool) {
	ATTACH :: u32(timed_stream.Command.Attach)
	kind, rights, through := system.handle_state(handle, clients_memory)
	needed := system.Rights{.Read}
	switch {
	case kind != .Memory:
		return errors.ring_fail(ATTACH, .Handle_Kind, .None, 1, i64(handle), i64(op.Object_Kind.Memory), i64(kind)), true
	case !(needed <= rights):
		return errors.ring_fail(ATTACH, .Handle_Rights, .None, 1, i64(handle), i64(transmute(u32)needed), i64(transmute(u32)rights)), true
	case !through:
		return errors.ring_fail(ATTACH, .Absent, .Region, 1), true
	}
	return {}, false
}

// attach takes the sample region of the client, once.
attach :: proc "contextless" (handle: system.Handle) -> (timed_stream.Status, [7]u64) {
	ATTACH :: u32(timed_stream.Command.Attach)
	if region_memory != 0 {
		return .Bad_Command, errors.ring_fail(ATTACH, .State, .None, 0)
	}
	if values, refused := region_refusal_of_a_stream(handle); refused {
		return .No_Region, values
	}
	pages, size_status := system.memory_size(handle)
	if size_status != .Ok {
		return .No_Region, errors.ring_fail(ATTACH, .Refused, .None, 1, i64(handle), 0, i64(size_status))
	}
	address, map_status := system.memory_map(handle, {})
	if map_status != .Ok {
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
	bytes := periods[slot * timed_stream.PERIOD_BYTES:][:timed_stream.PERIOD_BYTES]
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
// gives it to the device: the header, the frames, the status.
period_give :: proc "contextless" (slot: u32) {
	header_place := MESSAGE_HEADERS + slot * MESSAGE_SLOT_BYTES
	status_place := MESSAGE_STATUSES + slot * MESSAGE_SLOT_BYTES
	(^u32)(&messages[header_place])^ = stream_number
	// A device that does not write the status then gives no Ok of an
	// earlier period.
	(^u32)(&messages[status_place])^ = 0
	period_fill(slot, next_frame)
	head := u16(slot * DESCRIPTORS_OF_A_PERIOD)
	transmit_queue.descriptors[head] = {address = messages_physical + u64(header_place), length = 4, flags = virtio.DESCRIPTOR_NEXT, next = head + 1}
	transmit_queue.descriptors[head + 1] = {address = periods_physical + u64(slot * timed_stream.PERIOD_BYTES), length = timed_stream.PERIOD_BYTES, flags = virtio.DESCRIPTOR_NEXT, next = head + 2}
	transmit_queue.descriptors[head + 2] = {address = messages_physical + u64(status_place), length = 8, flags = virtio.DESCRIPTOR_DEVICE_WRITES}
	virtio.give(&transmit_queue, head)
	slots[slot] = {in_flight = true, first_frame = next_frame}
	next_frame += timed_stream.PERIOD_FRAMES
	in_flight += 1
}

// periods_give gives a period for each free slot.
periods_give :: proc "contextless" () {
	for slot in 0 ..< u32(timed_stream.PERIODS_GIVEN) {
		if !slots[slot].in_flight {
			period_give(slot)
		}
	}
}

// stream_start starts the device, sets the anchor at its answer, and gives
// it the first periods: silence until the first record.
stream_start :: proc "contextless" () -> (timed_stream.Status, [7]u64) {
	START :: u32(timed_stream.Command.Start)
	if started {
		return .Bad_Command, errors.ring_fail(START, .State, .None, 0)
	}
	if region_memory == 0 {
		return .No_Region, errors.ring_fail(START, .Absent, .Region, 0)
	}
	request := ([^]u32)(&messages[MESSAGE_REQUEST])
	request[0] = REQUEST_PCM_START
	request[1] = stream_number
	response, length := control_call(8, 4)
	if code := answer_code(response[:], length); code != ANSWER_OK {
		return .Device_Error, errors.ring_fail(START, .Device, .None, 0, 0, 0, i64(code))
	}
	started = true
	anchor = {frame = 0, time = system.nanoseconds()}
	next_frame = 0
	periods_give()
	virtio.notify(&transmit_queue)
	latency, _ := timed_stream.time_of_frame({}, timed_stream.PERIODS_GIVEN * timed_stream.PERIOD_FRAMES)
	system.log("sound: the stream started: the frame 0 plays at ", anchor.time, " ns of the system clock; the service holds ", latency, " ns")
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
	pending_end := next_frame
	if pending_count > 0 {
		pending_end = pending[(pending_head + pending_count - 1) % timed_stream.RING_CAPACITY].end_frame
	}
	placement, decision := timed_stream.play_place(record, anchor, next_frame, pending_end)
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

// played completes each pending record whose last frame is before the
// end of the frames that the device played.
played :: proc "contextless" (played_end: u64) -> (answered: bool) {
	for pending_count > 0 {
		record := pending[pending_head]
		if record.end_frame > played_end {
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
//    device played frees its slot; each pending record whose last frame
//    played gets its completion.
// 2. When the device played each period that it held and the time is past
//    the end of the frames given, the service was late: an underrun. It
//    moves the anchor, so the next frame plays now.
// 3. It gives a new period for each free slot.
// 4. While the completion queue has room, it takes the next command
//    through its border: `Attach`, `Start` or `Play`; any other word
//    completes at once with its refusal.
// 5. It tells the device of the new periods, wakes the client when a
//    completion came, and waits for the interrupt of the device or a new
//    command.
//
// **The stop**: with no ring, no configuration, no virtio registers, no
// output stream of the format, a device that needs a reset, or a device
// that uses a period that was not given, it writes the reason at the level
// error and stops with the code 1. Else it never returns.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	machine = ctx.handles[pci.GRANT_MACHINE]
	clients_memory = ctx.handles[timed_stream.SERVICE_RING]
	status: system.Status
	if clients, status = system.ring_open(clients_memory); status != .Ok {
		fail("no stream ring")
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
		// The used ring is read at each wake: an entry that no period asked
		// for is a fault of the device, as a reset is.
		for {
			used := virtio.used(&transmit_queue) or_break
			slot := used.id / DESCRIPTORS_OF_A_PERIOD
			if used.id % DESCRIPTORS_OF_A_PERIOD != 0 || slot >= timed_stream.PERIODS_GIVEN || !slots[slot].in_flight {
				device_failed("the device used a period that was not given")
			}
			answer := (^u32)(&messages[MESSAGE_STATUSES + slot * MESSAGE_SLOT_BYTES])^
			if answer != ANSWER_OK {
				system.log_in("sound", .Error, "sound: the device answered a period with the code ", u64(answer))
				device_failed("the device refused a period")
			}
			slots[slot].in_flight = false
			in_flight -= 1
			answered = played(slots[slot].first_frame + timed_stream.PERIOD_FRAMES) || answered
		}
		if virtio.used_ready(&control_queue) {
			device_failed("the device answered a control request that was not given")
		}
		if started && in_flight == 0 {
			now := system.nanoseconds()
			if end, known := timed_stream.time_of_frame(anchor, next_frame); !known || now > end {
				underruns += 1
				if underruns == 1 {
					system.log_in("sound", .Warning, "sound: the first underrun: the device played each period before the next one came; the next frame plays now, and each completion counts the underruns")
				}
				anchor = {frame = next_frame, time = now}
			}
		}
		if started {
			if virtio.status_read(&device) & virtio.STATUS_NEEDS_RESET != 0 {
				device_failed("the device needs a reset")
			}
			periods_give()
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
				attach_status, values := attach(system.Handle(command.values[0]))
				ring.push(&clients.completions, ring.Record{kind = u32(attach_status), tag = command.tag, values = values})
			case .Start:
				start_status, values := stream_start()
				ring.push(&clients.completions, ring.Record{kind = u32(start_status), tag = command.tag, values = values})
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
		system.wait_end(&wait)
	}
}

#assert(timed_stream.PERIODS_GIVEN * DESCRIPTORS_OF_A_PERIOD <= virtio.QUEUE_SIZE_LIMIT)
#assert(timed_stream.PERIOD_BYTES % timed_stream.FRAME_BYTES == 0)
