#+build !freestanding
package venus_vulkan

import "core:testing"
import "modus:contract/byte_order"

EXCHANGE_RING_BUFFER :: u32(4096)
EXCHANGE_REPLY_BYTES :: 1024
EXCHANGE_REPLY_RESOURCE :: u32(9)

// The shared memory of the ring and of the reply stream, aligned as a blob
// mapping is.
@(private = "file")
Exchange_Memory :: struct #align (64) {
	ring:    [RING_BUFFER_OFFSET + EXCHANGE_RING_BUFFER]u8,
	replies: [EXCHANGE_REPLY_BYTES]u8,
}

// The renderer of the tests: it takes the commands of the ring, writes the
// planned reply of each command with the reply flag at the position of the
// last seek, then stores its head, as vkr_ring does.
@(private = "file")
Test_Renderer :: struct {
	reader:   Ring_Reader,
	replies:  []u8,
	bound:    bool,
	position: u64,
	taken:    [EXCHANGE_RING_BUFFER]u8,
}

@(private = "file")
Exchange :: struct {
	memory:   Exchange_Memory,
	ring:     Ring,
	stream:   Reply_Stream,
	renderer: Test_Renderer,
	staging:  [512]u8,
	reply:    [EXCHANGE_REPLY_BYTES]u8,
}

@(private = "file")
exchange_start :: proc(exchange: ^Exchange, start: u32 = 0) {
	problem: Venus_Problem
	exchange.ring, problem = ring_init(exchange.memory.ring[:], EXCHANGE_RING_BUFFER, 0)
	assert(problem == .None)
	exchange.renderer.reader, problem = ring_reader_init(exchange.memory.ring[:], EXCHANGE_RING_BUFFER)
	assert(problem == .None)
	exchange.stream, problem = reply_stream_init(exchange.memory.replies[:], EXCHANGE_REPLY_RESOURCE, 4096)
	assert(problem == .None)
	exchange.renderer.replies = exchange.memory.replies[:]
	exchange.ring.tail = start
	exchange.renderer.reader.head = start
	byte_order.write_u32_little_endian(exchange.memory.ring[:], RING_HEAD_OFFSET, start)
	byte_order.write_u32_little_endian(exchange.memory.ring[:], RING_TAIL_OFFSET, start)
}

// renderer_run runs each command that waits in the ring and answers the
// one command with the reply flag with planned_reply. It gives the count
// of the commands that it ran.
@(private = "file")
renderer_run :: proc(t: ^testing.T, renderer: ^Test_Renderer, planned_reply: []u8) -> int {
	taken, problem := ring_reader_take(&renderer.reader, renderer.taken[:])
	testing.expect_value(t, problem, Venus_Problem.None)
	decoder := decoder_init(renderer.taken[:taken])
	commands := 0
	for decoder.cursor < taken {
		command, command_problem := command_decode_next(&decoder)
		if !testing.expect_value(t, command_problem, Venus_Problem.None) {
			return commands
		}
		commands += 1
		#partial switch command.command_type {
		case .Set_Reply_Command_Stream:
			testing.expect_value(t, u32(command.values[0]), EXCHANGE_REPLY_RESOURCE)
			testing.expect_value(t, command.values[1], u64(4096))
			testing.expect_value(t, command.values[2], u64(len(renderer.replies)))
			renderer.bound = true
		case .Seek_Reply_Command_Stream:
			renderer.position = command.values[0]
		case:
			if .Generate_Reply in command.flags {
				testing.expect(t, renderer.bound, "a reply before the reply stream is set")
				testing.expect_value(t, byte_order.read_u32_little_endian(planned_reply, 0), u32(command.command_type))
				copy(renderer.replies[renderer.position:], planned_reply)
				renderer.position += u64(len(planned_reply))
			}
		}
	}
	ring_reader_release(&renderer.reader)
	return commands
}

// exchange_one sends one command, checks that its reply is not ready before
// the renderer runs, runs the renderer, and gives the reply.
@(private = "file")
exchange_one :: proc(t: ^testing.T, exchange: ^Exchange, command: []u8, planned_reply: []u8) -> []u8 {
	submission, problem := venus_ring_submit_command(&exchange.ring, &exchange.stream, command, u64(len(planned_reply)), exchange.staging[:])
	if !testing.expect_value(t, problem, Venus_Problem.None) {
		return nil
	}
	reply, ready, poll_problem := venus_ring_poll_reply(&exchange.ring, &exchange.stream, &submission, exchange.reply[:])
	testing.expect(t, poll_problem == .None && !ready && reply == nil, "a reply is not ready before the renderer runs")
	renderer_run(t, &exchange.renderer, planned_reply)
	reply, ready, poll_problem = venus_ring_poll_reply(&exchange.ring, &exchange.stream, &submission, exchange.reply[:])
	testing.expect(t, poll_problem == .None && ready, "the reply is ready after the renderer runs")
	_, _, again := venus_ring_poll_reply(&exchange.ring, &exchange.stream, &submission, exchange.reply[:])
	testing.expect_value(t, again, Venus_Problem.Reply_Already_Read)
	return reply
}

@(private = "file")
encoded :: proc(storage: []u8, write: proc(encoder: ^Encoder) -> Venus_Problem) -> []u8 {
	encoder := encoder_init(storage)
	assert(write(&encoder) == .None)
	return encoder_bytes(&encoder)
}

// The start of a Vulkan device through the ring: each command and its reply,
// in the order of a driver, with each reply decoded.
@(test)
exchange_reads_each_reply_through_the_ring :: proc(t: ^testing.T) {
	exchange := new(Exchange)
	defer free(exchange)
	exchange_start(exchange)
	command_storage: [512]u8
	reply_storage: [EXCHANGE_REPLY_BYTES]u8

	// vkCreateInstance.
	command := encoded(command_storage[:], proc(encoder: ^Encoder) -> Venus_Problem {
		return encode_create_instance(encoder, 1, {application_name = "modus", api_version = API_VERSION_1_1})
	})
	planned := encoded(reply_storage[:], proc(encoder: ^Encoder) -> Venus_Problem {
		return encode_create_object_reply(encoder, .Create_Instance, .Success, 1)
	})
	testing.expect_value(t, u64(len(planned)), create_object_reply_bytes(.Create_Instance))
	reply := exchange_one(t, exchange, command, planned)
	decoder := decoder_init(reply)
	result, problem := decode_create_object_reply(&decoder, .Create_Instance, 1)
	testing.expect(t, problem == .None && result == .Success && decoder_done(&decoder))

	// vkEnumeratePhysicalDevices with one id.
	command = encoded(command_storage[:], proc(encoder: ^Encoder) -> Venus_Problem {
		ids := [1]Object_Id{2}
		return encode_enumerate_physical_devices(encoder, 1, ids[:])
	})
	planned = encoded(reply_storage[:], proc(encoder: ^Encoder) -> Venus_Problem {
		ids := [1]Object_Id{2}
		return encode_enumerate_physical_devices_reply(encoder, .Success, 1, ids[:])
	})
	testing.expect_value(t, u64(len(planned)), enumerate_physical_devices_reply_bytes(1))
	reply = exchange_one(t, exchange, command, planned)
	decoder = decoder_init(reply)
	ids := [1]Object_Id{2}
	enumerate_result, device_count, enumerate_problem := decode_enumerate_physical_devices_reply(&decoder, ids[:])
	testing.expect(t, enumerate_problem == .None && enumerate_result == .Success && device_count == 1 && decoder_done(&decoder))

	// vkGetPhysicalDeviceProperties: the largest reply, 880 bytes.
	command = encoded(command_storage[:], proc(encoder: ^Encoder) -> Venus_Problem {
		return encode_get_physical_device_properties(encoder, 2)
	})
	planned = encoded(reply_storage[:], proc(encoder: ^Encoder) -> Venus_Problem {
		properties: Physical_Device_Properties
		properties.api_version = API_VERSION_1_1
		properties.driver_version = 7
		properties.vendor_id = 0x1AF4
		properties.device_id = 0x1050
		properties.device_type = .Virtual_Gpu
		copy(properties.device_name[:], "Virtio-GPU Venus (Intel Arc)")
		return encode_get_physical_device_properties_reply(encoder, &properties)
	})
	testing.expect_value(t, u64(len(planned)), physical_device_properties_reply_bytes())
	reply = exchange_one(t, exchange, command, planned)
	decoder = decoder_init(reply)
	properties: Physical_Device_Properties
	testing.expect_value(t, decode_get_physical_device_properties_reply(&decoder, &properties), Venus_Problem.None)
	testing.expect_value(t, properties.api_version, API_VERSION_1_1)
	testing.expect_value(t, properties.driver_version, u32(7))
	testing.expect_value(t, properties.vendor_id, u32(0x1AF4))
	testing.expect_value(t, properties.device_id, u32(0x1050))
	testing.expect_value(t, properties.device_type, Physical_Device_Type.Virtual_Gpu)
	testing.expect_value(t, device_name_text(&properties), "Virtio-GPU Venus (Intel Arc)")

	// vkCreateDevice, vkCreateBuffer, vkAllocateMemory.
	command = encoded(command_storage[:], proc(encoder: ^Encoder) -> Venus_Problem {
		return encode_create_device(encoder, 2, 3, 0, 1.0)
	})
	planned = encoded(reply_storage[:], proc(encoder: ^Encoder) -> Venus_Problem {
		return encode_create_object_reply(encoder, .Create_Device, .Success, 3)
	})
	reply = exchange_one(t, exchange, command, planned)
	decoder = decoder_init(reply)
	result, problem = decode_create_object_reply(&decoder, .Create_Device, 3)
	testing.expect(t, problem == .None && result == .Success)

	command = encoded(command_storage[:], proc(encoder: ^Encoder) -> Venus_Problem {
		return encode_create_buffer(encoder, 3, 4, 4096, {.Transfer_Source})
	})
	planned = encoded(reply_storage[:], proc(encoder: ^Encoder) -> Venus_Problem {
		return encode_create_object_reply(encoder, .Create_Buffer, .Error_Out_Of_Device_Memory, 4)
	})
	reply = exchange_one(t, exchange, command, planned)
	decoder = decoder_init(reply)
	result, problem = decode_create_object_reply(&decoder, .Create_Buffer, 4)
	testing.expect(t, problem == .None && result == .Error_Out_Of_Device_Memory)

	command = encoded(command_storage[:], proc(encoder: ^Encoder) -> Venus_Problem {
		return encode_allocate_memory(encoder, 3, 5, 4096, 0)
	})
	planned = encoded(reply_storage[:], proc(encoder: ^Encoder) -> Venus_Problem {
		return encode_create_object_reply(encoder, .Allocate_Memory, .Success, 5)
	})
	reply = exchange_one(t, exchange, command, planned)
	decoder = decoder_init(reply)
	result, problem = decode_create_object_reply(&decoder, .Allocate_Memory, 5)
	testing.expect(t, problem == .None && result == .Success)

	// vkQueueSubmit asks for its reply with the flag.
	command = encoded(command_storage[:], proc(encoder: ^Encoder) -> Venus_Problem {
		buffers := [1]Object_Id{7}
		return encode_queue_submit(encoder, 6, buffers[:], 0, REPLY)
	})
	planned = encoded(reply_storage[:], proc(encoder: ^Encoder) -> Venus_Problem {
		return encode_result_reply(encoder, .Queue_Submit, .Success)
	})
	testing.expect_value(t, u64(len(planned)), result_reply_bytes(.Queue_Submit))
	reply = exchange_one(t, exchange, command, planned)
	decoder = decoder_init(reply)
	result, problem = decode_result_reply(&decoder, .Queue_Submit)
	testing.expect(t, problem == .None && result == .Success)
	testing.expect_value(t, exchange.stream.pending, u32(0))
}

// Many exchanges, with the counters of the ring past the largest u32: each
// write of a seek and its command crosses the end of the buffer somewhere,
// and each reply still reads back whole.
@(test)
exchange_wraps_around_the_ring :: proc(t: ^testing.T) {
	exchange := new(Exchange)
	defer free(exchange)
	exchange_start(exchange, max(u32) - 100)
	command_storage: [512]u8
	reply_storage: [64]u8
	restarts := 0
	for index in 0 ..< 300 {
		buffer := Object_Id(100 + index)
		encoder := encoder_init(command_storage[:])
		testing.expect_value(t, encode_create_buffer(&encoder, 3, buffer, 4096, {.Vertex_Buffer}), Venus_Problem.None)
		reply_encoder := encoder_init(reply_storage[:])
		testing.expect_value(t, encode_create_object_reply(&reply_encoder, .Create_Buffer, .Success, buffer), Venus_Problem.None)
		reply := exchange_one(t, exchange, encoder_bytes(&encoder), encoder_bytes(&reply_encoder))
		if index > 0 && exchange.stream.reserved == u64(len(encoder_bytes(&reply_encoder))) {
			restarts += 1
		}
		decoder := decoder_init(reply)
		result, problem := decode_create_object_reply(&decoder, .Create_Buffer, buffer)
		if !testing.expect(t, problem == .None && result == .Success) {
			return
		}
	}
	testing.expect(t, exchange.ring.tail < max(u32) - 100, "the counters wrapped")
	testing.expect(t, restarts > 5, "the reply stream started again at 0")
}

// Each refusal of a submission leaves the ring and the stream as they were.
@(test)
exchange_refuses_bad_submissions :: proc(t: ^testing.T) {
	exchange := new(Exchange)
	defer free(exchange)
	exchange_start(exchange)
	command_storage: [512]u8
	encoder := encoder_init(command_storage[:])
	assert(encode_get_physical_device_properties(&encoder, 2) == .None)
	command := encoder_bytes(&encoder)
	properties_bytes := physical_device_properties_reply_bytes()

	expect_unchanged :: proc(t: ^testing.T, exchange: ^Exchange, got, expected: Venus_Problem) {
		testing.expect_value(t, got, expected)
		testing.expect_value(t, exchange.ring.tail, u32(0))
		testing.expect_value(t, byte_order.read_u32_little_endian(exchange.memory.ring[:], RING_TAIL_OFFSET), u32(0))
		testing.expect(t, exchange.stream.reserved == 0 && exchange.stream.pending == 0 && !exchange.stream.bound)
	}
	_, problem := venus_ring_submit_command(&exchange.ring, &exchange.stream, nil, properties_bytes, exchange.staging[:])
	expect_unchanged(t, exchange, problem, .Stream_Empty)
	_, problem = venus_ring_submit_command(&exchange.ring, &exchange.stream, command[:len(command) - 2], properties_bytes, exchange.staging[:])
	expect_unchanged(t, exchange, problem, .Misaligned_Length)
	_, problem = venus_ring_submit_command(&exchange.ring, &exchange.stream, command[:len(command) - 4], properties_bytes, exchange.staging[:])
	expect_unchanged(t, exchange, problem, .Stream_Truncated)
	// Two commands, and a command with no flag Generate_Reply.
	two := encoder_init(command_storage[:])
	assert(encode_get_physical_device_properties(&two, 2) == .None)
	assert(encode_get_physical_device_properties(&two, 2) == .None)
	_, problem = venus_ring_submit_command(&exchange.ring, &exchange.stream, encoder_bytes(&two), properties_bytes, exchange.staging[:])
	expect_unchanged(t, exchange, problem, .Stream_Too_Large)
	no_reply := encoder_init(command_storage[:])
	assert(encode_get_physical_device_properties(&no_reply, 2, {}) == .None)
	_, problem = venus_ring_submit_command(&exchange.ring, &exchange.stream, encoder_bytes(&no_reply), properties_bytes, exchange.staging[:])
	expect_unchanged(t, exchange, problem, .Reply_Not_Requested)
	// An unknown command type.
	unknown: [8]u8
	byte_order.write_u32_little_endian(unknown[:], 0, 0xFFFF)
	byte_order.write_u32_little_endian(unknown[:], 4, 1)
	_, problem = venus_ring_submit_command(&exchange.ring, &exchange.stream, unknown[:], properties_bytes, exchange.staging[:])
	expect_unchanged(t, exchange, problem, .Unknown_Command_Type)

	encoder = encoder_init(command_storage[:])
	assert(encode_get_physical_device_properties(&encoder, 2) == .None)
	command = encoder_bytes(&encoder)
	// The size of the reply: 0, not a whole word, past the stream.
	for bytes, expected in ([3]struct {
			bytes:    u64,
			expected: Venus_Problem,
		}{{0, .Zero_Extent}, {6, .Misaligned_Length}, {EXCHANGE_REPLY_BYTES + 4, .Stream_Too_Large}}) {
		_ = expected
		_, problem = venus_ring_submit_command(&exchange.ring, &exchange.stream, command, bytes.bytes, exchange.staging[:])
		expect_unchanged(t, exchange, problem, bytes.expected)
	}
	// A staging that cannot hold the seek and the command.
	_, problem = venus_ring_submit_command(&exchange.ring, &exchange.stream, command, properties_bytes, exchange.staging[:len(command)])
	expect_unchanged(t, exchange, problem, .Buffer_Too_Short)
	// A full ring: the renderer has not read the bytes of an earlier write.
	filler: [EXCHANGE_RING_BUFFER - 8]u8
	_, fill_problem := ring_write(&exchange.ring, filler[:])
	testing.expect_value(t, fill_problem, Venus_Problem.None)
	tail := exchange.ring.tail
	_, problem = venus_ring_submit_command(&exchange.ring, &exchange.stream, command, properties_bytes, exchange.staging[:])
	testing.expect_value(t, problem, Venus_Problem.Ring_Full)
	testing.expect_value(t, exchange.ring.tail, tail)
	testing.expect(t, exchange.stream.reserved == 0 && exchange.stream.pending == 0 && !exchange.stream.bound)
}

// The reply stream starts again at 0 only when no reply waits in it.
@(test)
exchange_refuses_a_full_reply_stream :: proc(t: ^testing.T) {
	exchange := new(Exchange)
	defer free(exchange)
	exchange_start(exchange)
	command_storage: [512]u8
	encoder := encoder_init(command_storage[:])
	assert(encode_get_physical_device_properties(&encoder, 2) == .None)
	properties_bytes := physical_device_properties_reply_bytes()
	first, problem := venus_ring_submit_command(&exchange.ring, &exchange.stream, encoder_bytes(&encoder), properties_bytes, exchange.staging[:])
	testing.expect_value(t, problem, Venus_Problem.None)
	tail := exchange.ring.tail
	_, problem = venus_ring_submit_command(&exchange.ring, &exchange.stream, encoder_bytes(&encoder), properties_bytes, exchange.staging[:])
	testing.expect_value(t, problem, Venus_Problem.Reply_Stream_Full)
	testing.expect_value(t, exchange.ring.tail, tail)
	testing.expect_value(t, exchange.stream.pending, u32(1))
	// A destination too small for the reply.
	small: [8]u8
	_, _, poll_problem := venus_ring_poll_reply(&exchange.ring, &exchange.stream, &first, small[:])
	testing.expect_value(t, poll_problem, Venus_Problem.Buffer_Too_Short)
	// The renderer answers; the driver reads; the stream starts again at 0.
	planned: [1024]u8
	properties: Physical_Device_Properties
	reply_encoder := encoder_init(planned[:])
	assert(encode_get_physical_device_properties_reply(&reply_encoder, &properties) == .None)
	renderer_run(t, &exchange.renderer, encoder_bytes(&reply_encoder))
	_, ready, _ := venus_ring_poll_reply(&exchange.ring, &exchange.stream, &first, exchange.reply[:])
	testing.expect(t, ready)
	second, second_problem := venus_ring_submit_command(&exchange.ring, &exchange.stream, encoder_bytes(&encoder), properties_bytes, exchange.staging[:])
	testing.expect_value(t, second_problem, Venus_Problem.None)
	testing.expect_value(t, second.reply_position, u64(0))
	// A submission that names a place past the stream is refused.
	moved := second
	moved.reply_position = EXCHANGE_REPLY_BYTES - 4
	_, _, moved_problem := venus_ring_poll_reply(&exchange.ring, &exchange.stream, &moved, exchange.reply[:])
	testing.expect_value(t, moved_problem, Venus_Problem.Stream_Truncated)
}

// A renderer that sets the fatal bit: each poll and each submission is
// refused, and a status with an unknown bit too.
@(test)
exchange_refuses_a_fatal_ring :: proc(t: ^testing.T) {
	exchange := new(Exchange)
	defer free(exchange)
	exchange_start(exchange)
	command_storage: [512]u8
	encoder := encoder_init(command_storage[:])
	assert(encode_create_device(&encoder, 2, 3, 0, 1.0) == .None)
	reply_bytes := create_object_reply_bytes(.Create_Device)
	submission, problem := venus_ring_submit_command(&exchange.ring, &exchange.stream, encoder_bytes(&encoder), reply_bytes, exchange.staging[:])
	testing.expect_value(t, problem, Venus_Problem.None)
	ring_reader_set_status(&exchange.renderer.reader, {.Fatal})
	_, ready, poll_problem := venus_ring_poll_reply(&exchange.ring, &exchange.stream, &submission, exchange.reply[:])
	testing.expect(t, !ready)
	testing.expect_value(t, poll_problem, Venus_Problem.Ring_Fatal)
	_, problem = venus_ring_submit_command(&exchange.ring, &exchange.stream, encoder_bytes(&encoder), reply_bytes, exchange.staging[:])
	testing.expect_value(t, problem, Venus_Problem.Ring_Fatal)
	byte_order.write_u32_little_endian(exchange.memory.ring[:], RING_STATUS_OFFSET, 1 << 8)
	_, _, poll_problem = venus_ring_poll_reply(&exchange.ring, &exchange.stream, &submission, exchange.reply[:])
	testing.expect_value(t, poll_problem, Venus_Problem.Ring_Status_Invalid)
	// A head past the tail is a hostile renderer.
	byte_order.write_u32_little_endian(exchange.memory.ring[:], RING_STATUS_OFFSET, 0)
	byte_order.write_u32_little_endian(exchange.memory.ring[:], RING_HEAD_OFFSET, exchange.ring.tail + 4)
	_, _, poll_problem = venus_ring_poll_reply(&exchange.ring, &exchange.stream, &submission, exchange.reply[:])
	testing.expect_value(t, poll_problem, Venus_Problem.Ring_Head_Invalid)
}

@(test)
reply_stream_init_refuses_bad_ranges :: proc(t: ^testing.T) {
	memory: Exchange_Memory
	_, problem := reply_stream_init(memory.replies[:], 0, 0)
	testing.expect_value(t, problem, Venus_Problem.Zero_Object_Id)
	_, problem = reply_stream_init(nil, 1, 0)
	testing.expect_value(t, problem, Venus_Problem.Zero_Extent)
	_, problem = reply_stream_init(memory.replies[:6], 1, 0)
	testing.expect_value(t, problem, Venus_Problem.Misaligned_Length)
	_, problem = reply_stream_init(memory.replies[:], 1, 2)
	testing.expect_value(t, problem, Venus_Problem.Misaligned_Length)
	_, problem = reply_stream_init(memory.replies[1:5], 1, 0)
	testing.expect_value(t, problem, Venus_Problem.Ring_Memory_Misaligned)
	_, problem = reply_stream_init(memory.replies[:4], 1, 0)
	testing.expect_value(t, problem, Venus_Problem.None)
}

// The reply decoders on hostile replies: no bytes, a cut word, an unknown
// VkResult, a count past the bound, a name that is not UTF-8.
@(test)
reply_decoders_refuse_hostile_replies :: proc(t: ^testing.T) {
	properties: Physical_Device_Properties
	ids := [2]Object_Id{2, 4}
	empty: []u8
	decoder := decoder_init(empty)
	_, problem := decode_result_reply(&decoder, .Queue_Submit)
	testing.expect_value(t, problem, Venus_Problem.Stream_Truncated)
	_, problem = decode_create_object_reply(&decoder, .Create_Instance, 1)
	testing.expect_value(t, problem, Venus_Problem.Stream_Truncated)
	_, _, problem = decode_enumerate_physical_devices_reply(&decoder, ids[:])
	testing.expect_value(t, problem, Venus_Problem.Stream_Truncated)
	testing.expect_value(t, decode_get_physical_device_properties_reply(&decoder, &properties), Venus_Problem.Stream_Truncated)
	_, problem = decode_allocate_command_buffers_reply(&decoder, ids[:])
	testing.expect_value(t, problem, Venus_Problem.Stream_Truncated)
	_, problem = decode_create_graphics_pipelines_reply(&decoder, ids[:])
	testing.expect_value(t, problem, Venus_Problem.Stream_Truncated)
	testing.expect_value(t, decode_get_device_queue_2_reply(&decoder, 12), Venus_Problem.Stream_Truncated)
	testing.expect_value(t, decoder.cursor, 0)

	// A reply cut inside its last word, and a reply of the wrong command.
	storage: [1024]u8
	encoder := encoder_init(storage[:])
	assert(encode_create_object_reply(&encoder, .Create_Device, .Success, 3) == .None)
	reply := encoder_bytes(&encoder)
	decoder = decoder_init(reply[:len(reply) - 1])
	_, problem = decode_create_object_reply(&decoder, .Create_Device, 3)
	testing.expect_value(t, problem, Venus_Problem.Stream_Truncated)
	testing.expect_value(t, decoder.cursor, 0)
	decoder = decoder_init(reply)
	_, problem = decode_create_object_reply(&decoder, .Create_Buffer, 3)
	testing.expect_value(t, problem, Venus_Problem.Unexpected_Command_Type)
	// A command that has no reply of that form.
	decoder = decoder_init(reply)
	_, problem = decode_result_reply(&decoder, .Create_Device)
	testing.expect_value(t, problem, Venus_Problem.Unexpected_Command_Type)

	// Unknown VkResult words: one past each end of the known results.
	for word in ([]i32{1_000_000, -2_000_000_000, max(i32), min(i32)}) {
		corrupt: [64]u8
		copy(corrupt[:], reply)
		byte_order.write_u32_little_endian(corrupt[:], 4, u32(word))
		decoder = decoder_init(corrupt[:len(reply)])
		_, problem = decode_create_object_reply(&decoder, .Create_Device, 3)
		testing.expect_value(t, problem, Venus_Problem.Unknown_Result)
		result_reply: [8]u8
		byte_order.write_u32_little_endian(result_reply[:], 0, u32(Command_Type.Queue_Submit))
		byte_order.write_u32_little_endian(result_reply[:], 4, u32(word))
		decoder = decoder_init(result_reply[:])
		_, problem = decode_result_reply(&decoder, .Queue_Submit)
		testing.expect_value(t, problem, Venus_Problem.Unknown_Result)
	}

	// A count of physical devices past the bound, and a count that does not
	// match the echoed ids.
	encoder = encoder_init(storage[:])
	assert(encode_enumerate_physical_devices_reply(&encoder, .Success, MAX_ARRAY_ELEMENTS + 1, nil) == .None)
	decoder = decoder_init(encoder_bytes(&encoder))
	_, _, problem = decode_enumerate_physical_devices_reply(&decoder, nil)
	testing.expect_value(t, problem, Venus_Problem.Count_Out_Of_Range)
	testing.expect_value(t, enumerate_physical_devices_reply_bytes(MAX_ARRAY_ELEMENTS + 1), u64(0))
	encoder = encoder_init(storage[:])
	assert(encode_enumerate_physical_devices_reply(&encoder, .Success, 2, ids[:1]) == .None)
	decoder = decoder_init(encoder_bytes(&encoder))
	_, _, problem = decode_enumerate_physical_devices_reply(&decoder, ids[:])
	testing.expect_value(t, problem, Venus_Problem.Array_Size_Mismatch)

	// A device name that is not UTF-8: a cut sequence, a byte that no
	// sequence starts with, an encoded surrogate. The name starts at 40.
	copy(properties.device_name[:], "Venus")
	encoder = encoder_init(storage[:])
	assert(encode_get_physical_device_properties_reply(&encoder, &properties) == .None)
	good := encoder_bytes(&encoder)
	for bad in ([][]u8{{0xC3, 0x28}, {0xFF}, {0xED, 0xA0, 0x80}}) {
		corrupt: [1024]u8
		copy(corrupt[:], good)
		copy(corrupt[40:], bad)
		decoder = decoder_init(corrupt[:len(good)])
		decoded: Physical_Device_Properties
		testing.expect_value(t, decode_get_physical_device_properties_reply(&decoder, &decoded), Venus_Problem.String_Not_Text)
		testing.expect_value(t, decoder.cursor, 0)
	}
	// A name of 255 bytes and its null byte is the longest name.
	for index in 0 ..< PHYSICAL_DEVICE_NAME_BYTES - 1 {
		properties.device_name[index] = 'a'
	}
	encoder = encoder_init(storage[:])
	assert(encode_get_physical_device_properties_reply(&encoder, &properties) == .None)
	decoder = decoder_init(encoder_bytes(&encoder))
	decoded: Physical_Device_Properties
	testing.expect_value(t, decode_get_physical_device_properties_reply(&decoder, &decoded), Venus_Problem.None)
	testing.expect_value(t, len(device_name_text(&decoded)), PHYSICAL_DEVICE_NAME_BYTES - 1)
}
