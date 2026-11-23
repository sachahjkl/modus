// The screen through the scanout of the virtual GPU
// (src/md/infrastructure/whole_frame.md, "The screen through the scanout of
// the virtual GPU", and src/md/features/gpu_access.md).
//
// When the root service started gpu_device, it passes its client ring at
// GRANT_GPU_RING. The compositor then creates its screen memory (the pixels
// of the screen and one page for the present list), gives it to the service
// as the backing of the one resource of the scanout, and puts each frame on
// the screen with one Present_Frame: the damage rectangles of the frame,
// which the service gives the device in one batch. The compositor writes
// the screen memory only when no present is in flight: the damage of the
// frames in between waits and goes with the next present. It never waits
// for an answer in its loop.
package compositor

import "modus:contract/ring"
import "modus:contract/virtio_gpu"
import "modus:graphics"
import "modus:interface"
import "modus:system"

GRANT_GPU_RING :: 4

gpu_ring_memory: system.Handle
gpu_ring: ring.Ring
gpu_present: bool // The ring of gpu_device answered at the start.
gpu_attached: bool // The screen is the scanout: each frame goes through it.
gpu_width: u32
gpu_height: u32
gpu_venus_available: bool
gpu_venus_max_version: u32
gpu_tag: u32 = 1

// The screen memory: the pixels that the device reads, and the present list.
gpu_screen: graphics.Canvas
gpu_screen_list: []u8

// The present in flight, and the damage that waits for its answer.
gpu_in_flight: bool
gpu_in_flight_tag: u32
gpu_in_flight_since: u64 // The time of the system when it was sent.
gpu_waiting: interface.Damage
gpu_presents: u64 // The frames that the scanout showed: the service answered each.
gpu_frames_merged: u64 // The frames whose damage waited for an answer, and went with a later present.

// gpu_call_at_start sends one command and waits for its answer, up to the
// answer bound: the start of the compositor only, before its loop.
@(private = "file")
gpu_call_at_start :: proc "contextless" (cmd: virtio_gpu.Service_Command, values: [7]u64 = {}) -> (reply: ring.Record, ok: bool) {
	tag := gpu_tag
	gpu_tag += 1
	if !system.send(&gpu_ring.commands, ring.Record{kind = u32(cmd), tag = tag, values = values}) {
		return {}, false
	}
	deadline := system.time() + system.ANSWER_BOUND_MILLISECONDS
	for {
		wait := system.wait_begin()
		if record, got := system.receive(&gpu_ring.completions); got {
			if record.tag == tag {
				return record, record.kind == u32(virtio_gpu.Service_Status.Ok)
			}
			continue
		}
		if system.time() >= deadline {
			return {}, false
		}
		system.wait_records(&wait, &gpu_ring.completions)
		system.wait_end(&wait, deadline)
	}
}

// gpu_scanout_open asks the service for its display and its Venus state,
// then creates the screen memory and gives it as the backing of the
// scanout. On success each frame goes through the scanout from now on, and
// the first frame is the whole screen; else the screen pages stay.
gpu_scanout_open :: proc "contextless" (ctx: ^system.Context, width, height: int) {
	handle := ctx.handles[GRANT_GPU_RING]
	if handle == 0 {
		return
	}
	opened, status := system.ring_open(handle)
	if status != .Ok {
		return
	}
	gpu_ring_memory = handle
	gpu_ring = opened
	reply, ok := gpu_call_at_start(.Display_Info)
	if !ok {
		system.log_fact(.Info, Gpu_Scanout_Not_Taken{status = u64(reply.kind)})
		return
	}
	gpu_present = true
	gpu_width = u32(reply.values[0])
	gpu_height = u32(reply.values[1])
	if venus, venus_ok := gpu_call_at_start(.Venus_Info); venus_ok {
		gpu_venus_available = venus.values[0] != 0
		gpu_venus_max_version = u32(venus.values[1])
	}
	if width <= 0 || height <= 0 {
		system.log_fact(.Info, Gpu_Scanout_Not_Taken{status = u64(virtio_gpu.Service_Status.Bad_Command)})
		return
	}
	bytes, bytes_ok := virtio_gpu.framebuffer_bytes_with_list(u32(width), u32(height))
	list_offset, offset_ok := virtio_gpu.present_list_offset(u32(width), u32(height))
	if !bytes_ok || !offset_ok {
		system.log_fact(.Info, Gpu_Scanout_Not_Taken{status = u64(virtio_gpu.Service_Status.Out_Of_Range)})
		return
	}
	// Contiguous: the device reads the pixels through one backing entry.
	memory, create_status := system.memory_create((bytes + system.PAGE_SIZE - 1) / system.PAGE_SIZE, 0, {.Contiguous})
	if create_status != .Ok {
		system.log_fact(.Info, Gpu_Scanout_Not_Taken{status = u64(create_status)})
		return
	}
	address, map_status := system.memory_map(memory, {.Write})
	if map_status != .Ok {
		system.close(memory)
		system.log_fact(.Info, Gpu_Scanout_Not_Taken{status = u64(map_status)})
		return
	}
	lent, lend_status := system.give(gpu_ring_memory, memory, {.Read})
	system.close(memory) // The mapping and the handle of the service keep it.
	if lend_status != .Ok {
		system.memory_unmap(address)
		system.log_fact(.Info, Gpu_Scanout_Not_Taken{status = u64(lend_status)})
		return
	}
	attached, attached_ok := gpu_call_at_start(.Attach_Framebuffer, {0 = u64(lent), 1 = u64(width), 2 = u64(height), 3 = u64(virtio_gpu.Pixel_Format.B8G8R8X8_Unorm)})
	if !attached_ok {
		system.memory_unmap(address)
		system.log_fact(.Info, Gpu_Scanout_Not_Taken{status = u64(attached.kind)})
		return
	}
	gpu_screen = {pixels = ([^]graphics.Color)(address), width = width, height = height, stride = width}
	gpu_screen_list = ([^]u8)(uintptr(address) + uintptr(list_offset))[:virtio_gpu.PRESENT_LIST_PAGE_BYTES]
	gpu_attached = true
	system.log_fact(.Info, Screen_Is_Gpu_Scanout{width = u64(width), height = u64(height), resource_id = attached.values[0]})
}

// gpu_scanout_put puts the damage of a frame on the screen: at once when no
// present is in flight, else with the next present.
gpu_scanout_put :: proc "contextless" (areas: []Rectangle) {
	for area in areas {
		interface.damage_add(&gpu_waiting, {area.left, area.top, area.right, area.bottom})
	}
	if gpu_in_flight {
		gpu_frames_merged += 1
		return
	}
	gpu_present_send(true)
}

// gpu_present_send copies the damage that waits into the screen memory,
// writes its list, and sends one Present_Frame. The device reads the
// screen memory until the answer, so nothing writes it while a present is
// in flight. in_draw is true when called inside draw_areas.
@(private = "file")
gpu_present_send :: proc "contextless" (in_draw: bool) {
	if gpu_waiting.count == 0 {
		return
	}
	rectangles: [virtio_gpu.PRESENT_RECTANGLE_CAPACITY]virtio_gpu.Rect
	count := 0
	for rectangle in gpu_waiting.rectangles[:gpu_waiting.count] {
		left, top := max(rectangle.left, 0), max(rectangle.top, 0)
		right, bottom := min(rectangle.right, gpu_screen.width), min(rectangle.bottom, gpu_screen.height)
		if right <= left || bottom <= top {
			continue
		}
		screen_copy(gpu_screen, {left, top, right, bottom}, false)
		rectangles[count] = {x = u32(left), y = u32(top), width = u32(right - left), height = u32(bottom - top)}
		count += 1
	}
	gpu_waiting = {}
	if count == 0 {
		return
	}
	if virtio_gpu.present_list_encode(gpu_screen_list, rectangles[:count], u32(gpu_screen.width), u32(gpu_screen.height)) != .None {
		gpu_scanout_end(u64(virtio_gpu.Service_Status.Bad_Command), in_draw)
		return
	}
	tag := gpu_tag
	gpu_tag += 1
	if !system.send(&gpu_ring.commands, ring.Record{kind = u32(virtio_gpu.Service_Command.Present_Frame), tag = tag, values = {0 = u64(count)}}) {
		// The ring of a service that never takes its records: the screen
		// pages take the frames.
		gpu_scanout_end(u64(virtio_gpu.Service_Status.Device_Error), in_draw)
		return
	}
	gpu_in_flight = true
	gpu_in_flight_tag = tag
	gpu_in_flight_since = system.time()
}

// gpu_scanout_poll takes the answer of the present in flight, then sends
// the damage that waited. A refusal, or no answer in the answer bound, ends
// the scanout.
gpu_scanout_poll :: proc "contextless" (now: u64) {
	if !gpu_attached {
		return
	}
	for record in system.receive(&gpu_ring.completions) {
		if !gpu_in_flight || record.tag != gpu_in_flight_tag {
			continue
		}
		gpu_in_flight = false
		if record.kind != u32(virtio_gpu.Service_Status.Ok) {
			gpu_scanout_end(u64(record.kind), false)
			return
		}
		gpu_presents = record.values[0]
	}
	if gpu_in_flight && now - gpu_in_flight_since >= system.ANSWER_BOUND_MILLISECONDS {
		gpu_scanout_end(u64(virtio_gpu.Service_Status.Device_Error), false)
		return
	}
	if !gpu_in_flight {
		gpu_present_send(false)
	}
}

// gpu_scanout_wait adds the answer of the present in flight to the wait of
// the loop, and its bound to the deadline.
gpu_scanout_wait :: proc "contextless" (wait: ^system.Wait, deadline: u64) -> u64 {
	if !gpu_attached || !gpu_in_flight {
		return deadline
	}
	system.wait_records(wait, &gpu_ring.completions)
	return min(deadline, gpu_in_flight_since + system.ANSWER_BOUND_MILLISECONDS)
}

// gpu_scanout_end writes why the scanout ended, releases the screen memory
// mapping and ring, and puts the screen on the fallback screen pages. Inside
// draw_areas (in_draw), draw() clears damage immediately after draw_areas
// returns, so the whole frame goes straight to screen_put without mutating
// damage; outside draw_areas, damage_whole_screen schedules a full redraw.
@(private = "file")
gpu_scanout_end :: proc "contextless" (status: u64, in_draw: bool) {
	system.log_fact(.Info, Gpu_Present_Refused{status = status, presents = gpu_presents})
	gpu_attached = false
	gpu_in_flight = false
	gpu_waiting = {}
	if gpu_screen.pixels != nil {
		system.memory_unmap(gpu_screen.pixels)
		gpu_screen = {}
		gpu_screen_list = nil
	}
	system.ring_close(&gpu_ring)
	if gpu_ring_memory != 0 {
		system.close(gpu_ring_memory)
		gpu_ring_memory = 0
	}
	if in_draw {
		whole := [1]Rectangle{{0, 0, screen.width, screen.height}}
		screen_put(whole[:])
	} else {
		damage_whole_screen()
	}
}
