package stops_failed

// The log fact of stops_failed (src/md/features/log_facts.md). The fact
// template is the sentence that the line wrote before it was a fact, so
// the wait of the machine test reads it as before.

// The row stops itself with the outcome Failed, on purpose.
@(log_fact = "stops_failed: it fails on purpose")
Fails_On_Purpose :: struct {}
