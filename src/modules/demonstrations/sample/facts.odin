package sample

// The log facts of sample (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact.

// The context gives no service ring: the module serves nothing.
@(log_fact = "sample: no service ring")
No_Service_Ring :: struct {}

// The module serves its exports.
@(log_fact = "sample: serves its exports")
Serving :: struct {}
