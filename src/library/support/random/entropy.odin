package random

import "base:intrinsics"
import "modus:contract/blake3"
import op "modus:contract/operation"
import crypto "modus:support/cryptography/compatibility_crypto"

// The sources of entropy of the root service (docs/RANDOMNESS.md). The
// claim is no more than the sources: the processor's rdseed (an entropy
// source by its specification), else rdrand (a generator that the
// processor reseeds), else the jitter of the cycle counter, whose entropy
// this system does not measure and counts as 0 bits: a seed from it alone
// is "weak", and the window and the log say so.

DOMAIN_SEED :: "kernel random: the seed of the root service, version 1" // The context of the key derivation of a gathering: a hash of other bytes never gives this seed.
DOMAIN_RESEED :: "kernel random: a reseed, version 1" // The context of the key derivation of a reseed.
PROCESSOR_VALUES :: 8 // Values of 64 bits of rdseed or rdrand in a seed: 512 bits.
PROCESSOR_ATTEMPTS :: 32 // Tries for one value: rdseed can be empty for a while.
JITTER_SAMPLES :: 2048 // The deltas of the cycle counter in one gathering.
FRESH_LIMIT :: 10 * 1024 // Bytes that key_derive hashes at most: a gathering has 8320.

// How strong the source of a seed is (modus:contract/operation,
// Seed_Strength): each program receives it with its seed
// (`op.CONTEXT_VALUE_SEED_STRENGTH`), and `fill_for_a_key` refuses a seed
// below the strength that the caller asks. Its words are
// `op.seed_strength_names`.
Seed_Strength :: op.Seed_Strength

// What a gathering found: the window and the log show it.
Entropy_Report :: struct {
	rdseed_present:   bool, // The processor has rdseed.
	rdrand_present:   bool, // The processor has rdrand.
	rdseed_good:      u32, // Good values of rdseed.
	rdseed_refused:   u32, // Carry clear (empty), all ones, or a value that came before.
	rdrand_good:      u32, // Good values of rdrand.
	rdrand_refused:   u32, // Refused values of rdrand: carry clear, all ones, or repeated.
	jitter_samples:   u32, // The deltas of the cycle counter that the gathering hashed.
	jitter_distinct:  u32, // Distinct low bytes of the deltas: a sign of life of the counter, not a measure of entropy.
	device_present:   bool, // The machine has an entropy device, and its service started.
	device_bytes:     u32, // Bytes of the entropy device that device_bytes_mix mixed in, after the gathering. The root service counts the reads of its start here, and those of the fresh bytes in a report of its own.
	device_reads_refused: u32, // Reads of the entropy device that added nothing: no byte, one value only, the read before again, or a read that the entropy service refused.
	strength:         Seed_Strength, // The strength of the seed: the entropy device does not change it.
}

// Cycles_Read reads the cycle counter.
Cycles_Read :: #type proc "contextless" () -> u64

// Processor_Read is a read of rdseed or rdrand: false when the processor
// gave none. The tests give their own.
Processor_Read :: #type proc "contextless" () -> (value: u64, ok: bool)

// One instruction of the processor as a template: the value, and the carry
// flag of the processor, which says if the value is good. Volatile: each
// use runs the instruction again. An inline instruction that the compiler
// took as a pure function kept one value for a loop (a machine test found
// rdrand with 1 good value and 255 "repeated" ones).
processor_seed_value :: asm() -> (value: u64, good: bool) [
	good = %flags.c,
	#volatile,
] {
	rdseed value
}

// processor_random_value is rdrand, as processor_seed_value is rdseed.
processor_random_value :: asm() -> (value: u64, good: bool) [
	good = %flags.c,
	#volatile,
] {
	rdrand value
}

// rdseed_read reads one value of rdseed. A value 0 is refused.
rdseed_read :: proc "contextless" () -> (value: u64, ok: bool) {
	value, ok = processor_seed_value()
	return value, ok && value != 0
}

// rdrand_read reads one value of rdrand. A value 0 is refused.
rdrand_read :: proc "contextless" () -> (value: u64, ok: bool) {
	value, ok = processor_random_value()
	return value, ok && value != 0
}

// processor_features says if the processor has rdrand (CPUID 1, ECX bit
// 30) and rdseed (CPUID 7, EBX bit 18). An instruction that the processor
// does not have stops the program: it is run only when present.
processor_features :: proc "contextless" () -> (rdrand, rdseed: bool) {
	highest, _, _, _ := intrinsics.x86_cpuid(0, 0)
	_, _, features, _ := intrinsics.x86_cpuid(1, 0)
	rdrand = features >> 30 & 1 == 1
	if highest >= 7 {
		_, extended, _, _ := intrinsics.x86_cpuid(7, 0)
		rdseed = extended >> 18 & 1 == 1
	}
	return
}

// processor_values reads PROCESSOR_VALUES good values. A value that is 0
// (carry clear), all ones (a known fault of some processors of AMD), or
// equal to one before it is refused and read again.
processor_values :: proc "contextless" (read: Processor_Read, values: ^[PROCESSOR_VALUES]u64, good, refused: ^u32) -> bool {
	count := 0
	for _ in 0 ..< PROCESSOR_VALUES * PROCESSOR_ATTEMPTS {
		if count == PROCESSOR_VALUES {
			break
		}
		value, ok := read()
		repeated := false
		for earlier in values[:count] {
			repeated ||= earlier == value
		}
		if !ok || value == max(u64) || repeated {
			refused^ += 1
			continue
		}
		values[count] = value
		count += 1
		good^ += 1
	}
	return count == PROCESSOR_VALUES
}

// jitter_values reads the cycle counter around a short loop, JITTER_SAMPLES
// times: the deltas depend on interrupts, caches and, under QEMU, the exits
// of the virtual machine.
jitter_values :: proc "contextless" (deltas: ^[JITTER_SAMPLES]u32, cycles: Cycles_Read) -> (distinct_low_bytes: u32) {
	seen: [256]bool
	last := cycles()
	for &delta in deltas {
		spin: u64
		for step in 0 ..< 64 {
			spin += u64(step) * last
		}
		intrinsics.volatile_store(&spin, spin)
		now := cycles()
		delta = u32(now - last)
		last = now
		if !seen[delta & 0xFF] {
			seen[delta & 0xFF] = true
			distinct_low_bytes += 1
		}
	}
	return
}

// key_derive gives the BLAKE3 hash of a domain text, a key and the fresh
// bytes, each with its length before it: no two inputs give the same bytes
// to hash.
// Its frames and those of BLAKE3 under it hold the key and the chaining
// values: its callers erase the stack below them after it returns.
key_derive :: #force_no_inline proc "contextless" (domain: string, key: []u8, fresh: []u8) -> [SEED_SIZE]u8 {
	input: [128 + 64 + 3 * 8 + FRESH_LIMIT]u8
	count := 0
	put :: proc "contextless" (input: []u8, count: ^int, bytes: []u8) {
		length := u64(len(bytes))
		for index in 0 ..< 8 {
			input[count^ + index] = u8(length >> (8 * uint(index)))
		}
		count^ += 8
		copy(input[count^:], bytes)
		count^ += len(bytes)
	}
	ensure_contextless(len(domain) <= 128 && len(key) <= 64 && len(fresh) <= FRESH_LIMIT, "random: key_derive takes FRESH_LIMIT fresh bytes at most")
	put(input[:], &count, transmute([]u8)domain)
	put(input[:], &count, key)
	put(input[:], &count, fresh)
	hash := blake3.hash(input[:count])
	crypto.zero_explicit(&input, size_of(input))
	return hash
}

// Entropy_Sources are the reads of a gathering: the processor and the cycle
// counter of the machine, or those of a test.
Entropy_Sources :: struct {
	rdseed: Processor_Read, // nil: the processor has no rdseed.
	rdrand: Processor_Read, // nil: the processor has no rdrand.
	cycles: Cycles_Read, // The cycle counter.
}

// sources_of_the_processor gives the reads that the processor has.
sources_of_the_processor :: proc "contextless" () -> Entropy_Sources {
	rdrand, rdseed := processor_features()
	cycles :: proc "contextless" () -> u64 {
		return u64(intrinsics.read_cycle_counter())
	}
	return {rdseed = rdseed ? rdseed_read : nil, rdrand = rdrand ? rdrand_read : nil, cycles = cycles}
}

// entropy_gather makes the seed of the root service: BLAKE3 of the values
// of rdseed, of rdrand and of the jitter of the cycle counter, all of them.
// The report says which sources gave good values; the strength is the
// strongest source that gave all its values.
entropy_gather :: proc "contextless" (sources: Entropy_Sources, report: ^Entropy_Report) -> (seed: [SEED_SIZE]u8) {
	Gathered :: struct {
		rdseed: [PROCESSOR_VALUES]u64,
		rdrand: [PROCESSOR_VALUES]u64,
		jitter: [JITTER_SAMPLES]u32,
	}
	gathered: Gathered
	report^ = {strength = .Weak, rdseed_present = sources.rdseed != nil, rdrand_present = sources.rdrand != nil}
	if sources.rdrand != nil && processor_values(sources.rdrand, &gathered.rdrand, &report.rdrand_good, &report.rdrand_refused) {
		report.strength = .Processor
	}
	if sources.rdseed != nil && processor_values(sources.rdseed, &gathered.rdseed, &report.rdseed_good, &report.rdseed_refused) {
		report.strength = .Entropy
	}
	report.jitter_distinct = jitter_values(&gathered.jitter, sources.cycles)
	report.jitter_samples = JITTER_SAMPLES
	seed = key_derive(DOMAIN_SEED, nil, ([^]u8)(&gathered)[:size_of(gathered)])
	crypto.erase_stack_below_the_caller()
	crypto.zero_explicit(&gathered, size_of(gathered))
	return seed
}

// The entropy device (src/md/features/entropy_device.md): the root service
// mixes the bytes of each read of it into its generator, after the
// gathering. The bytes add to the key and never replace it, so a device that
// lies leaves the key as strong as the processor made it. A read that can
// add nothing is refused and counted, and the key stays as it was.

DOMAIN_DEVICE_READ :: "kernel random: a read of an entropy device, version 1" // The context of the hash of a read, which the mixer keeps to find a read that comes again.

// What a mix did with one read of the entropy device.
Device_Read_Outcome :: enum u8 {
	Mixed     = 0, // The bytes are in the key.
	Empty     = 1, // The read has no byte.
	One_Value = 2, // Each byte of the read has one value: zeros, all ones, or another byte again.
	Repeated  = 3, // The read has the bytes of the read before it.
}

// Device_Mixing is what the mixer keeps between two reads: the hash of the
// last read, not its bytes.
Device_Mixing :: struct {
	last_read_hash: [SEED_SIZE]u8,
	has_last_read:  bool,
}

// device_bytes_mix mixes the bytes of one read of the entropy device into a
// generator (reseed), unless the read can add nothing: no byte, one value
// only, or the bytes of the read before. A refused read leaves the key as
// it was and counts in report.device_reads_refused; a mixed read counts its
// bytes in report.device_bytes. The strength of the report does not change.
device_bytes_mix :: proc "contextless" (generator: ^Generator, mixing: ^Device_Mixing, bytes: []u8, report: ^Entropy_Report) -> Device_Read_Outcome {
	outcome := Device_Read_Outcome.Mixed
	if len(bytes) == 0 {
		outcome = .Empty
	} else {
		one_value := true
		for byte in bytes[1:] {
			one_value &&= byte == bytes[0]
		}
		hash := key_derive(DOMAIN_DEVICE_READ, nil, bytes)
		crypto.erase_stack_below_the_caller()
		if one_value {
			outcome = .One_Value
		} else if mixing.has_last_read && hash == mixing.last_read_hash {
			outcome = .Repeated
		}
		mixing.last_read_hash, mixing.has_last_read = hash, true
	}
	if outcome != .Mixed {
		report.device_reads_refused += 1
		return outcome
	}
	reseed(generator, bytes)
	report.device_bytes += u32(min(len(bytes), int(max(u32))))
	return .Mixed
}

// The values of the context of a program that shows the seed of the system
// (`randomness`): the root service writes its report in the values 0 to 7
// (the values 9 to 12 are the seed of the program).
REPORT_VALUES :: 8

// report_values_write writes a report in the values 0 to 7 of a context.
// Value 0: the strength in its low byte, then the presence of rdseed, of
// rdrand and of the entropy device in the bits 8, 9 and 10. Value 7: the
// bytes of the device in its low half, its refused reads in its high half.
report_values_write :: proc "contextless" (report: ^Entropy_Report, values: ^[op.CONTEXT_VALUES]u64) {
	values[0] = u64(report.strength) | u64(report.rdseed_present) << 8 | u64(report.rdrand_present) << 9 | u64(report.device_present) << 10
	values[1] = u64(report.rdseed_good)
	values[2] = u64(report.rdseed_refused)
	values[3] = u64(report.rdrand_good)
	values[4] = u64(report.rdrand_refused)
	values[5] = u64(report.jitter_samples)
	values[6] = u64(report.jitter_distinct)
	values[7] = u64(report.device_bytes) | u64(report.device_reads_refused) << 32
}

// report_values_read reads a report from the values 0 to 7 of a context.
// The values come from the starter: a strength that names no member is
// refused (ok false), and never taken for a strength.
report_values_read :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64) -> (report: Entropy_Report, ok: bool) {
	report.strength = op.seed_strength_of_word(values[0] & 0xFF) or_return
	report.rdseed_present = values[0] >> 8 & 1 != 0
	report.rdrand_present = values[0] >> 9 & 1 != 0
	report.device_present = values[0] >> 10 & 1 != 0
	report.rdseed_good = u32(values[1])
	report.rdseed_refused = u32(values[2])
	report.rdrand_good = u32(values[3])
	report.rdrand_refused = u32(values[4])
	report.jitter_samples = u32(values[5])
	report.jitter_distinct = u32(values[6])
	report.device_bytes = u32(values[7])
	report.device_reads_refused = u32(values[7] >> 32)
	ok = true
	return
}
