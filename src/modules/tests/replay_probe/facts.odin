package replay_probe

import op "modus:contract/operation"

// Log facts of replay_probe, the machine test of the record and the replay
// of a process with a shared writer (src/md/features/record_and_replay.md).
// A Text field comes last, and holds its longest text and a zero byte.

// The verdict field holds "as it must" and a zero byte: 16 bytes.
@(log_fact = "replay_probe: the record holds the shared mapping, a delta of the shared page for each round, the cycle counter and cpuid, and ends with the stop of the reader: {verdict}")
Record_Checked :: struct {
	verdict: [16]u8,
}

@(log_fact = "replay_probe: the replay with no writer reached the end of the history with 0 divergences: {verdict}")
Replay_Checked :: struct {
	verdict: [16]u8,
}

@(log_fact = "replay_probe: a changed byte of the shared page in the history: the replay stopped at the first entry after it that carries the sum: {verdict}")
Divergence_Checked :: struct {
	verdict: [16]u8,
}

// What the record of the reader holds.
@(log_fact = "replay_probe: detail: the record: {points} input points, {shared_deltas} deltas of the shared page, {cycle_reads} reads of the cycle counter, {cpuid_reads} of cpuid")
Probe_Recorded :: struct {
	points:        u64,
	shared_deltas: u64,
	cycle_reads:   u64,
	cpuid_reads:   u64,
}

// How the replay with no writer ended.
@(log_fact = "replay_probe: detail: the replay: {divergences} divergences, at the input point {divergence_point}")
Probe_Replayed :: struct {
	divergences:      u64,
	divergence_point: u64,
}

// The divergence of the replay of the changed history: its Divergence_Kind
// word, its point and the point that the test process expected, the two
// sums, and the instruction address of the record there.
@(log_fact = "replay_probe: detail: the divergence: kind {kind}, input point {point}, expected {expected_point}, sum of the history {recorded_sum}, sum of the replay {replayed_sum}, instruction {recorded_instruction}")
Probe_Divergence :: struct {
	kind:                 u64,
	point:                u64,
	expected_point:       u64,
	recorded_sum:         u64,
	replayed_sum:         u64,
	recorded_instruction: u64,
}

// Each case held.
@(log_fact = "replay_probe: ok, {cases} cases: a record with a shared writer, its replay with no writer, and the first divergence")
Probe_Held :: struct {
	cases: u64,
}

// Some cases did not hold.
@(log_fact = "replay_probe: failed: {wrong_cases} cases of {cases}")
Probe_Failed :: struct {
	wrong_cases: u64,
	cases:       u64,
}

// A step of the test process failed with a status.
@(log_fact = "replay_probe: detail: {step} gave the status {status_word}")
Probe_Step_Failed :: struct {
	status_word: op.Status_Word,
	step:        [32]u8,
}

// A reader did not stop within the hang bound.
@(log_fact = "replay_probe: a reader did not stop")
Probe_Reader_Hung :: struct {}

// The context carried an unknown role word.
@(log_fact = "replay_probe: unknown role word {word}")
Probe_Bad_Role :: struct {
	word: u64,
}

@(log_fact = "replay_probe: no seed of the generator in the context")
Probe_No_Random_Seed :: struct {}

@(log_fact = "replay_probe: no boot image")
Probe_No_Boot_Image :: struct {}
