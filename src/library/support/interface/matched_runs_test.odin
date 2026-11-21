#+build !freestanding
package interface

import "core:strings"
import "core:testing"

// The line under a match counts characters: a bit inside a character, past
// the name or past the 128 bytes that the places name is no match; a
// matched character of two or three bytes is under all its bytes; two
// matched characters side by side are one run. Then ASCII names, and the
// most runs.
@(test)
matched_runs_count_characters_not_bytes :: proc(t: ^testing.T) {
	bit :: proc(places: ..int) -> (set: u128) {
		for place in places {
			set |= u128(1) << uint(place)
		}
		return
	}
	Case :: struct {
		name:   string,
		places: u128,
		runs:   []Match_Run,
	}
	// 130 bytes: the places name the first 128.
	long := strings.repeat("a", 130, context.temp_allocator)
	cases := [?]Case {
		// No match: no bit, a bit inside é (its second byte), a bit past the
		// name, a name past 128 bytes with no bit.
		{"café", 0, nil},
		{"café", bit(4), nil},
		{"1.75", bit(4, 100), nil},
		{long, 0, nil},
		// A matched é is under its two bytes; € under its three.
		{"café", bit(3), {{3, 5}}},
		{"5 €", bit(2), {{2, 5}}},
		// Two matched characters of two bytes side by side: one run.
		{"ééa", bit(0, 2), {{0, 4}}},
		{"éxé", bit(0, 3), {{0, 2}, {3, 5}}},
		// ASCII: runs of bytes, as before.
		{"settings.set scale to 1.75", bit(22, 23, 24, 25), {{22, 26}}},
		{"monitor.count", bit(0, 8, 10, 11, 12), {{0, 1}, {8, 9}, {10, 13}}},
		{long, bit(127), {{127, 128}}},
	}
	for item in cases {
		runs := matched_runs(item.name, item.places)
		count := 0
		for run in runs {
			if run.end <= run.start {
				break
			}
			count += 1
		}
		if !testing.expectf(t, count == len(item.runs), "%q: %d runs, not %d: %v", item.name, count, len(item.runs), runs[:count]) {
			continue
		}
		for run, index in item.runs {
			testing.expectf(t, runs[index] == run, "%q: run %d is %v, not %v", item.name, index, runs[index], run)
		}
	}
	// The most runs: each other byte of 128, 64 runs, all kept.
	every_other: u128
	for place := 0; place < 128; place += 2 {
		every_other |= u128(1) << uint(place)
	}
	runs := matched_runs(long, every_other)
	testing.expect_value(t, runs[MATCH_RUN_CAPACITY - 1], Match_Run{126, 127})
}
