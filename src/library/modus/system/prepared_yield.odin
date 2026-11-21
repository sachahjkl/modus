package system

// The table of prepared modules as a cache that yields its room
// (src/md/features/module_outputs.md, "The budget"). Each prepared part
// holds one handle of the owner of the table, the root service most of
// all. When the owner needs room in its handle table, it closes the parts
// used least recently. A process that maps a part keeps its mapping, which
// holds the memory object, so a closed part costs only time and memory:
// the next start of its module prepares it again.

// One prepared part, as the choice of the parts to close sees it.
Prepared_Use :: struct {
	held:     bool, // The place holds a part: its handle is in the table of the owner.
	last_use: u64, // Prepared.last_use: a lower value was found earlier.
	in_use:   bool, // A load holds a pointer to the part now (the part Code while it finds the part Fixed): it is never closed.
}

// prepared_drop_choose writes in chosen the places of the parts to close,
// the least recently used first, until it chose needed of them or no part
// is left that it may close: a place that holds no part, and a part that a
// start holds, are never chosen. It gives the count that it chose: less
// than needed when the table cannot give more. needed of 0 or less chooses
// none. It reads the first PREPARED_CAPACITY places at most.
prepared_drop_choose :: proc "contextless" (uses: []Prepared_Use, needed: int, chosen: []int) -> (count: int) {
	taken: [PREPARED_CAPACITY]bool
	places := uses[:min(len(uses), PREPARED_CAPACITY)]
	for count < needed && count < len(chosen) {
		best := -1
		for item, place in places {
			if !item.held || item.in_use || taken[place] {
				continue
			}
			if best < 0 || item.last_use < places[best].last_use {
				best = place
			}
		}
		if best < 0 {
			break
		}
		taken[best] = true
		chosen[count] = best
		count += 1
	}
	return count
}

// prepared_yield frees handles of the owner of a table until free of them
// are at least margin, or the table has no part left that it may close:
// first each part that no process maps (prepared_sweep), then the parts
// used least recently. It takes the lock of the table, so no start of the
// owner holds a part while it closes them: a start finds its parts and maps
// them under that lock (place_map). It gives the count of the parts that it
// closed.
prepared_yield :: proc "contextless" (table: ^Prepared_Modules, free: int, margin: int) -> (closed: int) {
	if free >= margin {
		return 0
	}
	lock(&table.lock)
	defer unlock(&table.lock)
	held_before := prepared_held(table)
	prepared_sweep(table)
	closed = held_before - prepared_held(table)
	// Under the lock no load holds a part, so no part is in use.
	uses: [PREPARED_CAPACITY]Prepared_Use
	for item, place in table.modules {
		uses[place] = {held = item.memory != 0, last_use = item.last_use}
	}
	chosen: [PREPARED_CAPACITY]int
	count := prepared_drop_choose(uses[:], margin - free - closed, chosen[:])
	for place in chosen[:count] {
		close(table.modules[place].memory)
		table.modules[place] = {}
	}
	return closed + count
}

// prepared_held gives the parts that a table holds: one handle of its
// owner each.
prepared_held :: proc "contextless" (table: ^Prepared_Modules) -> (count: int) {
	for item in table.modules {
		if item.memory != 0 {
			count += 1
		}
	}
	return count
}
