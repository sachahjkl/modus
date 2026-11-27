package interface

import "modus:contract/scale_factor"
import "modus:display"

KEY_CAPACITY :: 16 // Plan value: keys buffered per frame before remaining events wait in the window ring.
// Inline capacity: fast tier for typical windows (observed desktop windows hold
// 4 to 48 focusable controls). Past this count, an Interface_State configured
// with interface_state_set_focus_overflow moves to its backing slice without
// dropping Tab targets, incrementing focus_overflow_moves.
FOCUS_ORDER_CAPACITY :: 64
KEY_TAB :: 0x0F // The code of the key Tab: it moves the focus (Shift+Tab: back).

// Caller-supplied growth callback for the slower focus-order tier. Returns a
// slice of at least minimum_count entries, or false when the budget refuses.
Focus_Order_Grow :: #type proc "contextless" (user_data: rawptr, current: []Element_Identity, minimum_count: int) -> (grown: []Element_Identity, ok: bool)

// A number that names one element from one frame to the next.
Element_Identity :: distinct u64

// identity makes the identity of an element from a text: the 64-bit FNV-1a
// hash of its bytes. 0 is no element. Two elements with one text have one
// identity: give each one a number with identity_with (a row, a card), or a
// parent with identity_in. Frame.identity_collisions counts the elements of
// a frame whose identity an element before them had.
identity :: proc "contextless" (name: string) -> Element_Identity {
	hash: u64 = 0xCBF2_9CE4_8422_2325
	for index in 0 ..< len(name) {
		hash = (hash ~ u64(name[index])) * 0x0000_0100_0000_01B3
	}
	return Element_Identity(hash | 1)
}

// identity_in makes the identity of an element inside another one: a
// button of a card.
identity_in :: proc "contextless" (parent: Element_Identity, name: string) -> Element_Identity {
	hash := u64(parent)
	for index in 0 ..< len(name) {
		hash = (hash ~ u64(name[index])) * 0x0000_0100_0000_01B3
	}
	return Element_Identity(hash | 1)
}

// identity_with makes the identity of one of a set of elements: a line of a
// list, a button of a row.
identity_with :: proc "contextless" (base: Element_Identity, index: int) -> Element_Identity {
	hash := u64(base)
	for shift := uint(0); shift < 64; shift += 8 {
		hash = (hash ~ (u64(index) >> shift & 0xFF)) * 0x0000_0100_0000_01B3
	}
	return Element_Identity(hash | 1)
}

// One key that went down in a frame, from a display event.
Key_Press :: struct {
	code:      u32, // The code of the key, as the input service gives it.
	character: rune, // The character of the key as a code point, or 0.
	modifiers: u32, // The keys Shift, Control and Alt that were down.
	taken:     bool, // An element took the key: no other element takes it.
}

// The input of one frame, filled from the display events of the frame.
Input :: struct {
	pointer_x, pointer_y: int,
	pointer_known:        bool, // The pointer is over the surface, or a button is held.
	pressed, released:    bool, // The left button went down, or up, in this frame.
	button_held:          bool, // The left button is down: the display gives the state, the input needs the change.
	// Where the left button went down last. A frame can hold a press and
	// moves after it: the pointer is then at the end of the moves, and a
	// drag needs the place where it began.
	press_x, press_y:           int,
	// Right mouse button state for per-window context menus.
	right_pressed, right_released: bool,
	right_held:                    bool,
	right_press_x, right_press_y:  int,
	// The notches of the wheel in this frame, signed
	// (display.WHEEL_TOWARD_THE_END). The first view under the pointer
	// takes them (scroll_bar), and sets this to 0: no other view moves.
	wheel:                int,
	keys:                 [KEY_CAPACITY]Key_Press, // The keys of the frame, in order.
	key_count:            int, // The keys in use.
	// The keys of the clipboard of the principal (src/md/features/clipboard.md),
	// which window_events keeps for the next frame: the element with the
	// focus takes them, and window_frame_end answers after the frame.
	copy_asked:           bool, // A copy waits for the text of the element with the focus.
	paste:                display.Event, // A paste (kind Pasted) for the element with the focus, or kind None.
	paste_window:         ^display.Window, // The window of the paste: the element reads it with display.paste_read.
}

// input_add adds one display event to the input of a frame. It gives false
// for an event that it does not take (a key released).
input_add :: proc "contextless" (input: ^Input, event: display.Event) -> bool {
	switch event.kind {
	case .None, .Presentation, .Go_To, .Resized, .Copy_Asked, .Pasted, .Capture_Size, .Capture_Frame, .Capture_Disconnect, .Capture_Opened, .Surface_Answer, .Work_Area, .Pointer_Delta, .Pointer_Lock_Changed:
		// The window layer takes these events itself (window_events).
	case .Pointer:
		input.pointer_x, input.pointer_y = event.x, event.y
		input.pointer_known = true
		held := event.buttons & display.BUTTON_LEFT != 0
		if held && !input.button_held {
			input.press_x, input.press_y = event.x, event.y
		}
		input.pressed ||= held && !input.button_held
		input.released ||= !held && input.button_held
		input.button_held = held
		r_held := event.buttons & display.BUTTON_RIGHT != 0
		if r_held && !input.right_held {
			input.right_press_x, input.right_press_y = event.x, event.y
		}
		input.right_pressed ||= r_held && !input.right_held
		input.right_released ||= !r_held && input.right_held
		input.right_held = r_held
		// Each event cuts its notches to key_path.WHEEL_NOTCHES_LIMIT, so
		// the sum of a frame stays far inside an int.
		input.wheel += event.wheel
		return true
	case .Key:
		if !event.pressed || input.key_count >= KEY_CAPACITY {
			return false
		}
		input.keys[input.key_count] = {code = event.code, character = event.character, modifiers = event.modifiers}
		input.key_count += 1
		return true
	}
	return false
}

// input_has_room says if the input of a frame can take one more key. When
// it cannot, the caller leaves the next events in the ring of the window for
// the next frame: no key is lost.
input_has_room :: proc "contextless" (input: ^Input) -> bool {
	return input.key_count < KEY_CAPACITY
}

// input_clear makes the input of the next frame: the pointer stays where it is.
input_clear :: proc "contextless" (input: ^Input) {
	input.pressed = false
	input.released = false
	input.right_pressed = false
	input.right_released = false
	input.wheel = 0
	input.key_count = 0
}

// What the package keeps between frames, in the memory of the process.
Interface_State :: struct {
	focus:         Element_Identity, // The element that takes the keys.
	under_pointer: Element_Identity, // The element under the pointer in the last frame.
	pressed:       Element_Identity, // The element where the left button went down, until it goes up.
	// The order of the elements that can take the focus, in the last frame:
	// Tab and Shift+Tab follow it.
	focus_order:          [FOCUS_ORDER_CAPACITY]Element_Identity,
	focus_count:          int, // The entries of the active focus order in use.
	focus_external:       []Element_Identity, // Slower tier: caller-supplied backing slice past FOCUS_ORDER_CAPACITY.
	focus_grow:           Focus_Order_Grow,
	focus_grow_data:      rawptr,
	focus_in_overflow:    bool, // True when the last frame's focus order lives in focus_external.
	focus_overflow_moves: u64, // Count of moves to or growths of the slower focus tier, visible as a measure.
	view_zoom:     scale_factor.View_Zoom, // Independent per-view zoom in eighths (0 reads as .One).
	// The scroll bar that holds the press (`pressed` is its identity): one
	// button is down at a time, so one scroll bar at most is held, and no
	// process keeps a state for its scroll bars.
	scroll_bar_part:      Scroll_Bar_Part, // The part where the button went down. None: `pressed` is not a scroll bar.
	scroll_bar_grab:      int, // A held thumb: the pixels from the start of the thumb to the pointer, along the bar.
	scroll_bar_repeat_at: u64, // A held arrow button: the time of its next step, in milliseconds of the clock of the system. 0: no step is due.
	scroll_bar_lit:       Element_Identity, // The scroll bar that the last frame drew lit, or 0.
	// The act names of the last frame (element_act_name): go to finds its
	// element here, and the window layer sends their set to the compositor.
	act_names:      [display.ACT_NAME_SET_CAPACITY]Act_Name,
	act_name_count: int, // The entries of `act_names` in use.
}
#assert(size_of(Interface_State) == 1208)

// interface_state_set_focus_overflow attaches a caller-supplied backing slice
// and optional growth callback for frames with more than FOCUS_ORDER_CAPACITY
// focusable elements. Frames within FOCUS_ORDER_CAPACITY stay on the inline tier.
interface_state_set_focus_overflow :: proc "contextless" (state: ^Interface_State, backing: []Element_Identity, grow: Focus_Order_Grow = nil, grow_data: rawptr = nil) {
	if state == nil {
		return
	}
	state.focus_external = backing
	state.focus_grow = grow
	state.focus_grow_data = grow_data
	if state.focus_count == 0 {
		state.focus_in_overflow = false
	}
}

// state_focus_order returns the active focus order slice from the last frame.
state_focus_order :: proc "contextless" (state: ^Interface_State) -> []Element_Identity {
	if state == nil || state.focus_count <= 0 {
		return nil
	}
	if state.focus_in_overflow {
		return state.focus_external[:min(state.focus_count, len(state.focus_external))]
	}
	return state.focus_order[:min(state.focus_count, FOCUS_ORDER_CAPACITY)]
}

// frame_focus_order returns the active focus order slice built in this frame.
frame_focus_order :: proc "contextless" (frame: ^Frame) -> []Element_Identity {
	if frame == nil || frame.focus_count <= 0 {
		return nil
	}
	if frame.focus_in_overflow && frame.state != nil {
		return frame.state.focus_external[:min(frame.focus_count, len(frame.state.focus_external))]
	}
	return frame.focus_order[:min(frame.focus_count, FOCUS_ORDER_CAPACITY)]
}

// One act name of a frame: what an element acts on, in the words of a
// palette entry that does the same thing
// (docs/INTERFACE.md, "4.2 Act names").
Act_Name :: struct {
	element: Element_Identity, // The first element of the frame that named it.
	hash:    u32, // display.act_name_hash of the text.
	length:  u8, // The bytes of `text` in use: 1 to display.ACT_NAME_CAPACITY.
	text:    [display.ACT_NAME_CAPACITY]u8, // "settings.set:font".
}

// act_name_text gives the text of an act name.
act_name_text :: proc "contextless" (name: ^Act_Name) -> string {
	return string(name.text[:min(int(name.length), display.ACT_NAME_CAPACITY)])
}

// element_act_name says that an element of the frame acts on what an act
// name names: the palette then offers to go to it, and go to gives it the
// focus. Call it in each frame that draws the element, with the identity
// that the element has. The first element of a frame with one act name
// keeps it: a process names the element that go to must reach. A name that
// is empty or longer than display.ACT_NAME_CAPACITY, and a name past the
// display.ACT_NAME_SET_CAPACITY names of a frame, are counted in
// Frame.act_names_dropped and kept nowhere.
element_act_name :: proc "contextless" (frame: ^Frame, element: Element_Identity, name: string) {
	if len(name) == 0 || len(name) > display.ACT_NAME_CAPACITY {
		frame.act_names_dropped += 1
		return
	}
	hash := display.act_name_hash(name)
	for &kept in frame.act_names[:frame.act_name_count] {
		if kept.hash == hash {
			return
		}
	}
	if frame.act_name_count >= display.ACT_NAME_SET_CAPACITY {
		frame.act_names_dropped += 1
		return
	}
	added := &frame.act_names[frame.act_name_count]
	added^ = {element = element, hash = hash, length = u8(len(name))}
	copy(added.text[:], name)
	frame.act_name_count += 1
}

// focus_by_act_name gives the focus to the element of the last frame that
// named an act name, by its hash: the palette went there. The next frame
// draws the focus. found is false when no element of the last frame named
// it; name is the text of the act name, for a line of the log.
focus_by_act_name :: proc "contextless" (state: ^Interface_State, hash: u32) -> (name: string, found: bool) {
	for &kept in state.act_names[:clamp(state.act_name_count, 0, display.ACT_NAME_SET_CAPACITY)] {
		if kept.hash == hash {
			state.focus = kept.element
			return act_name_text(&kept), true
		}
	}
	return "", false
}

// One frame: the table that it fills, the state, the input of the frame.
Frame :: struct {
	table:         ^Draw_Table, // The table of this frame.
	state:         ^Interface_State, // The state from the frame before; the frame writes the state for the next one.
	input:         ^Input, // The input of this frame.
	time:          u64, // The clock of the system at the start of the frame, in milliseconds. 0: the frame has no clock, and a held arrow button of a scroll bar does not repeat.
	scroll_bar_lit: Element_Identity, // The scroll bar that this frame drew lit, so far.
	scroll_bar_held_drawn: bool, // The scroll bar that holds the press is in this frame.
	under_pointer: Element_Identity, // The element under the pointer in this frame, so far.
	focus_order:       [FOCUS_ORDER_CAPACITY]Element_Identity, // The elements that can take the focus in this frame, so far.
	focus_count:       int, // The entries of the active focus order in use.
	focus_in_overflow: bool, // True when this frame moved its focus order into state.focus_external.
	// Two elements with one identity in this frame: both would show the
	// focus and take a press. The caller makes them two with identity_with.
	identity_collisions: int,
	// Elements that did not fit in the inline tier or any configured overflow
	// tier: a press reaches them, Tab does not.
	focus_overflow:      int,
	act_names:           [display.ACT_NAME_SET_CAPACITY]Act_Name, // The act names of this frame, so far: the first element of each one.
	act_name_count:      int, // The entries of `act_names` in use.
	act_names_dropped:   int, // The act names that the frame did not keep: too long, empty, or past the capacity.
	element_places:      Element_Places, // The named elements of this frame, so far (element_name): a window writes their changes on the log.
	// The area of the element with the focus in this frame: a window that
	// scrolls brings it into its view (window_scroll.odin).
	focus_area:          Area,
	focus_area_known:    bool,
	copied:              []u8, // The text that the element with the focus gives to a copy: memory of the caller, until the end of the frame.
	copy_given:          bool, // An element took the copy of this frame.
	paste_taken:         bool, // An element took the paste of this frame, inserted or refused.
}

// frame_begin clears the table and starts a frame. Tab and Shift+Tab move
// the focus here, in the order of the last frame. time is the clock of the
// system in milliseconds: a held arrow button of a scroll bar repeats by it.
frame_begin :: proc "contextless" (table: ^Draw_Table, state: ^Interface_State, input: ^Input, time: u64 = 0) -> Frame {
	draw_table_clear(table)
	order := state_focus_order(state)
	for &key in input.keys[:input.key_count] {
		if key.code != KEY_TAB || len(order) == 0 {
			continue
		}
		key.taken = true
		position := -1
		for item, index in order {
			if item == state.focus {
				position = index
			}
		}
		backward := key.modifiers & display.MODIFIER_SHIFT != 0
		if position < 0 {
			position = backward ? 0 : len(order) - 1
		}
		step := backward ? len(order) - 1 : 1
		state.focus = order[(position + step) % len(order)]
	}
	view_zoom_apply_keys(state, input)
	return {table = table, state = state, input = input, time = time}
}

// frame_end keeps what the next frame needs. It pops each clip that the
// frame left open, so the table ends in an order that the drawing module
// takes (draw_clips_close).
frame_end :: proc "contextless" (frame: ^Frame) {
	if frame.table != nil {
		draw_clips_close(frame.table)
	}
	state := frame.state
	state.under_pointer = frame.under_pointer
	state.focus_in_overflow = frame.focus_in_overflow
	if !frame.focus_in_overflow {
		state.focus_order = frame.focus_order
	}
	state.focus_count = frame.focus_count
	state.scroll_bar_lit = frame.scroll_bar_lit
	state.act_names = frame.act_names
	state.act_name_count = frame.act_name_count
	// A held scroll bar that the frame does not have takes no step: with a
	// step still due, a process that wakes for it would never sleep.
	if !frame.scroll_bar_held_drawn {
		state.scroll_bar_repeat_at = 0
	}
	if frame.input.released {
		state.pressed = 0
		state.scroll_bar_part = .None
		state.scroll_bar_repeat_at = 0
	}
}

// What the input did to one element in one frame.
Element_Result :: struct {
	activated:     bool, // Pressed and released on it, or Enter or Space with the focus.
	focused:       bool, // It has the focus.
	under_pointer: bool, // The pointer is over it.
	changed:       bool, // A text input: the text changed. A list: the choice changed.
}

// The kinds of elements that take input. The kind says which keys activate it.
Element_Kind :: enum u8 {
	Button, // Enter and Space activate it.
	List, // Enter activates it; up and down move its choice.
	Text_Input, // Enter activates it, in the order of the keys; Space is a character.
}

// element_interact gives what the input did to an element in an area. Each
// such element can take the focus, and joins the order of Tab.
element_interact :: proc "contextless" (frame: ^Frame, element: Element_Identity, area: Area, kind: Element_Kind) -> (result: Element_Result) {
	state := frame.state
	input := frame.input
	for other in frame_focus_order(frame) {
		if other == element {
			frame.identity_collisions += 1
			break
		}
	}
	if !frame.focus_in_overflow && frame.focus_count < FOCUS_ORDER_CAPACITY {
		frame.focus_order[frame.focus_count] = element
		frame.focus_count += 1
	} else {
		needed := frame.focus_count + 1
		ready := false
		if !frame.focus_in_overflow {
			target := state.focus_external
			if len(target) < needed && state.focus_grow != nil {
				if grown, ok := state.focus_grow(state.focus_grow_data, target, needed); ok && len(grown) >= needed && raw_data(grown) != nil {
					target = grown
				}
			}
			if len(target) >= needed {
				copy(target[:frame.focus_count], frame.focus_order[:frame.focus_count])
				state.focus_external = target
				frame.focus_in_overflow = true
				state.focus_overflow_moves += 1
				ready = true
			}
		} else if len(state.focus_external) >= needed {
			ready = true
		} else if state.focus_grow != nil {
			if grown, ok := state.focus_grow(state.focus_grow_data, state.focus_external, needed); ok && len(grown) >= needed && raw_data(grown) != nil {
				if raw_data(grown) != raw_data(state.focus_external) {
					copy(grown[:frame.focus_count], state.focus_external[:frame.focus_count])
				}
				state.focus_external = grown
				state.focus_overflow_moves += 1
				ready = true
			}
		}
		if ready {
			state.focus_external[frame.focus_count] = element
			frame.focus_count += 1
		} else {
			frame.focus_overflow += 1
		}
	}
	if input.pointer_known && area_contains(area, input.pointer_x, input.pointer_y) {
		result.under_pointer = true
		frame.under_pointer = element
		if input.pressed {
			state.pressed = element
			state.focus = element
		}
		if input.released && state.pressed == element {
			result.activated = true
		}
	}
	result.focused = state.focus == element
	if result.focused {
		frame.focus_area, frame.focus_area_known = area, true
	}
	// A text input takes Enter in the order of its keys (text_input).
	if result.focused && kind != .Text_Input {
		for &key in input.keys[:input.key_count] {
			if !key.taken && (key.code == display.KEY_ENTER || kind == .Button && key.character == ' ') {
				key.taken = true
				result.activated = true
			}
		}
	}
	return
}

// key_take gives the next key of the frame that no element took, for an
// element with the focus.
key_take :: proc "contextless" (frame: ^Frame) -> (key: Key_Press, ok: bool) {
	for &item in frame.input.keys[:frame.input.key_count] {
		if !item.taken {
			item.taken = true
			return item, true
		}
	}
	return {}, false
}
