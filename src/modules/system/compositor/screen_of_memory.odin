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
// The extra budgets that the root service gave for sizes larger than the
// start size (src/md/features/screen_of_memory.md, "The growth of the
// budgets"): the one of the size in force, and during a replacement the
// one of the size that replaces it. Each pays the frame and the background
// of its size.
screen_extras: memory_screen.Held_Extras
// The growth of the extra budget that holds the frame and the background
// of the size in force. 0: the budget of this process holds them.
screen_pictures_growth: u64

// screen_budget_take keeps an extra budget that the root service gave. A
// handle that is no budget, a number of 0, or a third one is closed with
// no use: the root service ends it at the stop of this process.
screen_budget_take :: proc "contextless" (budget: system.Handle, pages, width, height, growth: u64) {
	kind, _, _ := system.handle_state(budget)
	if kind != .Budget || !memory_screen.held_extras_take(&screen_extras, {u64(budget), growth, width, height}) {
		if budget != 0 {
			system.close(budget)
		}
		system.log_fact(.Warning, Screen_Budget_Not_Taken{width = width, height = height})
		return
	}
	system.log_fact(.Info, Screen_Budget_Taken{width = width, height = height, pages = value_kinds.Size_In_Pages(pages)})
}


// screen_size_paid_at_start says if the budget of this process pays the
// pictures of a size: at most the start size on each side.
screen_size_paid_at_start :: proc "contextless" (width, height: u64) -> bool {
	return width <= u64(screen_start_width) && height <= u64(screen_start_height)
}

// screen_budgets_give_back closes each extra budget that holds no picture,
// after each answer to a size: the old one of a replacement, or the new one
// of a size that was refused or never sent. It tells the root service the
// number of each, and the root service closes its own handle: the pages
// return.
@(private = "file")
screen_budgets_give_back :: proc "contextless" () {
	for extra in memory_screen.held_extras_give_back(&screen_extras, screen_pictures_growth) {
		if extra.handle == 0 {
			continue
		}
		system.close(system.Handle(extra.handle))
		if !system.send(&control.completions, ring.Record{kind = u32(display.Control.Screen_Budget_Release), values = {0 = extra.growth}}) {
			// The root service ends the budget at the stop of this process.
			system.log_fact(.Warning, Screen_Budget_Release_Not_Sent{})
		}
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
	// larger one from the extra budget of that size, with none no page.
	paid_at_start := screen_size_paid_at_start(width, height)
	paying, paying_known := memory_screen.held_extras_of_size(&screen_extras, width, height)
	pages_left: u64
	if paid_at_start || paying_known {
		if paid_at_start {
			paying = {}
		}
		if budget, budget_status := system.budget_read(system.Handle(paying.handle)); budget_status == .Ok {
			pages_left = u64(budget.pages)
		}
	}
	refusal, same := memory_screen.resize_decide(screen_of_memory, width, height, u32(screen.width), u32(screen.height), pages_left)
	if refusal == .None && !same {
		if windows, taken := screen_of_memory_take(int(width), int(height), paying); taken {
			system.log_fact(.Info, Screen_Of_Memory_Resized{width = width, height = height, windows = u64(windows)})
		} else {
			// The kernel had fewer pages than the budget says: the same cause.
			refusal = .Compositor_Budget
		}
	}
	screen_budgets_give_back()
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
screen_of_memory_take :: proc "contextless" (width, height: int, paying: memory_screen.Held_Extra) -> (windows: int, ok: bool) {
	new_frame, new_frame_memory, frame_made := canvas_try_create(width, height, system.Handle(paying.handle))
	if !frame_made {
		return 0, false
	}
	new_background, new_background_memory, background_made := canvas_try_create(width, height, system.Handle(paying.handle))
	if !background_made {
		canvas_free(new_frame, new_frame_memory)
		return 0, false
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
	// back after the answer (screen_budgets_give_back).
	screen_pictures_growth = paying.growth
	desktop_size_follow_screen(true) // scale.odin
	background_build()
	bar_mark_build()
	bar_layout_update()
	pointer_drawn_valid = false
	pointer_update(0)
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
	return windows, true
}

// screen_of_memory_face_ended runs when the capture face ends: the service
// closed it as its last viewer left, or the service stopped. No viewer
// looks, so a machine with no viewer pays only its start size: a grown
// screen goes back to the start size, from the budget of this process, and
// each extra budget goes back, also the new one of a growth whose size was
// never sent (src/md/features/screen_of_memory.md, "The growth of the
// budgets"). The next face asks the size and gets the start size.
screen_of_memory_face_ended :: proc "contextless" () {
	if memory_screen.face_ended_goes_to_start(screen_of_memory, screen_pictures_growth) {
		if windows, taken := screen_of_memory_take(screen_start_width, screen_start_height, {}); taken {
			system.log_fact(.Info, Screen_Of_Memory_Back_To_Start{width = u64(screen_start_width), height = u64(screen_start_height), windows = u64(windows)})
		} else {
			// The pictures stay in their extra budget, which stays too: the
			// next answer to a size gives it back.
			system.log_fact(.Warning, Screen_Of_Memory_Not_Back_To_Start{width = u64(screen_start_width), height = u64(screen_start_height)})
		}
	}
	screen_budgets_give_back()
}
