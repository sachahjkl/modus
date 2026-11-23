package compositor

// The screen of memory (src/md/features/screen_of_memory.md): on a machine
// with no screen, the frame is the screen, and a viewer of the remote
// display with the input can ask another size, through the capture face.

import "modus:contract/memory_screen"
import "modus:contract/value_kinds"
import "modus:system"

// The frame is a screen of memory: no framebuffer, no screen page.
screen_of_memory: bool

// The bytes of the cause in the line of a refused size.
RESIZE_REFUSAL_FIELD_BYTES :: 88

// screen_of_memory_resize takes a Screen_Size_Set of the client of the
// capture face. It answers with Capture_Size: the size in force, or the
// size that it asked with the cause of its refusal. A refusal changes
// nothing.
screen_of_memory_resize :: proc "contextless" (client: ^Client, width, height: u64) {
	budget, budget_status := system.budget_read()
	pages_left := budget_status == .Ok ? u64(budget.pages) : 0
	refusal, same := memory_screen.resize_decide(screen_of_memory, width, height, u32(screen.width), u32(screen.height), pages_left)
	if refusal == .None && !same && !screen_of_memory_take(int(width), int(height)) {
		// The kernel had fewer pages than the budget says: the same cause.
		refusal = .Compositor_Budget
	}
	if refusal != .None {
		system.log_fact(.Info, Screen_Of_Memory_Refused{width = width, height = height, resize_refusal = value_kinds.text_field(memory_screen.RESIZE_REFUSAL_SENTENCES[refusal], RESIZE_REFUSAL_FIELD_BYTES)})
		send(client, .Capture_Size, {0 = width, 1 = height, 2 = u64(refusal)})
		return
	}
	send(client, .Capture_Size, {0 = u64(screen.width), 1 = u64(screen.height)})
}

// screen_of_memory_take makes the frame and the background of a new size,
// then frees the old ones, so a refused memory leaves the screen as it
// was. Then the desktop takes the new size: its logical size at the scale
// in force, the background and the bar, the work area and the fit of each
// window, and the whole screen as damage.
@(private = "file")
screen_of_memory_take :: proc "contextless" (width, height: int) -> bool {
	new_frame, new_frame_memory, frame_made := canvas_try_create(width, height)
	if !frame_made {
		return false
	}
	new_background, new_background_memory, background_made := canvas_try_create(width, height)
	if !background_made {
		canvas_free(new_frame, new_frame_memory)
		return false
	}
	// The pictures of the capture face have the old size: the face stops
	// to write them before the frame changes (capture.odin).
	capture_pictures_leave()
	canvas_free(frame, frame_memory_handle)
	canvas_free(background, background_memory_handle)
	frame, frame_memory_handle = new_frame, new_frame_memory
	background, background_memory_handle = new_background, new_background_memory
	screen = {width = width, height = height, stride = width}
	desktop_size_follow_screen(true) // scale.odin
	background_build()
	bar_mark_build()
	bar_layout_update()
	pointer_drawn_valid = false
	pointer_update(0)
	windows := 0
	for &client in clients {
		if client.ring.head == nil || !client.created {
			continue
		}
		work_area_send(&client)
		window_fit_now(&client) // scale.odin
		windows += 1
	}
	damage_whole_screen()
	palette_refresh() // An open panel is measured again for the new desktop.
	system.log_fact(.Info, Screen_Of_Memory_Resized{width = u64(width), height = u64(height), windows = u64(windows)})
	return true
}
