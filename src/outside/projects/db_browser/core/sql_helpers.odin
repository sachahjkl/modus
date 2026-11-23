// SQL identifier escaping, query templates, error line/column lookup, and
// freestanding value formatting for db_browser (src/md/features/db_browser.md).
package db_browser_core

import "modus:contract/text_encoding"

// Inline capacity: sidebar click previews up to 500 rows for instant browsing;
// the principal can change or remove LIMIT in the SQL editor to read more.
BROWSE_ROW_LIMIT :: 500

// Format property: SQLite table/column names shown in sidebar queries.
SQL_IDENTIFIER_MAX_BYTES :: 128

// Default SQL shown when a new empty database opens.
DEFAULT_SQL :: "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name;"

// escape_sql_identifier doubles every '"' inside a SQL identifier so it can be
// safely enclosed in double quotes. Refuses empty names, names containing NUL,
// non-UTF-8 sequences, or output buffer overflow.
escape_sql_identifier :: proc "contextless" (name: string, out: []u8) -> (written: int, ok: bool) {
	raw := transmute([]u8)name
	if len(raw) == 0 || len(raw) > SQL_IDENTIFIER_MAX_BYTES {
		return 0, false
	}
	if !text_encoding.text_valid(raw) {
		return 0, false
	}
	pos := 0
	for b in raw {
		if b == 0 {
			return 0, false
		}
		if b == '"' {
			if pos + 2 > len(out) {
				return 0, false
			}
			out[pos] = '"'
			out[pos + 1] = '"'
			pos += 2
		} else {
			if pos + 1 > len(out) {
				return 0, false
			}
			out[pos] = b
			pos += 1
		}
	}
	return pos, true
}

// format_browse_table_sql writes `SELECT * FROM "<escaped>" LIMIT 500;`.
format_browse_table_sql :: proc "contextless" (table_name: string, out: []u8) -> (sql: string, ok: bool) {
	prefix := "SELECT * FROM \""
	suffix := "\" LIMIT 500;"
	if len(out) < len(prefix) + len(suffix) + 1 {
		return "", false
	}
	pos := copy(out, prefix)
	escaped_len, escaped_ok := escape_sql_identifier(table_name, out[pos:len(out) - len(suffix)])
	if !escaped_ok {
		return "", false
	}
	pos += escaped_len
	pos += copy(out[pos:], suffix)
	return string(out[:pos]), true
}

// format_table_info_sql writes `PRAGMA table_info("<escaped>");`.
format_table_info_sql :: proc "contextless" (table_name: string, out: []u8) -> (sql: string, ok: bool) {
	prefix := "PRAGMA table_info(\""
	suffix := "\");"
	if len(out) < len(prefix) + len(suffix) + 1 {
		return "", false
	}
	pos := copy(out, prefix)
	escaped_len, escaped_ok := escape_sql_identifier(table_name, out[pos:len(out) - len(suffix)])
	if !escaped_ok {
		return "", false
	}
	pos += escaped_len
	pos += copy(out[pos:], suffix)
	return string(out[:pos]), true
}

// sql_error_line_and_column converts a 0-based byte offset from sqlite3_error_offset
// into 1-based line and column numbers for editor highlighting.
sql_error_line_and_column :: proc "contextless" (sql: string, byte_offset: int) -> (line: int, column: int, valid: bool) {
	if byte_offset < 0 || byte_offset > len(sql) {
		return 0, 0, false
	}
	line = 1
	column = 1
	raw := transmute([]u8)sql
	i := 0
	for i < byte_offset {
		if raw[i] == '\n' {
			line += 1
			column = 1
			i += 1
		} else {
			_, step, _ := text_encoding.character_decode(raw, i)
			if step <= 0 {
				step = 1
			}
			column += 1
			i += step
		}
	}
	return line, column, true
}

// append_text appends s to out[pos^:] and advances pos^, clamping safely.
append_text :: proc "contextless" (out: []u8, pos: ^int, s: string) {
	if pos^ >= len(out) {
		return
	}
	n := copy(out[pos^:], s)
	pos^ += n
}

// format_u64 writes an unsigned decimal integer into out and returns the slice.
format_u64 :: proc "contextless" (value: u64, out: []u8) -> string {
	if len(out) == 0 {
		return ""
	}
	if value == 0 {
		out[0] = '0'
		return string(out[:1])
	}
	digits: [24]u8
	count := 0
	v := value
	for v > 0 {
		digits[count] = u8('0' + v % 10)
		v /= 10
		count += 1
	}
	n := min(count, len(out))
	for i in 0 ..< n {
		out[i] = digits[count - 1 - i]
	}
	return string(out[:n])
}

// format_i64 writes a signed decimal integer into out without overflowing on min(i64).
format_i64 :: proc "contextless" (value: i64, out: []u8) -> string {
	if len(out) == 0 {
		return ""
	}
	if value >= 0 {
		return format_u64(u64(value), out)
	}
	out[0] = '-'
	// Two's complement magnitude handles min(i64) cleanly.
	mag := u64(0) - u64(value)
	rest := format_u64(mag, out[1:])
	return string(out[:1 + len(rest)])
}

// format_blob_badge writes `<N B>` for a BLOB cell of N bytes.
format_blob_badge :: proc "contextless" (byte_length: i64, out: []u8) -> string {
	pos := 0
	append_text(out, &pos, "<")
	num_buf: [24]u8
	n := max(byte_length, 0)
	append_text(out, &pos, format_u64(u64(n), num_buf[:]))
	append_text(out, &pos, " B>")
	return string(out[:pos])
}

// format_f64_bits formats raw IEEE-754 double bits without libc or core:fmt.
// Handles NaN, +/-Inf, -0.0, exact integers, and up to 6 fractional digits
// with trailing zeros stripped.
format_f64_bits :: proc "contextless" (bits: u64, out: []u8) -> string {
	if len(out) == 0 {
		return ""
	}
	sign := (bits >> 63) != 0
	exp := (bits >> 52) & 0x7FF
	mant := bits & ((u64(1) << 52) - 1)
	if exp == 0x7FF {
		if mant != 0 {
			return string(out[:copy(out, "NaN")])
		}
		return string(out[:copy(out, sign ? "-Inf" : "Inf")])
	}
	if exp == 0 && mant == 0 {
		return string(out[:copy(out, sign ? "-0.0" : "0.0")])
	}
	val := transmute(f64)bits
	pos := 0
	if sign {
		append_text(out, &pos, "-")
		val = -val
	}
	// Very large or very small magnitudes use compact scientific notation.
	if val >= 1e15 || val < 1e-4 {
		e := 0
		scaled := val
		for scaled >= 10.0 && e < 400 {
			scaled /= 10.0
			e += 1
		}
		for scaled < 1.0 && e > -400 {
			scaled *= 10.0
			e -= 1
		}
		int_part := u64(scaled)
		frac_scaled := u64((scaled - f64(int_part)) * 1_000_000.0 + 0.5)
		if frac_scaled >= 1_000_000 {
			int_part += 1
			frac_scaled -= 1_000_000
		}
		num_buf: [24]u8
		append_text(out, &pos, format_u64(int_part, num_buf[:]))
		append_fraction(out, &pos, frac_scaled, 6, keep_zero = false)
		append_text(out, &pos, e >= 0 ? "e+" : "e-")
		abs_e := e >= 0 ? u64(e) : u64(-e)
		append_text(out, &pos, format_u64(abs_e, num_buf[:]))
		return string(out[:pos])
	}
	int_part := u64(val)
	rem := val - f64(int_part)
	frac_scaled := u64(rem * 1_000_000.0 + 0.5)
	if frac_scaled >= 1_000_000 {
		int_part += 1
		frac_scaled -= 1_000_000
	}
	num_buf: [24]u8
	append_text(out, &pos, format_u64(int_part, num_buf[:]))
	append_fraction(out, &pos, frac_scaled, 6, keep_zero = true)
	return string(out[:pos])
}

@(private = "file")
append_fraction :: proc "contextless" (out: []u8, pos: ^int, scaled: u64, digits: int, keep_zero: bool) {
	buf: [8]u8
	v := scaled
	for i := digits - 1; i >= 0; i -= 1 {
		buf[i] = u8('0' + v % 10)
		v /= 10
	}
	end := digits
	for end > 0 && buf[end - 1] == '0' {
		end -= 1
	}
	if end == 0 {
		if keep_zero {
			append_text(out, pos, ".0")
		}
		return
	}
	append_text(out, pos, ".")
	append_text(out, pos, string(buf[:end]))
}

// sanitize_single_line_text copies UTF-8 text into out, replacing control bytes
// (newline, carriage return, tab, C0/DEL) with spaces while preserving UTF-8 boundaries.
sanitize_single_line_text :: proc "contextless" (src: []u8, out: []u8) -> int {
	pos := 0
	i := 0
	for i < len(src) && pos < len(out) {
		b := src[i]
		if b < 0x20 || b == 0x7F {
			out[pos] = ' '
			pos += 1
			i += 1
			continue
		}
		if b < 0x80 {
			out[pos] = b
			pos += 1
			i += 1
			continue
		}
		_, step, valid := text_encoding.character_decode(src, i)
		if !valid || step <= 0 {
			out[pos] = '?'
			pos += 1
			i += 1
			continue
		}
		if pos + step > len(out) {
			break
		}
		copy(out[pos:][:step], src[i:][:step])
		pos += step
		i += step
	}
	return pos
}

// format_status_metrics formats the right side of the status band, stating each
// fact once: `<rows> rows · <cols> cols · <size> KiB · v<gen>`.
format_status_metrics :: proc "contextless" (
	out: []u8,
	rows: int,
	cols: int,
	database_bytes: u64,
	generation: i64,
	truncated: bool,
	read_only: bool,
) -> string {
	pos := 0
	num: [24]u8
	append_text(out, &pos, format_u64(u64(max(rows, 0)), num[:]))
	append_text(out, &pos, truncated ? "+ rows" : (rows == 1 ? " row" : " rows"))
	append_text(out, &pos, " · ")
	append_text(out, &pos, format_u64(u64(max(cols, 0)), num[:]))
	append_text(out, &pos, cols == 1 ? " col" : " cols")
	append_text(out, &pos, " · ")
	kib := (database_bytes + 1023) / 1024
	append_text(out, &pos, format_u64(kib, num[:]))
	append_text(out, &pos, " KiB")
	if generation > 0 {
		append_text(out, &pos, " · v")
		append_text(out, &pos, format_i64(generation, num[:]))
	}
	if read_only {
		append_text(out, &pos, " · read only")
	}
	return string(out[:pos])
}
