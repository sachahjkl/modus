// Live VirtIO-GPU 1.2 client ring bridge inside the compositor
// (src/md/features/gpu_access.md).
//
// When root discovered a VirtIO-GPU PCI device (0x1AF4:0x1050) and started
// gpu_device, it passes the client ring at GRANT_GPU_RING. The compositor
// queries Display_Info and Venus_Info at startup, attaches its framebuffer
// memory via Attach_Framebuffer, and flushes damaged rectangles via
// Present_Rect inside screen_put. When no VirtIO-GPU is present (handle 0),
// every procedure is a zero-cost no-op.
package compositor

import "modus:contract/ring"
import "modus:contract/virtio_gpu"
import "modus:system"

GRANT_GPU_RING :: 4

gpu_ring_memory: system.Handle
gpu_ring: ring.Ring
gpu_present: bool
gpu_attached: bool
gpu_width: u32
gpu_height: u32
gpu_venus_available: bool
gpu_venus_max_version: u32
gpu_presents: u64
gpu_tag: u32 = 1

@(private = "file")
gpu_call :: proc "contextless" (cmd: virtio_gpu.Service_Command, values: [7]u64 = {}) -> (reply: ring.Record, ok: bool) {
	if !gpu_present {
		return {}, false
	}
	tag := gpu_tag
	gpu_tag += 1
	if !system.send(&gpu_ring.commands, ring.Record{kind = u32(cmd), tag = tag, values = values}) {
		return {}, false
	}
	deadline := system.time() + 500
	for {
		if rec, got := system.receive(&gpu_ring.completions); got {
			if rec.tag == tag {
				return rec, rec.kind == u32(virtio_gpu.Service_Status.Ok)
			}
			continue
		}
		if system.time() >= deadline {
			gpu_present = false
			gpu_attached = false
			return {}, false
		}
		wait := system.wait_begin()
		system.wait_records(&wait, &gpu_ring.completions)
		system.wait_end(&wait, deadline)
	}
}

// gpu_scanout_open probes Display_Info and Venus capabilities on the optional
// VirtIO-GPU client ring handed by root, and attaches frame_memory when available.
gpu_scanout_open :: proc "contextless" (ctx: ^system.Context, frame_memory: system.Handle, width, height: int) {
	handle := ctx.handles[GRANT_GPU_RING]
	if handle == 0 {
		return
	}
	r, status := system.ring_open(handle)
	if status != .Ok {
		return
	}
	gpu_ring_memory = handle
	gpu_ring = r
	gpu_present = true

	if reply, ok := gpu_call(.Display_Info); ok {
		gpu_width = u32(reply.values[0])
		gpu_height = u32(reply.values[1])
	} else {
		return
	}
	if reply, ok := gpu_call(.Venus_Info); ok {
		gpu_venus_available = reply.values[0] != 0
		gpu_venus_max_version = u32(reply.values[1])
	}
	if frame_memory != 0 && width > 0 && height > 0 {
		if lent, lend_status := system.give(gpu_ring_memory, frame_memory, {.Read}); lend_status == .Ok {
			if _, ok := gpu_call(.Attach_Framebuffer, {0 = u64(lent), 1 = u64(width), 2 = u64(height), 3 = u64(virtio_gpu.Pixel_Format.B8G8R8X8_Unorm)}); ok {
				gpu_attached = true
			}
		}
	}
}

// gpu_scanout_present flushes damaged screen rectangles to the host VirtIO-GPU.
gpu_scanout_present :: proc "contextless" (areas: []Rectangle) {
	if !gpu_attached || len(areas) == 0 {
		return
	}
	for area in areas {
		w := area.right - area.left
		h := area.bottom - area.top
		if w <= 0 || h <= 0 || area.left < 0 || area.top < 0 {
			continue
		}
		if _, ok := gpu_call(.Present_Rect, {0 = u64(area.left), 1 = u64(area.top), 2 = u64(w), 3 = u64(h)}); ok {
			gpu_presents += 1
		}
	}
}
