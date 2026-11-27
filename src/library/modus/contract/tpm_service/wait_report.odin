package tpm_service

// The wait reports of a long wait of the path of a key: a step of the
// interface of the TPM, a request of the service, and the wait of a client
// for its answer (src/md/features/tpm_sealed_machine_key.md, "A wait that
// is long"). The bounds of these waits stay long, because a slow TPM that
// works must not fail; the wait reports say what a wait waits for before
// its bound.

// The time between two wait reports of one wait.
WAIT_REPORT_INTERVAL_MILLISECONDS :: 30_000

// The wait reports of one wait: when it started, and how many reports it
// wrote.
Wait_Reports :: struct {
	started: u64, // The time of the start of the wait, in milliseconds of the system clock.
	written: u64, // The wait reports written so far.
}

// wait_reports_start gives the wait reports of a wait that starts at now.
wait_reports_start :: proc "contextless" (now: u64) -> Wait_Reports {
	return {started = now}
}

// wait_report_next gives the time of the next wait report: the start plus
// one more interval than the reports written. The largest value of the
// clock means "never": a time past it, or equal to it, gives it, so a
// sleep until it never wraps, and wait_report_due writes no report then.
wait_report_next :: proc "contextless" (reports: Wait_Reports) -> u64 {
	// The count is compared before the addition: written + 1 times the
	// interval wraps past this count.
	if reports.written >= max(u64) / WAIT_REPORT_INTERVAL_MILLISECONDS {
		return max(u64)
	}
	offset := (reports.written + 1) * WAIT_REPORT_INTERVAL_MILLISECONDS
	if reports.started > max(u64) - offset {
		return max(u64)
	}
	return reports.started + offset
}

// wait_report_due says if the wait must write a wait report at now, and
// counts it. passed_seconds is the time that the report names: its count
// times the interval, a fixed number, not the time of the clock at the
// check. One check writes one report at most: a check that comes late
// writes the reports one after another, so the report of 60 s always
// comes, after the report of 30 s. A time before the start is no report:
// the clock of the system does not go back.
wait_report_due :: proc "contextless" (reports: ^Wait_Reports, now: u64) -> (due: bool, passed_seconds: u64) {
	next := wait_report_next(reports^)
	if next == max(u64) || now < reports.started || now < next {
		return false, 0
	}
	reports.written += 1
	return true, reports.written * (WAIT_REPORT_INTERVAL_MILLISECONDS / 1000)
}

// The bound that ended a wait of the interface.
Wait_Bound :: enum u8 {
	Step,             // The bound of the step of the interface.
	Deadline_Of_Work, // The deadline of the work that runs: a request, a flush, a check.
}

@(rodata)
wait_bound_words := [Wait_Bound]string {
	.Step             = "the bound of the step",
	.Deadline_Of_Work = "the deadline of the work",
}

// wait_bound_reached says if a wait of the interface reached a bound at
// now, and which one ended it: the earlier of the bound of the step and
// the deadline of the work. A deadline that passed before the wait started
// is the earlier one. On a tie, the step names the bound: the step is
// what waited.
wait_bound_reached :: proc "contextless" (now, step_limit, work_deadline: u64) -> (reached: bool, bound: Wait_Bound) {
	bound = work_deadline < step_limit ? .Deadline_Of_Work : .Step
	return now >= min(step_limit, work_deadline), bound
}

// The words of each request in a wait report. None is the work of the
// service outside a request of a client: the reads at the start, the
// check of the lockout hierarchy, the orderly shutdown.
@(rodata)
command_words := [Command]string {
	.None                 = "the work of the service itself",
	.Seal                 = "a seal",
	.Unseal               = "an unseal",
	.Measure_Start_Policy = "a measure of a start policy",
	.Pin_Read             = "a pin read",
	.Pin_Write            = "a pin write",
	.Seal_Authorized      = "an authorized seal",
	.Unseal_Authorized    = "an authorized unseal",
	.Owner_Protect        = "the owner hierarchy protection",
}
