#+build !freestanding
#+build !modus
package vector_font

import "core:testing"

@(private = "file")
placed_b612_regular := #load("../../../../resources/fonts/b612.ttf")
@(private = "file")
placed_b612_bold := #load("../../../../resources/fonts/b612_bold.ttf")

// The size of B612 on the grid comes from the cap height that the font
// states (1500 units in both weights), not from the top of the outline of
// "H" (1520 in Regular, 1527 in Bold, the angled tops of its stems): one
// cell is 1200 units in both weights. The rows of a flat capital of the
// face are in the test of the text rendering
// (a_flat_capital_sits_on_ten_rows).
@(test)
the_stated_cap_height_sizes_b612 :: proc(t: ^testing.T) {
	memory := new(Render_Memory)
	defer free(memory)
	for bytes in ([2][]u8{placed_b612_regular, placed_b612_bold}) {
		font, problem := font_open(bytes)
		testing.expect_value(t, problem, Font_Problem.None)
		measures, measured := font_measures(&font, memory)
		testing.expect_value(t, measured, Font_Problem.None)
		testing.expect(t, measures.cap_height > 1500) // The top of "H".
		placed, placed_problem := proportional_measures(&font, measures)
		testing.expect_value(t, placed_problem, Font_Problem.None)
		testing.expect_value(t, placed.cap_height, 1500)
		testing.expect_value(t, placed.x_height, 1100)
		testing.expect_value(t, placed.advance, 1200)
	}
}

// The rounding of a length: the nearest integer, a half toward plus
// infinity on both sides of 0.
@(test)
the_rounding_of_a_half :: proc(t: ^testing.T) {
	testing.expect_value(t, divide_rounded(-85, 2), i64(-42))
	testing.expect_value(t, divide_rounded(85, 2), i64(43))
	testing.expect_value(t, divide_rounded(-128, 3), i64(-43)) // -42.67
	testing.expect_value(t, divide_rounded(0, 3), i64(0))
}
