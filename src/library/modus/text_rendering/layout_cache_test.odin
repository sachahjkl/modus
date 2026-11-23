#+build !freestanding
package text_rendering

import "core:fmt"
import "core:testing"
import "modus:vector_font"

// The cache of the walk of each font of the script font set: no font is
// refused at its open, and for each script of each table and each feature
// of its default language system, the cache gives the lookups that the
// walk gives. The reads of each fill and the part of the pool that the set
// takes are printed.
@(test)
the_cache_of_each_font_of_the_set :: proc(t: ^testing.T) {
	test_state_take()
	words, script_words, missing := script_set_open(t, script_font_names[:])
	defer delete(words)
	defer delete(script_words)
	testing.expect_value(t, missing, Outline_Fonts{})
	testing.expect_value(t, layout_refused_fonts(), Outline_Fonts{})
	tags := [?]vector_font.Feature_Tag{{'l', 'a', 't', 'n'}, {'D', 'F', 'L', 'T'}, {'a', 'r', 'a', 'b'}, {'d', 'e', 'v', '2'}, {'b', 'n', 'g', '2'}, {'t', 'm', 'l', '2'}, {'m', 'l', 'm', '2'}, {'h', 'a', 'n', 'i'}}
	features := [?]vector_font.Feature_Tag{{'c', 'c', 'm', 'p'}, {'l', 'o', 'c', 'l'}, {'i', 'n', 'i', 't'}, {'h', 'a', 'l', 'f'}, {'p', 'r', 'e', 's'}, {'r', 'c', 'l', 't'}, {'m', 'a', 'r', 'k'}, {'k', 'e', 'r', 'n'}, {'v', 'e', 'r', 't'}}
	for font in SCRIPT_FONTS {
		file := &font_at(&state.font_set, font).file
		testing.expectf(t, file.layout_cache != nil, "%v keeps the walk of its tables", font)
		uncached := file^
		uncached.layout_cache = nil
		for script in tags {
			for feature in features {
				for place in ([2]vector_font.Table{file.gsub, file.gpos}) {
					cached, walked: vector_font.Layout_Lookups
					cached_problem := vector_font.layout_lookups(file, place, script, {'D', 'F', 'L', 'T'}, feature, &cached)
					walked_problem := vector_font.layout_lookups(&uncached, place, script, {'D', 'F', 'L', 'T'}, feature, &walked)
					testing.expectf(t, cached_problem == walked_problem && cached.count == walked.count && cached.indices == walked.indices, "%v %s %s: the cache gives %v %d, the walk %v %d", font, script, feature, cached_problem, cached.count, walked_problem, walked.count)
				}
			}
		}
		fmt.printfln("text_rendering: the fill of the cache of %v reads %d entries, of %d", font, state.layout_fill_reads[font], vector_font.LAYOUT_FILL_READ_LIMIT)
	}
	fmt.printfln("text_rendering: the caches of the %d script fonts take %d entries of %d and %d lookup indices of %d", card(SCRIPT_FONTS), state.layout_entries_used, LAYOUT_CACHE_ENTRY_LIMIT, state.layout_indices_used, LAYOUT_CACHE_INDEX_LIMIT)
}

// Crossing the inline pool capacity: a valid script font that does not fit
// the remaining pool stays open on the slower uncached walk tier, increments
// layout_cache_overflows, and is never marked refused.
@(test)
layout_cache_inline_capacity_moves_to_uncached_tier :: proc(t: ^testing.T) {
	test_state_take()
	words, script_words, missing := script_set_open(t, []string{"noto_sans_devanagari"})
	defer delete(words)
	defer delete(script_words)
	testing.expect(t, .Noto_Sans_Devanagari not_in missing)
	file := font_at(&state.font_set, .Noto_Sans_Devanagari).file
	file.layout_cache = nil
	// Set remaining pool entries to 1 (strictly less than Devanagari needs).
	state.layout_entries_used = LAYOUT_CACHE_ENTRY_LIMIT - 1
	state.layout_indices_used = 0
	state.layout_uncached = {}
	state.layout_cache_overflows = 0
	testing.expect(t, layout_cache_of(.Noto_Sans_Devanagari, &file))
	testing.expect(t, file.layout_cache == nil)
	testing.expect(t, .Noto_Sans_Devanagari in layout_uncached_fonts())
	testing.expect_value(t, state.layout_cache_overflows, u64(1))
	testing.expect_value(t, layout_refused_fonts(), Outline_Fonts{})
	// Lookups still succeed via the uncached walk tier.
	lookups: vector_font.Layout_Lookups
	testing.expect_value(t, vector_font.layout_lookups(&file, file.gsub, {'d', 'e', 'v', '2'}, {'D', 'F', 'L', 'T'}, {'r', 'p', 'h', 'f'}, &lookups), vector_font.Font_Problem.None)
	testing.expect(t, lookups.count > 0)
}
