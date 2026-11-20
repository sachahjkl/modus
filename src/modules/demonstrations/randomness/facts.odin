package randomness

import "modus:contract/value_kinds"

// The log facts of randomness (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence, and the bytes that a test keeps
// from it, read it as before. The Text fields are the last fields: the
// serial line of a fact stops at its last byte that is not zero.
//
// The rate of the generator is a field of hundredths of megabytes in one
// second, written with two decimals: the line wrote one decimal, which no
// field kind writes for a number that is not a time.

// The time of 4 MiB from the generator, and its rate.
@(log_fact = "randomness: the generator: 4 MiB in {elapsed}, {rate} MB/s")
Generator_Measured :: struct {
	elapsed: value_kinds.Time_In_Microseconds,
	rate:    value_kinds.Hundredths,
}

// The context of the process holds no random seed.
@(log_fact = "randomness: no random seed in the context")
No_Random_Seed :: struct {}

// The machine has no entropy device.
@(log_fact = "randomness: the entropy device: absent")
Entropy_Device_Absent :: struct {}

// The bytes of the Text field of the name of a seed strength: the longest,
// "weak (the cycle counter only)", has 29 bytes.
STRENGTH_FIELD_BYTES :: 32
// The bytes of the Text field of the first bytes of the stream: 16 bytes in
// 32 hexadecimal digits and 3 spaces.
FIRST_BYTES_FIELD_BYTES :: 40

// The context holds a seed strength that names no strength.
@(log_fact = "randomness: the root service gave the seed strength {strength_word}, which names no strength: nothing is shown")
Seed_Strength_Unknown :: struct {
	strength_word: u64,
}

// The strength of the seed of the system, and the first bytes of the
// stream of this process, which a test compares between two processes.
@(log_fact = "randomness: the seed of the system: strength {strength}; the first bytes of the stream of this process: {first_bytes}")
Seed_Shown :: struct {
	strength:    [32]u8,
	first_bytes: [40]u8,
}

// The entropy device: the bytes mixed after the gathering, and the reads
// that added nothing.
@(log_fact = "randomness: the entropy device: {device_bytes} mixed after the gathering; refused reads: {refused_reads}")
Entropy_Device_Shown :: struct {
	device_bytes:  value_kinds.Size_In_Bytes,
	refused_reads: u64,
}

// The least and the most count of the 16 values of the high 4 bits of each
// byte of 1 MiB.
@(log_fact = "randomness: 1 MiB by the high 4 bits of each byte: from {least} to {most} in each of 16 (the mean is 65536)")
Byte_Counts_Shown :: struct {
	least: u64,
	most:  u64,
}

// The fresh bytes of the root service reached the generator of this
// process.
@(log_fact = "randomness: the fresh bytes of the root service are mixed into the generator of this process, at the change {change} of its page")
Fresh_Bytes_Mixed :: struct {
	change: u64,
}

#assert(size_of(Seed_Shown) == STRENGTH_FIELD_BYTES + FIRST_BYTES_FIELD_BYTES)
#assert(FIRST_BYTES_FIELD_BYTES > 2 * len(first_bytes) + len(first_bytes) / 4 - 1)
