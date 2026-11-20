package host

// The log facts of the call host (src/md/features/log_facts.md): the module
// that it loaded, and the grants that it lacks, as records of fields. Each
// fact template is the sentence that the line wrote before it was a fact.
// No field has the name of a column of the head of facts(): number, time,
// process, level.

// The call host loaded its module, and serves its exports.
@(log_fact = "host: ready, {exports} exports")
Ready :: struct {
	exports: u64,
}

// The ring or the region of the calls does not open.
@(log_fact = "host: no call ring or no call region")
No_Call_Ring_Or_Region :: struct {}

// The call region has no size.
@(log_fact = "host: the call region has no size")
Call_Region_Without_Size :: struct {}
