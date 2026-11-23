package text_model

// Incremental search over the text of the editor (src/md/features/editor.md).
//
// Matches are computed only when the query or the text changes, never in a
// frame: matches[:match_count] holds the sorted byte offsets of all
// non-overlapping matches of query[:query_count] in the text. A frame
// finds the matches that overlap a visible row with one binary search
// (search_first_match_overlapping).

import "modus:contract/text_encoding"

// The most bytes of a search query: UTF-8 with no control character.
SEARCH_QUERY_CAPACITY :: 1024

// Inline match capacity when the caller supplies no external match buffer.
MATCH_CAPACITY :: TEXT_CAPACITY

// Caller-supplied growth callback for the search match offset array.
Match_Grow :: #type proc "contextless" (user_data: rawptr, current: []i32, minimum_matches: int) -> (grown: []i32, ok: bool)

// The moves of the caret inside the search query.
Search_Motion :: enum u8 {
	Left  = 0,
	Right = 1,
	Start = 2,
	End   = 3,
}

// The search state of the editor. The zero value is closed with an empty
// query and active_match == -1 after search_open.
Search :: struct {
	active:            bool,
	query:             [SEARCH_QUERY_CAPACITY]u8,
	query_count:       int,
	query_caret:       int,
	origin:            int, // Where incremental typing searches from, so typing "fo" after "f" does not jump past the current match.
	matches:           []i32, // Active slice of match byte offsets (external_matches or inline_matches[:]).
	inline_matches:    [MATCH_CAPACITY]i32,
	external_matches:  []i32,
	grow:              Match_Grow,
	grow_data:         rawptr,
	match_count:       int,
	active_match:      int, // Index in matches[:match_count], or -1 when there is no match.
	matches_truncated: bool, // True if the text had more matches than the caller's match budget held.
}

// search_init_buffer attaches a caller-supplied match buffer and optional
// growth callback to search.
search_init_buffer :: proc "contextless" (search: ^Search, buffer: []i32, grow: Match_Grow = nil, grow_data: rawptr = nil) {
	search.external_matches = buffer
	search.matches = len(buffer) > 0 ? buffer : search.inline_matches[:]
	search.grow = grow
	search.grow_data = grow_data
	search.match_count = 0
	search.active_match = -1
	search.matches_truncated = false
}

@(private)
search_storage :: proc "contextless" (search: ^Search) -> []i32 {
	if len(search.external_matches) > 0 {
		return search.external_matches
	}
	return search.inline_matches[:]
}

@(private)
search_ensure_capacity :: proc "contextless" (search: ^Search, needed: int, used: int) -> bool {
	if needed < 0 {
		return false
	}
	storage := search_storage(search)
	if needed <= len(storage) {
		search.matches = storage
		return true
	}
	if search.grow == nil {
		return false
	}
	grown, ok := search.grow(search.grow_data, storage, needed)
	if !ok || len(grown) < needed {
		return false
	}
	same_base := len(storage) > 0 && raw_data(grown) == raw_data(storage)
	if !same_base && used > 0 {
		copy(grown[:used], storage[:used])
	}
	search.external_matches = grown
	search.matches = grown
	return true
}

// search_query_bytes gives the current query bytes.
search_query_bytes :: proc "contextless" (search: ^Search) -> []u8 {
	return search.query[:search.query_count]
}

// search_query_valid says if bytes are a valid single-line search query:
// well-formed UTF-8 with no control character.
search_query_valid :: proc "contextless" (bytes: []u8) -> bool {
	return text_encoding.text_valid(bytes)
}

// search_open opens the search bar with an empty query anchored at the
// current caret position.
search_open :: proc "contextless" (search: ^Search, text: ^Text) {
	search.active = true
	search.query_count = 0
	search.query_caret = 0
	search.origin = text.caret
	search.match_count = 0
	search.active_match = -1
}

// search_close closes the search bar, keeping the last query for F3 /
// Shift+F3 while ending match highlights.
search_close :: proc "contextless" (search: ^Search) {
	search.active = false
}

// search_recompute finds all non-overlapping matches of the query in text.
// If matches exist, it selects the first match at or after from_place
// (wrapping to match 0 if none is after from_place); when move_caret is
// true, it moves text.caret and text.anchor to that match.
search_recompute :: proc "contextless" (search: ^Search, text: ^Text, from_place: int, move_caret: bool) {
	search.matches = search_storage(search)
	search.match_count = 0
	search.active_match = -1
	search.matches_truncated = false
	query_length := search.query_count
	length := text_length(text)
	if query_length == 0 || query_length > length {
		return
	}
	place := 0
	limit := length - query_length
	for place <= limit {
		matched := true
		for offset in 0 ..< query_length {
			if byte_at(text, place + offset) != search.query[offset] {
				matched = false
				break
			}
		}
		if matched {
			if !search_ensure_capacity(search, search.match_count + 1, search.match_count) {
				search.matches_truncated = true
				break
			}
			search.matches[search.match_count] = i32(place)
			search.match_count += 1
			place += query_length
		} else {
			place += 1
		}
	}
	if search.match_count == 0 {
		return
	}
	chosen := 0
	for index in 0 ..< search.match_count {
		if int(search.matches[index]) >= from_place {
			chosen = index
			break
		}
	}
	search.active_match = chosen
	if move_caret {
		target := int(search.matches[chosen])
		text.caret, text.anchor, text.has_goal = target, target, false
	}
}

// search_query_set replaces the search query and recomputes matches from
// search.origin. An empty slice clears the query and matches. A query that
// is too long or not valid UTF-8 text is refused and leaves the query
// unchanged.
search_query_set :: proc "contextless" (search: ^Search, text: ^Text, bytes: []u8) -> Edit_Problem {
	if len(bytes) > SEARCH_QUERY_CAPACITY {
		return .Too_Long
	}
	if !search_query_valid(bytes) {
		return .Not_Text
	}
	copy(search.query[:len(bytes)], bytes)
	search.query_count = len(bytes)
	search.query_caret = len(bytes)
	search_recompute(search, text, search.origin, true)
	return .None
}

// search_query_insert inserts UTF-8 bytes at query_caret and recomputes
// matches from search.origin. A refused insert leaves the query unchanged.
search_query_insert :: proc "contextless" (search: ^Search, text: ^Text, bytes: []u8) -> Edit_Problem {
	if len(bytes) == 0 {
		return .Empty
	}
	if !search_query_valid(bytes) {
		return .Not_Text
	}
	if search.query_count + len(bytes) > SEARCH_QUERY_CAPACITY {
		return .Too_Long
	}
	tail := search.query_count - search.query_caret
	if tail > 0 {
		copy(search.query[search.query_caret + len(bytes):search.query_count + len(bytes)], search.query[search.query_caret:search.query_count])
	}
	copy(search.query[search.query_caret:search.query_caret + len(bytes)], bytes)
	search.query_count += len(bytes)
	search.query_caret += len(bytes)
	search_recompute(search, text, search.origin, true)
	return .None
}

// search_query_insert_character inserts one typed character into the search
// query and recomputes matches. Control characters (including LF and tab)
// are refused with Not_Text.
search_query_insert_character :: proc "contextless" (search: ^Search, text: ^Text, character: rune) -> Edit_Problem {
	buffer: [text_encoding.CHARACTER_BYTES_LIMIT]u8
	length := text_encoding.character_encode(character, buffer[:])
	if length == 0 {
		return .Not_Text
	}
	return search_query_insert(search, text, buffer[:length])
}

// query_character_length gives the byte length of the UTF-8 character at
// place in search.query.
@(private = "file")
query_character_length :: proc "contextless" (search: ^Search, place: int) -> int {
	lead := search.query[place]
	switch {
	case lead & 0xE0 == 0xC0:
		return 2
	case lead & 0xF0 == 0xE0:
		return 3
	case lead & 0xF8 == 0xF0:
		return 4
	}
	return 1
}

// query_previous_character_start gives the start byte of the UTF-8
// character before place in search.query (place > 0).
@(private = "file")
query_previous_character_start :: proc "contextless" (search: ^Search, place: int) -> int {
	start := place - 1
	for start > 0 && place - start < text_encoding.CHARACTER_BYTES_LIMIT && search.query[start] & 0xC0 == 0x80 {
		start -= 1
	}
	return start
}

// search_query_delete_before removes the character before query_caret and
// recomputes matches from search.origin.
search_query_delete_before :: proc "contextless" (search: ^Search, text: ^Text) -> bool {
	if search.query_caret == 0 {
		return false
	}
	start := query_previous_character_start(search, search.query_caret)
	removed := search.query_caret - start
	copy(search.query[start:search.query_count - removed], search.query[search.query_caret:search.query_count])
	search.query_count -= removed
	search.query_caret = start
	search_recompute(search, text, search.origin, true)
	return true
}

// search_query_delete_after removes the character at query_caret and
// recomputes matches from search.origin.
search_query_delete_after :: proc "contextless" (search: ^Search, text: ^Text) -> bool {
	if search.query_caret >= search.query_count {
		return false
	}
	removed := query_character_length(search, search.query_caret)
	copy(search.query[search.query_caret:search.query_count - removed], search.query[search.query_caret + removed:search.query_count])
	search.query_count -= removed
	search_recompute(search, text, search.origin, true)
	return true
}

// search_query_move moves query_caret inside the search query by whole
// UTF-8 characters.
search_query_move :: proc "contextless" (search: ^Search, motion: Search_Motion) {
	switch motion {
	case .Left:
		if search.query_caret > 0 {
			search.query_caret = query_previous_character_start(search, search.query_caret)
		}
	case .Right:
		if search.query_caret < search.query_count {
			search.query_caret += query_character_length(search, search.query_caret)
		}
	case .Start:
		search.query_caret = 0
	case .End:
		search.query_caret = search.query_count
	}
}

// search_next moves to the next match, wrapping from the last match to
// match 0, and moves the caret there. false when there is no match.
search_next :: proc "contextless" (search: ^Search, text: ^Text) -> bool {
	if search.query_count == 0 {
		return false
	}
	if search.match_count == 0 || search.active_match < 0 {
		search_recompute(search, text, text.caret, true)
		if search.match_count == 0 {
			return false
		}
		search.origin = int(search.matches[search.active_match])
		return true
	}
	search.active_match = (search.active_match + 1) % search.match_count
	target := int(search.matches[search.active_match])
	search.origin = target
	text.caret, text.anchor, text.has_goal = target, target, false
	return true
}

// search_previous moves to the previous match, wrapping from match 0 to
// the last match, and moves the caret there. false when there is no match.
search_previous :: proc "contextless" (search: ^Search, text: ^Text) -> bool {
	if search.query_count == 0 {
		return false
	}
	if search.match_count == 0 || search.active_match < 0 {
		search_recompute(search, text, text.caret, false)
		if search.match_count == 0 {
			return false
		}
		chosen := search.match_count - 1
		for index := search.match_count - 1; index >= 0; index -= 1 {
			if int(search.matches[index]) <= text.caret {
				chosen = index
				break
			}
		}
		search.active_match = chosen
		target := int(search.matches[chosen])
		search.origin = target
		text.caret, text.anchor, text.has_goal = target, target, false
		return true
	}
	search.active_match = (search.active_match + search.match_count - 1) % search.match_count
	target := int(search.matches[search.active_match])
	search.origin = target
	text.caret, text.anchor, text.has_goal = target, target, false
	return true
}

// search_first_match_overlapping gives the smallest index in
// search.matches[:search.match_count] whose match ends after byte `start`,
// or search.match_count if no match reaches past `start`. Used by row
// drawing so a frame checks only matches visible in the window.
search_first_match_overlapping :: proc "contextless" (search: ^Search, start: int) -> int {
	if search.match_count == 0 || search.query_count == 0 {
		return search.match_count
	}
	low, high := 0, search.match_count
	for low < high {
		middle := (low + high) / 2
		if int(search.matches[middle]) + search.query_count <= start {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low
}
