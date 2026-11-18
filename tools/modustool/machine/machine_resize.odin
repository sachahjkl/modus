package machine

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import "modus:contract/reference_screen"
import "modustool:foundation"

// The step Resize: the pointer drags the bottom left corner of a window,
// as the principal does (src/md/features/window_resize.md). The window
// grows to the left and down: a new window is placed at the left of the
// screen, with room at its left and under it. The compositor
// sends the process the event Resized at the release, the process makes
// the surface of the new size, and the compositor writes its line when the
// window takes it, at the first picture of that surface:
// "compositor: window clock resized from 816x336 to 880x384".

// The line of the compositor at its start: "compositor: ok 1280x800".
SCREEN_SIZE_LINE :: "compositor: ok "
// The line on a test machine: the reference screen. The step Screen_Size
// of the main scenario checks it; a host test reads its size back
// (scenario_places_test.odin).
REFERENCE_SCREEN_LINE :: SCREEN_SIZE_LINE + "1920x1080"
#assert(reference_screen.WIDTH == 1920 && reference_screen.HEIGHT == 1080, "REFERENCE_SCREEN_LINE names 1920x1080")

// reference_screen_problem gives "" when the last line of the compositor
// at its start names the reference screen, else the sentence of the fault:
// the size that the firmware gave, or that the line is missing or has no
// size. A machine on another screen fails at its first check, not at the
// hang bound of a later step.
reference_screen_problem :: proc(log: string) -> string {
	width, height, known := screen_size_of_log(log)
	if !known {
		return fmt.tprintf("the log has no line \"%s<width>x<height>\"", SCREEN_SIZE_LINE)
	}
	if width != reference_screen.WIDTH || height != reference_screen.HEIGHT {
		return fmt.tprintf("the firmware gave %dx%d, not the reference screen %dx%d", width, height, reference_screen.WIDTH, reference_screen.HEIGHT)
	}
	return ""
}

// screen_size_of_log gives the size of the screen of the machine, from the
// line of the compositor at its start.
screen_size_of_log :: proc(log: string) -> (width, height: int, ok: bool) {
	at := strings.last_index(log, SCREEN_SIZE_LINE)
	if at < 0 {
		return 0, 0, false
	}
	line := log[at + len(SCREEN_SIZE_LINE):]
	if end := strings.index_byte(line, '\n'); end >= 0 {
		line = line[:end]
	}
	line = strings.trim_right(line, "\r")
	by := strings.index_byte(line, 'x')
	if by < 0 {
		return 0, 0, false
	}
	width = strconv.parse_int(line[:by]) or_return
	height = strconv.parse_int(line[by + 1:]) or_return
	return width, height, true
}

// window_resize_step runs one step Resize. The corner is the first column
// and the last line of the frame, on its border: the compositor gives that
// place the edges at the left and at the bottom. The move is a multiple of
// the grid of 8 when the sizes are, so the size is the one that the step
// names.
window_resize_step :: proc(machine: ^Machine, step: Step, index: int) -> bool {
	log := log_read(machine)
	frame, placed := log_window_rectangle(log, step.text)
	if !placed {
		fmt.eprintfln("modustool: test failed: step %d: the log does not have the place and the size of the window %s", index + 1, step.text)
		return false
	}
	width := frame.right - frame.left - 2 * WINDOW_BORDER
	height := frame.bottom - frame.top - WINDOW_TITLE_HEIGHT - WINDOW_BORDER
	corner_x, corner_y := frame.left, frame.bottom - 1
	target_x, target_y := corner_x - (step.to_x - width), corner_y + step.to_y - height
	// A target past the screen gives a smaller size than the step names:
	// the scenario is wrong, and the line says so before any press.
	screen_width, screen_height, known := screen_size_of_log(log)
	if !known || target_x < 0 || target_y < 0 || target_x >= screen_width || target_y >= screen_height {
		fmt.eprintfln("modustool: test failed: step %d: the corner of the window %s at %d,%d would go to %d,%d, which is not on the screen of %dx%d", index + 1, step.text, corner_x, corner_y, target_x, target_y, screen_width, screen_height)
		return false
	}
	window_front_where_covered(machine, step.text, corner_x, corner_y, index) or_return
	before := len(log_read(machine))
	pointer_press_at(machine, corner_x, corner_y, index) or_return
	if !pointer_move(machine, target_x, target_y) {
		fmt.eprintfln("modustool: test failed: step %d: the pointer did not reach its place", index + 1)
		return false
	}
	pointer_button(machine, false) or_return
	wanted := fmt.tprintf("compositor: window %s resized from %dx%d to %dx%d", step.text, width, height, step.to_x, step.to_y)
	for start := time.now(); time.since(start) < foundation.HANG_BOUND; {
		text := log_read(machine)
		if len(text) > before && strings.contains(text[before:], wanted) {
			foundation.test_passed_print("the window %s is %dx%d: its process drew the new size", step.text, step.to_x, step.to_y)
			return true
		}
		log_change_wait(machine)
	}
	fmt.eprintfln("modustool: test failed: step %d: the log does not have \"%s\" within %v", index + 1, wanted, foundation.HANG_BOUND)
	return false
}
