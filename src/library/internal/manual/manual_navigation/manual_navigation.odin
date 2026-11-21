// The navigation of the process `manual` between its pages
// (src/md/features/manual_links.md): the history that Backspace walks back,
// and the order in which Tab moves the focus between the links of a page.
// It has no state of its own: the process keeps a History, and the host
// tests check the two rules with no window.
package manual_navigation

// The places that the history keeps. A principal who goes back more than
// this far finds the oldest pages forgotten: the count is in
// History.forgotten.
HISTORY_CAPACITY :: 64

// What a page of the manual shows.
Page_Kind :: enum u8 {
	Module, // The page of a module of the boot image: `index` is its index in the image.
	Overview, // The table of all the modules.
	Link_Page, // A link page: `index` is its index in the resource manual_pages.
}

// One page, and the first row that the view showed of it.
Page_Place :: struct {
	kind:       Page_Kind,
	index:      i32,
	first_line: i32,
}

// The pages that the principal left, the newest last.
History :: struct {
	places:    [HISTORY_CAPACITY]Page_Place,
	count:     int, // The entries of `places` in use.
	forgotten: int, // The oldest places that a push removed from a full history.
}

// history_push keeps the page that the principal leaves. When the history
// is full, the oldest place goes, and the count of forgotten places grows.
history_push :: proc "contextless" (history: ^History, place: Page_Place) {
	if history.count >= HISTORY_CAPACITY {
		copy(history.places[:HISTORY_CAPACITY - 1], history.places[1:])
		history.count = HISTORY_CAPACITY - 1
		history.forgotten += 1
	}
	history.places[history.count] = place
	history.count += 1
}

// history_back gives the newest place and removes it. ok is false when the
// history is empty.
history_back :: proc "contextless" (history: ^History) -> (place: Page_Place, ok: bool) {
	if history.count <= 0 {
		return {}, false
	}
	history.count -= 1
	return history.places[history.count], true
}

// focus_step gives the link that takes the focus after a key Tab (or
// Shift+Tab when backward is true), from 0, or -1 when the page has no link.
// `focused` is the link with the focus, or -1. `first_in_view` is the first
// link at or under the top of the view, or link_count when no link is
// there. The order is the order of the text, and it goes round.
focus_step :: proc "contextless" (link_count, focused, first_in_view: int, backward: bool) -> int {
	if link_count <= 0 {
		return -1
	}
	if focused < 0 || focused >= link_count {
		start := clamp(first_in_view, 0, link_count)
		if backward {
			return start > 0 ? start - 1 : link_count - 1
		}
		return start < link_count ? start : 0
	}
	if backward {
		return (focused + link_count - 1) % link_count
	}
	return (focused + 1) % link_count
}
