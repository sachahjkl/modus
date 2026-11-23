package interface

// The picture of a window that draws its pixels by hand
// (src/md/features/desktop_to_browser.md, "The reference screen"). Such a
// process draws with src/library/modus/graphics at places in pixels; its
// surface is in pixels of the screen, at the scale of the desktop. So it
// draws into a picture of its own, of the logical size of its window, and
// shows it as one Picture record: the drawing module puts each of its
// pixels on the pixels of the screen of its logical pixel. The process
// computes no pixel of the screen, and keeps its layout as it was.
//
// The cost: one picture of the logical size in the memory of the process
// (hand_picture_pages), and the text that it draws by hand is pixels of a
// picture, not glyphs at the size of the screen. A window that moves its
// drawing to the elements of this package loses both.

import "modus:display"
import "modus:graphics"
import "modus:system"

// The records of the two tables of a hand picture: one Picture record, and
// room for the pops of the clips that a table keeps.
@(private)
HAND_PICTURE_RECORDS :: 4

// Hand_Picture: the logical picture of a window, and the drawing that shows
// it. It holds slices of itself: a process keeps it in one place, a global,
// from hand_picture_open on.
Hand_Picture :: struct {
	canvas:           graphics.Canvas, // The picture that the process draws, of the logical size of the window.
	memory:           system.Handle, // The memory of its pixels, from the budget of the process.
	drawing:          Window_Drawing,
	records_now:      [HAND_PICTURE_RECORDS]Draw_Record,
	records_before:   [HAND_PICTURE_RECORDS]Draw_Record,
	picture_memories: [1][]graphics.Color,
	generation:       u32, // A new number at each show: the difference sees new pixels.
	// The drawing of the frame of elements that the process draws into the
	// picture (window_frame_end_into_picture), or nil. The scroll of a
	// layout larger than the view is one for both: the show takes it from
	// that frame, and gives back the scroll that its bars set.
	elements:         ^Window_Drawing,
	scroll_show_due:  bool, // The scroll needs a frame that the compositor could not take yet (hand_picture_events).
}

// hand_picture_input_pass gives the drawing of a hand picture what the frame
// of elements drawn into it leaves to the window: its scroll, and the
// pointer, the press and the wheel, in the coordinates of the view, that
// the bars of the show take. The keys stay with the frame of elements,
// which took PageUp and PageDown already.
@(private)
hand_picture_input_pass :: proc "contextless" (picture: ^Hand_Picture, elements: ^Window_Drawing) {
	picture.elements = elements
	shown := &picture.drawing
	shown.scroll_x, shown.scroll_y = elements.scroll_x, elements.scroll_y
	from, to := &elements.input, &shown.input
	to.pointer_x, to.pointer_y, to.pointer_known = from.pointer_x, from.pointer_y, from.pointer_known
	to.press_x, to.press_y = from.press_x, from.press_y
	to.pressed ||= from.pressed
	to.released ||= from.released
	to.button_held = from.button_held
	to.wheel += from.wheel
}

// hand_picture_pages gives the pages of the picture of a window of a
// logical size: a window that states its budget adds them to its working
// memory.
hand_picture_pages :: proc "contextless" (width, height: int) -> u64 {
	return (u64(width * height * size_of(graphics.Color)) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
}

// hand_picture_open makes the picture of a window, of its logical size,
// from the budget of the process, and the drawing that shows it. It gives
// the status of the memory: a process with no picture has no window to
// draw.
hand_picture_open :: proc "contextless" (picture: ^Hand_Picture, window: ^display.Window) -> system.Status {
	memory, status := system.memory_create(hand_picture_pages(window.width, window.height))
	if status != .Ok {
		return status
	}
	address: rawptr
	address, status = system.memory_map(memory)
	if status != .Ok {
		system.close(memory)
		return status
	}
	pixels := ([^]graphics.Color)(address)
	picture.memory = memory
	picture.canvas = {pixels = pixels, width = window.width, height = window.height, stride = window.width}
	picture.picture_memories[0] = pixels[:window.width * window.height]
	picture.drawing = window_drawing_of_picture(picture.records_now[:], picture.records_before[:], picture.picture_memories[:])
	return .Ok
}

// hand_picture_show shows the picture that the process drew: one frame of
// the window, whose one record is the picture, at its new generation. The
// frame is left out when the compositor did not take the picture before
// (window_frame_end): the next show draws it.
hand_picture_show :: proc "contextless" (picture: ^Hand_Picture, window: ^display.Window) {
	picture.generation += 1
	picture.scroll_show_due = false
	show_picture(&picture.drawing, window, picture.canvas, picture.generation)
	if picture.elements != nil {
		picture.elements.scroll_x, picture.elements.scroll_y = picture.drawing.scroll_x, picture.drawing.scroll_y
	}
}

// hand_picture_events reads the events that wait for the window of a hand
// picture, for a process that reads none itself, and gives each to the
// scroll of the window (window_scroll_event). When the scroll needs a
// frame, it shows the picture again at the new scroll, once the compositor
// took the picture before; the pixels of the picture stay as the process
// drew them. It gives true when an event came.
hand_picture_events :: proc "contextless" (picture: ^Hand_Picture, window: ^display.Window) -> (came: bool) {
	for event in display.next_event(window) {
		came = true
		_, _, show_due := window_scroll_event(&picture.drawing, window, event)
		picture.scroll_show_due ||= show_due
	}
	// A canvas that the compositor still reads keeps the show due: the wait
	// of the window ends when the compositor has read it.
	if picture.scroll_show_due && display.canvas_free(window) {
		picture.scroll_show_due = false
		show_picture(&picture.drawing, window, picture.canvas, picture.generation)
	}
	return came
}

// hand_picture_wait_until reads the events of the window of a hand picture
// until a time of the clock of the system, as hand_picture_events: a
// process that draws at a fixed interval waits with it in place of a sleep,
// so the scroll of its window follows the wheel and the keys at once.
hand_picture_wait_until :: proc "contextless" (picture: ^Hand_Picture, window: ^display.Window, time: u64) {
	for {
		_ = hand_picture_events(picture, window)
		if system.time() >= time {
			return
		}
		_ = display.wait(window, time)
	}
}
