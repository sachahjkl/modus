package life

// The log facts of life (src/md/features/log_facts.md): each fact template
// is the line that the process wrote before it was a fact, so a wait of a
// machine test on that sentence reads it as before.

// The window shows its first generation.
@(log_fact = "life: ok")
Running :: struct {}
