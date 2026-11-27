// The SSE and SSE2 instructions of the software processor: the sixteen
// vector registers, MXCSR and its exceptions (src/md/features/browser_machine.md,
// "The vector instructions").
//
// Each form reads its operands, computes its result in locals, and writes
// a register or memory only as its last action. So a fault, which
// processor_step does not undo for the vector registers, leaves every
// vector register and MXCSR as they were before the instruction.
//
// A result that is not a number never comes from the host: the host gives a
// NaN whose sign and payload WebAssembly does not fix. The rules of x86-64
// (Intel SDM, volume 1, section 4.8.3.5 and table 11-1) choose each NaN here.
package software_machine

import "base:intrinsics"
import "modus:contract/enum_word"

// MXCSR of a new thread: every exception masked, round to nearest.
MXCSR_START :: u32(0x1F80)
// The bits of MXCSR that this processor takes: the low 16 bits but
// denormals-are-zero, which it lacks, as a processor that writes this mask
// with fxsave (Intel SDM, volume 1, section 11.6.6). ldmxcsr and fxrstor
// refuse any other bit with a protection fault.
MXCSR_MASK :: u32(0xFFBF)
MXCSR_EXCEPTION_MASK_SHIFT :: 7
MXCSR_ROUNDING_SHIFT :: 13
MXCSR_FLUSH_TO_ZERO :: u32(1) << 15

// The offsets of the area of fxsave and fxrstor (Intel SDM, volume 1,
// table 10-2), and its size and alignment.
FXSAVE_AREA_BYTES :: 512
FXSAVE_WRITTEN_BYTES :: 416 // The x87, MXCSR and vector part; the rest stays as it was.
FXSAVE_CONTROL_WORD_OFFSET :: 0
FXSAVE_MXCSR_OFFSET :: 24
FXSAVE_MXCSR_MASK_OFFSET :: 28
FXSAVE_XMM_OFFSET :: 160
// The x87 control word after fninit; the processor holds no x87 state.
X87_CONTROL_WORD_START :: u16(0x037F)

// One exception of a vector floating-point instruction: its bit in the
// flags of MXCSR, and in the masks 7 bits higher.
Simd_Exception :: enum u8 {
	Invalid        = 0,
	Denormal       = 1,
	Divide_By_Zero = 2,
	Overflow       = 3,
	Underflow      = 4,
	Precision      = 5,
}
Simd_Exceptions :: bit_set[Simd_Exception;u32]

// The rounding control of MXCSR, bits 13 and 14.
Rounding_Control :: enum u8 {
	Nearest     = 0,
	Down        = 1,
	Up          = 2,
	Toward_Zero = 3,
}

Float_Precision :: enum u8 {
	Single,
	Double,
}

Float_Operation :: enum u8 {
	Add,
	Subtract,
	Multiply,
	Divide,
	Minimum,
	Maximum,
}

// The predicate of cmpps, cmppd, cmpss and cmpsd: the low 3 bits of the
// immediate. The legacy form ignores bits 3 to 7.
Compare_Predicate :: enum u8 {
	Equal             = 0,
	Less              = 1,
	Less_Or_Equal     = 2,
	Unordered         = 3,
	Not_Equal         = 4,
	Not_Less          = 5,
	Not_Less_Or_Equal = 6,
	Ordered           = 7,
}

// The relation that ucomiss, ucomisd, comiss and comisd write to the flags.
Float_Relation :: enum u8 {
	Unordered,
	Less,
	Equal,
	Greater,
}

// The mandatory prefix that selects the form of a vector opcode: none,
// 66, F3 or F2. F3 and F2 come before 66, and the last of F3 and F2 wins.
Simd_Prefix :: enum u8 {
	None,
	Operand_Size,
	Repeat,
	Repeat_Not_Equal,
}

Vector_Shift :: enum u8 {
	Left,
	Right_Logical,
	Right_Arithmetic,
}

@(private = "file")
Float_Layout :: struct {
	sign, exponent, fraction, quiet, indefinite: u64,
}

@(private = "file")
float_layout :: #force_inline proc "contextless" (precision: Float_Precision) -> Float_Layout {
	switch precision {
	case .Single:
		return {sign = 1 << 31, exponent = 0x7F80_0000, fraction = 0x007F_FFFF, quiet = 1 << 22, indefinite = 0xFFC0_0000}
	case .Double:
		return {sign = 1 << 63, exponent = 0x7FF0_0000_0000_0000, fraction = 0x000F_FFFF_FFFF_FFFF, quiet = 1 << 51, indefinite = 0xFFF8_0000_0000_0000}
	}
	return {}
}

float_is_nan :: proc "contextless" (bits: u64, precision: Float_Precision) -> bool {
	layout := float_layout(precision)
	return (bits & layout.exponent) == layout.exponent && (bits & layout.fraction) != 0
}

float_is_signaling_nan :: proc "contextless" (bits: u64, precision: Float_Precision) -> bool {
	return float_is_nan(bits, precision) && (bits & float_layout(precision).quiet) == 0
}

float_is_infinite :: proc "contextless" (bits: u64, precision: Float_Precision) -> bool {
	layout := float_layout(precision)
	return (bits & layout.exponent) == layout.exponent && (bits & layout.fraction) == 0
}

float_is_denormal :: proc "contextless" (bits: u64, precision: Float_Precision) -> bool {
	layout := float_layout(precision)
	return (bits & layout.exponent) == 0 && (bits & layout.fraction) != 0
}

float_is_zero :: proc "contextless" (bits: u64, precision: Float_Precision) -> bool {
	return (bits & ~float_layout(precision).sign) == 0
}

@(private = "file")
float_quiet :: #force_inline proc "contextless" (bits: u64, precision: Float_Precision) -> u64 {
	return bits | float_layout(precision).quiet
}

// float_to_f64 widens a value that is not a NaN: exact for both precisions.
@(private = "file")
float_to_f64 :: #force_inline proc "contextless" (bits: u64, precision: Float_Precision) -> f64 {
	switch precision {
	case .Single:
		return f64(transmute(f32)u32(bits))
	case .Double:
		return transmute(f64)bits
	}
	return 0
}

// float_from_f64 rounds a value that is not a NaN to the precision, to
// nearest. An operation of two singles computed in double precision and
// rounded once more gives the correctly rounded single: 53 >= 2 * 24 + 2
// (Figueroa, "When is double rounding innocuous?", 1995).
@(private = "file")
float_from_f64 :: #force_inline proc "contextless" (value: f64, precision: Float_Precision) -> u64 {
	switch precision {
	case .Single:
		return u64(transmute(u32)f32(value))
	case .Double:
		return transmute(u64)value
	}
	return 0
}

// float_result gives the bits of a computed value and the exceptions of
// its rounding: a NaN from operands that are numbers is the invalid
// result, a value that grew to infinity from finite operands overflows,
// and a tiny result underflows: always when unmasked, flushed to zero with
// flush-to-zero when masked, and with masked underflow when the tiny result
// lost precision (IEEE-754 tininess and inexactness).
@(private = "file")
float_result :: proc "contextless" (value: f64, precision: Float_Precision, mxcsr: u32, operands_finite: bool, raised_before: Simd_Exceptions, double_underflow_inexact := false) -> (bits: u64, raised: Simd_Exceptions) {
	raised = raised_before
	layout := float_layout(precision)
	if value != value {
		return layout.indefinite, raised + {.Invalid}
	}
	bits = float_from_f64(value, precision)
	if float_is_infinite(bits, precision) && operands_finite && .Divide_By_Zero not_in raised {
		raised += {.Overflow, .Precision}
	}
	tiny := float_is_denormal(bits, precision) || (float_is_zero(bits, precision) && (value != 0 || double_underflow_inexact))
	if tiny {
		underflow_masked := (mxcsr >> (MXCSR_EXCEPTION_MASK_SHIFT + u32(Simd_Exception.Underflow))) & 1 != 0
		if !underflow_masked {
			raised += {.Underflow}
		} else if mxcsr & MXCSR_FLUSH_TO_ZERO != 0 {
			bits &= layout.sign
			raised += {.Underflow, .Precision}
		} else {
			inexact := (float_to_f64(bits, .Single) != value) if precision == .Single else double_underflow_inexact
			if inexact {
				raised += {.Underflow, .Precision}
			}
		}
	}
	return bits, raised
}

// double_tiny_mul_or_div_inexact checks whether a tiny double-precision
// product or quotient lost precision (subnormal rounding or underflow to zero).
@(private = "file")
double_tiny_mul_or_div_inexact :: proc "contextless" (operation: Float_Operation, first, second, result_bits: u64) -> bool {
	if float_is_zero(first, .Double) || float_is_zero(second, .Double) {
		return false
	}
	if float_is_infinite(first, .Double) || float_is_infinite(second, .Double) {
		return false
	}
	if float_is_zero(result_bits, .Double) {
		return true
	}
	if !float_is_denormal(result_bits, .Double) {
		return false
	}
	// Decompose normalized significand and unbiased binary exponent for exact check.
	decode_f64 :: proc "contextless" (bits: u64) -> (sig: u64, exp: i32) {
		raw_exp := i32((bits >> 52) & 0x7FF)
		frac := bits & 0x000F_FFFF_FFFF_FFFF
		if raw_exp == 0 {
			return frac, -1074
		}
		return (u64(1) << 52) | frac, raw_exp - 1023 - 52
	}
	sa, ea := decode_f64(first)
	sb, eb := decode_f64(second)
	sr, er := decode_f64(result_bits) // denormal: er == -1074
	if operation == .Multiply {
		// Exact iff sa * sb * 2^(ea + eb) == sr * 2^er.
		lo, hi := multiply_u64_to_u128(sa, sb)
		shift := er - (ea + eb)
		if shift <= 0 {
			return false
		}
		if shift >= 128 {
			return true
		}
		if shift >= 64 {
			if lo != 0 {
				return true
			}
			rem_shift := uint(shift - 64)
			mask := (u64(1) << rem_shift) - 1 if rem_shift < 64 else max(u64)
			return (hi & mask) != 0
		}
		mask := (u64(1) << uint(shift)) - 1
		return (lo & mask) != 0
	}
	if operation == .Divide {
		// Exact iff sa * 2^ea == sr * sb * 2^(er + eb).
		lo, hi := multiply_u64_to_u128(sr, sb)
		shift := ea - (er + eb)
		if shift < 0 {
			neg := uint(-shift)
			if neg >= 128 {
				return true
			}
			if neg >= 64 {
				return lo != 0 || (hi >> (neg - 64)) != sa || ((hi & ((u64(1) << (neg - 64)) - 1)) != 0)
			}
			shifted := (lo >> neg) | (hi << (64 - neg))
			return (hi >> neg) != 0 || shifted != sa || (lo & ((u64(1) << neg) - 1)) != 0
		}
		s_u := uint(shift)
		if s_u >= 128 {
			return true
		}
		exp_lo := sa << s_u if s_u < 64 else u64(0)
		exp_hi := (sa >> (64 - s_u)) if (s_u > 0 && s_u < 64) else (sa << (s_u - 64) if s_u >= 64 else u64(0))
		return lo != exp_lo || hi != exp_hi
	}
	return false
}

// float_binary computes one lane of addps to maxsd: first a NaN operand
// (the quiet form of the first NaN, the destination first), then the
// arithmetic of the host on numbers.
float_binary :: proc "contextless" (operation: Float_Operation, first, second: u64, precision: Float_Precision, mxcsr: u32) -> (result: u64, raised: Simd_Exceptions) {
	first_nan := float_is_nan(first, precision)
	second_nan := float_is_nan(second, precision)
	switch operation {
	case .Minimum, .Maximum:
		// A NaN operand, or two equal values such as two zeros, give the
		// second operand as it is (Intel SDM, MINPS and MAXPS).
		if first_nan || second_nan {
			return second, {.Invalid}
		}
		if float_is_denormal(first, precision) || float_is_denormal(second, precision) {
			raised += {.Denormal}
		}
		x := float_to_f64(first, precision)
		y := float_to_f64(second, precision)
		if operation == .Minimum {
			return first if x < y else second, raised
		}
		return first if x > y else second, raised
	case .Add, .Subtract, .Multiply, .Divide:
	}
	if first_nan || second_nan {
		if float_is_signaling_nan(first, precision) || float_is_signaling_nan(second, precision) {
			raised += {.Invalid}
		}
		return float_quiet(first, precision) if first_nan else float_quiet(second, precision), raised
	}
	x := float_to_f64(first, precision)
	y := float_to_f64(second, precision)
	operands_finite := !float_is_infinite(first, precision) && !float_is_infinite(second, precision)
	// Per x86-64 SSE exception priority, divide-by-zero on a finite non-zero
	// dividend takes precedence over the denormal operand flag.
	divide_by_zero := operation == .Divide && y == 0 && x != 0 && operands_finite
	if divide_by_zero {
		raised += {.Divide_By_Zero}
	} else if float_is_denormal(first, precision) || float_is_denormal(second, precision) {
		raised += {.Denormal}
	}
	value: f64
	switch operation {
	case .Add:
		value = x + y
	case .Subtract:
		value = x - y
	case .Multiply:
		value = x * y
	case .Divide:
		value = x / y
	case .Minimum, .Maximum:
	}
	double_inexact := false
	if precision == .Double && (operation == .Multiply || operation == .Divide) && operands_finite {
		double_inexact = double_tiny_mul_or_div_inexact(operation, first, second, transmute(u64)value)
	}
	return float_result(value, precision, mxcsr, operands_finite, raised, double_inexact)
}

float_square_root :: proc "contextless" (operand: u64, precision: Float_Precision, mxcsr: u32) -> (result: u64, raised: Simd_Exceptions) {
	layout := float_layout(precision)
	if float_is_nan(operand, precision) {
		if float_is_signaling_nan(operand, precision) {
			raised += {.Invalid}
		}
		return float_quiet(operand, precision), raised
	}
	if float_is_zero(operand, precision) {
		return operand, {}
	}
	if operand & layout.sign != 0 {
		return layout.indefinite, {.Invalid}
	}
	if float_is_denormal(operand, precision) {
		raised += {.Denormal}
	}
	return float_result(intrinsics.sqrt(float_to_f64(operand, precision)), precision, mxcsr, !float_is_infinite(operand, precision), raised)
}

// float_reciprocal gives rcpps and rsqrtps: the processor gives an
// approximation within 1.5 * 2^-12; this one gives the rounded exact
// value, which is within it. They raise no exception; a denormal operand
// counts as a zero and a tiny result is a zero (Intel SDM, RCPSS).
float_reciprocal :: proc "contextless" (operand: u32, square_root: bool) -> u32 {
	precision := Float_Precision.Single
	bits := u64(operand)
	layout := float_layout(precision)
	if float_is_nan(bits, precision) {
		return u32(float_quiet(bits, precision))
	}
	sign := bits & layout.sign
	if float_is_zero(bits, precision) || float_is_denormal(bits, precision) {
		return u32(sign | layout.exponent)
	}
	if square_root && sign != 0 {
		return u32(layout.indefinite)
	}
	if float_is_infinite(bits, precision) {
		return u32(sign)
	}
	x := float_to_f64(bits, precision)
	value := 1 / intrinsics.sqrt(x) if square_root else 1 / x
	result := float_from_f64(value, precision)
	if float_is_denormal(result, precision) {
		result &= layout.sign
	}
	return u32(result)
}

// float_compare gives one lane of cmpps to cmpsd. The predicates less and
// less or equal, and their negations, signal on any NaN; the others on a
// signaling NaN only.
float_compare :: proc "contextless" (predicate: Compare_Predicate, first, second: u64, precision: Float_Precision) -> (holds: bool, raised: Simd_Exceptions) {
	unordered := float_is_nan(first, precision) || float_is_nan(second, precision)
	switch predicate {
	case .Less, .Less_Or_Equal, .Not_Less, .Not_Less_Or_Equal:
		if unordered {
			raised += {.Invalid}
		}
	case .Equal, .Unordered, .Not_Equal, .Ordered:
		if float_is_signaling_nan(first, precision) || float_is_signaling_nan(second, precision) {
			raised += {.Invalid}
		}
	}
	if unordered {
		switch predicate {
		case .Equal, .Less, .Less_Or_Equal, .Ordered:
			return false, raised
		case .Unordered, .Not_Equal, .Not_Less, .Not_Less_Or_Equal:
			return true, raised
		}
	}
	if float_is_denormal(first, precision) || float_is_denormal(second, precision) {
		raised += {.Denormal}
	}
	x := float_to_f64(first, precision)
	y := float_to_f64(second, precision)
	switch predicate {
	case .Equal:
		return x == y, raised
	case .Less:
		return x < y, raised
	case .Less_Or_Equal:
		return x <= y, raised
	case .Unordered:
		return false, raised
	case .Not_Equal:
		return x != y, raised
	case .Not_Less:
		return !(x < y), raised
	case .Not_Less_Or_Equal:
		return !(x <= y), raised
	case .Ordered:
		return true, raised
	}
	return false, raised
}

// float_relation gives the relation of ucomiss to comisd. ucomis signals
// on a signaling NaN only, comis on any NaN.
float_relation :: proc "contextless" (first, second: u64, precision: Float_Precision, signal_quiet_nan: bool) -> (relation: Float_Relation, raised: Simd_Exceptions) {
	if float_is_nan(first, precision) || float_is_nan(second, precision) {
		if signal_quiet_nan || float_is_signaling_nan(first, precision) || float_is_signaling_nan(second, precision) {
			raised += {.Invalid}
		}
		return .Unordered, raised
	}
	if float_is_denormal(first, precision) || float_is_denormal(second, precision) {
		raised += {.Denormal}
	}
	x := float_to_f64(first, precision)
	y := float_to_f64(second, precision)
	if x < y {
		return .Less, raised
	}
	if x > y {
		return .Greater, raised
	}
	return .Equal, raised
}

// float_round_to_integral rounds a finite value to an integral value with
// the rounding control. A value of 2^52 or more is integral already.
@(private = "file")
float_round_to_integral :: proc "contextless" (value: f64, rounding: Rounding_Control) -> f64 {
	if !(abs(value) < 4503599627370496.0) {
		return value
	}
	whole := f64(i64(value))
	fraction := value - whole
	switch rounding {
	case .Toward_Zero:
		return whole
	case .Down:
		return whole - 1 if fraction < 0 else whole
	case .Up:
		return whole + 1 if fraction > 0 else whole
	case .Nearest:
		odd := (i64(whole) & 1) != 0
		if fraction > 0.5 || (fraction == 0.5 && odd) {
			return whole + 1
		}
		if fraction < -0.5 || (fraction == -0.5 && odd) {
			return whole - 1
		}
		return whole
	}
	return whole
}

// float_to_integer gives cvtss2si to cvttpd2dq: a NaN or a value out of the
// range of the integer gives the integer indefinite, the lowest value.
float_to_integer :: proc "contextless" (bits: u64, precision: Float_Precision, width: Operand_Width, rounding: Rounding_Control) -> (result: u64, raised: Simd_Exceptions) {
	indefinite := width_sign_bit(width)
	if float_is_nan(bits, precision) {
		return indefinite, {.Invalid}
	}
	if float_is_infinite(bits, precision) {
		return indefinite, {.Invalid}
	}
	rounded := float_round_to_integral(float_to_f64(bits, precision), rounding)
	if width == .Bits_32 {
		if rounded < -2147483648.0 || rounded > 2147483647.0 {
			return indefinite, {.Invalid}
		}
		return u64(u32(i32(rounded))), {}
	}
	if rounded < -9223372036854775808.0 || rounded >= 9223372036854775808.0 {
		return indefinite, {.Invalid}
	}
	return u64(i64(rounded)), {}
}

// integer_to_float gives cvtsi2ss to cvtdq2pd, rounded to nearest.
integer_to_float :: proc "contextless" (value: u64, width: Operand_Width, precision: Float_Precision) -> u64 {
	signed := sign_extend_to_i64(value, width)
	switch precision {
	case .Single:
		return u64(transmute(u32)f32(signed))
	case .Double:
		return transmute(u64)f64(signed)
	}
	return 0
}

// float_convert_precision gives cvtss2sd and cvtsd2ss. A NaN keeps its sign
// and the high bits of its payload, and becomes quiet.
float_convert_precision :: proc "contextless" (bits: u64, from: Float_Precision, mxcsr: u32) -> (result: u64, raised: Simd_Exceptions) {
	to := Float_Precision.Double if from == .Single else Float_Precision.Single
	if float_is_nan(bits, from) {
		if float_is_signaling_nan(bits, from) {
			raised += {.Invalid}
		}
		from_layout := float_layout(from)
		to_layout := float_layout(to)
		sign := to_layout.sign if bits & from_layout.sign != 0 else 0
		fraction := bits & from_layout.fraction
		// The fraction of a double has 29 more bits than the one of a single.
		moved := fraction << 29 if from == .Single else fraction >> 29
		return sign | to_layout.exponent | to_layout.quiet | (moved & to_layout.fraction), raised
	}
	if float_is_denormal(bits, from) {
		raised += {.Denormal}
	}
	return float_result(float_to_f64(bits, from), to, mxcsr, !float_is_infinite(bits, from), raised)
}

simd_rounding_control :: proc "contextless" (mxcsr: u32) -> Rounding_Control {
	rounding, _ := enum_word.member_of_word(Rounding_Control, u64((mxcsr >> MXCSR_ROUNDING_SHIFT) & 3))
	return rounding
}

// simd_exceptions_unmasked reports whether an exception that MXCSR does
// not mask was raised: the instruction then gives vector 19 and writes no
// destination.
simd_exceptions_unmasked :: proc "contextless" (mxcsr: u32, raised: Simd_Exceptions) -> bool {
	masks := (mxcsr >> MXCSR_EXCEPTION_MASK_SHIFT) & 0x3F
	return transmute(u32)raised & ~masks != 0
}

@(private = "file")
saturate_signed_byte :: #force_inline proc "contextless" (value: i32) -> u8 {
	return u8(i8(clamp(value, -128, 127)))
}

@(private = "file")
saturate_unsigned_byte :: #force_inline proc "contextless" (value: i32) -> u8 {
	return u8(clamp(value, 0, 255))
}

@(private = "file")
saturate_signed_word :: #force_inline proc "contextless" (value: i32) -> u16 {
	return u16(i16(clamp(value, -32768, 32767)))
}

@(private = "file")
saturate_unsigned_word :: #force_inline proc "contextless" (value: i32) -> u16 {
	return u16(clamp(value, 0, 65535))
}

// vector_shift shifts each lane of lane_bits bits by count, as psllw to
// psrad do: a count past the lane gives 0, or the sign in each bit.
vector_shift :: proc "contextless" (value: [16]u8, lane_bits: uint, count: u64, kind: Vector_Shift) -> [16]u8 {
	switch lane_bits {
	case 16:
		lanes := transmute([8]u16)value
		for &lane in lanes {
			lane = u16(lane_shift(u64(lane), 16, count, kind))
		}
		return transmute([16]u8)lanes
	case 32:
		lanes := transmute([4]u32)value
		for &lane in lanes {
			lane = u32(lane_shift(u64(lane), 32, count, kind))
		}
		return transmute([16]u8)lanes
	case 64:
		lanes := transmute([2]u64)value
		for &lane in lanes {
			lane = lane_shift(lane, 64, count, kind)
		}
		return transmute([16]u8)lanes
	}
	return value
}

@(private = "file")
lane_shift :: #force_inline proc "contextless" (lane: u64, lane_bits: uint, count: u64, kind: Vector_Shift) -> u64 {
	mask := max(u64) >> (64 - lane_bits)
	switch kind {
	case .Left:
		return 0 if count >= u64(lane_bits) else (lane << count) & mask
	case .Right_Logical:
		return 0 if count >= u64(lane_bits) else lane >> count
	case .Right_Arithmetic:
		shift := min(count, u64(lane_bits - 1))
		signed := i64(lane << (64 - lane_bits)) >> (64 - lane_bits)
		return u64(signed >> shift) & mask
	}
	return lane
}

// vector_byte_shift gives pslldq and psrldq: a shift of whole bytes.
vector_byte_shift :: proc "contextless" (value: [16]u8, count: u8, left: bool) -> [16]u8 {
	result: [16]u8
	shift := int(min(count, 16))
	for index in 0 ..< 16 {
		source := index - shift if left else index + shift
		if source >= 0 && source < 16 {
			result[index] = value[source]
		}
	}
	return result
}

// vector_integer_binary gives the integer instructions of the 66 map that
// take a vector register and a vector register or 16 aligned bytes. false:
// the opcode is not one of them.
vector_integer_binary :: proc "contextless" (opcode: u8, a, b: [16]u8) -> (result: [16]u8, ok: bool) {
	bytes_a, bytes_b := a, b
	words_a, words_b := transmute([8]u16)a, transmute([8]u16)b
	dwords_a, dwords_b := transmute([4]u32)a, transmute([4]u32)b
	qwords_a, qwords_b := transmute([2]u64)a, transmute([2]u64)b
	shift_count := qwords_b[0]
	switch opcode {
	case 0x60: // punpcklbw
		for index in 0 ..< 8 {
			result[2 * index], result[2 * index + 1] = bytes_a[index], bytes_b[index]
		}
	case 0x68: // punpckhbw
		for index in 0 ..< 8 {
			result[2 * index], result[2 * index + 1] = bytes_a[8 + index], bytes_b[8 + index]
		}
	case 0x61, 0x69: // punpcklwd, punpckhwd
		base := 0 if opcode == 0x61 else 4
		words: [8]u16
		for index in 0 ..< 4 {
			words[2 * index], words[2 * index + 1] = words_a[base + index], words_b[base + index]
		}
		result = transmute([16]u8)words
	case 0x62, 0x6A: // punpckldq, punpckhdq
		base := 0 if opcode == 0x62 else 2
		result = transmute([16]u8)[4]u32{dwords_a[base], dwords_b[base], dwords_a[base + 1], dwords_b[base + 1]}
	case 0x6C: // punpcklqdq
		result = transmute([16]u8)[2]u64{qwords_a[0], qwords_b[0]}
	case 0x6D: // punpckhqdq
		result = transmute([16]u8)[2]u64{qwords_a[1], qwords_b[1]}
	case 0x63, 0x67: // packsswb, packuswb
		for index in 0 ..< 8 {
			low := i32(i16(words_a[index]))
			high := i32(i16(words_b[index]))
			if opcode == 0x63 {
				result[index], result[8 + index] = saturate_signed_byte(low), saturate_signed_byte(high)
			} else {
				result[index], result[8 + index] = saturate_unsigned_byte(low), saturate_unsigned_byte(high)
			}
		}
	case 0x6B: // packssdw
		words: [8]u16
		for index in 0 ..< 4 {
			words[index] = saturate_signed_word(i32(dwords_a[index]))
			words[4 + index] = saturate_signed_word(i32(dwords_b[index]))
		}
		result = transmute([16]u8)words
	case 0x64, 0x74: // pcmpgtb, pcmpeqb
		for index in 0 ..< 16 {
			holds := i8(bytes_a[index]) > i8(bytes_b[index]) if opcode == 0x64 else bytes_a[index] == bytes_b[index]
			result[index] = 0xFF if holds else 0
		}
	case 0x65, 0x75: // pcmpgtw, pcmpeqw
		words: [8]u16
		for index in 0 ..< 8 {
			holds := i16(words_a[index]) > i16(words_b[index]) if opcode == 0x65 else words_a[index] == words_b[index]
			words[index] = 0xFFFF if holds else 0
		}
		result = transmute([16]u8)words
	case 0x66, 0x76: // pcmpgtd, pcmpeqd
		dwords: [4]u32
		for index in 0 ..< 4 {
			holds := i32(dwords_a[index]) > i32(dwords_b[index]) if opcode == 0x66 else dwords_a[index] == dwords_b[index]
			dwords[index] = 0xFFFF_FFFF if holds else 0
		}
		result = transmute([16]u8)dwords
	case 0xD1:
		result = vector_shift(a, 16, shift_count, .Right_Logical)
	case 0xD2:
		result = vector_shift(a, 32, shift_count, .Right_Logical)
	case 0xD3:
		result = vector_shift(a, 64, shift_count, .Right_Logical)
	case 0xE1:
		result = vector_shift(a, 16, shift_count, .Right_Arithmetic)
	case 0xE2:
		result = vector_shift(a, 32, shift_count, .Right_Arithmetic)
	case 0xF1:
		result = vector_shift(a, 16, shift_count, .Left)
	case 0xF2:
		result = vector_shift(a, 32, shift_count, .Left)
	case 0xF3:
		result = vector_shift(a, 64, shift_count, .Left)
	case 0xD4: // paddq
		result = transmute([16]u8)(qwords_a + qwords_b)
	case 0xFB: // psubq
		result = transmute([16]u8)(qwords_a - qwords_b)
	case 0xFC: // paddb
		result = bytes_a + bytes_b
	case 0xFD: // paddw
		result = transmute([16]u8)(words_a + words_b)
	case 0xFE: // paddd
		result = transmute([16]u8)(dwords_a + dwords_b)
	case 0xF8: // psubb
		result = bytes_a - bytes_b
	case 0xF9: // psubw
		result = transmute([16]u8)(words_a - words_b)
	case 0xFA: // psubd
		result = transmute([16]u8)(dwords_a - dwords_b)
	case 0xD5, 0xE5, 0xE4: // pmullw, pmulhw, pmulhuw
		words: [8]u16
		for index in 0 ..< 8 {
			switch opcode {
			case 0xD5:
				words[index] = words_a[index] * words_b[index]
			case 0xE5:
				words[index] = u16(u32(i32(i16(words_a[index])) * i32(i16(words_b[index]))) >> 16)
			case:
				words[index] = u16((u32(words_a[index]) * u32(words_b[index])) >> 16)
			}
		}
		result = transmute([16]u8)words
	case 0xF4: // pmuludq
		result = transmute([16]u8)[2]u64{u64(dwords_a[0]) * u64(dwords_b[0]), u64(dwords_a[2]) * u64(dwords_b[2])}
	case 0xF5: // pmaddwd
		dwords: [4]u32
		for index in 0 ..< 4 {
			low := i64(i16(words_a[2 * index])) * i64(i16(words_b[2 * index]))
			high := i64(i16(words_a[2 * index + 1])) * i64(i16(words_b[2 * index + 1]))
			dwords[index] = u32(low + high)
		}
		result = transmute([16]u8)dwords
	case 0xF6: // psadbw
		sums: [2]u64
		for index in 0 ..< 16 {
			difference := i32(bytes_a[index]) - i32(bytes_b[index])
			sums[index / 8] += u64(abs(difference))
		}
		result = transmute([16]u8)sums
	case 0xD8, 0xDC, 0xE8, 0xEC: // psubusb, paddusb, psubsb, paddsb
		for index in 0 ..< 16 {
			switch opcode {
			case 0xD8:
				result[index] = saturate_unsigned_byte(i32(bytes_a[index]) - i32(bytes_b[index]))
			case 0xDC:
				result[index] = saturate_unsigned_byte(i32(bytes_a[index]) + i32(bytes_b[index]))
			case 0xE8:
				result[index] = saturate_signed_byte(i32(i8(bytes_a[index])) - i32(i8(bytes_b[index])))
			case:
				result[index] = saturate_signed_byte(i32(i8(bytes_a[index])) + i32(i8(bytes_b[index])))
			}
		}
	case 0xD9, 0xDD, 0xE9, 0xED: // psubusw, paddusw, psubsw, paddsw
		words: [8]u16
		for index in 0 ..< 8 {
			switch opcode {
			case 0xD9:
				words[index] = saturate_unsigned_word(i32(words_a[index]) - i32(words_b[index]))
			case 0xDD:
				words[index] = saturate_unsigned_word(i32(words_a[index]) + i32(words_b[index]))
			case 0xE9:
				words[index] = saturate_signed_word(i32(i16(words_a[index])) - i32(i16(words_b[index])))
			case:
				words[index] = saturate_signed_word(i32(i16(words_a[index])) + i32(i16(words_b[index])))
			}
		}
		result = transmute([16]u8)words
	case 0xDA: // pminub
		for index in 0 ..< 16 {
			result[index] = min(bytes_a[index], bytes_b[index])
		}
	case 0xDE: // pmaxub
		for index in 0 ..< 16 {
			result[index] = max(bytes_a[index], bytes_b[index])
		}
	case 0xEA, 0xEE: // pminsw, pmaxsw
		words: [8]u16
		for index in 0 ..< 8 {
			x, y := i16(words_a[index]), i16(words_b[index])
			words[index] = u16(min(x, y) if opcode == 0xEA else max(x, y))
		}
		result = transmute([16]u8)words
	case 0xE0: // pavgb
		for index in 0 ..< 16 {
			result[index] = u8((u32(bytes_a[index]) + u32(bytes_b[index]) + 1) >> 1)
		}
	case 0xE3: // pavgw
		words: [8]u16
		for index in 0 ..< 8 {
			words[index] = u16((u32(words_a[index]) + u32(words_b[index]) + 1) >> 1)
		}
		result = transmute([16]u8)words
	case 0xDB: // pand
		result = transmute([16]u8)[2]u64{qwords_a[0] & qwords_b[0], qwords_a[1] & qwords_b[1]}
	case 0xDF: // pandn
		result = transmute([16]u8)[2]u64{~qwords_a[0] & qwords_b[0], ~qwords_a[1] & qwords_b[1]}
	case 0xEB: // por
		result = transmute([16]u8)[2]u64{qwords_a[0] | qwords_b[0], qwords_a[1] | qwords_b[1]}
	case 0xEF: // pxor
		result = transmute([16]u8)[2]u64{qwords_a[0] ~ qwords_b[0], qwords_a[1] ~ qwords_b[1]}
	case:
		return {}, false
	}
	return result, true
}

// The state of one vector instruction while it decodes and runs.
@(private = "file")
Simd_Step :: struct {
	cpu:      ^Processor_State,
	memory:   []u8,
	cursor:   ^Instruction_Cursor,
	prefixes: Decoded_Prefixes,
	modrm:    Decoded_Modrm,
}

@(private = "file")
simd_prefix_of :: proc "contextless" (prefixes: Decoded_Prefixes) -> Simd_Prefix {
	if prefixes.has_rep || prefixes.has_repne {
		return .Repeat_Not_Equal if prefixes.last_repeat_is_not_equal else .Repeat
	}
	if prefixes.has_operand_size_override {
		return .Operand_Size
	}
	return .None
}

@(private = "file")
simd_invalid :: proc "contextless" (step: ^Simd_Step) -> Step_Outcome {
	return record_fault(step.cpu, step.cursor.start_rip, .Invalid_Opcode, step.cursor.start_rip)
}

@(private = "file")
simd_decode :: proc "contextless" (step: ^Simd_Step) -> Step_Outcome {
	modrm, outcome := decode_modrm(step.cpu, step.memory, step.cursor, step.prefixes)
	step.modrm = modrm
	return outcome
}

@(private = "file")
simd_finish :: proc "contextless" (step: ^Simd_Step) -> Step_Outcome {
	step.cpu.rip = step.cursor.current_rip
	step.cpu.steps_executed += 1
	return .Running
}

@(private = "file")
simd_address :: proc "contextless" (step: ^Simd_Step) -> u64 {
	return resolve_effective_address(step.cpu, step.modrm, step.cursor.current_rip, true)
}

@(private = "file")
simd_destination :: #force_inline proc "contextless" (step: ^Simd_Step) -> [16]u8 {
	return step.cpu.xmm[step.modrm.reg_index & 15]
}

@(private = "file")
simd_set_destination :: #force_inline proc "contextless" (step: ^Simd_Step, value: [16]u8) {
	step.cpu.xmm[step.modrm.reg_index & 15] = value
}

// simd_read_vector reads the r/m operand of 16 bytes. Every legacy form
// with 16 bytes of memory needs them aligned, but movups, movupd and movdqu.
@(private = "file")
simd_read_vector :: proc "contextless" (step: ^Simd_Step, aligned: bool) -> ([16]u8, Step_Outcome) {
	return read_sse_operand(step.cpu, step.memory, step.cursor.start_rip, step.cursor.current_rip, step.modrm, aligned)
}

// simd_read_low reads the r/m operand of a scalar or a half: the low
// bytes of a vector register, or bytes of memory with no alignment.
@(private = "file")
simd_read_low :: proc "contextless" (step: ^Simd_Step, width: Operand_Width) -> (u64, Step_Outcome) {
	if step.modrm.is_register {
		lanes := transmute([2]u64)step.cpu.xmm[step.modrm.rm_register & 15]
		return lanes[0] & width_mask(width), .Running
	}
	return read_memory_width(step.cpu, step.memory, step.cursor.start_rip, simd_address(step), width)
}

@(private = "file")
simd_write_memory :: proc "contextless" (step: ^Simd_Step, width: Operand_Width, value: u64) -> Step_Outcome {
	return write_memory_width(step.cpu, step.memory, step.cursor.start_rip, simd_address(step), width, value)
}

// simd_exceptions_commit merges the raised exceptions into the flags of
// MXCSR. An unmasked one ends the instruction with vector 19: the flags
// change, and no destination does.
@(private = "file")
simd_exceptions_commit :: proc "contextless" (step: ^Simd_Step, raised: Simd_Exceptions) -> Step_Outcome {
	unmasked := simd_exceptions_unmasked(step.cpu.mxcsr, raised)
	step.cpu.mxcsr |= transmute(u32)raised
	if unmasked {
		return record_fault(step.cpu, step.cursor.start_rip, .Simd_Floating_Point, step.cursor.start_rip)
	}
	return .Running
}

@(private = "file")
precision_of :: #force_inline proc "contextless" (prefix: Simd_Prefix) -> Float_Precision {
	return .Double if prefix == .Operand_Size || prefix == .Repeat_Not_Equal else .Single
}

@(private = "file")
scalar_width :: #force_inline proc "contextless" (precision: Float_Precision) -> Operand_Width {
	return .Bits_32 if precision == .Single else .Bits_64
}

// lanes_of gives a vector as lanes of its precision, in u64 words.
@(private = "file")
lanes_of :: proc "contextless" (value: [16]u8, precision: Float_Precision) -> (lanes: [4]u64, count: int) {
	switch precision {
	case .Single:
		singles := transmute([4]u32)value
		return {u64(singles[0]), u64(singles[1]), u64(singles[2]), u64(singles[3])}, 4
	case .Double:
		doubles := transmute([2]u64)value
		return {doubles[0], doubles[1], 0, 0}, 2
	}
	return {}, 0
}

@(private = "file")
vector_of :: proc "contextless" (lanes: [4]u64, precision: Float_Precision) -> [16]u8 {
	switch precision {
	case .Single:
		return transmute([16]u8)[4]u32{u32(lanes[0]), u32(lanes[1]), u32(lanes[2]), u32(lanes[3])}
	case .Double:
		return transmute([16]u8)[2]u64{lanes[0], lanes[1]}
	}
	return {}
}

// simd_read_float_source reads the second operand of a float form: a
// whole aligned vector for a packed form, the low lane for a scalar one.
@(private = "file")
simd_read_float_source :: proc "contextless" (step: ^Simd_Step, precision: Float_Precision, packed: bool) -> (lanes: [4]u64, outcome: Step_Outcome) {
	if packed {
		vector, read_outcome := simd_read_vector(step, true)
		if read_outcome != .Running {
			return {}, read_outcome
		}
		lanes, _ = lanes_of(vector, precision)
		return lanes, .Running
	}
	scalar, read_outcome := simd_read_low(step, scalar_width(precision))
	lanes[0] = scalar
	return lanes, read_outcome
}

// simd_float_arithmetic gives addps to maxsd (0F 58, 59, 5C to 5F).
@(private = "file")
simd_float_arithmetic :: proc "contextless" (step: ^Simd_Step, operation: Float_Operation, prefix: Simd_Prefix) -> Step_Outcome {
	precision := precision_of(prefix)
	packed := prefix == .None || prefix == .Operand_Size
	source, outcome := simd_read_float_source(step, precision, packed)
	if outcome != .Running {
		return outcome
	}
	destination, count := lanes_of(simd_destination(step), precision)
	if !packed {
		count = 1
	}
	raised: Simd_Exceptions
	for index in 0 ..< count {
		lane, lane_raised := float_binary(operation, destination[index], source[index], precision, step.cpu.mxcsr)
		destination[index] = lane
		raised += lane_raised
	}
	if commit := simd_exceptions_commit(step, raised); commit != .Running {
		return commit
	}
	simd_set_destination(step, vector_of(destination, precision))
	return simd_finish(step)
}

@(private = "file")
simd_float_square_root :: proc "contextless" (step: ^Simd_Step, prefix: Simd_Prefix) -> Step_Outcome {
	precision := precision_of(prefix)
	packed := prefix == .None || prefix == .Operand_Size
	source, outcome := simd_read_float_source(step, precision, packed)
	if outcome != .Running {
		return outcome
	}
	destination, count := lanes_of(simd_destination(step), precision)
	if !packed {
		count = 1
	}
	raised: Simd_Exceptions
	for index in 0 ..< count {
		lane, lane_raised := float_square_root(source[index], precision, step.cpu.mxcsr)
		destination[index] = lane
		raised += lane_raised
	}
	if commit := simd_exceptions_commit(step, raised); commit != .Running {
		return commit
	}
	simd_set_destination(step, vector_of(destination, precision))
	return simd_finish(step)
}

@(private = "file")
simd_float_compare :: proc "contextless" (step: ^Simd_Step, prefix: Simd_Prefix) -> Step_Outcome {
	precision := precision_of(prefix)
	packed := prefix == .None || prefix == .Operand_Size
	immediate, fetch_outcome := fetch_u8(step.cpu, step.memory, step.cursor)
	if fetch_outcome != .Running {
		return fetch_outcome
	}
	predicate, _ := enum_word.member_of_word(Compare_Predicate, u64(immediate & 7))
	source, outcome := simd_read_float_source(step, precision, packed)
	if outcome != .Running {
		return outcome
	}
	destination, count := lanes_of(simd_destination(step), precision)
	if !packed {
		count = 1
	}
	all_ones := width_mask(scalar_width(precision))
	raised: Simd_Exceptions
	for index in 0 ..< count {
		holds, lane_raised := float_compare(predicate, destination[index], source[index], precision)
		destination[index] = all_ones if holds else 0
		raised += lane_raised
	}
	if commit := simd_exceptions_commit(step, raised); commit != .Running {
		return commit
	}
	simd_set_destination(step, vector_of(destination, precision))
	return simd_finish(step)
}

@(private = "file")
simd_float_relation :: proc "contextless" (step: ^Simd_Step, prefix: Simd_Prefix, signal_quiet_nan: bool) -> Step_Outcome {
	precision := precision_of(prefix)
	source, outcome := simd_read_low(step, scalar_width(precision))
	if outcome != .Running {
		return outcome
	}
	destination, _ := lanes_of(simd_destination(step), precision)
	relation, raised := float_relation(destination[0], source, precision, signal_quiet_nan)
	if commit := simd_exceptions_commit(step, raised); commit != .Running {
		return commit
	}
	cpu := step.cpu
	set_flag(cpu, RFLAGS_OF, false)
	set_flag(cpu, RFLAGS_SF, false)
	set_flag(cpu, RFLAGS_AF, false)
	set_flag(cpu, RFLAGS_ZF, relation == .Unordered || relation == .Equal)
	set_flag(cpu, RFLAGS_PF, relation == .Unordered)
	set_flag(cpu, RFLAGS_CF, relation == .Unordered || relation == .Less)
	return simd_finish(step)
}

// simd_bitwise gives andps to xorpd (0F 54 to 57), with or without 66.
@(private = "file")
simd_bitwise :: proc "contextless" (step: ^Simd_Step, opcode: u8) -> Step_Outcome {
	source, outcome := simd_read_vector(step, true)
	if outcome != .Running {
		return outcome
	}
	integer_opcode: u8
	switch opcode {
	case 0x54:
		integer_opcode = 0xDB
	case 0x55:
		integer_opcode = 0xDF
	case 0x56:
		integer_opcode = 0xEB
	case:
		integer_opcode = 0xEF
	}
	result, _ := vector_integer_binary(integer_opcode, simd_destination(step), source)
	simd_set_destination(step, result)
	return simd_finish(step)
}

// simd_move_scalar gives movss and movsd (F3 or F2, 0F 10 and 0F 11): a
// load from memory clears the rest of the register; a move between
// registers keeps it.
@(private = "file")
simd_move_scalar :: proc "contextless" (step: ^Simd_Step, precision: Float_Precision, store: bool) -> Step_Outcome {
	width := scalar_width(precision)
	register := step.cpu.xmm[step.modrm.reg_index & 15]
	if store {
		if !step.modrm.is_register {
			low := (transmute([2]u64)register)[0] & width_mask(width)
			if outcome := simd_write_memory(step, width, low); outcome != .Running {
				return outcome
			}
			return simd_finish(step)
		}
		step.cpu.xmm[step.modrm.rm_register & 15] = scalar_merge(step.cpu.xmm[step.modrm.rm_register & 15], register, width)
		return simd_finish(step)
	}
	if step.modrm.is_register {
		simd_set_destination(step, scalar_merge(register, step.cpu.xmm[step.modrm.rm_register & 15], width))
		return simd_finish(step)
	}
	value, outcome := simd_read_low(step, width)
	if outcome != .Running {
		return outcome
	}
	simd_set_destination(step, transmute([16]u8)[2]u64{value, 0})
	return simd_finish(step)
}

// scalar_merge gives target with its low lane of width taken from source.
@(private = "file")
scalar_merge :: proc "contextless" (target, source: [16]u8, width: Operand_Width) -> [16]u8 {
	result := target
	for index in 0 ..< int(width) {
		result[index] = source[index]
	}
	return result
}

// simd_move_half gives movlps, movhps, movlpd, movhpd, movhlps and
// movlhps (0F 12, 13, 16, 17).
@(private = "file")
simd_move_half :: proc "contextless" (step: ^Simd_Step, opcode: u8, prefix: Simd_Prefix) -> Step_Outcome {
	if prefix != .None && prefix != .Operand_Size {
		return simd_invalid(step)
	}
	high := opcode == 0x16 || opcode == 0x17
	store := opcode == 0x13 || opcode == 0x17
	register := transmute([2]u64)simd_destination(step)
	if step.modrm.is_register {
		// Only the forms without 66 and with a load have a register form.
		if store || prefix == .Operand_Size {
			return simd_invalid(step)
		}
		source := transmute([2]u64)step.cpu.xmm[step.modrm.rm_register & 15]
		if high {
			register[1] = source[0] // movlhps
		} else {
			register[0] = source[1] // movhlps
		}
		simd_set_destination(step, transmute([16]u8)register)
		return simd_finish(step)
	}
	lane := 1 if high else 0
	if store {
		if outcome := simd_write_memory(step, .Bits_64, register[lane]); outcome != .Running {
			return outcome
		}
		return simd_finish(step)
	}
	value, outcome := simd_read_low(step, .Bits_64)
	if outcome != .Running {
		return outcome
	}
	register[lane] = value
	simd_set_destination(step, transmute([16]u8)register)
	return simd_finish(step)
}

// simd_unpack_float gives unpcklps, unpckhps, unpcklpd and unpckhpd
// (0F 14 and 15).
@(private = "file")
simd_unpack_float :: proc "contextless" (step: ^Simd_Step, high: bool, prefix: Simd_Prefix) -> Step_Outcome {
	source, outcome := simd_read_vector(step, true)
	if outcome != .Running {
		return outcome
	}
	destination := simd_destination(step)
	result: [16]u8
	if prefix == .Operand_Size {
		opcode: u8 = 0x6D if high else 0x6C
		result, _ = vector_integer_binary(opcode, destination, source)
	} else {
		opcode: u8 = 0x6A if high else 0x62
		result, _ = vector_integer_binary(opcode, destination, source)
	}
	simd_set_destination(step, result)
	return simd_finish(step)
}

@(private = "file")
simd_shuffle_float :: proc "contextless" (step: ^Simd_Step, prefix: Simd_Prefix) -> Step_Outcome {
	immediate, fetch_outcome := fetch_u8(step.cpu, step.memory, step.cursor)
	if fetch_outcome != .Running {
		return fetch_outcome
	}
	source, outcome := simd_read_vector(step, true)
	if outcome != .Running {
		return outcome
	}
	destination := simd_destination(step)
	if prefix == .Operand_Size {
		first := transmute([2]u64)destination
		second := transmute([2]u64)source
		simd_set_destination(step, transmute([16]u8)[2]u64{first[immediate & 1], second[(immediate >> 1) & 1]})
		return simd_finish(step)
	}
	first := transmute([4]u32)destination
	second := transmute([4]u32)source
	result := [4]u32{first[immediate & 3], first[(immediate >> 2) & 3], second[(immediate >> 4) & 3], second[(immediate >> 6) & 3]}
	simd_set_destination(step, transmute([16]u8)result)
	return simd_finish(step)
}

// simd_shuffle_integer gives pshufd, pshufhw and pshuflw (0F 70).
@(private = "file")
simd_shuffle_integer :: proc "contextless" (step: ^Simd_Step, prefix: Simd_Prefix) -> Step_Outcome {
	immediate, fetch_outcome := fetch_u8(step.cpu, step.memory, step.cursor)
	if fetch_outcome != .Running {
		return fetch_outcome
	}
	source, outcome := simd_read_vector(step, true)
	if outcome != .Running {
		return outcome
	}
	switch prefix {
	case .Operand_Size:
		dwords := transmute([4]u32)source
		result: [4]u32
		for index in uint(0) ..< 4 {
			result[index] = dwords[(immediate >> (2 * index)) & 3]
		}
		simd_set_destination(step, transmute([16]u8)result)
	case .Repeat, .Repeat_Not_Equal:
		words := transmute([8]u16)source
		result := words
		base := 4 if prefix == .Repeat else 0
		for index in uint(0) ..< 4 {
			result[base + int(index)] = words[base + int((immediate >> (2 * index)) & 3)]
		}
		simd_set_destination(step, transmute([16]u8)result)
	case .None:
		return simd_invalid(step)
	}
	return simd_finish(step)
}

// simd_shift_immediate gives the groups 0F 71, 72 and 73 with 66: a shift
// of a vector register by an immediate.
@(private = "file")
simd_shift_immediate :: proc "contextless" (step: ^Simd_Step, opcode: u8) -> Step_Outcome {
	if !step.modrm.is_register {
		return simd_invalid(step)
	}
	immediate, fetch_outcome := fetch_u8(step.cpu, step.memory, step.cursor)
	if fetch_outcome != .Running {
		return fetch_outcome
	}
	target := step.modrm.rm_register & 15
	value := step.cpu.xmm[target]
	lane_bits: uint = 16 if opcode == 0x71 else (32 if opcode == 0x72 else 64)
	result: [16]u8
	switch step.modrm.reg_index & 7 {
	case 2:
		result = vector_shift(value, lane_bits, u64(immediate), .Right_Logical)
	case 4:
		if opcode == 0x73 {
			return simd_invalid(step)
		}
		result = vector_shift(value, lane_bits, u64(immediate), .Right_Arithmetic)
	case 6:
		result = vector_shift(value, lane_bits, u64(immediate), .Left)
	case 3:
		if opcode != 0x73 {
			return simd_invalid(step)
		}
		result = vector_byte_shift(value, immediate, false)
	case 7:
		if opcode != 0x73 {
			return simd_invalid(step)
		}
		result = vector_byte_shift(value, immediate, true)
	case:
		return simd_invalid(step)
	}
	step.cpu.xmm[target] = result
	return simd_finish(step)
}

// simd_convert gives the conversions of 0F 2A, 2C, 2D, 5A, 5B and E6.
@(private = "file")
simd_convert :: proc "contextless" (step: ^Simd_Step, opcode: u8, prefix: Simd_Prefix) -> Step_Outcome {
	cpu := step.cpu
	mxcsr := cpu.mxcsr
	switch opcode {
	case 0x2A:
		// cvtsi2ss and cvtsi2sd: an integer of 32 or 64 bits into the low lane.
		if prefix != .Repeat && prefix != .Repeat_Not_Equal {
			return simd_invalid(step)
		}
		width := Operand_Width.Bits_64 if step.prefixes.rex_w else Operand_Width.Bits_32
		value, outcome := read_rm_operand(cpu, step.memory, step.cursor.start_rip, step.cursor.current_rip, step.modrm, width, step.prefixes.has_rex)
		if outcome != .Running {
			return outcome
		}
		precision := precision_of(prefix)
		lanes, _ := lanes_of(simd_destination(step), precision)
		lanes[0] = integer_to_float(value, width, precision)
		simd_set_destination(step, vector_of(lanes, precision))
		return simd_finish(step)
	case 0x2C, 0x2D:
		// cvttss2si, cvttsd2si, cvtss2si and cvtsd2si.
		if prefix != .Repeat && prefix != .Repeat_Not_Equal {
			return simd_invalid(step)
		}
		precision := precision_of(prefix)
		source, outcome := simd_read_low(step, scalar_width(precision))
		if outcome != .Running {
			return outcome
		}
		width := Operand_Width.Bits_64 if step.prefixes.rex_w else Operand_Width.Bits_32
		rounding := Rounding_Control.Toward_Zero if opcode == 0x2C else simd_rounding_control(mxcsr)
		value, raised := float_to_integer(source, precision, width, rounding)
		if commit := simd_exceptions_commit(step, raised); commit != .Running {
			return commit
		}
		write_register(cpu, step.modrm.reg_index, width, step.prefixes.has_rex, value)
		return simd_finish(step)
	case 0x5A:
		switch prefix {
		case .Repeat, .Repeat_Not_Equal:
			// cvtss2sd and cvtsd2ss: the low lane, the rest kept.
			from := precision_of(prefix)
			to := Float_Precision.Double if from == .Single else Float_Precision.Single
			source, outcome := simd_read_low(step, scalar_width(from))
			if outcome != .Running {
				return outcome
			}
			value, raised := float_convert_precision(source, from, mxcsr)
			if commit := simd_exceptions_commit(step, raised); commit != .Running {
				return commit
			}
			lanes, _ := lanes_of(simd_destination(step), to)
			lanes[0] = value
			simd_set_destination(step, vector_of(lanes, to))
		case .None:
			// cvtps2pd: the two low singles, from a register or 8 bytes.
			source, outcome := simd_read_low(step, .Bits_64)
			if outcome != .Running {
				return outcome
			}
			result: [4]u64
			raised: Simd_Exceptions
			for index in 0 ..< 2 {
				lane, lane_raised := float_convert_precision((source >> (32 * uint(index))) & 0xFFFF_FFFF, .Single, mxcsr)
				result[index] = lane
				raised += lane_raised
			}
			if commit := simd_exceptions_commit(step, raised); commit != .Running {
				return commit
			}
			simd_set_destination(step, vector_of(result, .Double))
		case .Operand_Size:
			// cvtpd2ps: two singles in the low half, the high half cleared.
			source, outcome := simd_read_vector(step, true)
			if outcome != .Running {
				return outcome
			}
			doubles := transmute([2]u64)source
			result: [4]u64
			raised: Simd_Exceptions
			for index in 0 ..< 2 {
				lane, lane_raised := float_convert_precision(doubles[index], .Double, mxcsr)
				result[index] = lane
				raised += lane_raised
			}
			if commit := simd_exceptions_commit(step, raised); commit != .Running {
				return commit
			}
			simd_set_destination(step, vector_of(result, .Single))
		}
		return simd_finish(step)
	case 0x5B:
		source, outcome := simd_read_vector(step, true)
		if outcome != .Running {
			return outcome
		}
		dwords := transmute([4]u32)source
		result: [4]u32
		raised: Simd_Exceptions
		switch prefix {
		case .None:
			// cvtdq2ps.
			for index in 0 ..< 4 {
				result[index] = u32(integer_to_float(u64(dwords[index]), .Bits_32, .Single))
			}
		case .Operand_Size, .Repeat:
			// cvtps2dq and cvttps2dq.
			rounding := Rounding_Control.Toward_Zero if prefix == .Repeat else simd_rounding_control(mxcsr)
			for index in 0 ..< 4 {
				lane, lane_raised := float_to_integer(u64(dwords[index]), .Single, .Bits_32, rounding)
				result[index] = u32(lane)
				raised += lane_raised
			}
		case .Repeat_Not_Equal:
			return simd_invalid(step)
		}
		if commit := simd_exceptions_commit(step, raised); commit != .Running {
			return commit
		}
		simd_set_destination(step, transmute([16]u8)result)
		return simd_finish(step)
	case 0xE6:
		switch prefix {
		case .Repeat:
			// cvtdq2pd: the two low integers, from a register or 8 bytes.
			source, outcome := simd_read_low(step, .Bits_64)
			if outcome != .Running {
				return outcome
			}
			simd_set_destination(step, transmute([16]u8)[2]u64{integer_to_float(source & 0xFFFF_FFFF, .Bits_32, .Double), integer_to_float(source >> 32, .Bits_32, .Double)})
		case .Operand_Size, .Repeat_Not_Equal:
			// cvttpd2dq and cvtpd2dq: two integers, the high half cleared.
			source, outcome := simd_read_vector(step, true)
			if outcome != .Running {
				return outcome
			}
			doubles := transmute([2]u64)source
			rounding := Rounding_Control.Toward_Zero if prefix == .Operand_Size else simd_rounding_control(mxcsr)
			result: [4]u32
			raised: Simd_Exceptions
			for index in 0 ..< 2 {
				lane, lane_raised := float_to_integer(doubles[index], .Double, .Bits_32, rounding)
				result[index] = u32(lane)
				raised += lane_raised
			}
			if commit := simd_exceptions_commit(step, raised); commit != .Running {
				return commit
			}
			simd_set_destination(step, transmute([16]u8)result)
		case .None:
			return simd_invalid(step)
		}
		return simd_finish(step)
	}
	return simd_invalid(step)
}

// simd_state_group gives 0F AE: fxsave, fxrstor, ldmxcsr, stmxcsr and
// clflush with memory, and the three fences with a register.
@(private = "file")
simd_state_group :: proc "contextless" (step: ^Simd_Step, prefix: Simd_Prefix) -> Step_Outcome {
	if prefix != .None {
		return simd_invalid(step)
	}
	cpu := step.cpu
	selector := step.modrm.reg_index & 7
	if step.modrm.is_register {
		switch selector {
		case 5, 6, 7:
			// lfence, mfence and sfence: each access of this processor is
			// in order already.
			return simd_finish(step)
		}
		return simd_invalid(step)
	}
	address := simd_address(step)
	switch selector {
	case 0:
		return simd_fxsave(step, address)
	case 1:
		return simd_fxrstor(step, address)
	case 2:
		value, outcome := read_memory_width(cpu, step.memory, step.cursor.start_rip, address, .Bits_32)
		if outcome != .Running {
			return outcome
		}
		if u32(value) & ~MXCSR_MASK != 0 {
			return record_fault(cpu, step.cursor.start_rip, .General_Protection)
		}
		cpu.mxcsr = u32(value)
		return simd_finish(step)
	case 3:
		if outcome := write_memory_width(cpu, step.memory, step.cursor.start_rip, address, .Bits_32, u64(cpu.mxcsr)); outcome != .Running {
			return outcome
		}
		return simd_finish(step)
	case 7:
		// clflush: the processor has no cache; the line must be readable.
		if _, outcome := read_memory_width(cpu, step.memory, step.cursor.start_rip, address, .Bits_8); outcome != .Running {
			return outcome
		}
		return simd_finish(step)
	}
	// xsave, xrstor and xsaveopt: the answer of cpuid names no xsave.
	return simd_invalid(step)
}

@(private = "file")
simd_fxsave :: proc "contextless" (step: ^Simd_Step, address: u64) -> Step_Outcome {
	cpu := step.cpu
	if address & 15 != 0 {
		return record_fault(cpu, step.cursor.start_rip, .General_Protection)
	}
	// The whole area must be writable, though the write stops before its end.
	last := translate_virtual_address(&cpu.tlb, step.memory, cpu.cr3, address + FXSAVE_AREA_BYTES - 1, .User, .Write)
	if last.status != .Ok {
		return record_translation_fault(cpu, step.cursor.start_rip, last)
	}
	area: [FXSAVE_WRITTEN_BYTES]u8
	area[FXSAVE_CONTROL_WORD_OFFSET] = u8(X87_CONTROL_WORD_START & 0xFF)
	area[FXSAVE_CONTROL_WORD_OFFSET + 1] = u8(X87_CONTROL_WORD_START >> 8)
	for index in 0 ..< 4 {
		area[FXSAVE_MXCSR_OFFSET + index] = u8(cpu.mxcsr >> (8 * uint(index)))
		area[FXSAVE_MXCSR_MASK_OFFSET + index] = u8(MXCSR_MASK >> (8 * uint(index)))
	}
	for register, index in cpu.xmm {
		for byte, offset in register {
			area[FXSAVE_XMM_OFFSET + 16 * index + offset] = byte
		}
	}
	result := mmu_write_bytes(&cpu.tlb, step.memory, cpu.cr3, address, .User, area[:])
	if result.status != .Ok {
		return record_translation_fault(cpu, step.cursor.start_rip, result)
	}
	return simd_finish(step)
}

@(private = "file")
simd_fxrstor :: proc "contextless" (step: ^Simd_Step, address: u64) -> Step_Outcome {
	cpu := step.cpu
	if address & 15 != 0 {
		return record_fault(cpu, step.cursor.start_rip, .General_Protection)
	}
	area: [FXSAVE_AREA_BYTES]u8
	result := mmu_read_bytes(&cpu.tlb, step.memory, cpu.cr3, address, .User, .Read, area[:])
	if result.status != .Ok {
		return record_translation_fault(cpu, step.cursor.start_rip, result)
	}
	mxcsr := u32(area[FXSAVE_MXCSR_OFFSET]) | u32(area[FXSAVE_MXCSR_OFFSET + 1]) << 8 | u32(area[FXSAVE_MXCSR_OFFSET + 2]) << 16 | u32(area[FXSAVE_MXCSR_OFFSET + 3]) << 24
	if mxcsr & ~MXCSR_MASK != 0 {
		return record_fault(cpu, step.cursor.start_rip, .General_Protection)
	}
	cpu.mxcsr = mxcsr
	for &register, index in cpu.xmm {
		for &byte, offset in register {
			byte = area[FXSAVE_XMM_OFFSET + 16 * index + offset]
		}
	}
	return simd_finish(step)
}

// simd_mask_move gives maskmovdqu (66 0F F7): the bytes of the first
// register whose byte of the mask has its high bit go to rdi. Each byte is
// checked before the first one moves, so a fault writes none.
@(private = "file")
simd_mask_move :: proc "contextless" (step: ^Simd_Step) -> Step_Outcome {
	if !step.modrm.is_register {
		return simd_invalid(step)
	}
	cpu := step.cpu
	data := cpu.xmm[step.modrm.reg_index & 15]
	mask := cpu.xmm[step.modrm.rm_register & 15]
	base := cpu.registers[int(General_Register.Rdi)]
	if step.prefixes.has_address_size_override {
		base = u64(u32(base))
	}
	if step.prefixes.has_gs_override {
		base += cpu.gs_base
	}
	for index in 0 ..< 16 {
		if mask[index] & 0x80 == 0 {
			continue
		}
		check := translate_virtual_address(&cpu.tlb, step.memory, cpu.cr3, base + u64(index), .User, .Write)
		if check.status != .Ok {
			return record_translation_fault(cpu, step.cursor.start_rip, check)
		}
	}
	for index in 0 ..< 16 {
		if mask[index] & 0x80 == 0 {
			continue
		}
		result := mmu_write_u8(&cpu.tlb, step.memory, cpu.cr3, base + u64(index), .User, data[index])
		if result.status != .Ok {
			return record_translation_fault(cpu, step.cursor.start_rip, result)
		}
	}
	return simd_finish(step)
}

// simd_step runs one instruction of the 0F map that is a vector, MXCSR or
// cache instruction. handled is false for an opcode that is none of them.
@(private)
simd_step :: proc "contextless" (cpu: ^Processor_State, physical_memory: []u8, cursor: ^Instruction_Cursor, prefixes: Decoded_Prefixes, opcode: u8) -> (outcome: Step_Outcome, handled: bool) {
	switch opcode {
	case 0x10 ..= 0x18, 0x28 ..= 0x2F, 0x50 ..= 0x7F, 0xAE, 0xC2, 0xC4 ..= 0xC6, 0xD1 ..= 0xFE:
	case:
		return .Running, false
	}
	step := Simd_Step {
		cpu      = cpu,
		memory   = physical_memory,
		cursor   = cursor,
		prefixes = prefixes,
	}
	prefix := simd_prefix_of(prefixes)
	// Every form has a ModRM byte.
	if decoded := simd_decode(&step); decoded != .Running {
		return decoded, true
	}
	return simd_run(&step, opcode, prefix), true
}

@(private = "file")
simd_run :: proc "contextless" (step: ^Simd_Step, opcode: u8, prefix: Simd_Prefix) -> Step_Outcome {
	cpu := step.cpu
	switch opcode {
	case 0x10, 0x11:
		store := opcode == 0x11
		switch prefix {
		case .Repeat:
			return simd_move_scalar(step, .Single, store)
		case .Repeat_Not_Equal:
			return simd_move_scalar(step, .Double, store)
		case .None, .Operand_Size:
			// movups and movupd.
			if store {
				if outcome := write_sse_operand(cpu, step.memory, step.cursor.start_rip, step.cursor.current_rip, step.modrm, false, simd_destination(step)); outcome != .Running {
					return outcome
				}
				return simd_finish(step)
			}
			value, outcome := simd_read_vector(step, false)
			if outcome != .Running {
				return outcome
			}
			simd_set_destination(step, value)
			return simd_finish(step)
		}
	case 0x12, 0x13, 0x16, 0x17:
		return simd_move_half(step, opcode, prefix)
	case 0x14, 0x15:
		if prefix != .None && prefix != .Operand_Size {
			return simd_invalid(step)
		}
		return simd_unpack_float(step, opcode == 0x15, prefix)
	case 0x18:
		// prefetch: a hint, with no access and no fault.
		return simd_finish(step)
	case 0x28, 0x29, 0x2B:
		// movaps, movapd, movntps and movntpd.
		if prefix != .None && prefix != .Operand_Size {
			return simd_invalid(step)
		}
		if opcode == 0x28 {
			value, outcome := simd_read_vector(step, true)
			if outcome != .Running {
				return outcome
			}
			simd_set_destination(step, value)
			return simd_finish(step)
		}
		if opcode == 0x2B && step.modrm.is_register {
			return simd_invalid(step)
		}
		if outcome := write_sse_operand(cpu, step.memory, step.cursor.start_rip, step.cursor.current_rip, step.modrm, true, simd_destination(step)); outcome != .Running {
			return outcome
		}
		return simd_finish(step)
	case 0x2A, 0x2C, 0x2D, 0x5A, 0x5B, 0xE6:
		return simd_convert(step, opcode, prefix)
	case 0x2E, 0x2F:
		if prefix != .None && prefix != .Operand_Size {
			return simd_invalid(step)
		}
		return simd_float_relation(step, prefix, opcode == 0x2F)
	case 0x50:
		// movmskps and movmskpd: the sign of each lane into a register.
		if !step.modrm.is_register || (prefix != .None && prefix != .Operand_Size) {
			return simd_invalid(step)
		}
		precision := precision_of(prefix)
		lanes, count := lanes_of(cpu.xmm[step.modrm.rm_register & 15], precision)
		sign_shift := uint(31) if precision == .Single else 63
		mask: u64
		for index in 0 ..< count {
			mask |= ((lanes[index] >> sign_shift) & 1) << uint(index)
		}
		cpu.registers[step.modrm.reg_index & 15] = mask
		return simd_finish(step)
	case 0x51:
		return simd_float_square_root(step, prefix)
	case 0x52, 0x53:
		// rsqrtps, rsqrtss, rcpps and rcpss: single precision only.
		if prefix != .None && prefix != .Repeat {
			return simd_invalid(step)
		}
		packed := prefix == .None
		source, outcome := simd_read_float_source(step, .Single, packed)
		if outcome != .Running {
			return outcome
		}
		destination, count := lanes_of(simd_destination(step), .Single)
		if !packed {
			count = 1
		}
		for index in 0 ..< count {
			destination[index] = u64(float_reciprocal(u32(source[index]), opcode == 0x52))
		}
		simd_set_destination(step, vector_of(destination, .Single))
		return simd_finish(step)
	case 0x54 ..= 0x57:
		if prefix != .None && prefix != .Operand_Size {
			return simd_invalid(step)
		}
		return simd_bitwise(step, opcode)
	case 0x58, 0x59, 0x5C, 0x5D, 0x5E, 0x5F:
		operation: Float_Operation
		switch opcode {
		case 0x58:
			operation = .Add
		case 0x59:
			operation = .Multiply
		case 0x5C:
			operation = .Subtract
		case 0x5D:
			operation = .Minimum
		case 0x5E:
			operation = .Divide
		case:
			operation = .Maximum
		}
		return simd_float_arithmetic(step, operation, prefix)
	case 0x6E:
		// movd and movq: a general register or memory into the low lane.
		if prefix != .Operand_Size {
			return simd_invalid(step)
		}
		width := Operand_Width.Bits_64 if step.prefixes.rex_w else Operand_Width.Bits_32
		value, outcome := read_rm_operand(cpu, step.memory, step.cursor.start_rip, step.cursor.current_rip, step.modrm, width, step.prefixes.has_rex)
		if outcome != .Running {
			return outcome
		}
		simd_set_destination(step, transmute([16]u8)[2]u64{value, 0})
		return simd_finish(step)
	case 0x6F, 0x7F:
		// movdqa and movdqu.
		if prefix != .Operand_Size && prefix != .Repeat {
			return simd_invalid(step)
		}
		aligned := prefix == .Operand_Size
		if opcode == 0x6F {
			value, outcome := simd_read_vector(step, aligned)
			if outcome != .Running {
				return outcome
			}
			simd_set_destination(step, value)
			return simd_finish(step)
		}
		if outcome := write_sse_operand(cpu, step.memory, step.cursor.start_rip, step.cursor.current_rip, step.modrm, aligned, simd_destination(step)); outcome != .Running {
			return outcome
		}
		return simd_finish(step)
	case 0x70:
		return simd_shuffle_integer(step, prefix)
	case 0x71, 0x72, 0x73:
		if prefix != .Operand_Size {
			return simd_invalid(step)
		}
		return simd_shift_immediate(step, opcode)
	case 0x7E:
		switch prefix {
		case .Repeat:
			// movq: the low 8 bytes, the high half cleared.
			value, outcome := simd_read_low(step, .Bits_64)
			if outcome != .Running {
				return outcome
			}
			simd_set_destination(step, transmute([16]u8)[2]u64{value, 0})
			return simd_finish(step)
		case .Operand_Size:
			// movd and movq: the low lane into a general register or memory.
			width := Operand_Width.Bits_64 if step.prefixes.rex_w else Operand_Width.Bits_32
			low := (transmute([2]u64)simd_destination(step))[0] & width_mask(width)
			if outcome := write_rm_operand(cpu, step.memory, step.cursor.start_rip, step.cursor.current_rip, step.modrm, width, step.prefixes.has_rex, low); outcome != .Running {
				return outcome
			}
			return simd_finish(step)
		case .None, .Repeat_Not_Equal:
			return simd_invalid(step)
		}
	case 0xAE:
		return simd_state_group(step, prefix)
	case 0xC2:
		return simd_float_compare(step, prefix)
	case 0xC4:
		// pinsrw: a word of a general register or memory into a lane.
		if prefix != .Operand_Size {
			return simd_invalid(step)
		}
		immediate, fetch_outcome := fetch_u8(cpu, step.memory, step.cursor)
		if fetch_outcome != .Running {
			return fetch_outcome
		}
		value, outcome := read_rm_operand(cpu, step.memory, step.cursor.start_rip, step.cursor.current_rip, step.modrm, .Bits_16, step.prefixes.has_rex)
		if outcome != .Running {
			return outcome
		}
		words := transmute([8]u16)simd_destination(step)
		words[immediate & 7] = u16(value)
		simd_set_destination(step, transmute([16]u8)words)
		return simd_finish(step)
	case 0xC5:
		// pextrw: a lane into a general register, zero-extended.
		if prefix != .Operand_Size || !step.modrm.is_register {
			return simd_invalid(step)
		}
		immediate, fetch_outcome := fetch_u8(cpu, step.memory, step.cursor)
		if fetch_outcome != .Running {
			return fetch_outcome
		}
		words := transmute([8]u16)cpu.xmm[step.modrm.rm_register & 15]
		cpu.registers[step.modrm.reg_index & 15] = u64(words[immediate & 7])
		return simd_finish(step)
	case 0xC6:
		if prefix != .None && prefix != .Operand_Size {
			return simd_invalid(step)
		}
		return simd_shuffle_float(step, prefix)
	case 0xD6:
		// movq: the low 8 bytes into memory, or into a register whose high
		// half is cleared.
		if prefix != .Operand_Size {
			return simd_invalid(step)
		}
		low := (transmute([2]u64)simd_destination(step))[0]
		if step.modrm.is_register {
			cpu.xmm[step.modrm.rm_register & 15] = transmute([16]u8)[2]u64{low, 0}
			return simd_finish(step)
		}
		if outcome := simd_write_memory(step, .Bits_64, low); outcome != .Running {
			return outcome
		}
		return simd_finish(step)
	case 0xD7:
		// pmovmskb: the high bit of each byte into a general register.
		if prefix != .Operand_Size || !step.modrm.is_register {
			return simd_invalid(step)
		}
		bytes := cpu.xmm[step.modrm.rm_register & 15]
		mask: u64
		for index in uint(0) ..< 16 {
			mask |= u64(bytes[index] >> 7) << index
		}
		cpu.registers[step.modrm.reg_index & 15] = mask
		return simd_finish(step)
	case 0xE7:
		// movntdq: an aligned store.
		if prefix != .Operand_Size || step.modrm.is_register {
			return simd_invalid(step)
		}
		if outcome := write_sse_operand(cpu, step.memory, step.cursor.start_rip, step.cursor.current_rip, step.modrm, true, simd_destination(step)); outcome != .Running {
			return outcome
		}
		return simd_finish(step)
	case 0xF7:
		if prefix != .Operand_Size {
			return simd_invalid(step)
		}
		return simd_mask_move(step)
	}
	// The integer instructions of the 66 map; without 66 they are the MMX
	// forms, which the answer of cpuid does not name.
	if prefix != .Operand_Size {
		return simd_invalid(step)
	}
	source, outcome := simd_read_vector(step, true)
	if outcome != .Running {
		return outcome
	}
	result, known := vector_integer_binary(opcode, simd_destination(step), source)
	if !known {
		return simd_invalid(step)
	}
	simd_set_destination(step, result)
	return simd_finish(step)
}
