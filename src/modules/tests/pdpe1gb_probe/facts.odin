package pdpe1gb_probe

import "modus:contract/value_kinds"

// The log facts of the 4 GiB pdpe1gb live machine probe
// (src/md/features/frames_of_a_process.md).

@(log_fact = "pdpe1gb_probe: WRONG: {what} (got {got}, expected {expected})")
Wrong :: struct {
	got:      u64,
	expected: u64,
	what:     value_kinds.Text_View,
}

@(log_fact = "pdpe1gb_probe: refusals checked")
Refusals_Checked :: struct {}

@(log_fact = "pdpe1gb_probe: committed 1 GiB run, free_runs_1g {before} -> {after}")
Run_Committed :: struct {
	before: u64,
	after:  u64,
}

@(log_fact = "pdpe1gb_probe: mapped 1 GiB page entry: entries_1g={entries_1g}, entries_2m={entries_2m}, entries_4k={entries_4k}")
Mapped_1G :: struct {
	entries_1g: u64,
	entries_2m: u64,
	entries_4k: u64,
}

@(log_fact = "pdpe1gb_probe: demoted 1 GiB page with zero budget cost: entries_1g={entries_1g}, entries_2m={entries_2m}, entries_4k={entries_4k}")
Demoted_1G :: struct {
	entries_1g: u64,
	entries_2m: u64,
	entries_4k: u64,
}

@(log_fact = "pdpe1gb_probe: ok, 1 GiB run zeroed, mapped, demoted, and returned (free_runs_1g={free_runs_1g})")
Probe_Passed :: struct {
	free_runs_1g: u64,
}
