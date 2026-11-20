package store_importer

// The log facts of the importer of a library of the store
// (src/md/features/log_facts.md): each line, as a record of fields. Each
// fact template is the sentence that the line wrote before it was a fact,
// so the wait of the machine test reads it as before.

// The import gave 42.
@(log_fact = "store_importer: triple(14) of the module store_library of the store module_files gives 42: as it must")
Triple_Checked :: struct {}

// The import gave another result than 42. The field holds the bits of the
// result as the line wrote them: unsigned.
@(log_fact = "store_importer: triple(14) gives {result}, and 42 is the answer: WRONG")
Wrong_Result :: struct {
	result: u64,
}
