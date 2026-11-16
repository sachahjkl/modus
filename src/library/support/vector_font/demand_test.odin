#+build !freestanding
package vector_font

import "core:mem"
import "core:testing"
import "modus:contract/demand_cache"
import "modus:contract/glyph_cache"

@(private = "file")
b612_subset := #load("../../../../resources/fonts/b612.ttf")

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
	positions := [demand_cache.SIZE_COUNT]int{demand_cache.position_count_of(1), demand_cache.position_count_of(2), demand_cache.position_count_of(3)}
	size: int
	size, problem = glyph_cache_build_proportional(&font, b612_subset, "b612", true, memory, file, positions[:])
	testing.expect_value(t, problem, Font_Problem.None)
	cache, refused := glyph_cache.validate(file[:size])
	testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
	testing.expect(t, demand_cache.reader_matches(&cache))

	demand: Demand_Font
	demand, problem = demand_font_open(b612_subset, true, memory)
	testing.expect_value(t, problem, Font_Problem.None)
	testing.expect_value(t, demand.flags, cache.header.flags)
	bytes, allocation := mem.alloc_bytes(demand_cache.SIZE, demand_cache.PAGE_SIZE)
	testing.expect(t, allocation == nil)
	defer mem.free_bytes(bytes)
	writer := demand_cache.writer_open(uintptr(raw_data(bytes)), cache.header.font_hash, RENDERER_VERSION, demand.flags)

	characters := [?]rune{'A', 'g', 'j', 'W', 'T', ' ', 'é', 'ÿ', '€'}
	for character in characters {
		entry, result := demand_glyph_draw(&demand, &writer, character, memory)
		testing.expectf(t, result == .Drawn, "U+%04X is drawn on demand", int(character))
		index, _ := glyph_cache.character_index(character)
		for scale in 1 ..= demand_cache.SIZE_COUNT {
			testing.expectf(t, entry.advances[scale - 1] == glyph_cache.advances_of(&cache, scale)[index], "U+%04X at scale %v: the advance of the build", int(character), scale)
			for position in 0 ..< demand_cache.position_count_of(scale) {
				on_demand, _ := demand_cache.glyph_of_entry(&entry, scale, position)
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

// The characters of the subset past the glyph cache are drawn; a
// character that the font does not have, the capital pi and the small rho
// of B612 among them,
// is absent; a character whose words do not fit is refused, and gives its
// words back.
@(test)
the_greek_letters_and_the_refusals :: proc(t: ^testing.T) {
	memory := new(Render_Memory)
	defer free(memory)
	demand, problem := demand_font_open(b612_subset, true, memory)
	testing.expect_value(t, problem, Font_Problem.None)
	bytes, _ := mem.alloc_bytes(demand_cache.SIZE, demand_cache.PAGE_SIZE)
	defer mem.free_bytes(bytes)
	hash: [32]u8
	writer := demand_cache.writer_open(uintptr(raw_data(bytes)), hash, RENDERER_VERSION, demand.flags)
	// Each character of the subset fits one demand cache: no program can
	// fill it, as the font service publishes no character that the font
	// lacks.
	for range in demand_cache.subset_ranges {
		for character in range.first ..= range.last {
			place, search := demand_cache.place_find(&writer, character)
			testing.expectf(t, search == .Free, "U+%04X of the subset has a place", int(character))
			entry, result := demand_glyph_draw(&demand, &writer, character, memory)
			testing.expectf(t, result == .Drawn && demand_cache.entry_valid(&entry), "U+%04X of the subset is drawn, in the limits of the contract", int(character))
			demand_cache.publish(&writer, place, character, entry)
		}
	}
	testing.expectf(t, writer.words_used < demand_cache.WORD_CAPACITY / 4, "the subset takes %v words of %v", writer.words_used, demand_cache.WORD_CAPACITY)
	absent := [?]rune{0x03A0, 0x03C1, 0x0101, 0x4E00}
	for character in absent {
		_, result := demand_glyph_draw(&demand, &writer, character, memory)
		testing.expectf(t, result == .Absent, "U+%04X is absent from the font", int(character))
	}
	writer.words_used = demand_cache.WORD_CAPACITY - 1
	_, result := demand_glyph_draw(&demand, &writer, 'W', memory)
	testing.expect_value(t, result, Demand_Result.Refused)
	testing.expect_value(t, writer.words_used, demand_cache.WORD_CAPACITY - 1)
}
