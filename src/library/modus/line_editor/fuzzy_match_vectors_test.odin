#+build !freestanding
package line_editor

import "core:fmt"
import "core:testing"
import "core:time"

// The vector form against the scalar form: the same score, the same
// places, the same match, for every input (docs/SIMD.md, "1. The rule of
// the same bytes").
//
// The speed measure runs only with -define:MEASURE=true: a test checks no
// speed, and the regular test run does not time loops.
MEASURE :: #config(MEASURE, false)

@(private = "file")
expect_same_forms :: proc(t: ^testing.T, query, name: string, label: string) -> bool {
	reference_score, reference_places, reference_matched := fuzzy_match_scalar(query, name)
	vector_score, vector_places, vector_matched := fuzzy_match_vectors(query, name)
	same := reference_score == vector_score && reference_places == vector_places && reference_matched == vector_matched
	testing.expectf(t, same, "%s: query %q, name %q: the scalar form gives %v %d %v, the vector form %v %d %v", label, query, name, reference_matched, reference_score, transmute(u128)reference_places, vector_matched, vector_score, transmute(u128)vector_places)
	return same
}

// name_of_length gives a name of `length` bytes of 'x' with the bytes of
// `ends` at its end.
@(private = "file")
name_of_length :: proc(buffer: []u8, length: int, ends: string) -> string {
	for index in 0 ..< length {
		buffer[index] = 'x'
	}
	copy(buffer[max(length - len(ends), 0):length], ends)
	return string(buffer[:length])
}

// The edges first: the empty query and name, a query longer than the name,
// one byte, the borders of a block (15, 16, 17 bytes), the bound of the
// scan (127, 128, 129 bytes) and of the query (64, 65 bytes), the borders
// of the ranges that the lowering reads, a zero byte against the padding
// of the last block, and bytes past ASCII.
@(test)
vector_form_at_the_edges :: proc(t: ^testing.T) {
	buffer: [NAME_SCAN_LIMIT + 8]u8
	expect_match :: proc(t: ^testing.T, query, name: string, matched: bool, label: string) {
		if expect_same_forms(t, query, name, label) {
			_, _, found := fuzzy_match_vectors(query, name)
			testing.expectf(t, found == matched, "%s: matched is %v, not %v", label, found, matched)
		}
	}
	expect_match(t, "", "", true, "an empty query and an empty name")
	expect_match(t, "", "monitor.count", true, "an empty query")
	expect_match(t, "a", "", false, "an empty name")
	expect_match(t, "abc", "ab", false, "a query longer than the name")
	expect_match(t, "a", "a", true, "one byte")
	expect_match(t, "A", "a", true, "one byte in upper case")
	expect_match(t, "b", "a", false, "one byte that differs")
	for length in ([?]int{15, 16, 17, 31, 32, 33}) {
		label := fmt.tprintf("a name of %d bytes, the match at its last byte", length)
		expect_match(t, "xq", name_of_length(buffer[:], length, "q"), true, label)
		expect_match(t, "qx", name_of_length(buffer[:], length, "q"), false, label)
	}
	// The bound of the scan: byte 127 is read, byte 128 is not.
	expect_match(t, "q", name_of_length(buffer[:], NAME_SCAN_LIMIT - 1, "q"), true, "the match at byte 126")
	expect_match(t, "q", name_of_length(buffer[:], NAME_SCAN_LIMIT, "q"), true, "the match at byte 127, the last that the match reads")
	expect_match(t, "q", name_of_length(buffer[:], NAME_SCAN_LIMIT + 1, "q"), false, "the match at byte 128, past the bound")
	expect_match(t, "xxxq", name_of_length(buffer[:], NAME_SCAN_LIMIT, "q"), true, "a window at the end of the bound")
	// The query bound: 64 bytes match, 65 bytes match nothing.
	query: [QUERY_LIMIT + 1]u8
	for &value in query {
		value = 'x'
	}
	expect_match(t, string(query[:QUERY_LIMIT]), name_of_length(buffer[:], NAME_SCAN_LIMIT, ""), true, "a query of 64 bytes")
	expect_match(t, string(query[:]), name_of_length(buffer[:], NAME_SCAN_LIMIT, ""), false, "a query of 65 bytes")
	// The neighbours of the letters: '@' and '[' are no letter, and '`'
	// and '{' are not the lower case of one.
	expect_match(t, "@", "@", true, "@")
	expect_match(t, "`", "@", false, "` is not the lower case of @")
	expect_match(t, "{", "[", false, "{ is not the lower case of [")
	expect_match(t, "z", "Z", true, "Z")
	expect_match(t, "Z", "z", true, "z")
	// A zero byte matches a zero byte of the name, never the padding of
	// the last block. Each control character is the replacement character
	// for the scalar form, so two control characters are equal.
	expect_match(t, "\x00", "ab", false, "a zero byte against the padding")
	expect_match(t, "\x00", "a\x00b", true, "a zero byte of the name")
	expect_match(t, "\x00", "a\x7fb", true, "a zero byte and the byte 7F")
	expect_match(t, "\x1f", "a\x01b", true, "two control bytes")
	expect_match(t, " ", "a\x1fb", false, "a space is no control byte")
	// Past ASCII: the scalar form decides.
	expect_match(t, "é", "print(\"été\")", true, "é in a name past ASCII")
	expect_match(t, "e", "été", false, "e in a name past ASCII")
	expect_match(t, "t", "été", true, "t in a name past ASCII")
	expect_match(t, "é", "ete", false, "é in a name of ASCII")
	expect_match(t, "\xff", "ete", false, "an invalid byte in the query")
	expect_match(t, "\xff", "e\x01e", true, "an invalid byte of the query and a control byte of the name")
	expect_match(t, "mon", "\x01\x02mon\xff", true, "an invalid byte in the name")
	expect_match(t, "a", "\x7f\x7fa", true, "the largest byte of ASCII")
}

// A generator with a fixed seed: each host gets the same inputs.
@(private = "file")
Generator :: struct {
	state: u64,
}

@(private = "file")
generator_next :: proc(generator: ^Generator) -> u64 {
	generator.state ~= generator.state << 13
	generator.state ~= generator.state >> 7
	generator.state ~= generator.state << 17
	return generator.state
}

@(private = "file")
generator_below :: proc(generator: ^Generator, bound: int) -> int {
	return int(generator_next(generator) % u64(bound))
}

// The pieces of a random name: letters of both cases and their neighbours,
// the separators of the score, a digit, characters past ASCII, an invalid
// byte, a zero byte, a control byte.
@(private = "file")
FUZZ_PIECES := [?]string{"a", "b", "c", "m", "n", "o", "t", "x", "z", "A", "M", "Z", ".", "_", "/", " ", "0", "9", "@", "[", "`", "{", "é", "É", "\xff", "\x00", "\x7f", "\x01"}

FUZZ_SEED :: 0x9E37_79B9_7F4A_7C15
FUZZ_CASES :: 200_000

// Random queries and names, score for score. A query is most often a part
// of its name, with its case changed, so that most cases match and the two
// passes run; the lengths reach past each bound.
@(test)
vector_form_gives_the_result_of_the_scalar_form :: proc(t: ^testing.T) {
	generator := Generator{FUZZ_SEED}
	name_bytes: [NAME_SCAN_LIMIT + 32]u8
	query_bytes: [QUERY_LIMIT + 8]u8
	matched_cases := 0
	for case_number in 0 ..< FUZZ_CASES {
		state_before := generator.state
		// Mostly ASCII names, where the vector form runs; one in eight
		// takes a piece past ASCII.
		pieces := generator_below(&generator, 8) == 0 ? len(FUZZ_PIECES) : len(FUZZ_PIECES) - 6
		target_length := generator_below(&generator, len(name_bytes) + 1)
		name_length := 0
		for name_length < target_length {
			piece := FUZZ_PIECES[generator_below(&generator, pieces)]
			if name_length + len(piece) > target_length {
				break
			}
			copy(name_bytes[name_length:], piece)
			name_length += len(piece)
		}
		name := string(name_bytes[:name_length])
		query_length := 0
		if generator_below(&generator, 4) == 0 {
			// A random query.
			target := generator_below(&generator, len(query_bytes) + 1)
			for query_length < target {
				piece := FUZZ_PIECES[generator_below(&generator, pieces)]
				if query_length + len(piece) > target {
					break
				}
				copy(query_bytes[query_length:], piece)
				query_length += len(piece)
			}
		} else {
			// Bytes of the name in their order, the case of a letter
			// changed now and then.
			for index in 0 ..< name_length {
				if query_length < len(query_bytes) && generator_below(&generator, 6) == 0 {
					value := name_bytes[index]
					if value >= 'a' && value <= 'z' && generator_below(&generator, 2) == 0 {
						value -= 'a' - 'A'
					}
					query_bytes[query_length] = value
					query_length += 1
				}
			}
		}
		query := string(query_bytes[:query_length])
		label := fmt.tprintf("case %d of the seed %x (generator state %x)", case_number, u64(FUZZ_SEED), state_before)
		if !expect_same_forms(t, query, name, label) {
			return
		}
		if _, _, matched := fuzzy_match_scalar(query, name); matched {
			matched_cases += 1
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("line_editor: the vector form gave the result of the scalar form in %d random cases of the seed %x, %d of them a match", FUZZ_CASES, u64(FUZZ_SEED), matched_cases)
}

// ---- The measure: names matched per second, scalar against vector.

@(private = "file")
SERVICE_WORDS := [?]string{"monitor", "storage", "manual", "compositor", "settings", "date", "network", "console", "debugger", "scheduler", "remote", "processes", "cryptography", "drawing", "sound"}
@(private = "file")
EXPORT_WORDS := [?]string{"count", "counts", "named", "write", "read", "restore", "objects", "segments", "modules", "show", "about", "signature", "set", "font", "now", "pointer", "windows", "versions", "clone", "compare", "served", "processes", "hash", "expand", "memory", "watch", "strategy", "stores", "size"}
@(private = "file")
FOLDER_WORDS := [?]string{"src", "library", "support", "contract", "private", "modules", "system", "line_editor", "graphics", "palette", "compositor", "console", "kernel", "md", "features", "docs", "tools", "modustool", "machine", "storage"}

// realistic_names writes `count` names: one third exports
// (`service.export_word`), one third module names (`word_word`), one third
// file paths (`src/library/modus/line_editor/word_word.odin`).
@(private = "file")
realistic_names :: proc(count: int, bytes: ^[dynamic]u8, names: ^[dynamic]string) {
	generator := Generator{0x2545_F491_4F6C_DD1D}
	clear(bytes)
	clear(names)
	ends := make([dynamic]int, context.temp_allocator)
	for number in 0 ..< count {
		switch number % 3 {
		case 0:
			append(bytes, SERVICE_WORDS[generator_below(&generator, len(SERVICE_WORDS))])
			append(bytes, ".")
			append(bytes, EXPORT_WORDS[generator_below(&generator, len(EXPORT_WORDS))])
			if generator_below(&generator, 2) == 0 {
				append(bytes, "_")
				append(bytes, EXPORT_WORDS[generator_below(&generator, len(EXPORT_WORDS))])
			}
		case 1:
			append(bytes, EXPORT_WORDS[generator_below(&generator, len(EXPORT_WORDS))])
			append(bytes, "_")
			append(bytes, SERVICE_WORDS[generator_below(&generator, len(SERVICE_WORDS))])
		case 2:
			for _ in 0 ..< 2 + generator_below(&generator, 4) {
				append(bytes, FOLDER_WORDS[generator_below(&generator, len(FOLDER_WORDS))])
				append(bytes, "/")
			}
			append(bytes, EXPORT_WORDS[generator_below(&generator, len(EXPORT_WORDS))])
			append(bytes, "_")
			append(bytes, EXPORT_WORDS[generator_below(&generator, len(EXPORT_WORDS))])
			append(bytes, generator_below(&generator, 2) == 0 ? ".odin" : ".md")
		}
		append(&ends, len(bytes))
	}
	start := 0
	for end in ends {
		append(names, string(bytes[start:end]))
		start = end
	}
}

// Prints the names that each form matches in one second, for 100, 10 000
// and 100 000 names and four queries. It fails only when the two forms
// match a different count of names; a time is a measure, never a bound.
// Opt-in: runs only with -define:MEASURE=true.
@(test)
fuzzy_match_speed_of_each_form :: proc(t: ^testing.T) {
	if !MEASURE {
		return
	}
	bytes := make([dynamic]u8)
	defer delete(bytes)
	names := make([dynamic]string)
	defer delete(names)
	QUERIES :: [?]string{"mcnt", "stwr", "srclinedit", "zqj"}
	MATCHES_PER_MEASURE :: 300_000
	for count in ([?]int{100, 10_000, 100_000}) {
		realistic_names(count, &bytes, &names)
		for query in QUERIES {
			rounds := max(1, MATCHES_PER_MEASURE / count)
			scalar_matched, vector_matched := 0, 0
			started := time.tick_now()
			for _ in 0 ..< rounds {
				for name in names {
					if _, _, matched := fuzzy_match_scalar(query, name); matched {
						scalar_matched += 1
					}
				}
			}
			scalar_time := time.tick_since(started)
			started = time.tick_now()
			for _ in 0 ..< rounds {
				for name in names {
					if _, _, matched := fuzzy_match_vectors(query, name); matched {
						vector_matched += 1
					}
				}
			}
			vector_time := time.tick_since(started)
			testing.expectf(t, scalar_matched == vector_matched, "%q over %d names: the scalar form matched %d, the vector form %d", query, count, scalar_matched, vector_matched)
			per_second :: proc(names: int, spent: time.Duration) -> f64 {
				return f64(names) / max(time.duration_seconds(spent), 1e-9)
			}
			scalar_rate := per_second(rounds * count, scalar_time)
			vector_rate := per_second(rounds * count, vector_time)
			fmt.printfln("line_editor: %q over %d names (%d match): the scalar form %.1f million names a second, the vector form %.1f million, %.1f times", query, count, scalar_matched / rounds, scalar_rate / 1e6, vector_rate / 1e6, vector_rate / scalar_rate)
		}
	}
}
