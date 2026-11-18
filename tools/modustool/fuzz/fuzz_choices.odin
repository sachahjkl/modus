package fuzz

// The choices of a generated fuzz target (src/md/infrastructure/fuzzing.md,
// "Two kinds of fuzz input, one engine"): a generator reads its next
// decision from the fuzz input, and reads zeros when the input ends. The
// smallest decision is always the zero bytes, so a shorter input, or an
// input with smaller bytes, gives a simpler value: the minimizer then makes
// a value simpler by making the bytes smaller, and each value that it
// makes is a value that the generator can build.

Fuzz_Choices :: struct {
	bytes: []u8,
	place: int,
}

fuzz_choices_of :: proc(input: []u8) -> Fuzz_Choices {
	return {bytes = input}
}

// fuzz_choice_byte gives the next byte of the input, or 0 after its end.
fuzz_choice_byte :: proc(choices: ^Fuzz_Choices) -> u8 {
	if choices.place >= len(choices.bytes) {
		choices.place += 1
		return 0
	}
	value := choices.bytes[choices.place]
	choices.place += 1
	return value
}

// fuzz_choice_word gives the next `size` bytes as a little-endian number:
// 1 to 8 bytes.
fuzz_choice_word :: proc(choices: ^Fuzz_Choices, size: int) -> u64 {
	value: u64
	for index in 0 ..< clamp(size, 1, 8) {
		value |= u64(fuzz_choice_byte(choices)) << (8 * u64(index))
	}
	return value
}

// fuzz_choice_below gives a number from 0 to count - 1, from the fewest
// bytes that hold count. A count of 0 or 1 reads no byte and gives 0; a
// count of 0 has no place, so a caller never uses that 0 as a place.
fuzz_choice_below :: proc(choices: ^Fuzz_Choices, count: int) -> int {
	if count <= 1 {
		return 0
	}
	size := 1
	for size < 8 && u64(count - 1) >> (8 * u64(size)) != 0 {
		size += 1
	}
	return int(fuzz_choice_word(choices, size) % u64(count))
}

// fuzz_choice_range gives a number from first to last, both included.
fuzz_choice_range :: proc(choices: ^Fuzz_Choices, first, last: int) -> int {
	if last <= first {
		return first
	}
	return first + fuzz_choice_below(choices, last - first + 1)
}

// fuzz_choice_rare is true one time in `one_in`, and false for a zero
// byte: the simple value of a decision is "no".
fuzz_choice_rare :: proc(choices: ^Fuzz_Choices, one_in: int) -> bool {
	return fuzz_choice_below(choices, max(one_in, 2)) == one_in - 1
}

// fuzz_choice_flag is true for an odd byte.
fuzz_choice_flag :: proc(choices: ^Fuzz_Choices) -> bool {
	return fuzz_choice_byte(choices) & 1 == 1
}

// fuzz_choice_fill writes the next bytes of the input into `into`, zeros
// after its end.
fuzz_choice_fill :: proc(choices: ^Fuzz_Choices, into: []u8) {
	for &item in into {
		item = fuzz_choice_byte(choices)
	}
}

// fuzz_choices_ran_out says if the generator read past the end of the
// input: the rest of its decisions were zeros.
fuzz_choices_ran_out :: proc(choices: ^Fuzz_Choices) -> bool {
	return choices.place > len(choices.bytes)
}

// The generator of numbers of the engine: splitmix64. The engine draws
// its own numbers, never from the code under test, so a run depends on
// its seed alone.
Fuzz_Random :: struct {
	state: u64,
}

fuzz_random_next :: proc(random: ^Fuzz_Random) -> u64 {
	random.state += 0x9E37_79B9_7F4A_7C15
	value := random.state
	value = (value ~ (value >> 30)) * 0xBF58_476D_1CE4_E5B9
	value = (value ~ (value >> 27)) * 0x94D0_49BB_1331_11EB
	return value ~ (value >> 31)
}

// fuzz_random_below gives a number from 0 to count - 1; 0 for a count of
// 0 or 1.
fuzz_random_below :: proc(random: ^Fuzz_Random, count: int) -> int {
	if count <= 1 {
		return 0
	}
	return int(fuzz_random_next(random) % u64(count))
}

// fuzz_random_one_in is true one time in `count`.
fuzz_random_one_in :: proc(random: ^Fuzz_Random, count: int) -> bool {
	return fuzz_random_below(random, count) == 0
}
