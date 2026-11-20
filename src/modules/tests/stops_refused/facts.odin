package stops_refused

// The log fact of stops_refused (src/md/features/log_facts.md). The fact
// template is the sentence that the line wrote before it was a fact, so
// the wait of the machine test reads it as before.

// The row refuses its context and stops itself with the outcome Refused,
// on purpose.
@(log_fact = "stops_refused: it refuses its context on purpose")
Refuses_On_Purpose :: struct {}
