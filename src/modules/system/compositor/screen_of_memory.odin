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
// An extra budget that the root service gave for a size larger than the
// start size (src/md/features/screen_of_memory.md, "The growth of the
// budgets"): it pays the frame and the background of that size. A handle of
// 0 is none.
Screen_Extra :: struct {
	handle:        system.Handle,
	growth:        u64, // The number of its growth, which names it in a release.
	width, height: u64,
}

// The extra budgets held: the one of the size in force, and during a
// replacement the one of the size that replaces it.
screen_extras: [memory_screen.EXTRAS_PER_PROCESS]Screen_Extra
// The growth of the extra budget that holds the frame and the background
// of the size in force. 0: the budget of this process holds them.
screen_pictures_growth: u64

// screen_budget_take keeps an extra budget that the root service gave. A
// handle that is no budget, a number of 0, or a third one is closed with
// no use: the root service ends it at the stop of this process.
screen_budget_take :: proc "contextless" (budget: system.Handle, pages, width, height, growth: u64) {
	kind, _, _ := system.handle_state(budget)
	free := -1
	for extra, place in screen_extras {
		if extra.handle == 0 {
			free = place
		}
	}
	if kind != .Budget || growth == 0 || free < 0 {
		if budget != 0 {
			system.close(budget)
		}
		system.log_fact(.Warning, Screen_Budget_Not_Taken{width = width, height = height})
		return
	}
	screen_extras[free] = {budget, growth, width, height}
	system.log_fact(.Info, Screen_Budget_Taken{width = width, height = height, pages = value_kinds.Size_In_Pages(pages)})
}

// screen_extra_of_size gives the newest extra budget of a size. ok false:
// none pays it.
@(private = "file")
screen_extra_of_size :: proc "contextless" (width, height: u64) -> (extra: Screen_Extra, ok: bool) {
	for held in screen_extras {
		if held.handle != 0 && held.width == width && held.height == height && held.growth > extra.growth {
			extra, ok = held, true
		}
	}
	return
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
	for &extra in screen_extras {
		if extra.handle == 0 || extra.growth == screen_pictures_growth {
			continue
		}
		system.close(extra.handle)
		if !system.send(&control.completions, ring.Record{kind = u32(display.Control.Screen_Budget_Release), values = {0 = extra.growth}}) {
			// The root service ends the budget at the stop of this process.
			system.log_fact(.Warning, Screen_Budget_Release_Not_Sent{})
		}
		extra = {}
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
	paying, paying_known := screen_extra_of_size(width, height)
	pages_left: u64
	if paid_at_start || paying_known {
		if paid_at_start {
			paying = {}
		}
		if budget, budget_status := system.budget_read(paying.handle); budget_status == .Ok {
			pages_left = u64(budget.pages)
		}
	}
	refusal, same := memory_screen.resize_decide(screen_of_memory, width, height, u32(screen.width), u32(screen.height), pages_left)
	if refusal == .None && !same && !screen_of_memory_take(int(width), int(height), paying) {
		// The kernel had fewer pages than the budget says: the same cause.
		refusal = .Compositor_Budget
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
screen_of_memory_take :: proc "contextless" (width, height: int, paying: Screen_Extra) -> bool {
	new_frame, new_frame_memory, frame_made := canvas_try_create(width, height, paying.handle)
	if !frame_made {
		return false
	}
	new_background, new_background_memory, background_made := canvas_try_create(width, height, paying.handle)
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
	// back after the answer (screen_budgets_give_back).
	screen_pictures_growth = paying.growth
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
