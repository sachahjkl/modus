package fuzz

import "core:mem"
import "modus:contract/font_outlines"
import "modus:contract/text_encoding"
import "modus:text_rendering"
import "modus:vector_font"

// The fuzz target of the shapers of Khmer, Myanmar and the Universal
// Shaping Engine over a hostile font (src/md/features/written_shaping.md,
// "Khmer, Myanmar and the Universal Shaping Engine"): the text of the
// input in the blocks of one of their scripts, with joiners, the grapheme
// joiner, a variation selector and the dotted circle, shaped with a copy of
// the font of that script whose tables GSUB, GPOS and GDEF the input
// changes at the places it names. Each character draws: the count of
// glyphs is at least one for each character that draws something and at
// most the glyphs of a shaped cluster for each character; each cluster is
// the first byte of a character; text_width agrees with shape; and the
// work of the call stays in its budget, so a hostile table ends a call,
// never hangs it.

// The head of an input: the bytes of the text that follow it and the
// script, then the changes of the tables, each a place and a byte.
@(private = "file")
Fuzz_Syllabic_Head :: struct #packed {
	text_count: u16,
	script:     u8, // The script modulo the scripts of the target.
}

@(private = "file")
Fuzz_Syllabic_Change :: struct #packed {
	place: u32, // In the tables GSUB, GPOS and GDEF, one after the other, modulo their bytes.
	value: u8,
}

FUZZ_SYLLABIC_INPUT_LIMIT :: 4 << 10

// A script of the target: its font and the block that the bytes of the
// text name.
@(private = "file")
Fuzz_Syllabic_Script :: struct {
	name:        string,
	font:        text_rendering.Outline_Font,
	first:       rune,
	block_count: int,
}

@(rodata, private = "file")
fuzz_syllabic_scripts := [?]Fuzz_Syllabic_Script {
	{"noto_sans_khmer", .Noto_Sans_Khmer, 0x1780, 0x80},
	{"noto_sans_myanmar", .Noto_Sans_Myanmar, 0x1000, 0xA0},
	{"noto_serif_tibetan", .Noto_Serif_Tibetan, 0x0F00, 0x100},
	{"noto_sans_balinese", .Noto_Sans_Balinese, 0x1B00, 0x80},
	{"noto_sans_javanese", .Noto_Sans_Javanese, 0xA980, 0x60},
	{"noto_sans_sundanese", .Noto_Sans_Sundanese, 0x1B80, 0x40},
}

// The set of the target: the fonts of the boot image and the fonts of the
// scripts, opened once at the start and only read after it.
@(private = "file")
fuzz_syllabic_fonts: ^text_rendering.Font_Set
@(private = "file")
fuzz_syllabic_words: []u64

fuzz_syllabic_shaping_start :: proc() -> bool {
	fonts := make([dynamic]font_outlines.Font_Input)
	append(&fonts, font_outlines.Font_Input{"b612", #load("../../../resources/fonts/b612.ttf")})
	append(&fonts, font_outlines.Font_Input{"b612_bold", #load("../../../resources/fonts/b612_bold.ttf")})
	append(&fonts, font_outlines.Font_Input{"paper_mono", #load("../../../resources/fonts/paper_mono.ttf")})
	append(&fonts, font_outlines.Font_Input{"paper_mono_semibold", #load("../../../resources/fonts/paper_mono_semibold.ttf")})
	append(&fonts, font_outlines.Font_Input{"noto_sans", #load("../../../resources/fonts/noto_sans.ttf")})
	// With a font missing the target does not start, so the run counts no
	// execution as a pass; fuzz_script_font_file said why.
	for script in fuzz_syllabic_scripts {
		bytes, found := fuzz_script_font_file(script.name)
		if !found {
			return false
		}
		append(&fonts, font_outlines.Font_Input{script.name, bytes})
	}
	size := font_outlines.resource_size(fonts[:])
	fuzz_syllabic_words = make([]u64, (size + 7) / 8)
	bytes := ([^]u8)(raw_data(fuzz_syllabic_words))[:size]
	if _, written := font_outlines.resource_write(fonts[:], bytes); !written {
		return false
	}
	room := new(font_outlines.Record_Room)
	outlines, problem := font_outlines.validate(bytes, room[:])
	if problem.kind != .None {
		return false
	}
	fuzz_syllabic_fonts = new(text_rendering.Font_Set)
	fuzz_syllabic_fonts.room = new(text_rendering.Font_Room)[:]
	memory := new(text_rendering.Outline_Memory)
	outline := text_rendering.outline_of(memory)
	_ = text_rendering.fonts_open(fuzz_syllabic_fonts, &outlines, &outline)
	missing := text_rendering.script_fonts_open_in(fuzz_syllabic_fonts, &outlines, &outline)
	for script in fuzz_syllabic_scripts {
		if script.font in missing {
			return false
		}
	}
	return true
}

// fuzz_syllabic_text writes the text of an input: each byte a character of
// the block of the script, or one of the characters that its syllables
// share.
@(private = "file")
fuzz_syllabic_text :: proc(script: Fuzz_Syllabic_Script, input: []u8) -> []u8 {
	text := make([dynamic]u8, context.temp_allocator)
	for byte in input {
		character: rune
		switch byte {
		case 0xFF:
			character = 0x200D
		case 0xFE:
			character = 0x200C
		case 0xFD:
			character = 0x034F
		case 0xFC:
			character = 0xFE00
		case 0xFB:
			character = 0x25CC
		case:
			character = script.first + rune(int(byte) % script.block_count)
		}
		encoded: [4]u8
		length := text_encoding.character_encode(character, encoded[:])
		append(&text, ..encoded[:length])
	}
	return text[:]
}

fuzz_syllabic_shaping_execute :: proc(input: []u8) -> Fuzz_Verdict {
	// The start opened the fonts, or the target did not start.
	if fuzz_syllabic_fonts == nil {
		return fuzz_broken(.Contract, "the target runs with no fonts: its start did not open the fonts of the scripts")
	}
	head: Fuzz_Syllabic_Head
	copy(mem.ptr_to_bytes(&head), input)
	rest := input[min(len(input), size_of(head)):]
	script := fuzz_syllabic_scripts[int(head.script) % len(fuzz_syllabic_scripts)]
	text_count := min(int(head.text_count), len(rest))
	text := fuzz_syllabic_text(script, rest[:text_count])
	rest = rest[text_count:]
	// A copy of the font, with the changes of the input in its tables.
	shared := text_rendering.font_at(fuzz_syllabic_fonts, script.font)
	font := shared^
	bytes := make([]u8, len(shared.file.bytes), context.temp_allocator)
	copy(bytes, shared.file.bytes)
	font.file.bytes = bytes
	parts := [3]vector_font.Table{font.file.gsub, font.file.gpos, font.file.gdef}
	span := 0
	for part in parts {
		span += part.length
	}
	for len(rest) >= size_of(Fuzz_Syllabic_Change) && span > 0 {
		change: Fuzz_Syllabic_Change
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
	set := fuzz_syllabic_fonts^
	set.fonts[script.font] = &font
	spacing, ok := text_rendering.spacing_in(&set, .Interface, text_rendering.TEXT_SIZE_OF_SCALE_ONE)
	if !ok {
		return fuzz_broken(.Contract, "the set of the target gives no spacing")
	}
	characters := text_encoding.character_count(text)
	placed := make([]text_rendering.Placed_Glyph, (1 + text_rendering.CLUSTER_MARK_LIMIT) * max(characters, 1), context.temp_allocator)
	count, width, shaped := text_rendering.shape(&spacing, text, placed)
	if !shaped || count > len(placed) {
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

fuzz_syllabic_shaping_seeds :: proc(seeds: ^[dynamic][]u8) {
	// A word of each script (ក្រុ, မြန်မာ, བསྒྲུབས, ᬓ᭄ᬭᬶ, ꦏꦿꦺꦴ, ᮞᮥᮔ᮪ᮓ), a broken
	// syllable, and joiners, with no change; then the same text with a few
	// changes at the start of each table.
	Seed :: struct {
		script: u8,
		word:   []u8,
	}
	words := [?]Seed {
		{0, {0x00, 0x52, 0x1A, 0x3B}},
		{1, {0x19, 0x3C, 0x14, 0x3A, 0x19, 0x2C}},
		{2, {0x56, 0x66, 0x92, 0xB2, 0x74, 0x56, 0x66}},
		{3, {0x13, 0x44, 0x2D, 0x36}},
		{4, {0x0F, 0x3F, 0x3A, 0x34}},
		{5, {0x1E, 0x25, 0x14, 0x2A, 0x13}},
		{0, {0x37, 0xFF, 0x00, 0xFE, 0xFD, 0x37}},
		{2, {0x72, 0x71, 0xFB, 0x84, 0x84, 0x84}},
	}
	for seed in words {
		input := make([dynamic]u8)
		append(&input, u8(len(seed.word)), 0, seed.script)
		append(&input, ..seed.word)
		append(seeds, input[:])
		changed := make([dynamic]u8)
		append(&changed, ..input[:])
		for place in ([3]u32{4, 64, 1024}) {
			change := Fuzz_Syllabic_Change{place = place, value = 0xFF}
			append(&changed, ..mem.ptr_to_bytes(&change))
		}
		append(seeds, changed[:])
	}
}
