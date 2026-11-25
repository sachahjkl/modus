// Shared contract for Universal Shaping Engine (USE) script classification,
// syllable cluster segmentation with pre-base vowel reordering, and
// Mongolian/Phags-Pa topographical joining forms
// (src/md/features/written_shaping.md).
//
// Pure freestanding contract package: no kernel calls, no host imports, and
// no dynamic allocation. Covers Sinhala, Lao, Khmer, Myanmar, Tibetan,
// Javanese, Balinese, and Mongolian (plus Phags-Pa topographical forms).
package use_shaping

import "modus:contract/enum_word"

// Format property: matches the 16-item syllable cluster bound of written_shaping.md
// so caller stack buffers stay compact on freestanding worker threads.
USE_CLUSTER_MAX_ITEMS :: 16

// Plan value: maximum syllable clusters accepted in a single shaping pass.
USE_MAX_CLUSTERS :: 256

// Closed set of scripts supported by this USE shaping contract.
// Values cross process borders explicitly.
Use_Script :: enum u8 {
	None      = 0,
	Sinhala   = 1,
	Lao       = 2,
	Khmer     = 3,
	Myanmar   = 4,
	Tibetan   = 5,
	Javanese  = 6,
	Balinese  = 7,
	Mongolian = 8,
}

// Closed set of USE syllabic and positional character categories.
Use_Category :: enum u8 {
	Other       = 0,
	Base        = 1,
	Vowel_Pre   = 2,
	Vowel_Above = 3,
	Vowel_Below = 4,
	Vowel_Post  = 5,
	Virama      = 6,
	Halant      = 7,
	Tone_Mark   = 8,
	Joiner      = 9,
}

// Closed set of OpenType topographical joining forms (`isol`, `init`, `medi`, `fina`).
Topographical_Form :: enum u8 {
	Isolated = 0,
	Initial  = 1,
	Medial   = 2,
	Final    = 3,
}

// Closed set of refusal outcomes returned by USE shaping procedures.
Use_Shaping_Refusal :: enum u8 {
	None              = 0,
	Empty_Input       = 1,
	Output_Too_Small  = 2,
	Cluster_Too_Large = 3,
	Bad_Script        = 4,
	Bad_Codepoint     = 5,
}

// One shaped item in visual cluster order after pre-base vowel reordering and
// topographical form resolution.
Use_Glyph_Item :: struct {
	codepoint:     rune,
	logical_index: u32,
	script:        Use_Script,
	category:      Use_Category,
	form:          Topographical_Form,
}

// One segmented syllable cluster slice inside `out_glyphs[start : start + count]`.
Use_Cluster :: struct {
	start:       u32,
	count:       u16,
	script:      Use_Script,
	base_offset: u16,
}

// use_script_of_word converts a transport word into Use_Script at a border.
use_script_of_word :: proc "contextless" (word: u64) -> (script: Use_Script, ok: bool) {
	return enum_word.member_of_word(Use_Script, word)
}

// use_category_of_word converts a transport word into Use_Category at a border.
use_category_of_word :: proc "contextless" (word: u64) -> (cat: Use_Category, ok: bool) {
	return enum_word.member_of_word(Use_Category, word)
}

// topographical_form_of_word converts a transport word into Topographical_Form.
topographical_form_of_word :: proc "contextless" (word: u64) -> (form: Topographical_Form, ok: bool) {
	return enum_word.member_of_word(Topographical_Form, word)
}

// use_is_codepoint_valid reports whether `cp` is a Unicode scalar value.
use_is_codepoint_valid :: proc "contextless" (cp: rune) -> bool {
	if cp < 0 || cp > 0x10FFFF {
		return false
	}
	if cp >= 0xD800 && cp <= 0xDFFF {
		return false
	}
	return true
}

// use_classify_codepoint maps a Unicode scalar value to its USE script and
// syllabic/positional category across all 8 USE scripts plus global joiners.
use_classify_codepoint :: proc "contextless" (cp: rune) -> (script: Use_Script, category: Use_Category) {
	// Zero-width joiner and non-joiner apply across scripts.
	if cp == 0x200C || cp == 0x200D {
		return .None, .Joiner
	}

	switch cp {
	// Sinhala (U+0D80..U+0DFF)
	case 0x0D80 ..= 0x0DFF:
		return .Sinhala, classify_sinhala(cp)

	// Lao (U+0E80..U+0EFF)
	case 0x0E80 ..= 0x0EFF:
		return .Lao, classify_lao(cp)

	// Tibetan (U+0F00..U+0FFF)
	case 0x0F00 ..= 0x0FFF:
		return .Tibetan, classify_tibetan(cp)

	// Myanmar (U+1000..U+109F)
	case 0x1000 ..= 0x109F:
		return .Myanmar, classify_myanmar(cp)

	// Khmer (U+1780..U+17FF)
	case 0x1780 ..= 0x17FF:
		return .Khmer, classify_khmer(cp)

	// Mongolian (U+1800..U+18AF) and Phags-Pa (U+A840..U+A877)
	case 0x1800 ..= 0x18AF:
		return .Mongolian, classify_mongolian(cp)
	case 0xA840 ..= 0xA877:
		return .Mongolian, classify_phags_pa(cp)

	// Balinese (U+1B00..U+1B7F)
	case 0x1B00 ..= 0x1B7F:
		return .Balinese, classify_balinese(cp)

	// Javanese (U+A980..U+A9DF)
	case 0xA980 ..= 0xA9DF:
		return .Javanese, classify_javanese(cp)
	}
	return .None, .Other
}

// use_resolve_topographical resolves `isol`/`init`/`medi`/`fina` joining forms
// for Mongolian and Phags-Pa letter runs, treating ZWJ (U+200D) as join-causing,
// ZWNJ (U+200C) as join-breaking, and Mongolian variation selectors as transparent.
// Refuses Empty_Input, Bad_Codepoint, or Output_Too_Small with zero mutation.
use_resolve_topographical :: proc "contextless" (
	codepoints: []rune,
	out_forms: []Topographical_Form,
) -> (count: int, refusal: Use_Shaping_Refusal) {
	if len(codepoints) == 0 {
		return 0, .Empty_Input
	}
	for cp in codepoints {
		if !use_is_codepoint_valid(cp) {
			return 0, .Bad_Codepoint
		}
	}
	if len(out_forms) < len(codepoints) {
		return 0, .Output_Too_Small
	}

	n := len(codepoints)
	for i in 0 ..< n {
		cp := codepoints[i]
		if !is_topographical_letter(cp) {
			out_forms[i] = .Isolated
			continue
		}
		joins_prev := has_joining_neighbor(codepoints, i, -1)
		joins_next := has_joining_neighbor(codepoints, i, +1)
		switch {
		case joins_prev && joins_next:
			out_forms[i] = .Medial
		case !joins_prev && joins_next:
			out_forms[i] = .Initial
		case joins_prev && !joins_next:
			out_forms[i] = .Final
		case:
			out_forms[i] = .Isolated
		}
	}
	return n, .None
}

// use_shape_clusters classifies codepoints, segments syllable clusters, stably
// reorders pre-base vowels before each cluster base, and resolves Mongolian
// and Phags-Pa topographical joining forms.
// On any refusal, `out_glyphs` and `out_clusters` are not modified.
use_shape_clusters :: proc "contextless" (
	codepoints: []rune,
	out_glyphs: []Use_Glyph_Item,
	out_clusters: []Use_Cluster,
) -> (glyph_count: int, cluster_count: int, refusal: Use_Shaping_Refusal) {
	if len(codepoints) == 0 {
		return 0, 0, .Empty_Input
	}
	for cp in codepoints {
		if !use_is_codepoint_valid(cp) {
			return 0, 0, .Bad_Codepoint
		}
	}
	if len(out_glyphs) < len(codepoints) {
		return 0, 0, .Output_Too_Small
	}

	// Pass 1: validate cluster boundaries and capacities before mutating outputs.
	n := len(codepoints)
	needed_clusters := 0
	pos := 0
	for pos < n {
		cluster_end := find_cluster_end(codepoints, pos)
		cluster_len := cluster_end - pos
		if cluster_len > USE_CLUSTER_MAX_ITEMS {
			return 0, 0, .Cluster_Too_Large
		}
		needed_clusters += 1
		if needed_clusters > USE_MAX_CLUSTERS {
			return 0, 0, .Output_Too_Small
		}
		pos = cluster_end
	}
	if needed_clusters > len(out_clusters) {
		return 0, 0, .Output_Too_Small
	}

	// Pass 2: emit clusters with stable pre-base vowel reordering and joining forms.
	c_idx := 0
	pos = 0
	for pos < n {
		cluster_end := find_cluster_end(codepoints, pos)
		cluster_len := cluster_end - pos

		local_items: [USE_CLUSTER_MAX_ITEMS]Use_Glyph_Item
		cluster_script := Use_Script.None
		for k in 0 ..< cluster_len {
			orig := pos + k
			cp := codepoints[orig]
			sc, cat := use_classify_codepoint(cp)
			if cluster_script == .None && sc != .None {
				cluster_script = sc
			}
			form := Topographical_Form.Isolated
			if is_topographical_letter(cp) {
				jp := has_joining_neighbor(codepoints, orig, -1)
				jn := has_joining_neighbor(codepoints, orig, +1)
				switch {
				case jp && jn:  form = .Medial
				case !jp && jn: form = .Initial
				case jp && !jn: form = .Final
				case:           form = .Isolated
				}
			}
			local_items[k] = {
				codepoint     = cp,
				logical_index = u32(orig),
				script        = sc,
				category      = cat,
				form          = form,
			}
		}

		// Stable pre-base vowel reordering: place all Vowel_Pre items first in
		// their original order, followed by the remaining items of the cluster.
		write_at := pos
		pre_count := 0
		for k in 0 ..< cluster_len {
			if local_items[k].category == .Vowel_Pre {
				out_glyphs[write_at] = local_items[k]
				write_at += 1
				pre_count += 1
			}
		}
		base_off := u16(pre_count)
		found_base := false
		for k in 0 ..< cluster_len {
			if local_items[k].category != .Vowel_Pre {
				if !found_base && local_items[k].category == .Base {
					base_off = u16(write_at - pos)
					found_base = true
				}
				out_glyphs[write_at] = local_items[k]
				write_at += 1
			}
		}

		out_clusters[c_idx] = {
			start       = u32(pos),
			count       = u16(cluster_len),
			script      = cluster_script,
			base_offset = base_off,
		}
		c_idx += 1
		pos = cluster_end
	}

	return n, c_idx, .None
}

// ---- Private script tables and syllable helpers.

@(private = "file")
find_cluster_end :: proc "contextless" (codepoints: []rune, start: int) -> int {
	n := len(codepoints)
	if start >= n {
		return n
	}
	first_script, first_cat := use_classify_codepoint(codepoints[start])
	if first_cat == .Other {
		return start + 1
	}

	// Consume following combining marks, virama/halant conjuncts, vowels, tones, and joiners.
	prev_cat := first_cat
	i := start + 1
	for i < n {
		sc, cat := use_classify_codepoint(codepoints[i])
		if cat == .Other {
			break
		}
		// Script change starts a new cluster (except script-neutral joiners).
		if sc != .None && first_script != .None && sc != first_script {
			break
		}
		if cat == .Base {
			// A consonant after Virama/Halant (or Virama+Joiner) joins the same syllable cluster.
			joined_by_virama := prev_cat == .Virama || prev_cat == .Halant
			if !joined_by_virama && prev_cat == .Joiner && i >= start + 2 {
				_, before_joiner := use_classify_codepoint(codepoints[i - 2])
				joined_by_virama = before_joiner == .Virama || before_joiner == .Halant
			}
			if !joined_by_virama {
				break
			}
		}
		prev_cat = cat
		i += 1
	}
	return i
}

@(private = "file")
is_topographical_letter :: proc "contextless" (cp: rune) -> bool {
	if (cp >= 0x1820 && cp <= 0x1878) || (cp >= 0x1880 && cp <= 0x18AA) {
		return true
	}
	if cp >= 0xA840 && cp <= 0xA873 {
		return true
	}
	return false
}

@(private = "file")
is_topographical_transparent :: proc "contextless" (cp: rune) -> bool {
	return (cp >= 0x180B && cp <= 0x180D) || cp == 0x180F
}

@(private = "file")
has_joining_neighbor :: proc "contextless" (codepoints: []rune, index: int, dir: int) -> bool {
	i := index + dir
	for i >= 0 && i < len(codepoints) {
		cp := codepoints[i]
		if is_topographical_transparent(cp) {
			i += dir
			continue
		}
		if cp == 0x200D {
			return true
		}
		if cp == 0x200C {
			return false
		}
		return is_topographical_letter(cp)
	}
	return false
}

@(private = "file")
classify_sinhala :: proc "contextless" (cp: rune) -> Use_Category {
	switch cp {
	case 0x0D85 ..= 0x0D96, 0x0D9A ..= 0x0DC6:
		return .Base
	case 0x0DCA:
		return .Halant
	case 0x0DD9 ..= 0x0DDE:
		return .Vowel_Pre
	case 0x0DD2, 0x0DD3:
		return .Vowel_Above
	case 0x0DD4, 0x0DD6:
		return .Vowel_Below
	case 0x0DCF ..= 0x0DD1, 0x0DD8, 0x0DDF, 0x0DF2, 0x0DF3:
		return .Vowel_Post
	case 0x0D81 ..= 0x0D83:
		return .Tone_Mark
	}
	return .Other
}

@(private = "file")
classify_lao :: proc "contextless" (cp: rune) -> Use_Category {
	switch cp {
	case 0x0E81 ..= 0x0EAE, 0x0EDC ..= 0x0EDF:
		return .Base
	case 0x0EC0 ..= 0x0EC4:
		return .Vowel_Pre
	case 0x0EB1, 0x0EB4 ..= 0x0EB7, 0x0EBB, 0x0ECD:
		return .Vowel_Above
	case 0x0EB8, 0x0EB9, 0x0EBC:
		return .Vowel_Below
	case 0x0EB0, 0x0EB2, 0x0EB3, 0x0EBD:
		return .Vowel_Post
	case 0x0EC8 ..= 0x0ECC:
		return .Tone_Mark
	}
	return .Other
}

@(private = "file")
classify_khmer :: proc "contextless" (cp: rune) -> Use_Category {
	switch cp {
	case 0x1780 ..= 0x17B3:
		return .Base
	case 0x17D2:
		return .Virama
	case 0x17C1 ..= 0x17C5:
		return .Vowel_Pre
	case 0x17B7 ..= 0x17BA, 0x17C6, 0x17C9 ..= 0x17D1, 0x17D3, 0x17DD:
		return .Vowel_Above
	case 0x17BB ..= 0x17BD:
		return .Vowel_Below
	case 0x17B6, 0x17BE ..= 0x17C0, 0x17C7, 0x17C8:
		return .Vowel_Post
	}
	return .Other
}

@(private = "file")
classify_myanmar :: proc "contextless" (cp: rune) -> Use_Category {
	switch cp {
	case 0x1000 ..= 0x102A, 0x103F:
		return .Base
	case 0x1039:
		return .Virama
	case 0x103A:
		return .Halant
	case 0x1031, 0x103C:
		return .Vowel_Pre
	case 0x102D, 0x102E, 0x1032, 0x1036, 0x103D:
		return .Vowel_Above
	case 0x102F, 0x1030, 0x103E:
		return .Vowel_Below
	case 0x102B, 0x102C, 0x103B:
		return .Vowel_Post
	case 0x1037, 0x1038:
		return .Tone_Mark
	}
	return .Other
}

@(private = "file")
classify_tibetan :: proc "contextless" (cp: rune) -> Use_Category {
	switch cp {
	case 0x0F40 ..= 0x0F6C:
		return .Base
	case 0x0F84:
		return .Halant
	case 0x0F72, 0x0F7A ..= 0x0F7E, 0x0F80, 0x0F82, 0x0F83, 0x0F86, 0x0F87:
		return .Vowel_Above
	case 0x0F71, 0x0F74, 0x0F90 ..= 0x0FBC:
		return .Vowel_Below
	case 0x0F7F:
		return .Vowel_Post
	}
	return .Other
}

@(private = "file")
classify_javanese :: proc "contextless" (cp: rune) -> Use_Category {
	switch cp {
	case 0xA984 ..= 0xA9B2:
		return .Base
	case 0xA9C0:
		return .Halant
	case 0xA9BA, 0xA9BB:
		return .Vowel_Pre
	case 0xA980 ..= 0xA982, 0xA9B3, 0xA9B6, 0xA9B7, 0xA9BC:
		return .Vowel_Above
	case 0xA9B8, 0xA9B9, 0xA9BD ..= 0xA9BF:
		return .Vowel_Below
	case 0xA983, 0xA9B4, 0xA9B5:
		return .Vowel_Post
	}
	return .Other
}

@(private = "file")
classify_balinese :: proc "contextless" (cp: rune) -> Use_Category {
	switch cp {
	case 0x1B05 ..= 0x1B33, 0x1B45 ..= 0x1B4C:
		return .Base
	case 0x1B44:
		return .Virama
	case 0x1B3E ..= 0x1B41:
		return .Vowel_Pre
	case 0x1B00 ..= 0x1B03, 0x1B34, 0x1B36, 0x1B37, 0x1B42, 0x1B43:
		return .Vowel_Above
	case 0x1B38 ..= 0x1B3C:
		return .Vowel_Below
	case 0x1B04, 0x1B35, 0x1B3D:
		return .Vowel_Post
	}
	return .Other
}

@(private = "file")
classify_mongolian :: proc "contextless" (cp: rune) -> Use_Category {
	switch cp {
	case 0x1820 ..= 0x1878, 0x1880 ..= 0x18AA:
		return .Base
	case 0x180B ..= 0x180F:
		return .Joiner
	}
	return .Other
}

@(private = "file")
classify_phags_pa :: proc "contextless" (cp: rune) -> Use_Category {
	if cp >= 0xA840 && cp <= 0xA873 {
		return .Base
	}
	return .Other
}
