#+build !freestanding
package gpu_device_service

import "core:testing"
import "modus:contract/byte_order"
import op "modus:contract/operation"
import "modus:pci"
import "modus:contract/venus_vulkan"
import "modus:virtio"

@(test)
venus_cache_map_flags_select_write_combining_and_refuse_none :: proc(t: ^testing.T) {
	flags, ok := venus_map_flags_for_cache(.None)
	testing.expect(t, !ok && flags == {})

	flags, ok = venus_map_flags_for_cache(.Write_Combined)
	testing.expect(t, ok && flags == op.Map_Flags{.Write, .Write_Combining})

	flags, ok = venus_map_flags_for_cache(.Uncached)
	testing.expect(t, ok && flags == op.Map_Flags{.Write})

	flags, ok = venus_map_flags_for_cache(.Cached)
	testing.expect(t, ok && flags == op.Map_Flags{.Write})
}

@(test)
venus_runtime_ring_init_client_submit_notify_and_reply_exchange :: proc(t: ^testing.T) {
	blob := new([VENUS_COMBINED_BLOB_BYTES]u8)
	defer free(blob)
	rt: Venus_Ring_Runtime
	create_cmd: [VENUS_CONTROL_CMD_MAX_BYTES]u8

	// Refusals first: nil runtime, zero resource_id, bad cache, short blob, short cmd buffer.
	_, prob := venus_runtime_init(nil, blob[:], 1, .Write_Combined, VENUS_RING_BUFFER_BYTES, create_cmd[:])
	testing.expect_value(t, prob, venus_vulkan.Venus_Problem.Ring_Memory_Too_Small)

	_, prob = venus_runtime_init(&rt, blob[:], 0, .Write_Combined, VENUS_RING_BUFFER_BYTES, create_cmd[:])
	testing.expect_value(t, prob, venus_vulkan.Venus_Problem.Zero_Object_Id)

	_, prob = venus_runtime_init(&rt, blob[:], 1, .None, VENUS_RING_BUFFER_BYTES, create_cmd[:])
	testing.expect_value(t, prob, venus_vulkan.Venus_Problem.Ring_Status_Invalid)

	_, prob = venus_runtime_init(&rt, blob[:4096], 1, .Write_Combined, VENUS_RING_BUFFER_BYTES, create_cmd[:])
	testing.expect_value(t, prob, venus_vulkan.Venus_Problem.Ring_Memory_Too_Small)

	_, prob = venus_runtime_init(&rt, blob[:], 1, .Write_Combined, VENUS_RING_BUFFER_BYTES, create_cmd[:8])
	testing.expect_value(t, prob, venus_vulkan.Venus_Problem.Buffer_Too_Short)
	testing.expect(t, !rt.active)

	// Valid init builds vkCreateRingMESA and activates live ring + reply stream.
	create_len, init_prob := venus_runtime_init(&rt, blob[:], 7, .Write_Combined, VENUS_RING_BUFFER_BYTES, create_cmd[:])
	testing.expect_value(t, init_prob, venus_vulkan.Venus_Problem.None)
	testing.expect(t, rt.active && create_len > 0)

	dec := venus_vulkan.decoder_init(create_cmd[:create_len])
	decoded, dec_prob := venus_vulkan.command_decode_next(&dec)
	testing.expect_value(t, dec_prob, venus_vulkan.Venus_Problem.None)
	testing.expect_value(t, decoded.command_type, venus_vulkan.Command_Type.Create_Ring)

	// Client stream attempting to send ring-control command is refused at border.
	hostile_buf: [128]u8
	hostile_enc := venus_vulkan.encoder_init(hostile_buf[:])
	testing.expect_value(t, venus_vulkan.encode_notify_ring(&hostile_enc, 1, 1), venus_vulkan.Venus_Problem.None)
	notify_cmd: [VENUS_CONTROL_CMD_MAX_BYTES]u8
	res, _, _, submit_prob := venus_runtime_submit_client(&rt, venus_vulkan.encoder_bytes(&hostile_enc), notify_cmd[:])
	testing.expect_value(t, res, Venus_Ring_Submit_Result.Refused_Client_Stream)
	testing.expect(t, submit_prob != .None)
	testing.expect_value(t, rt.submissions, u64(0))

	// Valid client rendering command writes into live Venus ring.
	client_buf: [256]u8
	client_enc := venus_vulkan.encoder_init(client_buf[:])
	testing.expect_value(t, venus_vulkan.encode_queue_wait_idle(&client_enc, 1, {}), venus_vulkan.Venus_Problem.None)
	client_bytes := venus_vulkan.encoder_bytes(&client_enc)

	reader, reader_prob := venus_vulkan.ring_reader_init(blob[:venus_vulkan.ring_shared_bytes(VENUS_RING_BUFFER_BYTES, 0)], VENUS_RING_BUFFER_BYTES)
	testing.expect_value(t, reader_prob, venus_vulkan.Venus_Problem.None)

	// Renderer idle: submission succeeds AND produces vkNotifyRingMESA.
	venus_vulkan.ring_reader_set_status(&reader, {.Idle, .Alive})
	seqno: u32
	notify_len: int
	res, seqno, notify_len, submit_prob = venus_runtime_submit_client(&rt, client_bytes, notify_cmd[:])
	testing.expect_value(t, submit_prob, venus_vulkan.Venus_Problem.None)
	testing.expect_value(t, res, Venus_Ring_Submit_Result.Submitted_Needs_Notify)
	testing.expect(t, seqno > 0 && notify_len > 0)
	testing.expect_value(t, rt.submissions, u64(1))
	testing.expect_value(t, rt.notifications, u64(1))

	ndec := venus_vulkan.decoder_init(notify_cmd[:notify_len])
	ndecoded, ndec_prob := venus_vulkan.command_decode_next(&ndec)
	testing.expect_value(t, ndec_prob, venus_vulkan.Venus_Problem.None)
	testing.expect_value(t, ndecoded.command_type, venus_vulkan.Command_Type.Notify_Ring)

	// Renderer drains command from ring.
	read_buf: [256]u8
	read_n, read_prob := venus_vulkan.ring_reader_read(&reader, read_buf[:])
	testing.expect_value(t, read_prob, venus_vulkan.Venus_Problem.None)
	testing.expect_value(t, read_n, len(client_bytes))

	// Service command + reply stream exchange round-trip.
	venus_vulkan.ring_reader_set_status(&reader, {.Alive})
	svc_cmd_buf: [256]u8
	svc_enc := venus_vulkan.encoder_init(svc_cmd_buf[:])
	testing.expect_value(t, venus_vulkan.encode_queue_wait_idle(&svc_enc, 1, {.Generate_Reply}), venus_vulkan.Venus_Problem.None)
	svc_cmd := venus_vulkan.encoder_bytes(&svc_enc)
	reply_size := venus_vulkan.result_reply_bytes(.Queue_Wait_Idle)
	staging: [512]u8
	sub, svc_notify_len, sub_prob := venus_runtime_submit_with_reply(&rt, svc_cmd, reply_size, staging[:], notify_cmd[:])
	testing.expect_value(t, sub_prob, venus_vulkan.Venus_Problem.None)
	testing.expect_value(t, svc_notify_len, 0)

	// Before renderer advances head, poll reports not ready.
	reply_copy: [128]u8
	_, ready, poll_prob := venus_runtime_poll_reply(&rt, &sub, reply_copy[:])
	testing.expect_value(t, poll_prob, venus_vulkan.Venus_Problem.None)
	testing.expect(t, !ready)

	// Renderer consumes ring bytes, writes reply into reply stream, and releases head.
	took, take_prob := venus_vulkan.ring_reader_take(&reader, read_buf[:])
	testing.expect_value(t, take_prob, venus_vulkan.Venus_Problem.None)
	testing.expect(t, took > len(svc_cmd))
	reply_enc := venus_vulkan.encoder_init(blob[VENUS_REPLY_STREAM_OFFSET + sub.reply_position:][:sub.reply_bytes])
	testing.expect_value(t, venus_vulkan.encode_result_reply(&reply_enc, .Queue_Wait_Idle, .Success), venus_vulkan.Venus_Problem.None)
	venus_vulkan.ring_reader_release(&reader)

	got_reply, got_ready, got_prob := venus_runtime_poll_reply(&rt, &sub, reply_copy[:])
	testing.expect_value(t, got_prob, venus_vulkan.Venus_Problem.None)
	testing.expect(t, got_ready)
	reply_dec := venus_vulkan.decoder_init(got_reply)
	vk_res, rdec_prob := venus_vulkan.decode_result_reply(&reply_dec, .Queue_Wait_Idle)
	testing.expect_value(t, rdec_prob, venus_vulkan.Venus_Problem.None)
	testing.expect_value(t, vk_res, venus_vulkan.Vulkan_Result.Success)

	// Fatal ring status is latched and refuses subsequent submissions and polls.
	venus_vulkan.ring_reader_set_status(&reader, {.Fatal})
	res, _, _, submit_prob = venus_runtime_submit_client(&rt, client_bytes, notify_cmd[:])
	testing.expect_value(t, res, Venus_Ring_Submit_Result.Refused_Ring_Fatal)
	testing.expect_value(t, submit_prob, venus_vulkan.Venus_Problem.Ring_Fatal)
	testing.expect(t, rt.fatal)

	// Inactive runtime falls back cleanly to SUBMIT_3D for valid client streams.
	inactive: Venus_Ring_Runtime
	res, _, _, submit_prob = venus_runtime_submit_client(&inactive, client_bytes, notify_cmd[:])
	testing.expect_value(t, res, Venus_Ring_Submit_Result.Fallback_To_Submit_3d)
	testing.expect_value(t, submit_prob, venus_vulkan.Venus_Problem.None)
}

@(test)
virtio_shared_memory_place_walks_short_caps_and_refuses_overflow :: proc(t: ^testing.T) {
	cfg: [pci.CONFIGURATION_SIZE]u8
	// Place a short non-SHM capability near the end of config space (0xEC > 256-24)
	// pointing to a valid 24-byte shared memory capability at 0x40.
	cfg[pci.OFFSET_CAPABILITIES] = 0xEC
	cfg[0xEC] = 0x05 // MSI capability
	cfg[0xED] = 0x40 // next capability pointer

	cfg[0x40] = 0x09 // CAPABILITY_VIRTIO
	cfg[0x41] = 0x00
	cfg[0x42] = 24 // SHARED_MEMORY_CAPABILITY_LENGTH
	cfg[0x43] = 8  // CAPABILITY_SHARED_MEMORY
	cfg[0x44] = 4  // BAR 4
	cfg[0x45] = VIRTIO_GPU_SHM_ID_HOST_VISIBLE
	byte_order.write_u32_little_endian(cfg[:], 0x40 + 8, 0x0000_2000)
	byte_order.write_u32_little_endian(cfg[:], 0x40 + 16, 0x0000_0001)
	byte_order.write_u32_little_endian(cfg[:], 0x40 + 12, 0x0010_0000)
	byte_order.write_u32_little_endian(cfg[:], 0x40 + 20, 0x0000_0000)

	bar, place, length, found := virtio.shared_memory_place(cfg[:], VIRTIO_GPU_SHM_ID_HOST_VISIBLE)
	testing.expect(t, found)
	testing.expect_value(t, bar, u8(4))
	testing.expect_value(t, place, u64(0x0000_0001_0000_2000))
	testing.expect_value(t, length, u64(0x0010_0000))

	// Overflowing 64-bit place + length is refused.
	byte_order.write_u32_little_endian(cfg[:], 0x40 + 8, 0xFFFF_F000)
	byte_order.write_u32_little_endian(cfg[:], 0x40 + 16, 0xFFFF_FFFF)
	byte_order.write_u32_little_endian(cfg[:], 0x40 + 12, 0x0000_2000)
	byte_order.write_u32_little_endian(cfg[:], 0x40 + 20, 0x0000_0000)
	_, _, _, found = virtio.shared_memory_place(cfg[:], VIRTIO_GPU_SHM_ID_HOST_VISIBLE)
	testing.expect(t, !found)
}

@(test)
venus_shm_window_and_corrupt_ring_fail_closed :: proc(t: ^testing.T) {
	// Wraparound, misalignment, zero size, and past-end offsets are refused.
	testing.expect(t, !venus_shm_window_valid(max(u64) - 8, 64, 4096))
	testing.expect(t, !venus_shm_window_valid(4, 4096, 65536))
	testing.expect(t, !venus_shm_window_valid(0, 0, 65536))
	testing.expect(t, !venus_shm_window_valid(4096, 4097, 8192))
	testing.expect(t, venus_shm_window_valid(4096, 4096, 8192))

	blob := new([VENUS_COMBINED_BLOB_BYTES]u8)
	defer free(blob)
	rt: Venus_Ring_Runtime
	create_cmd: [VENUS_CONTROL_CMD_MAX_BYTES]u8
	_, init_prob := venus_runtime_init(&rt, blob[:], 3, .Write_Combined, VENUS_RING_BUFFER_BYTES, create_cmd[:])
	testing.expect_value(t, init_prob, venus_vulkan.Venus_Problem.None)

	client_buf: [128]u8
	client_enc := venus_vulkan.encoder_init(client_buf[:])
	testing.expect_value(t, venus_vulkan.encode_queue_wait_idle(&client_enc, 1, {}), venus_vulkan.Venus_Problem.None)
	client_bytes := venus_vulkan.encoder_bytes(&client_enc)

	// Corrupt ring head (unaligned) latches fatal and refuses instead of falling back.
	byte_order.write_u32_little_endian(blob[:], int(venus_vulkan.RING_HEAD_OFFSET), 3)
	notify_cmd: [VENUS_CONTROL_CMD_MAX_BYTES]u8
	res, _, _, prob := venus_runtime_submit_client(&rt, client_bytes, notify_cmd[:])
	testing.expect_value(t, res, Venus_Ring_Submit_Result.Refused_Ring_Fatal)
	testing.expect_value(t, prob, venus_vulkan.Venus_Problem.Ring_Head_Invalid)
	testing.expect(t, rt.fatal)

	// Reinitialize cleanly and verify undersized notify buffer fails closed.
	blob^ = {}
	_, init_prob = venus_runtime_init(&rt, blob[:], 3, .Write_Combined, VENUS_RING_BUFFER_BYTES, create_cmd[:])
	testing.expect_value(t, init_prob, venus_vulkan.Venus_Problem.None)
	reader, rprob := venus_vulkan.ring_reader_init(blob[:venus_vulkan.ring_shared_bytes(VENUS_RING_BUFFER_BYTES, 0)], VENUS_RING_BUFFER_BYTES)
	testing.expect_value(t, rprob, venus_vulkan.Venus_Problem.None)
	venus_vulkan.ring_reader_set_status(&reader, {.Idle, .Alive})

	res, _, _, prob = venus_runtime_submit_client(&rt, client_bytes, notify_cmd[:4])
	testing.expect_value(t, res, Venus_Ring_Submit_Result.Refused_Ring_Fatal)
	testing.expect_value(t, prob, venus_vulkan.Venus_Problem.Buffer_Too_Short)
	testing.expect(t, rt.fatal)
}
