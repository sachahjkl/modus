// Test-only planted hardware randomness divergence probe for process record
// and replay (src/md/features/record_and_replay.md).
//
// This module intentionally executes `rdrand` without consulting `cpuid`,
// exercising the unrecordable-instruction exception of record and replay:
// - While recorded, CPUID faulting hides the `rdrand` feature bit (leaf 1,
//   ECX bit 30 is 0).
// - Executing `rdrand` anyway produces a fresh hardware random value on each
//   run; the module mixes it into a checksum and passes that checksum as an
//   argument of `Word_Wake`, then stops cleanly.
// - On replay, `rdrand` yields a different value, so the kernel stops the
//   replay at the exact `Word_Wake` input point with `Unexpected_Arguments`.
//
// Excluded from every release boot image (group Tests).
package replay_rdrand_probe

import "base:intrinsics"
import "modus:system"

// Small fixed budget: one thread and no window, objects, or child processes.
MODULE_BUDGET :: system.Stated_Budget{processes = 1, threads = 1}

// Maximum retry attempts if the hardware random generator reports carry clear.
RDRAND_ATTEMPTS :: 32

// Unwaited word whose wake carries the checksum derived from `rdrand` into
// a kernel entry argument compared during replay.
checksum_word: u32

// planted_rdrand_value executes the hardware `rdrand` instruction directly.
// Volatile prevents the compiler from hoisting or caching the value.
planted_rdrand_value :: asm() -> (value: u64, ok: bool) [
	ok = %flags.c,
	#volatile,
] {
	rdrand value
}

// mix_checksum folds the hardware random value into a non-zero 64-bit value
// carried by the kernel entry argument.
mix_checksum :: proc "contextless" (raw: u64) -> u64 {
	state := raw ~ 0x9E37_79B9_7F4A_7C15
	state = (state * 0xBF58_476D_1CE4_E5B9) + 1
	state ~= state >> 27
	return state | 1
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	_ = ctx
	_, _, leaf1_ecx, _ := intrinsics.x86_cpuid(1, 0)
	cpuid_rdrand := (leaf1_ecx >> 30) & 1

	raw_value: u64
	got_random := false
	for _ in 0 ..< RDRAND_ATTEMPTS {
		value, ok := planted_rdrand_value()
		if ok && value != 0 && value != max(u64) {
			raw_value = value
			got_random = true
			break
		}
	}
	checksum := mix_checksum(raw_value)
	// Put the rdrand-derived checksum directly in a kernel entry argument so
	// replay detects the exact divergence point and both checksums.
	system.word_wake(&checksum_word, checksum)
	system.log_fact(.Info, Probe_Ran{cpuid_rdrand = u64(cpuid_rdrand), rdrand_ok = u64(got_random ? 1 : 0), checksum = checksum})
	system.stop(.Done)
}
