// The view of the conversation of the assistant: the place of each entry in
// the content, the scroll of the view, and the bound of the lines of a long
// text (src/md/features/assistant.md, "The view of the conversation"). The
// window lays out an entry only when it changes, keeps its height here, and
// each frame reads the places in logarithmic time: no frame does work in
// proportion to the conversation. The package makes no call of the system,
// so a host test drives each rule.
package conversation_view

import assistant_contract "modus:contract/assistant"

// The entries that the view places: each entry of the conversation.
ENTRY_CAPACITY :: assistant_contract.CONVERSATION_ENTRY_CAPACITY

// The lines of the words of one entry that a layout keeps. A text of 16 KiB
// takes fewer: a line of the room of the window holds about 60 of the
// widest letters, so 16 KiB of them take about 280 lines. Past the
// capacity, the entry says how many lines it does not show.
WORD_LINE_CAPACITY :: 512
#assert(assistant_contract.REPLY_TEXT_BYTES <= int(max(u16)))

// The lines of the code of one act: a line of 200 bytes takes at most 4
// lines of the room of the window.
CODE_LINE_CAPACITY :: 8
#assert(assistant_contract.ACT_LINE_BYTES <= int(max(u16)))

// One line of a text: its first byte and its bytes.
Line :: struct {
	start: u16,
	count: u16,
}

// The layout of one entry, for one width, one height of the view and one
// size of the fonts. The window keeps one for each place of the ring of
// the conversation, and lays out the entry again only when its number, its
// revision, its fold or a size changed.
Entry_Layout :: struct {
	number:          u64, // The entry that the layout is of; 0: none.
	revision:        u32,
	width:           i32, // The room of a line, in pixels.
	view_height:     i32,
	metrics:         u64, // The heights of the lines of the two fonts and the width of a cell: a new font lays out again.
	folded:          bool,
	fold_button:     bool, // A button that folds or opens the result.
	has_table:       bool,
	words_are_value: bool, // The words are a value, in the font of the cells.
	more_button:     bool, // A button that shows the other lines, or fewer.
	page_bar:        bool, // The buttons of the rows of a table.
	table_rows:      i32, // The rows of the table that the window carries when it laid out.
	result_lines:    i32, // The lines of the typed result, fitted to the room.
	result_room:     i32, // The room in lines that the result was fitted to.
	height:          i32, // The whole entry, its gap under it too.
	word_total:      i32, // Every line of the words, kept or not.
	code_count:      u16,
	word_count:      u16, // The lines that the entry shows.
	code:            [CODE_LINE_CAPACITY]Line,
	words:           [WORD_LINE_CAPACITY]Line,
}

// The places of the entries, oldest first: tops[i] is the first pixel of
// entry i in the content, tops[count] the height of the whole content, and
// numbers[i] the number of entry i, which grows with i.
Places :: struct {
	count:   int,
	tops:    [ENTRY_CAPACITY + 1]int,
	numbers: [ENTRY_CAPACITY]u64,
}

// The scroll of the view. The view follows the newest entry until the
// principal moves it up; it then keeps the entry at its top, at the same
// pixel of that entry, while entries are added under it, leave the ring
// above it, or change their height.
Scroll :: struct {
	first:         int, // The pixel of the content at the top of the view.
	following:     bool, // The view shows the end of the content.
	anchor_number: u64, // The entry at the top of the view.
	anchor_offset: int, // The pixels of that entry above the view.
}

// scroll_start gives the scroll of a new view: it follows the newest entry.
scroll_start :: proc "contextless" () -> Scroll {
	return {following = true}
}

// total gives the height of the whole content.
total :: proc "contextless" (places: ^Places) -> int {
	return places.tops[places.count]
}

// most gives the largest first pixel of a view of a height.
most :: proc "contextless" (places: ^Places, view_height: int) -> int {
	return max(total(places) - max(view_height, 0), 0)
}

// entry_at gives the entry that holds a pixel of the content: the last
// entry whose top is at or above it, or 0 for a pixel above the content.
// -1 when the content has no entry.
entry_at :: proc "contextless" (places: ^Places, y: int) -> int {
	if places.count == 0 {
		return -1
	}
	low, high := 0, places.count - 1
	for low < high {
		middle := low + (high - low + 1) / 2
		if places.tops[middle] <= y {
			low = middle
		} else {
			high = middle - 1
		}
	}
	return low
}

// index_of_number gives the place of the entry with a number, or false.
index_of_number :: proc "contextless" (places: ^Places, number: u64) -> (index: int, found: bool) {
	low, high := 0, places.count - 1
	for low <= high {
		middle := low + (high - low) / 2
		switch {
		case places.numbers[middle] == number:
			return middle, true
		case places.numbers[middle] < number:
			low = middle + 1
		case:
			high = middle - 1
		}
	}
	return 0, false
}

// anchor_set keeps the entry at the top of the view and its offset.
@(private = "file")
anchor_set :: proc "contextless" (scroll: ^Scroll, places: ^Places) {
	index := entry_at(places, scroll.first)
	if index < 0 {
		scroll.anchor_number, scroll.anchor_offset = 0, 0
		return
	}
	scroll.anchor_number = places.numbers[index]
	scroll.anchor_offset = scroll.first - places.tops[index]
}

// settle gives the first pixel of the view for the places of now: the end
// of the content for a view that follows; else the same pixel of the entry
// that was at the top. When that entry left the ring, the view shows the
// oldest entry. A view that reaches the end follows again.
settle :: proc "contextless" (scroll: ^Scroll, places: ^Places, view_height: int) {
	end := most(places, view_height)
	if !scroll.following {
		index, found := index_of_number(places, scroll.anchor_number)
		if found {
			height := places.tops[index + 1] - places.tops[index]
			scroll.first = places.tops[index] + clamp(scroll.anchor_offset, 0, max(height - 1, 0))
		} else {
			scroll.first = 0
		}
		scroll.first = clamp(scroll.first, 0, end)
		scroll.following = scroll.first >= end
	}
	if scroll.following {
		scroll.first = end
	}
	anchor_set(scroll, places)
}

// scroll_set moves the view to a first pixel that the principal asked
// (the wheel, the bar, a page key), cut to the content. The view follows
// again when it reaches the end.
scroll_set :: proc "contextless" (scroll: ^Scroll, places: ^Places, view_height, first: int) {
	end := most(places, view_height)
	scroll.first = clamp(first, 0, end)
	scroll.following = scroll.first >= end
	anchor_set(scroll, places)
}

// visible gives the entries that a view of a height at a first pixel
// shows, whole or in part: start ..< end.
visible :: proc "contextless" (places: ^Places, first, view_height: int) -> (start, end: int) {
	if places.count == 0 || view_height <= 0 {
		return 0, 0
	}
	start = max(entry_at(places, first), 0)
	end = entry_at(places, first + view_height - 1) + 1
	return start, max(end, start)
}

// lines_bound gives the lines of a text that an entry shows: every line
// when they fit the room; else the room, or every line that the layout
// keeps when the principal asked for them. hidden counts each line that
// does not show.
lines_bound :: proc "contextless" (total_lines, room_lines: int, expanded: bool, capacity := WORD_LINE_CAPACITY) -> (shown, hidden: int) {
	all_lines := max(total_lines, 0)
	kept := min(all_lines, max(capacity, 0))
	switch {
	case all_lines <= max(room_lines, 0):
		shown = kept
	case expanded:
		shown = kept
	case:
		shown = clamp(room_lines, min(1, kept), kept)
	}
	return shown, all_lines - shown
}
