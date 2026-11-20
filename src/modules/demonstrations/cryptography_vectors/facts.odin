package cryptography_vectors

// The log facts of the demonstration cryptography_vectors
// (src/md/features/log_facts.md, "The facts of the demonstrations"): each
// vector and each speed, as records of fields. Each fact template is the
// sentence that the line wrote before it was a fact, so a wait of a machine
// test on that sentence, and the measure record that reads the seal, read
// it as before. A Text field comes last, and holds its longest text and a
// zero byte.

// A primitive against its published test vector: "passed" or "FAILED",
// then, for a primitive whose bad input this process gives, whether the
// module refused it with no byte given, or nothing.
@(log_fact = "cryptography_vectors: {primitive} ({standard}): {verdict}{refusal}")
Vector_Checked :: struct {
	verdict:   [8]u8,
	primitive: [32]u8,
	standard:  [24]u8,
	refusal:   [48]u8,
}

// The speed of one primitive: the mean of one call, and its rate.
@(log_fact = "cryptography_vectors: {primitive}: {call_time} ns for {call_bytes} bytes, {megabytes_in_one_second} MB/s")
Speed_Measured :: struct {
	call_time:               u64,
	call_bytes:              u64,
	megabytes_in_one_second: u64,
	primitive:               [32]u8,
}

// The time of one call of an export of the module with no work.
@(log_fact = "cryptography_vectors: one call of an export of the module, through its import slot: {call_time} ns")
Empty_Call_Measured :: struct {
	call_time: u64,
}
