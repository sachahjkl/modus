package compositor

// The screen of memory (src/md/features/screen_of_memory.md): on a machine
// with no screen, the frame is the screen, and a viewer of the remote
// display with the input can ask another size, through the capture face.

import "modus:contract/memory_screen"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:system"

// The frame is a screen of memory: no framebuffer, no screen page.
screen_of_memory: bool
// The size of the screen of memory at the start: the budget of this
// process pays its frame and its background at this size and below.
screen_start_width, screen_start_height: int
// The extra budget that the root service gave for a larger size
// (src/md/features/screen_of_memory.md, "The growth of the budgets"), and
// whether the frame and the background of the size in force are its
// objects. 0: none.
screen_extra_budget: system.Handle
screen_pictures_in_extra: bool

// screen_budget_take keeps the extra budget that the root service gave. A
// second one while one is held is closed with no use: the root service
// gives one at a time.
screen_budget_take :: proc "contextless" (budget: system.Handle, pages, width, height: u64) {
	kind, _, _ := system.handle_state(budget)
	if kind != .Budget || screen_extra_budget != 0 {
		if budget != 0 {
			system.close(budget)
		}
		system.log_fact(.Warning, Screen_Budget_Not_Taken{width = width, height = height})
		return
	}
	screen_extra_budget = budget
	system.log_fact(.Info, Screen_Budget_Taken{width = width, height = height, pages = value_kinds.Size_In_Pages(pages)})
}

// screen_size_paid_at_start says if the budget of this process pays the
// pictures of a size: at most the start size on each side.
screen_size_paid_at_start :: proc "contextless" (width, height: u64) -> bool {
	return width <= u64(screen_start_width) && height <= u64(screen_start_height)
}

// screen_budget_give_back closes the extra budget when no picture of it is
// left, and tells the root service, which closes its own handle: the pages
// return.
@(private = "file")
screen_budget_give_back :: proc "contextless" () {
	if screen_extra_budget == 0 || screen_pictures_in_extra {
		return
	}
	system.close(screen_extra_budget)
	screen_extra_budget = 0
	if !system.send(&control.completions, ring.Record{kind = u32(display.Control.Screen_Budget_Release)}) {
		// The root service ends the budget at the stop of this process.
		system.log_fact(.Warning, Screen_Budget_Release_Not_Sent{})
	}
}

// The bytes of the cause in the line of a refused size.
RESIZE_REFUSAL_FIELD_BYTES :: 88

// screen_of_memory_resize takes a Screen_Size_Set of the client of the
// capture face. It answers with Capture_Size: the size in force, or the
// size that it asked with the cause of its refusal. A refusal changes
// nothing.
screen_of_memory_resize :: proc "contextless" (client: ^Client, width, height: u64) {
	// A size that the start paid comes from the budget of this process; a
	// larger one from the extra budget, with no extra budget no page.
	paying: system.Handle
	if !screen_size_paid_at_start(width, height) {
		paying = screen_extra_budget
	}
	pages_left: u64
	if paying != 0 || screen_size_paid_at_start(width, height) {
		if budget, budget_status := system.budget_read(paying); budget_status == .Ok {
			pages_left = u64(budget.pages)
		}
	}
	refusal, same := memory_screen.resize_decide(screen_of_memory, width, height, u32(screen.width), u32(screen.height), pages_left)
	if refusal == .None && !same && !screen_of_memory_take(int(width), int(height), paying) {
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
screen_of_memory_take :: proc "contextless" (width, height: int, paying: system.Handle) -> bool {
	new_frame, new_frame_memory, frame_made := canvas_try_create(width, height, paying)
	if !frame_made {
		return false
	}
	new_background, new_background_memory, background_made := canvas_try_create(width, height, paying)
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
	// The old pictures are gone: an extra budget with none of them left goes
	// back to the root service.
	screen_pictures_in_extra = paying != 0
	screen_budget_give_back()
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
