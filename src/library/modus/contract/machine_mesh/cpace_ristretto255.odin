// Pure freestanding RFC 9496 Ristretto255 prime-order group over Curve25519.
//
// Ristretto255 constructs a prime-order group of order l = 2^252 +
// 27742317777372353535851937790883648493 on top of the twisted Edwards curve
// -x^2 + y^2 = 1 + d * x^2 * y^2 over F_p (p = 2^255 - 19), eliminating
// cofactor and small-order subgroup vulnerabilities by construction.
//
// All field arithmetic, scalar reduction, and scalar multiplication run in
// constant time with zero allocations and explicit erasure of secret copies.
package machine_mesh

import "modus:contract/byte_order"

// Fixed encoded sizes for Ristretto255 group elements and scalars.
RISTRETTO255_ELEMENT_SIZE :: 32
RISTRETTO255_SCALAR_SIZE :: 32
RISTRETTO255_UNIFORM_BYTES_SIZE :: 64

// Field element modulo p = 2^255 - 19 in 5 radix-2^51 limbs.
@(private)
Field_Element :: [5]u64

@(private = "file")
LIMB_MASK :: u64((1 << 51) - 1)

// Group element represented in extended twisted Edwards coordinates (X, Y, Z, T)
// satisfying x = X/Z, y = Y/Z, x*y = T/Z.
Ristretto_Point :: struct {
	x: Field_Element,
	y: Field_Element,
	z: Field_Element,
	t: Field_Element,
}

// Field constants from RFC 9496 Section 4.1 in radix-2^51 representation.
@(private = "file", rodata)
FE_ZERO := Field_Element{0, 0, 0, 0, 0}

@(private = "file", rodata)
FE_ONE := Field_Element{1, 0, 0, 0, 0}

@(private = "file", rodata)
FE_D := Field_Element{929955233495203, 466365720129213, 1662059464998953, 2033849074728123, 1442794654840575}

@(private = "file", rodata)
FE_TWO_D := Field_Element{1859910466990425, 932731440258426, 1072319116312658, 1815898335770999, 633789495995903}

@(private = "file", rodata)
FE_SQRT_M1 := Field_Element{1718705420411056, 234908883556509, 2233514472574048, 2117202627021982, 765476049583133}

@(private = "file", rodata)
FE_INVSQRT_A_MINUS_D := Field_Element{278908739862762, 821645201101625, 8113234426968, 1777959178193151, 2118520810568447}

@(private = "file", rodata)
FE_ONE_MINUS_D_SQ := Field_Element{1136626929484150, 1998550399581263, 496427632559748, 118527312129759, 45110755273534}

@(private = "file", rodata)
FE_D_MINUS_ONE_SQ := Field_Element{1507062230895904, 1572317787530805, 683053064812840, 317374165784489, 1572899562415810}

@(private = "file", rodata)
FE_SQRT_AD_MINUS_ONE := Field_Element{2241493124984347, 425987919032274, 2207028919301688, 1220490630685848, 974799131293748}

// Prime group order l = 2^252 + 27742317777372353535851937790883648493
// in four little-endian 64-bit limbs.
@(private = "file", rodata)
GROUP_ORDER_L := [4]u64{0x5812631a5cf5d3ed, 0x14def9dea2f79cd6, 0x0000000000000000, 0x1000000000000000}

@(private = "file")
fe_carry :: proc "contextless" (a: Field_Element) -> Field_Element {
	out := a
	c0 := out[0] >> 51
	out[0] &= LIMB_MASK
	out[1] += c0

	c1 := out[1] >> 51
	out[1] &= LIMB_MASK
	out[2] += c1

	c2 := out[2] >> 51
	out[2] &= LIMB_MASK
	out[3] += c2

	c3 := out[3] >> 51
	out[3] &= LIMB_MASK
	out[4] += c3

	c4 := out[4] >> 51
	out[4] &= LIMB_MASK
	out[0] += c4 * 19

	c0_second := out[0] >> 51
	out[0] &= LIMB_MASK
	out[1] += c0_second
	return out
}

@(private = "file")
fe_add :: proc "contextless" (a, b: Field_Element) -> Field_Element {
	return fe_carry(Field_Element{a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3], a[4] + b[4]})
}

@(private = "file")
fe_sub :: proc "contextless" (a, b: Field_Element) -> Field_Element {
	// Add 2*p before subtracting so every limb stays strictly non-negative
	// for any reduced input limbs < 2^52.
	p2_0 :: u64(0xFFFFFFFFFFFDA) // 2 * (2^51 - 19)
	p2_other :: u64(0xFFFFFFFFFFFFE) // 2 * (2^51 - 1)
	return fe_carry(Field_Element {
		(a[0] + p2_0) - b[0],
		(a[1] + p2_other) - b[1],
		(a[2] + p2_other) - b[2],
		(a[3] + p2_other) - b[3],
		(a[4] + p2_other) - b[4],
	})
}

@(private = "file")
fe_neg :: proc "contextless" (a: Field_Element) -> Field_Element {
	return fe_sub(FE_ZERO, a)
}

@(private = "file")
fe_mul :: proc "contextless" (a, b: Field_Element) -> Field_Element {
	a0, a1, a2, a3, a4 := u128(a[0]), u128(a[1]), u128(a[2]), u128(a[3]), u128(a[4])
	b0, b1, b2, b3, b4 := u128(b[0]), u128(b[1]), u128(b[2]), u128(b[3]), u128(b[4])

	b1_19 := b1 * 19
	b2_19 := b2 * 19
	b3_19 := b3 * 19
	b4_19 := b4 * 19

	t0 := a0 * b0 + a1 * b4_19 + a2 * b3_19 + a3 * b2_19 + a4 * b1_19
	t1 := a0 * b1 + a1 * b0 + a2 * b4_19 + a3 * b3_19 + a4 * b2_19
	t2 := a0 * b2 + a1 * b1 + a2 * b0 + a3 * b4_19 + a4 * b3_19
	t3 := a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0 + a4 * b4_19
	t4 := a0 * b4 + a1 * b3 + a2 * b2 + a3 * b1 + a4 * b0

	mask := u128(LIMB_MASK)
	c := t0 >> 51
	r0 := u64(t0 & mask)
	t1 += c

	c = t1 >> 51
	r1 := u64(t1 & mask)
	t2 += c

	c = t2 >> 51
	r2 := u64(t2 & mask)
	t3 += c

	c = t3 >> 51
	r3 := u64(t3 & mask)
	t4 += c

	c = t4 >> 51
	r4 := u64(t4 & mask)

	r0_wide := u128(r0) + c * 19
	c = r0_wide >> 51
	r0 = u64(r0_wide & mask)
	r1 += u64(c)

	return Field_Element{r0, r1, r2, r3, r4}
}

@(private = "file")
fe_square :: proc "contextless" (a: Field_Element) -> Field_Element {
	return fe_mul(a, a)
}

@(private = "file")
fe_pow2k :: proc "contextless" (a: Field_Element, count: int) -> Field_Element {
	out := a
	for _ in 0 ..< count {
		out = fe_square(out)
	}
	return out
}

@(private = "file")
fe_cond_select :: proc "contextless" (when_false, when_true: Field_Element, choose_true: u64) -> Field_Element {
	mask := 0 - (choose_true & 1)
	return Field_Element {
		(when_false[0] & ~mask) | (when_true[0] & mask),
		(when_false[1] & ~mask) | (when_true[1] & mask),
		(when_false[2] & ~mask) | (when_true[2] & mask),
		(when_false[3] & ~mask) | (when_true[3] & mask),
		(when_false[4] & ~mask) | (when_true[4] & mask),
	}
}

@(private = "file")
fe_to_bytes :: proc "contextless" (a: Field_Element) -> (output: [32]u8) {
	t := fe_carry(a)

	// Subtract p = 2^255 - 19 in constant time; keep the subtracted value if
	// t >= p (indicated by carry out of limb 4).
	q := (t[0] + 19) >> 51
	q = (t[1] + q) >> 51
	q = (t[2] + q) >> 51
	q = (t[3] + q) >> 51
	q = (t[4] + q) >> 51

	t[0] += 19 * q
	t[1] += t[0] >> 51
	t[0] &= LIMB_MASK
	t[2] += t[1] >> 51
	t[1] &= LIMB_MASK
	t[3] += t[2] >> 51
	t[2] &= LIMB_MASK
	t[4] += t[3] >> 51
	t[3] &= LIMB_MASK
	t[4] &= LIMB_MASK

	w0 := t[0] | (t[1] << 51)
	w1 := (t[1] >> 13) | (t[2] << 38)
	w2 := (t[2] >> 26) | (t[3] << 25)
	w3 := (t[3] >> 39) | (t[4] << 12)
	byte_order.write_u64_little_endian(output[:], 0, w0)
	byte_order.write_u64_little_endian(output[:], 8, w1)
	byte_order.write_u64_little_endian(output[:], 16, w2)
	byte_order.write_u64_little_endian(output[:], 24, w3)
	return output
}

// fe_from_bytes_masked decodes 32 little-endian bytes ignoring bit 255.
@(private = "file")
fe_from_bytes_masked :: proc "contextless" (input: [32]u8) -> Field_Element {
	copy_in := input
	w0 := byte_order.read_u64_little_endian(copy_in[:], 0)
	w1 := byte_order.read_u64_little_endian(copy_in[:], 8)
	w2 := byte_order.read_u64_little_endian(copy_in[:], 16)
	w3 := byte_order.read_u64_little_endian(copy_in[:], 24)

	t0 := w0 & LIMB_MASK
	t1 := ((w0 >> 51) | (w1 << 13)) & LIMB_MASK
	t2 := ((w1 >> 38) | (w2 << 26)) & LIMB_MASK
	t3 := ((w2 >> 25) | (w3 << 39)) & LIMB_MASK
	t4 := (w3 >> 12) & LIMB_MASK
	return fe_carry(Field_Element{t0, t1, t2, t3, t4})
}

// fe_from_bytes_canonical decodes 32 little-endian bytes and verifies that the
// input is strictly less than p and has bit 255 cleared.
@(private = "file")
fe_from_bytes_canonical :: proc "contextless" (input: [32]u8) -> (element: Field_Element, ok: bool) {
	element = fe_from_bytes_masked(input)
	reencoded := fe_to_bytes(element)
	if !keys_equal_constant_time(reencoded, input) {
		return FE_ZERO, false
	}
	return element, true
}

@(private = "file")
fe_is_negative :: proc "contextless" (a: Field_Element) -> u64 {
	encoded := fe_to_bytes(a)
	return u64(encoded[0] & 1)
}

@(private = "file")
fe_is_zero :: proc "contextless" (a: Field_Element) -> u64 {
	encoded := fe_to_bytes(a)
	acc: u8 = 0
	for value in encoded {
		acc |= value
	}
	// acc == 0 -> 1, acc != 0 -> 0.
	non_zero := u64((u32(acc) | u32(-i32(acc))) >> 31)
	return 1 ~ non_zero
}

@(private = "file")
fe_equal :: proc "contextless" (a, b: Field_Element) -> u64 {
	ab := fe_to_bytes(a)
	bb := fe_to_bytes(b)
	diff: u8 = 0
	for index in 0 ..< 32 {
		diff |= ab[index] ~ bb[index]
	}
	non_zero := u64((u32(diff) | u32(-i32(diff))) >> 31)
	return 1 ~ non_zero
}

@(private = "file")
fe_cond_negate :: proc "contextless" (a: Field_Element, negate: u64) -> Field_Element {
	return fe_cond_select(a, fe_neg(a), negate)
}

@(private = "file")
fe_abs :: proc "contextless" (a: Field_Element) -> Field_Element {
	return fe_cond_negate(a, fe_is_negative(a))
}

// fe_pow_p_minus_5_div_8 computes x^((p - 5) / 8) mod p = x^(2^252 - 3).
@(private = "file")
fe_pow_p_minus_5_div_8 :: proc "contextless" (x: Field_Element) -> Field_Element {
	x2 := fe_square(x)
	x3 := fe_mul(x2, x) // 2^2 - 1
	x6 := fe_pow2k(x3, 1) // 2^3 - 2
	x7 := fe_mul(x6, x) // 2^3 - 1
	t0 := fe_pow2k(x7, 3)
	x_2_6_m1 := fe_mul(t0, x7) // 2^6 - 1
	t1 := fe_pow2k(x_2_6_m1, 6)
	x_2_12_m1 := fe_mul(t1, x_2_6_m1) // 2^12 - 1
	t2 := fe_pow2k(x_2_12_m1, 12)
	x_2_24_m1 := fe_mul(t2, x_2_12_m1) // 2^24 - 1
	t3 := fe_pow2k(x_2_24_m1, 1)
	x_2_25_m1 := fe_mul(t3, x) // 2^25 - 1
	t4 := fe_pow2k(x_2_25_m1, 25)
	x_2_50_m1 := fe_mul(t4, x_2_25_m1) // 2^50 - 1
	t5 := fe_pow2k(x_2_50_m1, 50)
	x_2_100_m1 := fe_mul(t5, x_2_50_m1) // 2^100 - 1
	t6 := fe_pow2k(x_2_100_m1, 100)
	x_2_200_m1 := fe_mul(t6, x_2_100_m1) // 2^200 - 1
	t7 := fe_pow2k(x_2_200_m1, 50)
	x_2_250_m1 := fe_mul(t7, x_2_50_m1) // 2^250 - 1
	t8 := fe_pow2k(x_2_250_m1, 2) // 2^252 - 4
	return fe_mul(t8, x) // 2^252 - 3
}

// fe_sqrt_ratio_m1 implements RFC 9496 Section 4.2 SQRT_RATIO_M1(u, v).
@(private = "file")
fe_sqrt_ratio_m1 :: proc "contextless" (u, v: Field_Element) -> (was_square: u64, r: Field_Element) {
	v2 := fe_square(v)
	v3 := fe_mul(v2, v)
	v6 := fe_square(v3)
	v7 := fe_mul(v6, v)

	uv3 := fe_mul(u, v3)
	uv7 := fe_mul(u, v7)
	r = fe_mul(uv3, fe_pow_p_minus_5_div_8(uv7))

	check := fe_mul(v, fe_square(r))
	neg_u := fe_neg(u)
	neg_u_i := fe_mul(neg_u, FE_SQRT_M1)

	correct_sign_sqrt := fe_equal(check, u)
	flipped_sign_sqrt := fe_equal(check, neg_u)
	flipped_sign_sqrt_i := fe_equal(check, neg_u_i)

	r_prime := fe_mul(FE_SQRT_M1, r)
	r = fe_cond_select(r, r_prime, flipped_sign_sqrt | flipped_sign_sqrt_i)
	r = fe_abs(r)
	was_square = correct_sign_sqrt | flipped_sign_sqrt
	return was_square, r
}

// ristretto255_identity returns the canonical identity element of Ristretto255.
ristretto255_identity :: proc "contextless" () -> Ristretto_Point {
	return Ristretto_Point{x = FE_ZERO, y = FE_ONE, z = FE_ONE, t = FE_ZERO}
}

// ristretto255_point_clear erases a Ristretto_Point in place.
ristretto255_point_clear :: proc "contextless" (point: ^Ristretto_Point) {
	clear_bytes_explicitly(([^]u8)(point)[:size_of(Ristretto_Point)])
}

// ristretto255_point_cond_select selects point_true when choose_true == 1 and
// point_false when choose_true == 0, in constant time.
@(private = "file")
ristretto255_point_cond_select :: proc "contextless" (
	point_false, point_true: Ristretto_Point,
	choose_true: u64,
) -> Ristretto_Point {
	return Ristretto_Point {
		x = fe_cond_select(point_false.x, point_true.x, choose_true),
		y = fe_cond_select(point_false.y, point_true.y, choose_true),
		z = fe_cond_select(point_false.z, point_true.z, choose_true),
		t = fe_cond_select(point_false.t, point_true.t, choose_true),
	}
}

// ristretto255_add adds two extended twisted Edwards points using the complete
// unified addition law for a = -1 (valid for all points including doubling and
// identity).
ristretto255_add :: proc "contextless" (p, q: Ristretto_Point) -> Ristretto_Point {
	a := fe_mul(fe_sub(p.y, p.x), fe_sub(q.y, q.x))
	b := fe_mul(fe_add(p.y, p.x), fe_add(q.y, q.x))
	c := fe_mul(fe_mul(p.t, FE_TWO_D), q.t)
	d := fe_mul(fe_add(p.z, p.z), q.z)
	e := fe_sub(b, a)
	f := fe_sub(d, c)
	g := fe_add(d, c)
	h := fe_add(b, a)
	return Ristretto_Point {
		x = fe_mul(e, f),
		y = fe_mul(g, h),
		z = fe_mul(f, g),
		t = fe_mul(e, h),
	}
}

// ristretto255_double doubles a twisted Edwards point in extended coordinates.
ristretto255_double :: proc "contextless" (p: Ristretto_Point) -> Ristretto_Point {
	a := fe_square(p.x)
	b := fe_square(p.y)
	z2 := fe_square(p.z)
	c := fe_add(z2, z2)
	h := fe_add(a, b)
	xy := fe_add(p.x, p.y)
	e := fe_sub(h, fe_square(xy))
	g := fe_sub(a, b)
	f := fe_add(c, g)
	return Ristretto_Point {
		x = fe_mul(e, f),
		y = fe_mul(g, h),
		z = fe_mul(f, g),
		t = fe_mul(e, h),
	}
}

// ristretto255_equal checks Ristretto255 equivalence of two group elements in
// constant time (RFC 9496 Section 4.3.3).
ristretto255_equal :: proc "contextless" (p, q: Ristretto_Point) -> bool {
	xy_eq := fe_equal(fe_mul(p.x, q.y), fe_mul(p.y, q.x))
	yx_eq := fe_equal(fe_mul(p.y, q.y), fe_mul(p.x, q.x))
	return (xy_eq | yx_eq) == 1
}

// ristretto255_is_identity reports whether point represents the Ristretto255
// identity element.
ristretto255_is_identity :: proc "contextless" (point: Ristretto_Point) -> bool {
	return ristretto255_equal(point, ristretto255_identity())
}

// ristretto255_encode encodes a Ristretto255 group element into its unique
// canonical 32-byte representation (RFC 9496 Section 4.3.2).
ristretto255_encode :: proc "contextless" (point: Ristretto_Point) -> [RISTRETTO255_ELEMENT_SIZE]u8 {
	u1 := fe_mul(fe_add(point.z, point.y), fe_sub(point.z, point.y))
	u2 := fe_mul(point.x, point.y)
	_, invsqrt := fe_sqrt_ratio_m1(FE_ONE, fe_mul(u1, fe_square(u2)))
	den1 := fe_mul(invsqrt, u1)
	den2 := fe_mul(invsqrt, u2)
	z_inv := fe_mul(fe_mul(den1, den2), point.t)

	ix := fe_mul(point.x, FE_SQRT_M1)
	iy := fe_mul(point.y, FE_SQRT_M1)
	enchanted_denominator := fe_mul(den1, FE_INVSQRT_A_MINUS_D)

	rotate := fe_is_negative(fe_mul(point.t, z_inv))
	x := fe_cond_select(point.x, iy, rotate)
	y := fe_cond_select(point.y, ix, rotate)
	den_inv := fe_cond_select(den2, enchanted_denominator, rotate)

	y = fe_cond_negate(y, fe_is_negative(fe_mul(x, z_inv)))
	s := fe_abs(fe_mul(den_inv, fe_sub(point.z, y)))
	return fe_to_bytes(s)
}

// ristretto255_decode strictly decodes 32 bytes into a Ristretto255 group
// element (RFC 9496 Section 4.3.1). Non-canonical or invalid encodings are
// refused and return the identity element with ok = false.
ristretto255_decode :: proc "contextless" (input: [RISTRETTO255_ELEMENT_SIZE]u8) -> (point: Ristretto_Point, ok: bool) {
	s, canonical := fe_from_bytes_canonical(input)
	if !canonical {
		return ristretto255_identity(), false
	}
	if fe_is_negative(s) == 1 {
		return ristretto255_identity(), false
	}

	ss := fe_square(s)
	u1 := fe_sub(FE_ONE, ss)
	u2 := fe_add(FE_ONE, ss)
	u2_sqr := fe_square(u2)
	v := fe_sub(fe_neg(fe_mul(FE_D, fe_square(u1))), u2_sqr)

	was_square, invsqrt := fe_sqrt_ratio_m1(FE_ONE, fe_mul(v, u2_sqr))
	den_x := fe_mul(invsqrt, u2)
	den_y := fe_mul(fe_mul(invsqrt, den_x), v)

	x := fe_abs(fe_mul(fe_add(s, s), den_x))
	y := fe_mul(u1, den_y)
	t := fe_mul(x, y)

	if was_square == 0 || fe_is_negative(t) == 1 || fe_is_zero(y) == 1 {
		return ristretto255_identity(), false
	}
	return Ristretto_Point{x = x, y = y, z = FE_ONE, t = t}, true
}

// map_elligator_ristretto255 implements MAP(t) from RFC 9496 Section 4.3.4.
@(private = "file")
map_elligator_ristretto255 :: proc "contextless" (input: [32]u8) -> Ristretto_Point {
	r0 := fe_from_bytes_masked(input)
	r := fe_mul(FE_SQRT_M1, fe_square(r0))
	n_s := fe_mul(fe_add(r, FE_ONE), FE_ONE_MINUS_D_SQ)
	c := fe_neg(FE_ONE)
	d_val := fe_mul(fe_sub(c, fe_mul(FE_D, r)), fe_add(r, FE_D))

	was_square, s := fe_sqrt_ratio_m1(n_s, d_val)
	s_prime := fe_neg(fe_abs(fe_mul(s, r0)))
	s = fe_cond_select(s_prime, s, was_square)
	c = fe_cond_select(r, c, was_square)

	n_t := fe_sub(fe_mul(fe_mul(c, fe_sub(r, FE_ONE)), FE_D_MINUS_ONE_SQ), d_val)

	w0 := fe_mul(fe_add(s, s), d_val)
	w1 := fe_mul(n_t, FE_SQRT_AD_MINUS_ONE)
	s_sq := fe_square(s)
	w2 := fe_sub(FE_ONE, s_sq)
	w3 := fe_add(FE_ONE, s_sq)

	return Ristretto_Point {
		x = fe_mul(w0, w3),
		y = fe_mul(w2, w1),
		z = fe_mul(w1, w3),
		t = fe_mul(w0, w2),
	}
}

// ristretto255_from_uniform_bytes maps 64 uniform bytes (such as a SHA-512
// digest) to a Ristretto255 group element (RFC 9496 Section 4.3.4).
ristretto255_from_uniform_bytes :: proc "contextless" (bytes: [RISTRETTO255_UNIFORM_BYTES_SIZE]u8) -> Ristretto_Point {
	bytes_copy := bytes
	first, second: [32]u8
	copy(first[:], bytes_copy[0:32])
	copy(second[:], bytes_copy[32:64])
	p0 := map_elligator_ristretto255(first)
	p1 := map_elligator_ristretto255(second)
	clear_bytes_explicitly(bytes_copy[:])
	clear_bytes_explicitly(first[:])
	clear_bytes_explicitly(second[:])
	return ristretto255_add(p0, p1)
}

// scalar_reduce_bytes_mod_l reduces an arbitrary little-endian byte slice
// modulo the prime group order l in constant time.
@(private = "file")
scalar_reduce_bytes_mod_l :: proc "contextless" (input: []u8) -> (reduced: [RISTRETTO255_SCALAR_SIZE]u8) {
	acc: [4]u64
	order := GROUP_ORDER_L
	total_bits := len(input) * 8
	for bit_index := total_bits - 1; bit_index >= 0; bit_index -= 1 {
		byte_index := bit_index >> 3
		bit_offset := uint(bit_index & 7)
		in_bit := u64((input[byte_index] >> bit_offset) & 1)

		// acc = (acc << 1) | in_bit; acc < l < 2^253 so no 256-bit overflow occurs.
		acc[3] = (acc[3] << 1) | (acc[2] >> 63)
		acc[2] = (acc[2] << 1) | (acc[1] >> 63)
		acc[1] = (acc[1] << 1) | (acc[0] >> 63)
		acc[0] = (acc[0] << 1) | in_bit

		// Compute diff = acc - l with borrow propagation.
		diff: [4]u64
		borrow: u64 = 0
		for limb in 0 ..< 4 {
			a := acc[limb]
			b := order[limb]
			sub1 := a - b
			b1: u64 = a < b ? 1 : 0
			sub2 := sub1 - borrow
			b2: u64 = sub1 < borrow ? 1 : 0
			diff[limb] = sub2
			borrow = b1 | b2
		}

		// Keep diff when borrow == 0 (acc >= l), otherwise keep acc.
		keep_diff := 0 - (1 ~ borrow)
		for limb in 0 ..< 4 {
			acc[limb] = (acc[limb] & ~keep_diff) | (diff[limb] & keep_diff)
		}
	}
	for limb in 0 ..< 4 {
		byte_order.write_u64_little_endian(reduced[:], limb * 8, acc[limb])
	}
	clear_bytes_explicitly(([^]u8)(&acc[0])[:size_of(acc)])
	return reduced
}

// ristretto255_scalar_reduce_32 reduces 32 little-endian bytes modulo l.
ristretto255_scalar_reduce_32 :: proc "contextless" (input: [32]u8) -> [RISTRETTO255_SCALAR_SIZE]u8 {
	copy_in := input
	defer clear_bytes_explicitly(copy_in[:])
	return scalar_reduce_bytes_mod_l(copy_in[:])
}

// ristretto255_scalar_reduce_64 reduces 64 little-endian bytes modulo l.
ristretto255_scalar_reduce_64 :: proc "contextless" (input: [64]u8) -> [RISTRETTO255_SCALAR_SIZE]u8 {
	copy_in := input
	defer clear_bytes_explicitly(copy_in[:])
	return scalar_reduce_bytes_mod_l(copy_in[:])
}

// ristretto255_scalar_is_zero returns true when scalar is 0 mod l.
ristretto255_scalar_is_zero :: proc "contextless" (scalar: [RISTRETTO255_SCALAR_SIZE]u8) -> bool {
	reduced := ristretto255_scalar_reduce_32(scalar)
	defer clear_bytes_explicitly(reduced[:])
	return bytes_all_zero(reduced[:])
}

// ristretto255_scalar_mul computes scalar * point in constant time using a
// 4-bit fixed window table over all 64 nibbles of the canonical reduced scalar.
ristretto255_scalar_mul :: proc "contextless" (
	scalar: [RISTRETTO255_SCALAR_SIZE]u8,
	point: Ristretto_Point,
) -> Ristretto_Point {
	reduced := ristretto255_scalar_reduce_32(scalar)
	defer clear_bytes_explicitly(reduced[:])

	table: [16]Ristretto_Point
	defer clear_bytes_explicitly(([^]u8)(&table[0])[:size_of(table)])
	table[0] = ristretto255_identity()
	table[1] = point
	for index in 2 ..< 16 {
		table[index] = ristretto255_add(table[index - 1], point)
	}

	result := ristretto255_identity()
	// Process 64 nibbles from MSB (byte 31 high nibble) to LSB (byte 0 low nibble).
	for byte_index := 31; byte_index >= 0; byte_index -= 1 {
		for shift := uint(4); ; shift -= 4 {
			result = ristretto255_double(result)
			result = ristretto255_double(result)
			result = ristretto255_double(result)
			result = ristretto255_double(result)

			nibble := u64((reduced[byte_index] >> shift) & 0x0F)
			chosen := table[0]
			for entry_index in 1 ..< 16 {
				diff := nibble ~ u64(entry_index)
				is_equal := 1 ~ ((diff | (0 - diff)) >> 63)
				chosen = ristretto255_point_cond_select(chosen, table[entry_index], is_equal)
			}
			result = ristretto255_add(result, chosen)
			if shift == 0 {
				break
			}
		}
	}
	return result
}
