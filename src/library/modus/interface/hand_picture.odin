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
	show_picture(&picture.drawing, window, picture.canvas, picture.generation)
}
