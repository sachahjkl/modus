package twin

// The log facts of twin (src/md/features/log_facts.md): each fact template
// is the line that the process wrote before it was a fact.

// The context names no mode of a twin: the process does nothing.
@(log_fact = "twin: the mode {mode_word} names no mode of a twin: nothing is done")
Mode_Word_Unknown :: struct {
	mode_word: u64,
}
