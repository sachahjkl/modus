package console_language

// The names near a name that the console does not know: a command, a field,
// a variable or a topic of help. A name typed with one or two faults gets
// the names that it is near in its error, "did you mean processes?", so the
// principal does not read a list of 100 names to find the fault.
//
// The distance is the optimal string alignment distance: an insertion, a
// deletion, a change of one byte, or two neighbour bytes in the other
// order, each one edit. It is computed only up to a bound that grows with
// the length of the name, so a short name never gets a far suggestion.
// Names are ASCII identifiers of the system, so a byte is a character.

// The names that one error suggests at most.
NEAREST_NAME_CAPACITY :: 3

// The longest name that the distance reads: a longer name or candidate gets
// no suggestion. No command, field or variable of the console is longer.
NAME_DISTANCE_BYTES_MOST :: 64

// The nearest names found so far, from the nearest.
Nearest_Names :: struct {
	wanted:    string,
	bound:     int, // The most edits of a suggestion.
	names:     [NEAREST_NAME_CAPACITY]string,
	distances: [NEAREST_NAME_CAPACITY]int,
	count:     int,
}

// nearest_names_start starts a search for the names near wanted. The bound
// is 1 edit for a name of 1 to 4 bytes, 2 edits up to 8 bytes, and 3 past
// that: half the bytes of a short name changed is another name, not a fault.
nearest_names_start :: proc "contextless" (wanted: string) -> Nearest_Names {
	bound := 3
	switch {
	case len(wanted) <= 4:
		bound = 1
	case len(wanted) <= 8:
		bound = 2
	}
	return {wanted = wanted, bound = bound}
}

// nearest_name_offer gives a candidate to the search. The candidate is kept
// when it is within the bound and nearer than a kept one. The wanted name
// itself, an empty name and a name already kept are not kept.
nearest_name_offer :: proc "contextless" (nearest: ^Nearest_Names, candidate: string) {
	if len(candidate) == 0 || candidate == nearest.wanted {
		return
	}
	for kept in nearest.names[:nearest.count] {
		if kept == candidate {
			return
		}
	}
	distance := name_distance(nearest.wanted, candidate, nearest.bound)
	if distance > nearest.bound {
		return
	}
	nearest_name_keep(nearest, candidate, distance)
}

// nearest_name_keep keeps a candidate at a distance that the caller gives:
// 0 for a candidate that is near by its meaning, not by its letters, as a
// field counted in pages for the name "pages". The candidate goes after
// each kept name that is as near, and a name already kept stays once.
nearest_name_keep :: proc "contextless" (nearest: ^Nearest_Names, candidate: string, distance: int) {
	if len(candidate) == 0 || candidate == nearest.wanted {
		return
	}
	for kept in nearest.names[:nearest.count] {
		if kept == candidate {
			return
		}
	}
	// The place of the candidate: after each kept name that is as near,
	// so that the order of the offers decides between equal distances.
	place := nearest.count
	for place > 0 && nearest.distances[place - 1] > distance {
		place -= 1
	}
	if place >= NEAREST_NAME_CAPACITY {
		return
	}
	last := min(nearest.count, NEAREST_NAME_CAPACITY - 1)
	for index := last; index > place; index -= 1 {
		nearest.names[index], nearest.distances[index] = nearest.names[index - 1], nearest.distances[index - 1]
	}
	nearest.names[place], nearest.distances[place] = candidate, distance
	nearest.count = min(nearest.count + 1, NEAREST_NAME_CAPACITY)
}

// nearest_names_found gives the kept names, from the nearest.
nearest_names_found :: proc "contextless" (nearest: ^Nearest_Names) -> []string {
	return nearest.names[:nearest.count]
}

// name_distance gives the optimal string alignment distance of two names,
// or bound + 1 when they are more than bound edits apart. A name longer than
// NAME_DISTANCE_BYTES_MOST is always farther than the bound.
name_distance :: proc "contextless" (first, second: string, bound: int) -> int {
	farther := max(bound, 0) + 1
	if len(first) > NAME_DISTANCE_BYTES_MOST || len(second) > NAME_DISTANCE_BYTES_MOST || bound < 0 {
		return farther
	}
	if abs(len(first) - len(second)) > bound {
		return farther
	}
	// Three rows of the table, the row of line L at rows[L % 3]: the row
	// before the row before is read for an exchange of two bytes.
	rows: [3][NAME_DISTANCE_BYTES_MOST + 1]int
	for column in 0 ..= len(second) {
		rows[0][column] = column
	}
	for line in 1 ..= len(first) {
		current, before, before_before := &rows[line % 3], &rows[(line + 2) % 3], &rows[(line + 1) % 3]
		current[0] = line
		least := line
		for column in 1 ..= len(second) {
			change := first[line - 1] == second[column - 1] ? 0 : 1
			value := min(before[column] + 1, current[column - 1] + 1, before[column - 1] + change)
			if line > 1 && column > 1 && first[line - 1] == second[column - 2] && first[line - 2] == second[column - 1] {
				value = min(value, before_before[column - 2] + 1)
			}
			current[column] = value
			least = min(least, value)
		}
		// Each later row is at least the least value of this one.
		if least > bound {
			return farther
		}
	}
	result := rows[len(first) % 3][len(second)]
	return result > bound ? farther : result
}
