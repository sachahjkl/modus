// Exact integer unit algebra and border conversion for Lex typed unit literals
// (src/md/features/declarations.md, "Lex v3 language extensions").
//
// Enforces exact overflow-checked arithmetic across value_kinds.Integer_Unit:
//   - Size-bytes family: bytes (1), KiB (1024), pages (4096), MiB (1048576).
//   - Size-blocks family: blocks only (incompatible with byte-sized units).
//   - Time family: ns (1), us (1000), ms (1_000_000), s (1_000_000_000).
// Zero silent truncation and zero wrapping.
package lex_evaluator

import "modus:console_language"
import "modus:contract/enum_word"
import "modus:contract/value_kinds"

// Closed set of unit dimension families.
@(private)
Unit_Family :: enum u8 {
	None        = 0,
	Size_Bytes  = 1,
	Size_Blocks = 2,
	Time        = 3,
}

// Result of converting or aligning integer units.
Unit_Convert_Status :: enum u8 {
	Ok           = 0,
	Incompatible = 1,
	Non_Exact    = 2,
	Overflow     = 3,
}

@(private)
unit_family_and_scale :: proc "contextless" (u: value_kinds.Integer_Unit) -> (family: Unit_Family, scale: i64) {
	if !value_kinds.integer_unit_valid(u) {
		return .None, 1
	}
	switch u.kind {
	case .None:
		return .None, 1
	case .Size:
		size_unit, ok := enum_word.member_of_word(value_kinds.Size_Unit, u64(u.unit))
		if !ok {
			return .None, 1
		}
		switch size_unit {
		case .Bytes:     return .Size_Bytes, 1
		case .Kibibytes: return .Size_Bytes, 1024
		case .Pages:     return .Size_Bytes, 4096
		case .Mebibytes: return .Size_Bytes, 1024 * 1024
		case .Blocks:    return .Size_Blocks, 1
		}
	case .Time:
		dur_unit, ok := enum_word.member_of_word(value_kinds.Duration_Unit, u64(u.unit))
		if !ok {
			return .None, 1
		}
		switch dur_unit {
		case .Nanoseconds:  return .Time, 1
		case .Microseconds: return .Time, 1_000
		case .Milliseconds: return .Time, 1_000_000
		case .Seconds:      return .Time, 1_000_000_000
		}
	case .Number, .Handle, .Value, .Grant, .Status, .Type, .Operation, .Command, .Module, .File, .Guide, .Term, .Version, .Yes, .No, .Procedure, .Constant, .Variable:
	}
	return .None, 1
}

// align_integer_units converts (a_val, a_u) and (b_val, b_u) to their common
// finer unit when they belong to the same exact family. Refuses mismatched
// dimensions, blocks vs byte-sizes, and unit vs dimensionless.
align_integer_units :: proc "contextless" (a_val, b_val: i64, a_u, b_u: value_kinds.Integer_Unit) -> (la, rb: i64, out_u: value_kinds.Integer_Unit, status: Unit_Convert_Status) {
	if a_u == b_u {
		return a_val, b_val, a_u, .Ok
	}
	fa, sa := unit_family_and_scale(a_u)
	fb, sb := unit_family_and_scale(b_u)
	if fa != fb || fa == .None || fa == .Size_Blocks {
		return 0, 0, {}, .Incompatible
	}
	if sa < sb {
		ratio := sb / sa
		scaled, fits := console_language.integer_multiply(b_val, ratio)
		if !fits {
			return 0, 0, {}, .Overflow
		}
		return a_val, scaled, a_u, .Ok
	}
	ratio := sa / sb
	scaled, fits := console_language.integer_multiply(a_val, ratio)
	if !fits {
		return 0, 0, {}, .Overflow
	}
	return scaled, b_val, b_u, .Ok
}

// convert_integer_unit converts `val` from unit `from` to unit `to` with exact
// integer arithmetic. When `allow_plain_into_unit` is true (export, console,
// record, and plan borders), a dimensionless integer passes through unchanged.
// When false (explicit `: Integer[Unit]` function parameter annotations), a
// dimensionless integer is refused.
convert_integer_unit :: proc "contextless" (val: i64, from, to: value_kinds.Integer_Unit, allow_plain_into_unit: bool) -> (out: i64, status: Unit_Convert_Status) {
	if from == to {
		return val, .Ok
	}
	if from.kind == .None {
		if allow_plain_into_unit {
			return val, .Ok
		}
		return 0, .Incompatible
	}
	if to.kind == .None {
		return 0, .Incompatible
	}
	ff, sf := unit_family_and_scale(from)
	ft, st := unit_family_and_scale(to)
	if ff != ft || ff == .None || ff == .Size_Blocks {
		return 0, .Incompatible
	}
	if sf >= st {
		ratio := sf / st
		scaled, fits := console_language.integer_multiply(val, ratio)
		if !fits {
			return 0, .Overflow
		}
		return scaled, .Ok
	}
	ratio := st / sf
	if val % ratio != 0 {
		return 0, .Non_Exact
	}
	return val / ratio, .Ok
}
