#+build !freestanding
package palette

import "core:slice"
import "core:strings"
import "core:testing"
import "modus:contract/draw_record"
import "modus:contract/palette_table"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:kind_icons"
import "modus:line_editor"

@(private = "file")
MODULE_NAMES := [?]string{"boot", "pages", "log", "console", "monitor", "plasma", "life", "paint", "sample", "clock"}

// A panel and its list, in one allocation: the panel is its first field.
@(private = "file")
Panel_Memory :: struct {
	panel:   Panel,
	list:    List,
	storage: []u8,
}

@(private = "file")
panel_make_sized :: proc(provider_capacity, total_capacity: int) -> ^Panel {
	memory := new(Panel_Memory)
	bytes, ok := list_memory_bytes(provider_capacity, total_capacity)
	assert(ok)
	memory.storage = make([]u8, int(bytes))
	bound := list_bind_memory(&memory.list, memory.storage, provider_capacity, total_capacity)
	assert(bound)
	memory.panel.list = &memory.list
	memory.panel.pressed_row = NO_ROW
	return &memory.panel
}

@(private = "file")
panel_make :: proc() -> ^Panel {
	return panel_make_sized(palette_table.INITIAL_ENTRY_CAPACITY, palette_table.INITIAL_ENTRY_CAPACITY + 128)
}

@(private = "file")
panel_free :: proc(panel: ^Panel) {
	memory := (^Panel_Memory)(panel)
	delete(memory.storage)
	free(memory)
}

// A panel with the modules above and the windows console (in front) and
// plasma.
@(private = "file")
panel_of_test :: proc(panel: ^Panel) {
	panel.pressed_row = NO_ROW
	entries_collect(panel, MODULE_NAMES[:], {{title = "console", number = 3, focus = true}, {title = "plasma", number = 7}})
}

@(private = "file")
type_text :: proc(panel: ^Panel, text: string) {
	for character in text {
		if _, text_changed := typed_edit(panel, .Character, character); text_changed {
			list_build(panel)
		}
	}
}

// The row of the list as "name (kind)", or the heading in brackets.
@(private = "file")
row_text :: proc(panel: ^Panel, row: int) -> string {
	item := panel.list.rows[row]
	switch item.kind {
	case .Heading_Recent:
		return "[recent]"
	case .Heading_Windows:
		return "[windows]"
	case .Heading_Modules:
		return "[modules]"
	case .Entry:
		entry := &panel.list.entries[item.entry]
		parts := [?]string{entry_name(entry), " (", kind_words(entry.kind), ")"}
		buffer := make([]u8, 128, context.temp_allocator)
		count := 0
		for part in parts {
			count += copy(buffer[count:], part)
		}
		return string(buffer[:count])
	}
	return ""
}

// Each state with each key: the whole table of key_action.
@(test)
each_key_in_each_state :: proc(t: ^testing.T) {
	for key in Key {
		testing.expect_value(t, key_action(.Closed, key), key == .Super ? Action.Open : Action.None)
	}
	search := [Key]Action {
		.Other     = .None,
		.Super     = .Close,
		.Escape    = .Close,
		.Enter     = .Run,
		.Up        = .Choose_Previous,
		.Down      = .Choose_Next,
		.Page_Up   = .Choose_Page_Before,
		.Page_Down = .Choose_Page_After,
		.Left      = .Edit,
		.Right     = .Edit,
		.Home      = .Edit,
		.End       = .Edit,
		.Backspace = .Edit,
		.Delete    = .Edit,
		.Character = .Edit,
		.Tab           = .None,
		.Shift_Tab     = .None,
		.Control_Enter = .Open_In_Console,
		.Shift_Enter   = .Go_To,
		.Select_Left   = .Edit,
		.Select_Right  = .Edit,
		.Select_Home   = .Edit,
		.Select_End    = .Edit,
		.Select_All    = .Edit,
		.Copy          = .Copy,
		.Cut           = .Cut,
		.Paste         = .Paste,
	}
	for key in Key {
		testing.expectf(t, key_action(.Search, key) == search[key], "Search, %v: %v", key, key_action(.Search, key))
	}
	// The question: Enter confirms, the key super closes, each other key
	// only goes back: it never edits and never destroys.
	for key in Key {
		expected := Action.Back
		#partial switch key {
		case .Enter:
			expected = .Confirm
		case .Super:
			expected = .Close
		}
		testing.expectf(t, key_action(.Confirm, key) == expected, "Confirm, %v: %v", key, key_action(.Confirm, key))
	}
}

// The state that follows each action.
@(test)
the_state_after_each_action :: proc(t: ^testing.T) {
	testing.expect_value(t, state_after(.Closed, .Open, .Nothing), State.Search)
	testing.expect_value(t, state_after(.Search, .Close, .Runs), State.Closed)
	testing.expect_value(t, state_after(.Confirm, .Close, .Destroys), State.Closed)
	// Enter: an empty list keeps the search, an entry that runs closes the
	// panel, an entry that destroys asks first.
	testing.expect_value(t, state_after(.Search, .Run, .Nothing), State.Search)
	testing.expect_value(t, state_after(.Search, .Run, .Runs), State.Closed)
	testing.expect_value(t, state_after(.Search, .Run, .Destroys), State.Confirm)
	testing.expect_value(t, state_after(.Confirm, .Confirm, .Destroys), State.Closed)
	testing.expect_value(t, state_after(.Confirm, .Back, .Destroys), State.Search)
	// An action that a state does not give changes nothing.
	testing.expect_value(t, state_after(.Search, .Confirm, .Destroys), State.Search)
	testing.expect_value(t, state_after(.Closed, .Run, .Runs), State.Closed)
	for action in ([]Action{.None, .Edit, .Choose_Previous, .Choose_Next, .Choose_Page_Before, .Choose_Page_After}) {
		for state in State {
			testing.expect_value(t, state_after(state, action, .Runs), state)
		}
	}
}

// The entries of the two sources: the windows, the modules, the move of
// the window in front, the closes; the mark of each one says one fact.
@(test)
entries_of_the_two_sources :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	testing.expect_value(t, panel.list.entry_count, 2 + len(MODULE_NAMES) + 1 + 2)
	move := &panel.list.entries[2 + len(MODULE_NAMES)]
	testing.expect_value(t, move.kind, Entry_Kind.Move_Window)
	testing.expect_value(t, entry_name(move), MOVE_WINDOW_NAME)
	testing.expect_value(t, move.number, 3)
	testing.expect(t, !entry_destroys(move))
	testing.expect_value(t, entry_name(&panel.list.entries[0]), "console")
	testing.expect_value(t, panel.list.entries[0].kind, Entry_Kind.Window)
	testing.expect_value(t, panel.list.entries[0].mark, Entry_Mark.Has_Focus)
	testing.expect_value(t, panel.list.entries[0].number, 3)
	testing.expect_value(t, panel.list.entries[1].mark, Entry_Mark.Window)
	for &entry in panel.list.entries[:panel.list.entry_count] {
		if entry.kind != .Module {
			continue
		}
		has_window := entry_name(&entry) == "console" || entry_name(&entry) == "plasma"
		testing.expect_value(t, entry.mark, has_window ? Entry_Mark.Has_Window : Entry_Mark.No_Window)
	}
	last := &panel.list.entries[panel.list.entry_count - 1]
	testing.expect_value(t, entry_name(last), "close plasma")
	testing.expect_value(t, last.kind, Entry_Kind.Close_Window)
	testing.expect_value(t, last.mark, Entry_Mark.Destroys)
	testing.expect_value(t, last.number, 7)
	testing.expect(t, entry_destroys(last))
	testing.expect_value(t, window_title_of(last), "plasma")
}

// The move and the resize by keys are entries of the window in front only:
// no window, windows with no focus, and a fixed window give no resize.
@(test)
the_window_in_front_moves_and_resizes_by_keys :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	count_of :: proc(panel: ^Panel, kind: Entry_Kind) -> (count: int, number: u32) {
		for &entry in panel.list.entries[:panel.list.entry_count] {
			if entry.kind == kind {
				count += 1
				number = entry.number
			}
		}
		return
	}
	// No window: no act on a window.
	entries_collect(panel, MODULE_NAMES[:], nil)
	moves, number := count_of(panel, .Move_Window)
	resizes, _ := count_of(panel, .Resize_Window)
	testing.expect(t, moves == 0 && resizes == 0)
	// Windows, none with the focus, resizable or not: no act either.
	entries_collect(panel, MODULE_NAMES[:], {{title = "console", number = 3, resizable = true}, {title = "plasma", number = 7}})
	moves, _ = count_of(panel, .Move_Window)
	resizes, _ = count_of(panel, .Resize_Window)
	testing.expect(t, moves == 0 && resizes == 0)
	// A fixed window in front moves and does not resize.
	entries_collect(panel, MODULE_NAMES[:], {{title = "plasma", number = 7, focus = true}, {title = "console", number = 3, resizable = true}})
	moves, number = count_of(panel, .Move_Window)
	resizes, _ = count_of(panel, .Resize_Window)
	testing.expect(t, moves == 1 && number == 7 && resizes == 0)
	// A resizable window in front: one move and one resize, of that window.
	entries_collect(panel, MODULE_NAMES[:], {{title = "console", number = 3, focus = true, resizable = true}, {title = "plasma", number = 7}})
	moves, number = count_of(panel, .Move_Window)
	testing.expect(t, moves == 1 && number == 3)
	resizes, number = count_of(panel, .Resize_Window)
	testing.expect(t, resizes == 1 && number == 3)
	testing.expect_value(t, panel.list.entry_count, 2 + len(MODULE_NAMES) + FRONT_WINDOW_ENTRY_COUNT + 2)
	// The two lead a typed match of their names, and say what they are.
	panel.state = .Search
	type_text(panel, "resize window")
	testing.expect_value(t, panel.list.entries[panel.list.rows[0].entry].kind, Entry_Kind.Resize_Window)
	testing.expect_value(t, kind_words(.Move_Window), "move by keys")
	testing.expect_value(t, kind_words(.Resize_Window), "resize by keys")
}

// A name is whole or absent: a name longer than its room is not listed,
// and an empty one is not listed.
@(test)
a_name_too_long_is_not_listed :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	long: [NAME_CAPACITY + 1]u8
	for &character in long {
		character = 'a'
	}
	names := [?]string{"clock", string(long[:]), "", string(long[:NAME_CAPACITY])}
	entries_collect(panel, names[:], nil)
	testing.expect_value(t, panel.list.entry_count, 2)
	testing.expect_value(t, entry_name(&panel.list.entries[1]), string(long[:NAME_CAPACITY]))
	testing.expect_value(t, panel.list.entries[1].number, 3)
}

// One ranked list over the two kinds: with equal scores a window comes
// before the module of the same name, and the close comes last.
@(test)
one_ranked_list_over_the_kinds :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	type_text(panel, "pla")
	testing.expect_value(t, panel.list.row_count, 3)
	testing.expect_value(t, panel.list.matched_count, 3)
	testing.expect_value(t, row_text(panel, 0), "plasma (window)")
	testing.expect_value(t, row_text(panel, 1), "plasma (module)")
	testing.expect_value(t, row_text(panel, 2), "close plasma (close a window)")
	testing.expect_value(t, panel.choice, 0)
	// The matched characters of each name: the places that the row marks.
	testing.expect_value(t, panel.list.rows[0].places, line_editor.Match_Places{0, 1, 2})
	testing.expect_value(t, panel.list.rows[2].places, line_editor.Match_Places{6, 7, 8})
	// The match is fuzzy: the characters in their order, not side by side.
	line_editor.line_clear(&panel.line)
	type_text(panel, "closepla")
	testing.expect_value(t, panel.list.row_count, 1)
	testing.expect_value(t, row_text(panel, 0), "close plasma (close a window)")
	testing.expect_value(t, chosen_of(panel), Chosen.Destroys)
	// No entry has the part: no row, no choice.
	line_editor.line_clear(&panel.line)
	type_text(panel, "xyz")
	testing.expect_value(t, panel.list.row_count, 0)
	testing.expect_value(t, panel.choice, NO_ROW)
	testing.expect_value(t, chosen_of(panel), Chosen.Nothing)
	testing.expect(t, chosen_entry(panel) == nil)
}

// A recent choice comes first among equal scores. Its frecency bonus, at
// most line_editor.FRECENCY_BONUS_LIMIT points, never passes a match with
// one more start of a word or one more run.
@(test)
a_recent_choice_wins_a_tie_only :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	for &entry in panel.list.entries[:panel.list.entry_count] {
		if entry.kind == .Module && (entry_name(&entry) == "paint" || entry_name(&entry) == "sample") {
			recent_note(panel, &entry)
		}
	}
	panel_of_test(panel)
	// "p": each name that starts with p has one score; the recent one first,
	// then the window, then the modules in the order of their table.
	type_text(panel, "p")
	testing.expect_value(t, row_text(panel, 0), "paint (module)")
	testing.expect_value(t, row_text(panel, 1), "plasma (window)")
	testing.expect_value(t, row_text(panel, 2), "pages (module)")
	testing.expect_value(t, row_text(panel, 3), "plasma (module)")
	// "pl": plasma holds it at its start, sample in its middle. sample is
	// the newest choice, and still comes after each plasma.
	type_text(panel, "l")
	testing.expect_value(t, row_text(panel, 0), "plasma (window)")
	testing.expect_value(t, row_text(panel, 1), "plasma (module)")
	testing.expect_value(t, row_text(panel, 2), "sample (module)")
}

// Each run counts in the frecency of the panel, and a used entry passes a
// match that differs only by a gap: "abc" gives abxc 93 points and axxbc
// 92, and one run of axxbc adds 4. The close of a window counts nothing.
@(test)
the_frecency_of_the_runs :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	names := [?]string{"abxc", "axxbc"}
	entries_collect(panel, names[:], {{title = "w"}})
	type_text(panel, "abc")
	testing.expect_value(t, row_text(panel, 0), "abxc (module)")
	testing.expect_value(t, row_text(panel, 1), "axxbc (module)")
	recent_note(panel, &panel.list.entries[2]) // axxbc
	testing.expect_value(t, line_editor.frecency_bonus(&panel.frecency, "axxbc"), 4)
	recent_note(panel, &panel.list.entries[panel.list.entry_count - 1]) // close w
	testing.expect_value(t, line_editor.frecency_score(&panel.frecency, "close w"), 0)
	entries_collect(panel, names[:], {{title = "w"}})
	testing.expect_value(t, row_text(panel, 0), "axxbc (module)")
	testing.expect_value(t, row_text(panel, 1), "abxc (module)")
	// The places stay the places of the match.
	testing.expect_value(t, panel.list.rows[0].places, line_editor.Match_Places{0, 3, 4})
}

// With no typed part: the windows, the front one first, then the modules
// in the order of their table, each group under its heading. No recent
// choice: no group "recent". The closes show only for a typed part.
@(test)
the_first_open_shows_groups :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	testing.expect_value(t, panel.list.row_count, 1 + 2 + 1 + len(MODULE_NAMES))
	testing.expect_value(t, row_text(panel, 0), "[windows]")
	testing.expect_value(t, row_text(panel, 1), "console (window)")
	testing.expect_value(t, row_text(panel, 2), "plasma (window)")
	testing.expect_value(t, row_text(panel, 3), "[modules]")
	testing.expect_value(t, row_text(panel, 4), "boot (module)")
	testing.expect_value(t, panel.choice, 1)
	testing.expect_value(t, panel.list.matched_count, 2 + len(MODULE_NAMES))
	for row in panel.list.rows[:panel.list.row_count] {
		testing.expect(t, row.kind != .Entry || panel.list.entries[row.entry].kind != .Close_Window)
	}
	// After a choice: the group "recent" is first, the newest choice first.
	recent_note(panel, &panel.list.entries[2 + 5]) // plasma, the module.
	recent_note(panel, &panel.list.entries[1]) // plasma, the window.
	panel_of_test(panel)
	testing.expect_value(t, row_text(panel, 0), "[recent]")
	testing.expect_value(t, row_text(panel, 1), "plasma (window)")
	testing.expect_value(t, row_text(panel, 2), "plasma (module)")
	testing.expect_value(t, row_text(panel, 3), "[windows]")
	testing.expect_value(t, panel.choice, 1)
}

// With no window, the list starts with the modules.
@(test)
no_window_no_group :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	entries_collect(panel, MODULE_NAMES[:], nil)
	testing.expect_value(t, row_text(panel, 0), "[modules]")
	testing.expect_value(t, panel.choice, 1)
	entries_collect(panel, nil, nil)
	testing.expect_value(t, panel.list.row_count, 0)
	testing.expect_value(t, panel.choice, NO_ROW)
	testing.expect(t, !choice_move(panel, .Next))
}

// The choice goes from the last entry to the first and back, and never
// stops on a heading. The rows shown always hold it.
@(test)
the_choice_wraps_and_skips_headings :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	last := panel.list.row_count - 1
	testing.expect_value(t, panel.choice, 1)
	testing.expect(t, choice_move(panel, .Previous))
	testing.expect_value(t, panel.choice, last)
	testing.expect(t, panel.choice >= panel.first_row && panel.choice < panel.first_row + LIST_ROWS)
	testing.expect(t, choice_move(panel, .Next))
	testing.expect_value(t, panel.choice, 1)
	// The first entry is chosen: its heading shows over it.
	testing.expect_value(t, panel.first_row, 0)
	// Down from the last window: over the heading of the modules.
	testing.expect(t, choice_move(panel, .Next))
	testing.expect_value(t, panel.choice, 2)
	testing.expect(t, choice_move(panel, .Next))
	testing.expect_value(t, panel.choice, 4)
	testing.expect(t, choice_move(panel, .Previous))
	testing.expect_value(t, panel.choice, 2)
	// Each row of a whole turn is an entry, and the view holds it.
	for _ in 0 ..< panel.list.row_count {
		choice_move(panel, .Next)
		testing.expect(t, row_is_entry(panel, panel.choice))
		testing.expect(t, panel.choice >= panel.first_row && panel.choice < panel.first_row + LIST_ROWS)
	}
}

// A page moves the choice by 11 rows and does not wrap.
@(test)
a_page_does_not_wrap :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	last := panel.list.row_count - 1 // 13: the list has 14 rows.
	testing.expect(t, choice_move(panel, .Page_After))
	testing.expect_value(t, panel.choice, 1 + PAGE_ROWS)
	testing.expect(t, choice_move(panel, .Page_After))
	testing.expect_value(t, panel.choice, last)
	testing.expect(t, !choice_move(panel, .Page_After))
	testing.expect_value(t, panel.choice, last)
	testing.expect(t, panel.choice < panel.first_row + LIST_ROWS)
	testing.expect(t, choice_move(panel, .Page_Before))
	testing.expect_value(t, panel.choice, last - PAGE_ROWS)
	// A page up from near the top stops at the first entry, under its heading.
	testing.expect(t, choice_move(panel, .Page_Before))
	testing.expect_value(t, panel.choice, 1)
	testing.expect_value(t, panel.first_row, 0)
	testing.expect(t, !choice_move(panel, .Page_Before))
	// A page that lands on a heading takes the entry after it.
	panel.choice = 1
	entries_collect(panel, MODULE_NAMES[:], {{title = "a"}, {title = "b"}, {title = "c"}, {title = "d"}, {title = "e"}, {title = "f"}, {title = "g"}, {title = "h"}, {title = "i"}, {title = "j"}, {title = "k"}})
	testing.expect_value(t, panel.list.rows[1 + PAGE_ROWS].kind, Row_Kind.Heading_Modules)
	testing.expect(t, choice_move(panel, .Page_After))
	testing.expect_value(t, panel.choice, 2 + PAGE_ROWS)
}

// The typed part: the keys of the line edit it, the list follows, and a
// character past its room is refused.
@(test)
the_typed_part :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	drawn, text_changed := typed_edit(panel, .Character, 'p')
	testing.expect(t, drawn && text_changed)
	drawn, text_changed = typed_edit(panel, .Left, 0)
	testing.expect(t, drawn && !text_changed)
	drawn, text_changed = typed_edit(panel, .Left, 0)
	testing.expect(t, !drawn && !text_changed, "the caret is at the start")
	typed_edit(panel, .Character, 's')
	testing.expect_value(t, typed_text(panel), "sp")
	typed_edit(panel, .End, 0)
	drawn, text_changed = typed_edit(panel, .Backspace, 0)
	testing.expect(t, drawn && text_changed)
	testing.expect_value(t, typed_text(panel), "s")
	drawn, _ = typed_edit(panel, .Other, 0)
	testing.expect(t, !drawn)
	drawn, _ = typed_edit(panel, .Character, 7)
	testing.expect(t, !drawn, "a byte that the font does not draw")
	line_editor.line_clear(&panel.line)
	for _ in 0 ..< TYPED_CAPACITY + 8 {
		typed_edit(panel, .Character, 'a')
	}
	testing.expect_value(t, len(typed_text(panel)), TYPED_CAPACITY)
	// The close empties the typed part and makes the list of the next open.
	panel.state = .Search
	panel_close(panel)
	list_build(panel)
	testing.expect_value(t, panel.state, State.Closed)
	testing.expect_value(t, typed_text(panel), "")
	testing.expect_value(t, row_text(panel, 0), "[windows]")
}

// The remembered choices: the newest first, a choice made again moves to
// the front, the oldest one leaves a full table, an entry that destroys is
// not remembered.
@(test)
the_remembered_choices :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	names: [RECENT_CAPACITY + 4]string
	letters := "abcdefghijklmnopqrstuvwxyz"
	for &name, index in names {
		name = letters[index:index + 1]
	}
	entries_collect(panel, names[:], {{title = "w"}})
	for index in 0 ..< len(names) {
		recent_note(panel, &panel.list.entries[1 + index])
	}
	testing.expect_value(t, panel.recent_count, RECENT_CAPACITY)
	testing.expect_value(t, recent_age(panel, .Module, names[len(names) - 1]), 1)
	testing.expect_value(t, recent_age(panel, .Module, names[0]), 0)
	testing.expect_value(t, recent_age(panel, .Module, names[4]), RECENT_CAPACITY)
	// The oldest one, chosen again, is the newest; each other is one older.
	recent_note(panel, &panel.list.entries[1 + 4])
	testing.expect_value(t, recent_age(panel, .Module, names[4]), 1)
	testing.expect_value(t, recent_age(panel, .Module, names[len(names) - 1]), 2)
	testing.expect_value(t, panel.recent_count, RECENT_CAPACITY)
	// A kind is a part of the choice: the window w is not the module w.
	testing.expect_value(t, recent_age(panel, .Window, names[4]), 0)
	recent_note(panel, &panel.list.entries[panel.list.entry_count - 1]) // close w
	testing.expect_value(t, recent_age(panel, .Close_Window, "close w"), 0)
	testing.expect_value(t, recent_age(panel, .Module, names[4]), 1)
}

// A panel that asks for a second Enter goes back to the search when its
// entries change: the entry that it showed can be gone.
@(test)
new_entries_end_the_question :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	panel.state = .Confirm
	entries_collect(panel, MODULE_NAMES[:], nil)
	testing.expect_value(t, panel.state, State.Search)
	panel.state = .Closed
	entries_collect(panel, MODULE_NAMES[:], nil)
	testing.expect_value(t, panel.state, State.Closed)
}

// The parts of the panel under the pointer, and the row at a point.
@(test)
the_parts_under_the_pointer :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	panel_open(panel) // The pointer finds a row of an open panel only.
	x, y := panel_place(1024)
	testing.expect_value(t, x, 192)
	testing.expect_value(t, y, 96)
	narrow_x, _ := panel_place(320)
	testing.expect_value(t, narrow_x, 0)
	// The middle, to the pixel: no screen moves the panel to a step of 8.
	for width in ([]int{0, PANEL_WIDTH - 1, PANEL_WIDTH, PANEL_WIDTH + 1}) {
		edge_x, _ := panel_place(width)
		testing.expectf(t, edge_x == 0, "a screen of %d puts the panel at %d", width, edge_x)
	}
	odd_x, _ := panel_place(PANEL_WIDTH + 2)
	testing.expect_value(t, odd_x, 1)
	middle_x, _ := panel_place(1036)
	testing.expect_value(t, middle_x, (1036 - PANEL_WIDTH) / 2)
	testing.expect_value(t, part_at(x, y, x - 1, y), Part.Outside)
	testing.expect_value(t, part_at(x, y, x, y - 1), Part.Outside)
	testing.expect_value(t, part_at(x, y, x + PANEL_WIDTH, y), Part.Outside)
	testing.expect_value(t, part_at(x, y, x, y + PANEL_HEIGHT), Part.Outside)
	testing.expect_value(t, part_at(x, y, x, y), Part.Input_Band)
	testing.expect_value(t, part_at(x, y, x + PANEL_WIDTH - 1, y + INPUT_BAND_HEIGHT - 1), Part.Input_Band)
	testing.expect_value(t, part_at(x, y, x + 8, y + INPUT_BAND_HEIGHT), Part.List)
	testing.expect_value(t, part_at(x, y, x + 8, y + DETAIL_TOP), Part.Rest)
	testing.expect_value(t, part_at(x, y, x + 8, y + PANEL_HEIGHT - 1), Part.Rest)
	testing.expect_value(t, row_at(panel, x, y, x + 8, y + LIST_TOP), 0)
	testing.expect_value(t, row_at(panel, x, y, x + 8, y + LIST_TOP + ROW_HEIGHT), 1)
	testing.expect_value(t, row_at(panel, x, y, x + 8, y + LIST_TOP + LIST_HEIGHT - 1), LIST_ROWS - 1)
	testing.expect_value(t, row_at(panel, x, y, x, y + LIST_TOP), NO_ROW) // The border.
	testing.expect_value(t, row_at(panel, x, y, x + 8, y + 8), NO_ROW) // The input band.
	// The pointer chooses an entry, and never a heading.
	testing.expect(t, !choice_set(panel, 0))
	testing.expect(t, !choice_set(panel, 1), "the row is the choice already")
	testing.expect(t, choice_set(panel, 2))
	testing.expect(t, !choice_set(panel, NO_ROW))
	testing.expect_value(t, panel.choice, 2)
	// Under the last row of a short list: no row.
	type_text(panel, "pla")
	testing.expect_value(t, row_at(panel, x, y, x + 8, y + LIST_TOP + 3 * ROW_HEIGHT), NO_ROW)
}

@(private = "file")
SCREEN_WIDTH :: 1024
@(private = "file")
SCREEN_HEIGHT :: 768
@(private = "file")
OUTSIDE_COLOR :: 0x123456 // A color that no record of the panel draws.

@(private = "file")
Screen :: struct {
	records: [768]interface.Draw_Record, // As the compositor has: the rows, the rectangles of their icons, and the buttons of the setting rows.
	text:    [6144]u8,
	table:   interface.Draw_Table,
	pixels:  []graphics.Color,
	canvas:  graphics.Canvas,
}

@(private = "file")
screen_make :: proc() -> ^Screen {
	screen := new(Screen)
	screen.table = {records = screen.records[:], text = screen.text[:]}
	screen.pixels = make([]graphics.Color, SCREEN_WIDTH * SCREEN_HEIGHT)
	screen.canvas = {pixels = raw_data(screen.pixels), width = SCREEN_WIDTH, height = SCREEN_HEIGHT, stride = SCREEN_WIDTH}
	return screen
}

@(private = "file")
screen_free :: proc(screen: ^Screen) {
	delete(screen.pixels)
	free(screen)
}

// The draw records of a panel, in the table of a screen.
@(private = "file")
panel_build :: proc(screen: ^Screen, panel: ^Panel) {
	state: interface.Interface_State
	input: interface.Input
	frame := interface.frame_begin(&screen.table, &state, &input)
	x, y := panel_place(SCREEN_WIDTH)
	panel_draw(&frame, panel, x, y)
	interface.frame_end(&frame)
}

@(private = "file")
pixel :: proc(screen: ^Screen, x, y: int) -> graphics.Color {
	return screen.pixels[y * SCREEN_WIDTH + x]
}

// The geometry of the panel, on a drawn canvas. The input band is flush
// with the top, the left and the right edge of the panel: its fill is the
// first pixel at each of the three edges, and no pixel of a border is
// there. The line of 2 pixels under it goes from edge to edge. The rest
// has a border of 1 pixel at the left, the right and the bottom, and none
// at its top. No pixel is drawn outside the panel.
@(test)
the_input_band_is_flush_with_three_edges :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	panel_open(panel)
	for typed in ([]string{"", "pla"}) {
		line_editor.line_clear(&panel.line)
		list_build(panel)
		type_text(panel, typed)
		screen := screen_make()
		defer screen_free(screen)
		graphics.clear(screen.canvas, OUTSIDE_COLOR)
		panel_build(screen, panel)
		testing.expect(t, !screen.table.full, "the draw table holds the panel")
		interface.execute(&screen.table, screen.canvas)
		x, y := panel_place(SCREEN_WIDTH)
		right := x + PANEL_WIDTH - 1
		line_top := y + INPUT_BAND_HEIGHT - 2
		// The top edge: each pixel of the first row is the fill of the band.
		for column in x ..= right {
			if pixel(screen, column, y) != graphics.colors.track {
				testing.expectf(t, false, "typed %q: the top row at x %d is %06x, not the fill of the band", typed, column, u32(pixel(screen, column, y)))
				break
			}
		}
		// The left and the right edge of the band: the fill, on each row.
		for row in y ..< line_top {
			if pixel(screen, x, row) != graphics.colors.track || pixel(screen, right, row) != graphics.colors.track {
				testing.expectf(t, false, "typed %q: an edge of the band at y %d is %06x and %06x, not its fill", typed, row, u32(pixel(screen, x, row)), u32(pixel(screen, right, row)))
				break
			}
		}
		// The line of 2 pixels, from edge to edge.
		for row in line_top ..< line_top + 2 {
			for column in x ..= right {
				if pixel(screen, column, row) != graphics.colors.title {
					testing.expectf(t, false, "typed %q: the line under the band at %d,%d is %06x", typed, column, row, u32(pixel(screen, column, row)))
					break
				}
			}
		}
		// Under the band: a border at the left, the right and the bottom;
		// the pixel inside it is the surface of a card, also on the first
		// row: the rest has no border at its top.
		body_top := y + INPUT_BAND_HEIGHT
		bottom := y + PANEL_HEIGHT - 1
		// With no typed part the first row is a heading, on the surface of
		// the card; with a typed part it is the chosen row. A list with
		// more rows than the panel shows has its scroll bar between
		// the rows and the right border: the row ends before the bar.
		inside_color := graphics.Color(typed == "" ? graphics.colors.card_top : graphics.colors.chosen)
		bar_width := panel.list.row_count > LIST_ROWS ? interface.LIST_ROW_SCROLL_WIDTH : 0
		testing.expect_value(t, bar_width, typed == "" ? interface.LIST_ROW_SCROLL_WIDTH : 0)
		testing.expect_value(t, pixel(screen, x + BORDER, body_top), inside_color)
		testing.expect_value(t, pixel(screen, right - BORDER - bar_width, body_top), inside_color)
		for row in body_top ..= bottom {
			left_pixel, right_pixel := pixel(screen, x, row), pixel(screen, right, row)
			border := interface_border_color(row - body_top, PANEL_HEIGHT - INPUT_BAND_HEIGHT)
			if left_pixel != border || right_pixel != border {
				testing.expectf(t, false, "typed %q: the border at y %d is %06x and %06x, not %06x", typed, row, u32(left_pixel), u32(right_pixel), u32(border))
				break
			}
		}
		for column in x ..= right {
			if pixel(screen, column, bottom) != pixel(screen, x, bottom) {
				testing.expectf(t, false, "typed %q: the bottom border at x %d is %06x", typed, column, u32(pixel(screen, column, bottom)))
				break
			}
		}
		testing.expect(t, pixel(screen, x + 8, bottom - 1) != pixel(screen, x, bottom), "the row over the bottom border is the surface of the card")
		// Nothing around the panel: the pixels beside each edge keep their color.
		for column in x - 1 ..= right + 1 {
			testing.expect_value(t, pixel(screen, column, y - 1), graphics.Color(OUTSIDE_COLOR))
			testing.expect_value(t, pixel(screen, column, bottom + 1), graphics.Color(OUTSIDE_COLOR))
		}
		for row in y ..= bottom {
			testing.expect_value(t, pixel(screen, x - 1, row), graphics.Color(OUTSIDE_COLOR))
			testing.expect_value(t, pixel(screen, right + 1, row), graphics.Color(OUTSIDE_COLOR))
		}
	}
}

// The color of the border of the panel on one row: the gradient of a
// border of a card, as the execution of a vertical gradient computes it.
// The test draws the same record alone and reads its pixel, so it holds no
// arithmetic of its own.
@(private = "file")
interface_border_color :: proc(row, height: int) -> graphics.Color {
	records: [1]interface.Draw_Record
	table := interface.Draw_Table{records = records[:]}
	interface.draw_vertical_gradient(&table, 0, 0, 1, height, graphics.shade(graphics.colors.kernel, 28), graphics.shade(graphics.colors.kernel, 14))
	pixels := make([]graphics.Color, height, context.temp_allocator)
	interface.execute(&table, {pixels = raw_data(pixels), width = 1, height = height, stride = 1})
	return pixels[row]
}

// The typed part is at scale 2: the caret is 4 pixels wide and 32 high, in
// the blue of the title bar, 16 pixels from the left edge when the part is
// empty, and one cell of 16 pixels farther for each character.
@(test)
the_caret_follows_the_typed_part :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	panel_open(panel)
	x, y := panel_place(SCREEN_WIDTH)
	for typed, count in ([]string{"", "p", "pl"}) {
		line_editor.line_clear(&panel.line)
		type_text(panel, typed)
		screen := screen_make()
		defer screen_free(screen)
		panel_build(screen, panel)
		caret_x := x + interface.TEXT_INPUT_LINE_MARGIN + count * graphics.CELL_WIDTH * INPUT_SCALE
		found := false
		for record in screen.table.records[:screen.table.record_count] {
			// In the input band only: under it, a part of the icon of a
			// window can have the same color and the same width.
			place, color, is_rectangle := rectangle_of_record(record)
			if is_rectangle && color == graphics.colors.title && place.right - place.left == 2 * INPUT_SCALE && place.top < y + INPUT_BAND_HEIGHT - 2 {
				found = true
				testing.expect_value(t, place.left, caret_x)
				testing.expect_value(t, place.top, y + (INPUT_BAND_HEIGHT - graphics.CELL_HEIGHT * INPUT_SCALE) / 2)
				testing.expect_value(t, place.bottom - place.top, graphics.CELL_HEIGHT * INPUT_SCALE)
			}
		}
		testing.expectf(t, found, "typed %q: the panel has a caret", typed)
	}
}

// The icon of each entry: its form is the kind of the entry, or the act
// of an entry that destroys; its color is the color of the kind when the
// thing is there or in use, and the quiet color when it is not.
@(test)
the_icon_of_each_entry :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	table := table_make(GIVEN[:])
	defer delete(table)
	testing.expect_value(t, collect_with_table(panel, table), palette_table.Problem.None)
	window_icon := kind_icons.cells_of_desktop_kind(.Window)
	setting_icon := kind_icons.cells_of_desktop_kind(.Setting)
	export_icon := kind_icons.cells_of_desktop_kind(.Export)
	stop_icon := kind_icons.cells_of_desktop_kind(.Stop)
	module_icon := kind_icons.cells_of_value_kind(.Module)
	command_icon := kind_icons.cells_of_value_kind(.Command)
	grant_icon := kind_icons.cells_of_value_kind(.Grant)
	module_color := graphics.value_kind_color(.Module, graphics.appearance)
	command_color := graphics.value_kind_color(.Command, graphics.appearance)
	Expected :: struct {
		kind:  Entry_Kind,
		name:  string,
		icon:  ^kind_icons.Cells,
		color: graphics.Color,
	}
	expected := [?]Expected {
		{.Window, "console", window_icon, graphics.colors.title}, // It has the focus.
		{.Module, "console", module_icon, module_color}, // It has a window.
		{.Module, "plasma", module_icon, icon_color_quiet()}, // It has no window.
		{.Close_Window, "close console", stop_icon, icon_color_of_stop()},
		{.Command, "memory", command_icon, command_color},
		{.Command, "stop", command_icon, icon_color_quiet()}, // It needs arguments: the panel asks nothing yet.
		{.Command, "shutdown", stop_icon, icon_color_of_stop()}, // It destroys: the icon of the act, not of the kind.
	}
	for item in expected {
		found := false
		for &entry in panel.list.entries[:panel.list.entry_count] {
			if entry.kind != item.kind || entry_name(&entry) != item.name {
				continue
			}
			found = true
			cells, cells_color := entry_icon(&entry, false)
			testing.expectf(t, cells == item.icon && cells_color == item.color, "%s (%v): the icon is %p in %06x", item.name, item.kind, cells, cells_color)
		}
		testing.expectf(t, found, "the list has %s (%v)", item.name, item.kind)
	}
	// Each entry of the list has an icon, in a color of the icons.
	for &entry in panel.list.entries[:panel.list.entry_count] {
		cells, cells_color := entry_icon(&entry, false)
		testing.expectf(t, cells != nil && cells_color != 0, "%s has no icon", entry_name(&entry))
	}
	// A window that has not the focus, a setting and an export.
	other_window := Entry{kind = .Window, mark = .Window}
	setting := Entry{kind = .Setting}
	export_entry := Entry{kind = .Export}
	export_with_parameters := Entry{kind = .Export, flags = {.Needs_Arguments}}
	icon, color := entry_icon(&other_window, false)
	testing.expect(t, icon == window_icon && color == icon_color_quiet())
	icon, color = entry_icon(&setting, true)
	testing.expect(t, icon == setting_icon && color == graphics.colors.text)
	icon, color = entry_icon(&setting, false)
	testing.expect(t, icon == setting_icon && color == icon_color_quiet())
	icon, color = entry_icon(&export_entry, false)
	testing.expect(t, icon == export_icon && color == module_color)
	icon, color = entry_icon(&export_with_parameters, false)
	testing.expect(t, icon == export_icon && color == icon_color_quiet())
	// The candidates of a field of a form.
	icon, color = candidate_icon(.Process)
	testing.expect(t, icon == module_icon && color == module_color)
	icon, color = candidate_icon(.Module)
	testing.expect(t, icon == module_icon && color == module_color)
	icon, color = candidate_icon(.Grant)
	testing.expect(t, icon == grant_icon && color == graphics.value_kind_color(.Grant, graphics.appearance))
	icon, _ = candidate_icon(.None)
	testing.expect(t, icon == nil)
}

// set_cells_of counts the cells of an icon.
@(private = "file")
set_cells_of :: proc(icon: ^kind_icons.Cells) -> (count: int) {
	for cell_y in 0 ..< kind_icons.ICON_SIZE {
		for cell_x in 0 ..< kind_icons.ICON_SIZE {
			count += kind_icons.cell_is_set(icon, cell_x, cell_y) ? 1 : 0
		}
	}
	return
}

// Each row that the panel shows has the icon of its entry at its left, in
// the box of 12 pixels before the name: each cell once, in the color of
// the entry, and in white on the chosen row and on the row that asks for
// a second Enter. A heading has none.
@(test)
each_row_shows_the_icon_of_its_entry :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	panel_open(panel)
	screen := screen_make()
	defer screen_free(screen)
	x, y := panel_place(SCREEN_WIDTH)
	rows_checked := 0
	check :: proc(t: ^testing.T, screen: ^Screen, panel: ^Panel, panel_x, panel_y: int, what: string) -> (entries: int) {
		panel_build(screen, panel)
		testing.expectf(t, !screen.table.full, "%s: the draw table holds the panel and its icons", what)
		for shown in 0 ..< min(panel.list.row_count - panel.first_row, LIST_ROWS) {
			row := panel.list.rows[panel.first_row + shown]
			box_left := panel_x + BORDER + interface.LIST_ROW_ICON_X
			box_top := panel_y + LIST_TOP + shown * ROW_HEIGHT + (ROW_HEIGHT - interface.LIST_ROW_ICON_SIZE) / 2
			icon: ^kind_icons.Cells
			color: graphics.Color
			if row.kind == .Entry {
				icon, color = entry_icon(&panel.list.entries[row.entry], false)
				if panel.first_row + shown == panel.choice {
					color = graphics.COLOR_WHITE
				}
				entries += 1
			}
			pixels, others := 0, 0
			for record in screen.table.records[:screen.table.record_count] {
				place, record_color, is_rectangle := rectangle_of_record(record)
				if !is_rectangle || place.left < box_left || place.top < box_top || place.right > box_left + interface.LIST_ROW_ICON_SIZE || place.bottom > box_top + interface.LIST_ROW_ICON_SIZE {
					continue
				}
				if icon != nil && record_color == color {
					pixels += (place.right - place.left) * (place.bottom - place.top)
				} else {
					others += 1
				}
			}
			testing.expectf(t, pixels == set_cells_of(icon) && others == 0, "%s, row %d: %d pixels of the icon for %d cells, and %d other rectangles in its box", what, shown, pixels, set_cells_of(icon), others)
		}
		return
	}
	// The groups: windows and modules, with and without a window.
	rows_checked += check(t, screen, panel, x, y, "no typed part")
	// One ranked list of windows, modules and the close of a window.
	type_text(panel, "pla")
	rows_checked += check(t, screen, panel, x, y, "pla")
	// The row that asks for a second Enter.
	line_editor.line_clear(&panel.line)
	type_text(panel, "closepla")
	panel.state = state_after(panel.state, key_action(panel.state, .Enter), chosen_of(panel))
	testing.expect_value(t, panel.state, State.Confirm)
	rows_checked += check(t, screen, panel, x, y, "the question")
	testing.expect(t, rows_checked >= 12)
}

// What the rows say: the chosen row is filled with the chosen blue and
// has the hint of its kind; the row that asks for a second Enter is in the
// color of "stop a process" and says the act in full.
@(test)
the_chosen_row_and_the_question :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	panel_open(panel)
	type_text(panel, "closepla")
	screen := screen_make()
	defer screen_free(screen)
	x, y := panel_place(SCREEN_WIDTH)
	has_text :: proc(table: ^interface.Draw_Table, text: string) -> bool {
		for record in table.records[:table.record_count] {
			if found, _, is_text := interface.text_of_record(table, record); is_text && strings.contains(found, text) {
				return true
			}
		}
		return false
	}
	row_fill :: proc(table: ^interface.Draw_Table, panel_x, panel_y: int) -> (color: graphics.Color, found: bool) {
		for record in table.records[:table.record_count] {
			place, fill, is_rectangle := rectangle_of_record(record)
			if is_rectangle && place.left == panel_x + BORDER && place.top == panel_y + LIST_TOP && place.bottom - place.top == ROW_HEIGHT {
				return fill, true
			}
		}
		return 0, false
	}
	panel_build(screen, panel)
	color, found := row_fill(&screen.table, x, y)
	testing.expect(t, found)
	testing.expect_value(t, color, graphics.Color(graphics.colors.chosen))
	testing.expect(t, has_text(&screen.table, "close plasma"))
	// The chosen row keeps its kind; the footer says what Enter does, and
	// counts the entries in a plain word.
	testing.expect(t, has_text(&screen.table, "close a window"))
	testing.expect(t, has_text(&screen.table, "enter: close   esc: close"))
	testing.expect(t, has_text(&screen.table, "1 of 15"))
	testing.expect(t, has_text(&screen.table, "entries"))
	testing.expect(t, has_text(&screen.table, NOTE_NO_PROVIDER))
	testing.expect(t, has_text(&screen.table, "Stops the process plasma: its window closes. Asks for a second Enter."))
	panel.state = state_after(panel.state, key_action(panel.state, .Enter), chosen_of(panel))
	testing.expect_value(t, panel.state, State.Confirm)
	panel_build(screen, panel)
	color, found = row_fill(&screen.table, x, y)
	testing.expect(t, found)
	testing.expect_value(t, color, graphics.Color(graphics.colors.stop_process))
	testing.expect(t, has_text(&screen.table, "stop plasma: its window closes"))
	testing.expect(t, has_text(&screen.table, KEYS_OF_CONFIRM))
	testing.expect(t, !has_text(&screen.table, "close plasma"))
	// No entry: one line says which part no name has.
	panel.state = .Search
	line_editor.line_clear(&panel.line)
	type_text(panel, "xyz")
	panel_build(screen, panel)
	testing.expect(t, has_text(&screen.table, "nothing has \"xyz\" in its name"))
	testing.expect(t, has_text(&screen.table, "0 of 15"))
	// The first open: the placeholder, and the headings of the groups.
	line_editor.line_clear(&panel.line)
	list_build(panel)
	panel_build(screen, panel)
	testing.expect(t, has_text(&screen.table, PLACEHOLDER))
	testing.expect(t, has_text(&screen.table, HEADING_WINDOWS))
	testing.expect(t, has_text(&screen.table, HEADING_MODULES))
	testing.expect(t, has_text(&screen.table, "enter: to the front"))
	testing.expect(t, has_text(&screen.table, "The window of the process console. It has the focus."))
}

// A panel drawn in the damage of its difference with the panel before is
// the panel drawn whole, pixel for pixel: each key damages what it changes
// and nothing is left of the frame before.
@(test)
the_damage_of_a_key_is_never_too_small :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	panel_open(panel)
	before, now := screen_make(), screen_make()
	defer screen_free(before)
	defer screen_free(now)
	whole := make([]graphics.Color, SCREEN_WIDTH * SCREEN_HEIGHT)
	defer delete(whole)
	graphics.clear(before.canvas, OUTSIDE_COLOR)
	panel_build(before, panel)
	interface.execute(&before.table, before.canvas)
	Step :: struct {
		key:       Key,
		character: rune,
	}
	steps := [?]Step{{.Down, 0}, {.Character, 'p'}, {.Character, 'l'}, {.Down, 0}, {.Backspace, 0}, {.Page_Down, 0}, {.Character, 'x'}, {.Character, 'y'}, {.Backspace, 0}, {.Backspace, 0}, {.Backspace, 0}, {.Up, 0}}
	for step, number in steps {
		#partial switch key_action(panel.state, step.key) {
		case .Edit:
			typed_edit(panel, step.key, step.character)
			list_build(panel)
		case .Choose_Next:
			choice_move(panel, .Next)
		case .Choose_Previous:
			choice_move(panel, .Previous)
		case .Choose_Page_After:
			choice_move(panel, .Page_After)
		}
		panel_build(now, panel)
		damage: interface.Damage
		interface.damage_by_difference(&before.table, &now.table, &damage)
		// The frame before, then the new records in the damage only.
		interface.execute_in_rectangles(&now.table, before.canvas, damage.rectangles[:damage.count])
		whole_canvas := graphics.Canvas{pixels = raw_data(whole), width = SCREEN_WIDTH, height = SCREEN_HEIGHT, stride = SCREEN_WIDTH}
		graphics.clear(whole_canvas, OUTSIDE_COLOR)
		interface.execute(&now.table, whole_canvas)
		// slice.equal compares each pixel: a transmute of a slice of colors to
		// bytes keeps the count of colors, so it compares a quarter of them.
		testing.expectf(t, slice.equal(before.pixels, whole), "step %d (%v): the panel in its damage differs from the whole panel", number, step.key)
		testing.expect(t, interface.draw_table_copy(&before.table, &now.table))
	}
}

// A table of a provider, as the console writes it: the memory of the test.
@(private = "file")
Given :: struct {
	name:       string,
	signature:  string,
	about:      string,
	parameters: u8,
	result:     palette_table.Value_Kind,
	destroys:   bool,
	kinds:      [2]palette_table.Value_Kind,
	names:      [2]string,
	units:      [2]value_kinds.Integer_Unit,
	setting:    bool, // A Provider_Setting entry: one button of a setting row.
	in_use:     bool, // Its flag In_Use: the provider read that the machine uses its value.
}

@(private = "file")
GIVEN := [?]Given {
	{name = "memory", signature = "memory() -> Record", about = "memory and kernel counters", result = .Record},
	{name = "processes", signature = "processes() -> Table", about = "the processes that run", result = .Table},
	{name = "stop", signature = "stop(Text)", about = "stop a process, by name", parameters = 1, destroys = true},
	{name = "shutdown", signature = "shutdown()", about = "stop the machine", destroys = true},
}

@(private = "file")
table_make :: proc(given: []Given) -> []u8 {
	bytes, ok := palette_table.table_bytes_for(u64(len(given)))
	assert(ok)
	memory := make([]u8, int(bytes))
	header := (^palette_table.Header)(raw_data(memory))
	header^ = {magic = palette_table.MAGIC, version = palette_table.VERSION, change_count = 6, entry_count = u32(len(given)), byte_length = bytes}
	for item, index in given {
		entry := (^palette_table.Entry)(&memory[palette_table.ENTRIES_OFFSET + index * size_of(palette_table.Entry)])
		entry.kind = u8(palette_table.Entry_Kind.Command)
		if item.destroys {
			entry.flags = {.Destroys}
		}
		entry.parameter_count = item.parameters
		entry.result = u8(item.result)
		entry.name_length = u8(copy(entry.name[:], item.name))
		entry.signature_length = u8(copy(entry.signature[:], item.signature))
		entry.about_length = u8(copy(entry.about[:], item.about))
		for kind, number in item.kinds {
			entry.parameters[number] = u8(kind)
			entry.parameter_name_lengths[number] = u8(copy(entry.parameter_names[number][:], item.names[number]))
			entry.parameter_units[number] = item.units[number]
		}
		if item.setting {
			entry.kind = u8(palette_table.Entry_Kind.Provider_Setting)
			if item.in_use {
				entry.flags += {.In_Use}
			}
		}
	}
	return memory
}

@(private = "file")
collect_with_table :: proc(panel: ^Panel, table: []u8) -> palette_table.Problem {
	problem, _ := list_collect(panel.list, {}, MODULE_NAMES[:], {{title = "console", number = 3, focus = true}}, table)
	list_build(panel)
	return problem
}

// The entries of a provider join the one ranked list: a command is found
// by its letters, says its kind, and what Enter does on it follows from
// its parameters and from what it destroys.
@(test)
the_entries_of_a_provider :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	table := table_make(GIVEN[:])
	defer delete(table)
	testing.expect_value(t, collect_with_table(panel, table), palette_table.Problem.None)
	testing.expect_value(t, panel.list.provider, Provider_State.Ready)
	testing.expect_value(t, panel.list.snapshot.generation, 6)
	testing.expect_value(t, panel.list.entry_count, 1 + len(MODULE_NAMES) + 1 + 1 + len(GIVEN))
	// With no typed part the commands do not show.
	for row in panel.list.rows[:panel.list.row_count] {
		testing.expect(t, row.kind != .Entry || !entry_of_provider(&panel.list.entries[row.entry]))
	}
	type_text(panel, "mem")
	testing.expect_value(t, row_text(panel, 0), "memory (command)")
	testing.expect_value(t, chosen_of(panel), Chosen.Sends)
	testing.expect_value(t, state_after(.Search, .Run, chosen_of(panel)), State.Running)
	line_editor.line_clear(&panel.line)
	type_text(panel, "stop")
	testing.expect_value(t, row_text(panel, 0), "stop (command)")
	testing.expect_value(t, entry_words(chosen_entry(panel)), "command, needs arguments")
	// A command with parameters opens in the console: the panel closes at
	// once, and asks nothing, also when the command destroys.
	testing.expect_value(t, chosen_of(panel), Chosen.Runs)
	line_editor.line_clear(&panel.line)
	type_text(panel, "shut")
	testing.expect_value(t, chosen_of(panel), Chosen.Destroys_Then_Sends)
	testing.expect_value(t, state_after(.Search, .Run, chosen_of(panel)), State.Confirm)
	testing.expect_value(t, state_after(.Confirm, .Confirm, chosen_of(panel)), State.Running)
	testing.expect_value(t, state_after(.Confirm, .Back, chosen_of(panel)), State.Search)
	// The rows as the panel draws them: the signature after the name, the
	// help sentence in the detail line, the act in full on the row that asks.
	screen := screen_make()
	defer screen_free(screen)
	has :: proc(table: ^interface.Draw_Table, text: string) -> bool {
		for record in table.records[:table.record_count] {
			if found, _, is_text := interface.text_of_record(table, record); is_text && strings.contains(found, text) {
				return true
			}
		}
		return false
	}
	panel.state = .Search
	panel_build(screen, panel)
	testing.expect(t, has(&screen.table, "shutdown") && has(&screen.table, "()") && has(&screen.table, "stop the machine"))
	// The band says the mode of the chosen entry: shutdown destroys.
	testing.expect(t, has(&screen.table, MODE_DESTROY) && !has(&screen.table, NOTE_NO_PROVIDER))
	panel.state = .Confirm
	panel_build(screen, panel)
	testing.expect(t, has(&screen.table, "shutdown(): stop the machine"))
	panel.state = .Running
	sent_set(panel, chosen_entry(panel))
	panel_build(screen, panel)
	testing.expect(t, has(&screen.table, WORDS_OF_RUNNING) && has(&screen.table, KEYS_OF_RUNNING))
}

// A table that fails a check gives a list with the modules and the
// windows only, and its problem: each malformed table is refused.
@(test)
a_hostile_table_gives_no_entry :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	Damage :: struct {
		problem: palette_table.Problem,
		change:  proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header),
	}
	damages := [?]Damage {
		{.Bad_Magic, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {header.magic = 1}},
		{.Bad_Version, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {header.version = 99}},
		{.Bad_Byte_Length, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {header.entry_count = 4096}},
		{.Too_Small, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {
			header.entry_count = 4096
			header.byte_length, _ = palette_table.table_bytes_for(4096)
		}},
		{.Never_Stable, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {header.change_count = 7}},
		{.Bad_Length, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.name_length = 0}},
		{.Bad_Length, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.name_length = 200}},
		{.Bad_Length, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.parameter_count = 200}},
		{.Bad_Length, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.about_length = 255}},
		{.Bad_Byte, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.name[1] = 7}},
		{.Bad_Byte, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.about[0] = 200}},
		{.Bad_Kind, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.kind = u8(max(palette_table.Entry_Kind)) + 1}},
		{.Bad_Kind, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.kind = max(u8)}},
		{.Bad_Kind, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.result = u8(max(palette_table.Value_Kind)) + 1}},
		{.Bad_Kind, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.result = max(u8)}},
		{.Bad_Kind, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.parameters[5] = u8(max(palette_table.Value_Kind)) + 1}},
		{.Bad_Kind, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.parameters[0] = max(u8)}},
		{.Bad_Kind, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.flags = transmute(palette_table.Entry_Flags)u8(0x80)}},
		{.Bad_Signature, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.signature[0] = 'x'}},
		{.Bad_Kind, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.reserved_first = 1}},
		{.Bad_Kind, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.reserved[1] = 9}},
		{.Bad_Setting, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.flags = {.In_Use}}},
		{.Bad_Length, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.parameter_name_lengths[0] = 99}},
	}
	for damage, number in damages {
		table := table_make(GIVEN[:])
		defer delete(table)
		// The second entry: the check reads each entry, not the first only.
		damage.change(table, (^palette_table.Entry)(&table[palette_table.ENTRIES_OFFSET + size_of(palette_table.Entry)]), (^palette_table.Header)(raw_data(table)))
		problem := collect_with_table(panel, table)
		testing.expectf(t, problem == damage.problem, "damage %d: %v, not %v", number, problem, damage.problem)
		testing.expect_value(t, panel.list.provider, Provider_State.Refused)
		testing.expect_value(t, panel.list.entry_count, 1 + len(MODULE_NAMES) + 1 + 1)
		testing.expect_value(t, panel.list.snapshot.entry_count, 0)
	}
	// A memory smaller than a table is no table.
	small := make([]u8, 4096)
	defer delete(small)
	testing.expect_value(t, collect_with_table(panel, small), palette_table.Problem.Too_Small)
	// The footer says what the list lacks.
	screen := screen_make()
	defer screen_free(screen)
	panel_open(panel)
	panel_build(screen, panel)
	found := false
	for record in screen.table.records[:screen.table.record_count] {
		if shown, _, is_text := interface.text_of_record(&screen.table, record); is_text && shown == NOTE_REFUSED_PROVIDER {
			found = true
		}
	}
	testing.expect(t, found)
}

// The keys of the states Running and Result, and what an answer of the
// provider does to a panel.
@(test)
running_and_result :: proc(t: ^testing.T) {
	for key in Key {
		closes := key == .Super || key == .Escape
		testing.expect_value(t, key_action(.Running, key), closes ? Action.Close : Action.None)
		testing.expect_value(t, key_action(.Result, key), closes ? Action.Close : Action.Back)
	}
	testing.expect_value(t, state_after(.Result, .Back, .Nothing), State.Search)
	testing.expect_value(t, state_after(.Running, .Close, .Sends), State.Closed)
	panel := panel_make()
	defer panel_free(panel)
	table := table_make(GIVEN[:])
	defer delete(table)
	collect_with_table(panel, table)
	type_text(panel, "mem")
	sent_set(panel, chosen_entry(panel))
	result_area := table[palette_table.RESULT_OFFSET:][:palette_table.RESULT_CAPACITY]
	write :: proc(area: []u8, lines: [][2]string) -> u64 {
		writer := palette_table.Result_Writer{buffer = area, fits = true}
		for line in lines {
			palette_table.result_run(&writer, .Label, line[0])
			palette_table.result_run(&writer, .Number, line[1])
			palette_table.result_line_end(&writer)
		}
		return u64(writer.count)
	}
	// A panel that waits for no answer takes none.
	panel.state = .Search
	result_set(panel, u64(palette_table.Outcome.Shown_In_Panel), 3, table, 0)
	testing.expect_value(t, panel.state, State.Search)
	// A Record: its lines in the panel.
	length := write(result_area, {{"memory_megabytes  ", "256"}, {"free_megabytes  ", "198"}})
	panel.state = .Running
	result_set(panel, u64(palette_table.Outcome.Shown_In_Panel), u64(palette_table.Value_Kind.Record), table, length)
	testing.expect_value(t, panel.state, State.Result)
	testing.expect_value(t, panel.result.kind, palette_table.Value_Kind.Record)
	screen := screen_make()
	defer screen_free(screen)
	panel_build(screen, panel)
	texts := [?]string{"memory()", "memory_megabytes  ", "256", "free_megabytes  ", "198", KEYS_OF_RESULT}
	for text in texts {
		found := false
		for record in screen.table.records[:screen.table.record_count] {
			if shown, _, is_text := interface.text_of_record(&screen.table, record); is_text && shown == text {
				found = true
			}
		}
		testing.expectf(t, found, "the panel shows %q", text)
	}
	// An Integer: its one number at the largest text size.
	length = write(result_area, {{"", "42"}})
	panel.state = .Running
	result_set(panel, u64(palette_table.Outcome.Shown_In_Panel), u64(palette_table.Value_Kind.Integer), table, length)
	panel_build(screen, panel)
	large := false
	for record in screen.table.records[:screen.table.record_count] {
		if shown, size, is_text := interface.text_of_record(&screen.table, record); is_text && size == interface.font_text_size(interface.FONT_LARGEST) && shown == "42" {
			large = true
		}
	}
	testing.expect(t, large)
	// The window of the provider has the result: the panel closes.
	panel.state = .Running
	result_set(panel, u64(palette_table.Outcome.Shown_In_Console), u64(palette_table.Value_Kind.Table), table, 0)
	testing.expect_value(t, panel.state, State.Closed)
	// A hostile answer: a length past the area, a run past the length, a
	// byte that the font does not draw, a part out of its range, too many
	// lines, an outcome that is none. Each one shows the sentence of the
	// panel itself, and nothing of the area.
	Hostile :: struct {
		outcome: u64,
		length:  u64,
		bytes:   []u8,
	}
	many: [2 * (palette_table.RESULT_LINE_CAPACITY + 1)]u8
	for index in 0 ..< palette_table.RESULT_LINE_CAPACITY + 1 {
		many[2 * index] = u8(palette_table.Run_Part.End_Line)
	}
	hostile := [?]Hostile {
		{1, palette_table.RESULT_CAPACITY + 1, {}},
		{1, 4, {0, 200, 'a', 'b'}},
		{1, 3, {0, 1, 7}},
		{1, 3, {99, 1, 'a'}},
		{1, 1, {0}},
		{1, 2, {255, 3}},
		{1, len(many), many[:]},
		{77, 3, {0, 1, 'a'}},
		{1, 0, {}},
	}
	for item, number in hostile {
		copy(result_area, item.bytes)
		panel.state = .Running
		result_set(panel, item.outcome, 1, table, item.length)
		testing.expectf(t, panel.state == .Result && panel.result.outcome == .Refused, "hostile answer %d is refused", number)
		testing.expect(t, palette_table.result_valid(panel.result.runs[:panel.result.count]))
	}
	// A valid area with a word that names no outcome or no kind: the
	// panel refuses the answer, and the kind of the result before goes.
	valid_length := write(result_area, {{"", "42"}})
	words := [?][2]u64 {
		{u64(max(palette_table.Outcome)) + 1, u64(palette_table.Value_Kind.Integer)},
		{max(u64), u64(palette_table.Value_Kind.Integer)},
		{u64(palette_table.Outcome.Shown_In_Panel), u64(max(palette_table.Value_Kind)) + 1},
		{u64(palette_table.Outcome.Shown_In_Panel), max(u64)},
	}
	for word, number in words {
		panel.state = .Running
		result_set(panel, word[0], word[1], table, valid_length)
		testing.expectf(t, panel.state == .Result && panel.result.outcome == .Refused && panel.result.kind == .None, "the answer of words %d is refused", number)
	}
	// The provider left while the panel waited.
	panel.state = .Running
	result_sentence(panel, "the console stopped")
	testing.expect_value(t, panel.state, State.Result)
}

@(private = "file")
FORMS := [?]Given {
	{name = "revoke", signature = "revoke(name: Text, grant: Text) -> Integer", about = "end a grant of a process that runs", parameters = 2, result = .Integer, destroys = true, kinds = {.Text, .Text}, names = {"name", "grant"}},
	{name = "repeat", signature = "repeat(Text, Integer) -> Text", about = "a text, several times", parameters = 2, result = .Text, kinds = {.Text, .Integer}},
	{name = "where", signature = "where(Table, Text, Text) -> Table", about = "the rows of a table", parameters = 3, result = .Table, kinds = {.Table, .Text}},
	{name = "set font to vector", signature = "set font to vector", about = "settings.set(font = .vector)", setting = true},
	{name = "set font to spleen", signature = "set font to spleen", about = "settings.set(font = .spleen)", setting = true, in_use = true},
	{name = "start", signature = "start(Text)", about = "start a process", parameters = 1, kinds = {.Text, .None}},
}

// The form of an entry: its fields from the record of the provider, the
// order of Tab, what each kind takes, the check, and the typed values that
// go to the provider.
@(test)
the_form_of_an_entry :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	table := table_make(FORMS[:])
	defer delete(table)
	collect_with_table(panel, table)
	// A parameter that no field can give: no form, the console has it.
	type_text(panel, ">where")
	testing.expect_value(t, chosen_of(panel), Chosen.Runs)
	line_editor.line_clear(&panel.line)
	type_text(panel, "repeat")
	testing.expect_value(t, chosen_of(panel), Chosen.Opens_Form)
	testing.expect_value(t, state_after(.Search, .Run, chosen_of(panel)), State.Arguments)
	form_open(panel, chosen_entry(panel))
	form := &panel.form
	testing.expect_value(t, panel.state, State.Arguments)
	testing.expect_value(t, form.field_count, 2)
	testing.expect_value(t, chosen_of(panel), Chosen.Form_Sends)
	// A Text field takes each character but a quote.
	for character in "ab" {
		form_field_edit(panel, .Character, character)
	}
	drawn, leave := form_field_edit(panel, .Character, '"')
	testing.expect(t, drawn && !leave)
	testing.expect_value(t, field_text(form, 0), "ab")
	testing.expect_value(t, form_message(form), "a text holds no quote")
	// Enter in a field that is not the last one goes to the next field.
	ready, moved := form_submit(panel, false)
	testing.expect(t, !ready && moved)
	testing.expect_value(t, form.current, 1)
	testing.expect_value(t, form_message(form), "")
	// An Integer field refuses a letter, and says so; it takes a sign at
	// its start only.
	form_field_edit(panel, .Character, 'x')
	testing.expect_value(t, field_text(form, 1), "")
	testing.expect_value(t, form_message(form), "an Integer takes digits, and one - at its start")
	form_field_edit(panel, .Character, '-')
	form_field_edit(panel, .Character, '3')
	form_field_edit(panel, .Character, '-')
	testing.expect_value(t, field_text(form, 1), "-3")
	// The order of Tab: from the last field to the first, and back.
	testing.expect(t, form_field_move(panel, 1))
	testing.expect_value(t, form.current, 0)
	testing.expect(t, form_field_move(panel, -1))
	testing.expect_value(t, form.current, 1)
	// The typed values: a Text as its bytes, an Integer as a number.
	ready, _ = form_submit(panel, false)
	testing.expect(t, ready)
	parameter, argument, ok := palette_table.argument_unpack(form_argument(form, 0))
	testing.expect(t, ok && parameter == 0 && argument.kind == .Text && string(argument.text[:argument.length]) == "ab")
	parameter, argument, ok = palette_table.argument_unpack(form_argument(form, 1))
	testing.expect(t, ok && parameter == 1 && argument.kind == .Integer && argument.integer == -3)
	testing.expect_value(t, state_after(.Arguments, .Submit, chosen_of(panel)), State.Running)
	// An empty field: the check moves the caret there and says why.
	form_field_move(panel, 1)
	for _ in 0 ..< 2 {
		form_field_edit(panel, .Backspace, 0)
	}
	form_field_move(panel, 1)
	ready, moved = form_submit(panel, true)
	testing.expect(t, !ready && moved)
	testing.expect_value(t, form.current, 0)
	testing.expect_value(t, form_message(form), "empty")
	// Backspace in the first field, empty: back to the search.
	_, leave = form_field_edit(panel, .Backspace, 0)
	testing.expect(t, leave)
	testing.expect_value(t, state_after(.Arguments, .Back, chosen_of(panel)), State.Search)
	// An entry that destroys asks after its arguments, and goes back to
	// its form with the fields kept.
	form_close(panel)
	panel.state = .Search
	line_editor.line_clear(&panel.line)
	type_text(panel, "revoke")
	form_open(panel, chosen_entry(panel))
	testing.expect_value(t, field_name(form, 1), "grant")
	testing.expect_value(t, chosen_of(panel), Chosen.Form_Destroys)
	testing.expect_value(t, state_after(.Arguments, .Submit_All, chosen_of(panel)), State.Confirm)
	testing.expect_value(t, state_after(.Confirm, .Back, chosen_of(panel)), State.Arguments)
	testing.expect_value(t, state_after(.Confirm, .Confirm, chosen_of(panel)), State.Running)
	// The numbers: the bounds of an Integer of 64 bits.
	Number :: struct {
		text:  string,
		value: i64,
		ok:    bool,
	}
	numbers := [?]Number{{"0", 0, true}, {"-0", 0, true}, {"9223372036854775807", max(i64), true}, {"9223372036854775808", 0, false}, {"-9223372036854775808", min(i64), true}, {"-9223372036854775809", 0, false}, {"", 0, false}, {"-", 0, false}, {"1a", 0, false}}
	for number in numbers {
		value, good := integer_of(number.text)
		testing.expectf(t, good == number.ok && (!good || value == number.value), "%q: %v %v", number.text, value, good)
	}
	// The keys of the state.
	testing.expect_value(t, key_action(.Arguments, .Tab), Action.Field_Next)
	testing.expect_value(t, key_action(.Arguments, .Shift_Tab), Action.Field_Previous)
	testing.expect_value(t, key_action(.Arguments, .Enter), Action.Submit)
	testing.expect_value(t, key_action(.Arguments, .Control_Enter), Action.Submit_All)
	testing.expect_value(t, key_action(.Arguments, .Escape), Action.Back)
	testing.expect_value(t, key_action(.Arguments, .Character), Action.Field_Edit)
	testing.expect_value(t, key_action(.Arguments, .Down), Action.Candidate_Next)
	testing.expect_value(t, key_action(.Arguments, .Super), Action.Close)
	// The band of the form, as the panel draws it: the call, and the
	// caret in the current field.
	screen := screen_make()
	defer screen_free(screen)
	for character in "net" {
		form_field_edit(panel, .Character, character)
	}
	panel_build(screen, panel)
	texts := [?]string{"revoke", "name", "net", "grant"}
	for text in texts {
		found := false
		for record in screen.table.records[:screen.table.record_count] {
			if shown, size, is_text := interface.text_of_record(&screen.table, record); is_text && size == INPUT_SIZE && strings.contains(shown, text) {
				found = true
			}
		}
		testing.expectf(t, found, "the band of the form shows %q", text)
	}
}

// The candidates of a field: a checked copy, narrowed by the text of the
// field; Tab takes the chosen one. A hostile area gives none.
@(test)
the_candidates_of_a_field :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	table := table_make(FORMS[:])
	defer delete(table)
	collect_with_table(panel, table)
	type_text(panel, "start")
	form_open(panel, chosen_entry(panel))
	form := &panel.form
	names := [?]string{"console", "plasma", "paint", "life"}
	for name, index in names {
		candidate := (^palette_table.Candidate)(&table[palette_table.CANDIDATES_OFFSET + index * size_of(palette_table.Candidate)])
		candidate.length = u8(copy(candidate.name[:], name))
	}
	form_candidates_set(form, table, u64(len(names)), u64(palette_table.Candidate_Kind.Process))
	testing.expect_value(t, form.shown_count, 4)
	testing.expect_value(t, form.candidate_choice, 0)
	form_field_edit(panel, .Character, 'p')
	testing.expect_value(t, form.shown_count, 2)
	testing.expect_value(t, candidate_name(form, 0), "plasma")
	testing.expect(t, form_candidate_move(form, 1))
	testing.expect_value(t, candidate_name(form, form.candidate_choice), "paint")
	testing.expect(t, form_candidate_move(form, 1))
	testing.expect_value(t, form.candidate_choice, 0)
	testing.expect(t, form_candidate_take(form))
	testing.expect_value(t, field_text(form, 0), "plasma")
	testing.expect(t, !form_candidate_take(form), "the field holds the candidate")
	// A count past the area, a kind out of its range, a name with a byte
	// that the font does not draw: no candidate.
	form_candidates_set(form, table, palette_table.CANDIDATE_CAPACITY + 1, 1)
	testing.expect_value(t, form.candidate_count, 0)
	form_candidates_set(form, table, 4, 99)
	testing.expect_value(t, form.candidate_count, 0)
	table[palette_table.CANDIDATES_OFFSET + 3] = 1
	form_candidates_set(form, table, 4, 1)
	testing.expect_value(t, form.candidate_count, 0)
	testing.expect_value(t, form.candidate_choice, NO_ROW)
}

// A prefix restricts the kinds of the list; the part after it is what the
// names match. A setting says which value is in use.
@(test)
the_prefixes :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	table := table_make(FORMS[:])
	defer delete(table)
	collect_with_table(panel, table)
	kinds_of :: proc(panel: ^Panel) -> (kinds: bit_set[Entry_Kind]) {
		for row in panel.list.rows[:panel.list.row_count] {
			if row.kind == .Entry {
				kinds += {panel.list.entries[row.entry].kind}
			}
		}
		return
	}
	Case :: struct {
		typed: string,
		kinds: bit_set[Entry_Kind],
	}
	cases := [?]Case{{">", {.Command}}, {"@", {.Window, .Close_Window, .Move_Window}}, {":", {.Setting}}, {"?", {.Module}}, {">re", {.Command}}, {"?pla", {.Module}}}
	for item in cases {
		line_editor.line_clear(&panel.line)
		type_text(panel, item.typed)
		testing.expectf(t, kinds_of(panel) == item.kinds, "%q lists %v", item.typed, kinds_of(panel))
		// A prefix alone: no heading, each row is an entry.
		for row in panel.list.rows[:panel.list.row_count] {
			testing.expect_value(t, row.kind, Row_Kind.Entry)
		}
	}
	prefix, rest := prefix_of(":font")
	testing.expect(t, prefix == .Settings && rest == "font")
	prefix, rest = prefix_of("font")
	testing.expect(t, prefix == .None && rest == "font")
	// The matched places are those of the name, not of the typed part
	// with its prefix.
	line_editor.line_clear(&panel.line)
	type_text(panel, ">rev")
	testing.expect_value(t, row_text(panel, 0), "revoke (command)")
	testing.expect_value(t, panel.list.rows[0].places, line_editor.Match_Places{0, 1, 2})
	// With the prefix of the manual, a module is sent to the provider.
	line_editor.line_clear(&panel.line)
	type_text(panel, "?pla")
	testing.expect_value(t, row_text(panel, 0), "plasma (module)")
	testing.expect_value(t, chosen_of(panel), Chosen.Sends)
	// The settings: the value in use says so.
	line_editor.line_clear(&panel.line)
	type_text(panel, ":font")
	testing.expect_value(t, panel.list.row_count, 2)
	testing.expect_value(t, chosen_of(panel), Chosen.Sends)
	testing.expect(t, !setting_in_use(panel, &panel.list.entries[panel.list.rows[0].entry]))
	testing.expect(t, setting_in_use(panel, &panel.list.entries[panel.list.rows[1].entry]))
}

// A signature longer than its room is cut at the end of a parameter, with
// "...", and never inside one.
@(test)
a_signature_is_cut_at_a_parameter :: proc(t: ^testing.T) {
	buffer: [160]u8
	whole := "(name: Text, grant: Text, count: Integer) -> Table(Process)"
	testing.expect_value(t, signature_fit(whole, len(whole), buffer[:]), whole)
	testing.expect_value(t, signature_fit(whole, len(whole) - 1, buffer[:]), "(name: Text, grant: Text, ...)")
	testing.expect_value(t, signature_fit(whole, 30, buffer[:]), "(name: Text, grant: Text, ...)")
	testing.expect_value(t, signature_fit(whole, 29, buffer[:]), "(name: Text, ...)")
	testing.expect_value(t, signature_fit(whole, 16, buffer[:]), "(...)")
	testing.expect_value(t, signature_fit(whole, 4, buffer[:]), "")
	// A comma inside the type of the result is no end of a parameter.
	nested := "(table: Table(Reading, Read)) -> Integer"
	testing.expect_value(t, signature_fit(nested, 20, buffer[:]), "(...)")
}

// The choice is an entry, not a row. A list that comes for the same typed
// part keeps the chosen entry chosen, at the row that it has now. Only an
// entry that left the list moves the choice to the first row, and Enter
// then runs nothing before a frame showed it.
@(test)
the_choice_follows_its_entry :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	panel_open(panel)
	type_text(panel, "pla")
	// plasma (window), plasma (module), close plasma. The input goes
	// down to the module.
	testing.expect(t, choice_move(panel, .Next))
	testing.expect_value(t, row_text(panel, panel.choice), "plasma (module)")
	// The window of plasma closes behind the panel: the module is now
	// the first row, and it is still the chosen entry.
	adoption := entries_collect(panel, MODULE_NAMES[:], {{title = "console", number = 3, focus = true}})
	testing.expect_value(t, adoption, Adoption.Kept)
	testing.expect_value(t, panel.choice, 0)
	testing.expect_value(t, row_text(panel, panel.choice), "plasma (module)")
	testing.expect(t, !panel.choice_undrawn)
	// The same list again: nothing changes, and the owner draws nothing.
	testing.expect_value(t, entries_collect(panel, MODULE_NAMES[:], {{title = "console", number = 3, focus = true}}), Adoption.Same)
	testing.expect_value(t, panel.choice, 0)
	// A window appears: the chosen module goes down one row, and stays
	// chosen there. This is the fault that the rule ends: Enter must not
	// run the row that took the place of the chosen one.
	adoption = entries_collect(panel, MODULE_NAMES[:], {{title = "plasma", number = 7, focus = true}, {title = "console", number = 3}})
	testing.expect_value(t, adoption, Adoption.Kept)
	testing.expect_value(t, panel.choice, 1)
	testing.expect_value(t, row_text(panel, panel.choice), "plasma (module)")
	testing.expect_value(t, entry_name(chosen_entry(panel)), "plasma")
	testing.expect_value(t, chosen_entry(panel).kind, Entry_Kind.Module)
	// The chosen entry leaves the list: the first entry is chosen, and the
	// panel waits for a frame before an action that runs an entry.
	adoption = entries_collect(panel, MODULE_NAMES[:5], {{title = "plasma", number = 7, focus = true}})
	testing.expect_value(t, adoption, Adoption.Moved)
	testing.expect_value(t, panel.choice, 0)
	testing.expect_value(t, row_text(panel, 0), "plasma (window)")
	testing.expect(t, panel.choice_undrawn)
	for action in Action {
		runs := action == .Run || action == .Confirm || action == .Submit || action == .Submit_All || action == .Open_In_Console || action == .Go_To
		testing.expect_value(t, action_runs(action), runs)
	}
	panel_drawn(panel)
	testing.expect(t, !panel.choice_undrawn)
	// A list for a new typed part is the answer to the keys of the input:
	// its first entry is chosen, and Enter means it.
	testing.expect(t, choice_move(panel, .Next))
	type_text(panel, "s")
	testing.expect_value(t, panel.choice, 0)
	testing.expect(t, !panel.choice_undrawn)
	// The question of an entry that destroys follows its entry too: it
	// stays while the entry is in the list, at its new row, and ends when
	// the entry leaves.
	line_editor.line_clear(&panel.line)
	type_text(panel, "close")
	testing.expect_value(t, row_text(panel, panel.choice), "close plasma (close a window)")
	panel.state = .Confirm
	adoption = entries_collect(panel, MODULE_NAMES[:], {{title = "console", number = 3, focus = true}, {title = "plasma", number = 7}})
	testing.expect_value(t, adoption, Adoption.Kept)
	testing.expect_value(t, panel.state, State.Confirm)
	testing.expect_value(t, row_text(panel, panel.choice), "close plasma (close a window)")
	adoption = entries_collect(panel, MODULE_NAMES[:], {{title = "console", number = 3, focus = true}})
	testing.expect_value(t, adoption, Adoption.Moved)
	testing.expect_value(t, panel.state, State.Search)
	testing.expect_value(t, row_text(panel, panel.choice), "close console (close a window)")
	testing.expect(t, panel.choice_undrawn)
	// A closed panel has no choice to keep: its next open shows the first
	// entry.
	panel_close(panel)
	panel_drawn(panel)
	list_build(panel)
	testing.expect_value(t, panel.choice, 1)
	testing.expect(t, !panel.choice_undrawn)
}

// The first row of the list that is an entry, or NO_ROW.
@(private = "file")
first_entry_row :: proc(panel: ^Panel) -> int {
	for row, index in panel.list.rows[:panel.list.row_count] {
		if row.kind == .Entry {
			return index
		}
	}
	return NO_ROW
}

// A panel whose choice a list just moved, with no frame since: the typed
// part is "pla", the chosen module left the list, and the first entry,
// the window of plasma, is chosen and not drawn.
@(private = "file")
panel_with_a_moved_choice :: proc(t: ^testing.T, panel: ^Panel) {
	panel_of_test(panel)
	panel_open(panel)
	type_text(panel, "pla")
	testing.expect(t, choice_move(panel, .Next))
	testing.expect_value(t, row_text(panel, panel.choice), "plasma (module)")
	testing.expect_value(t, entries_collect(panel, MODULE_NAMES[:5], {{title = "plasma", number = 7, focus = true}}), Adoption.Moved)
	testing.expect(t, panel.choice_undrawn)
}

// Keys typed in one batch after a list moved the choice, before any frame:
// a change of the typed part ends the wait for a frame, because the choice
// that no frame showed was of the list before. Enter is then for the list
// of the new typed part (the owner makes it wait for that list), and that
// list chooses its first entry.
@(test)
a_typed_part_forgets_the_choice_that_no_frame_showed :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_with_a_moved_choice(t, panel)
	// A key that moves the caret changes no text: the wait stays.
	drawn, text_changed := typed_edit(panel, .Left, 0)
	testing.expect(t, drawn && !text_changed)
	testing.expect(t, panel.choice_undrawn)
	testing.expect(t, !panel.typed_since_list)
	typed_edit(panel, .End, 0)
	// A character: the wait for a frame ends, and the next list is a list
	// for a new typed part.
	_, text_changed = typed_edit(panel, .Character, 's')
	testing.expect(t, text_changed)
	testing.expect(t, !panel.choice_undrawn)
	testing.expect(t, panel.typed_since_list)
	// The list of "plas" comes, with no frame before it: its first entry is
	// chosen, and Enter runs it.
	testing.expect_value(t, list_build(panel), Adoption.Kept)
	testing.expect(t, first_entry_row(panel) != NO_ROW)
	testing.expect_value(t, panel.choice, first_entry_row(panel))
	testing.expect(t, !panel.choice_undrawn)
	testing.expect(t, !panel.typed_since_list)
}

// The narrow case: after a list moved the choice, one batch moves the
// choice, types a character and erases it. The text is again the text of
// the list shown, and the list that answers the batch has the same
// content. It is still the answer to keys of the input: its first entry is
// chosen, not the entry that the arrow reached with no frame. The list
// after it, with no key between, is the same list.
@(test)
a_text_that_comes_back_still_chooses_the_first_entry :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_with_a_moved_choice(t, panel)
	testing.expect(t, choice_move(panel, .Next))
	testing.expect(t, panel.choice != first_entry_row(panel))
	typed_edit(panel, .Character, 'x')
	typed_edit(panel, .Backspace, 0)
	testing.expect_value(t, typed_text(panel), "pla")
	testing.expect(t, !panel.choice_undrawn)
	testing.expect(t, panel.typed_since_list)
	adoption := entries_collect(panel, MODULE_NAMES[:5], {{title = "plasma", number = 7, focus = true}})
	testing.expect_value(t, adoption, Adoption.Kept)
	testing.expect_value(t, panel.choice, first_entry_row(panel))
	testing.expect(t, !panel.choice_undrawn)
	testing.expect(t, !panel.typed_since_list)
	testing.expect_value(t, entries_collect(panel, MODULE_NAMES[:5], {{title = "plasma", number = 7, focus = true}}), Adoption.Same)
	// With no key, a choice that the arrow moved stays through an equal
	// list.
	testing.expect(t, choice_move(panel, .Next))
	chosen := panel.choice
	testing.expect_value(t, entries_collect(panel, MODULE_NAMES[:5], {{title = "plasma", number = 7, focus = true}}), Adoption.Same)
	testing.expect_value(t, panel.choice, chosen)
}

// Tab before the candidates of a field came waits for them: it never goes
// to the next field while a candidate that it can take is on its way. The
// chosen candidate stays chosen when the text of the field narrows the
// list.
@(test)
tab_waits_for_the_candidates :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	table := table_make(FORMS[:])
	defer delete(table)
	collect_with_table(panel, table)
	type_text(panel, "revoke")
	form_open(panel, chosen_entry(panel))
	form := &panel.form
	// With no request, and no candidate: Tab goes to the next field.
	testing.expect_value(t, form_tab(form), Tab_Effect.Moves)
	// The owner asked: Tab waits, and the caret stays in its field.
	form.candidates_pending = true
	testing.expect_value(t, form_tab(form), Tab_Effect.Waits)
	testing.expect_value(t, form.current, 0)
	names := [?]string{"console", "plasma", "paint"}
	for name, index in names {
		candidate := (^palette_table.Candidate)(&table[palette_table.CANDIDATES_OFFSET + index * size_of(palette_table.Candidate)])
		candidate.length = u8(copy(candidate.name[:], name))
	}
	for character in "pa" {
		form_field_edit(panel, .Character, character)
	}
	// The answer: the wait ends, and Tab takes the candidate that the
	// typed text chose.
	form_candidates_set(form, table, u64(len(names)), u64(palette_table.Candidate_Kind.Process))
	testing.expect(t, !form.candidates_pending)
	testing.expect_value(t, form_tab(form), Tab_Effect.Takes)
	testing.expect_value(t, candidate_name(form, form.candidate_choice), "plasma")
	// The input goes down to paint; one more letter keeps paint chosen,
	// at its new place.
	testing.expect(t, form_candidate_move(form, 1))
	testing.expect_value(t, candidate_name(form, form.candidate_choice), "paint")
	form_field_edit(panel, .Character, 'i')
	testing.expect_value(t, form.shown_count, 1)
	testing.expect_value(t, candidate_name(form, form.candidate_choice), "paint")
	testing.expect(t, form_candidate_take(form))
	testing.expect_value(t, form_tab(form), Tab_Effect.Moves)
	// A move to another field ends the wait for the field before.
	form.candidates_pending = true
	form_field_move(panel, 1)
	testing.expect(t, !form.candidates_pending)
}

// A press in the input band of a form puts the caret in the field under
// the pointer, at the place between two characters that is nearest to it.
// The band is "revoke(name: plasma, grant: )": the name of the command
// takes 7 characters, the value of the first field starts at the character
// 13, the name of the second parameter at 21, and its value at 28.
@(test)
a_press_in_a_field_puts_the_caret_there :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	table := table_make(FORMS[:])
	defer delete(table)
	collect_with_table(panel, table)
	type_text(panel, "revoke")
	form_open(panel, chosen_entry(panel))
	form := &panel.form
	for character in "plasma" {
		form_field_edit(panel, .Character, character)
	}
	x, _ := panel_place(1024)
	text_x := x + interface.TEXT_INPUT_LINE_MARGIN
	// On the name of the command, and left of the text: no field.
	_, _, in_a_field := form_place_at(form, x, text_x + 2 * BAND_CELL_WIDTH + 4)
	testing.expect(t, !in_a_field, "the name of the command is no field")
	_, _, in_a_field = form_place_at(form, x, text_x - 1)
	testing.expect(t, !in_a_field, "the margin is no field")
	// On the name of the first parameter: the start of its field.
	field, caret: int
	field, caret, in_a_field = form_place_at(form, x, text_x + 8 * BAND_CELL_WIDTH + 4)
	testing.expect(t, in_a_field && field == 0 && caret == 0)
	// Between the "l" and the "a" of plasma, 2 pixels left of the edge of
	// the two cells: the caret is after 2 characters.
	field, caret, in_a_field = form_place_at(form, x, text_x + 15 * BAND_CELL_WIDTH - 2)
	testing.expect(t, in_a_field && field == 0)
	testing.expect_value(t, caret, 2)
	// On the comma after the first field: its end.
	field, caret, in_a_field = form_place_at(form, x, text_x + 19 * BAND_CELL_WIDTH + 2)
	testing.expect(t, in_a_field && field == 0)
	testing.expect_value(t, caret, 6)
	// On the name of the second parameter, and on the parenthesis after
	// its empty value: the second field.
	field, caret, in_a_field = form_place_at(form, x, text_x + 23 * BAND_CELL_WIDTH + 4)
	testing.expect(t, in_a_field && field == 1 && caret == 0)
	field, caret, in_a_field = form_place_at(form, x, text_x + 28 * BAND_CELL_WIDTH + 12)
	testing.expect(t, in_a_field && field == 1 && caret == 0)
	// Past the end of the call: no field.
	_, _, in_a_field = form_place_at(form, x, text_x + 31 * BAND_CELL_WIDTH)
	testing.expect(t, !in_a_field, "the band after the call is no field")
	// The caret in the same field: no new candidates, and the next
	// character goes in at the caret.
	testing.expect(t, !form_caret_put(panel, 0, 2))
	testing.expect_value(t, form.fields[0].caret, 2)
	form_field_edit(panel, .Character, 'X')
	testing.expect_value(t, field_text(form, 0), "plXasma")
	// The caret in another field: the candidates of the field before
	// leave, and the typed text is the text of the new field.
	form.candidates_pending = true
	testing.expect(t, form_caret_put(panel, 1, 0))
	testing.expect_value(t, form.current, 1)
	testing.expect(t, !form.candidates_pending)
	form_field_edit(panel, .Character, 'l')
	testing.expect_value(t, field_text(form, 1), "l")
	testing.expect_value(t, field_text(form, 0), "plXasma")
	// A place past the text is cut to its end; a field that the form has
	// not is refused.
	form_caret_put(panel, 0, 99)
	testing.expect_value(t, form.fields[0].caret, 7)
	testing.expect(t, !form_caret_put(panel, 7, 0))
	testing.expect_value(t, form.current, 0)
}

// The scroll bar of the list takes the pointer: a press on its arrow
// button moves the view by one row, and the choice follows the view to
// the nearest entry that it shows. A point on the scroll bar is on no row.
@(test)
the_scroll_bar_moves_the_view_and_the_choice :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	panel_open(panel)
	// Two headings, two windows and ten modules: two rows more than the panel shows.
	testing.expect_value(t, panel.list.row_count, LIST_ROWS + 2)
	x, y := panel_place(1024)
	area, shown := scroll_bar_area(panel, x, y)
	testing.expect(t, shown)
	testing.expect_value(t, area, interface.Area{x + PANEL_WIDTH - BORDER - interface.LIST_ROW_SCROLL_WIDTH, y + LIST_TOP, interface.LIST_ROW_SCROLL_WIDTH, LIST_HEIGHT})
	testing.expect_value(t, row_at(panel, x, y, area.x - 1, y + LIST_TOP + 4), 0)
	testing.expect_value(t, row_at(panel, x, y, area.x, y + LIST_TOP + 4), NO_ROW)
	// A frame with a press on the arrow button at the bottom.
	screen := screen_make()
	defer screen_free(screen)
	state: interface.Interface_State
	press_x, press_y := area.x + area.width / 2, area.y + area.height - 8
	input := interface.Input{pointer_known = true, pointer_x = press_x, pointer_y = press_y, pressed = true, button_held = true, press_x = press_x, press_y = press_y}
	frame := interface.frame_begin(&screen.table, &state, &input)
	panel_draw(&frame, panel, x, y)
	interface.frame_end(&frame)
	testing.expect(t, panel.scrolled.changed)
	testing.expect_value(t, panel.scrolled.first, 1)
	testing.expect_value(t, panel.scrolled.pressed_now, interface.Scroll_Bar_Part.Arrow_Forward)
	testing.expect_value(t, state.pressed, scroll_bar_identity())
	// The choice is the first window, at the row 1: the view from the row
	// 1 still shows it.
	testing.expect_value(t, panel.choice, 1)
	testing.expect(t, view_scrolled(panel))
	testing.expect_value(t, panel.first_row, 1)
	testing.expect_value(t, panel.choice, 1)
	testing.expect(t, !view_scrolled(panel), "what the pointer did is applied one time")
	// The view from the row 2 does not show the choice: it goes to the
	// first entry of the view.
	panel.scrolled = {changed = true, first = 2}
	testing.expect(t, view_scrolled(panel))
	testing.expect_value(t, panel.first_row, 2)
	testing.expect_value(t, panel.choice, 2)
	// The choice on the last row, then the view from the row 0: the
	// choice goes to the last row that the view shows.
	panel.choice = panel.list.row_count - 1
	panel.scrolled = {changed = true, first = 0}
	testing.expect(t, view_scrolled(panel))
	testing.expect_value(t, panel.choice, LIST_ROWS - 1)
	testing.expect(t, row_is_entry(panel, panel.choice))
	// A first row past the list is cut to its last view.
	panel.scrolled = {changed = true, first = 99}
	testing.expect(t, view_scrolled(panel))
	testing.expect_value(t, panel.first_row, 2)
	// A draw with no pointer leaves nothing to apply.
	panel_build(screen, panel)
	testing.expect(t, !view_scrolled(panel))
	// The question of an entry that destroys has no scroll bar that the
	// pointer moves; a list that the panel shows whole has none.
	panel.state = .Confirm
	_, shown = scroll_bar_area(panel, x, y)
	testing.expect(t, !shown)
	panel.state = .Search
	type_text(panel, "pla")
	_, shown = scroll_bar_area(panel, x, y)
	testing.expect(t, !shown)
}

// The candidates of a form: the pointer finds the candidate under it, the
// scroll bar moves their view, and the choice follows the view.
@(test)
the_pointer_on_the_candidates :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	table := table_make(FORMS[:])
	defer delete(table)
	collect_with_table(panel, table)
	type_text(panel, "start")
	x, y := panel_place(1024)
	testing.expect_value(t, candidate_at(panel, x, y, x + 8, y + LIST_TOP + 4), NO_ROW) // No form yet.
	form_open(panel, chosen_entry(panel))
	form := &panel.form
	COUNT :: 20
	for index in 0 ..< COUNT {
		candidate := (^palette_table.Candidate)(&table[palette_table.CANDIDATES_OFFSET + index * size_of(palette_table.Candidate)])
		name := [2]u8{'a' + u8(index), 'x'}
		candidate.length = u8(copy(candidate.name[:], name[:]))
	}
	form_candidates_set(form, table, COUNT, u64(palette_table.Candidate_Kind.Module))
	testing.expect_value(t, form.shown_count, COUNT)
	testing.expect_value(t, candidate_at(panel, x, y, x + 8, y + LIST_TOP + 4), 0)
	testing.expect_value(t, candidate_at(panel, x, y, x + 8, y + LIST_TOP + 3 * ROW_HEIGHT + 4), 3)
	testing.expect_value(t, candidate_at(panel, x, y, x + 8, y + 8), NO_ROW) // The input band.
	area, shown := scroll_bar_area(panel, x, y)
	testing.expect(t, shown)
	testing.expect_value(t, candidate_at(panel, x, y, area.x + 2, y + LIST_TOP + 4), NO_ROW) // The scroll bar.
	// The pointer chooses a candidate; Tab then takes it.
	testing.expect(t, form_candidate_set(form, 3))
	testing.expect(t, !form_candidate_set(form, 3), "the candidate is the choice already")
	testing.expect(t, !form_candidate_set(form, COUNT))
	testing.expect_value(t, candidate_name(form, form.candidate_choice), "dx")
	// The scroll bar moves the view: the choice goes into it.
	panel.scrolled = {changed = true, first = 5}
	testing.expect(t, view_scrolled(panel))
	testing.expect_value(t, candidates_first(form), 5)
	testing.expect_value(t, form.candidate_choice, 5)
	testing.expect_value(t, candidate_at(panel, x, y, x + 8, y + LIST_TOP + 4), 5)
	// The keys move the choice, and the view follows it: from the first
	// candidate to the last one and back.
	form.candidate_choice = 0
	testing.expect(t, form_candidate_move(form, -1))
	testing.expect_value(t, form.candidate_choice, COUNT - 1)
	testing.expect_value(t, candidates_first(form), COUNT - LIST_ROWS)
	testing.expect(t, form_candidate_move(form, 1))
	testing.expect_value(t, candidates_first(form), 0)
	// A text that narrows the candidates to a few: the view starts at
	// the first one.
	panel.scrolled = {changed = true, first = 8}
	view_scrolled(panel)
	form_field_edit(panel, .Character, 'c')
	testing.expect_value(t, form.shown_count, 1)
	testing.expect_value(t, candidates_first(form), 0)
	_, shown = scroll_bar_area(panel, x, y)
	testing.expect(t, !shown)
}

// A value that only the provider knows: the scheduling strategy. Its
// entries are settings for the panel, and the one that the provider marks
// says that the machine uses it.
@(test)
the_strategy_in_use_is_the_mark_of_the_provider :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	given := [?]Given {
		{name = "set strategy to fair", signature = "set strategy to fair", about = "strategy(\"fair\")", result = .Integer},
		{name = "set strategy to eevdf", signature = "set strategy to eevdf", about = "strategy(\"eevdf\")", result = .Integer},
	}
	table := table_make(given[:])
	defer delete(table)
	entries := ([^]palette_table.Entry)(&table[palette_table.ENTRIES_OFFSET])
	entries[0].kind = u8(palette_table.Entry_Kind.Provider_Setting)
	entries[1].kind = u8(palette_table.Entry_Kind.Provider_Setting)
	entries[1].flags = {.In_Use}
	testing.expect_value(t, collect_with_table(panel, table), palette_table.Problem.None)
	// The entry of a row of the list, by its name: the order of two
	// entries of one score is not what this test checks.
	listed :: proc(panel: ^Panel, name: string) -> ^Entry {
		for row in panel.list.rows[:panel.list.row_count] {
			if row.kind == .Entry && entry_name(&panel.list.entries[row.entry]) == name {
				return &panel.list.entries[row.entry]
			}
		}
		return nil
	}
	type_text(panel, ":strat")
	testing.expect_value(t, panel.list.row_count, 2)
	testing.expect_value(t, chosen_of(panel), Chosen.Sends)
	fair := listed(panel, "set strategy to fair")
	eevdf := listed(panel, "set strategy to eevdf")
	if !testing.expect(t, fair != nil && eevdf != nil, "the two strategies are entries of the prefix of the settings") {
		return
	}
	testing.expect_value(t, fair.kind, Entry_Kind.Setting)
	testing.expect(t, !setting_in_use(panel, fair))
	testing.expect(t, setting_in_use(panel, eevdf))
	// The mark is a part of what the panel shows: a table that moves it
	// gives a list with another content, which the panel draws again.
	content_before := panel.list.content
	entries[0].flags = {.In_Use}
	entries[1].flags = {}
	collect_with_table(panel, table)
	testing.expect(t, panel.list.content != content_before)
	testing.expect(t, setting_in_use(panel, listed(panel, "set strategy to fair")))
	testing.expect(t, !setting_in_use(panel, listed(panel, "set strategy to eevdf")))
	// The flag on an entry that is no such setting: the table is refused.
	entries[0].kind = u8(palette_table.Entry_Kind.Command)
	testing.expect_value(t, collect_with_table(panel, table), palette_table.Problem.Bad_Setting)
}

// The texts of the form of an entry, as a provider writes them: its act
// name, the name of its setting row and the name of its value.
@(private = "file")
row_texts_set :: proc(entry: ^palette_table.Entry, act_name, setting_name, value_name: string) {
	entry.act_name_length = u8(copy(entry.act_name[:], act_name))
	entry.setting_name_length = u8(copy(entry.setting_name[:], setting_name))
	entry.value_name_length = u8(copy(entry.value_name[:], value_name))
}

// The entries of one setting, side by side in the table, are one row of
// the list: the name of the setting, then its values. Left and Right
// choose a value; the panel sends the entry of that value. A run of more
// values than a row holds stays entries.
@(test)
the_values_of_one_setting_are_one_row :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	given := [?]Given {
		{name = "memory", signature = "memory() -> Record", about = "memory and kernel counters", result = .Record},
		{name = "set font to vector", signature = "set font to vector", about = "settings.set(font = .vector)", setting = true},
		{name = "set font to spleen", signature = "set font to spleen", about = "settings.set(font = .spleen)", setting = true, in_use = true},
		{name = "set strategy to round_robin", signature = "set strategy to round_robin", about = "strategy(\"round_robin\")"},
		{name = "set strategy to fair", signature = "set strategy to fair", about = "strategy(\"fair\")"},
		{name = "set strategy to eevdf", signature = "set strategy to eevdf", about = "strategy(\"eevdf\")"},
		{name = "set shade to a", signature = "set shade to a", about = "shade(\"a\")"},
		{name = "set shade to b", signature = "set shade to b", about = "shade(\"b\")"},
		{name = "set shade to c", signature = "set shade to c", about = "shade(\"c\")"},
		{name = "set shade to d", signature = "set shade to d", about = "shade(\"d\")"},
		{name = "set shade to e", signature = "set shade to e", about = "shade(\"e\")"},
		{name = "set shade to f", signature = "set shade to f", about = "shade(\"f\")"},
		{name = "set shade to g", signature = "set shade to g", about = "shade(\"g\")"},
	}
	table := table_make(given[:])
	defer delete(table)
	entries := ([^]palette_table.Entry)(&table[palette_table.ENTRIES_OFFSET])
	row_texts_set(&entries[1], "settings.set:font", "font", "vector")
	row_texts_set(&entries[2], "settings.set:font", "font", "spleen")
	strategies := [3]string{"round_robin", "fair", "eevdf"}
	for value, index in strategies {
		entries[3 + index].kind = u8(palette_table.Entry_Kind.Provider_Setting)
		row_texts_set(&entries[3 + index], "strategy", "strategy", value)
	}
	entries[5].flags = {.In_Use}
	shades := [7]string{"a", "b", "c", "d", "e", "f", "g"}
	for value, index in shades {
		entries[6 + index].kind = u8(palette_table.Entry_Kind.Provider_Setting)
		row_texts_set(&entries[6 + index], "shade", "shade", value)
	}
	testing.expect_value(t, collect_with_table(panel, table), palette_table.Problem.None)
	// One window, its move, its close, the modules, the command, two rows,
	// and the seven shades one by one.
	testing.expect_value(t, panel.list.entry_count, 1 + len(MODULE_NAMES) + 1 + 1 + 1 + 2 + 7)
	panel.state = .Search
	type_text(panel, ":font")
	testing.expect_value(t, row_text(panel, 0), "font (setting)")
	row := chosen_entry(panel)
	testing.expect(t, row != nil && entry_is_setting_row(row))
	testing.expect_value(t, row.value_count, 2)
	testing.expect_value(t, row.act, display.act_name_hash("settings.set:font"))
	testing.expect_value(t, value_name(panel.list, row, 0), "vector")
	// The row starts at its value in use.
	testing.expect_value(t, value_chosen(panel, row), 1)
	testing.expect(t, value_in_use(panel, row, 1) && !value_in_use(panel, row, 0))
	testing.expect(t, setting_in_use(panel, row))
	// Left and Right choose a value there; Home still edits the typed part.
	testing.expect_value(t, key_action_for(panel, .Right), Action.Value_Next)
	testing.expect_value(t, key_action_for(panel, .Left), Action.Value_Previous)
	testing.expect_value(t, key_action_for(panel, .Home), Action.Edit)
	testing.expect(t, value_move(panel, 1))
	testing.expect_value(t, value_chosen(panel, row), 0)
	// Enter sends the entry of the chosen value, by its own name: the
	// provider checks it as one entry.
	number, name := entry_sent(panel, row)
	testing.expect_value(t, number, 1)
	testing.expect_value(t, name, "set font to vector")
	testing.expect_value(t, chosen_of(panel), Chosen.Sends)
	sent_set(panel, row)
	testing.expect_value(t, sent_text(panel), "set font to vector")
	// A new list for the same typed part keeps the value on its row.
	list_build(panel)
	testing.expect_value(t, value_chosen(panel, chosen_entry(panel)), 0)
	// The row as the panel draws it: the name, one button for each value,
	// the mode in the band, and the line that the chosen value runs.
	screen := screen_make()
	defer screen_free(screen)
	has :: proc(table: ^interface.Draw_Table, text: string) -> bool {
		for record in table.records[:table.record_count] {
			if found, _, is_text := interface.text_of_record(table, record); is_text && found == text {
				return true
			}
		}
		return false
	}
	panel_build(screen, panel)
	testing.expect(t, has(&screen.table, "font") && has(&screen.table, "vector") && has(&screen.table, "spleen"))
	// The band: the word of the prefix, then the mode.
	testing.expect(t, has(&screen.table, "settings" + MODE_GAP + MODE_RUN))
	testing.expect(t, has(&screen.table, "settings.set(font = .vector)"))
	testing.expect(t, !screen.table.full)
	// A press on a button finds its row and its value, by the layout that
	// the drawing used.
	x, y := panel_place(SCREEN_WIDTH)
	buttons := value_buttons_layout(&screen.table, panel.list, row, row_area(panel, x, y, panel.choice), entry_words(row))
	testing.expect_value(t, buttons.count, 2)
	testing.expect(t, buttons.areas[0].x + buttons.areas[0].width <= buttons.areas[1].x)
	pressed_row, pressed_value := value_at(panel, &screen.table, x, y, buttons.areas[1].x + 2, buttons.areas[1].y + 2)
	testing.expect_value(t, pressed_row, panel.choice)
	testing.expect_value(t, pressed_value, 1)
	pressed_row, pressed_value = value_at(panel, &screen.table, x, y, x + interface.LIST_ROW_NAME_X + 1, buttons.areas[1].y + 2)
	testing.expect_value(t, pressed_value, NO_ROW)
	// The strategies: a row of three, at the value that the provider marks.
	line_editor.line_clear(&panel.line)
	type_text(panel, ":strategy")
	strategy := chosen_entry(panel)
	testing.expect(t, strategy != nil && entry_is_setting_row(strategy))
	testing.expect_value(t, entry_name(strategy), "strategy")
	testing.expect_value(t, strategy.value_count, 3)
	testing.expect_value(t, value_chosen(panel, strategy), 2)
	// Seven shades are more than a row holds: seven entries.
	line_editor.line_clear(&panel.line)
	type_text(panel, ":set shade")
	testing.expect_value(t, panel.list.matched_count, 7)
	for listed in panel.list.rows[:panel.list.row_count] {
		testing.expect(t, !entry_is_setting_row(&panel.list.entries[listed.entry]))
	}
	testing.expect_value(t, key_action_for(panel, .Right), Action.Edit)
	// The next open starts the font at its value in use again.
	panel_close(panel)
	testing.expect_value(t, panel.value_row_length, 0)
}

// The control of a field comes from the field: a few closed values are a
// row of buttons, more closed values and suggestions are a list, and a
// field with no candidate is typed. Enter takes the chosen button.
@(test)
the_control_of_a_field :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	given := [?]Given {
		{name = "strategy", signature = "strategy(name: Text) -> Integer", about = "set the scheduling strategy", parameters = 1, result = .Integer, kinds = {.Text, .None}, names = {"name", ""}},
		{name = "repeat", signature = "repeat(Text, Integer) -> Text", about = "a text, several times", parameters = 2, result = .Text, kinds = {.Text, .Integer}},
	}
	table := table_make(given[:])
	defer delete(table)
	collect_with_table(panel, table)
	panel.state = .Search
	type_text(panel, "strategy")
	form_open(panel, chosen_entry(panel))
	testing.expect_value(t, panel.state, State.Arguments)
	form := &panel.form
	testing.expect_value(t, field_control(form, 0), Field_Control.Text)
	names := [?]string{"round_robin", "fair", "eevdf", "four", "five", "six", "seven"}
	for name, index in names {
		candidate := (^palette_table.Candidate)(&table[palette_table.CANDIDATES_OFFSET + index * size_of(palette_table.Candidate)])
		candidate.length = u8(copy(candidate.name[:], name))
	}
	form_candidates_set(form, table, 3, u64(palette_table.Candidate_Kind.Strategy), palette_table.CANDIDATES_CLOSED)
	testing.expect_value(t, field_control(form, 0), Field_Control.Buttons)
	testing.expect_value(t, key_action_for(panel, .Right), Action.Candidate_Next)
	testing.expect_value(t, key_action_for(panel, .Home), Action.Field_Edit)
	// Suggestions are a list, also when they are few.
	form_candidates_set(form, table, 3, u64(palette_table.Candidate_Kind.Strategy), 0)
	testing.expect_value(t, field_control(form, 0), Field_Control.Candidate_List)
	testing.expect_value(t, key_action_for(panel, .Right), Action.Field_Edit)
	// More closed values than a row holds are a list.
	form_candidates_set(form, table, u64(len(names)), u64(palette_table.Candidate_Kind.Strategy), palette_table.CANDIDATES_CLOSED)
	testing.expect_value(t, field_control(form, 0), Field_Control.Candidate_List)
	// A fact that the contract does not know: no candidate.
	form_candidates_set(form, table, 3, u64(palette_table.Candidate_Kind.Strategy), 2)
	testing.expect_value(t, form.candidate_count, 0)
	testing.expect_value(t, field_control(form, 0), Field_Control.Text)
	// Right chooses fair, and Enter takes it before the form runs.
	form_candidates_set(form, table, 3, u64(palette_table.Candidate_Kind.Strategy), palette_table.CANDIDATES_CLOSED)
	testing.expect(t, form_candidate_move(form, 1))
	ready, _ := form_submit(panel, false)
	testing.expect(t, ready)
	testing.expect_value(t, field_text(form, 0), "fair")
	// The buttons as the panel draws them, in the band or under it, each
	// with its whole name.
	screen := screen_make()
	defer screen_free(screen)
	panel_build(screen, panel)
	x, y := panel_place(SCREEN_WIDTH)
	buttons := form_buttons_layout(&screen.table, form, x, y)
	testing.expect(t, buttons.count >= 1)
	for area in buttons.areas[:buttons.count] {
		testing.expect(t, area.x >= x && area.x + area.width <= x + PANEL_WIDTH - TEXT_MARGIN)
	}
	// An Integer field with no candidate is typed as an Integer.
	form_close(panel)
	panel.state = .Search
	line_editor.line_clear(&panel.line)
	type_text(panel, "repeat")
	form_open(panel, chosen_entry(panel))
	testing.expect_value(t, field_control(&panel.form, 1), Field_Control.Integer)
	testing.expect_value(t, field_control(&panel.form, 0), Field_Control.Text)
}

// An Integer that counts a size or a time shows the unit of the entry
// after its number: in the band, also while the field is empty, and in the
// prompt under it. A press on the unit puts the caret after the number, and
// the panel sends the number as it was typed.
@(test)
a_number_with_its_unit :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	given := [?]Given {
		{name = "buffer", signature = "buffer(count: Integer) -> Handle", about = "a new memory object, in pages", parameters = 1, result = .Handle, kinds = {.Integer, .None}, names = {"count", ""}, units = {value_kinds.size_in(.Pages), {}}},
		{name = "wait_stop", signature = "wait_stop(milliseconds: Integer) -> Table", about = "wait for a stop", parameters = 1, result = .Table, kinds = {.Integer, .None}, names = {"milliseconds", ""}, units = {value_kinds.time_in(.Milliseconds), {}}},
	}
	table := table_make(given[:])
	defer delete(table)
	testing.expect_value(t, collect_with_table(panel, table), palette_table.Problem.None)
	panel.state = .Search
	type_text(panel, "buffer")
	form_open(panel, chosen_entry(panel))
	testing.expect_value(t, panel.state, State.Arguments)
	form := &panel.form
	testing.expect_value(t, field_control(form, 0), Field_Control.Number_With_Unit)
	testing.expect_value(t, field_unit_text(form, 0), " pages")
	band: Band_Layout
	form_band_layout(form, &band)
	testing.expect_value(t, string(band.characters[:band.count]), "buffer(count:  pages)")
	form_field_edit(panel, .Character, '4')
	form_band_layout(form, &band)
	testing.expect_value(t, string(band.characters[:band.count]), "buffer(count: 4 pages)")
	testing.expect_value(t, band.classes[14], Band_Class.Value)
	testing.expect_value(t, band.classes[16], Band_Class.Size_Unit)
	// A unit is no digit: the field holds the number alone.
	testing.expect_value(t, field_text(form, 0), "4")
	x, _ := panel_place(SCREEN_WIDTH)
	text_x := x + interface.TEXT_INPUT_LINE_MARGIN
	field, caret, in_a_field := form_place_at(form, x, text_x + 18 * BAND_CELL_WIDTH + 4)
	testing.expect(t, in_a_field)
	testing.expect_value(t, field, 0)
	testing.expect_value(t, caret, 1)
	argument := form_argument(form, 0)
	_, value, ok := palette_table.argument_unpack(argument)
	testing.expect(t, ok)
	testing.expect_value(t, value.integer, 4)
	// The panel draws the unit as one text, and the prompt says it.
	screen := screen_make()
	defer screen_free(screen)
	form_field_edit(panel, .Backspace, 0)
	panel_build(screen, panel)
	unit_found, prompt_found := false, false
	for record in screen.table.records[:screen.table.record_count] {
		text, _, is_text := interface.text_of_record(&screen.table, record)
		if !is_text {
			continue
		}
		unit_found ||= text == " pages"
		prompt_found ||= strings.contains(text, "an Integer, in pages")
	}
	testing.expect(t, unit_found)
	testing.expect(t, prompt_found)
	// A time has the unit of a time.
	form_close(panel)
	panel.state = .Search
	line_editor.line_clear(&panel.line)
	type_text(panel, "wait_stop")
	form_open(panel, chosen_entry(panel))
	form_band_layout(&panel.form, &band)
	testing.expect_value(t, string(band.characters[:band.count]), "wait_stop(milliseconds:  ms)")
	testing.expect_value(t, band.classes[band.count - 2], Band_Class.Time_Unit)
}

// A press on a button of a field finds the button that the drawing placed,
// and only in a form whose field shows its buttons.
@(test)
a_press_on_a_button_of_a_field :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	given := [?]Given{{name = "strategy", signature = "strategy(name: Text) -> Integer", about = "set the scheduling strategy", parameters = 1, result = .Integer, kinds = {.Text, .None}, names = {"name", ""}}}
	table := table_make(given[:])
	defer delete(table)
	collect_with_table(panel, table)
	panel.state = .Search
	type_text(panel, "strategy")
	form_open(panel, chosen_entry(panel))
	form := &panel.form
	names := [?]string{"round_robin", "fair", "eevdf"}
	for name, index in names {
		candidate := (^palette_table.Candidate)(&table[palette_table.CANDIDATES_OFFSET + index * size_of(palette_table.Candidate)])
		candidate.length = u8(copy(candidate.name[:], name))
	}
	form_candidates_set(form, table, 3, u64(palette_table.Candidate_Kind.Strategy), palette_table.CANDIDATES_CLOSED)
	screen := screen_make()
	defer screen_free(screen)
	panel_build(screen, panel)
	x, y := panel_place(SCREEN_WIDTH)
	buttons := form_buttons_layout(&screen.table, form, x, y)
	testing.expect_value(t, buttons.count, 3)
	for area, index in buttons.areas[:buttons.count] {
		testing.expect_value(t, form_button_at(panel, &screen.table, x, y, area.x + area.width / 2, area.y + area.height / 2), index)
		// The gap after a button is on no button.
		testing.expect_value(t, form_button_at(panel, &screen.table, x, y, area.x + area.width + VALUE_BUTTON_GAP / 2, area.y + area.height / 2), NO_ROW)
	}
	first := buttons.areas[0]
	testing.expect_value(t, form_button_at(panel, &screen.table, x, y, first.x - 1, first.y + first.height / 2), NO_ROW)
	// The press takes the value as Tab does after Left and Right.
	testing.expect(t, form_candidate_move(form, 1))
	testing.expect(t, form_candidate_set(form, 0))
	testing.expect(t, form_candidate_take(form))
	testing.expect_value(t, field_text(form, 0), "round_robin")
	// The search has no field: no button.
	form_close(panel)
	panel.state = .Search
	testing.expect_value(t, form_button_at(panel, &screen.table, x, y, first.x + 2, first.y + 2), NO_ROW)
}

// The act names of a window are checked as values of another process, and
// go to takes the window in front of the others that names the act.
@(test)
the_match_of_an_act_name :: proc(t: ^testing.T) {
	font := display.act_name_hash("settings.set:font")
	strategy := display.act_name_hash("strategy")
	testing.expect(t, font != 0 && strategy != 0 && font != strategy)
	front, ok := act_name_set_of_record({0 = 1, 1 = font})
	testing.expect(t, ok)
	testing.expect_value(t, front.count, 1)
	back: Act_Name_Set
	back, ok = act_name_set_of_record({0 = 2, 1 = font, 2 = strategy})
	testing.expect(t, ok)
	testing.expect(t, act_name_set_has(&back, strategy) && act_name_set_has(&back, font))
	testing.expect(t, !act_name_set_has(&front, strategy))
	testing.expect(t, !act_name_set_has(&back, 0))
	// A count past the record, a hash of 0 in the count, a value after it.
	_, ok = act_name_set_of_record({0 = 7})
	testing.expect(t, !ok)
	_, ok = act_name_set_of_record({0 = 2, 1 = font})
	testing.expect(t, !ok)
	_, ok = act_name_set_of_record({0 = 1, 1 = font, 3 = strategy})
	testing.expect(t, !ok)
	empty, empty_ok := act_name_set_of_record({})
	testing.expect(t, empty_ok && empty.count == 0)
	// The front window first: both name the font, only the back one the
	// strategy; a window that names nothing is passed.
	sets := [?]^Act_Name_Set{nil, &front, &back}
	testing.expect_value(t, act_name_front(sets[:], font), 1)
	testing.expect_value(t, act_name_front(sets[:], strategy), 2)
	testing.expect_value(t, act_name_front(sets[:], display.act_name_hash("grid")), NO_ROW)
	testing.expect_value(t, act_name_front(sets[:], 0), NO_ROW)
	// The panel hashes the act name of an entry of the table as the window
	// hashes the name of its element.
	panel := panel_make()
	defer panel_free(panel)
	given := [?]Given{{name = "set font to spleen", signature = "set font to spleen", about = "settings.set(font = .spleen)", setting = true, in_use = true}}
	table := table_make(given[:])
	defer delete(table)
	row_texts_set((^palette_table.Entry)(&table[palette_table.ENTRIES_OFFSET]), "settings.set:font", "font", "spleen")
	collect_with_table(panel, table)
	panel.state = .Search
	type_text(panel, ":font")
	picked := chosen_entry(panel)
	testing.expect(t, picked != nil && act_name_set_has(&back, picked.act))
	// Shift with Enter goes there, from the search only.
	testing.expect_value(t, key_action(.Search, .Shift_Enter), Action.Go_To)
	testing.expect_value(t, state_after(.Search, .Go_To, chosen_of(panel)), State.Closed)
	testing.expect_value(t, state_after(.Search, .Go_To, .Nothing), State.Search)
	testing.expect_value(t, key_action(.Arguments, .Shift_Enter), Action.None)
	testing.expect(t, action_runs(.Go_To))
	// The band offers it when its owner says that a window names the act.
	screen := screen_make()
	defer screen_free(screen)
	panel.go_to_offered = true
	panel_build(screen, panel)
	found := false
	for record in screen.table.records[:screen.table.record_count] {
		if shown, _, is_text := interface.text_of_record(&screen.table, record); is_text && strings.contains(shown, MODE_GO_TO) {
			found = true
		}
	}
	testing.expect(t, found)
}

// The rectangle and the color of a record of the kind Rectangle, read
// through the border of the draw record; false for another record, for a
// Rectangle with a pattern, which fills no box, and for a color that is not
// opaque. The color is its channels, as a token of the appearance.
@(private = "file")
rectangle_of_record :: proc(record: interface.Draw_Record) -> (place: interface.Rectangle, color: graphics.Color, is_rectangle: bool) {
	primitive, problem := draw_record.read(record)
	fields, is_kind := primitive.(draw_record.Draw_Rectangle)
	if problem != .None || !is_kind || fields.repetition != (draw_record.Repetition{}) || draw_record.alpha_of(fields.color) != 255 {
		return {}, 0, false
	}
	return interface.record_rectangle(record), draw_record.channels_of(fields.color), true
}

// Helper: build a provider table with `count` distinct Command entries named
// "cmd_0000" .. "cmd_{count-1}" in a region sized exactly for `count`.
@(private = "file")
table_make_numbered :: proc(count: int) -> []u8 {
	bytes, ok := palette_table.table_bytes_for(u64(count))
	assert(ok)
	memory := make([]u8, int(bytes))
	header := (^palette_table.Header)(raw_data(memory))
	header^ = {magic = palette_table.MAGIC, version = palette_table.VERSION, change_count = 2, entry_count = u32(count), byte_length = bytes}
	for index in 0 ..< count {
		entry := (^palette_table.Entry)(&memory[palette_table.ENTRIES_OFFSET + index * size_of(palette_table.Entry)])
		entry.kind = u8(palette_table.Entry_Kind.Command)
		entry.result = u8(palette_table.Value_Kind.Integer)
		name_buf: [16]u8
		name_buf[0], name_buf[1], name_buf[2], name_buf[3] = 'c', 'm', 'd', '_'
		v := index
		name_buf[7] = u8('0' + v % 10); v /= 10
		name_buf[6] = u8('0' + v % 10); v /= 10
		name_buf[5] = u8('0' + v % 10); v /= 10
		name_buf[4] = u8('0' + v % 10)
		name := string(name_buf[:8])
		entry.name_length = u8(copy(entry.name[:], name))
		sig_buf: [24]u8
		copy(sig_buf[:8], name)
		sig_buf[8], sig_buf[9] = '(', ')'
		entry.signature_length = u8(copy(entry.signature[:], string(sig_buf[:10])))
		entry.about_length = u8(copy(entry.about[:], "numbered command"))
	}
	return memory
}

// Any count of entries (0, 1, 500, 5000): all entries are collected and ranked
// with SIMD fuzzy matching + frecency, and panel_draw emits O(LIST_ROWS) draw
// records regardless of total entry count.
@(test)
any_count_of_entries_0_1_500_5000 :: proc(t: ^testing.T) {
	screen := screen_make()
	defer screen_free(screen)
	draw_records_by_count: [4]int
	counts := [4]int{0, 1, 500, 5000}
	for count, case_index in counts {
		panel := panel_make_sized(max(count, 1), max(count, 1) + 16)
		defer panel_free(panel)
		table := table_make_numbered(count)
		defer delete(table)
		problem, _ := list_collect(panel.list, panel_uses(panel), nil, nil, table)
		testing.expect_value(t, problem, palette_table.Problem.None)
		testing.expect_value(t, panel.list.provider, Provider_State.Ready)
		testing.expect_value(t, panel.list.entry_count, count)
		// Type ">cmd_" so every provider command matches and enters the ranked list.
		panel_open(panel)
		type_text(panel, ">cmd_")
		testing.expect_value(t, panel.list.matched_count, count)
		testing.expect_value(t, panel.list.row_count, count)
		panel_build(screen, panel)
		draw_records_by_count[case_index] = screen.table.record_count
		if count == 5000 {
			// Verify the last entry (index 4999, well past old 256/512/4096 limits)
			// is found at rank 0 by fuzzy matching.
			line_editor.line_clear(&panel.line)
			type_text(panel, "cmd_4999")
			testing.expect_value(t, panel.list.row_count, 1)
			testing.expect_value(t, entry_name(chosen_entry(panel)), "cmd_4999")
			// Verify frecency boosts a frequently-used deep entry to rank 0.
			recent_note(panel, chosen_entry(panel))
			recent_note(panel, chosen_entry(panel))
			problem2, _ := list_collect(panel.list, panel_uses(panel), nil, nil, table)
			testing.expect_value(t, problem2, palette_table.Problem.None)
			line_editor.line_clear(&panel.line)
			type_text(panel, ">cmd_")
			testing.expect_value(t, panel.list.row_count, 5000)
			testing.expect_value(t, entry_name(chosen_entry(panel)), "cmd_4999")
		}
	}
	// Virtualization bound: 5,000 entries must emit the exact same O(LIST_ROWS)
	// draw record count as 500 entries (bounded well below 300 records).
	testing.expect(t, draw_records_by_count[2] > 0 && draw_records_by_count[3] > 0)
	testing.expect(t, draw_records_by_count[3] <= draw_records_by_count[2] + 8)
	testing.expect(t, draw_records_by_count[3] < 300)
}

// Virtualized viewport scrolling across 5,000 entries: top, negative, middle,
// bottom, and past-end offsets clamp cleanly, draw only the visible window,
// and agree with pointer hit testing (row_at).
@(test)
virtual_viewport_scroll_offsets :: proc(t: ^testing.T) {
	COUNT :: 5000
	panel := panel_make_sized(COUNT, COUNT + 16)
	defer panel_free(panel)
	table := table_make_numbered(COUNT)
	defer delete(table)
	problem, _ := list_collect(panel.list, panel_uses(panel), nil, nil, table)
	testing.expect_value(t, problem, palette_table.Problem.None)
	panel_open(panel)
	type_text(panel, ">cmd_")
	testing.expect_value(t, panel.list.row_count, COUNT)

	screen := screen_make()
	defer screen_free(screen)
	px, py := panel_place(1920)
	Check :: struct {
		requested_first: int,
		expected_first:  int,
		expected_name:   string,
	}
	checks := [?]Check {
		{-10, 0, "cmd_0000"},
		{0, 0, "cmd_0000"},
		{2500, 2500, "cmd_2500"},
		{COUNT - LIST_ROWS, COUNT - LIST_ROWS, "cmd_4988"},
		{COUNT - 1, COUNT - LIST_ROWS, "cmd_4988"},
		{COUNT, COUNT - LIST_ROWS, "cmd_4988"},
		{999_999, COUNT - LIST_ROWS, "cmd_4988"},
	}
	for c in checks {
		panel.first_row = c.requested_first
		testing.expect_value(t, list_first_row(panel), c.expected_first)
		// Hit test on the first visible row and last visible row of the viewport.
		testing.expect_value(t, row_at(panel, px, py, px + 32, py + LIST_TOP + 4), c.expected_first)
		testing.expect_value(t, row_at(panel, px, py, px + 32, py + LIST_TOP + (LIST_ROWS - 1) * ROW_HEIGHT + 4), c.expected_first + LIST_ROWS - 1)
		panel_build(screen, panel)
		// Confirm the expected first visible row's name appears in the draw
		// table and an entry outside the viewport does not.
		found_first := false
		found_outside := false
		outside_name := c.expected_first == 0 ? "cmd_4999" : "cmd_0000"
		for record in screen.table.records[:screen.table.record_count] {
			if shown, _, is_text := interface.text_of_record(&screen.table, record); is_text {
				if shown == c.expected_name {
					found_first = true
				}
				if shown == outside_name {
					found_outside = true
				}
			}
		}
		testing.expectf(t, found_first, "offset %d: expected visible row %s", c.requested_first, c.expected_name)
		testing.expectf(t, !found_outside, "offset %d: off-screen row %s must not be drawn", c.requested_first, outside_name)
	}
}

// Malformed provider headers, truncated regions, and undersized list bindings
// are refused cleanly with nothing changed.
@(test)
malformed_header_and_truncated_region_refused :: proc(t: ^testing.T) {
	// list_bind_memory edge refusals leave List unchanged.
	sentinel_list := List{entry_count = 7, row_count = 3}
	tiny: [16]u8
	testing.expect(t, !list_bind_memory(&sentinel_list, tiny[:], -1, 10))
	testing.expect(t, !list_bind_memory(&sentinel_list, tiny[:], 10, -1))
	testing.expect(t, !list_bind_memory(&sentinel_list, tiny[:], 10, 10))
	testing.expect_value(t, sentinel_list.entry_count, 7)
	testing.expect_value(t, sentinel_list.row_count, 3)

	// Valid snapshot first; then a malformed header or truncated region must
	// be refused before touching snapshot.entries bytes.
	valid := table_make_numbered(4)
	defer delete(valid)
	entries_buf := make([]palette_table.Entry, 4)
	defer delete(entries_buf)
	snap := palette_table.Snapshot{entries = entries_buf}
	problem, _ := palette_table.snapshot_take(valid, &snap)
	testing.expect_value(t, problem, palette_table.Problem.None)
	saved_first := entries_buf[0]

	// Truncated by 1 byte -> Too_Small, entries_buf untouched.
	problem, _ = palette_table.snapshot_take(valid[:len(valid) - 1], &snap)
	testing.expect_value(t, problem, palette_table.Problem.Too_Small)
	testing.expect_value(t, snap.entry_count, 0)
	testing.expect_value(t, snap.generation, 0)
	testing.expect_value(t, entries_buf[0], saved_first)

	// Truncated below MIN_TABLE_BYTES -> Too_Small, entries_buf untouched.
	problem, _ = palette_table.snapshot_take(valid[:palette_table.MIN_TABLE_BYTES - 1], &snap)
	testing.expect_value(t, problem, palette_table.Problem.Too_Small)
	testing.expect_value(t, entries_buf[0], saved_first)

	// Empty slice -> Too_Small, entries_buf untouched.
	problem, _ = palette_table.snapshot_take(nil, &snap)
	testing.expect_value(t, problem, palette_table.Problem.Too_Small)
	testing.expect_value(t, entries_buf[0], saved_first)

	// Mismatched byte_length (0, +1, max(u64)) -> Bad_Byte_Length, entries_buf untouched.
	header := (^palette_table.Header)(raw_data(valid))
	orig_len := header.byte_length
	for bad_len in ([3]u64{0, orig_len + 1, max(u64)}) {
		header.byte_length = bad_len
		problem, _ = palette_table.snapshot_take(valid, &snap)
		testing.expect_value(t, problem, palette_table.Problem.Bad_Byte_Length)
		testing.expect_value(t, entries_buf[0], saved_first)
	}
	header.byte_length = orig_len

	// Corrupt magic / version -> refused, entries_buf untouched.
	header.magic = 0
	problem, _ = palette_table.snapshot_take(valid, &snap)
	testing.expect_value(t, problem, palette_table.Problem.Bad_Magic)
	testing.expect_value(t, entries_buf[0], saved_first)
	header.magic = palette_table.MAGIC
	header.version = palette_table.VERSION + 1
	problem, _ = palette_table.snapshot_take(valid, &snap)
	testing.expect_value(t, problem, palette_table.Problem.Bad_Version)
	testing.expect_value(t, entries_buf[0], saved_first)
}

// Palette selection, copy, cut, and paste in Search and Arguments states,
// including empty selection refusal, reversed anchor, replacement, invalid
// characters, and capacity limits.
@(test)
palette_selection_cut_copy_paste :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	panel_open(panel)

	buf: [line_editor.LINE_CAPACITY]u8
	// Closed/empty selection: copy & cut refused cleanly.
	copied, ok := panel_copy(panel, buf[:])
	testing.expect(t, !ok && copied == 0)
	cut_copied, text_changed, cut_ok := panel_cut(panel, buf[:])
	testing.expect(t, !cut_ok && !text_changed && cut_copied == 0)

	// Type "console", select "sole" via Shift+Left (reversed anchor).
	type_text(panel, "console")
	for _ in 0 ..< 4 {
		drawn, changed := typed_edit(panel, .Select_Left, 0)
		testing.expect(t, drawn && !changed, "selection move redraws without re-ranking")
	}
	copied, ok = panel_copy(panel, buf[:])
	testing.expect(t, ok && copied == 4 && string(buf[:copied]) == "sole")
	testing.expect_value(t, typed_text(panel), "console")

	// Cut deletes selection and marks text_changed.
	copied, text_changed, cut_ok = panel_cut(panel, buf[:])
	testing.expect(t, cut_ok && text_changed && copied == 4 && string(buf[:copied]) == "sole")
	testing.expect_value(t, typed_text(panel), "con")

	// Paste inserts at caret.
	drawn, changed, paste_ok := panel_paste(panel, "fig")
	testing.expect(t, drawn && changed && paste_ok)
	testing.expect_value(t, typed_text(panel), "config")

	// Select all (Ctrl+A) and paste replaces whole search text.
	drawn, changed = typed_edit(panel, .Select_All, 0)
	testing.expect(t, drawn && !changed)
	drawn, changed, paste_ok = panel_paste(panel, "monitor")
	testing.expect(t, drawn && changed && paste_ok)
	testing.expect_value(t, typed_text(panel), "monitor")

	// Control characters and invisible direction marks refused without altering text.
	drawn, changed, paste_ok = panel_paste(panel, "bad\nline")
	testing.expect(t, !drawn && !changed && !paste_ok)
	drawn, changed, paste_ok = panel_paste(panel, "bad\u202Etext")
	testing.expect(t, !drawn && !changed && !paste_ok)
	testing.expect_value(t, typed_text(panel), "monitor")

	// Overflow past TYPED_CAPACITY refused whole (no truncation).
	too_long: [TYPED_CAPACITY]u8
	for &b in too_long {
		b = 'x'
	}
	drawn, changed, paste_ok = panel_paste(panel, string(too_long[:]))
	testing.expect(t, !drawn && !changed && !paste_ok)
	testing.expect_value(t, typed_text(panel), "monitor")

	// Select all and paste exact TYPED_CAPACITY fits!
	_, _ = typed_edit(panel, .Select_All, 0)
	drawn, changed, paste_ok = panel_paste(panel, string(too_long[:]))
	testing.expect(t, drawn && changed && paste_ok)
	testing.expect_value(t, len(typed_text(panel)), TYPED_CAPACITY)

	// Form field paste: Integer field refuses non-digits and accepts valid integer;
	// Text field refuses quotes and overflow past ARGUMENT_TEXT_CAPACITY.
	panel.state = .Arguments
	panel.form.active = true
	panel.form.field_count = 2
	panel.form.current = 0
	panel.form.given.parameter_count = 2
	panel.form.given.parameters[0] = u8(palette_table.Value_Kind.Integer)
	panel.form.given.parameters[1] = u8(palette_table.Value_Kind.Text)
	line_editor.line_clear(&panel.form.fields[0])
	line_editor.line_clear(&panel.form.fields[1])

	// Refused non-digit paste into Integer field sets message and leaves field empty.
	drawn, changed, paste_ok = panel_paste(panel, "12a")
	testing.expect(t, drawn && !changed && !paste_ok)
	testing.expect(t, form_message(&panel.form) != "")
	testing.expect_value(t, field_text(&panel.form, 0), "")

	// Valid negative integer paste accepted, then Ctrl+A + cut moves it out cleanly.
	drawn, changed, paste_ok = panel_paste(panel, "-42")
	testing.expect(t, drawn && changed && paste_ok)
	testing.expect_value(t, field_text(&panel.form, 0), "-42")
	f_drawn, f_leave := form_field_edit(panel, .Select_All, 0)
	testing.expect(t, f_drawn && !f_leave)
	copied, text_changed, cut_ok = panel_cut(panel, buf[:])
	testing.expect(t, cut_ok && text_changed && copied == 3 && string(buf[:copied]) == "-42")
	testing.expect_value(t, field_text(&panel.form, 0), "")

	// Text field refuses quote and > ARGUMENT_TEXT_CAPACITY.
	panel.form.current = 1
	drawn, changed, paste_ok = panel_paste(panel, "a\"b")
	testing.expect(t, drawn && !changed && !paste_ok)
	testing.expect_value(t, field_text(&panel.form, 1), "")
	long_arg: [palette_table.ARGUMENT_TEXT_CAPACITY + 1]u8
	for &b in long_arg {
		b = 'z'
	}
	drawn, changed, paste_ok = panel_paste(panel, string(long_arg[:]))
	testing.expect(t, drawn && !changed && !paste_ok)
	testing.expect_value(t, field_text(&panel.form, 1), "")
	drawn, changed, paste_ok = panel_paste(panel, string(long_arg[:palette_table.ARGUMENT_TEXT_CAPACITY]))
	testing.expect(t, drawn && changed && paste_ok)
	testing.expect_value(t, len(field_text(&panel.form, 1)), palette_table.ARGUMENT_TEXT_CAPACITY)
}
