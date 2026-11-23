#+build !freestanding
package console_language

import "core:strings"
import "core:testing"

// The edges of the distance: an empty name, a name past the longest, a
// negative bound, the bound and one past it; then the edits that it counts.
@(test)
name_distance_counts_the_edits_up_to_the_bound :: proc(t: ^testing.T) {
	long := strings.repeat("a", NAME_DISTANCE_BYTES_MOST + 1, context.temp_allocator)
	most := strings.repeat("a", NAME_DISTANCE_BYTES_MOST, context.temp_allocator)
	testing.expect_value(t, name_distance("", "", 0), 0)
	testing.expect_value(t, name_distance("", "a", 0), 1)
	testing.expect_value(t, name_distance("", "a", 1), 1)
	testing.expect_value(t, name_distance("ab", "ab", -1), 1)
	testing.expect_value(t, name_distance(long, long, 3), 4)
	testing.expect_value(t, name_distance(most, most, 3), 0)
	testing.expect_value(t, name_distance(most, long, 3), 4)
	// The bound and one past it.
	testing.expect_value(t, name_distance("abcd", "wxyz", 4), 4)
	testing.expect_value(t, name_distance("abcd", "wxyz", 3), 4)
	testing.expect_value(t, name_distance("abcdef", "a", 4), 5)
	// One edit of each kind.
	testing.expect_value(t, name_distance("proceses", "processes", 3), 1)
	testing.expect_value(t, name_distance("processes", "proceses", 3), 1)
	testing.expect_value(t, name_distance("pages", "paget", 3), 1)
	testing.expect_value(t, name_distance("slto", "slot", 3), 1)
	testing.expect_value(t, name_distance("ca", "abc", 3), 3)
}

// A search keeps the names within its bound, from the nearest, at most
// NEAREST_NAME_CAPACITY of them, the first offered among equal distances,
// and never the wanted name, an empty name or a name twice.
@(test)
nearest_names_keep_the_nearest_within_the_bound :: proc(t: ^testing.T) {
	nearest := nearest_names_start("")
	nearest_name_offer(&nearest, "")
	nearest_name_offer(&nearest, "a")
	testing.expect_value(t, len(nearest_names_found(&nearest)), 1)

	nearest = nearest_names_start("pages")
	testing.expect_value(t, nearest.bound, 2)
	for name in ([]string{"pages", "", "slot", "name", "resident", "mapped", "handles"}) {
		nearest_name_offer(&nearest, name)
	}
	testing.expect_value(t, len(nearest_names_found(&nearest)), 0)

	// A short name takes 1 edit, a name up to 8 bytes 2, a longer one 3.
	testing.expect_value(t, nearest_names_start("abcd").bound, 1)
	testing.expect_value(t, nearest_names_start("abcdefgh").bound, 2)
	testing.expect_value(t, nearest_names_start("abcdefghi").bound, 3)

	nearest = nearest_names_start("proceses")
	for name in ([]string{"process", "processes", "processes", "proceses", "precesses", "procedure", "prices", "procs"}) {
		nearest_name_offer(&nearest, name)
	}
	found := nearest_names_found(&nearest)
	testing.expect_value(t, len(found), NEAREST_NAME_CAPACITY)
	// Both are 1 edit away: the first offered comes first.
	testing.expect_value(t, found[0], "process")
	testing.expect_value(t, found[1], "processes")
	testing.expect_value(t, nearest.distances[2] >= 1 && nearest.distances[2] <= nearest.bound, true)

	// A nearer name offered last pushes the farthest out, and comes first.
	nearest = nearest_names_start("monitor.proceses")
	for name in ([]string{"monitor.prices", "monitor.procedures", "monitor.precise", "monitor.processes"}) {
		nearest_name_offer(&nearest, name)
	}
	found = nearest_names_found(&nearest)
	testing.expect_value(t, found[0], "monitor.processes")
	testing.expect_value(t, nearest.distances[0], 1)
	for index in 1 ..< len(found) {
		testing.expect(t, nearest.distances[index - 1] <= nearest.distances[index])
	}

	// A name near by its meaning, kept at the distance 0, comes before the
	// names near by their letters, and a later offer does not keep it twice.
	nearest = nearest_names_start("pages")
	nearest_name_offer(&nearest, "paged")
	nearest_name_keep(&nearest, "resident", 0)
	nearest_name_keep(&nearest, "mapped", 0)
	nearest_name_offer(&nearest, "resident")
	nearest_name_keep(&nearest, "pages", 0)
	found = nearest_names_found(&nearest)
	testing.expect_value(t, len(found), 3)
	testing.expect_value(t, found[0], "resident")
	testing.expect_value(t, found[1], "mapped")
	testing.expect_value(t, found[2], "paged")
}
