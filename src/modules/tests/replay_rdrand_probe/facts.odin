package replay_rdrand_probe

// Log facts of replay_rdrand_probe, the planted hardware randomness divergence
// probe for record and replay (src/md/features/record_and_replay.md).

@(log_fact = "replay_rdrand_probe: ran with cpuid rdrand {cpuid_rdrand}, rdrand ok {rdrand_ok}, checksum {checksum}")
Probe_Ran :: struct {
	cpuid_rdrand: u64,
	rdrand_ok:    u64,
	checksum:     u64,
}
