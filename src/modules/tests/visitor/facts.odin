package visitor

// The log facts of the disk process visitor (src/md/features/log_facts.md):
// the lines with a value, as records of fields. Each fact template is the
// sentence that the line wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before. A line that writes a
// status as its number stays text: a field of a status writes the name of
// its member. They are in a file of their own: the machine test of the
// disk processes names lines of main.odin, which must not move.
//
// The copies of this module that the test builds outside the sources
// (outsider, outsider_fault) write these facts too, with their own module
// hash; the tool renders a fact of a module of its build only, and no step
// waits for one of these lines from a copy.

// The context holds handles of a grant: a disk process with no grant
// receives none.
@(log_fact = "visitor: the context holds {grant_handles} handles of a grant: WRONG")
Wrong_Grant_Handles :: struct {
	grant_handles: u64,
}

// The count of the visits in the store is not 8 bytes.
@(log_fact = "visitor: the count in the store has {count_bytes} bytes, not 8: WRONG")
Wrong_Count_Size :: struct {
	count_bytes: u64,
}

// The store of the nickname holds the new count of the visits, read again.
@(log_fact = "visitor: the store of its nickname holds the visit {visit}, read again: as it must")
Visit_Read_Again :: struct {
	visit: u64,
}
