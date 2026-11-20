package host

// The log facts of the call host (src/md/features/log_facts.md): the module
// that it loaded, as a record of fields. The fact template is the sentence
// that the line wrote before it was a fact. No field has the name of a
// column of the head of facts(): number, time, process, level.

// The call host loaded its module, and serves its exports.
@(log_fact = "host: ready, {exports} exports")
Ready :: struct {
	exports: u64,
}
