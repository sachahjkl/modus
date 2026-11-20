package vector_glyphs

import "modus:contract/value_kinds"

// The log facts of vector_glyphs (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence, and the measure that the tool
// reads from it, read it as before. The Text fields are the last fields:
// the serial line of a fact stops at its last byte that is not zero.

// The bytes of the Text field of the name of a candidate font: the
// longest, "Paper Mono (default)", has 20 bytes.
FONT_FIELD_BYTES :: 24
// The bytes of the Text field of the name of a problem of a font: the
// longest name has 66 bytes.
FONT_PROBLEM_FIELD_BYTES :: 72
// The bytes of the Text field of the sentence of a problem of a glyph
// cache: the longest has 103 bytes.
CACHE_PROBLEM_FIELD_BYTES :: 104

// A candidate font is refused at its open or at the build of its cache.
@(log_fact = "vector_glyphs: the font {font} is refused: {font_problem}")
Font_Refused :: struct {
	font:         [24]u8,
	font_problem: [72]u8,
}

// The glyph cache built for a candidate font is refused by its check.
@(log_fact = "vector_glyphs: the cache of {font} is refused: {cache_problem}")
Cache_Refused :: struct {
	font:          [24]u8,
	cache_problem: [104]u8,
}

// The time of one glyph from its outline at three scales, from the private
// glyph cache, and of the bitmap font. A time is an unsigned count of
// nanoseconds: a scale that measured nothing keeps the largest value, as
// the line wrote it.
@(log_fact = "vector_glyphs: one glyph from its outline, in fixed point, with the stripes (the least of batches): scale 1 {scale_one} ns, scale 2 {scale_two} ns, scale 3 {scale_three} ns; from the private glyph cache: {glyph_cache} ns; Spleen 8x16: {spleen} ns")
Glyph_Measured :: struct {
	scale_one:   u64,
	scale_two:   u64,
	scale_three: u64,
	glyph_cache: u64,
	spleen:      u64,
}

// The glyph cache of a candidate font: its build time and its bytes.
@(log_fact = "vector_glyphs: the cache of {font}: 95 characters at 3 scales built in {build}, {cache_size}")
Cache_Built :: struct {
	build:      value_kinds.Time_In_Microseconds,
	cache_size: value_kinds.Size_In_Bytes,
	font:       [24]u8,
}

// The candidate fonts are ready.
@(log_fact = "vector_glyphs: ok, {candidates} candidates beside Spleen 8x16")
Candidates_Ready :: struct {
	candidates: u64,
}

#assert(size_of(Font_Refused) == FONT_FIELD_BYTES + FONT_PROBLEM_FIELD_BYTES)
#assert(size_of(Cache_Refused) == FONT_FIELD_BYTES + CACHE_PROBLEM_FIELD_BYTES)

// font_field gives the Text field of the name of a candidate font.
font_field :: proc "contextless" (name: string) -> [FONT_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, FONT_FIELD_BYTES)
}
