package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import module "modus:contract/module"

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

@(test)
c_world_build_recipe_module_refusals_and_zstd_reference :: proc(t: ^testing.T) {
	// Refusals first: empty work dir and invalid zstd module bytes.
	_, empty_dir_ok := c_world_build_recipe_module(.Zstd, "")
	testing.expect(t, !empty_dir_ok, "empty work directory must be refused")

	_, _, bad_zstd_ok := c_world_zstd_reference_frame(nil)
	testing.expect(t, !bad_zstd_ok, "empty zstd module bytes must be refused")
	garbage := [16]u8{0 = 1, 1 = 2, 2 = 3, 3 = 4}
	_, _, garbage_zstd_ok := c_world_zstd_reference_frame(garbage[:])
	testing.expect(t, !garbage_zstd_ok, "corrupted zstd module bytes must be refused")

	if os.get_env("ZSTD_SOURCE", context.temp_allocator) == "" {
		return
	}
	temp_base, _ := os.temp_dir(context.temp_allocator)
	work := fmt.aprintf("%s/modus_c_world_zstd_test_%d", strings.trim_right(temp_base, "/"), os.get_pid())
	defer delete(work)
	_ = os.remove_all(work)
	defer os.remove_all(work)

	zstd_mod, built := c_world_build_recipe_module(.Zstd, work)
	if !testing.expect(t, built, "zstd recipe builds a freestanding module") {
		return
	}
	defer delete(zstd_mod)
	testing.expect_value(t, module.validate(zstd_mod), module.Error.None)

	size1, hash1, ok1 := c_world_zstd_reference_frame(zstd_mod)
	size2, hash2, ok2 := c_world_zstd_reference_frame(zstd_mod)
	testing.expect(t, ok1 && ok2, "zstd reference frame executes cleanly on host")
	testing.expect(t, size1 > 0 && size1 < C_WORLD_ZSTD_VECTOR_BYTES, "zstd compresses the 16 KiB test vector")
	testing.expect_value(t, size1, size2)
	testing.expect_value(t, hash1, hash2)
	testing.expect(t, hash1 != blake3.Hash{}, "zstd frame hash is non-zero")
}
