package text_rendering

// The syllable machine of the shapers of Khmer, Myanmar and USE
// (src/md/features/written_shaping.md, "The syllable machine"). A grammar
// of HarfBuzz (hb-ot-shaper-*-machine.rl) runs over the categories of a
// window of characters as a set of reached places: bit i says that a match
// can stand before the character i of the window. A category moves each
// place by one; an optional part adds its places to those it starts from;
// a repeated part runs to its fixed point. The places only grow, and a
// window has at most 15 characters, so each fixed point ends.

// Reach: the places of a window that a part of a grammar reaches. The
// window of a syllable has at most SYLLABIC_WINDOW_LIMIT characters, so its
// places, the end too, fit the word.
Reach :: distinct u32
#assert(SYLLABIC_WINDOW_LIMIT + 1 <= 32)

// The categories of the window of a syllable, each the value of the
// category of its model, and the set of categories that a step takes, one
// bit for each value.
Syllable_Categories :: struct {
	values: [SYLLABIC_WINDOW_LIMIT]u8,
	count:  int,
}

// reach_step moves each reached place over one character whose category is
// in a set; the places that no such character follows are dropped.
@(private)
reach_step :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories, accepted: u64) -> (next: Reach) {
	for place in 0 ..< categories.count {
		if reach & (Reach(1) << uint(place)) != 0 && accepted & (u64(1) << categories.values[place]) != 0 {
			next |= Reach(1) << uint(place + 1)
		}
	}
	return next
}

// reach_optional is a step or none.
@(private)
reach_optional :: #force_inline proc "contextless" (reach: Reach, categories: ^Syllable_Categories, accepted: u64) -> Reach {
	return reach | reach_step(reach, categories, accepted)
}

// reach_repeated is a step repeated any number of times, none too.
@(private)
reach_repeated :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories, accepted: u64) -> Reach {
	result := reach
	for {
		grown := result | reach_step(result, categories, accepted)
		if grown == result {
			return result
		}
		result = grown
	}
}

// reach_longest gives the length of the longest match that a reach holds:
// its highest place past 0; 0 for none.
@(private)
reach_longest :: #force_inline proc "contextless" (reach: Reach) -> int {
	cut := reach &~ 1
	if cut == 0 {
		return 0
	}
	length := 0
	for cut != 0 {
		cut >>= 1
		length += 1
	}
	return length - 1
}

// Syllable_Match: the pattern of a grammar that matched first among the
// longest, as a Ragel scanner chooses, and its length.
Syllable_Match :: struct {
	pattern: int,
	length:  int,
}

// match_choose keeps a match of a pattern when it is longer than the best
// so far: a later pattern of the same length does not take its place.
@(private)
match_choose :: #force_inline proc "contextless" (best: ^Syllable_Match, pattern: int, reach: Reach) {
	if length := reach_longest(reach); length > best.length {
		best^ = {pattern, length}
	}
}
