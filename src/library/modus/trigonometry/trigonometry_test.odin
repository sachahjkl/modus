#+build !freestanding
#+build !modus
package trigonometry

import "core:fmt"
import "core:math"
import "core:testing"

// The angles that are exact in binary give exact results: 0, a quarter, a
// half, three quarters and a whole turn, the same angles one turn later
// and before, and -0.25, which is three quarters.
@(test)
whole_quarter_turns_are_exact :: proc(t: ^testing.T) {
	Exact :: struct {
		angle_turns: f64,
		cosine:      f64,
		sine:        f64,
	}
	cases := [?]Exact {
		{0, 1, 0},
		{0.25, 0, 1},
		{0.5, -1, 0},
		{0.75, 0, -1},
		{1, 1, 0},
		{-0.25, 0, -1},
		{-0.5, -1, 0},
		{-0.75, 0, 1},
		{-1, 1, 0},
		{1.25, 0, 1},
		{2.5, -1, 0},
		{-3.75, 0, 1},
		{1e6 + 0.75, 0, -1},
	}
	for item in cases {
		testing.expectf(t, cosine(item.angle_turns) == item.cosine, "the cosine of %v turns is %v, not exactly %v", item.angle_turns, cosine(item.angle_turns), item.cosine)
		testing.expectf(t, sine(item.angle_turns) == item.sine, "the sine of %v turns is %v, not exactly %v", item.angle_turns, sine(item.angle_turns), item.sine)
	}
	// A right angle gives +0, not -0.
	testing.expect(t, !math.sign_bit(cosine(0.25)), "the cosine of a quarter turn is -0")
	testing.expect(t, !math.sign_bit(sine(0.5)), "the sine of a half turn is -0")
}

// An angle past one turn wraps: it has the value of its fraction of a
// turn, at each count of whole turns and of each sign.
@(test)
an_angle_past_one_turn_wraps :: proc(t: ^testing.T) {
	fractions := [?]f64{0.1, 0.125, 0.3, 0.6, 0.875, 0.999}
	for fraction in fractions {
		for whole in ([?]f64{1, 2, 7, 1000, -1, -2, -1000}) {
			angle := whole + fraction
			testing.expectf(t, abs(cosine(angle) - cosine(fraction)) < 1e-12, "the cosine of %v turns is not the cosine of %v turns", angle, fraction)
			testing.expectf(t, abs(sine(angle) - sine(fraction)) < 1e-12, "the sine of %v turns is not the sine of %v turns", angle, fraction)
		}
	}
	testing.expect_value(t, fraction_of_turn(2.375), 0.375)
	testing.expect_value(t, fraction_of_turn(-0.25), 0.75)
	testing.expect_value(t, fraction_of_turn(-2.25), 0.75)
	testing.expect_value(t, fraction_of_turn(0), 0)
	// The largest whole numbers: each is a whole count of turns.
	testing.expect_value(t, cosine(WHOLE_NUMBERS_FROM), 1)
	testing.expect_value(t, cosine(max(f64)), 1)
	testing.expect_value(t, sine(-max(f64)), 0)
	// The f64 just under 2^52 holds a half: the direction of a half turn.
	testing.expect_value(t, cosine(WHOLE_NUMBERS_FROM - 0.5), -1)
	// A negative angle of less than 2^-53 turns rounds to the direction 0.
	testing.expect_value(t, cosine(-1e-300), 1)
	testing.expect(t, abs(sine(-1e-300)) <= 1e-300, "the sine of -1e-300 turns is not near 0")
}

// An angle with no direction, infinite or NaN, gives a NaN, never a
// number.
@(test)
an_angle_with_no_direction_gives_nan :: proc(t: ^testing.T) {
	for angle in ([?]f64{math.inf_f64(1), math.inf_f64(-1), math.nan_f64()}) {
		testing.expectf(t, math.is_nan(cosine(angle)), "the cosine of %v turns is %v", angle, cosine(angle))
		testing.expectf(t, math.is_nan(sine(angle)), "the sine of %v turns is %v", angle, sine(angle))
	}
}

// The precision against the radian form of the core library, and against
// the series in radians that `tone` computed before. The radian form
// rounds 2π · t, and that rounding grows with the angle: the bound is 4
// units of the last place of an f64 near 1, times 1 + the angle in
// radians. The largest difference, in those units, is printed as a
// measure.
@(test)
the_precision_matches_the_radian_form :: proc(t: ^testing.T) {
	STEPS :: 200_000
	BOUND :: 4 * 2.220446049250313e-16
	worst_cosine, worst_sine, worst_identity: f64
	for step in 0 ..= STEPS {
		angle := -2 + 4 * f64(step) / STEPS
		// The core library takes radians: the one conversion of the test.
		radians := angle * math.TAU
		scale := 1 + abs(radians)
		worst_cosine = max(worst_cosine, abs(cosine(angle) - math.cos(radians)) / scale)
		worst_sine = max(worst_sine, abs(sine(angle) - math.sin(radians)) / scale)
		worst_identity = max(worst_identity, abs(cosine(angle) * cosine(angle) + sine(angle) * sine(angle) - 1))
	}
	fmt.printfln("trigonometry: measure: the largest difference from the radian form of the core library over -2 to 2 turns, divided by 1 + the angle in radians: cosine %e, sine %e; sine^2 + cosine^2 - 1 at most %e", worst_cosine, worst_sine, worst_identity)
	testing.expectf(t, worst_cosine <= BOUND, "the cosine is %e from the radian form", worst_cosine)
	testing.expectf(t, worst_sine <= BOUND, "the sine is %e from the radian form", worst_sine)
	testing.expectf(t, worst_identity <= BOUND, "sine^2 + cosine^2 is %e from 1", worst_identity)

	// The series of eight terms in radians that `tone` used, at the step
	// of its tone: 440 Hz at 48 000 frames in one second.
	radian_series :: proc(angle_radians: f64) -> (sum: f64) {
		term := 1.0
		for order in 0 ..< 8 {
			sum += term
			n := f64(2 * order)
			term *= -angle_radians * angle_radians / ((n + 1) * (n + 2))
		}
		return sum
	}
	step_turns := 440.0 / 48000.0
	old := radian_series(2 * 3.141592653589793 * step_turns)
	testing.expectf(t, abs(cosine(step_turns) - old) <= BOUND, "the step of the tone is %v in turns and %v in the radian series", cosine(step_turns), old)
}
