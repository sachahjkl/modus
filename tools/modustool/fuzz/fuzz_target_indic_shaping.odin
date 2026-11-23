package fuzz

import "core:mem"
import "modus:contract/font_outlines"
import "modus:contract/text_encoding"
import "modus:text_rendering"
import "modus:vector_font"

// The fuzz target of the shaper of the scripts of India over a hostile
// font (src/md/features/written_shaping.md, "The scripts of India"): the
// text of the input in the blocks of India, with joiners, shaped with a
// copy of Noto Sans Devanagari whose tables GSUB, GPOS and GDEF the input
// changes at the places it names. Each character draws: the count of
// glyphs is at least one for each syllable and at most the glyphs of a
// shaped cluster for each character; each cluster is the first byte of a
// character; text_width agrees with shape; and the work of the call stays
// in its budget, so a hostile table ends a call, never hangs it.

// The head of an input: the bytes of the text that follow it, then the
// changes of the tables, each a place and a byte.
@(private = "file")
Fuzz_Indic_Head :: struct #packed {
	text_count: u16,
}

@(private = "file")
Fuzz_Indic_Change :: struct #packed {
	place: u32, // In the tables GSUB, GPOS and GDEF, one after the other, modulo their bytes.
	value: u8,
}

FUZZ_INDIC_INPUT_LIMIT :: 4 << 10

// The set of the target: the fonts of the boot image and Noto Sans
// Devanagari, opened once at the start and only read after it.
@(private = "file")
fuzz_indic_fonts: ^text_rendering.Font_Set
@(private = "file")
fuzz_indic_words: []u64

fuzz_indic_shaping_start :: proc() -> bool {
	// With no Noto Sans Devanagari the target has nothing to shape: it does
	// not start, so the run counts no execution as a pass.
	// fuzz_script_font_file said why on the error output.
	devanagari, found := fuzz_script_font_file("noto_sans_devanagari")
	if !found {
		return false
	}
	fonts := [6]font_outlines.Font_Input {
		{"b612", #load("../../../resources/fonts/b612.ttf")},
		{"b612_bold", #load("../../../resources/fonts/b612_bold.ttf")},
		{"paper_mono", #load("../../../resources/fonts/paper_mono.ttf")},
		{"paper_mono_semibold", #load("../../../resources/fonts/paper_mono_semibold.ttf")},
		{"noto_sans", #load("../../../resources/fonts/noto_sans.ttf")},
		{"noto_sans_devanagari", devanagari},
	}
	size := font_outlines.resource_size(fonts[:])
	fuzz_indic_words = make([]u64, (size + 7) / 8)
	bytes := ([^]u8)(raw_data(fuzz_indic_words))[:size]
	if _, written := font_outlines.resource_write(fonts[:], bytes); !written {
		return false
	}
	room := new(font_outlines.Record_Room)
	outlines, problem := font_outlines.validate(bytes, room[:])
	if problem.kind != .None {
		return false
	}
	fuzz_indic_fonts = new(text_rendering.Font_Set)
	fuzz_indic_fonts.room = new(text_rendering.Font_Room)[:]
	memory := new(text_rendering.Outline_Memory)
	outline := text_rendering.outline_of(memory)
	_ = text_rendering.fonts_open(fuzz_indic_fonts, &outlines, &outline)
	missing := text_rendering.script_fonts_open_in(fuzz_indic_fonts, &outlines, &outline)
	return .Noto_Sans_Devanagari not_in missing
}

// fuzz_indic_text writes the text of an input: each byte a character of
// the blocks of India (its script from its high bits, its place in the
// block from the low ones), a joiner or a non-joiner.
@(private = "file")
fuzz_indic_text :: proc(input: []u8) -> []u8 {
	text := make([dynamic]u8, context.temp_allocator)
	for byte in input {
		character: rune
		switch {
		case byte == 0xFE:
			character = 0x200D
		case byte == 0xFF:
			character = 0x200C
		case:
			character = 0x0900 + rune(byte & 0x7F) + (byte & 0x80 != 0 ? 0x80 * rune(byte % 9) : 0)
		}
		encoded: [4]u8
		length := text_encoding.character_encode(character, encoded[:])
		append(&text, ..encoded[:length])
	}
	return text[:]
}

fuzz_indic_shaping_execute :: proc(input: []u8) -> Fuzz_Verdict {
	// The start opened the fonts, or the target did not start.
	if fuzz_indic_fonts == nil {
		return fuzz_broken(.Contract, "the target runs with no fonts: its start did not open Noto Sans Devanagari")
	}
	head: Fuzz_Indic_Head
	copy(mem.ptr_to_bytes(&head), input)
	rest := input[min(len(input), size_of(head)):]
	text_count := min(int(head.text_count), len(rest))
	text := fuzz_indic_text(rest[:text_count])
	rest = rest[text_count:]
	// A copy of the font, with the changes of the input in its tables.
	shared := text_rendering.font_at(fuzz_indic_fonts, .Noto_Sans_Devanagari)
	font := shared^
	bytes := make([]u8, len(shared.file.bytes), context.temp_allocator)
	copy(bytes, shared.file.bytes)
	font.file.bytes = bytes
	parts := [3]vector_font.Table{font.file.gsub, font.file.gpos, font.file.gdef}
	span := 0
	for part in parts {
		span += part.length
	}
	for len(rest) >= size_of(Fuzz_Indic_Change) && span > 0 {
		change: Fuzz_Indic_Change
		copy(mem.ptr_to_bytes(&change), rest)
		rest = rest[size_of(change):]
		place := int(change.place) % span
		for part in parts {
			if place < part.length {
				bytes[part.offset + place] = change.value
				break
			}
			place -= part.length
		}
	}
	set := fuzz_indic_fonts^
	set.fonts[.Noto_Sans_Devanagari] = &font
	spacing, ok := text_rendering.spacing_in(&set, .Interface, text_rendering.TEXT_SIZE_OF_SCALE_ONE)
	if !ok {
		return fuzz_broken(.Contract, "the set of the target gives no spacing")
	}
	characters := text_encoding.character_count(text)
	placed := make([]text_rendering.Placed_Glyph, (1 + text_rendering.CLUSTER_MARK_LIMIT) * max(characters, 1), context.temp_allocator)
	count, width, shaped := text_rendering.shape(&spacing, text, placed)
	if !shaped || count > len(placed) || characters > 0 && count == 0 {
		return fuzz_broken(.Contract, "shape gives %d glyphs, %v, for %d characters", count, shaped, characters)
	}
	starts := make([]bool, len(text) + 1, context.temp_allocator)
	for place := 0; place < len(text); {
		_, length, _ := text_encoding.character_decode(text, place)
		starts[place] = true
		place += max(length, 1)
	}
	sum: i64
	for glyph, index in placed[:count] {
		if int(glyph.cluster) >= len(text) || !starts[glyph.cluster] {
			return fuzz_broken(.Contract, "the glyph %d names the byte %d, which starts no character", index, glyph.cluster)
		}
		sum += i64(glyph.advance)
	}
	if sum != width {
		return fuzz_broken(.Contract, "shape gives the width %d; its advances give %d", width, sum)
	}
	if measured, measured_ok := text_rendering.text_width(&spacing, text); !measured_ok || measured != width {
		return fuzz_broken(.Two_Readers, "text_width gives %d; shape gives %d", measured, width)
	}
	return FUZZ_PASSED
}

fuzz_indic_shaping_seeds :: proc(seeds: ^[dynamic][]u8) {
	// नमस्ते, र्क, क्षि, a lone virama, and joiners, with no change; then the
	// same text with a few changes at the start of each table.
	words := [?][]u8{{0x28, 0x2E, 0x38, 0x4D, 0x24, 0x47}, {0x30, 0x4D, 0x15}, {0x15, 0x4D, 0x37, 0x3F}, {0x4D}, {0x15, 0x4D, 0xFE, 0x37, 0xFF}}
	for word in words {
		input := make([dynamic]u8)
		append(&input, u8(len(word)), 0)
		append(&input, ..word)
		append(seeds, input[:])
		changed := make([dynamic]u8)
		append(&changed, ..input[:])
		for place in ([3]u32{4, 64, 1024}) {
			change := Fuzz_Indic_Change{place = place, value = 0xFF}
			append(&changed, ..mem.ptr_to_bytes(&change))
		}
		append(seeds, changed[:])
	}
}
