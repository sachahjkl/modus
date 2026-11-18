#+build !freestanding
package graphics

import "core:testing"

// The least contrast of a text of normal size (WCAG 2), and of a large
// text: a text of 24 pixels or more.
TEXT_CONTRAST_LEAST :: 4.5
LARGE_TEXT_CONTRAST_LEAST :: 3.0
// The least contrast of a graphic that carries a fact (WCAG 2.1, 1.4.11).
GRAPHIC_CONTRAST_LEAST :: 3.0

// expect_contrast checks that one pair of colors keeps a contrast, and names
// the pair and the appearance in its message.
expect_contrast :: proc(t: ^testing.T, of: Appearance, what: string, text, surface: Color, least: f64) {
	ratio := value_contrast_ratio(text, surface)
	testing.expectf(t, ratio >= least, "%v appearance: %s (%06x on %06x): a contrast of %.2f; at least %.1f", of, what, u32(text), u32(surface), ratio, least)
}

// The pairs of colors of the palette (docs/DESIGN.md, "Palette") keep the
// contrast that a text needs, in each appearance.
@(test)
palette_colors_keep_their_contrast :: proc(t: ^testing.T) {
	for of in Appearance {
		tokens := color_tokens_of(of)
		// The chosen row: its name and its hint are white on the chosen blue.
		expect_contrast(t, of, "white on the chosen row", COLOR_WHITE, tokens.chosen, TEXT_CONTRAST_LEAST)
		// The row that asks for a second Enter: white on the color of "stop a
		// process".
		expect_contrast(t, of, "white on the row that asks", COLOR_WHITE, tokens.stop_process, TEXT_CONTRAST_LEAST)
		// The input band: the typed part is the strong text on the track,
		// and each class of code keeps its contrast there too.
		expect_contrast(t, of, "the typed part on the input band", tokens.text_strong, tokens.track, TEXT_CONTRAST_LEAST)
		for class in Code_Class {
			if class != .None {
				expect_contrast(t, of, "a class of code on the input band", code_class_color(class, of), tokens.track, TEXT_CONTRAST_LEAST)
			}
		}
		// The placeholder of the input band is dim, at twice the size of the
		// font: a large text.
		expect_contrast(t, of, "the placeholder on the input band", tokens.dim, tokens.track, LARGE_TEXT_CONTRAST_LEAST)
		// The rows, the headings of the groups, the detail line and the
		// footer are on the surface of a card: the name in the text color,
		// the words at the right and the sentences in the dim color.
		for surface in ([2]Color{tokens.card_top, tokens.card_bottom}) {
			expect_contrast(t, of, "a name on the card", tokens.text, surface, TEXT_CONTRAST_LEAST)
			expect_contrast(t, of, "a dim text on the card", tokens.dim, surface, TEXT_CONTRAST_LEAST)
		}
	}
}

// The icon of a row of the palette (docs/DESIGN.md, "The icons of the
// kinds") keeps the contrast of a graphic on each surface under it, in each
// appearance: each color that an icon takes on the surface of a card, and
// white on the chosen row and on the row that asks for a second Enter. The
// deep red of "stop a process" does not keep it on a dark card, so the icon
// of an entry that destroys has the brighter red of that concept.
@(test)
palette_icon_colors_keep_their_contrast :: proc(t: ^testing.T) {
	for of in Appearance {
		tokens := color_tokens_of(of)
		icon_colors := [?]Color {
			value_kind_color(.Module, of), // A module whose process has a window, an export.
			value_kind_color(.Command, of), // A command.
			value_kind_color(.Grant, of), // A grant, as a candidate of a field.
			tokens.title, // The window that has the focus.
			tokens.text, // The value of a setting that the machine uses.
			tokens.dim, // The quiet state of each of them.
			tokens.stop_process_pointer_over, // An entry that destroys.
		}
		for surface in ([2]Color{tokens.card_top, tokens.card_bottom}) {
			for color in icon_colors {
				expect_contrast(t, of, "an icon on the card", color, surface, GRAPHIC_CONTRAST_LEAST)
			}
		}
		expect_contrast(t, of, "a white icon on the chosen row", COLOR_WHITE, tokens.chosen, GRAPHIC_CONTRAST_LEAST)
		expect_contrast(t, of, "a white icon on the row that asks", COLOR_WHITE, tokens.stop_process, GRAPHIC_CONTRAST_LEAST)
		// Why each icon of a chosen row is white: the color of a module is
		// under the bound on the chosen blue.
		testing.expect(t, value_contrast_ratio(value_kind_color(.Module, of), tokens.chosen) < GRAPHIC_CONTRAST_LEAST)
	}
	// Why the icon of an entry that destroys is not in the deep red: that
	// pair is under the bound on a card of the dark appearance.
	testing.expect(t, value_contrast_ratio(DARK_STOP_PROCESS, DARK_CARD_TOP) < GRAPHIC_CONTRAST_LEAST)
}
