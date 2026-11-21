// The sine and the cosine of an angle in turns, for the code of the
// system, which has no library of mathematics.
//
// An angle of the system is in turns: 1 is a whole circle, 0.25 a right
// angle. The angles that code uses most, a quarter, a half and an eighth,
// are exact in binary, so the cosine of a right angle is exactly 0. The
// reduction to the nearest quarter turn is a subtraction of whole
// quarters, exact for each angle. A form in radians multiplies by 2π at
// each call and then divides by π/2 to find the quarter: here that factor
// is inside the coefficients of the polynomials, so the code holds no π.
//
// A derivative of a function of an angle in turns gains that factor: the
// derivative of cosine(t) is -2π · sine(t). Code that takes a formula of
// calculus from a book, written for radians, must add it.
package trigonometry

// From 2^52 on, each f64 is a whole number: a whole count of turns.
WHOLE_NUMBERS_FROM :: 4503599627370496.0

// The coefficients of the Taylor series of the cosine and of the sine at 0,
// with the angle in turns: (-1)^k (2π)^(2k) / (2k)! and
// (-1)^k (2π)^(2k+1) / (2k+1)!. Nine terms of each reach the precision of an
// f64 up to an eighth of a turn: the first term left out is below 1e-18.
COSINE_0 :: 1.0
COSINE_1 :: -19.739208802178716
COSINE_2 :: 64.9393940226683
COSINE_3 :: -85.45681720669373
COSINE_4 :: 60.24464137187666
COSINE_5 :: -26.4262567833744
COSINE_6 :: 7.903536371318469
COSINE_7 :: -1.714390711088672
COSINE_8 :: 0.28200596845579123

SINE_0 :: 6.283185307179586
SINE_1 :: -41.34170224039976
SINE_2 :: 81.60524927607506
SINE_3 :: -76.70585975306139
SINE_4 :: 42.058693944897655
SINE_5 :: -15.09464257682299
SINE_6 :: 3.819952584848282
SINE_7 :: -0.7181223017785006
SINE_8 :: 0.10422916220813984

// cosine gives the cosine of an angle in turns. A whole number of quarter
// turns gives an exact 1, 0 or -1. An infinite angle or a NaN gives a NaN.
cosine :: proc "contextless" (angle_turns: f64) -> f64 {
	quarter, rest_turns := quarter_and_rest(angle_turns)
	switch quarter {
	case 0:
		return cosine_near_zero(rest_turns)
	case 1:
		// 0 - x and not -x: a right angle gives +0, not -0.
		return 0 - sine_near_zero(rest_turns)
	case 2:
		return 0 - cosine_near_zero(rest_turns)
	}
	return sine_near_zero(rest_turns)
}

// sine gives the sine of an angle in turns. A whole number of quarter
// turns gives an exact 0, 1 or -1. An infinite angle or a NaN gives a NaN.
sine :: proc "contextless" (angle_turns: f64) -> f64 {
	quarter, rest_turns := quarter_and_rest(angle_turns)
	switch quarter {
	case 0:
		return sine_near_zero(rest_turns)
	case 1:
		return cosine_near_zero(rest_turns)
	case 2:
		return 0 - sine_near_zero(rest_turns)
	}
	return 0 - cosine_near_zero(rest_turns)
}

// fraction_of_turn gives the same direction as the angle, from 0 to 1: the
// whole turns are taken away, which is exact. A negative angle of less
// than 2^-53 turns can round to 1, which is the same direction as 0.
fraction_of_turn :: proc "contextless" (angle_turns: f64) -> f64 {
	// A NaN fails the comparison too. x - x is 0 for a whole number, and a
	// NaN for an infinite angle or a NaN.
	if !(abs(angle_turns) < WHOLE_NUMBERS_FROM) {
		return angle_turns - angle_turns
	}
	fraction := angle_turns - f64(i64(angle_turns))
	if fraction < 0 {
		fraction += 1
	}
	return fraction
}

// quarter_and_rest gives the nearest whole quarter turn of an angle, from 0
// to 3, and the rest in turns, from -1/8 to 1/8. The multiplication by 4 and
// the subtraction of a whole number below 5 are exact.
@(private = "file")
quarter_and_rest :: proc "contextless" (angle_turns: f64) -> (quarter: i64, rest_turns: f64) {
	quarters := fraction_of_turn(angle_turns) * 4
	if quarters != quarters {
		return 0, quarters
	}
	nearest := i64(quarters + 0.5)
	return nearest & 3, (quarters - f64(nearest)) * 0.25
}

@(private = "file")
cosine_near_zero :: proc "contextless" (rest_turns: f64) -> f64 {
	square := rest_turns * rest_turns
	return COSINE_0 + square * (COSINE_1 + square * (COSINE_2 + square * (COSINE_3 + square * (COSINE_4 + square * (COSINE_5 + square * (COSINE_6 + square * (COSINE_7 + square * COSINE_8)))))))
}

@(private = "file")
sine_near_zero :: proc "contextless" (rest_turns: f64) -> f64 {
	square := rest_turns * rest_turns
	return rest_turns * (SINE_0 + square * (SINE_1 + square * (SINE_2 + square * (SINE_3 + square * (SINE_4 + square * (SINE_5 + square * (SINE_6 + square * (SINE_7 + square * SINE_8))))))))
}
