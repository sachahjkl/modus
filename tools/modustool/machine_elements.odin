package modustool

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

import "modus:private/compositor/bar"
import "modustool:foundation"

// The press of a machine test on an element by its name
// (src/md/infrastructure/test_pointer.md; docs/TOOLS.md, "The scenario
// steps"). A window writes the place of each named element when it
// changes: "interface: debugger_window: the element watch at x,y,width,height",
// in pixels of its surface. The palette is a panel of the compositor, not
// a window: the compositor writes the places of its fields and of its
// buttons, in pixels of the screen: "compositor: the palette: the element
// round_robin at x,y,width,height". A step names the element; the tool reads
// its place from the last line, and so follows a change of the layout.

// The owner of the step Click_Element that names an element of the
// palette, in place of the title of a window.
PALETTE_ELEMENTS :: "the palette"

// Where the last element line of an element puts it.
Element_Line :: enum {
	Absent, // The log has no line of the element yet.
	Gone, // The last line says that the element is gone.
	Placed, // The last line gives its rectangle.
}

// element_line_prefix gives the start of each element line of an owner:
// "interface: debugger_window: the element " or "compositor: the palette:
// the element ".
element_line_prefix :: proc(owner: string) -> string {
	if owner == PALETTE_ELEMENTS {
		return strings.concatenate({"compositor: ", PALETTE_ELEMENTS, ": the element "}, context.temp_allocator)
	}
	return strings.concatenate({"interface: ", owner, ": the element "}, context.temp_allocator)
}

// element_line_read reads the last element line of an element in a log:
// the rectangle that it gives, in pixels of the surface of the window or
// of the screen for the palette. The name ends with " at " or " is gone",
// so the line of "frame 1" is not the line of "frame 10".
element_line_read :: proc(log: string, owner, element: string) -> (x, y, width, height: int, found: Element_Line) {
	prefix := element_line_prefix(owner)
	placed_mark := strings.concatenate({prefix, element, " at "}, context.temp_allocator)
	gone_mark := strings.concatenate({prefix, element, " is gone"}, context.temp_allocator)
	placed_at := strings.last_index(log, placed_mark)
	gone_at := strings.last_index(log, gone_mark)
	if placed_at < 0 && gone_at < 0 {
		return 0, 0, 0, 0, .Absent
	}
	if gone_at > placed_at {
		return 0, 0, 0, 0, .Gone
	}
	rest := log[placed_at + len(placed_mark):]
	if end := strings.index_byte(rest, '\n'); end >= 0 {
		rest = rest[:end]
	}
	numbers := strings.split(strings.trim_space(rest), ",", context.temp_allocator)
	if len(numbers) != 4 {
		return 0, 0, 0, 0, .Absent
	}
	values: [4]int
	for text, index in numbers {
		value, ok := strconv.parse_int(text)
		if !ok {
			return 0, 0, 0, 0, .Absent
		}
		values[index] = value
	}
	return values[0], values[1], values[2], values[3], .Placed
}

// element_center_wait waits until the log places an element, then gives
// the middle of its rectangle on the screen. An element whose last line
// says that it is gone, or that has no line yet, is waited for: the frame
// that draws it writes its line. The wait ends at HANG_BOUND.
element_center_wait :: proc(machine: ^Machine, owner, element: string, index: int) -> (x, y: int, ok: bool) {
	found := Element_Line.Absent
	element_x, element_y, width, height: int
	for start := time.now(); time.since(start) < foundation.HANG_BOUND; {
		element_x, element_y, width, height, found = element_line_read(log_read(machine), owner, element)
		if found == .Placed {
			break
		}
		log_change_wait(machine)
	}
	if found != .Placed {
		words := found == .Gone ? "says that it is gone" : "has no line of it"
		fmt.eprintfln("modustool: test failed: step %d: the element %s of %s is not placed: the log %s within %v", index + 1, element, owner, words, foundation.HANG_BOUND)
		return 0, 0, false
	}
	x, y = element_x + width / 2, element_y + height / 2
	if owner == PALETTE_ELEMENTS {
		return x, y, true
	}
	window_x, window_y, placed := window_place(machine, owner)
	if !placed {
		fmt.eprintfln("modustool: test failed: step %d: the log does not have the place of the window %s", index + 1, owner)
		return 0, 0, false
	}
	return window_x + WINDOW_BORDER + x, window_y + WINDOW_TITLE_HEIGHT + y, true
}

// window_covered says if another window is over a point of the screen in
// front of the window with a title, from compositor.windows(): its rows
// give the place, the size and the order of each window. known is false
// when the tool cannot read the table (before a step Call with pointer):
// the log gives the places of the windows, not their order.
window_covered :: proc(machine: ^Machine, title: string, x, y: int) -> (covered: bool, known: bool) {
	if !machine.confirm {
		return false, false
	}
	table := table_call(&machine.client, "compositor.windows()") or_return
	rows := len(table.rows) / table.size
	target_order := -1
	for row in 0 ..< rows {
		if table_value(&table, row, "title") == title {
			target_order = strconv.parse_int(table_value(&table, row, "order")) or_return
		}
	}
	if target_order < 0 {
		return false, false
	}
	for row in 0 ..< rows {
		order := strconv.parse_int(table_value(&table, row, "order")) or_return
		if order >= target_order {
			continue
		}
		left := strconv.parse_int(table_value(&table, row, "x")) or_return
		top := strconv.parse_int(table_value(&table, row, "y")) or_return
		width := strconv.parse_int(table_value(&table, row, "width")) or_return
		height := strconv.parse_int(table_value(&table, row, "height")) or_return
		if x >= left && x < left + width && y >= top && y < top + height {
			return true, true
		}
	}
	return false, true
}

// window_front_where_covered brings a window to the front when another
// window covers a point that a step presses in it, or when the tool cannot
// read the order of the windows: a press must reach the window that the
// step names, not a window over it.
window_front_where_covered :: proc(machine: ^Machine, title: string, x, y: int, index: int) -> bool {
	covered, known := window_covered(machine, title, x, y)
	if known && !covered {
		return true
	}
	return window_front_bring(machine, title, index)
}

// pointer_known_make pushes the pointer to the corner of the screen the
// first time a step moves it: it starts at a place that the tool does not
// know.
pointer_known_make :: proc(machine: ^Machine, index: int) -> bool {
	if machine.pointer_known {
		return true
	}
	machine.pointer_known = true
	if !pointer_corner_push(machine) {
		fmt.eprintfln("modustool: test failed: step %d: the pointer did not go to the corner of the screen", index + 1)
		return false
	}
	return true
}

// The start of the line that the compositor writes for each press of the
// left button, before its place "x,y".
PRESS_LINE :: "compositor: a press of the left button at "

// press_place_read waits for the line of the first press after the byte
// `from` of the log, and gives the place where the compositor took it.
press_place_read :: proc(machine: ^Machine, from: int, index: int) -> (x, y: int, ok: bool) {
	for start := time.now(); time.since(start) < foundation.HANG_BOUND; {
		text := log_read(machine)
		at := len(text) > from ? strings.index(text[from:], PRESS_LINE) : -1
		end := at < 0 ? -1 : strings.index_byte(text[from + at:], '\n')
		if end < 0 {
			log_change_wait(machine)
			continue
		}
		place := strings.trim_right(text[from + at + len(PRESS_LINE):from + at + end], "\r")
		comma := strings.index_byte(place, ',')
		x_read, x_ok := strconv.parse_int(place[:max(comma, 0)])
		y_read, y_ok := strconv.parse_int(place[comma + 1:])
		if comma < 0 || !x_ok || !y_ok {
			fmt.eprintfln("modustool: test failed: step %d: the line of the press gives the place \"%s\", not x,y", index + 1, place)
			return 0, 0, false
		}
		return x_read, y_read, true
	}
	fmt.eprintfln("modustool: test failed: step %d: the compositor wrote no line of the press within %v: the machine did not receive the press", index + 1, foundation.HANG_BOUND)
	return 0, 0, false
}

// pointer_press_at moves the pointer to a point of the screen and presses
// the left button there. With no confirmation of the pointer, the place
// that the tool believes is a sum of its moves: the input service joins
// the moves that find its ring full, and the edge of the screen cuts a
// joined move where it would not cut each move alone, so that sum can be
// wrong. The compositor writes the place of each press: a press at another
// place is released, the tool takes the place that the compositor wrote,
// and moves again, at most POINTER_TRIES times.
pointer_press_at :: proc(machine: ^Machine, x, y: int, index: int) -> bool {
	pointer_known_make(machine, index) or_return
	for _ in 0 ..< POINTER_TRIES {
		if !pointer_move(machine, x, y) {
			fmt.eprintfln("modustool: test failed: step %d: the pointer did not reach its place", index + 1)
			return false
		}
		before := len(log_read(machine))
		pointer_button(machine, true) or_return
		if machine.confirm {
			return true
		}
		pressed_x, pressed_y := press_place_read(machine, before, index) or_return
		if pressed_x == x && pressed_y == y {
			return true
		}
		fmt.printfln("modustool: step %d: the press landed at %d,%d, not at %d,%d: the tool moves again from the place that the compositor wrote", index + 1, pressed_x, pressed_y, x, y)
		pointer_button(machine, false) or_return
		machine.x, machine.y = pressed_x, pressed_y
	}
	fmt.eprintfln("modustool: test failed: step %d: %d presses did not land at %d,%d", index + 1, POINTER_TRIES, x, y)
	return false
}

// pointer_click moves the pointer to a point of the screen, then presses
// and releases the left button there.
pointer_click :: proc(machine: ^Machine, x, y: int, index: int) -> bool {
	pointer_press_at(machine, x, y, index) or_return
	pointer_button(machine, false) or_return
	return true
}

// window_front_bring opens the menu of the windows, and presses the line
// of the last window with a title: the window comes to the front. The
// compositor writes the lines of the menu, then that the window is in
// front.
window_front_bring :: proc(machine: ^Machine, title: string, index: int) -> bool {
	// The menu of the windows lists a window from its first picture on; the
	// line of its surface comes before that picture.
	shown := fmt.tprintf("compositor: window %s is shown", title)
	for start := time.now(); !strings.contains(log_read(machine), shown); {
		if time.since(start) >= foundation.HANG_BOUND {
			fmt.eprintfln("modustool: test failed: step %d: the compositor did not show the window %s within %v", index + 1, title, foundation.HANG_BOUND)
			return false
		}
		log_change_wait(machine)
	}
	before := len(log_read(machine))
	layout, known := machine_bar_layout(machine)
	if !known {
		return false
	}
	menu_x, menu_y := bar.windows_button_center(layout)
	pointer_click(machine, menu_x, menu_y, index) or_return
	line, found := windows_line(machine, title, before)
	if !found {
		fmt.eprintfln("modustool: test failed: step %d: the menu of the windows does not have %s", index + 1, title)
		return false
	}
	line_x, line_y := bar.windows_line_center(layout, line)
	pointer_click(machine, line_x, line_y, index) or_return
	mark := strings.concatenate({"compositor: window ", title, " in front"}, context.temp_allocator)
	arrived := false
	for start := time.now(); !arrived && time.since(start) < foundation.HANG_BOUND; {
		text := log_read(machine)
		if arrived = len(text) > before && strings.contains(text[before:], mark); !arrived {
			log_change_wait(machine)
		}
	}
	if !arrived {
		fmt.eprintfln("modustool: test failed: step %d: the window %s did not come to the front", index + 1, title)
		return false
	}
	foundation.test_passed_print("the window %s came to the front", title)
	return true
}

// window_in_front says if the window with a title is the one in front, from
// the column order of compositor.windows() (0: in front). known is false
// when the tool cannot read the table.
window_in_front :: proc(machine: ^Machine, title: string) -> (front: bool, known: bool) {
	if !machine.confirm {
		return false, false
	}
	table := table_call(&machine.client, "compositor.windows()") or_return
	rows := len(table.rows) / table.size
	for row in 0 ..< rows {
		if table_value(&table, row, "title") == title {
			order := strconv.parse_int(table_value(&table, row, "order")) or_return
			return order == 0, true
		}
	}
	return false, false
}

// element_wheel turns the wheel over the element of a step Wheel. The
// compositor gives the notches only to the window in front, so the window
// comes to the front first when it is not there; the palette takes the
// pointer while it is open.
element_wheel :: proc(machine: ^Machine, owner, element: string, notches: int, index: int) -> bool {
	if owner != PALETTE_ELEMENTS {
		if front, known := window_in_front(machine, owner); !known || !front {
			window_front_bring(machine, owner, index) or_return
		}
	}
	x, y := element_center_wait(machine, owner, element, index) or_return
	pointer_known_make(machine, index) or_return
	if !pointer_move(machine, x, y) {
		fmt.eprintfln("modustool: test failed: step %d: the pointer did not reach its place", index + 1)
		return false
	}
	if !pointer_wheel(machine, notches) {
		fmt.eprintfln("modustool: test failed: step %d: the machine did not take the %d notches of the wheel", index + 1, notches)
		return false
	}
	foundation.test_passed_print("the tool turned the wheel by %d notches over the element %s of %s at %d,%d", notches, element, owner, x, y)
	return true
}

// element_click presses the element of a step Click_Element: the window
// comes to the front first when another window covers the element.
element_click :: proc(machine: ^Machine, owner, element: string, index: int) -> bool {
	x, y := element_center_wait(machine, owner, element, index) or_return
	if owner != PALETTE_ELEMENTS {
		window_front_where_covered(machine, owner, x, y, index) or_return
	}
	pointer_click(machine, x, y, index) or_return
	foundation.test_passed_print("the tool pressed the element %s of %s at %d,%d", element, owner, x, y)
	return true
}
