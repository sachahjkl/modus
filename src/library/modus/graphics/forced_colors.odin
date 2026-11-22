// Forced high-contrast color token axis and pure integer WCAG relative
// luminance checks (src/md/features/accessibility.md, "4. The settings of the principal").
//
// Adds the closed Color_Contrast_Mode axis beside Appearance so high-contrast
// dark and light palettes stay in the one color token table with flat surfaces
// (no decorative gradients or dot grid) and mathematically guaranteed WCAG AAA
// (>= 7.0:1) contrast ratios across foreground and surface pairs.
package graphics

import "modus:contract/enum_word"

// Colors is the palette alias of Color_Tokens returned by contrast-mode queries.
Colors :: Color_Tokens

// WCAG 2.x minimum contrast thresholds multiplied by 100.
WCAG_AAA_CONTRAST_RATIO_X100 :: u32(700) // 7.00:1 for normal text in high-contrast modes.
WCAG_AA_CONTRAST_RATIO_X100 :: u32(450)  // 4.50:1 for standard normal text.

// Closed set of desktop contrast modes. Standard follows the dark/light
// appearance; the forced high-contrast modes override surfaces and accents to
// meet WCAG AAA (>= 7.0:1) on every foreground/surface pair.
Color_Contrast_Mode :: enum u8 {
	Standard                   = 0,
	Forced_High_Contrast_Dark  = 1,
	Forced_High_Contrast_Light = 2,
}

// color_contrast_mode_of_word is the single border converting a transport word
// into a Color_Contrast_Mode member.
color_contrast_mode_of_word :: proc "contextless" (word: u64) -> (mode: Color_Contrast_Mode, ok: bool) {
	return enum_word.member_of_word(Color_Contrast_Mode, word)
}

// Forced high-contrast dark palette: pure black background, flat surfaces
// (card_top == card_bottom, point == background), and bright high-luminance
// accents guaranteeing >= 7.0:1 contrast on background, cards, and track.
FORCED_HIGH_CONTRAST_DARK_COLORS :: Colors {
	background                = 0x000000,
	point                     = 0x000000,
	card_top                  = 0x080808,
	card_bottom               = 0x080808,
	track                     = 0x141414,
	firmware                  = 0xC8B0FF,
	boot_program              = 0xFFD060,
	kernel                    = 0x7CC8FF,
	process                   = 0x6BFF90,
	memory                    = 0x5CEEE0,
	machine                   = 0xFFA0E0,
	no_entry                  = 0xE8E468,
	resource                  = 0xC8D4F0,
	failed                    = 0xFF8C8C,
	not_usable                = 0xB8C2CE,
	text                      = COLOR_WHITE,
	dim                       = 0xD0D8E2,
	text_strong               = COLOR_WHITE,
	warning                   = 0xFFE65C,
	near_limit                = 0xFFB066,
	link                      = 0x80D4FF,
	series                    = {0x80C8FF, 0xFFB866, 0x70FF88, 0xE89CFF, 0xFF94B8, 0x70F0E8, 0xECEC70, 0xB8E660},
	title                     = 0x0044AA,
	title_end                 = 0x0044AA,
	chosen                    = 0x003D99,
	title_quiet               = 0x141414,
	title_quiet_end           = 0x141414,
	stop_process              = 0x9E0018,
	stop_process_pointer_over = 0x8A0014,
	stop_process_quiet        = 0x2B0008,
	stop_process_quiet_mark   = COLOR_WHITE,
}

// Forced high-contrast light palette: pure white background, flat surfaces
// (card_top == card_bottom, point == background), and deep low-luminance
// accents guaranteeing >= 7.0:1 contrast on background, cards, and track.
FORCED_HIGH_CONTRAST_LIGHT_COLORS :: Colors {
	background                = COLOR_WHITE,
	point                     = COLOR_WHITE,
	card_top                  = 0xFAFAFA,
	card_bottom               = 0xFAFAFA,
	track                     = 0xEBEBEB,
	firmware                  = 0x3C1C7A,
	boot_program              = 0x5C3400,
	kernel                    = 0x003B7A,
	process                   = 0x005218,
	memory                    = 0x004E4E,
	machine                   = 0x720E52,
	no_entry                  = 0x4C4400,
	resource                  = 0x26324A,
	failed                    = 0x8C0014,
	not_usable                = 0x3D454E,
	text                      = COLOR_BLACK,
	dim                       = 0x242A32,
	text_strong               = COLOR_BLACK,
	warning                   = 0x563E00,
	near_limit                = 0x6E2C00,
	link                      = 0x003388,
	series                    = {0x003A8C, 0x6E2E00, 0x00541C, 0x60107A, 0x7E0A3C, 0x004E4A, 0x4A4400, 0x2E4E00},
	title                     = 0x003388,
	title_end                 = 0x003388,
	chosen                    = 0x003388,
	title_quiet               = 0xEBEBEB,
	title_quiet_end           = 0xEBEBEB,
	stop_process              = 0x8C0014,
	stop_process_pointer_over = 0x700010,
	stop_process_quiet        = 0xFCE6E9,
	stop_process_quiet_mark   = 0x4A000A,
}

// colors_for_contrast_mode returns the complete desktop Colors palette for a
// given Color_Contrast_Mode and base dark/light appearance preference.
colors_for_contrast_mode :: proc "contextless" (mode: Color_Contrast_Mode, base_dark_mode: bool) -> Colors {
	switch mode {
	case .Standard:
		return base_dark_mode ? DARK_COLOR_TOKENS : LIGHT_COLOR_TOKENS
	case .Forced_High_Contrast_Dark:
		return FORCED_HIGH_CONTRAST_DARK_COLORS
	case .Forced_High_Contrast_Light:
		return FORCED_HIGH_CONTRAST_LIGHT_COLORS
	}
	return base_dark_mode ? DARK_COLOR_TOKENS : LIGHT_COLOR_TOKENS
}

// Exact sRGB channel [0..255] to linear intensity scaled by 1,000,000,
// following WCAG 2.x relative luminance transfer curve without floating point.
@(private = "file", rodata)
SRGB_LINEAR_PPM := [256]u32 {
	      0,     304,     607,     911,    1214,    1518,    1821,    2125,
	   2428,    2732,    3035,    3347,    3677,    4025,    4391,    4777,
	   5182,    5605,    6049,    6512,    6995,    7499,    8023,    8568,
	   9134,    9721,   10330,   10960,   11612,   12286,   12983,   13702,
	  14444,   15209,   15996,   16807,   17642,   18500,   19382,   20289,
	  21219,   22174,   23153,   24158,   25187,   26241,   27321,   28426,
	  29557,   30713,   31896,   33105,   34340,   35601,   36889,   38204,
	  39546,   40915,   42311,   43735,   45186,   46665,   48172,   49707,
	  51269,   52861,   54480,   56128,   57805,   59511,   61246,   63010,
	  64803,   66626,   68478,   70360,   72272,   74214,   76185,   78187,
	  80220,   82283,   84376,   86500,   88656,   90842,   93059,   95307,
	  97587,   99899,  102242,  104616,  107023,  109462,  111932,  114435,
	 116971,  119538,  122139,  124772,  127438,  130136,  132868,  135633,
	 138432,  141263,  144128,  147027,  149960,  152926,  155926,  158961,
	 162029,  165132,  168269,  171441,  174647,  177888,  181164,  184475,
	 187821,  191202,  194618,  198069,  201556,  205079,  208637,  212231,
	 215861,  219526,  223228,  226966,  230740,  234551,  238398,  242281,
	 246201,  250158,  254152,  258183,  262251,  266356,  270498,  274677,
	 278894,  283149,  287441,  291771,  296138,  300544,  304987,  309469,
	 313989,  318547,  323143,  327778,  332452,  337164,  341914,  346704,
	 351533,  356400,  361307,  366253,  371238,  376262,  381326,  386429,
	 391572,  396755,  401978,  407240,  412543,  417885,  423268,  428690,
	 434154,  439657,  445201,  450786,  456411,  462077,  467784,  473531,
	 479320,  485150,  491021,  496933,  502886,  508881,  514918,  520996,
	 527115,  533276,  539479,  545724,  552011,  558340,  564712,  571125,
	 577580,  584078,  590619,  597202,  603827,  610496,  617207,  623960,
	 630757,  637597,  644480,  651406,  658375,  665387,  672443,  679542,
	 686685,  693872,  701102,  708376,  715694,  723055,  730461,  737910,
	 745404,  752942,  760525,  768151,  775822,  783538,  791298,  799103,
	 806952,  814847,  822786,  830770,  838799,  846873,  854993,  863157,
	 871367,  879622,  887923,  896269,  904661,  913099,  921582,  930111,
	 938686,  947307,  955973,  964686,  973445,  982251,  991102, 1000000,
}

// relative_luminance_ppm returns the WCAG 2.x relative luminance of color in
// parts per million [0, 1_000_000] using pure integer arithmetic.
relative_luminance_ppm :: proc "contextless" (color: Color) -> u32 {
	r := u64(SRGB_LINEAR_PPM[(color >> 16) & 0xFF])
	g := u64(SRGB_LINEAR_PPM[(color >> 8) & 0xFF])
	b := u64(SRGB_LINEAR_PPM[color & 0xFF])
	return u32((2126 * r + 7152 * g + 722 * b + 5000) / 10000)
}

// contrast_ratio_x100 returns the WCAG 2.x contrast ratio between first and
// second multiplied by 100 (for example 2100 for 21.00:1, 700 for 7.00:1),
// computed with pure integer arithmetic and zero floating point.
contrast_ratio_x100 :: proc "contextless" (first, second: Color) -> u32 {
	lighter := u64(relative_luminance_ppm(first))
	darker := u64(relative_luminance_ppm(second))
	if lighter < darker {
		lighter, darker = darker, lighter
	}
	return u32(((lighter + 50_000) * 100) / (darker + 50_000))
}
