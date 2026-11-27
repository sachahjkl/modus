// Live Venus Vulkan command-ring and reply-stream runtime for gpu_device
// (src/md/features/gpu_access.md).
//
// Maps the VirtIO-GPU host-visible shared memory blob using kernel
// Write_Combining when reported by RESOURCE_MAP_BLOB, initializes the Mesa
// Venus Ring and Reply_Stream in place, emits vkCreateRingMESA and
// vkNotifyRingMESA control streams for SUBMIT_3D, and drives validated client
// stream submission and reply exchange without heap allocation.
package gpu_device_service

import op "modus:contract/operation"
import "modus:contract/venus_vulkan"
import "modus:contract/virtio_gpu"
import "modus:system"

// Format property: VIRTIO_GPU_SHM_ID_HOST_VISIBLE in virtio_gpu.h.
VIRTIO_GPU_SHM_ID_HOST_VISIBLE :: u8(1)

// Plan value: Venus ring object identifier registered with vkCreateRingMESA.
VENUS_RING_OBJECT_ID :: u64(1)

// Plan value: idle timeout advertised to the host Venus renderer (10 ms).
VENUS_RING_IDLE_TIMEOUT_NS :: u64(10_000_000)

// Plan value: reply stream size in bytes placed after the command ring inside
// the host-visible blob resource (4 pages = 16 KiB).
VENUS_REPLY_STREAM_BYTES :: u64(16 * 1024)

// Computed: page-aligned byte offset of the reply stream after the command ring.
VENUS_REPLY_STREAM_OFFSET :: (u64(venus_vulkan.RING_BUFFER_OFFSET) + u64(VENUS_RING_BUFFER_BYTES) + system.PAGE_SIZE - 1) / system.PAGE_SIZE * system.PAGE_SIZE

// Computed: total host-visible blob size holding both command ring and reply stream.
VENUS_COMBINED_BLOB_BYTES :: VENUS_REPLY_STREAM_OFFSET + VENUS_REPLY_STREAM_BYTES

// Format property: maximum bytes of one encoded vkCreateRingMESA or vkNotifyRingMESA command.
VENUS_CONTROL_CMD_MAX_BYTES :: 128

// Closed set of outcomes when submitting a client Venus stream through the live ring.
Venus_Ring_Submit_Result :: enum u8 {
	Submitted               = 1,
	Submitted_Needs_Notify  = 2,
	Fallback_To_Submit_3d   = 3,
	Refused_Client_Stream   = 4,
	Refused_Ring_Fatal      = 5,
}

// Live state of the GPU device service's Venus ring and reply stream inside
// the mapped host-visible blob region.
Venus_Ring_Runtime :: struct {
	active:          bool,
	fatal:           bool,
	ring_id:         u64,
	resource_id:     u32,
	cache:           virtio_gpu.Map_Cache,
	ring:            venus_vulkan.Ring,
	reply_stream:    venus_vulkan.Reply_Stream,
	submissions:     u64,
	notifications:   u64,
	last_seqno:      u32,
}

// venus_shm_window_valid checks that the host-visible blob window lies
// strictly inside bar_bytes without u64 wraparound and is 8-byte aligned for
// atomic ring control words.
venus_shm_window_valid :: proc "contextless" (shm_offset, blob_bytes, bar_bytes: u64) -> bool {
	if blob_bytes == 0 || (shm_offset & 7) != 0 {
		return false
	}
	return shm_offset <= bar_bytes && blob_bytes <= bar_bytes - shm_offset
}

// venus_map_flags_for_cache converts a RESOURCE_MAP_BLOB Map_Cache enum into
// kernel Memory_Map flags, using Write_Combining when the device requests it
// and refusing Map_Cache.None or unknown values.
venus_map_flags_for_cache :: proc "contextless" (cache: virtio_gpu.Map_Cache) -> (flags: op.Map_Flags, ok: bool) {
	switch cache {
	case .None:
		return {}, false
	case .Cached, .Uncached:
		return {.Write}, true
	case .Write_Combined:
		return {.Write, .Write_Combining}, true
	}
	return {}, false
}

// venus_runtime_init partitions the mapped host-visible blob into the Venus
// command ring and reply stream, initializes both, and writes the encoded
// vkCreateRingMESA command into create_cmd_out for submission via SUBMIT_3D.
venus_runtime_init :: proc "contextless" (
	rt: ^Venus_Ring_Runtime,
	blob_shared: []u8,
	resource_id: u32,
	cache: virtio_gpu.Map_Cache,
	ring_buffer_bytes: u32,
	create_cmd_out: []u8,
) -> (create_cmd_len: int, problem: venus_vulkan.Venus_Problem) {
	if rt == nil {
		return 0, .Ring_Memory_Too_Small
	}
	rt^ = {}
	if resource_id == 0 {
		return 0, .Zero_Object_Id
	}
	if _, cache_ok := venus_map_flags_for_cache(cache); !cache_ok {
		return 0, .Ring_Status_Invalid
	}
	ring_bytes := venus_vulkan.ring_shared_bytes(ring_buffer_bytes, 0)
	reply_offset := (ring_bytes + system.PAGE_SIZE - 1) / system.PAGE_SIZE * system.PAGE_SIZE
	if u64(len(blob_shared)) < reply_offset + 4096 {
		return 0, .Ring_Memory_Too_Small
	}
	ring, ring_prob := venus_vulkan.ring_init(blob_shared[:ring_bytes], ring_buffer_bytes, 0)
	if ring_prob != .None {
		return 0, ring_prob
	}
	reply_len := u64(len(blob_shared)) - reply_offset
	reply_len = reply_len &~ u64(3)
	reply_stream, reply_prob := venus_vulkan.reply_stream_init(blob_shared[reply_offset:][:reply_len], resource_id, reply_offset)
	if reply_prob != .None {
		return 0, reply_prob
	}

	info := venus_vulkan.ring_create_info(&ring, resource_id, 0, VENUS_RING_IDLE_TIMEOUT_NS)
	enc := venus_vulkan.encoder_init(create_cmd_out)
	if enc_prob := venus_vulkan.encode_create_ring(&enc, VENUS_RING_OBJECT_ID, info); enc_prob != .None {
		return 0, enc_prob
	}

	rt.active = true
	rt.ring_id = VENUS_RING_OBJECT_ID
	rt.resource_id = resource_id
	rt.cache = cache
	rt.ring = ring
	rt.reply_stream = reply_stream
	return len(venus_vulkan.encoder_bytes(&enc)), .None
}

// venus_runtime_submit_client validates a copied client Venus stream via
// stream_validate_client and writes it into the live Venus command ring.
// If the host renderer has set Ring_Status_Flag.Idle, encodes vkNotifyRingMESA
// into notify_cmd_out so the caller wakes the renderer via SUBMIT_3D.
venus_runtime_submit_client :: proc "contextless" (
	rt: ^Venus_Ring_Runtime,
	client_payload: []u8,
	notify_cmd_out: []u8,
) -> (result: Venus_Ring_Submit_Result, seqno: u32, notify_len: int, problem: venus_vulkan.Venus_Problem) {
	if _, validate_prob := venus_vulkan.stream_validate_client(client_payload); validate_prob != .None {
		return .Refused_Client_Stream, 0, 0, validate_prob
	}
	if rt == nil || !rt.active {
		return .Fallback_To_Submit_3d, 0, 0, .None
	}
	if rt.fatal {
		return .Refused_Ring_Fatal, 0, 0, .Ring_Fatal
	}
	written_seqno, write_prob := venus_vulkan.ring_write(&rt.ring, client_payload)
	if write_prob == .Ring_Fatal || write_prob == .Ring_Head_Invalid || write_prob == .Ring_Status_Invalid {
		rt.fatal = true
		return .Refused_Ring_Fatal, 0, 0, write_prob
	}
	if write_prob == .Ring_Full || write_prob == .Stream_Too_Large {
		return .Fallback_To_Submit_3d, 0, 0, write_prob
	}
	if write_prob != .None {
		rt.fatal = true
		return .Refused_Ring_Fatal, 0, 0, write_prob
	}
	rt.submissions += 1
	rt.last_seqno = written_seqno

	needs_notify, status_prob := venus_vulkan.ring_needs_notify(&rt.ring)
	if status_prob != .None {
		rt.fatal = true
		return .Refused_Ring_Fatal, 0, 0, status_prob
	}
	if needs_notify {
		enc := venus_vulkan.encoder_init(notify_cmd_out)
		if enc_prob := venus_vulkan.encode_notify_ring(&enc, rt.ring_id, written_seqno); enc_prob != .None {
			rt.fatal = true
			return .Refused_Ring_Fatal, 0, 0, enc_prob
		}
		rt.notifications += 1
		return .Submitted_Needs_Notify, written_seqno, len(venus_vulkan.encoder_bytes(&enc)), .None
	}
	return .Submitted, written_seqno, 0, .None
}

// venus_runtime_submit_with_reply submits one service-owned Venus command
// expecting a reply into the ring and reply stream, and encodes
// vkNotifyRingMESA when the renderer is idle.
venus_runtime_submit_with_reply :: proc "contextless" (
	rt: ^Venus_Ring_Runtime,
	command: []u8,
	reply_bytes: u64,
	staging: []u8,
	notify_cmd_out: []u8,
) -> (submission: venus_vulkan.Ring_Submission, notify_len: int, problem: venus_vulkan.Venus_Problem) {
	if rt == nil || !rt.active {
		return {}, 0, .Ring_Memory_Too_Small
	}
	if rt.fatal {
		return {}, 0, .Ring_Fatal
	}
	sub, sub_prob := venus_vulkan.venus_ring_submit_command(&rt.ring, &rt.reply_stream, command, reply_bytes, staging)
	if sub_prob == .Ring_Fatal || sub_prob == .Ring_Head_Invalid || sub_prob == .Ring_Status_Invalid {
		rt.fatal = true
	}
	if sub_prob != .None {
		return {}, 0, sub_prob
	}
	rt.submissions += 1
	rt.last_seqno = sub.seqno
	needs_notify, status_prob := venus_vulkan.ring_needs_notify(&rt.ring)
	if status_prob != .None {
		rt.fatal = true
		return {}, 0, status_prob
	}
	if needs_notify {
		enc := venus_vulkan.encoder_init(notify_cmd_out)
		if enc_prob := venus_vulkan.encode_notify_ring(&enc, rt.ring_id, sub.seqno); enc_prob != .None {
			rt.fatal = true
			return {}, 0, enc_prob
		}
		rt.notifications += 1
		notify_len = len(venus_vulkan.encoder_bytes(&enc))
	}
	return sub, notify_len, .None
}

// venus_runtime_poll_reply polls the live reply stream for a submitted
// service command, copying the completed reply bytes out of shared memory.
venus_runtime_poll_reply :: proc "contextless" (
	rt: ^Venus_Ring_Runtime,
	submission: ^venus_vulkan.Ring_Submission,
	destination: []u8,
) -> (reply: []u8, ready: bool, problem: venus_vulkan.Venus_Problem) {
	if rt == nil || !rt.active {
		return nil, false, .Ring_Memory_Too_Small
	}
	if rt.fatal {
		return nil, false, .Ring_Fatal
	}
	reply, ready, problem = venus_vulkan.venus_ring_poll_reply(&rt.ring, &rt.reply_stream, submission, destination)
	if problem == .Ring_Fatal {
		rt.fatal = true
	}
	return reply, ready, problem
}
