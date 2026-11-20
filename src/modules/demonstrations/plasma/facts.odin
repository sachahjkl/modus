package plasma

// The log facts of plasma (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before.

// The window shows its first frame.
@(log_fact = "plasma: ok")
Running :: struct {}
