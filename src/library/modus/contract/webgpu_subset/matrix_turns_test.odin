#+build !freestanding
#+build !modus
package webgpu_subset

import "core:testing"

@(test)
matrix_turns_trigonometry_and_rotations :: proc(t: ^testing.T) {
	// Exact quarter-turn values.
	testing.expect(t, abs(cosine_turns(0.0) - 1.0) < 1e-12)
	testing.expect(t, abs(sine_turns(0.0) - 0.0) < 1e-12)
	testing.expect(t, abs(cosine_turns(0.25) - 0.0) < 1e-12)
	testing.expect(t, abs(sine_turns(0.25) - 1.0) < 1e-12)
	testing.expect(t, abs(cosine_turns(0.5) - (-1.0)) < 1e-12)
	testing.expect(t, abs(sine_turns(0.5) - 0.0) < 1e-12)
	testing.expect(t, abs(cosine_turns(0.75) - 0.0) < 1e-12)
	testing.expect(t, abs(sine_turns(0.75) - (-1.0)) < 1e-12)

	// Quarter-turn rotations around X, Y, Z axes.
	px := matrix_4x4_transform_vec4(matrix_4x4_rotate_x(0.25), {0, 1, 0, 1})
	testing.expect(t, abs(px[0]) < 1e-6 && abs(px[1]) < 1e-6 && abs(px[2] - 1.0) < 1e-6)

	py := matrix_4x4_transform_vec4(matrix_4x4_rotate_y(0.25), {0, 0, 1, 1})
	testing.expect(t, abs(py[0] - 1.0) < 1e-6 && abs(py[1]) < 1e-6 && abs(py[2]) < 1e-6)

	pz := matrix_4x4_transform_vec4(matrix_4x4_rotate_z(0.25), {1, 0, 0, 1})
	testing.expect(t, abs(pz[0]) < 1e-6 && abs(pz[1] - 1.0) < 1e-6 && abs(pz[2]) < 1e-6)
}

@(test)
matrix_turns_perspective_and_look_at_refusals_and_ndc_bounds :: proc(t: ^testing.T) {
	nan_f64 := transmute(f64)u64(0x7FF8_0000_0000_0000)
	nan_f32 := transmute(f32)u32(0x7FC0_0000)
	inf_f32 := transmute(f32)u32(0x7F80_0000)

	// Perspective refusals.
	for bad_fov in ([]f64{0.0, -0.1, 0.5, 1.0, nan_f64}) {
		_, ok := matrix_4x4_perspective_turns(bad_fov, 1.0, 0.1, 100.0)
		testing.expect(t, !ok)
	}
	_, ok := matrix_4x4_perspective_turns(0.25, 0.0, 0.1, 100.0)
	testing.expect(t, !ok)
	_, ok = matrix_4x4_perspective_turns(0.25, 1.0, 0.0, 100.0)
	testing.expect(t, !ok)
	_, ok = matrix_4x4_perspective_turns(0.25, 1.0, 10.0, 10.0)
	testing.expect(t, !ok)
	_, ok = matrix_4x4_perspective_turns(0.25, nan_f32, 0.1, 100.0)
	testing.expect(t, !ok)
	_, ok = matrix_4x4_perspective_turns(0.25, 1.0, 0.1, inf_f32)
	testing.expect(t, !ok)

	// Valid 0.25-turn perspective maps -near -> ndc_z 0 and -far -> ndc_z 1.
	proj, proj_ok := matrix_4x4_perspective_turns(0.25, 16.0 / 9.0, 1.0, 10.0)
	testing.expect(t, proj_ok && matrix_4x4_is_finite(proj))
	near_c := matrix_4x4_transform_vec4(proj, {0, 0, -1.0, 1.0})
	far_c := matrix_4x4_transform_vec4(proj, {0, 0, -10.0, 1.0})
	testing.expect(t, abs(near_c[2] / near_c[3] - 0.0) < 1e-5)
	testing.expect(t, abs(far_c[2] / far_c[3] - 1.0) < 1e-5)

	// Look-at refusals: coincident eye/target, collinear up, non-finite.
	_, ok = matrix_4x4_look_at({0, 0, 5}, {0, 0, 5}, {0, 1, 0})
	testing.expect(t, !ok)
	_, ok = matrix_4x4_look_at({0, 0, 0}, {0, 1, 0}, {0, 1, 0})
	testing.expect(t, !ok)
	_, ok = matrix_4x4_look_at({nan_f32, 0, 0}, {0, 0, -1}, {0, 1, 0})
	testing.expect(t, !ok)

	// Valid look-at from (0, 0, 5) toward origin maps origin to (0, 0, -5) in view space.
	view, view_ok := matrix_4x4_look_at({0, 0, 5}, {0, 0, 0}, {0, 1, 0})
	testing.expect(t, view_ok && matrix_4x4_is_finite(view))
	origin_view := matrix_4x4_transform_vec4(view, {0, 0, 0, 1})
	testing.expect(t, abs(origin_view[0]) < 1e-5 && abs(origin_view[1]) < 1e-5 && abs(origin_view[2] - (-5.0)) < 1e-5)
}
