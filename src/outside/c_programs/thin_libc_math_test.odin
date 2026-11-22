#+build !freestanding
// The host test of the elementary functions of the thin libc
// (thin_libc/modus_thin_libc_math.c): pow, exp and the logarithms against
// core:math and the C library of the host, at the special cases of Annex F of
// C, at the exact powers, and at random values.
package c_programs

import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:testing"

// The distance in units in the last place between two doubles of one sign;
// two NaNs are at 0, a NaN and a number at the largest distance.
units_in_last_place :: proc(expected: f64, found_bits: u64) -> u64 {
	found := transmute(f64)found_bits
	if expected != expected || found != found {
		return 0 if expected != expected && found != found else max(u64)
	}
	ordered :: proc(bits: u64) -> i64 {
		magnitude := i64(bits & 0x7fffffffffffffff)
		return -magnitude if bits >> 63 != 0 else magnitude
	}
	difference := ordered(transmute(u64)expected) - ordered(found_bits)
	return u64(difference if difference >= 0 else -difference)
}

// A zero, an infinity and a NaN are exact, with their sign: an error of one
// unit there changes the class of the result.
special_result_matches :: proc(expected: f64, found_bits: u64) -> bool {
	if expected != expected {
		return (found_bits >> 52) & 0x7ff == 0x7ff && found_bits & 0xfffffffffffff != 0
	}
	return transmute(u64)expected == found_bits
}

Elementary_Function :: struct {
	operation: Math_Operation,
	reference: proc(left, right: f64) -> f64,
	bound:     u64, // The largest error in units in the last place.
}

ELEMENTARY_FUNCTIONS := [?]Elementary_Function {
	{.Exp, proc(left, _: f64) -> f64 {return math.exp(left)}, 1},
	{.Log, proc(left, _: f64) -> f64 {return libc.log(left)}, 1},
	{.Log2, proc(left, _: f64) -> f64 {return libc.log2(left)}, 1},
	// log10 of glibc is off by up to 2 units; the test below pins two inputs
	// where the thin libc gives the correct rounding and the host does not.
	{.Log10, proc(left, _: f64) -> f64 {return libc.log10(left)}, 2},
	{.Pow, proc(left, right: f64) -> f64 {return math.pow(left, right)}, 1},
	{.Sin, proc(left, _: f64) -> f64 {return math.sin(left)}, 1},
	{.Cos, proc(left, _: f64) -> f64 {return math.cos(left)}, 1},
	{.Tan, proc(left, _: f64) -> f64 {return libc.tan(left)}, 2},
	{.Asin, proc(left, _: f64) -> f64 {return libc.asin(left)}, 2},
	{.Acos, proc(left, _: f64) -> f64 {return libc.acos(left)}, 2},
	{.Atan, proc(left, _: f64) -> f64 {return libc.atan(left)}, 2},
	{.Atan2, proc(left, right: f64) -> f64 {return libc.atan2(left, right)}, 2},
}

uniform :: proc(generator: ^Generator, low, high: f64) -> f64 {
	unit := f64(next_word(generator) >> 11) / 9007199254740992 // 2^53
	return low + (high - low) * unit
}

// The inputs of one function: the edges, random bits, and the ranges where
// its algorithm changes its path.
elementary_inputs :: proc(operation: Math_Operation, generator: ^Generator) -> [][2]f64 {
	inputs := make([dynamic][2]f64, context.temp_allocator)
	edges := double_edges()
	for left in edges {
		for right_index in 0 ..< 6 {
			right := edges[(int(left % 97) + right_index * 13) % len(edges)]
			append(&inputs, [2]f64{transmute(f64)left, transmute(f64)right})
		}
	}
	for _ in 0 ..< 2000 {
		append(&inputs, [2]f64{transmute(f64)next_word(generator), transmute(f64)next_word(generator)})
	}
	for _ in 0 ..< 4000 {
		pair: [2]f64
		switch operation {
		case .Exp:
			pair = {uniform(generator, -746, 710), 0}
		case .Log, .Log2, .Log10:
			pair = {uniform(generator, 0, 4), 0}
			if next_below(generator, 2) == 0 {
				pair[0] = 1 + uniform(generator, -1, 1) * math.pow(2, -f64(next_below(generator, 50)))
			}
		case .Pow:
			switch next_below(generator, 4) {
			case 0:
				pair = {uniform(generator, 0, 100), uniform(generator, -150, 150)}
			case 1:
				// A base near 1 and a large exponent: the error of ln x is
				// multiplied by y.
				pair = {1 + uniform(generator, -1, 1) * math.pow(2, -f64(10 + next_below(generator, 40))), uniform(generator, -1e12, 1e12)}
			case 2:
				pair = {-uniform(generator, 0, 10), f64(i64(next_below(generator, 601)) - 300)}
			case 3:
				pair = {transmute(f64)(next_word(generator) & 0x7fffffffffffffff), uniform(generator, -3, 3)}
			}
		case .Sin, .Cos, .Tan:
			switch next_below(generator, 4) {
			case 0:
				pair = {uniform(generator, -10, 10), 0}
			case 1:
				pair = {uniform(generator, -1e6, 1e6), 0}
			case 2:
				// The doubles nearest a multiple of pi/2, where the reduction
				// cancels the most bits.
				pair = {f64(next_below(generator, 200000)) * (math.PI / 2), 0}
			case 3:
				pair = {transmute(f64)((next_word(generator) & 0x3fffffffffffffff) | 0x4100000000000000), 0}
			}
		case .Asin, .Acos:
			pair = {uniform(generator, -1, 1), 0}
			if next_below(generator, 2) == 0 {
				pair[0] = 1 - math.pow(2, -f64(next_below(generator, 53)))
			}
		case .Atan:
			pair = {uniform(generator, -3, 3) * math.pow(10, f64(next_below(generator, 9)) - 4), 0}
		case .Atan2:
			pair = {uniform(generator, -10, 10), uniform(generator, -10, 10)}
		case .Floor, .Ceil, .Trunc, .Fabs, .Fmod, .Sqrt, .Ldexp, .Frexp_Fraction, .Frexp_Exponent:
		}
		append(&inputs, pair)
	}
	return inputs[:]
}

@(test)
thin_libc_elementary_functions_match_the_host_within_their_bound :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	generator := Generator{0x5eed_0006}
	for function in ELEMENTARY_FUNCTIONS {
		largest: u64
		failures := 0
		inputs := elementary_inputs(function.operation, &generator)
		for pair in inputs {
			expected := function.reference(pair[0], pair[1])
			found := u64(call(loaded, "call_math", i64(function.operation), i64(transmute(u64)pair[0]), i64(transmute(u64)pair[1])))
			special := expected == 0 || expected != expected || math.is_inf(expected)
			distance := units_in_last_place(expected, found)
			passed := special_result_matches(expected, found) if special else distance <= function.bound
			if !special {
				largest = max(largest, distance)
			}
			if !passed {
				failures += 1
				if failures <= 5 {
					testing.expectf(t, false, "%v(%x, %x): the host gives %x, the thin libc %x", function.operation, transmute(u64)pair[0], transmute(u64)pair[1], transmute(u64)expected, found)
				}
			}
		}
		testing.expectf(t, failures == 0, "%v: %d of %d inputs past the bound", function.operation, failures, len(inputs))
		fmt.printfln("thin libc %v: %d inputs, largest error %d units in the last place", function.operation, len(inputs), largest)
	}
}

@(test)
thin_libc_log10_rounds_correctly_where_the_host_does_not :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	// The correct roundings, from log10 at 300 bits of mpmath.
	cases := [?][2]u64{{0x3fe20988644cb9c8, 0xbfcfde93410ab973}, {0x3fefffff79b41f0f, 0xbe7d297f29e114e2}}
	for pair in cases {
		testing.expect_value(t, u64(call(loaded, "call_math", i64(Math_Operation.Log10), i64(pair[0]), 0)), pair[1])
	}
	// Exact powers of ten and of two give exact logarithms.
	ten := f64(1)
	for exponent in 0 ..= 22 {
		testing.expect_value(t, transmute(f64)u64(call(loaded, "call_math", i64(Math_Operation.Log10), i64(transmute(u64)ten), 0)), f64(exponent))
		ten *= 10
	}
	for exponent in -1074 ..= 1023 {
		testing.expect_value(t, transmute(f64)u64(call(loaded, "call_math", i64(Math_Operation.Log2), i64(transmute(u64)math.ldexp(f64(1), exponent)), 0)), f64(exponent))
	}
}

@(test)
thin_libc_pow_follows_annex_f_and_gives_exact_powers :: proc(t: ^testing.T) {
	loaded, ok := load_module(t)
	if !ok {
		return
	}
	defer unload_module(loaded)
	pow_of :: proc(loaded: Loaded_Module, x, y: f64) -> u64 {
		return u64(call(loaded, "call_math", i64(Math_Operation.Pow), i64(transmute(u64)x), i64(transmute(u64)y)))
	}
	nan := math.nan_f64()
	infinity := math.inf_f64(1)
	bases := [?]f64{0, -0.0, 1, -1, 0.5, -0.5, 2, -2, -3, infinity, -infinity, nan, 5e-324, 1e-310, 1.7976931348623157e308, -1.7976931348623157e308, 0.9999999999999999, 1.0000000000000002}
	exponents := [?]f64{0, -0.0, 1, -1, 0.5, -0.5, 2, -2, 3, -3, 1.5, -1.5, infinity, -infinity, nan, 1e20, -1e20, 9007199254740992, 9007199254740994, 4503599627370497, 1023, 1024, -1074, -1075, 1e300, -1e300}
	for x in bases {
		for y in exponents {
			expected := math.pow(x, y)
			found := pow_of(loaded, x, y)
			if expected == 0 || expected != expected || math.is_inf(expected) {
				testing.expectf(t, special_result_matches(expected, found), "pow(%v, %v): the host gives %x, the thin libc %x", x, y, transmute(u64)expected, found)
			} else {
				testing.expectf(t, units_in_last_place(expected, found) <= 1, "pow(%v, %v): the host gives %x, the thin libc %x", x, y, transmute(u64)expected, found)
			}
		}
	}
	// A NaN gives 1 with an exponent of zero or a base of one, as Annex F says.
	testing.expect_value(t, pow_of(loaded, nan, 0), transmute(u64)f64(1))
	testing.expect_value(t, pow_of(loaded, 1, nan), transmute(u64)f64(1))
	testing.expect_value(t, pow_of(loaded, -1, infinity), transmute(u64)f64(1))
	// A negative base with an exponent that is not an integer has no real power.
	testing.expect(t, (transmute(f64)pow_of(loaded, -8, 1.0 / 3.0)) != (transmute(f64)pow_of(loaded, -8, 1.0 / 3.0)))
	// The exact powers are exact.
	for exponent in -1074 ..= 1023 {
		testing.expectf(t, pow_of(loaded, 2, f64(exponent)) == transmute(u64)math.ldexp(f64(1), exponent), "pow(2, %d)", exponent)
	}
	ten := f64(1)
	for exponent in 0 ..= 22 {
		testing.expectf(t, pow_of(loaded, 10, f64(exponent)) == transmute(u64)ten, "pow(10, %d)", exponent)
		ten *= 10
	}
	three := f64(1)
	for exponent in 0 ..= 33 {
		testing.expectf(t, pow_of(loaded, 3, f64(exponent)) == transmute(u64)three, "pow(3, %d)", exponent)
		testing.expectf(t, pow_of(loaded, -3, f64(exponent)) == transmute(u64)(three if exponent % 2 == 0 else -three), "pow(-3, %d)", exponent)
		three *= 3
	}
}
