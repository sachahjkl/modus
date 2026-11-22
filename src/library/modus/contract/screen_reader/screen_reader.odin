// Pure freestanding assistive suite: screen reader announcement generator,
// keyboard focus traversal, viewport magnifier transform, and 8-dot Unicode
// refreshable Braille display encoder (src/md/features/accessibility.md).
package screen_reader

import "modus:contract/accessibility"
import "modus:contract/enum_word"

MAX_ANNOUNCEMENT_BYTES :: 256
MAX_BRAILLE_CELLS :: 80 // Standard 40- or 80-cell refreshable Braille display

Magnifier_Filter :: enum u8 {
	Normal        = 1,
	Inverted      = 2,
	High_Contrast = 3,
}

magnifier_filter_of_word :: proc "contextless" (word: u64) -> (f: Magnifier_Filter, ok: bool) {
	return enum_word.member_of_word(Magnifier_Filter, word)
}

// ============================================================================
// Screen Reader: semantic node -> human-readable spoken announcement
// ============================================================================

append_str :: proc "contextless" (dst: []u8, pos: ^int, s: string) {
	for i in 0 ..< len(s) {
		if pos^ >= len(dst) {
			return
		}
		dst[pos^] = s[i]
		pos^ += 1
	}
}

role_spoken_name :: proc "contextless" (role: accessibility.Role) -> string {
	switch role {
	case .None:         return ""
	case .Window:       return "window"
	case .Region:       return "region"
	case .Toolbar:      return "toolbar"
	case .Navigation:   return "navigation"
	case .Main:         return "main"
	case .Status:       return "status"
	case .Dialog:       return "dialog"
	case .Alert_Dialog: return "alert dialog"
	case .Button:       return "button"
	case .Checkbox:     return "checkbox"
	case .Radio:        return "radio"
	case .Switch:       return "switch"
	case .Text_Box:     return "text box"
	case .Slider:       return "slider"
	case .List:         return "list"
	case .List_Item:    return "list item"
	case .Menu:         return "menu"
	case .Menu_Item:    return "menu item"
	case .Tab_List:     return "tab list"
	case .Tab:          return "tab"
	case .Tree:         return "tree"
	case .Tree_Item:    return "tree item"
	case .Table:        return "table"
	case .Row:          return "row"
	case .Cell:         return "cell"
	case .Heading:      return "heading"
	case .Label:        return "label"
	case .Image:        return "image"
	case .Progress_Bar: return "progress bar"
	case .Link:         return "link"
	case .Separator:    return "separator"
	}
	return ""
}

// announce_node formats a focused semantic tree node into a concise spoken
// phrase: "<name>, <role>, <states>" suitable for eSpeak NG / speech_output.
announce_node :: proc "contextless" (
	node: accessibility.Semantic_Node,
	name_bytes: []u8,
	out: []u8,
) -> int {
	pos := 0
	if len(name_bytes) > 0 {
		for b in name_bytes {
			if pos >= len(out) {
				break
			}
			out[pos] = b
			pos += 1
		}
	}
	role_txt := role_spoken_name(node.role)
	if len(role_txt) > 0 {
		if pos > 0 {
			append_str(out, &pos, ", ")
		}
		append_str(out, &pos, role_txt)
	}
	if .Checked in node.states {
		append_str(out, &pos, ", checked")
	}
	if .Pressed in node.states {
		append_str(out, &pos, ", pressed")
	}
	if .Expanded in node.states {
		append_str(out, &pos, ", expanded")
	}
	if .Disabled in node.states {
		append_str(out, &pos, ", disabled")
	}
	return pos
}

// ============================================================================
// Viewport Magnifier (1.5x..8.0x in eighths, focus/pointer tracking)
// ============================================================================

Magnifier_State :: struct {
	enabled:      bool,
	zoom_eighths: u16, // 12 = 1.5x, 16 = 2x, ..., 64 = 8x
	screen_w:     i32,
	screen_h:     i32,
	view_x:       i32, // Top-left source pixel on desktop
	view_y:       i32,
	filter:       Magnifier_Filter,
}

magnifier_init :: proc "contextless" (m: ^Magnifier_State, screen_w, screen_h: i32, zoom_eighths: u16 = 16) -> bool {
	if m == nil || screen_w <= 0 || screen_h <= 0 || zoom_eighths < 12 || zoom_eighths > 64 {
		return false
	}
	m^ = {
		enabled      = true,
		zoom_eighths = zoom_eighths,
		screen_w     = screen_w,
		screen_h     = screen_h,
		filter       = .Normal,
	}
	return true
}

// magnifier_focus_on centers the magnified viewport smoothly on target (tx, ty)
// clamped strictly inside [0, screen_w - view_w] x [0, screen_h - view_h].
magnifier_focus_on :: proc "contextless" (m: ^Magnifier_State, tx, ty: i32) {
	if m == nil || !m.enabled || m.zoom_eighths < 8 {
		return
	}
	view_w := (m.screen_w * 8) / i32(m.zoom_eighths)
	view_h := (m.screen_h * 8) / i32(m.zoom_eighths)
	max_x := max(i32(0), m.screen_w - view_w)
	max_y := max(i32(0), m.screen_h - view_h)
	m.view_x = clamp(tx - view_w / 2, 0, max_x)
	m.view_y = clamp(ty - view_h / 2, 0, max_y)
}

// ============================================================================
// Refreshable Braille Display (Unicode Braille Patterns U+2800..U+28FF)
// ============================================================================

// Standard Grade-1 dot patterns (bit0=dot1 .. bit7=dot8) for ASCII a..z and 0..9.
@(private)
BRAILLE_ALPHA :: [26]u8{
	0x01, 0x03, 0x09, 0x19, 0x11, 0x0B, 0x1B, 0x13, 0x0A, 0x1A, // a..j
	0x05, 0x07, 0x0D, 0x1D, 0x15, 0x0F, 0x1F, 0x17, 0x0E, 0x1E, // k..t
	0x25, 0x27, 0x3A, 0x2D, 0x3D, 0x35, // u..z
}

// ascii_to_braille_cells translates ASCII text into 8-dot Braille cell bitmasks
// (dot 7 = 0x40 marks uppercase, dot 8 = 0x80 marks digits) windowed at pan_offset
// for a display of cell_count cells (<= MAX_BRAILLE_CELLS).
ascii_to_braille_cells :: proc "contextless" (
	text: []u8,
	pan_offset: int,
	out_cells: []u8,
) -> int {
	limit := min(len(out_cells), MAX_BRAILLE_CELLS)
	if pan_offset < 0 || pan_offset >= len(text) || limit <= 0 {
		for i in 0 ..< limit {
			out_cells[i] = 0
		}
		return 0
	}
	n := min(len(text) - pan_offset, limit)
	for i in 0 ..< n {
		ch := text[pan_offset + i]
		dots := u8(0)
		switch {
		case ch >= 'a' && ch <= 'z':
			dots = BRAILLE_ALPHA[ch - 'a']
		case ch >= 'A' && ch <= 'Z':
			dots = BRAILLE_ALPHA[ch - 'A'] | 0x40 // Dot 7: capital
		case ch >= '1' && ch <= '9':
			dots = BRAILLE_ALPHA[ch - '1'] | 0x80 // Dot 8: digit
		case ch == '0':
			dots = BRAILLE_ALPHA[9] | 0x80 // 'j' + dot 8
		case ch == '.':
			dots = 0x32
		case ch == ',':
			dots = 0x02
		case ch == '?':
			dots = 0x26
		case ch == '!':
			dots = 0x16
		case ch == '-':
			dots = 0x24
		case:
			dots = 0x00 // Space / unknown
		}
		out_cells[i] = dots
	}
	for i in n ..< limit {
		out_cells[i] = 0
	}
	return n
}
