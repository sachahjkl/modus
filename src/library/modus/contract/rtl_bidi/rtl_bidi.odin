// Pure freestanding UAX #9 bidirectional text ordering (Arabic & Hebrew) and
// right-to-left interface layout mirroring
// (src/md/features/interface_language.md).
//
// Zero dynamic allocations, zero kernel operations, and strict UTF-8 borders.
package rtl_bidi

import "modus:contract/enum_word"
import "modus:contract/text_encoding"

MAX_BIDI_RUNES :: 256

Paragraph_Direction :: enum u8 {
	Left_To_Right = 0,
	Right_To_Left = 1,
}

paragraph_direction_of_word :: proc "contextless" (word: u64) -> (dir: Paragraph_Direction, ok: bool) {
	return enum_word.member_of_word(Paragraph_Direction, word)
}

Bidi_Class :: enum u8 {
	L   = 0, // Left-to-right strong (Latin, etc.)
	R   = 1, // Right-to-left strong (Hebrew)
	AL  = 2, // Arabic letter strong
	EN  = 3, // European number (0-9)
	AN  = 4, // Arabic-Indic number
	ES  = 5, // European separator (+, -)
	ET  = 6, // European terminator (%, $)
	CS  = 7, // Common separator (., ,)
	NSM = 8, // Nonspacing mark
	WS  = 9, // Whitespace
	ON  = 10, // Other neutral
}

bidi_class_of :: proc "contextless" (r: rune) -> Bidi_Class {
	switch {
	case (r >= 0x0590 && r <= 0x05FF) || (r >= 0xFB1D && r <= 0xFB4F):
		return .R
	case (r >= 0x0600 && r <= 0x065F) || (r >= 0x066E && r <= 0x06FF) || (r >= 0x0750 && r <= 0x077F) || (r >= 0x08A0 && r <= 0x08FF) || (r >= 0xFB50 && r <= 0xFDFF) || (r >= 0xFE70 && r <= 0xFEFF):
		return .AL
	case r >= 0x0660 && r <= 0x0669:
		return .AN
	case r >= '0' && r <= '9':
		return .EN
	case r == '+' || r == '-':
		return .ES
	case r == '$' || r == '%' || r == '#' || r == 0x20AC:
		return .ET
	case r == ',' || r == '.' || r == ':' || r == '/':
		return .CS
	case (r >= 0x0300 && r <= 0x036F):
		return .NSM
	case r == ' ' || r == '\t' || r == '\n' || r == '\r':
		return .WS
	case (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || (r >= 0x00C0 && r <= 0x024F):
		return .L
	}
	return .ON
}

// base_direction_detect implements UAX #9 P2/P3 (first strong character).
base_direction_detect :: proc "contextless" (text: string) -> Paragraph_Direction {
	if !text_encoding.text_valid(transmute([]u8)text) {
		return .Left_To_Right
	}
	bytes := transmute([]u8)text
	for pos := 0; pos < len(bytes); {
		r, width, ok := text_encoding.character_decode(bytes, pos)
		if !ok || width <= 0 {
			break
		}
		pos += width
		cls := bidi_class_of(r)
		if cls == .L {
			return .Left_To_Right
		}
		if cls == .R || cls == .AL {
			return .Right_To_Left
		}
	}
	return .Left_To_Right
}

// mirror_glyph_for_rtl returns the UAX #9 mirrored bracket/punctuation pair
// when rendered at an odd (RTL) embedding level.
mirror_glyph_for_rtl :: proc "contextless" (r: rune) -> rune {
	switch r {
	case '(': return ')'
	case ')': return '('
	case '[': return ']'
	case ']': return '['
	case '{': return '}'
	case '}': return '{'
	case '<': return '>'
	case '>': return '<'
	case '«': return '»'
	case '»': return '«'
	}
	return r
}

Visual_Slot :: struct {
	logical_index: u16,
	character:     rune,
	level:         u8,
}

// bidi_reorder_line implements UAX #9 weak/neutral/implicit level resolution
// (W1..W7, N1..N2, I1..I2) and L2 visual reordering for one line into out.
bidi_reorder_line :: proc "contextless" (
	text: string,
	base_dir: Paragraph_Direction,
	out: []Visual_Slot,
) -> (count: int, ok: bool) {
	if !text_encoding.text_valid(transmute([]u8)text) {
		return 0, false
	}
	bytes := transmute([]u8)text
	runes: [MAX_BIDI_RUNES]rune
	classes: [MAX_BIDI_RUNES]Bidi_Class
	levels: [MAX_BIDI_RUNES]u8
	n := 0
	for pos := 0; pos < len(bytes); {
		if n >= MAX_BIDI_RUNES || n >= len(out) {
			return 0, false
		}
		r, width, dec_ok := text_encoding.character_decode(bytes, pos)
		if !dec_ok || width <= 0 {
			return 0, false
		}
		pos += width
		runes[n] = r
		classes[n] = bidi_class_of(r)
		n += 1
	}
	if n == 0 {
		return 0, true
	}

	base_level := u8(base_dir == .Right_To_Left ? 1 : 0)
	sos_class := base_dir == .Right_To_Left ? Bidi_Class.R : Bidi_Class.L

	// Nonspacing marks inherit the class of the previous character.
	for i in 0 ..< n {
		if classes[i] == .NSM {
			classes[i] = i == 0 ? sos_class : classes[i - 1]
		}
	}
	// European numbers after Arabic letters become Arabic numbers; AL becomes R.
	last_strong := sos_class
	for i in 0 ..< n {
		switch classes[i] {
		case .L, .R, .AL:
			last_strong = classes[i]
		case .EN:
			if last_strong == .AL {
				classes[i] = .AN
			}
		case .AN, .ES, .ET, .CS, .NSM, .WS, .ON:
		}
	}
	for i in 0 ..< n {
		if classes[i] == .AL {
			classes[i] = .R
		}
	}
	// Resolve simple numeric separators and LTR-context European numbers.
	for i in 0 ..< n {
		if classes[i] == .ES && i > 0 && i + 1 < n && classes[i - 1] == .EN && classes[i + 1] == .EN {
			classes[i] = .EN
		} else if classes[i] == .CS && i > 0 && i + 1 < n && classes[i - 1] == classes[i + 1] && (classes[i - 1] == .EN || classes[i - 1] == .AN) {
			classes[i] = classes[i - 1]
		} else if classes[i] == .ES || classes[i] == .ET || classes[i] == .CS {
			classes[i] = .ON
		}
	}
	last_strong = sos_class
	for i in 0 ..< n {
		if classes[i] == .L || classes[i] == .R {
			last_strong = classes[i]
		} else if classes[i] == .EN && last_strong == .L {
			classes[i] = .L
		}
	}

	// Resolve neutral and whitespace runs between strong directions.
	i := 0
	for i < n {
		if classes[i] != .WS && classes[i] != .ON {
			i += 1
			continue
		}
		run_start := i
		for i < n && (classes[i] == .WS || classes[i] == .ON) {
			i += 1
		}
		prev_dir := run_start == 0 ? sos_class : (classes[run_start - 1] == .L ? Bidi_Class.L : Bidi_Class.R)
		next_dir := i >= n ? sos_class : (classes[i] == .L ? Bidi_Class.L : Bidi_Class.R)
		resolved := prev_dir == next_dir ? prev_dir : sos_class
		for j in run_start ..< i {
			classes[j] = resolved
		}
	}

	// Compute implicit embedding levels for each character.
	max_level := base_level
	for k in 0 ..< n {
		lvl := base_level
		if base_level == 0 {
			switch classes[k] {
			case .R:
				lvl = 1
			case .AN, .EN:
				lvl = 2
			case .L, .AL, .ES, .ET, .CS, .NSM, .WS, .ON:
			}
		} else {
			switch classes[k] {
			case .L, .EN, .AN:
				lvl = 2
			case .R, .AL, .ES, .ET, .CS, .NSM, .WS, .ON:
			}
		}
		levels[k] = lvl
		if lvl > max_level {
			max_level = lvl
		}
		ch := (lvl & 1) == 1 ? mirror_glyph_for_rtl(runes[k]) : runes[k]
		out[k] = Visual_Slot{logical_index = u16(k), character = ch, level = lvl}
	}

	// Reverse contiguous runs at each embedding level from highest down to 1.
	for l := max_level; l >= 1; l -= 1 {
		idx := 0
		for idx < n {
			if out[idx].level < l {
				idx += 1
				continue
			}
			start := idx
			for idx < n && out[idx].level >= l {
				idx += 1
			}
			lo, hi := start, idx - 1
			for lo < hi {
				out[lo], out[hi] = out[hi], out[lo]
				lo += 1
				hi -= 1
			}
		}
	}
	return n, true
}

// Layout_Rect represents an interface widget box in container-relative coordinates.
Layout_Rect :: struct {
	x:      i32,
	y:      i32,
	width:  i32,
	height: i32,
}

// mirror_rect_for_direction mirrors rect horizontally inside container_width
// when dir == .Right_To_Left, returning ok = false on invalid container/rect.
mirror_rect_for_direction :: proc "contextless" (container_width: i32, rect: Layout_Rect, dir: Paragraph_Direction) -> (result: Layout_Rect, ok: bool) {
	if container_width <= 0 || rect.width < 0 || rect.height < 0 {
		return {}, false
	}
	if dir == .Left_To_Right {
		return rect, true
	}
	mirrored := rect
	mirrored.x = container_width - rect.x - rect.width
	return mirrored, true
}
