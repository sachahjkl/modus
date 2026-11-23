package interface_font

import "modus:contract/value_kinds"

// The log facts of interface_font (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence, and its line that fails a step,
// read it as before. The Text fields are the last fields: the serial line
// of a fact stops at its last byte that is not zero.

// The bytes of the Text field of the name of an outline font: the longest,
// "paper_mono_semibold", has 19 bytes.
FONT_NAME_FIELD_BYTES :: 24

// Each Greek letter of the subset of B612 is drawn from the private glyph
// cache of this process.
@(log_fact = "interface_font: each Greek letter of B612 is drawn by this process: {letters} letters: as it must")
Greek_Letters_Drawn :: struct {
	letters: u64,
}

// Some Greek letters of B612 have no glyph that this process draws.
@(log_fact = "interface_font: not each Greek letter of B612 is drawn: {drawn} of {letters}, {missing} with no glyph")
Greek_Letters_Missing :: struct {
	drawn:   u64,
	letters: u64,
	missing: u64,
}

// A box-drawing character comes from another font than paper_mono, or has
// no ink: the fallback chain is wrong.
@(log_fact = "interface_font: the fallback chain of the interface is wrong: the character {character} comes from the font {font}, with {ink_rows} rows of ink")
Box_Character_Wrong :: struct {
	character: u64,
	ink_rows:  u64,
	font:      [24]u8,
}

// Each box-drawing character comes from paper_mono.
@(log_fact = "interface_font: the box-drawing characters come from paper_mono, the second font of the chain of the interface: {characters} characters: as it must")
Box_Characters_From_Paper_Mono :: struct {
	characters: u64,
}

// A character that no font of the chain has got a glyph.
@(log_fact = "interface_font: the fallback chain of the interface is wrong: the character {character} has a glyph, and no font of the chain has it")
Missing_Character_Has_Glyph :: struct {
	character: u64,
}

// A character that no font of the chain has got the advance of a font, not
// the advance of the replacement glyph.
@(log_fact = "interface_font: the fallback chain of the interface is wrong: the character {character} has an advance of a font")
Missing_Character_Has_Advance :: struct {
	character: u64,
}

// The characters that no font of the chain has draw the replacement glyph.
@(log_fact = "interface_font: {characters} characters that no font of the chain has draw the replacement glyph: as it must")
Replacement_Glyph_Drawn :: struct {
	characters: u64,
}

// The fallback chain has no glyph memory to check: each glyph is drawn
// band by band.
@(log_fact = "interface_font: the fallback chain of the interface is wrong: this process has no glyph memory: each glyph is drawn band by band")
Fallback_Without_Glyph_Memory :: struct {}

// The boot image gives no font outlines: the window cannot draw.
@(log_fact = "interface_font: the boot image gives no font outlines with the interface font")
Font_Outlines_Missing :: struct {}

// The process has no glyph memory for its measure: each glyph is drawn
// band by band.
@(log_fact = "interface_font: this process has no glyph memory: each glyph is drawn band by band")
Glyph_Memory_Missing :: struct {}

// The time of one line of B612: its shaping, its drawing from the glyph
// cache, and its first drawing from the outlines.
@(log_fact = "interface_font: one line of {characters} characters in B612 at scale 1 (the least of 50 batches): shaping {shaping}, drawing {drawing}; its first draw, each glyph from its outline: {first_drawing}")
Line_Measured :: struct {
	characters:    u64,
	shaping:       value_kinds.Time_In_Nanoseconds,
	drawing:       value_kinds.Time_In_Nanoseconds,
	first_drawing: value_kinds.Time_In_Nanoseconds,
}

// The fonts of the interface are open, with their kerning pairs.
@(log_fact = "interface_font: ok, B612 Regular and Bold, {regular_pairs} and {bold_pairs} pairs")
Fonts_Ready :: struct {
	regular_pairs: u64,
	bold_pairs:    u64,
}

#assert(size_of(Box_Character_Wrong) == 16 + FONT_NAME_FIELD_BYTES)

// The machine maps no script font set: the line of Hebrew, Arabic, CJK and
// an emoji draws the replacement glyph.
@(log_fact = "interface_font: no script font set is mapped: the line of Hebrew, Arabic, Thai, Devanagari, the ideographs and an emoji draws the replacement glyph")
Script_Fonts_Not_Mapped :: struct {}

// Each glyph of the line of the script font set has a font, and each base
// glyph has ink.
@(log_fact = "interface_font: the line of Hebrew, Arabic, Thai, Devanagari, the ideographs, an emoji and a geometric shape draws {glyphs} glyphs, with no replacement glyph: as it must")
Script_Line_Drawn :: struct {
	glyphs: u64,
}

// This module compiles the fast part of the text only: the library module
// text_rendering shaped the line, and gave the outline of each glyph of a
// font of the set.
@(log_fact = "interface_font: the library module text_rendering shaped the line and holds the {fonts} fonts of the set, as this module compiles no written part")
Script_Line_Through_Module :: struct {
	fonts: u64,
}

// A font of the set is open in this module but not held by the library
// module: the fast part would have opened a script font itself.
@(log_fact = "interface_font: WRONG: the font {font} of the script font set is open in this module, not held by the library module text_rendering")
Script_Font_Not_Held :: struct {
	font: u64,
}

// A character of the line of the script font set is the replacement glyph
// with the set mapped.
@(log_fact = "interface_font: the script font set is mapped, and the character {character} of its line draws the replacement glyph")
Script_Line_Box :: struct {
	character: u64,
}

// A glyph of the line of the script font set has no ink.
@(log_fact = "interface_font: the script font set is mapped, and the character {character} of its line has {ink_rows} rows of ink")
Script_Line_Without_Ink :: struct {
	character: u64,
	ink_rows:  u64,
}

// The line of the script font set has more glyphs than the table of one
// line.
@(log_fact = "interface_font: the line of the script font set has {glyphs} glyphs, more than one line holds")
Script_Line_Too_Long :: struct {
	glyphs: u64,
}
