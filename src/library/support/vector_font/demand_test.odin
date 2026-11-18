#+build !freestanding
package vector_font

import "core:mem"
import "core:testing"
import "modus:contract/demand_cache"
import "modus:contract/glyph_cache"

@(private = "file")
b612_subset := #load("../../../../resources/fonts/b612.ttf")
@(private = "file")
paper_mono_subset := #load("../../../../resources/fonts/paper_mono.ttf")
@(private = "file")
paper_mono_semibold_subset := #load("../../../../resources/fonts/paper_mono_semibold.ttf")

// font_file_of gives the font file of the outlines of a face: the file of
// its glyph cache.
@(private = "file")
font_file_of :: proc(face: demand_cache.Face) -> []u8 {
	switch face {
	case .Interface:
		return b612_subset
	case .Cells, .Cells_Without_Grid_Fit:
		return paper_mono_subset
	case .Cells_Bold:
		return paper_mono_semibold_subset
	}
	return nil
}

// A demand cache in the memory of the test, with no face named.
@(private = "file")
writer_make :: proc() -> (writer: demand_cache.Writer, bytes: []u8) {
	allocation: mem.Allocator_Error
	bytes, allocation = mem.alloc_bytes(demand_cache.SIZE, demand_cache.PAGE_SIZE)
	assert(allocation == nil)
	faces: [demand_cache.Face]demand_cache.Face_Header
	return demand_cache.writer_open(uintptr(raw_data(bytes)), RENDERER_VERSION, faces), bytes
}

// A glyph drawn on demand is the glyph of the build: for characters of the
// glyph cache, the on-demand path gives the same box, the same words and
// the same advance at each scale and each position as the proportional
// glyph cache that the build writes from the same font file. So a glyph on
// demand stands on the baseline of the glyphs beside it, and a picture
// does not depend on which path drew a glyph.
@(test)
a_glyph_on_demand_is_the_glyph_of_the_build :: proc(t: ^testing.T) {
	memory := new(Render_Memory)
	defer free(memory)
	font, problem := font_open(b612_subset)
	testing.expect_value(t, problem, Font_Problem.None)
	out := make([]u64, PROPORTIONAL_GLYPH_CACHE_LIMIT / 8)
	defer delete(out)
	file := ([^]u8)(raw_data(out))[:PROPORTIONAL_GLYPH_CACHE_LIMIT]
	positions := demand_cache.face_forms[.Interface].positions
	size: int
	size, problem = glyph_cache_build_proportional(&font, b612_subset, "b612", true, memory, file, positions[:])
	testing.expect_value(t, problem, Font_Problem.None)
	cache, refused := glyph_cache.validate(file[:size])
	testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
	testing.expect(t, demand_cache.reader_matches(.Interface, &cache))

	demand: Demand_Font
	demand, problem = demand_font_open(b612_subset, .Interface, memory)
	testing.expect_value(t, problem, Font_Problem.None)
	testing.expect_value(t, demand.flags, cache.header.flags)
	writer, bytes := writer_make()
	defer mem.free_bytes(bytes)

	characters := [?]rune{'A', 'g', 'j', 'W', 'T', ' ', 'é', 'ÿ', '€'}
	for character in characters {
		entry, result := demand_glyph_draw(&demand, &writer, character, memory)
		testing.expectf(t, result == .Drawn, "U+%04X is drawn on demand", int(character))
		index, _ := glyph_cache.character_index(character)
		for scale in 1 ..= demand_cache.SIZE_COUNT {
			testing.expectf(t, entry.advances[scale - 1] == glyph_cache.advances_of(&cache, scale)[index], "U+%04X at scale %v: the advance of the build", int(character), scale)
			for position in 0 ..< demand_cache.position_count_of(.Interface, scale) {
				on_demand, _ := demand_cache.glyph_of_entry(.Interface, &entry, scale, position)
				_, built, _ := glyph_cache.glyph_of_index(&cache, index, scale, position)
				same_box := on_demand.row_count == built.row_count && (built.row_count == 0 || on_demand.first_row == built.first_row && on_demand.left == built.left && on_demand.width == built.width)
				testing.expectf(t, same_box, "U+%04X at scale %v, position %v: the box of the build", int(character), scale, position)
				if !same_box {
					continue
				}
				count := int(built.row_count) * int(built.width)
				differ := 0
				for word in 0 ..< count {
					if writer.words[int(on_demand.word_offset) + word] != cache.words[int(built.word_offset) + word] {
						differ += 1
					}
				}
				testing.expectf(t, differ == 0, "U+%04X at scale %v, position %v: %v words differ from the build", int(character), scale, position, differ)
			}
		}
	}
}

// A glyph of a face of cells drawn on demand is the glyph of the build:
// for characters of the glyph cache, each of the three faces of Paper Mono
// gives the box, the words and the advance of the cache of cells that the
// build writes from the same font file, with the same grid fit and the
// same scales. Each entry stays in its cell (demand_cache.entry_valid).
@(test)
a_cell_glyph_on_demand_is_the_glyph_of_the_build :: proc(t: ^testing.T) {
	memory := new(Render_Memory)
	defer free(memory)
	out := make([]u64, GLYPH_CACHE_LIMIT / 8)
	defer delete(out)
	file := ([^]u8)(raw_data(out))[:GLYPH_CACHE_LIMIT]
	writer, bytes := writer_make()
	defer mem.free_bytes(bytes)
	for face in ([3]demand_cache.Face{.Cells, .Cells_Without_Grid_Fit, .Cells_Bold}) {
		form := demand_cache.face_forms[face]
		font_bytes := font_file_of(face)
		font, problem := font_open(font_bytes)
		testing.expect_value(t, problem, Font_Problem.None)
		size: int
		size, problem = glyph_cache_build(&font, font_bytes, "paper_mono", form.grid_fit, memory, file, form.scale_count)
		testing.expect_value(t, problem, Font_Problem.None)
		cache, refused := glyph_cache.validate(file[:size])
		testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
		testing.expectf(t, demand_cache.reader_matches(face, &cache), "%v: the cache of the build has the form of the face", face)
		demand: Demand_Font
		demand, problem = demand_font_open(font_bytes, face, memory)
		testing.expect_value(t, problem, Font_Problem.None)
		testing.expectf(t, demand.flags == cache.header.flags, "%v: the flags of the cache of the build", face)
		characters := [?]rune{'A', 'g', 'j', 'W', '_', '|', ' ', 'é', '€'}
		for character in characters {
			entry, result := demand_glyph_draw(&demand, &writer, character, memory)
			testing.expectf(t, result == .Drawn && demand_cache.entry_valid(face, &entry), "%v: U+%04X is drawn on demand, in its cell", face, int(character))
			for scale in 1 ..= form.scale_count {
				_, built, _ := glyph_cache.glyph(&cache, character, scale)
				index, _ := glyph_cache.character_index(character)
				testing.expectf(t, entry.advances[scale - 1] == glyph_cache.advances_of(&cache, scale)[index], "%v: U+%04X at scale %v: the advance of the build", face, int(character), scale)
				on_demand, _ := demand_cache.glyph_of_entry(face, &entry, scale, 0)
				same_box := on_demand.row_count == built.row_count && (built.row_count == 0 || on_demand.first_row == built.first_row && on_demand.left == built.left && on_demand.width == built.width)
				testing.expectf(t, same_box, "%v: U+%04X at scale %v: the box of the build", face, int(character), scale)
				if !same_box {
					continue
				}
				count := int(built.row_count) * int(built.width)
				differ := 0
				for word in 0 ..< count {
					if writer.words[int(on_demand.word_offset) + word] != cache.words[int(built.word_offset) + word] {
						differ += 1
					}
				}
				testing.expectf(t, differ == 0, "%v: U+%04X at scale %v: %v words differ from the build", face, int(character), scale, differ)
			}
		}
	}
}

// Each face of the subset fits one demand cache, as the font service draws
// it at its start: each character of the subset of each face, face after
// face, is drawn, in the limits of the contract, with no refusal. So no
// process can fill the cache, as the font service publishes no character
// that is not in a subset. This test needs the subsets of
// resources/fonts that hold the characters on demand: modustool
// vector_fonts writes them.
@(test)
each_face_of_the_subset_fits_the_demand_cache :: proc(t: ^testing.T) {
	memory := new(Render_Memory)
	defer free(memory)
	writer, bytes := writer_make()
	defer mem.free_bytes(bytes)
	for face in demand_cache.Face {
		demand, problem := demand_font_open(font_file_of(face), face, memory)
		testing.expectf(t, problem == .None, "%v: the font opens", face)
		for range in demand_cache.subset_of(face) {
			for character in range.first ..= range.last {
				place, search := demand_cache.place_find(&writer, face, character)
				testing.expectf(t, search == .Free, "%v: U+%04X of the subset has a place", face, int(character))
				entry, result := demand_glyph_draw(&demand, &writer, character, memory)
				testing.expectf(t, result == .Drawn && demand_cache.entry_valid(face, &entry), "%v: U+%04X of the subset is drawn, in the limits of the contract", face, int(character))
				if search == .Free {
					demand_cache.publish(&writer, place, face, character, entry)
				}
			}
		}
	}
	testing.expectf(t, writer.words_used <= demand_cache.WORD_CAPACITY && writer.refused == 0, "the subsets take %v words of %v", writer.words_used, demand_cache.WORD_CAPACITY)
	total := 0
	for face in demand_cache.Face {
		total += demand_cache.subset_count(face)
	}
	testing.expect_value(t, writer.entry_count, total)
}

// A character that the font does not have, the capital pi and the small
// rho of B612 among them, is absent; a character whose words do not fit is
// refused, and gives its words back. A face of cells is refused the same
// way.
@(test)
the_absent_and_the_refused_characters :: proc(t: ^testing.T) {
	memory := new(Render_Memory)
	defer free(memory)
	demand, problem := demand_font_open(b612_subset, .Interface, memory)
	testing.expect_value(t, problem, Font_Problem.None)
	writer, bytes := writer_make()
	defer mem.free_bytes(bytes)
	absent := [?]rune{0x03A0, 0x03C1, 0x0101, 0x4E00}
	for character in absent {
		_, result := demand_glyph_draw(&demand, &writer, character, memory)
		testing.expectf(t, result == .Absent, "U+%04X is absent from the font", int(character))
	}
	writer.words_used = demand_cache.WORD_CAPACITY - 1
	_, result := demand_glyph_draw(&demand, &writer, 'W', memory)
	testing.expect_value(t, result, Demand_Result.Refused)
	testing.expect_value(t, writer.words_used, demand_cache.WORD_CAPACITY - 1)
	cells: Demand_Font
	cells, problem = demand_font_open(paper_mono_subset, .Cells, memory)
	testing.expect_value(t, problem, Font_Problem.None)
	_, result = demand_glyph_draw(&cells, &writer, 'W', memory)
	testing.expect_value(t, result, Demand_Result.Refused)
	testing.expect_value(t, writer.words_used, demand_cache.WORD_CAPACITY - 1)
	_, result = demand_glyph_draw(&cells, &writer, 0x4E00, memory)
	testing.expect_value(t, result, Demand_Result.Absent)
}
