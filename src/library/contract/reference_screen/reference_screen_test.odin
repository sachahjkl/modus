#+build !freestanding
package reference_screen

import "core:testing"

// An empty list, a list of modes that the system cannot draw, and a list
// of larger modes only: no mode is chosen, and the firmware keeps its mode.
@(test)
no_mode_is_chosen_with_nothing_that_fits :: proc(t: ^testing.T) {
	chosen, choice := mode_choose(nil)
	testing.expect_value(t, choice, Mode_Choice.None)
	testing.expect_value(t, chosen, Screen_Mode{})

	other_format := []Screen_Mode{{number = 0, width = WIDTH, height = HEIGHT, drawable = false}, {number = 1, width = 1024, height = 768, drawable = false}}
	chosen, choice = mode_choose(other_format)
	testing.expect_value(t, choice, Mode_Choice.None)
	testing.expect_value(t, chosen, Screen_Mode{})

	larger := []Screen_Mode{{number = 0, width = WIDTH + 1, height = HEIGHT, drawable = true}, {number = 1, width = WIDTH, height = HEIGHT + 1, drawable = true}, {number = 2, width = 2560, height = 1600, drawable = true}, {number = 3, width = max(u32), height = max(u32), drawable = true}}
	chosen, choice = mode_choose(larger)
	testing.expect_value(t, choice, Mode_Choice.None)
	testing.expect_value(t, chosen, Screen_Mode{})

	no_side := []Screen_Mode{{number = 0, width = 0, height = HEIGHT, drawable = true}, {number = 1, width = WIDTH, height = 0, drawable = true}, {number = 2, width = 0, height = 0, drawable = true}}
	chosen, choice = mode_choose(no_side)
	testing.expect_value(t, choice, Mode_Choice.None)
}

// With no exact mode, the largest mode that fits inside the reference
// screen in both sides: never a larger one, never one of another format,
// the first one of two of the same size.
@(test)
the_largest_mode_inside_the_reference_screen_is_chosen :: proc(t: ^testing.T) {
	one_smaller := []Screen_Mode{{number = 4, width = 1280, height = 800, drawable = true}}
	chosen, choice := mode_choose(one_smaller)
	testing.expect_value(t, choice, Mode_Choice.Smaller)
	testing.expect_value(t, chosen.number, u32(4))

	modes := []Screen_Mode {
		{number = 0, width = 640, height = 480, drawable = true},
		{number = 1, width = WIDTH, height = 1200, drawable = true}, // Higher than the reference screen.
		{number = 2, width = 1600, height = 900, drawable = false}, // Another format.
		{number = 3, width = 1280, height = 1024, drawable = true},
		{number = 4, width = 1440, height = 900, drawable = true}, // Wider than 3, but fewer pixels: 1296000 against 1310720.
		{number = 5, width = 1280, height = 1024, drawable = true}, // The size of 3, later in the list.
		{number = 6, width = WIDTH, height = HEIGHT - 1, drawable = true},
	}
	chosen, choice = mode_choose(modes[:6])
	testing.expect_value(t, choice, Mode_Choice.Smaller)
	testing.expect_value(t, chosen.number, u32(3))
	chosen, choice = mode_choose(modes)
	testing.expect_value(t, choice, Mode_Choice.Smaller)
	testing.expect_value(t, chosen.number, u32(6))
}

// The exact mode wins over every other mode, wherever it is in the list,
// but only in a format that the system draws.
@(test)
the_exact_mode_is_chosen :: proc(t: ^testing.T) {
	modes := []Screen_Mode {
		{number = 0, width = WIDTH, height = HEIGHT, drawable = false},
		{number = 1, width = 1600, height = 900, drawable = true},
		{number = 2, width = 2560, height = 1440, drawable = true},
		{number = 3, width = WIDTH, height = HEIGHT, drawable = true},
		{number = 4, width = WIDTH, height = HEIGHT, drawable = true},
	}
	chosen, choice := mode_choose(modes)
	testing.expect_value(t, choice, Mode_Choice.Exact)
	testing.expect_value(t, chosen, modes[3])
	exact_only := []Screen_Mode{{number = 9, width = WIDTH, height = HEIGHT, drawable = true}}
	chosen, choice = mode_choose(exact_only)
	testing.expect_value(t, choice, Mode_Choice.Exact)
	testing.expect_value(t, chosen.number, u32(9))
}
