#+build !freestanding
#+build !modus
package graphics

import "modus:contract/value_kinds"
import "core:math"
import "core:testing"

// value_contrast_ratio gives the contrast ratio of two colors (WCAG 2), as
// the tests of the site and of the terminal compute it.
value_contrast_ratio :: proc(first, second: Color) -> f64 {
	luminance :: proc(color: Color) -> f64 {
		channel :: proc(value: u32) -> f64 {
			part := f64(value) / 255
			return part <= 0.03928 ? part / 12.92 : math.pow((part + 0.055) / 1.055, 2.4)
		}
		value := u32(color)
		return 0.2126 * channel((value >> 16) & 0xFF) + 0.7152 * channel((value >> 8) & 0xFF) + 0.0722 * channel(value & 0xFF)
	}
	lighter, darker := luminance(first), luminance(second)
	if lighter < darker {
		lighter, darker = darker, lighter
	}
	return (lighter + 0.05) / (darker + 0.05)
}

// Each value kind keeps its contrast on the surfaces where a process draws
// values, in each appearance: the background and the two colors of a card.
// The band of every second row of the process log is the top of a card.
@(test)
value_colors_keep_their_contrast :: proc(t: ^testing.T) {
	for of in Appearance {
		tokens := color_tokens_of(of)
		surfaces := [?]Color{tokens.background, tokens.card_top, tokens.card_bottom}
		for kind in value_kinds.Value_Kind {
			color := value_kind_color(kind, of)
			for surface in surfaces {
				ratio := value_contrast_ratio(color, surface)
				testing.expectf(t, ratio >= TEXT_CONTRAST_LEAST, "%v appearance: the value kind %v (%06x) on %06x: a contrast of %.2f; at least %.1f", of, kind, u32(color), u32(surface), ratio, TEXT_CONTRAST_LEAST)
			}
		}
	}
}

// The kind None has the plain color, or the text color of the appearance
// with no plain color. A byte past the kinds never reaches the table: its
// border refuses it (value_kinds.value_kind_of).
@(test)
value_kind_none_is_plain :: proc(t: ^testing.T) {
	_, past_the_kinds_ok := value_kinds.value_kind_of(200)
	testing.expect(t, !past_the_kinds_ok)
	testing.expect_value(t, value_kind_color(.None, .Dark, DARK_DIM), Color(DARK_DIM))
	testing.expect_value(t, value_kind_color(.None, .Light), color_tokens_of(.Light).text)
	testing.expect_value(t, value_kind_color(.None, .Dark), color_tokens_of(.Dark).text)
	testing.expect_value(t, value_kind_color(.Size, .Dark), shade(DARK_MEMORY, 100))
}
