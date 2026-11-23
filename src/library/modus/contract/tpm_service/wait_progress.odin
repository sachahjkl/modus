package tpm_service

// The progress of a long wait of the path of a key: a step of the interface
// of the TPM, a request of the service, and the wait of a client for its
// answer (src/md/features/tpm_sealed_machine_key.md, "A wait that is long").
// The bounds of these waits stay long, because a slow TPM that works must
// not fail; the reports make a stall readable before its bound.

// The time between two progress reports of one wait.
WAIT_PROGRESS_INTERVAL_MILLISECONDS :: 30_000

// The state of the reports of one wait: when it started, and how many
// reports it wrote.
Wait_Progress :: struct {
	started: u64, // The time of the start of the wait, in milliseconds of the system clock.
	reports: u64, // The reports written so far.
}

// wait_progress_start gives the state of a wait that starts at now.
wait_progress_start :: proc "contextless" (now: u64) -> Wait_Progress {
	return {started = now}
}

// wait_progress_next gives the time of the next report: the start plus one
// more interval than the reports written. A time past the largest value of
// the clock gives that largest value, so a sleep until it never wraps.
wait_progress_next :: proc "contextless" (progress: Wait_Progress) -> u64 {
	// The count is compared before the addition: reports + 1 wraps at
	// the largest count.
	if progress.reports >= max(u64) / WAIT_PROGRESS_INTERVAL_MILLISECONDS {
		return max(u64)
	}
	count := progress.reports + 1
	offset := count * WAIT_PROGRESS_INTERVAL_MILLISECONDS
	if progress.started > max(u64) - offset {
		return max(u64)
	}
	return progress.started + offset
}

// wait_progress_due says if the wait must write a report at now, and counts
// it. passed_seconds is the time that the report names: its count times the
// interval, a fixed number that a test can wait for, not the time of the
// clock at the check. One check writes one report at most: a check that
// comes late writes the reports one after another, so the report of 60 s
// always comes, after the report of 30 s. A time before the start is no
// report: the clock of the system does not go back.
wait_progress_due :: proc "contextless" (progress: ^Wait_Progress, now: u64) -> (due: bool, passed_seconds: u64) {
	if now < progress.started || now < wait_progress_next(progress^) || wait_progress_next(progress^) == max(u64) {
		return false, 0
	}
	progress.reports += 1
	return true, progress.reports * (WAIT_PROGRESS_INTERVAL_MILLISECONDS / 1000)
}

// The words of each request, for the reports of a wait: a wait outside a
// request of a client (the reads at the start, the check of the lockout
// hierarchy, the orderly shutdown) names None.
@(rodata)
command_words := [Command]string {
	.None                 = "no request",
	.Seal                 = "seal",
	.Unseal               = "unseal",
	.Measure_Start_Policy = "measure of a start policy",
	.Pin_Read             = "pin read",
	.Pin_Write            = "pin write",
}
