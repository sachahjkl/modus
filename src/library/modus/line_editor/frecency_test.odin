#+build !freestanding
package line_editor

import "core:testing"

// One use gives FRECENCY_USE_WEIGHT and a bonus of 4; a table that does
// not hold a name gives 0; an empty table and no table give 0.
@(test)
frecency_of_one_use :: proc(t: ^testing.T) {
	table: Frecency
	testing.expect_value(t, frecency_score(nil, "monitor.count"), 0)
	testing.expect_value(t, frecency_bonus(&table, "monitor.count"), 0)
	testing.expect_value(t, frecency_bonus(nil, "monitor.count"), 0)
	frecency_note_use(&table, {"monitor.count"})
	testing.expect_value(t, table.count, 1)
	testing.expect_value(t, frecency_score(&table, "monitor.count"), FRECENCY_USE_WEIGHT)
	testing.expect_value(t, frecency_bonus(&table, "monitor.count"), 4)
	testing.expect_value(t, frecency_bonus(&table, "monitor.counts"), 0)
	// An empty name, and a name two times in one use, count once.
	frecency_note_use(&table, {"", "storage.write", "storage.write"})
	testing.expect_value(t, table.count, 2)
	testing.expect_value(t, frecency_score(&table, "storage.write"), FRECENCY_USE_WEIGHT)
	testing.expect_value(t, frecency_key(""), frecency_key(""))
	testing.expect(t, frecency_key("") != 0, "no key is 0")
}

// Each use takes 1/32 of each score, rounded up, so a score halves after
// 22 uses and reaches 0, and the name leaves the table.
@(test)
frecency_decay :: proc(t: ^testing.T) {
	table: Frecency
	frecency_note_use(&table, {"old"})
	frecency_note_use(&table, {"other"})
	testing.expect_value(t, frecency_score(&table, "old"), FRECENCY_USE_WEIGHT - FRECENCY_USE_WEIGHT / 32)
	expected: u32 = FRECENCY_USE_WEIGHT - FRECENCY_USE_WEIGHT / 32
	uses := 1
	for frecency_score(&table, "old") > FRECENCY_USE_WEIGHT / 2 {
		frecency_note_use(&table, {})
		expected -= (expected + 31) / 32
		testing.expect_value(t, frecency_score(&table, "old"), expected)
		uses += 1
	}
	testing.expect_value(t, uses, 22)
	testing.expect_value(t, frecency_score(&table, "old"), 501)
	// The bonus follows the score down: 501 >> 7 is 3, of bit length 2.
	testing.expect_value(t, frecency_bonus(&table, "old"), 2)
	for frecency_score(&table, "old") > 0 {
		frecency_note_use(&table, {})
		uses += 1
	}
	// The rounding up takes the score to 0, and the name leaves; "other",
	// used one use later, is still there.
	testing.expect_value(t, uses, 128)
	testing.expect_value(t, table.count, 1)
	testing.expect(t, frecency_score(&table, "other") > 0, "the name used later stays")
	// From the highest score, a name that is never used again leaves
	// after at most 260 uses.
	for _ in 0 ..< 2000 {
		frecency_note_use(&table, {"top"})
	}
	testing.expect_value(t, frecency_score(&table, "top"), 32737)
	left_after := 0
	for frecency_score(&table, "top") > 0 {
		frecency_note_use(&table, {})
		left_after += 1
	}
	testing.expect(t, left_after <= 260, "the highest score leaves after at most 260 uses")
}

// The bound: a table holds FRECENCY_CAPACITY names, a new name takes the
// place of the lowest score, the keys stay in order, and no score reaches
// FRECENCY_SCORE_LIMIT, however often a name is used.
@(test)
frecency_bound :: proc(t: ^testing.T) {
	table: Frecency
	names: [FRECENCY_CAPACITY + 40]string
	buffer: [FRECENCY_CAPACITY + 40][8]u8
	for index in 0 ..< len(names) {
		buffer[index] = {'n', 'a', 'm', 'e', u8('a' + index / 26 % 26), u8('a' + index % 26), 0, 0}
		names[index] = string(buffer[index][:6])
	}
	for name in names {
		frecency_note_use(&table, {name})
		testing.expect(t, table.count <= FRECENCY_CAPACITY, "the table stays in its bound")
	}
	testing.expect_value(t, table.count, FRECENCY_CAPACITY)
	testing.expect_value(t, frecency_score(&table, names[0]), 0) // The oldest left first.
	testing.expect_value(t, frecency_score(&table, names[len(names) - 1]), FRECENCY_USE_WEIGHT)
	for index in 1 ..< table.count {
		testing.expect(t, table.entries[index - 1].key < table.entries[index].key, "the keys stay in order")
	}
	for _ in 0 ..< 5000 {
		frecency_note_use(&table, {"often"})
	}
	score := frecency_score(&table, "often")
	testing.expect(t, score < FRECENCY_SCORE_LIMIT && score > FRECENCY_SCORE_LIMIT - FRECENCY_USE_WEIGHT, "the score stays under its limit")
	testing.expect_value(t, frecency_bonus(&table, "often"), FRECENCY_BONUS_LIMIT)
	// A use counts FRECENCY_NAMES_PER_USE names, and no name of a use
	// takes the place of another name of the same use.
	table = {}
	frecency_note_use(&table, names[:FRECENCY_NAMES_PER_USE + 5])
	testing.expect_value(t, table.count, FRECENCY_NAMES_PER_USE)
	testing.expect_value(t, frecency_score(&table, names[FRECENCY_NAMES_PER_USE]), 0)
	table = {}
	for name in names[:FRECENCY_CAPACITY] {
		frecency_note_use(&table, {name})
	}
	frecency_note_use(&table, names[FRECENCY_CAPACITY:][:FRECENCY_NAMES_PER_USE])
	for name in names[FRECENCY_CAPACITY:][:FRECENCY_NAMES_PER_USE] {
		testing.expect_value(t, frecency_score(&table, name), FRECENCY_USE_WEIGHT)
	}
}

// A table in the memory of its owner with a count out of its bounds is
// repaired before a read: a negative count, one past the capacity, the
// largest value. A score past the limit comes back under it, and an entry
// of key 0 leaves at the next use.
@(test)
frecency_hostile_counts :: proc(t: ^testing.T) {
	for count in ([?]int{-1, FRECENCY_CAPACITY + 1, max(int), min(int)}) {
		table: Frecency
		table.count = count
		testing.expect_value(t, frecency_bonus(&table, "a"), 0)
		frecency_note_use(&table, {"a"})
		testing.expect(t, table.count >= 0 && table.count <= FRECENCY_CAPACITY, "the count is in its bounds")
	}
	table: Frecency
	frecency_note_use(&table, {"a"})
	table.entries[0].score = max(u32)
	frecency_note_use(&table, {"a"})
	testing.expect(t, frecency_score(&table, "a") < FRECENCY_SCORE_LIMIT, "a score past the limit comes back under it")
	table = {}
	table.count = 2
	table.entries[1] = {key = frecency_key("b"), score = 5000}
	frecency_note_use(&table, {})
	testing.expect_value(t, table.count, 1)
	testing.expect(t, table.entries[0].key == frecency_key("b"), "the entry of key 0 left")
}

// The names of a line: runs of letters, digits, '_' and '.', not a number,
// with the part after the last dot; the bound of the names of a line.
@(test)
frecency_names_of_a_line :: proc(t: ^testing.T) {
	names: [FRECENCY_NAMES_PER_USE]string
	count := frecency_line_names("monitor.count(\"processors\") + 12 * x.", names[:])
	testing.expect_value(t, count, 4)
	testing.expect_value(t, names[0], "monitor.count")
	testing.expect_value(t, names[1], "count")
	testing.expect_value(t, names[2], "processors")
	testing.expect_value(t, names[3], "x")
	testing.expect_value(t, frecency_line_names("", names[:]), 0)
	testing.expect_value(t, frecency_line_names("1.5 + 2 ... ()", names[:]), 0)
	// A byte past ASCII ends a name.
	testing.expect_value(t, frecency_line_names("été", names[:]), 1)
	testing.expect_value(t, names[0], "t")
	small: [1]string
	testing.expect_value(t, frecency_line_names("a.b c", small[:]), 1)
	testing.expect_value(t, small[0], "a.b")
	testing.expect_value(t, frecency_line_names("a b c", names[:0]), 0)
}

// The table of a history is the table of its lines, the oldest first. A
// history file that a check refuses gives an empty history, so an empty
// table: nothing of a damaged file counts.
@(test)
frecency_from_a_history :: proc(t: ^testing.T) {
	history := new(History)
	defer free(history)
	history_add(history, "storage.write(\"a\", \"b\")")
	history_add(history, "monitor.count(\"processors\")")
	from_history: Frecency
	frecency_from_history(&from_history, history)
	by_lines: Frecency
	frecency_note_line(&by_lines, "storage.write(\"a\", \"b\")")
	frecency_note_line(&by_lines, "monitor.count(\"processors\")")
	testing.expect_value(t, from_history, by_lines)
	testing.expect_value(t, frecency_score(&from_history, "monitor.count"), FRECENCY_USE_WEIGHT)
	testing.expect_value(t, frecency_score(&from_history, "storage.write"), FRECENCY_USE_WEIGHT - FRECENCY_USE_WEIGHT / 32)

	buffer: [HISTORY_FILE_SIZE_LIMIT]u8
	file := history_file_write(history, buffer[:])
	file[HISTORY_FILE_HEADER_SIZE + 1] ~= 1
	read_back := new(History)
	defer free(read_back)
	testing.expect_value(t, history_file_read(file, read_back), History_File_Problem.Wrong_Hash)
	frecency_from_history(&from_history, read_back)
	testing.expect_value(t, from_history.count, 0)
}

// The bonus changes the order of near equal matches, and never the order
// of a match with one more start of a word; it never makes a name match.
@(test)
frecency_in_the_ranking :: proc(t: ^testing.T) {
	table: Frecency
	frecency_note_use(&table, {"monitor.counts"})
	names := [?]string{"monitor.count", "monitor.counts", "manual.replacements"}
	candidates: [len(names)]Candidate
	for name, index in names {
		candidates[index] = {name = name, bonus = frecency_bonus(&table, name)}
	}
	ranked: [RANKED_CAPACITY]Ranked
	kept, _ := rank_candidates("mcnt", candidates[:], ranked[:])
	testing.expect_value(t, kept, 3)
	// monitor.count and monitor.counts have one score: the used one comes first.
	testing.expect_value(t, candidates[ranked[0].candidate].name, "monitor.counts")
	testing.expect_value(t, ranked[0].score, 123 + 4)
	// The bonus does not pass 29 points of match.
	for _ in 0 ..< 100 {
		frecency_note_use(&table, {"manual.replacements"})
	}
	candidates[2].bonus = frecency_bonus(&table, "manual.replacements")
	testing.expect_value(t, candidates[2].bonus, FRECENCY_BONUS_LIMIT)
	kept, _ = rank_candidates("mcnt", candidates[:], ranked[:])
	testing.expect_value(t, candidates[ranked[kept - 1].candidate].name, "manual.replacements")
	// A bonus never makes a name match, and a bonus past the limit counts
	// as the limit.
	candidates[2].bonus = max(u8)
	kept, _ = rank_candidates("xyz", candidates[:], ranked[:])
	testing.expect_value(t, kept, 0)
	kept, _ = rank_candidates("mcnt", candidates[:], ranked[:])
	testing.expect_value(t, ranked[kept - 1].score, 94 + FRECENCY_BONUS_LIMIT)
}

// The bonus thresholds and the tie-break on eviction: min(bit_length(score >> 7), 8),
// and when a full table holds equal lowest scores, the first in key order leaves.
@(test)
frecency_bonus_thresholds_and_eviction_tie :: proc(t: ^testing.T) {
	Threshold :: struct {
		score: u32,
		bonus: u8,
	}
	thresholds := [?]Threshold {
		{0, 0},
		{127, 0},
		{128, 1},
		{255, 1},
		{256, 2},
		{511, 2},
		{512, 3},
		{1023, 3},
		{1024, 4},
		{2048, 5},
		{4096, 6},
		{8192, 7},
		{16383, 7},
		{16384, 8},
		{FRECENCY_SCORE_LIMIT - 1, 8},
	}
	table: Frecency
	table.count = 1
	table.entries[0].key = frecency_key("x")
	for item in thresholds {
		table.entries[0].score = item.score
		testing.expectf(t, frecency_bonus(&table, "x") == item.bonus, "score %d gives bonus %d, not %d", item.score, frecency_bonus(&table, "x"), item.bonus)
	}

	// Fill a table with equal scores: the first entry in key order leaves.
	table = {}
	table.count = FRECENCY_CAPACITY
	for index in 0 ..< FRECENCY_CAPACITY {
		table.entries[index] = {key = u64(index + 10), score = 500}
	}
	frecency_note_use(&table, {"evictor"})
	testing.expect_value(t, table.count, FRECENCY_CAPACITY)
	// Key 10 had the lowest key among equal scores and left; key 11 stayed.
	_, found_first := frecency_find(&table, 10)
	_, found_second := frecency_find(&table, 11)
	testing.expect(t, !found_first, "the first key among equal lowest scores leaves")
	testing.expect(t, found_second, "the next key stays")
	testing.expect_value(t, frecency_score(&table, "evictor"), FRECENCY_USE_WEIGHT)
}
