package limits

// The log facts of limits (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test and of a measure run on that sentence reads it as
// before.

// The processor time that each budget used in one second, against its
// limit, in microseconds: the three budgets of the threads and the process.
@(log_fact = "limits: processor time of one second, used of limit: {first_used} of {first_limit}, {second_used} of {second_limit}, {third_used} of {third_limit}, the process {process_used} of {process_limit}")
Processor_Time_Used :: struct {
	first_used:    u64,
	first_limit:   u64,
	second_used:   u64,
	second_limit:  u64,
	third_used:    u64,
	third_limit:   u64,
	process_used:  u64,
	process_limit: u64,
}

// Each budget kept its processor time, and the log limit of this process
// refused the records past it.
@(log_fact = "limits: ok, 4 budgets within their processor time, {accepted} log records written and {refused} refused with {log_limit} for each second")
Budgets_Within_Limits :: struct {
	accepted:  u64,
	refused:   u64,
	log_limit: u64,
}

// A check failed: each check as 1 when it passed.
@(log_fact = "limits: wrong: threads {threads_started} log {log_right} rule {rule_right}")
Checks_Wrong :: struct {
	threads_started: u64,
	log_right:       u64,
	rule_right:      u64,
}
