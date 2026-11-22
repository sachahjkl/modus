// Pure freestanding CJK input method candidate-window protocol and UAX #11
// East Asian cell width rules (src/md/features/interface_language.md).
//
// Zero dynamic allocations, zero kernel operations, strict closed-enum borders.
package ime_cjk

import "modus:contract/enum_word"

MAX_PREEDIT_BYTES :: 64
MAX_CANDIDATE_BYTES :: 32
MAX_CANDIDATES :: 9

Ime_Mode :: enum u8 {
	Direct      = 0,
	Pinyin      = 1,
	Romaji_Kana = 2,
	Hangul_Jamo = 3,
}

ime_mode_of_word :: proc "contextless" (word: u64) -> (mode: Ime_Mode, ok: bool) {
	return enum_word.member_of_word(Ime_Mode, word)
}

Ime_Refusal :: enum u8 {
	None             = 0,
	Nil_State        = 1,
	Invalid_Mode     = 2,
	Invalid_Char     = 3,
	Preedit_Full     = 4,
	Empty_Preedit    = 5,
	Invalid_Index    = 6,
	Buffer_Too_Small = 7,
}

Candidate :: struct {
	text: [MAX_CANDIDATE_BYTES]u8,
	len:  u8,
}

Ime_State :: struct {
	mode:            Ime_Mode,
	preedit:         [MAX_PREEDIT_BYTES]u8,
	preedit_len:     int,
	candidates:      [MAX_CANDIDATES]Candidate,
	candidate_count: int,
	selected_index:  int,
}

// east_asian_cell_width returns 2 for CJK Unified Ideographs, Hiragana,
// Katakana, Hangul syllables, and Fullwidth forms (UAX #11 Wide/Fullwidth),
// 0 for combining marks, and 1 for all other printable characters.
east_asian_cell_width :: proc "contextless" (r: rune) -> int {
	if (r >= 0x0300 && r <= 0x036F) || (r >= 0x1AB0 && r <= 0x1AFF) || (r >= 0xFE20 && r <= 0xFE2F) {
		return 0
	}
	switch {
	case r >= 0x1100 && r <= 0x115F: return 2 // Hangul Jamo
	case r >= 0x2E80 && r <= 0x303E: return 2 // CJK Radicals / Punctuation
	case r >= 0x3041 && r <= 0x33FF: return 2 // Hiragana, Katakana, Bopomofo, CJK Compat
	case r >= 0x3400 && r <= 0x4DBF: return 2 // CJK Extension A
	case r >= 0x4E00 && r <= 0x9FFF: return 2 // CJK Unified Ideographs
	case r >= 0xAC00 && r <= 0xD7A3: return 2 // Hangul Syllables
	case r >= 0xF900 && r <= 0xFAFF: return 2 // CJK Compat Ideographs
	case r >= 0xFF01 && r <= 0xFF60: return 2 // Fullwidth ASCII variants
	case r >= 0xFFE0 && r <= 0xFFE6: return 2 // Fullwidth symbols
	case r >= 0x20000 && r <= 0x2FFFD: return 2 // CJK Extensions B..F
	}
	return 1
}

Dict_Entry :: struct {
	key:   string,
	words: [3]string,
	count: int,
}

@(rodata)
PINYIN_TABLE := [?]Dict_Entry{
	{"ni", {"你", "泥", "拟"}, 3},
	{"hao", {"好", "号", "豪"}, 3},
	{"zhong", {"中", "重", "钟"}, 3},
	{"wen", {"文", "问", "温"}, 3},
}

@(rodata)
ROMAJI_TABLE := [?]Dict_Entry{
	{"ka", {"か", "カ", ""}, 2},
	{"ki", {"き", "キ", ""}, 2},
	{"ni", {"に", "ニ", ""}, 2},
	{"kon", {"こん", "今", ""}, 2},
}

@(private = "file")
refresh_candidates :: proc "contextless" (s: ^Ime_State) {
	s.candidate_count = 0
	s.selected_index = 0
	if s.preedit_len == 0 || s.mode == .Direct {
		return
	}
	key := string(s.preedit[:s.preedit_len])
	table: []Dict_Entry
	switch s.mode {
	case .Direct, .Hangul_Jamo:
		return
	case .Pinyin:
		table = PINYIN_TABLE[:]
	case .Romaji_Kana:
		table = ROMAJI_TABLE[:]
	}
	for entry in table {
		if entry.key == key {
			for i in 0 ..< min(entry.count, MAX_CANDIDATES) {
				wb := transmute([]u8)entry.words[i]
				if len(wb) > 0 && len(wb) <= MAX_CANDIDATE_BYTES {
					c: Candidate
					copy(c.text[:], wb)
					c.len = u8(len(wb))
					s.candidates[s.candidate_count] = c
					s.candidate_count += 1
				}
			}
			break
		}
	}
}

ime_init :: proc "contextless" (s: ^Ime_State, mode: Ime_Mode) -> Ime_Refusal {
	if s == nil {
		return .Nil_State
	}
	if _, ok := ime_mode_of_word(u64(mode)); !ok {
		return .Invalid_Mode
	}
	s^ = {mode = mode}
	return .None
}

ime_push_ascii :: proc "contextless" (s: ^Ime_State, ch: u8) -> Ime_Refusal {
	if s == nil {
		return .Nil_State
	}
	if ch < 'a' || ch > 'z' {
		return .Invalid_Char
	}
	if s.preedit_len >= MAX_PREEDIT_BYTES {
		return .Preedit_Full
	}
	s.preedit[s.preedit_len] = ch
	s.preedit_len += 1
	refresh_candidates(s)
	return .None
}

ime_backspace :: proc "contextless" (s: ^Ime_State) -> Ime_Refusal {
	if s == nil {
		return .Nil_State
	}
	if s.preedit_len == 0 {
		return .Empty_Preedit
	}
	s.preedit_len -= 1
	s.preedit[s.preedit_len] = 0
	refresh_candidates(s)
	return .None
}

ime_cancel :: proc "contextless" (s: ^Ime_State) -> Ime_Refusal {
	if s == nil {
		return .Nil_State
	}
	s.preedit = {}
	s.preedit_len = 0
	s.candidate_count = 0
	s.selected_index = 0
	return .None
}

// ime_commit_candidate commits candidate index (0-based) into out and clears preedit.
ime_commit_candidate :: proc "contextless" (s: ^Ime_State, index: int, out: []u8) -> (written: int, refusal: Ime_Refusal) {
	if s == nil {
		return 0, .Nil_State
	}
	if index < 0 || index >= s.candidate_count {
		return 0, .Invalid_Index
	}
	cand := &s.candidates[index]
	n := int(cand.len)
	if len(out) < n {
		return 0, .Buffer_Too_Small
	}
	copy(out[:n], cand.text[:n])
	_ = ime_cancel(s)
	return n, .None
}
