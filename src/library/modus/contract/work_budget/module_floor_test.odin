#+build !freestanding
package work_budget

import "core:testing"

@(test)
module_floor_refusals_glyph_copies_and_overflow :: proc(t: ^testing.T) {
	// Enum border checks.
	ref, ok := module_floor_refusal_of_word(u64(Module_Floor_Refusal.Bad_Value))
	testing.expect(t, ok)
	testing.expect_value(t, ref, Module_Floor_Refusal.Bad_Value)
	_, bad_high := module_floor_refusal_of_word(u64(Module_Floor_Refusal.Bad_Value) + 1)
	testing.expect(t, !bad_high)
	_, bad_max := module_floor_refusal_of_word(max(u64))
	testing.expect(t, !bad_max)

	// Zero load_pages refused.
	total, r := module_floor_total_pages({start_object_pages = 10})
	testing.expect_value(t, r, Module_Floor_Refusal.Zero_Load_Pages)
	testing.expect_value(t, total, u64(0))

	// Overflow on every component refused.
	_, r = module_floor_total_pages({load_pages = max(u64), start_object_pages = 1})
	testing.expect_value(t, r, Module_Floor_Refusal.Overflow)
	_, r = module_floor_total_pages({load_pages = 1, own_text_glyph_pages = max(u64)})
	testing.expect_value(t, r, Module_Floor_Refusal.Overflow)
	_, r = module_floor_total_pages({load_pages = 1, drawing_text_glyph_pages = max(u64)})
	testing.expect_value(t, r, Module_Floor_Refusal.Overflow)
	_, r = module_floor_total_pages({load_pages = 1, child_floor_pages = max(u64)})
	testing.expect_value(t, r, Module_Floor_Refusal.Overflow)

	// Exact MODULE_FLOOR_MAX_PAGES succeeds; +1 refused with Exceeds_Limit.
	exact, r_exact := module_floor_total_pages({load_pages = MODULE_FLOOR_MAX_PAGES})
	testing.expect_value(t, r_exact, Module_Floor_Refusal.None)
	testing.expect_value(t, exact, MODULE_FLOOR_MAX_PAGES)

	_, r_over := module_floor_total_pages({load_pages = MODULE_FLOOR_MAX_PAGES, start_object_pages = 1})
	testing.expect_value(t, r_over, Module_Floor_Refusal.Exceeds_Limit)

	// Glyph copy counting: neither, own only, drawing only, both, and zero per-copy refusal.
	_, _, r_bad := module_floor_glyph_pages(true, false, 0)
	testing.expect_value(t, r_bad, Module_Floor_Refusal.Bad_Value)
	_, _, r_bad2 := module_floor_glyph_pages(false, true, 0)
	testing.expect_value(t, r_bad2, Module_Floor_Refusal.Bad_Value)

	own0, draw0, r0 := module_floor_glyph_pages(false, false, 0)
	testing.expect_value(t, r0, Module_Floor_Refusal.None)
	testing.expect_value(t, own0, u64(0))
	testing.expect_value(t, draw0, u64(0))

	own1, draw1, r1 := module_floor_glyph_pages(true, true)
	testing.expect_value(t, r1, Module_Floor_Refusal.None)
	testing.expect_value(t, own1, GLYPH_CACHE_PRIVATE_DEFAULT_PAGES)
	testing.expect_value(t, draw1, GLYPH_CACHE_PRIVATE_DEFAULT_PAGES)

	// Realistic window module floor combining all 5 counted components.
	sum, r_sum := module_floor_total_pages({
		load_pages               = 240,
		start_object_pages       = 32,
		own_text_glyph_pages     = own1,
		drawing_text_glyph_pages = draw1,
		child_floor_pages        = 128,
	})
	testing.expect_value(t, r_sum, Module_Floor_Refusal.None)
	testing.expect_value(t, sum, u64(240 + 32 + 64 + 64 + 128))
}
