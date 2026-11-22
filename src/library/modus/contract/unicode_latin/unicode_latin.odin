// Pure freestanding Unicode text algorithms for Latin scripts
// (src/md/features/interface_language.md, "Unicode text for Latin"):
//
// 1. NFC check and canonical composition for Latin (refusing NFD look-alikes);
// 2. UAX #29 extended grapheme cluster stepping (base + combining marks, CRLF,
//    regional indicators) for line editing;
// 3. UAX #14 line break opportunities (spaces, hyphens, mandatory breaks);
// 4. Multi-level Latin collation for French and English so accented words sort
//    in reader order instead of raw UTF-8 codepoint order.
//
// Zero dynamic allocations, zero kernel operations, and strict UTF-8 borders.
package unicode_latin

import "modus:contract/enum_word"
import "modus:contract/text_encoding"

// Supported collation locales for Latin sorting.
Collation_Locale :: enum u8 {
	English = 1,
	French  = 2,
}

collation_locale_of_word :: proc "contextless" (word: u64) -> (locale: Collation_Locale, ok: bool) {
	return enum_word.member_of_word(Collation_Locale, word)
}

// Combining diacritical marks relevant to Latin NFC and UAX #29.
COMBINING_GRAVE     :: rune(0x0300)
COMBINING_ACUTE     :: rune(0x0301)
COMBINING_CIRCUMFLEX :: rune(0x0302)
COMBINING_TILDE     :: rune(0x0303)
COMBINING_DIAERESIS :: rune(0x0308)
COMBINING_RING      :: rune(0x030A)
COMBINING_CEDILLA   :: rune(0x0327)

// Canonical combining class (CCC) for Latin combining marks (0 = starter).
combining_class :: proc "contextless" (r: rune) -> u8 {
	if r == COMBINING_CEDILLA {
		return 202
	}
	if r >= 0x0300 && r <= 0x036F {
		return 230
	}
	return 0
}

// is_combining_mark reports whether r is a Unicode combining mark (Mn/Mc subset).
is_combining_mark :: proc "contextless" (r: rune) -> bool {
	return (r >= 0x0300 && r <= 0x036F) || (r >= 0x1AB0 && r <= 0x1AFF) || (r >= 0x1DC0 && r <= 0x1DFF) || (r >= 0xFE20 && r <= 0xFE2F)
}

is_regional_indicator :: proc "contextless" (r: rune) -> bool {
	return r >= 0x1F1E6 && r <= 0x1F1FF
}

// Canonical Latin composition table: (base, mark) -> NFC precomposed rune.
Composition_Pair :: struct {
	base:     rune,
	mark:     rune,
	composed: rune,
}

@(rodata)
LATIN_COMPOSITIONS := [?]Composition_Pair{
	// Grave
	{'A', COMBINING_GRAVE, 'À'}, {'a', COMBINING_GRAVE, 'à'},
	{'E', COMBINING_GRAVE, 'È'}, {'e', COMBINING_GRAVE, 'è'},
	{'I', COMBINING_GRAVE, 'Ì'}, {'i', COMBINING_GRAVE, 'ì'},
	{'O', COMBINING_GRAVE, 'Ò'}, {'o', COMBINING_GRAVE, 'ò'},
	{'U', COMBINING_GRAVE, 'Ù'}, {'u', COMBINING_GRAVE, 'ù'},
	// Acute
	{'A', COMBINING_ACUTE, 'Á'}, {'a', COMBINING_ACUTE, 'á'},
	{'E', COMBINING_ACUTE, 'É'}, {'e', COMBINING_ACUTE, 'é'},
	{'I', COMBINING_ACUTE, 'Í'}, {'i', COMBINING_ACUTE, 'í'},
	{'O', COMBINING_ACUTE, 'Ó'}, {'o', COMBINING_ACUTE, 'ó'},
	{'U', COMBINING_ACUTE, 'Ú'}, {'u', COMBINING_ACUTE, 'ú'},
	{'Y', COMBINING_ACUTE, 'Ý'}, {'y', COMBINING_ACUTE, 'ý'},
	// Circumflex
	{'A', COMBINING_CIRCUMFLEX, 'Â'}, {'a', COMBINING_CIRCUMFLEX, 'â'},
	{'E', COMBINING_CIRCUMFLEX, 'Ê'}, {'e', COMBINING_CIRCUMFLEX, 'ê'},
	{'I', COMBINING_CIRCUMFLEX, 'Î'}, {'i', COMBINING_CIRCUMFLEX, 'î'},
	{'O', COMBINING_CIRCUMFLEX, 'Ô'}, {'o', COMBINING_CIRCUMFLEX, 'ô'},
	{'U', COMBINING_CIRCUMFLEX, 'Û'}, {'u', COMBINING_CIRCUMFLEX, 'û'},
	// Tilde
	{'A', COMBINING_TILDE, 'Ã'}, {'a', COMBINING_TILDE, 'ã'},
	{'N', COMBINING_TILDE, 'Ñ'}, {'n', COMBINING_TILDE, 'ñ'},
	{'O', COMBINING_TILDE, 'Õ'}, {'o', COMBINING_TILDE, 'õ'},
	// Diaeresis
	{'A', COMBINING_DIAERESIS, 'Ä'}, {'a', COMBINING_DIAERESIS, 'ä'},
	{'E', COMBINING_DIAERESIS, 'Ë'}, {'e', COMBINING_DIAERESIS, 'ë'},
	{'I', COMBINING_DIAERESIS, 'Ï'}, {'i', COMBINING_DIAERESIS, 'ï'},
	{'O', COMBINING_DIAERESIS, 'Ö'}, {'o', COMBINING_DIAERESIS, 'ö'},
	{'U', COMBINING_DIAERESIS, 'Ü'}, {'u', COMBINING_DIAERESIS, 'ü'},
	{'Y', COMBINING_DIAERESIS, 'Ÿ'}, {'y', COMBINING_DIAERESIS, 'ÿ'},
	// Ring
	{'A', COMBINING_RING, 'Å'}, {'a', COMBINING_RING, 'å'},
	// Cedilla
	{'C', COMBINING_CEDILLA, 'Ç'}, {'c', COMBINING_CEDILLA, 'ç'},
}

latin_compose :: proc "contextless" (base, mark: rune) -> (composed: rune, ok: bool) {
	for pair in LATIN_COMPOSITIONS {
		if pair.base == base && pair.mark == mark {
			return pair.composed, true
		}
	}
	return 0, false
}

@(private = "file")
utf8_encode_rune :: proc "contextless" (r: rune, out: []u8) -> (n: int, ok: bool) {
	v := u32(r)
	switch {
	case v <= 0x7F:
		if len(out) < 1 {
			return 0, false
		}
		out[0] = u8(v)
		return 1, true
	case v <= 0x7FF:
		if len(out) < 2 {
			return 0, false
		}
		out[0] = 0xC0 | u8(v >> 6)
		out[1] = 0x80 | u8(v & 0x3F)
		return 2, true
	case v <= 0xFFFF:
		if len(out) < 3 {
			return 0, false
		}
		out[0] = 0xE0 | u8(v >> 12)
		out[1] = 0x80 | u8((v >> 6) & 0x3F)
		out[2] = 0x80 | u8(v & 0x3F)
		return 3, true
	case v <= 0x10FFFF:
		if len(out) < 4 {
			return 0, false
		}
		out[0] = 0xF0 | u8(v >> 18)
		out[1] = 0x80 | u8((v >> 12) & 0x3F)
		out[2] = 0x80 | u8((v >> 6) & 0x3F)
		out[3] = 0x80 | u8(v & 0x3F)
		return 4, true
	}
	return 0, false
}

// ============================================================================
// 1. NFC Check & Latin Canonical Composition
// ============================================================================

// is_nfc_latin reports whether text is valid UTF-8 in Unicode NFC for Latin:
// rejects invalid UTF-8, out-of-order combining classes, and any starter +
// combining mark that has a canonical Latin NFC composition.
is_nfc_latin :: proc "contextless" (text: string) -> bool {
	if !text_encoding.text_valid(transmute([]u8)text) {
		return false
	}
	bytes := transmute([]u8)text
	pos := 0
	last_starter := rune(0)
	has_starter := false
	last_ccc := u8(0)
	for pos < len(bytes) {
		r, width, ok := text_encoding.character_decode(bytes, pos)
		if !ok || width <= 0 {
			return false
		}
		pos += width
		ccc := combining_class(r)
		if ccc == 0 {
			last_starter = r
			has_starter = true
			last_ccc = 0
			continue
		}
		if last_ccc > ccc {
			return false
		}
		if has_starter && (last_ccc == 0 || last_ccc < ccc) {
			if _, can_compose := latin_compose(last_starter, r); can_compose {
				return false
			}
		}
		last_ccc = ccc
	}
	return true
}

// normalize_nfc_latin writes the NFC-composed form of Latin UTF-8 text into out.
// Refuses invalid UTF-8 or insufficient output capacity without partial claims.
normalize_nfc_latin :: proc "contextless" (text: string, out: []u8) -> (written: int, ok: bool) {
	if !text_encoding.text_valid(transmute([]u8)text) {
		return 0, false
	}
	bytes := transmute([]u8)text
	pos := 0
	has_pending := false
	pending := rune(0)
	w := 0

	flush_pending :: proc "contextless" (has: ^bool, r: rune, out: []u8, w: ^int) -> bool {
		if !has^ {
			return true
		}
		n, enc_ok := utf8_encode_rune(r, out[w^:])
		if !enc_ok {
			return false
		}
		w^ += n
		has^ = false
		return true
	}

	for pos < len(bytes) {
		r, width, dec_ok := text_encoding.character_decode(bytes, pos)
		if !dec_ok || width <= 0 {
			return 0, false
		}
		pos += width
		if has_pending && combining_class(r) != 0 {
			if composed, can_compose := latin_compose(pending, r); can_compose {
				pending = composed
				continue
			}
		}
		if !flush_pending(&has_pending, pending, out, &w) {
			return 0, false
		}
		pending = r
		has_pending = true
	}
	if !flush_pending(&has_pending, pending, out, &w) {
		return 0, false
	}
	return w, true
}

// ============================================================================
// 2. UAX #29 Extended Grapheme Cluster Stepping
// ============================================================================

// grapheme_next returns the byte offset of the end of the grapheme cluster
// starting at offset (keeping CRLF, base + combining marks, and regional
// indicator pairs intact).
grapheme_next :: proc "contextless" (text: string, offset: int) -> int {
	bytes := transmute([]u8)text
	if offset < 0 {
		return 0
	}
	if offset >= len(bytes) {
		return len(bytes)
	}
	// Keep CR and LF together as one grapheme cluster (ASCII control bytes).
	if bytes[offset] == '\r' && offset + 1 < len(bytes) && bytes[offset + 1] == '\n' {
		return offset + 2
	}
	r0, w0, ok := text_encoding.character_decode(bytes, offset)
	if !ok || w0 <= 0 {
		return min(offset + 1, len(bytes))
	}
	pos := offset + w0
	// Keep regional indicator pairs together.
	if is_regional_indicator(r0) && pos < len(bytes) {
		r1, w1, ok1 := text_encoding.character_decode(bytes, pos)
		if ok1 && w1 > 0 && is_regional_indicator(r1) {
			pos += w1
		}
	}
	// Attach following combining marks and ZWJ sequences.
	for pos < len(bytes) {
		r, wn, ok_next := text_encoding.character_decode(bytes, pos)
		if !ok_next || wn <= 0 {
			break
		}
		if is_combining_mark(r) {
			pos += wn
			continue
		}
		if r == 0x200D { // ZWJ: keep joiner and following code point together.
			pos += wn
			if pos < len(bytes) {
				_, wa, ok_after := text_encoding.character_decode(bytes, pos)
				if ok_after && wa > 0 {
					pos += wa
				}
			}
			continue
		}
		break
	}
	return pos
}

// grapheme_prev returns the byte offset of the start of the grapheme cluster
// immediately preceding offset.
grapheme_prev :: proc "contextless" (text: string, offset: int) -> int {
	bytes := transmute([]u8)text
	if offset <= 0 {
		return 0
	}
	target := min(offset, len(bytes))
	prev := 0
	cur := 0
	for cur < target {
		next := grapheme_next(text, cur)
		if next <= cur {
			break
		}
		prev = cur
		cur = next
	}
	return prev
}

// ============================================================================
// 3. UAX #14 Line Break Finder
// ============================================================================

Line_Break_Kind :: enum u8 {
	None      = 0,
	Soft      = 1, // Break after space or hyphen.
	Mandatory = 2, // Break after LF or CRLF.
	Forced    = 3, // Hard break at max_columns when no earlier soft break fits.
}

@(private = "file")
is_non_starting_punctuation :: proc "contextless" (r: rune) -> bool {
	switch r {
	case '.', ',', ';', ':', '!', '?', ')', ']', '}', '»':
		return true
	}
	return false
}

// line_break_next computes the byte end of the next wrapped line starting at
// start_offset within max_columns grapheme clusters.
line_break_next :: proc "contextless" (text: string, start_offset: int, max_columns: int) -> (end_offset: int, kind: Line_Break_Kind) {
	bytes := transmute([]u8)text
	if start_offset < 0 || start_offset >= len(bytes) || max_columns <= 0 {
		return clamp(start_offset, 0, len(bytes)), .None
	}
	pos := start_offset
	cols := 0
	last_soft := -1

	for pos < len(bytes) {
		next := grapheme_next(text, pos)
		if next <= pos {
			break
		}
		// Mandatory newline break (ASCII LF or CRLF).
		if bytes[pos] == '\n' || (bytes[pos] == '\r' && next == pos + 2 && bytes[pos + 1] == '\n') {
			return next, .Mandatory
		}
		r, _, _ := text_encoding.character_decode(bytes, pos)
		if cols + 1 > max_columns {
			if last_soft > start_offset {
				return last_soft, .Soft
			}
			return pos > start_offset ? pos : next, .Forced
		}
		pos = next
		cols += 1
		// Record break opportunity after space or hyphen unless followed by non-starting punctuation.
		if r == ' ' || r == '-' {
			allow := true
			if pos < len(bytes) {
				peek, _, ok := text_encoding.character_decode(bytes, pos)
				if ok && is_non_starting_punctuation(peek) {
					allow = false
				}
			}
			if allow {
				last_soft = pos
			}
		}
	}
	return len(bytes), .None
}

// ============================================================================
// 4. Multi-Level French / English Latin Collation
// ============================================================================

Collation_Weight :: struct {
	primary:   u16, // Base letter weight ('a'..'z' mapped uniformly).
	secondary: u8,  // Diacritic weight (0 = base, 1 = acute, 2 = grave, 3 = circumflex, 4 = diaeresis, 5 = cedilla, 6 = tilde, 7 = ring).
	tertiary:  u8,  // Case weight (0 = lowercase, 1 = uppercase).
}

@(private = "file")
latin_weight :: proc "contextless" (r: rune) -> Collation_Weight {
	switch r {
	case 'a' ..= 'z':
		return {primary = u16(r), secondary = 0, tertiary = 0}
	case 'A' ..= 'Z':
		return {primary = u16(r - 'A' + 'a'), secondary = 0, tertiary = 1}
	case 'á': return {primary = 'a', secondary = 1, tertiary = 0}
	case 'Á': return {primary = 'a', secondary = 1, tertiary = 1}
	case 'à': return {primary = 'a', secondary = 2, tertiary = 0}
	case 'À': return {primary = 'a', secondary = 2, tertiary = 1}
	case 'â': return {primary = 'a', secondary = 3, tertiary = 0}
	case 'Â': return {primary = 'a', secondary = 3, tertiary = 1}
	case 'ä': return {primary = 'a', secondary = 4, tertiary = 0}
	case 'Ä': return {primary = 'a', secondary = 4, tertiary = 1}
	case 'ã': return {primary = 'a', secondary = 6, tertiary = 0}
	case 'Ã': return {primary = 'a', secondary = 6, tertiary = 1}
	case 'å': return {primary = 'a', secondary = 7, tertiary = 0}
	case 'Å': return {primary = 'a', secondary = 7, tertiary = 1}
	case 'ç': return {primary = 'c', secondary = 5, tertiary = 0}
	case 'Ç': return {primary = 'c', secondary = 5, tertiary = 1}
	case 'é': return {primary = 'e', secondary = 1, tertiary = 0}
	case 'É': return {primary = 'e', secondary = 1, tertiary = 1}
	case 'è': return {primary = 'e', secondary = 2, tertiary = 0}
	case 'È': return {primary = 'e', secondary = 2, tertiary = 1}
	case 'ê': return {primary = 'e', secondary = 3, tertiary = 0}
	case 'Ê': return {primary = 'e', secondary = 3, tertiary = 1}
	case 'ë': return {primary = 'e', secondary = 4, tertiary = 0}
	case 'Ë': return {primary = 'e', secondary = 4, tertiary = 1}
	case 'í': return {primary = 'i', secondary = 1, tertiary = 0}
	case 'Í': return {primary = 'i', secondary = 1, tertiary = 1}
	case 'ì': return {primary = 'i', secondary = 2, tertiary = 0}
	case 'Ì': return {primary = 'i', secondary = 2, tertiary = 1}
	case 'î': return {primary = 'i', secondary = 3, tertiary = 0}
	case 'Î': return {primary = 'i', secondary = 3, tertiary = 1}
	case 'ï': return {primary = 'i', secondary = 4, tertiary = 0}
	case 'Ï': return {primary = 'i', secondary = 4, tertiary = 1}
	case 'ñ': return {primary = 'n', secondary = 6, tertiary = 0}
	case 'Ñ': return {primary = 'n', secondary = 6, tertiary = 1}
	case 'ó': return {primary = 'o', secondary = 1, tertiary = 0}
	case 'Ó': return {primary = 'o', secondary = 1, tertiary = 1}
	case 'ò': return {primary = 'o', secondary = 2, tertiary = 0}
	case 'Ò': return {primary = 'o', secondary = 2, tertiary = 1}
	case 'ô': return {primary = 'o', secondary = 3, tertiary = 0}
	case 'Ô': return {primary = 'o', secondary = 3, tertiary = 1}
	case 'ö': return {primary = 'o', secondary = 4, tertiary = 0}
	case 'Ö': return {primary = 'o', secondary = 4, tertiary = 1}
	case 'õ': return {primary = 'o', secondary = 6, tertiary = 0}
	case 'Õ': return {primary = 'o', secondary = 6, tertiary = 1}
	case 'œ': return {primary = 'o', secondary = 8, tertiary = 0}
	case 'Œ': return {primary = 'o', secondary = 8, tertiary = 1}
	case 'æ': return {primary = 'a', secondary = 8, tertiary = 0}
	case 'Æ': return {primary = 'a', secondary = 8, tertiary = 1}
	case 'ú': return {primary = 'u', secondary = 1, tertiary = 0}
	case 'Ú': return {primary = 'u', secondary = 1, tertiary = 1}
	case 'ù': return {primary = 'u', secondary = 2, tertiary = 0}
	case 'Ù': return {primary = 'u', secondary = 2, tertiary = 1}
	case 'û': return {primary = 'u', secondary = 3, tertiary = 0}
	case 'Û': return {primary = 'u', secondary = 3, tertiary = 1}
	case 'ü': return {primary = 'u', secondary = 4, tertiary = 0}
	case 'Ü': return {primary = 'u', secondary = 4, tertiary = 1}
	case 'ÿ': return {primary = 'y', secondary = 4, tertiary = 0}
	case 'Ÿ': return {primary = 'y', secondary = 4, tertiary = 1}
	}
	return {primary = u16(min(u32(r), u32(max(u16)))), secondary = 0, tertiary = 0}
}

// collate_latin compares two UTF-8 strings in primary (base letter), secondary
// (diacritic; backwards in French per CLDR/UCA), and tertiary (case) order.
// Returns -1 (a < b), 0 (a == b), or +1 (a > b).
collate_latin :: proc "contextless" (a, b: string, locale: Collation_Locale) -> int {
	a_bytes := transmute([]u8)a
	b_bytes := transmute([]u8)b
	MAX_WEIGHTS :: 128
	wa: [MAX_WEIGHTS]Collation_Weight
	wb: [MAX_WEIGHTS]Collation_Weight
	na, nb := 0, 0
	for pos := 0; pos < len(a_bytes) && na < MAX_WEIGHTS; {
		r, width, ok := text_encoding.character_decode(a_bytes, pos)
		if !ok || width <= 0 {
			break
		}
		pos += width
		wa[na] = latin_weight(r)
		na += 1
	}
	for pos := 0; pos < len(b_bytes) && nb < MAX_WEIGHTS; {
		r, width, ok := text_encoding.character_decode(b_bytes, pos)
		if !ok || width <= 0 {
			break
		}
		pos += width
		wb[nb] = latin_weight(r)
		nb += 1
	}

	// Pass 1: primary (base letters).
	nmin := min(na, nb)
	for i in 0 ..< nmin {
		if wa[i].primary < wb[i].primary {
			return -1
		}
		if wa[i].primary > wb[i].primary {
			return 1
		}
	}
	if na != nb {
		return na < nb ? -1 : 1
	}

	// Pass 2: secondary (diacritics; backwards for French per CLDR).
	switch locale {
	case .French:
		for i := na - 1; i >= 0; i -= 1 {
			if wa[i].secondary < wb[i].secondary {
				return -1
			}
			if wa[i].secondary > wb[i].secondary {
				return 1
			}
		}
	case .English:
		for i in 0 ..< na {
			if wa[i].secondary < wb[i].secondary {
				return -1
			}
			if wa[i].secondary > wb[i].secondary {
				return 1
			}
		}
	}

	// Pass 3: tertiary (case).
	for i in 0 ..< na {
		if wa[i].tertiary < wb[i].tertiary {
			return -1
		}
		if wa[i].tertiary > wb[i].tertiary {
			return 1
		}
	}
	return 0
}
