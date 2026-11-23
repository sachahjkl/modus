// The state of a box across frames, by its identity, and the box input of
// one frame (src/md/features/box_layout.md, "The chosen form").
package layout

import "modus:hash_table"

// The groups of 16 slots of the state table: 1024 slots, of which the table
// fills 7 of each 8.
STATE_GROUP_COUNT :: 64

// The frames after which an entry that no frame saw is stale: a search then
// finds it as a new entry, and an insert into a full table removes it.
STALE_FRAMES :: 120

// What a box keeps across frames.
Box_State :: struct {
	scroll:            [Axis]i32, // The scroll offsets, as the last solve clamped them.
	split_ratio:       i32, // Parts of 10 000; 0 until the caller sets one.
	chosen_index:      i32, // The chosen part of a box: a page of a set of pages, a row.
	sort_column:       i32,
	collapsed:         bool,
	sort_ascending:    bool,
	scrolls:           bool, // The box scrolls on an axis: the wheel goes to it.
	last_order:        u32, // Its index in the tree of the last frame: a later box is drawn on top.
	last_rect:         Rect,
	last_clipped_rect: Rect,
	last_seen_frame:   u64,
	input_frame:       u64, // The frame where box_input asked for its input last.
}

// The input of one frame, as the window got it from its events.
Frame_Input :: struct {
	pointer_x:           i32,
	pointer_y:           i32,
	pointer_present:     bool, // The pointer is over the window.
	primary_down:        bool, // The primary button is down now.
	primary_pressed:     bool, // The primary button went down in this frame.
	primary_released:    bool, // The primary button went up in this frame.
	primary_press_count: u8, // 2 for the second press of a double press.
	secondary_pressed:   bool,
	wheel_x:             i32, // Pixels; a positive value scrolls toward the end.
	wheel_y:             i32,
	activate_key:        bool, // Enter or Space went down in this frame.
}

// What the input of one frame does to one box.
Box_Input :: struct {
	under_pointer:     bool,
	held:              bool, // The primary press started on it and the button is down.
	activated:         bool, // A press and a release on it, or Enter or Space with the focus.
	activated_twice:   bool, // Activated by the second press of a double press.
	pressed_secondary: bool,
	dragging:          bool, // Held, and the pointer moved since the press.
	focused:           bool,
	drag_x:            i32, // The distance from the place of the press.
	drag_y:            i32,
	scrolled_x:        i32, // The wheel that this box took.
	scrolled_y:        i32,
}

// The outcome of a search of the state table.
State_Status :: enum u8 {
	Done           = 0,
	No_Identity    = 1, // Identity 0 keeps no state.
	Table_Full     = 2, // Each slot that a new entry can take holds an entry that a recent frame saw.
	Identity_Taken = 3, // box_input already gave the input of this identity in this frame: two boxes share it.
}

// The state of the boxes of one window across frames, and the input that
// the frame in progress gives.
Box_States :: struct {
	table:             hash_table.Hash_Table(Identity, Box_State, STATE_GROUP_COUNT),
	frame:             u64,
	input:             Frame_Input,
	focused:           Identity,
	held:              Identity,
	held_twice:        bool, // The press of the held box was the second of a double press.
	press_x:           i32,
	press_y:           i32,
	under_pointer:     Identity, // The box on top under the pointer, of the boxes that asked for input.
	scroll_target:     Identity, // The box on top under the pointer, of the boxes that scroll.
	activated:         Identity,
	activated_twice:   Identity,
	pressed_secondary: Identity,
}

// states_seed_set gives an empty table its seed: when the labels come from
// another party (the names of files), a seed that it does not know keeps it
// from choosing identities that fall in one group.
states_seed_set :: proc "contextless" (states: ^Box_States, seed: u64) -> bool {
	return hash_table.table_seed_set(&states.table, seed)
}

@(private)
entry_is_stale :: #force_inline proc "contextless" (states: ^Box_States, entry: ^Box_State) -> bool {
	return states.frame > entry.last_seen_frame + STALE_FRAMES
}

// The input of a frame acts on what the principal saw: the boxes of the
// frame before, which asked for input there.
@(private)
entry_was_shown :: #force_inline proc "contextless" (states: ^Box_States, entry: ^Box_State) -> bool {
	return states.frame > 0 && entry.last_seen_frame == states.frame - 1
}

// states_frame_begin starts a frame with its input: it finds the box under
// the pointer from the rects of the frame before, and gives the press, the
// release, the focus and the wheel to their boxes.
states_frame_begin :: proc "contextless" (states: ^Box_States, input: Frame_Input) {
	states.frame += 1
	states.input = input
	states.under_pointer = 0
	states.scroll_target = 0
	states.activated = 0
	states.activated_twice = 0
	states.pressed_secondary = 0
	top_order, top_scroll_order := -1, -1
	if input.pointer_present {
		place := 0
		for identity, entry in hash_table.iterate(&states.table, &place) {
			if !entry_was_shown(states, entry) || !rect_contains(entry.last_clipped_rect, input.pointer_x, input.pointer_y) {
				continue
			}
			if entry.input_frame == states.frame - 1 && int(entry.last_order) > top_order {
				top_order = int(entry.last_order)
				states.under_pointer = identity
			}
			if entry.scrolls && int(entry.last_order) > top_scroll_order {
				top_scroll_order = int(entry.last_order)
				states.scroll_target = identity
			}
		}
	}
	if input.primary_released && states.held != 0 {
		if states.held == states.under_pointer {
			states.activated = states.held
			if states.held_twice {
				states.activated_twice = states.held
			}
		}
		states.held = 0
		states.held_twice = false
	}
	if input.primary_pressed {
		states.held = states.under_pointer
		states.held_twice = input.primary_press_count >= 2
		states.press_x = input.pointer_x
		states.press_y = input.pointer_y
		states.focused = states.under_pointer
	}
	if !input.primary_down && !input.primary_pressed {
		states.held = 0
		states.held_twice = false
	}
	if input.activate_key && states.focused != 0 {
		states.activated = states.focused
	}
	if input.secondary_pressed {
		states.pressed_secondary = states.under_pointer
	}
	if states.scroll_target != 0 && (input.wheel_x != 0 || input.wheel_y != 0) {
		if entry, found := hash_table.find(&states.table, states.scroll_target); found {
			entry.scroll[.X] = i32(clamp(i64(entry.scroll[.X]) + i64(input.wheel_x), 0, LENGTH_LIMIT))
			entry.scroll[.Y] = i32(clamp(i64(entry.scroll[.Y]) + i64(input.wheel_y), 0, LENGTH_LIMIT))
		}
	}
}

// state_of gives the state of an identity in this frame, and makes a new
// one at the first frame of the identity or after it went stale. The place
// holds until the next call that adds an entry.
state_of :: proc "contextless" (states: ^Box_States, identity: Identity) -> (^Box_State, State_Status) {
	if identity == 0 {
		return nil, .No_Identity
	}
	if entry, found := hash_table.find(&states.table, identity); found {
		if entry_is_stale(states, entry) {
			entry^ = {}
		}
		entry.last_seen_frame = states.frame
		return entry, .Done
	}
	outcome := hash_table.insert(&states.table, identity, Box_State{last_seen_frame = states.frame})
	if outcome == .Full {
		states_remove_stale(states)
		outcome = hash_table.insert(&states.table, identity, Box_State{last_seen_frame = states.frame})
	}
	if outcome == .Full {
		return nil, .Table_Full
	}
	entry, _ := hash_table.find(&states.table, identity)
	return entry, .Done
}

// states_remove_stale removes each entry that no frame saw for STALE_FRAMES
// frames, and gives the count removed.
states_remove_stale :: proc "contextless" (states: ^Box_States) -> int {
	removed := 0
	place := 0
	for identity, entry in hash_table.iterate(&states.table, &place) {
		if entry_is_stale(states, entry) {
			hash_table.remove(&states.table, identity)
			removed += 1
		}
	}
	return removed
}

// box_input gives what the input of this frame does to the box of an
// identity. A box asks once in a frame: a second ask is refused, because
// two boxes with one identity would take one press.
box_input :: proc "contextless" (states: ^Box_States, identity: Identity) -> (Box_Input, State_Status) {
	entry, status := state_of(states, identity)
	if status != .Done {
		return {}, status
	}
	if entry.input_frame == states.frame && states.frame != 0 {
		return {}, .Identity_Taken
	}
	entry.input_frame = states.frame
	input := states.input
	result := Box_Input {
		under_pointer     = states.under_pointer == identity,
		held              = states.held == identity && input.primary_down,
		activated         = states.activated == identity,
		activated_twice   = states.activated_twice == identity,
		pressed_secondary = states.pressed_secondary == identity,
		focused           = states.focused == identity,
	}
	if result.held {
		result.drag_x = input.pointer_x - states.press_x
		result.drag_y = input.pointer_y - states.press_y
		result.dragging = result.drag_x != 0 || result.drag_y != 0
	}
	if states.scroll_target == identity {
		result.scrolled_x = input.wheel_x
		result.scrolled_y = input.wheel_y
	}
	return result, .Done
}

// states_record keeps the rects of the solved tree of this frame for the
// input of the next frame, and the scroll offsets that the solver clamped.
// A box with no identity keeps nothing. It gives the count of boxes whose
// state the full table refused.
states_record :: proc "contextless" (states: ^Box_States, tree: ^Box_Tree) -> int {
	refused := 0
	boxes := tree_boxes(tree)
	for index in 1 ..= min(tree.count, len(boxes) - 1) {
		box := &boxes[index]
		if box.identity == 0 {
			continue
		}
		entry, status := state_of(states, box.identity)
		if status != .Done {
			refused += 1
			continue
		}
		entry.last_rect = box.rect
		entry.last_clipped_rect = box.clipped_rect
		entry.last_order = u32(index)
		entry.scrolls = box.overflow[.X] == .Scroll || box.overflow[.Y] == .Scroll
		entry.scroll = box.scroll
	}
	return refused
}
