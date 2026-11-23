package fuzz

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "modus:contract/blake3"
import "modus:contract/font_outlines"
import "modus:contract/font_characters"
import "modus:vector_font"

// The fuzz targets of the fonts (src/md/infrastructure/fuzzing.md, "The
// targets, in order of value"): each process with text reads the font
// files of the outlines with the vector font reader, and validates the
// font outlines once, then trusts each entry. A signed image writes them
// today; a fault there still stops a service.

// fuzz_aligned_input gives an input on a multiple of 8: the readers of the
// outlines and of a theme refuse other memory, as the
// starter maps them on a page. An input that is aligned already is given
// as it is, so the page with no access beside it still catches a read past
// its ends; only another input is copied, and loses that guard.
fuzz_aligned_input :: proc(input: []u8) -> []u8 {
	if uintptr(raw_data(input)) % 8 == 0 {
		return input
	}
	words := make([]u64, (len(input) + 7) / 8, context.temp_allocator)
	bytes := slice.to_bytes(words)[:len(input)]
	copy(bytes, input)
	return bytes
}

// ---------------------------------------------------------------------
// The vector font reader.

// The font of a seed: the smallest font file of resources/fonts.
@(private = "file")
fuzz_font_seed := #load("../../../resources/fonts/commit_mono.ttf")

// The memory of the renderer: one for the process, as a service keeps it.
@(private = "file")
fuzz_font_memory: ^vector_font.Render_Memory

fuzz_vector_font_start :: proc() -> bool {
	fuzz_font_memory = new(vector_font.Render_Memory)
	return fuzz_font_memory != nil
}

// The characters that the target asks of a font: the edges of the code
// points, the characters that font_measures reads, and some past ASCII.
@(rodata, private = "file")
fuzz_font_characters := [?]rune{0, ' ', 'A', 'V', 'g', 'x', 'H', 0xE9, font_characters.EURO_SIGN, 0xFFFD, 0xFFFF, 0x10000, 0x10FFFF}

// fuzz_vector_font_execute: a font that font_open accepts gives each glyph,
// outline, advance, pair and substitution with no fault, and an outline in
// the memory of the caller; a font whose measures it reads draws a glyph.
fuzz_vector_font_execute :: proc(input: []u8) -> Fuzz_Verdict {
	// A collection opens at its first face; another file at its start.
	face, face_problem := vector_font.collection_face_offset(input, 0)
	if face_problem > max(vector_font.Font_Problem) {
		return fuzz_broken(.Contract, "collection_face_offset gives a problem out of its enumeration: %d", u8(face_problem))
	}
	if face_problem != .None {
		return FUZZ_PASSED
	}
	font, problem := vector_font.font_open(input, face)
	if problem > max(vector_font.Font_Problem) {
		return fuzz_broken(.Contract, "font_open gives a problem out of its enumeration: %d", u8(problem))
	}
	if problem != .None {
		return FUZZ_PASSED
	}
	memory := fuzz_font_memory
	outline := vector_font.Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	private_cache: vector_font.Cff_Private_Cache
	with_cache := font
	vector_font.cff_private_cache_fill(&with_cache, &private_cache)
	cached_memory := new(vector_font.Render_Memory, context.temp_allocator)
	cached_outline := vector_font.Outline{points = cached_memory.points[:], contour_ends = cached_memory.contours[:]}
	glyphs := make([dynamic]int, context.temp_allocator)
	append(&glyphs, 0, 1, font.glyph_count - 1, font.glyph_count, int(max(u16)))
	for character in fuzz_font_characters {
		glyph, glyph_problem := vector_font.glyph_of(&font, character)
		if glyph_problem == .None {
			if glyph < 0 || glyph >= font.glyph_count {
				return fuzz_broken(.Contract, "glyph_of gives the glyph %d of %d", glyph, font.glyph_count)
			}
			append(&glyphs, glyph)
		}
		_ = vector_font.character_advance(&font, character)
	}
	for glyph in glyphs {
		// A glyph number of the file is a word of 16 bits: never negative.
		if glyph < 0 {
			continue
		}
		_ = vector_font.glyph_advance(&font, glyph)
		_, _ = vector_font.glyph_data(&font, glyph)
		outline_problem := vector_font.glyph_outline(&font, glyph, &outline)
		if outline_problem == .None {
			if outline.point_count < 0 || outline.point_count > len(outline.points) || outline.contour_count < 0 || outline.contour_count > len(outline.contour_ends) {
				return fuzz_broken(.Contract, "the outline of the glyph %d has %d points and %d contours", glyph, outline.point_count, outline.contour_count)
			}
		}
		// The cache of the Private dictionaries gives the outline that the
		// read of its own dictionary gives.
		if with_cache.cff.private_cache != nil {
			cached_problem := vector_font.glyph_outline(&with_cache, glyph, &cached_outline)
			if cached_problem != outline_problem || cached_problem == .None && (cached_outline.point_count != outline.point_count || cached_outline.contour_count != outline.contour_count) {
				return fuzz_broken(.Two_Readers, "the glyph %d with the cache of the Private dictionaries: %v, %d points; without: %v, %d points", glyph, cached_problem, cached_outline.point_count, outline_problem, outline.point_count)
			}
		}
		for tag in ([?]vector_font.Feature_Tag{{'s', 's', '0', '1'}, {'z', 'e', 'r', 'o'}}) {
			if substitute, substitution_problem := vector_font.single_substitution(&font, tag, glyph); substitution_problem == .None && (substitute < 0 || substitute >= font.glyph_count) {
				return fuzz_broken(.Contract, "single_substitution gives the glyph %d of %d", substitute, font.glyph_count)
			}
		}
	}
	if verdict := fuzz_layout_check(&font, glyphs[:]); verdict.oracle != .None {
		return verdict
	}
	if pairs, pairs_problem := vector_font.pair_table_open(&font); pairs_problem == .None {
		_ = vector_font.character_pair_adjustment(&font, &pairs, 'A', 'V')
		_ = vector_font.pair_adjustment(&pairs, 0, max(int))
	}
	measures, measures_problem := vector_font.font_measures(&font, memory)
	if measures_problem != .None {
		return FUZZ_PASSED
	}
	style := vector_font.glyph_style_of(measures, 8, 16, false)
	pixels: [8 * 16]u32
	_ = vector_font.glyph_render(&font, measures, style, 'A', memory, pixels[:])
	return FUZZ_PASSED
}

fuzz_vector_font_seeds :: proc(seeds: ^[dynamic][]u8) {
	append(seeds, slice.clone(fuzz_font_seed), slice.clone(fuzz_font_seed[:12]), make([]u8, 0))
	// A font with CFF outlines, one with CFF2 outlines, each with a
	// character map of format 12, and a collection of one face.
	append(seeds, fuzz_font_of_cff(1), fuzz_font_of_cff(2), fuzz_collection_of(fuzz_font_seed))
	// Noto Sans Hebrew, whole, when the shell names it: GSUB, GPOS and
	// GDEF, with mark anchors.
	if hebrew, found := fuzz_script_font_file("noto_sans_hebrew"); found && len(hebrew) <= 64 << 10 {
		append(seeds, hebrew)
	}
}

// fuzz_script_font_file reads a script font that SCRIPT_FONT_SOURCES names.
fuzz_script_font_file :: proc(name: string) -> (bytes: []u8, found: bool) {
	sources := os.get_env("SCRIPT_FONT_SOURCES", context.temp_allocator)
	rest := sources
	prefix := strings.concatenate({name, "="}, context.temp_allocator)
	for item in strings.split_iterator(&rest, ";") {
		if strings.has_prefix(item, prefix) {
			read, error := os.read_entire_file(item[len(prefix):], context.allocator)
			return read, error == nil
		}
	}
	return nil, false
}

// The scripts and the features that the layout check asks of each font.
@(rodata, private = "file")
fuzz_layout_scripts := [?]vector_font.Feature_Tag{{'a', 'r', 'a', 'b'}, {'h', 'e', 'b', 'r'}, {'d', 'e', 'v', '2'}, {'m', 'l', 'm', '2'}, {'D', 'F', 'L', 'T'}}
@(rodata, private = "file")
fuzz_layout_features := [?]vector_font.Feature_Tag{{'c', 'c', 'm', 'p'}, {'i', 'n', 'i', 't'}, {'f', 'i', 'n', 'a'}, {'r', 'l', 'i', 'g'}, {'p', 'r', 'e', 's'}, {'h', 'a', 'l', 'f'}}

// fuzz_layout_check: the substitutions, the ligatures, the anchors and the
// engine over the glyphs of a font: each answer a refusal or glyphs of the
// font, each sequence and each buffer within its bound, each attachment to
// a glyph before the mark.
fuzz_layout_check :: proc(font: ^vector_font.Font_File, glyphs: []int) -> Fuzz_Verdict {
	// The first 16 glyphs of the font that the list names: the edges (0, 1,
	// the last) and the glyphs of a few characters, so that one execution
	// stays short.
	usable := make([dynamic]int, context.temp_allocator)
	for glyph in glyphs {
		if glyph >= 0 && glyph < font.glyph_count && len(usable) < 16 {
			append(&usable, glyph)
		}
	}
	if len(usable) == 0 {
		return FUZZ_PASSED
	}
	// The cache of the walk answers as the walk, and the test of a feature
	// on exact glyphs refuses or answers with no fault.
	cache_entries: [256]vector_font.Layout_Cache_Entry
	cache_indices: [2048]u16
	cache := vector_font.Layout_Cache{entries = cache_entries[:], indices = cache_indices[:]}
	cached := font^
	vector_font.layout_cache_fill(&cached, &cache)
	for script in fuzz_layout_scripts {
		for tag in fuzz_layout_features {
			for place in ([2]vector_font.Table{font.gsub, font.gpos}) {
				walked, from_cache: vector_font.Layout_Lookups
				walk_problem := vector_font.layout_lookups(font, place, script, {'D', 'F', 'L', 'T'}, tag, &walked)
				cache_problem := vector_font.layout_lookups(&cached, place == font.gsub ? cached.gsub : cached.gpos, script, {'D', 'F', 'L', 'T'}, tag, &from_cache)
				if walk_problem == .None && (cache_problem != .None || walked.count != from_cache.count || walked.indices != from_cache.indices) {
					return fuzz_broken(.Two_Readers, "the cache of the walk gives %v and %d lookups; the walk gives %d", cache_problem, from_cache.count, walked.count)
				}
			}
			_ = vector_font.layout_would_substitute(font, script, tag, usable[:min(len(usable), 3)])
		}
	}
	for script in fuzz_layout_scripts {
		for tag in fuzz_layout_features {
			for glyph in usable {
				out: [vector_font.SEQUENCE_LIMIT]int
				count, problem := vector_font.script_substitution(font, script, tag, glyph, out[:])
				if problem == .None {
					if count < 1 || count > len(out) {
						return fuzz_broken(.Contract, "script_substitution gives %d glyphs", count)
					}
					for value in out[:count] {
						if value < 0 || value >= font.glyph_count {
							return fuzz_broken(.Contract, "script_substitution gives the glyph %d of %d", value, font.glyph_count)
						}
					}
				}
				if ligature, ligature_problem := vector_font.script_ligature(font, script, tag, glyph, usable[0]); ligature_problem == .None && (ligature <= 0 || ligature >= font.glyph_count) {
					return fuzz_broken(.Contract, "script_ligature gives the glyph %d of %d", ligature, font.glyph_count)
				}
			}
		}
		for glyph in usable {
			for attachment in vector_font.Mark_Attachment {
				_, _, _, problem := vector_font.mark_anchor_offset(font, script, attachment, usable[0], glyph)
				if problem > max(vector_font.Font_Problem) {
					return fuzz_broken(.Contract, "mark_anchor_offset gives a problem out of its enumeration")
				}
			}
		}
		// The engine over the glyphs, both tables, every feature on each.
		buffer: vector_font.Engine_Buffer
		for glyph, index in usable[:min(len(usable), 8)] {
			buffer.glyphs[index] = {glyph = u16(glyph), place = u8(index), mask = max(u32)}
			buffer.count += 1
		}
		vector_font.engine_buffer_prepare(font, &buffer)
		features: [len(fuzz_layout_features)]vector_font.Engine_Feature
		for tag, index in fuzz_layout_features {
			features[index] = {tag, 1 << uint(index)}
		}
		positions := [?]vector_font.Engine_Feature{{{'m', 'a', 'r', 'k'}, 1}, {{'m', 'k', 'm', 'k'}, 1}, {{'k', 'e', 'r', 'n'}, 1}, {{'d', 'i', 's', 't'}, 1}}
		_ = vector_font.engine_stage(font, .Substitution, script, features[:], &buffer)
		_ = vector_font.engine_stage(font, .Positioning, script, positions[:], &buffer)
		vector_font.engine_positions_finish(&buffer)
		if buffer.count < 0 || buffer.count > vector_font.ENGINE_GLYPH_LIMIT {
			return fuzz_broken(.Contract, "the engine leaves %d glyphs", buffer.count)
		}
		for glyph, index in buffer.glyphs[:buffer.count] {
			if int(glyph.glyph) >= font.glyph_count && glyph.glyph != 0 || int(glyph.attach) >= index {
				return fuzz_broken(.Contract, "the engine leaves the glyph %d attached to %d at %d", glyph.glyph, glyph.attach, index)
			}
		}
	}
	return FUZZ_PASSED
}

// fuzz_collection_of wraps a font file in a collection of one face: its
// table offsets move by the header of the collection.
fuzz_collection_of :: proc(font: []u8) -> []u8 {
	HEADER :: 16
	bytes := make([]u8, HEADER + len(font))
	copy(bytes, "ttcf")
	bytes[5] = 1 // version 1.0
	bytes[11] = 1 // one face
	bytes[15] = HEADER // its offset
	copy(bytes[HEADER:], font)
	table_count := int(font[4]) << 8 | int(font[5])
	for index in 0 ..< table_count {
		at := HEADER + 12 + 16 * index + 8
		if at + 4 > len(bytes) {
			break
		}
		offset := int(bytes[at]) << 24 | int(bytes[at + 1]) << 16 | int(bytes[at + 2]) << 8 | int(bytes[at + 3]) + HEADER
		bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3] = u8(offset >> 24), u8(offset >> 16), u8(offset >> 8), u8(offset)
	}
	return bytes
}

@(private = "file")
fuzz_put :: proc(bytes: ^[dynamic]u8, value, size: int) {
	for shift := 8 * (size - 1); shift >= 0; shift -= 8 {
		append(bytes, u8(value >> uint(shift)))
	}
}

// fuzz_font_of_cff writes a small OpenType font with CFF (version 1) or
// CFF2 (version 2) outlines: three glyphs (none, a square, a triangle), a
// character map of format 12 (A to Z, and an emoji), and the tables that
// font_open reads.
fuzz_font_of_cff :: proc(version: int) -> []u8 {
	GLYPHS :: 3
	charstrings := [GLYPHS][]u8 {
		{139, 139, 21},
		{139, 139, 21, 239, 139, 5, 139, 239, 5, 39, 139, 5},
		{139, 139, 21, 239, 139, 5, 89, 239, 5},
	}
	index :: proc(bytes: ^[dynamic]u8, items: [][]u8, version: int) {
		fuzz_put(bytes, len(items), version == 2 ? 4 : 2)
		if len(items) == 0 {
			return
		}
		append(bytes, 1)
		offset := 1
		append(bytes, u8(offset))
		for item in items {
			offset += len(item)
			append(bytes, u8(offset))
		}
		for item in items {
			append(bytes, ..item)
		}
	}
	items := make([dynamic][]u8, context.temp_allocator)
	for charstring in charstrings {
		code := make([dynamic]u8, context.temp_allocator)
		append(&code, ..charstring)
		if version == 1 {
			append(&code, 14) // endchar
		}
		append(&items, code[:])
	}
	cff := make([dynamic]u8, context.temp_allocator)
	if version == 2 {
		// The header, a top dictionary of CharStrings and FDArray, an empty
		// global subroutine INDEX, the charstrings, a FDArray of one empty
		// dictionary.
		TOP :: 12
		append(&cff, 2, 0, 5, 0, TOP)
		char_strings_at := 5 + TOP + 4
		char_strings := make([dynamic]u8, context.temp_allocator)
		index(&char_strings, items[:], 2)
		fd_array_at := char_strings_at + len(char_strings)
		append(&cff, 29)
		fuzz_put(&cff, char_strings_at, 4)
		append(&cff, 17, 29)
		fuzz_put(&cff, fd_array_at, 4)
		append(&cff, 12, 36)
		fuzz_put(&cff, 0, 4)
		append(&cff, ..char_strings[:])
		append(&cff, 0, 0, 0, 1, 1, 1, 1)
	} else {
		// The header, the Name INDEX, the Top DICT INDEX, the String and the
		// global subroutine INDEX, the charstrings, an empty Private DICT.
		append(&cff, 1, 0, 4, 1)
		index(&cff, {{'A'}}, 1)
		TOP :: 5 + 1 + 1 + 5 + 1
		top_at := len(cff)
		after_top := top_at + 2 + 1 + 2 + TOP
		char_strings_at := after_top + 2 + 2
		char_strings := make([dynamic]u8, context.temp_allocator)
		index(&char_strings, items[:], 1)
		private_at := char_strings_at + len(char_strings)
		top := make([dynamic]u8, context.temp_allocator)
		append(&top, 29)
		fuzz_put(&top, char_strings_at, 4)
		append(&top, 17, 139, 29)
		fuzz_put(&top, private_at, 4)
		append(&top, 18)
		index(&cff, {top[:]}, 1)
		append(&cff, 0, 0, 0, 0)
		append(&cff, ..char_strings[:])
	}
	cmap := make([dynamic]u8, context.temp_allocator)
	fuzz_put(&cmap, 0, 2)
	fuzz_put(&cmap, 1, 2)
	fuzz_put(&cmap, 3, 2)
	fuzz_put(&cmap, 10, 2)
	fuzz_put(&cmap, 12, 4)
	fuzz_put(&cmap, 12, 2)
	fuzz_put(&cmap, 0, 2)
	fuzz_put(&cmap, 16 + 12 * 2, 4)
	fuzz_put(&cmap, 0, 4)
	fuzz_put(&cmap, 2, 4)
	for group in ([2][3]int{{'A', 'Z', 1}, {0x1F600, 0x1F600, 2}}) {
		fuzz_put(&cmap, group[0], 4)
		fuzz_put(&cmap, group[1], 4)
		fuzz_put(&cmap, group[2], 4)
	}
	head := make([dynamic]u8, 54, context.temp_allocator)
	head[1] = 1
	head[12], head[13], head[14], head[15] = 0x5F, 0x0F, 0x3C, 0xF5
	head[18], head[19] = u8(1000 >> 8), u8(1000 & 0xFF)
	hhea := make([dynamic]u8, 36, context.temp_allocator)
	hhea[1] = 1
	hhea[4], hhea[5] = u8(800 >> 8), u8(800 & 0xFF)
	hhea[6], hhea[7] = 0xFF, 0x38
	hhea[35] = GLYPHS
	maxp := make([dynamic]u8, context.temp_allocator)
	fuzz_put(&maxp, 0x00005000, 4)
	fuzz_put(&maxp, GLYPHS, 2)
	hmtx := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< GLYPHS {
		fuzz_put(&hmtx, 500, 2)
		fuzz_put(&hmtx, 0, 2)
	}
	Table :: struct {
		tag:   string,
		bytes: []u8,
	}
	tables := [?]Table{{version == 2 ? "CFF2" : "CFF ", cff[:]}, {"cmap", cmap[:]}, {"head", head[:]}, {"hhea", hhea[:]}, {"hmtx", hmtx[:]}, {"maxp", maxp[:]}}
	font := make([dynamic]u8)
	append(&font, 'O', 'T', 'T', 'O')
	fuzz_put(&font, len(tables), 2)
	fuzz_put(&font, 0, 6)
	offset := 12 + 16 * len(tables)
	for table in tables {
		append(&font, ..transmute([]u8)table.tag)
		fuzz_put(&font, 0, 4)
		fuzz_put(&font, offset, 4)
		fuzz_put(&font, len(table.bytes), 4)
		offset += (len(table.bytes) + 3) &~ 3
	}
	for table in tables {
		append(&font, ..table.bytes)
		for len(font) % 4 != 0 {
			append(&font, 0)
		}
	}
	return font[:]
}

// ---------------------------------------------------------------------
// The font outlines.

// fuzz_font_outlines_execute: a resource that validate accepts gives each
// font file inside it, and its fonts written again by resource_write give
// a resource that validate accepts with the same names and the same bytes.
fuzz_font_outlines_execute :: proc(input: []u8) -> Fuzz_Verdict {
	bytes := fuzz_aligned_input(input)
	outlines, problem := font_outlines.validate(bytes)
	if problem.kind > max(font_outlines.Problem_Kind) {
		return fuzz_broken(.Contract, "validate gives a problem out of its enumeration: %d", u8(problem.kind))
	}
	if problem.kind != .None {
		if outlines.header != {} || outlines.count != 0 {
			return fuzz_broken(.Contract, "validate refuses with %v and gives records", problem.kind)
		}
		return FUZZ_PASSED
	}
	fonts := make([]font_outlines.Font_Input, outlines.count, context.temp_allocator)
	for &record, index in outlines.records[:outlines.count] {
		fonts[index] = {name = font_outlines.name_of(&record), bytes = font_outlines.font_bytes(&outlines, index)}
	}
	out := fuzz_aligned_input(make([]u8, font_outlines.resource_size(fonts), context.temp_allocator))
	if _, written := font_outlines.resource_write(fonts, out); !written {
		return fuzz_broken(.Round_Trip, "resource_write refuses the fonts of a resource that validate accepted")
	}
	again, again_problem := font_outlines.validate(out)
	if again_problem.kind != .None || again.count != len(fonts) {
		return fuzz_broken(.Round_Trip, "validate refuses what resource_write wrote: %v", again_problem.kind)
	}
	for &record, index in again.records[:again.count] {
		font := font_outlines.font_bytes(&again, index)
		if font_outlines.name_of(&record) != fonts[index].name || !slice.equal(font, fonts[index].bytes) || record.hash != blake3.hash(font) {
			return fuzz_broken(.Round_Trip, "the font %d written again differs", index)
		}
	}
	return FUZZ_PASSED
}

fuzz_font_outlines_seeds :: proc(seeds: ^[dynamic][]u8) {
	for count in ([?]int{1, 3, font_outlines.FONT_LIMIT}) {
		fonts := make([]font_outlines.Font_Input, count, context.temp_allocator)
		for &font, index in fonts {
			font = {name = fmt.tprintf("font_%d", index), bytes = fuzz_font_seed[index * 16:][:16 + index]}
		}
		out := fuzz_aligned_input(make([]u8, font_outlines.resource_size(fonts), context.temp_allocator))
		_, _ = font_outlines.resource_write(fonts, out)
		append(seeds, slice.clone(out))
	}
	append(seeds, make([]u8, font_outlines.HEADER_SIZE - 1))
}

fuzz_font_outlines_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	if len(input) < font_outlines.HEADER_SIZE {
		return
	}
	append(regions, Fuzz_Region{offset = 0, type = font_outlines.Header, count = 1})
	records := min(font_outlines.FONT_LIMIT, (len(input) - font_outlines.HEADER_SIZE) / font_outlines.RECORD_SIZE)
	if records > 0 {
		append(regions, Fuzz_Region{offset = font_outlines.RECORDS_OFFSET, type = font_outlines.Font_Record, count = records})
	}
}
