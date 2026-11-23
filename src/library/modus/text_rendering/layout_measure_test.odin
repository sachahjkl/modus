#+build !freestanding
package text_rendering

import "core:fmt"
import "core:testing"
import "core:time"

// The time of the shaping of a line of each script that reads the tables
// GSUB and GPOS of its font: printed as a measure, never asserted. Opt-in:
// -define:MEASURE=true (a test that measures time is opt-in).
@(private = "file")
MEASURE :: #config(MEASURE, false)

@(test)
the_time_of_a_line_of_each_script :: proc(t: ^testing.T) {
	when !MEASURE {
		return
	}
	test_state_take()
	names := [?]string{"noto_sans_arabic", "noto_sans_devanagari", "noto_sans_bengali", "noto_sans_symbols_2", "noto_sans_cjk"}
	words, script_words, _ := script_set_open(t, names[:])
	defer delete(words)
	defer delete(script_words)
	Line :: struct {
		name, text: string,
	}
	lines := [?]Line {
		{"arabic", "مرحبا بالعالم هذا نص عربي قصير للقياس"},
		{"devanagari", "नमस्ते दुनिया यह हिन्दी का एक छोटा वाक्य है"},
		{"bengali", "নমস্কার পৃথিবী এটি বাংলা ভাষার একটি ছোট বাক্য"},
	}
	placed: [256]Placed_Glyph
	spacing, _ := spacing_of(.Interface, TEXT_SIZE_OF_SCALE_ONE)
	fmt.printfln("text_rendering: the caches of the walk of %d fonts take %d entries of %d and %d lookup indices of %d", len(names), state.layout_entries_used, LAYOUT_CACHE_ENTRY_LIMIT, state.layout_indices_used, LAYOUT_CACHE_INDEX_LIMIT)
	ROUNDS :: 200
	for line in lines {
		least := max(i64)
		for _ in 0 ..< ROUNDS {
			start := time.tick_now()
			_, _, _ = shape(&spacing, transmute([]u8)line.text, placed[:])
			least = min(least, i64(time.tick_since(start)))
		}
		fmt.printfln("text_rendering: the shaping of a line of %s (%d bytes), the least of %d: %d ns", line.name, len(line.text), ROUNDS, least)
	}
}
