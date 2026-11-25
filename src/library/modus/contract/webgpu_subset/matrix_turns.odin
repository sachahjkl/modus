// Turns-based 3D rotation, perspective, and camera transform helpers extending
// webgpu_subset.Matrix_4x4 (src/md/features/gpu_access.md and
// src/md/data/angles_in_turns.md).
//
// All angles are in turns (1.0 is a full circle, 0.25 is a right angle).
// Turns trigonometry stays local here because contract packages do not import
// support packages such as modus:trigonometry.
package webgpu_subset

// Format property: from 2^52 on, each f64 is a whole number of turns.
@(private = "file")
TURNS_WHOLE_FROM :: 4503599627370496.0

// Format property: 9-term Taylor coefficients in turns on [-1/8, 1/8],
// identical to src/library/modus/trigonometry/trigonometry.odin.
@(private = "file")
TURNS_COS_0 :: 1.0
@(private = "file")
TURNS_COS_1 :: -19.739208802178716
@(private = "file")
TURNS_COS_2 :: 64.9393940226683
@(private = "file")
TURNS_COS_3 :: -85.45681720669373
@(private = "file")
TURNS_COS_4 :: 60.24464137187666
@(private = "file")
TURNS_COS_5 :: -26.4262567833744
@(private = "file")
TURNS_COS_6 :: 7.903536371318469
@(private = "file")
TURNS_COS_7 :: -1.714390711088672
@(private = "file")
TURNS_COS_8 :: 0.28200596845579123

@(private = "file")
TURNS_SIN_0 :: 6.283185307179586
@(private = "file")
TURNS_SIN_1 :: -41.34170224039976
@(private = "file")
TURNS_SIN_2 :: 81.60524927607506
@(private = "file")
TURNS_SIN_3 :: -76.70585975306139
@(private = "file")
TURNS_SIN_4 :: 42.058693944897655
@(private = "file")
TURNS_SIN_5 :: -15.09464257682299
@(private = "file")
TURNS_SIN_6 :: 3.819952584848282
@(private = "file")
TURNS_SIN_7 :: -0.7181223017785006
@(private = "file")
TURNS_SIN_8 :: 0.10422916220813984

@(private = "file")
turns_finite_f32 :: #force_inline proc "contextless" (v: f32) -> bool {
	return (transmute(u32)v & 0x7F80_0000) != 0x7F80_0000
}

@(private = "file")
turns_finite_f64 :: #force_inline proc "contextless" (v: f64) -> bool {
	return (transmute(u64)v & 0x7FF0_0000_0000_0000) != 0x7FF0_0000_0000_0000
}

@(private = "file")
turns_fraction :: proc "contextless" (angle_turns: f64) -> f64 {
	if !(abs(angle_turns) < TURNS_WHOLE_FROM) {
		return angle_turns - angle_turns
	}
	fraction := angle_turns - f64(i64(angle_turns))
	if fraction < 0 {
		fraction += 1
	}
	return fraction
}

@(private = "file")
turns_quarter_and_rest :: proc "contextless" (angle_turns: f64) -> (quarter: i64, rest_turns: f64) {
	quarters := turns_fraction(angle_turns) * 4
	if quarters != quarters {
		return 0, quarters
	}
	nearest := i64(quarters + 0.5)
	return nearest & 3, (quarters - f64(nearest)) * 0.25
}

@(private = "file")
turns_cos_near_zero :: proc "contextless" (rest_turns: f64) -> f64 {
	sq := rest_turns * rest_turns
	return TURNS_COS_0 + sq * (TURNS_COS_1 + sq * (TURNS_COS_2 + sq * (TURNS_COS_3 + sq * (TURNS_COS_4 + sq * (TURNS_COS_5 + sq * (TURNS_COS_6 + sq * (TURNS_COS_7 + sq * TURNS_COS_8)))))))
}

@(private = "file")
turns_sin_near_zero :: proc "contextless" (rest_turns: f64) -> f64 {
	sq := rest_turns * rest_turns
	return rest_turns * (TURNS_SIN_0 + sq * (TURNS_SIN_1 + sq * (TURNS_SIN_2 + sq * (TURNS_SIN_3 + sq * (TURNS_SIN_4 + sq * (TURNS_SIN_5 + sq * (TURNS_SIN_6 + sq * (TURNS_SIN_7 + sq * TURNS_SIN_8))))))))
}

// cosine_turns returns the cosine of angle_turns with exact quarter-turn outputs.
cosine_turns :: proc "contextless" (angle_turns: f64) -> f64 {
	quarter, rest_turns := turns_quarter_and_rest(angle_turns)
	switch quarter {
	case 0:
		return turns_cos_near_zero(rest_turns)
	case 1:
		return 0 - turns_sin_near_zero(rest_turns)
	case 2:
		return 0 - turns_cos_near_zero(rest_turns)
	}
	return turns_sin_near_zero(rest_turns)
}

// sine_turns returns the sine of angle_turns with exact quarter-turn outputs.
sine_turns :: proc "contextless" (angle_turns: f64) -> f64 {
	quarter, rest_turns := turns_quarter_and_rest(angle_turns)
	switch quarter {
	case 0:
		return turns_sin_near_zero(rest_turns)
	case 1:
		return turns_cos_near_zero(rest_turns)
	case 2:
		return 0 - turns_sin_near_zero(rest_turns)
	}
	return 0 - turns_cos_near_zero(rest_turns)
}

// matrix_4x4_is_finite reports whether all 16 entries of m are finite f32 values.
matrix_4x4_is_finite :: proc "contextless" (m: Matrix_4x4) -> bool {
	for entry in m {
		if !turns_finite_f32(entry) {
			return false
		}
	}
	return true
}

// matrix_4x4_transform_vec4 multiplies column-major Matrix_4x4 by column vector v.
matrix_4x4_transform_vec4 :: proc "contextless" (m: Matrix_4x4, v: [4]f32) -> [4]f32 {
	return [4]f32 {
		m[0] * v[0] + m[4] * v[1] + m[8] * v[2] + m[12] * v[3],
		m[1] * v[0] + m[5] * v[1] + m[9] * v[2] + m[13] * v[3],
		m[2] * v[0] + m[6] * v[1] + m[10] * v[2] + m[14] * v[3],
		m[3] * v[0] + m[7] * v[1] + m[11] * v[2] + m[15] * v[3],
	}
}

matrix_4x4_rotate_x :: proc "contextless" (angle_turns: f64) -> Matrix_4x4 {
	c := f32(cosine_turns(angle_turns))
	s := f32(sine_turns(angle_turns))
	m := matrix_4x4_identity()
	m[5] = c
	m[6] = s
	m[9] = -s
	m[10] = c
	return m
}

matrix_4x4_rotate_y :: proc "contextless" (angle_turns: f64) -> Matrix_4x4 {
	c := f32(cosine_turns(angle_turns))
	s := f32(sine_turns(angle_turns))
	m := matrix_4x4_identity()
	m[0] = c
	m[2] = -s
	m[8] = s
	m[10] = c
	return m
}

matrix_4x4_rotate_z :: proc "contextless" (angle_turns: f64) -> Matrix_4x4 {
	c := f32(cosine_turns(angle_turns))
	s := f32(sine_turns(angle_turns))
	m := matrix_4x4_identity()
	m[0] = c
	m[1] = s
	m[4] = -s
	m[5] = c
	return m
}

// matrix_4x4_perspective_turns constructs a right-handed WebGPU NDC [0, 1]
// perspective matrix from fov_y_turns in (0, 0.5). Refuses non-finite or out-of-range
// parameters with ok == false.
matrix_4x4_perspective_turns :: proc "contextless" (
	fov_y_turns: f64,
	aspect: f32,
	near: f32,
	far: f32,
) -> (
	m: Matrix_4x4,
	ok: bool,
) {
	if !turns_finite_f64(fov_y_turns) || fov_y_turns <= 0 || fov_y_turns >= 0.5 {
		return {}, false
	}
	if !turns_finite_f32(aspect) || aspect <= 0 || !turns_finite_f32(near) || near <= 0 || !turns_finite_f32(far) || far <= near {
		return {}, false
	}
	half := fov_y_turns * 0.5
	s := sine_turns(half)
	c := cosine_turns(half)
	if !turns_finite_f64(s) || !turns_finite_f64(c) || s <= 0 {
		return {}, false
	}
	cot := f32(c / s)
	if !turns_finite_f32(cot) {
		return {}, false
	}
	result := matrix_4x4_perspective_zero_to_one(cot, aspect, near, far)
	if !matrix_4x4_is_finite(result) {
		return {}, false
	}
	return result, true
}

@(private = "file")
sqrt_f64_positive :: proc "contextless" (x: f64) -> f64 {
	if x <= 0 || !turns_finite_f64(x) {
		return 0
	}
	// Bit-seeded Newton-Raphson reaches full f64 precision in 6 iterations.
	bits := transmute(u64)x
	guess := transmute(f64)((bits >> 1) + (0x3FF0_0000_0000_0000 >> 1))
	for _ in 0 ..< 6 {
		guess = 0.5 * (guess + x / guess)
	}
	return guess
}

@(private = "file")
vec3_finite :: #force_inline proc "contextless" (v: [3]f32) -> bool {
	return turns_finite_f32(v[0]) && turns_finite_f32(v[1]) && turns_finite_f32(v[2])
}

// matrix_4x4_look_at constructs a right-handed view matrix looking from eye
// toward target with up hint. Refuses non-finite inputs, coincident eye/target,
// or collinear up vector.
matrix_4x4_look_at :: proc "contextless" (eye, target, up: [3]f32) -> (m: Matrix_4x4, ok: bool) {
	if !vec3_finite(eye) || !vec3_finite(target) || !vec3_finite(up) {
		return {}, false
	}
	fx := f64(target[0]) - f64(eye[0])
	fy := f64(target[1]) - f64(eye[1])
	fz := f64(target[2]) - f64(eye[2])
	flen := sqrt_f64_positive(fx * fx + fy * fy + fz * fz)
	if flen <= 1e-9 {
		return {}, false
	}
	fx /= flen
	fy /= flen
	fz /= flen

	ux, uy, uz := f64(up[0]), f64(up[1]), f64(up[2])
	sx := fy * uz - fz * uy
	sy := fz * ux - fx * uz
	sz := fx * uy - fy * ux
	slen := sqrt_f64_positive(sx * sx + sy * sy + sz * sz)
	if slen <= 1e-9 {
		return {}, false
	}
	sx /= slen
	sy /= slen
	sz /= slen

	vx := sy * fz - sz * fy
	vy := sz * fx - sx * fz
	vz := sx * fy - sy * fx

	ex, ey, ez := f64(eye[0]), f64(eye[1]), f64(eye[2])
	result := Matrix_4x4 {
		f32(sx), f32(vx), f32(-fx), 0,
		f32(sy), f32(vy), f32(-fy), 0,
		f32(sz), f32(vz), f32(-fz), 0,
		f32(-(sx * ex + sy * ey + sz * ez)),
		f32(-(vx * ex + vy * ey + vz * ez)),
		f32(fx * ex + fy * ey + fz * ez),
		1,
	}
	if !matrix_4x4_is_finite(result) {
		return {}, false
	}
	return result, true
}
