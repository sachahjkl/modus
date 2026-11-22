// Pure freestanding complex script shaper, CJK ideograph cell-width metrics,
// and large-text line reflow engine (without enlarging windows).
package complex_shaping

Joining_Type :: enum u8 {
	Non_Joining   = 0,
	Right_Joining = 1,
	Dual_Joining  = 2,
	Transparent   = 3,
}

Shaped_Glyph :: struct {
	codepoint:   rune,
	cluster:     u32,
	advance_px:  i32,
	is_mark:     bool,
	is_wide_cjk: bool,
}

is_cjk_ideograph :: proc "contextless" (r: rune) -> bool {
	return (r >= 0x4E00 && r <= 0x9FFF) || // CJK Unified Ideographs
		(r >= 0x3400 && r <= 0x4DBF) ||    // Extension A
		(r >= 0x3040 && r <= 0x30FF) ||    // Hiragana & Katakana
		(r >= 0xAC00 && r <= 0xD7AF)       // Hangul Syllables
}

is_combining_mark :: proc "contextless" (r: rune) -> bool {
	return (r >= 0x0300 && r <= 0x036F) || // Combining Diacritical Marks
		(r >= 0x064B && r <= 0x065F) ||    // Arabic Tashkil / Harakat
		(r >= 0x093E && r <= 0x094D)       // Devanagari Matras & Virama
}

arabic_joining_type :: proc "contextless" (r: rune) -> Joining_Type {
	if is_combining_mark(r) {
		return .Transparent
	}
	switch r {
	case 0x0627, 0x062F, 0x0630, 0x0631, 0x0632, 0x0648, 0x0629:
		return .Right_Joining // Alef, Dal, Thal, Reh, Zain, Waw, Teh Marbuta
	case 0x0628, 0x062A, 0x062B, 0x062C, 0x062D, 0x062E,
	     0x0633, 0x0634, 0x0635, 0x0636, 0x0637, 0x0638,
	     0x0639, 0x063A, 0x0641, 0x0642, 0x0643, 0x0644,
	     0x0645, 0x0646, 0x0647, 0x064A:
		return .Dual_Joining
	}
	return .Non_Joining
}

// Contextual presentation forms (Isolated, Final, Initial, Medial) for core Arabic letters.
arabic_presentation_form :: proc "contextless" (r: rune, join_prev, join_next: bool) -> rune {
	base: rune = 0
	has_init_med := true
	switch r {
	case 0x0627: base = 0xFE8D; has_init_med = false // Alef
	case 0x0628: base = 0xFE8F // Beh
	case 0x062A: base = 0xFE95 // Teh
	case 0x0633: base = 0xFEB1 // Seen
	case 0x0644: base = 0xFEDD // Lam
	case 0x0645: base = 0xFEE1 // Meem
	case 0x0646: base = 0xFEE5 // Noon
	case 0x0647: base = 0xFEE9 // Heh
	case 0x064A: base = 0xFEF1 // Yeh
	case:
		return r
	}
	if !has_init_med {
		return join_prev ? base + 1 : base
	}
	if join_prev && join_next {
		return base + 3 // Medial
	}
	if join_prev {
		return base + 1 // Final
	}
	if join_next {
		return base + 2 // Initial
	}
	return base // Isolated
}

// shape_run shapes a slice of Unicode runes (Arabic contextual joining +
// Lam-Alef mandatory ligature, zero-width combining marks, and double-width CJK)
// into caller-supplied out_glyphs.
shape_run :: proc "contextless" (runes: []rune, cell_px: i32, out_glyphs: []Shaped_Glyph) -> int {
	if cell_px <= 0 || len(out_glyphs) == 0 {
		return 0
	}
	count := 0
	i := 0
	for i < len(runes) && count < len(out_glyphs) {
		r := runes[i]
		// Mandatory Arabic Lam (0x0644) + Alef (0x0627) ligature.
		if r == 0x0644 && i + 1 < len(runes) && runes[i + 1] == 0x0627 {
			join_prev := false
			for p := i - 1; p >= 0; p -= 1 {
				jt := arabic_joining_type(runes[p])
				if jt == .Transparent {
					continue
				}
				join_prev = jt == .Dual_Joining
				break
			}
			out_glyphs[count] = {
				codepoint  = join_prev ? rune(0xFEFC) : rune(0xFEFB),
				cluster    = u32(i),
				advance_px = cell_px,
			}
			count += 1
			i += 2
			continue
		}

		mark := is_combining_mark(r)
		wide := is_cjk_ideograph(r)
		shaped := r
		jt := arabic_joining_type(r)
		if jt == .Right_Joining || jt == .Dual_Joining {
			join_prev := false
			for p := i - 1; p >= 0; p -= 1 {
				pt := arabic_joining_type(runes[p])
				if pt == .Transparent {
					continue
				}
				join_prev = pt == .Dual_Joining
				break
			}
			join_next := false
			if jt == .Dual_Joining {
				for q := i + 1; q < len(runes); q += 1 {
					nt := arabic_joining_type(runes[q])
					if nt == .Transparent {
						continue
					}
					join_next = nt == .Right_Joining || nt == .Dual_Joining
					break
				}
			}
			shaped = arabic_presentation_form(r, join_prev, join_next)
		}

		adv := mark ? i32(0) : (wide ? cell_px * 2 : cell_px)
		out_glyphs[count] = {
			codepoint   = shaped,
			cluster     = u32(i),
			advance_px  = adv,
			is_mark     = mark,
			is_wide_cjk = wide,
		}
		count += 1
		i += 1
	}
	return count
}

// reflow_line_count computes how many wrapped lines a shaped glyph run needs
// inside a fixed max_width_px window when the principal increases text scale
// (larger text with no larger windows).
reflow_line_count :: proc "contextless" (glyphs: []Shaped_Glyph, max_width_px: i32) -> int {
	if len(glyphs) == 0 || max_width_px <= 0 {
		return 0
	}
	lines := 1
	cur_w := i32(0)
	for g in glyphs {
		if g.advance_px == 0 {
			continue
		}
		if cur_w > 0 && cur_w + g.advance_px > max_width_px {
			lines += 1
			cur_w = g.advance_px
		} else {
			cur_w += g.advance_px
		}
	}
	return lines
}
