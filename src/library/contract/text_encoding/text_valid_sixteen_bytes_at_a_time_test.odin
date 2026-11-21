#+build !freestanding
package text_encoding

import "core:fmt"
import "core:testing"
import "core:time"

// both_forms_answer checks that the two forms of text_valid give the
// expected answer for bytes, and that neither writes to them.
@(private = "file")
both_forms_answer :: proc(t: ^testing.T, bytes: []u8, expected: bool, loc := #caller_location) -> bool {
	copy_before := make([]u8, len(bytes))
	defer delete(copy_before)
	copy(copy_before, bytes)
	reference := text_valid_byte_by_byte(bytes)
	in_groups := text_valid_sixteen_bytes_at_a_time(bytes)
	unchanged := string(copy_before) == string(bytes)
	good := reference == expected && in_groups == expected && unchanged && text_valid(bytes) == expected
	testing.expectf(t, good, "the bytes % x: expected %v, the reference gave %v, the groups gave %v, unchanged %v", bytes, expected, reference, in_groups, unchanged, loc = loc)
	return good
}

// The sequences that the tests place at each offset of a buffer of ASCII.
@(private = "file")
Placed_Sequence :: struct {
	bytes: string,
	valid: bool,
}

@(private = "file")
placed_sequences := [?]Placed_Sequence {
	{" ", true}, // C2 A0: the first character after the controls of C1.
	{"é", true},
	{"߿", true},
	{"ࠀ", true}, // E0 A0 80: the first character of three bytes.
	{"€", true},
	{"퟿", true}, // ED 9F BF: the last before the surrogates.
	{"", true},
	{"￿", true},
	{"\U00010000", true}, // F0 90 80 80: the first character of four bytes.
	{"\U0001f600", true},
	{"\U00100000", true}, // F4 80 80 80.
	{"\U0010ffff", true}, // F4 8F BF BF: the last code point.
	{"\x80", false}, // A lone continuation.
	{"\xbf", false},
	{"\xbf\xbf", false},
	{"\xc3", false}, // Cut short, before an ASCII byte or at the end.
	{"\xe2\x82", false},
	{"\xf0\x9f\x98", false},
	{"\xc0\x80", false}, // Overlong forms.
	{"\xc1\xbf", false},
	{"\xe0\x80\x80", false},
	{"\xe0\x9f\xbf", false},
	{"\xf0\x80\x80\x80", false},
	{"\xf0\x8f\xbf\xbf", false},
	{"\xed\xa0\x80", false}, // Surrogates.
	{"\xed\xbf\xbf", false},
	{"\xf4\x90\x80\x80", false}, // Above U+10FFFF.
	{"\xf4\xbf\xbf\xbf", false},
	{"\xf5\x80\x80\x80", false},
	{"\xf8\x88\x80\x80\x80", false},
	{"\xfe", false},
	{"\xff", false},
	{"\xc3\xa9\xa9", false}, // Too many continuations.
	{"\xe2\x82\xac\x80", false},
	{"\xf0\x9f\x98\x80\x80", false},
	{"\xc3\x28", false}, // A lead, then no continuation.
	{"\xe2\x28\xa1", false},
	{"\xe2\x82\x28", false},
	{"\xf0\x9f\x28\x80", false},
	{"\x00", false}, // The controls of C0, DEL and C1.
	{"\x09", false},
	{"\x0a", false},
	{"\x1f", false},
	{"\x7f", false},
	{"\xc2\x80", false},
	{"\xc2\x9f", false},
}

// The edges of the length first: each length around a group, with no
// character outside ASCII, then with the last byte a control.
@(test)
lengths_around_a_group_give_the_answer_of_the_reference :: proc(t: ^testing.T) {
	buffer: [64]u8
	for length in ([?]int{0, 1, 2, 15, 16, 17, 31, 32, 33, 47, 48, 49, 63, 64}) {
		for &value in buffer[:length] {
			value = 'a'
		}
		both_forms_answer(t, buffer[:length], true)
		if length > 0 {
			buffer[length - 1] = 0x1F
			both_forms_answer(t, buffer[:length], false)
			buffer[length - 1] = 0x20
			both_forms_answer(t, buffer[:length], true)
			buffer[length - 1] = 0x7E
			both_forms_answer(t, buffer[:length], true)
			buffer[length - 1] = 0x7F
			both_forms_answer(t, buffer[:length], false)
		}
	}
}

// Each sequence at each place of buffers of each length from its own
// length to 50: so each sequence ends a text, starts one, and straddles
// each boundary of 16 bytes at each of its bytes.
@(test)
each_sequence_at_each_place_gives_its_answer :: proc(t: ^testing.T) {
	buffer: [64]u8
	for sequence in placed_sequences {
		for length in len(sequence.bytes) ..= 50 {
			for place in 0 ..= length - len(sequence.bytes) {
				for &value in buffer[:length] {
					value = 'a'
				}
				copy(buffer[place:], sequence.bytes)
				if !both_forms_answer(t, buffer[:length], sequence.valid) {
					fmt.printfln("the sequence % x at %d of %d bytes", transmute([]u8)sequence.bytes, place, length)
					return
				}
			}
		}
	}
}

// Valid texts of each kind, longer than a group.
@(test)
valid_texts_of_each_kind_pass_in_groups :: proc(t: ^testing.T) {
	texts := [?]string {
		"the quick brown fox jumps over the lazy dog, 0123456789 ~!@#$%^&*()",
		"été à Noël: où êtes-vous, Ærøskøbing, ça coûte 12 €, ¡sí! «guillemets»",
		"日本語のテキストと中文的文本, 한국어 텍스트, ありがとう",
		"\U0001f600\U0001f680\U00010348\U0010ffff\U00010000\U0001d11e\U0001f600\U0001f680",
		"aé€\U0001f600aé€\U0001f600aé€\U0001f600aé€\U0001f600",
	}
	for text in texts {
		both_forms_answer(t, transmute([]u8)text, true)
	}
}

// A sequence cut short by the end of the slice, while the byte after the
// end in memory would complete it: the forms must not read past the slice.
@(test)
a_sequence_cut_by_the_end_of_the_slice_is_refused :: proc(t: ^testing.T) {
	euro := "aaaaaaaaaaaaaa€" // The euro sign takes bytes 14, 15 and 16.
	bytes := transmute([]u8)euro
	for length in 15 ..< len(bytes) {
		both_forms_answer(t, bytes[:length], false)
	}
	both_forms_answer(t, bytes, true)
}

// The full set of windows of three bytes runs only with
// -define:EXHAUSTIVE=true: 2^24 windows at three places is too long for
// each run of the host tests, which take one window in WINDOW_STRIDE.
EXHAUSTIVE :: #config(EXHAUSTIVE, false)

// An odd stride, so that each byte of the window takes many values.
@(private = "file")
WINDOW_STRIDE :: 251

// forms_agree compares the two forms on bytes, with no allocation, and
// reports a difference with its bytes.
@(private = "file")
forms_agree :: proc(t: ^testing.T, bytes: []u8, what: string, loc := #caller_location) -> bool {
	reference := text_valid_byte_by_byte(bytes)
	in_groups := text_valid_sixteen_bytes_at_a_time(bytes)
	if reference != in_groups {
		testing.expectf(t, false, "%s: the reference gave %v, the groups gave %v, for the bytes % x", what, reference, in_groups, bytes, loc = loc)
		return false
	}
	return true
}

// Each window of three bytes at the places 13, 14 and 15 of a text of 32
// bytes of ASCII: before the boundary of the first group, across it at
// its second byte, and across it at its first byte.
@(test)
every_window_of_three_bytes_across_a_group_boundary :: proc(t: ^testing.T) {
	stride := 1 when EXHAUSTIVE else WINDOW_STRIDE
	buffer: [32]u8
	count := 0
	for window := 0; window < 1 << 24; window += stride {
		for place in 13 ..= 15 {
			for &value in buffer {
				value = 'a'
			}
			buffer[place] = u8(window >> 16)
			buffer[place + 1] = u8(window >> 8)
			buffer[place + 2] = u8(window)
			if !forms_agree(t, buffer[:], "a window of three bytes") {
				return
			}
			count += 1
		}
	}
	fmt.printfln("text_encoding: %d windows of three bytes across a group boundary, the same answer in both forms", count)
}

// The leads of four bytes F0 to F4 at the places 12 to 15, so that the
// sequence ends at each place of the next group, with each second byte and
// the edge classes of the third and the fourth byte.
@(test)
leads_of_four_bytes_at_the_end_of_a_group :: proc(t: ^testing.T) {
	edges := [?]u8{0x00, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC2, 0xE0, 0xF0, 0xFF}
	buffer: [32]u8
	count := 0
	for lead in u8(0xF0) ..= 0xF4 {
		for place in 12 ..= 15 {
			for second in 0 ..= 255 {
				for third in edges {
					for fourth in edges {
						for &value in buffer {
							value = 'a'
						}
						buffer[place] = lead
						buffer[place + 1] = u8(second)
						buffer[place + 2] = third
						buffer[place + 3] = fourth
						if !forms_agree(t, buffer[:], "a lead of four bytes") {
							return
						}
						count += 1
					}
				}
			}
		}
	}
	fmt.printfln("text_encoding: %d texts with a lead of four bytes at the end of a group, the same answer in both forms", count)
}

// Slices that start at the places 1 to 15 of a larger buffer, so that no
// load of a group is aligned on 16 bytes, with each sequence at each place.
@(test)
slices_that_start_at_each_place_of_a_group :: proc(t: ^testing.T) {
	LENGTH :: 40
	buffer: [16 + LENGTH + 16]u8
	for start in 1 ..= 15 {
		for sequence in placed_sequences {
			for place in 0 ..= LENGTH - len(sequence.bytes) {
				// Bytes outside the slice that would complete a cut
				// sequence: a form that reads them gives a wrong answer.
				for &value in buffer {
					value = 0x80
				}
				text := buffer[start:][:LENGTH]
				for &value in text {
					value = 'a'
				}
				copy(text[place:], sequence.bytes)
				if !both_forms_answer(t, text, sequence.valid) {
					fmt.printfln("the sequence % x at %d of a slice that starts at %d", transmute([]u8)sequence.bytes, place, start)
					return
				}
			}
		}
	}
}

// A group that is not ASCII ends with a lead, and the next groups are
// ASCII, so the text has no last bytes outside a group: only the leads
// that the group keeps for the next group find the cut.
@(test)
a_lead_cut_at_the_end_of_a_group_before_groups_of_ascii :: proc(t: ^testing.T) {
	Case :: struct {
		end_of_group: [4]u8, // The places 12 to 15; the places 0 to 11 hold é six times.
		after:        string, // The bytes after the group, before the ASCII.
		valid:        bool,
	}
	cases := [?]Case {
		{{'a', 'a', 'a', 0xE2}, "", false}, // A lead of three bytes at the place 15.
		{{'a', 'a', 'a', 0xC3}, "", false}, // A lead of two bytes at the place 15.
		{{'a', 'a', 'a', 0xF0}, "", false},
		{{'a', 'a', 0xE2, 0x82}, "", false}, // At the place 14.
		{{'a', 'a', 0xF0, 0x9F}, "", false},
		{{'a', 0xF0, 0x9F, 0x98}, "", false}, // At the place 13.
		{{'a', 0xE2, 0x82, 0xAC}, "", true}, // Each one whole.
		{{'a', 'a', 0xC3, 0xA9}, "", true},
		{{'a', 'a', 'a', 0xE2}, "\x82\xac", true},
		{{'a', 'a', 0xF0, 0x9F}, "\x98\x80", true},
		{{'a', 0xF0, 0x9F, 0x98}, "\x80", true},
	}
	for one in cases {
		text := make([dynamic]u8, 0, 64)
		defer delete(text)
		for _ in 0 ..< 6 {
			append(&text, 0xC3, 0xA9)
		}
		end_of_group := one.end_of_group
		append(&text, ..end_of_group[:])
		append(&text, one.after)
		// ASCII up to the end of the third group: no last bytes.
		for len(text) < 48 {
			append(&text, 'b')
		}
		both_forms_answer(t, text[:], one.valid)
	}
}

// A generator with a fixed seed, so that a failure gives the same input on
// each host and each run.
@(private = "file")
Test_Random :: struct {
	state: u64,
}

@(private = "file")
next_random :: proc(random: ^Test_Random) -> u64 {
	random.state ~= random.state << 13
	random.state ~= random.state >> 7
	random.state ~= random.state << 17
	return random.state
}

// The bytes at the edges of the rule, which a random byte meets rarely.
@(private = "file")
EDGE_BYTES :: [?]u8{0x00, 0x1F, 0x20, 0x41, 0x7E, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1, 0xC2, 0xC3, 0xDF, 0xE0, 0xE1, 0xEC, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xF8, 0xFE, 0xFF}

// random_character_append writes one character of a text, from each length
// of sequence, the edges of each range often.
@(private = "file")
random_character_append :: proc(random: ^Test_Random, text: ^[dynamic]u8) {
	ranges := [?][2]u32{{0x20, 0x7E}, {0xA0, 0x7FF}, {0x800, 0xD7FF}, {0xE000, 0xFFFF}, {0x10000, 0x10FFFF}}
	span := ranges[next_random(random) % len(ranges)]
	choice := next_random(random)
	code_point := span[0] + u32(choice >> 8) % (span[1] - span[0] + 1)
	switch choice % 8 {
	case 0:
		code_point = span[0]
	case 1:
		code_point = span[1]
	}
	encoded: [CHARACTER_BYTES_LIMIT]u8
	length := character_encode(rune(code_point), encoded[:])
	append(text, ..encoded[:length])
}

// The two forms on many texts: random bytes, random edge bytes, valid
// texts, and valid texts with one, two or three bytes changed, inserted or
// removed, of each length from 0 to 300.
@(test)
the_groups_give_the_answer_of_the_reference_on_random_texts :: proc(t: ^testing.T) {
	SEED :: 0x9E3779B97F4A7C15
	TEXT_COUNT :: 400_000
	random := Test_Random{state = SEED}
	text := make([dynamic]u8, 0, 320)
	defer delete(text)
	edge_bytes := EDGE_BYTES
	valid_count := 0
	for index in 0 ..< TEXT_COUNT {
		clear(&text)
		length := int(next_random(&random) % 301)
		kind := index % 7
		switch kind {
		case 0:
			for _ in 0 ..< length {
				append(&text, u8(next_random(&random)))
			}
		case 1:
			for _ in 0 ..< length {
				append(&text, edge_bytes[next_random(&random) % len(edge_bytes)])
			}
		case:
			for len(text) < length {
				random_character_append(&random, &text)
			}
			// Kinds 2 to 4 make one change of their own; kind 5 keeps the
			// valid text whole; kind 6 makes two or three changes of any
			// sort, so that two faults can meet in one group.
			changes := 1
			if kind == 5 {
				changes = 0
			} else if kind == 6 {
				changes = 2 + int(next_random(&random) % 2)
			}
			for _ in 0 ..< changes {
				if len(text) == 0 {
					break
				}
				place := int(next_random(&random) % u64(len(text)))
				value := edge_bytes[next_random(&random) % len(edge_bytes)]
				change := kind if kind != 6 else 2 + int(next_random(&random) % 3)
				switch change {
				case 2:
					text[place] = value
				case 3:
					inject_at(&text, place, value)
				case 4:
					ordered_remove(&text, place)
				}
			}
		}
		reference := text_valid_byte_by_byte(text[:])
		in_groups := text_valid_sixteen_bytes_at_a_time(text[:])
		if reference {
			valid_count += 1
		}
		if reference != in_groups {
			testing.expectf(t, false, "the seed %x, text %d: the reference gave %v, the groups gave %v, for the bytes % x", u64(SEED), index, reference, in_groups, text[:])
			return
		}
	}
	fmt.printfln("text_encoding: %d random texts, %d of them valid, the same answer in both forms (seed %x)", TEXT_COUNT, valid_count, u64(SEED))
}

// The time of each form, as a measure: the least of 5 runs. Each run
// checks one text again until 4 MiB passed. Random bytes stop at their
// first invalid sequence, so their number is the time of a check that
// refuses, not a throughput. It runs only with -define:MEASURE=true: a
// test that measures time is opt-in. Build with -o:speed and
// -microarch:x86-64 for a number of a module.
MEASURE :: #config(MEASURE, false)

@(test)
text_valid_speed_of_each_form :: proc(t: ^testing.T) {
	if !MEASURE {
		return
	}
	MEASURED_BYTES :: 4 << 20
	sizes := [?]int{64, 4096, 1 << 20}
	random := Test_Random{state = 11}
	ascii := make([dynamic]u8, 0, 1 << 20)
	mixed := make([dynamic]u8, 0, (1 << 20) + 8)
	invalid := make([dynamic]u8, 0, 1 << 20)
	defer delete(ascii)
	defer delete(mixed)
	defer delete(invalid)
	words := [?]string{"le ", "café ", "où ", "été ", "Noël ", "日本語 ", "中文 ", "テキスト ", "€ ", "the ", "text "}
	for len(ascii) < 1 << 20 {
		append(&ascii, u8(0x20 + next_random(&random) % 95))
	}
	for len(mixed) < 1 << 20 {
		append(&mixed, words[next_random(&random) % len(words)])
	}
	for len(invalid) < 1 << 20 {
		append(&invalid, u8(next_random(&random)))
	}
	Kind :: struct {
		name:  string,
		bytes: []u8,
	}
	kinds := [?]Kind{{"ASCII", ascii[:]}, {"French and CJK", mixed[:]}, {"random bytes", invalid[:]}}
	Form :: struct {
		name:  string,
		check: proc "contextless" (bytes: []u8) -> bool,
	}
	forms := [?]Form{{"byte by byte", text_valid_byte_by_byte}, {"16 bytes at a time", text_valid_sixteen_bytes_at_a_time}}
	for kind in kinds {
		for size in sizes {
			text := kind.bytes[:size]
			// Mixed text cut at its size can end inside a character: cut
			// it after a whole one, so both forms check a valid text.
			text = text[:complete_characters(text)]
			for form in forms {
				least_seconds := max(f64)
				calls := (MEASURED_BYTES + len(text) - 1) / len(text)
				answer := false
				for _ in 0 ..< 5 {
					start := time.tick_now()
					for _ in 0 ..< calls {
						answer = form.check(text)
					}
					least_seconds = min(least_seconds, time.duration_seconds(time.tick_since(start)))
				}
				testing.expectf(t, answer == text_valid_byte_by_byte(text), "the form %s gave another answer", form.name)
				fmt.printfln("text_encoding: %s, %d bytes, %s: %.1f ns for each check, %.0f MiB/s of the text", kind.name, len(text), form.name, least_seconds * 1e9 / f64(calls), f64(calls * len(text)) / least_seconds / f64(1 << 20))
			}
		}
	}
}
