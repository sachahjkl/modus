package store_importer

// The log fact of the importer of a library of the store
// (src/md/features/log_facts.md): its one line with a value. The fact
// template is the sentence that the line wrote before it was a fact.

// The import gave another result than 42. The field holds the bits of the
// result as the line wrote them: unsigned.
@(log_fact = "store_importer: triple(14) gives {result}, and 42 is the answer: WRONG")
Wrong_Result :: struct {
	result: u64,
}
