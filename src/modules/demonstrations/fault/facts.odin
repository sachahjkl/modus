package fault

// The log facts of the demonstration fault (src/md/features/log_facts.md,
// "The facts of the demonstrations"): two lines with no value, each a fact
// type whose sentence is its template.

// The process writes to the address 0: the kernel stops it on the fault.
@(log_fact = "fault: this process writes to address 0")
Write_To_Address_Zero :: struct {}

// The write to the address 0 did not stop the process: a fault of the
// kernel.
@(log_fact = "fault: the write did not stop the process")
Write_Did_Not_Stop :: struct {}
