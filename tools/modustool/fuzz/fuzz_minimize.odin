package fuzz

import "core:slice"

// The minimizer of a fuzz finding (src/md/infrastructure/fuzzing.md, "Fuzz
// findings, minimization and the corpus"). It makes the input smaller in
// the order of Hypothesis: first shorter, then with smaller bytes from the
// left, while the finding keeps its signature. On the choices of a
// generated target the same passes remove decisions and make them simpler,
// and each smaller input is still one that the generator reads whole.

// The procedure that says if a candidate still gives the fuzz finding: the
// same oracle and the same place.
Fuzz_Still_Found :: #type proc(data: rawptr, candidate: []u8) -> bool

// fuzz_minimize gives the smallest input that it found, in the allocator
// of the context, and the count of the candidates that it tried. It tries
// at most candidate_limit candidates.
fuzz_minimize :: proc(input: []u8, still_found: Fuzz_Still_Found, data: rawptr, candidate_limit: int) -> (smallest: []u8, tried: int) {
	current := slice.clone(input)
	candidate := make([dynamic]u8)
	defer delete(candidate)
	changed := true
	for changed && tried < candidate_limit {
		changed = false
		// Remove ranges: halves first, then smaller and smaller ones, from
		// the end, as a decision at the end depends on fewer others.
		for chunk := max(len(current) / 2, 1); chunk >= 1 && len(current) > 0; chunk /= 2 {
			for start := len(current) - chunk; start >= 0; start -= chunk {
				if start + chunk > len(current) {
					continue
				}
				clear(&candidate)
				append(&candidate, ..current[:start])
				append(&candidate, ..current[start + chunk:])
				if fuzz_minimize_candidate_found(candidate[:], still_found, data, &tried, candidate_limit) {
					delete(current)
					current = slice.clone(candidate[:])
					changed = true
				}
			}
		}
		// Set ranges to zero.
		for chunk := max(len(current) / 2, 1); chunk >= 1 && len(current) > 0; chunk /= 2 {
			for start := 0; start + chunk <= len(current); start += chunk {
				if slice.all_of(current[start:][:chunk], 0) {
					continue
				}
				clear(&candidate)
				append(&candidate, ..current[:])
				slice.fill(candidate[start:][:chunk], 0)
				if fuzz_minimize_candidate_found(candidate[:], still_found, data, &tried, candidate_limit) {
					copy(current, candidate[:])
					changed = true
				}
			}
		}
		// Lower each byte: to zero, to its half, by one.
		for index in 0 ..< len(current) {
			for lower in 0 ..< 3 {
				value := current[index]
				if value == 0 {
					break
				}
				smaller := lower == 0 ? 0 : lower == 1 ? value / 2 : value - 1
				clear(&candidate)
				append(&candidate, ..current[:])
				candidate[index] = smaller
				if fuzz_minimize_candidate_found(candidate[:], still_found, data, &tried, candidate_limit) {
					current[index] = smaller
					changed = true
					break
				}
			}
		}
	}
	return current, tried
}

// fuzz_minimize_candidate_found runs one candidate, when the limit leaves
// room for it.
fuzz_minimize_candidate_found :: proc(candidate: []u8, still_found: Fuzz_Still_Found, data: rawptr, tried: ^int, limit: int) -> bool {
	if tried^ >= limit {
		return false
	}
	tried^ += 1
	return still_found(data, candidate)
}
