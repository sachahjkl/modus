package replay_probe

// Log facts of replay_probe, the test module for single-thread record and
// replay (src/md/features/record_and_replay.md).

// Deterministic run finished with its computed checksum, measured elapsed time,
// and observed CPUID feature words.
@(log_fact = "replay_probe: checksum {checksum}, elapsed {elapsed_nanoseconds} ns, leaf1_ecx {leaf1_ecx}, leaf7_ebx {leaf7_ebx}, leaf7_ecx {leaf7_ecx}")
Probe_Summary :: struct {
	checksum:            u64,
	elapsed_nanoseconds: u64,
	leaf1_ecx:           u64,
	leaf7_ebx:           u64,
	leaf7_ecx:           u64,
}

// The opt-in divergence path executed before stopping.
@(log_fact = "replay_probe: opt-in divergence path {mode} ran, value {value}")
Probe_Divergence_Triggered :: struct {
	mode:  u64,
	value: u64,
}

// The context carried an unknown mode word.
@(log_fact = "replay_probe: unknown probe mode word {word}")
Probe_Bad_Mode :: struct {
	word: u64,
}
