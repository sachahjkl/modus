#+build !freestanding
package complex_shaping

import "core:testing"

@(test)
arabic_ligature_joining_cjk_width_and_reflow :: proc(t: ^testing.T) {
	// Arabic "سلام" (Seen + Lam + Alef + Meem): Seen Initial + Lam-Alef Final ligature + Meem Isolated.
	word := [4]rune{0x0633, 0x0644, 0x0627, 0x0645}
	out: [8]Shaped_Glyph
	n := shape_run(word[:], 8, out[:])
	testing.expect_value(t, n, 3)
	testing.expect_value(t, out[0].codepoint, rune(0xFEB3)) // Seen Initial
	testing.expect_value(t, out[1].codepoint, rune(0xFEFC)) // Lam-Alef Final ligature
	testing.expect_value(t, out[2].codepoint, rune(0xFEE1)) // Meem Isolated

	// CJK ideograph gets 2x width; combining acute gets 0 width.
	mixed := [3]rune{'e', 0x0301, 0x4E2D} // e + combining acute + 中
	m_out: [4]Shaped_Glyph
	mn := shape_run(mixed[:], 10, m_out[:])
	testing.expect_value(t, mn, 3)
	testing.expect_value(t, m_out[0].advance_px, i32(10))
	testing.expect_value(t, m_out[1].advance_px, i32(0))
	testing.expect(t, m_out[2].is_wide_cjk && m_out[2].advance_px == 20)

	// Larger text reflows inside fixed 25px width into 2 lines instead of enlarging window.
	testing.expect_value(t, reflow_line_count(m_out[:mn], 25), 2)
}
