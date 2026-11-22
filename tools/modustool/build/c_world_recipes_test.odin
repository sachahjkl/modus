package build

import "core:testing"

@(test)
c_world_recipes_have_distinct_hashes_and_fixed_point_check :: proc(t: ^testing.T) {
	testing.expect_value(t, len(C_WORLD_RECIPES), 5)
	hashes: [5][32]u8
	for r, i in C_WORLD_RECIPES {
		testing.expect(t, len(r.name) > 0 && len(r.self_test_suite) > 0)
		hashes[i] = c_world_recipe_hash(r)
		for j in 0 ..< i {
			testing.expect(t, hashes[i] != hashes[j])
		}
	}
	// Stage 1 == Stage 2 fixed point check.
	a := [4]u8{0x7F, 'E', 'L', 'F'}
	b := [4]u8{0x7F, 'E', 'L', 'F'}
	c := [4]u8{0x7F, 'E', 'L', 'X'}
	testing.expect(t, chibicc_stages_fixed_point(a[:], b[:]))
	testing.expect(t, !chibicc_stages_fixed_point(a[:], c[:]))
	testing.expect(t, !chibicc_stages_fixed_point(nil, nil))
}
