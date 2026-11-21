package line_editor

import "base:intrinsics"

// The frecency: how often, and how lately, the principal used a name
// (src/md/features/fuzzy_match.md, "The frecency"). A name in the table
// gains a small bonus in the ranking, so among near equal matches the
// used name comes first.
//
// The decay counts uses, not time: each use first takes 1/32 of each
// score, rounded up so that a score reaches 0, then adds
// FRECENCY_USE_WEIGHT to each name of the use. A score halves after 22
// uses of other names, and no clock is read.
//
// The table is in the memory of its owner. The console builds it from its
// line history, the palette from its runs. A count out of its bounds is
// read as the nearest bound, and a use writes it back repaired.

FRECENCY_CAPACITY :: 64 // The names that a table holds: a new name in a full table takes the place of the lowest score.
FRECENCY_USE_WEIGHT :: 1024 // What one use adds to the score of a name.
FRECENCY_DECAY_SHIFT :: 5 // Each use takes score / 32 of each score: a score halves after 22 uses.
// No score reaches it: at this score a use takes as much as it adds.
FRECENCY_SCORE_LIMIT :: FRECENCY_USE_WEIGHT << FRECENCY_DECAY_SHIFT
FRECENCY_NAMES_PER_USE :: 16 // The names that one use counts: the names after them in a line count nothing.
FRECENCY_BONUS_SHIFT :: 7 // The bonus is the bit length of score >> 7: one use gives 4, regular use gives 8.
// The most that the frecency adds to the score of a match. It is less
// than a run of two characters and than the start of a part of a name:
// the frecency passes a match that differs only by its gaps, never a
// match with one more start of a word.
FRECENCY_BONUS_LIMIT :: 8

#assert(FRECENCY_BONUS_LIMIT < SCORE_SIDE_BY_SIDE && FRECENCY_BONUS_LIMIT < SCORE_SEGMENT && FRECENCY_BONUS_LIMIT < SCORE_START)
// The highest score gives the highest bonus: 255 has a bit length of 8.
#assert((FRECENCY_SCORE_LIMIT - 1) >> FRECENCY_BONUS_SHIFT == 255 && FRECENCY_BONUS_LIMIT == 8)

// One name of the table: the hash of the name and its score.
Frecency_Entry :: struct {
	key:   u64, // frecency_key of the name: never 0.
	score: u32, // 1 to FRECENCY_SCORE_LIMIT - 1.
}

// The names that the principal used, sorted by their key, so a lookup is
// a binary search.
Frecency :: struct {
	entries: [FRECENCY_CAPACITY]Frecency_Entry,
	count:   int,
}

// frecency_key gives the key of a name: its FNV-1a hash of 64 bits, never
// 0. The key is the name and not its kind: a use of the window plasma
// lifts the start of the process plasma too.
frecency_key :: proc "contextless" (name: string) -> u64 {
	hash: u64 = 0xCBF2_9CE4_8422_2325
	for index in 0 ..< len(name) {
		hash = (hash ~ u64(name[index])) * 0x0000_0100_0000_01B3
	}
	return hash == 0 ? 1 : hash
}

// frecency_count gives the count of a table in its bounds. It writes
// nothing: a read of the table changes no byte of it.
@(private)
frecency_count :: proc "contextless" (table: ^Frecency) -> int {
	return clamp(table.count, 0, FRECENCY_CAPACITY)
}

// frecency_find gives the place of a key in the table: found, or the place
// where it goes.
@(private)
frecency_find :: proc "contextless" (table: ^Frecency, key: u64) -> (place: int, found: bool) {
	count := frecency_count(table)
	low, high := 0, count
	for low < high {
		middle := (low + high) / 2
		if table.entries[middle].key < key {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low, low < count && table.entries[low].key == key
}

// frecency_score gives the score of a name, or 0 when the table is nil or
// does not hold it.
frecency_score :: proc "contextless" (table: ^Frecency, name: string) -> u32 {
	if table == nil {
		return 0
	}
	place, found := frecency_find(table, frecency_key(name))
	return found ? table.entries[place].score : 0
}

// frecency_bonus gives the points that a name gains in the ranking: 0 to
// FRECENCY_BONUS_LIMIT.
frecency_bonus :: proc "contextless" (table: ^Frecency, name: string) -> u8 {
	if table == nil || frecency_count(table) == 0 {
		return 0
	}
	scaled := frecency_score(table, name) >> FRECENCY_BONUS_SHIFT
	return u8(min(32 - int(intrinsics.count_leading_zeros(scaled)), FRECENCY_BONUS_LIMIT))
}

// frecency_note_use counts one use of names: each score decays, then each
// name gains FRECENCY_USE_WEIGHT. A name that is empty, or that comes again
// in the same use, counts once; the names after the first
// FRECENCY_NAMES_PER_USE count nothing. A use with no name decays only.
frecency_note_use :: proc "contextless" (table: ^Frecency, names: []string) {
	keys: [FRECENCY_NAMES_PER_USE]u64
	key_count := 0
	next_name: for name in names {
		if key_count == FRECENCY_NAMES_PER_USE {
			break
		}
		if len(name) == 0 {
			continue
		}
		key := frecency_key(name)
		for kept in keys[:key_count] {
			if kept == key {
				continue next_name
			}
		}
		keys[key_count] = key
		key_count += 1
	}
	// The decay, and the names whose score reaches 0 leave. The order of
	// the keys stays.
	count := frecency_count(table)
	kept := 0
	for index in 0 ..< count {
		entry := table.entries[index]
		entry.score = min(entry.score, FRECENCY_SCORE_LIMIT - 1)
		entry.score -= (entry.score + (1 << FRECENCY_DECAY_SHIFT) - 1) >> FRECENCY_DECAY_SHIFT
		if entry.score > 0 && entry.key != 0 {
			table.entries[kept] = entry
			kept += 1
		}
	}
	table.count = kept
	for key in keys[:key_count] {
		frecency_add(table, key, keys[:key_count])
	}
}

// frecency_add adds one use to a key. A new key in a full table takes the
// place of the lowest score among the keys that are not of this use; on
// equal scores, of the first in the order of the keys.
@(private)
frecency_add :: proc "contextless" (table: ^Frecency, key: u64, use: []u64) {
	place, found := frecency_find(table, key)
	if found {
		// The decay before keeps the sum under the limit: a score below
		// the limit loses at least a use when it is at the limit.
		table.entries[place].score = min(table.entries[place].score + FRECENCY_USE_WEIGHT, FRECENCY_SCORE_LIMIT - 1)
		return
	}
	if table.count == FRECENCY_CAPACITY {
		lowest := -1
		next_entry: for entry, index in table.entries[:table.count] {
			for used in use {
				if used == entry.key {
					continue next_entry
				}
			}
			if lowest < 0 || entry.score < table.entries[lowest].score {
				lowest = index
			}
		}
		if lowest < 0 {
			return // Each place holds a key of this use: FRECENCY_NAMES_PER_USE is below the capacity, so this does not come.
		}
		copy(table.entries[lowest:table.count - 1], table.entries[lowest + 1:table.count])
		table.count -= 1
		if lowest < place {
			place -= 1
		}
	}
	copy(table.entries[place + 1:table.count + 1], table.entries[place:table.count])
	table.entries[place] = {key = key, score = FRECENCY_USE_WEIGHT}
	table.count += 1
}

#assert(FRECENCY_NAMES_PER_USE < FRECENCY_CAPACITY)

// frecency_line_names gives the names of a line of the console: each run
// of letters, digits, '_' and '.' that does not start with a digit, without
// a '.' at its ends, and after a run with a dot its part after the last
// dot, because the completion of a member lists that part. A text in
// quotes is read the same way: it holds the names of processes. At most
// len(names) names.
frecency_line_names :: proc "contextless" (line: string, names: []string) -> (count: int) {
	name_byte :: proc "contextless" (value: u8) -> bool {
		return value >= 'a' && value <= 'z' || value >= 'A' && value <= 'Z' || value >= '0' && value <= '9' || value == '_' || value == '.'
	}
	place := 0
	for place < len(line) && count < len(names) {
		if !name_byte(line[place]) {
			place += 1
			continue
		}
		start := place
		for place < len(line) && name_byte(line[place]) {
			place += 1
		}
		run := line[start:place]
		for len(run) > 0 && run[0] == '.' {
			run = run[1:]
		}
		for len(run) > 0 && run[len(run) - 1] == '.' {
			run = run[:len(run) - 1]
		}
		if len(run) == 0 || run[0] >= '0' && run[0] <= '9' {
			continue
		}
		names[count] = run
		count += 1
		last_dot := -1
		for index in 0 ..< len(run) {
			if run[index] == '.' {
				last_dot = index
			}
		}
		if last_dot >= 0 && count < len(names) {
			names[count] = run[last_dot + 1:]
			count += 1
		}
	}
	return count
}

// frecency_note_line counts one line of the console as one use of its
// names.
frecency_note_line :: proc "contextless" (table: ^Frecency, line: string) {
	names: [FRECENCY_NAMES_PER_USE]string
	count := frecency_line_names(line, names[:])
	frecency_note_use(table, names[:count])
}

// frecency_from_history builds the table again from the lines of a
// history, the oldest first: the same table as the notes of each line when
// it was added, for the lines that the history kept.
frecency_from_history :: proc "contextless" (table: ^Frecency, history: ^History) {
	table^ = {}
	for age := history_count(history) - 1; age >= 0; age -= 1 {
		if text, ok := history_line(history, age); ok {
			frecency_note_line(table, text)
		}
	}
}
