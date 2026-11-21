// Test module for single-thread record and replay
// (src/md/features/record_and_replay.md).
//
// Runs deterministic arithmetic, reads the cycle counter through
// system.nanoseconds, queries CPUID leaves 0, 1 and 7, logs a summary fact,
// and stops cleanly. An opt-in context mode executes an extra nondeterministic
// divergence step so replay proves that divergence is caught immediately.
package replay_probe

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:support/system"

// Working memory: 128 pages for the stack and probe scratch. Threads: 1, the main thread of the probe.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 128, processes = 1, threads = 1}

COMPUTATION_ROUNDS :: u64(256)

// Selected by ctx.values[0]. Zero is the deterministic recording/replay run.
Probe_Mode :: enum u64 {
	Deterministic         = 0,
	Diverge_Operation     = 1,
	Diverge_Cpuid         = 2,
	Diverge_Cycle_Counter = 3,
}

// mix_deterministic runs a pure integer mixing loop whose result depends only
// on its inputs.
mix_deterministic :: proc "contextless" (seed: u64, rounds: u64) -> u64 {
	state := seed ~ 0x9E37_79B9_7F4A_7C15
	for step in u64(0) ..< rounds {
		state = (state * 0xBF58_476D_1CE4_E5B9) + (step * 2 + 1)
		state ~= state >> 27
	}
	return state
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	mode_word: u64
	if ctx != nil {
		mode_word = ctx.values[0]
	}
	mode, mode_ok := enum_word.member_of_word(Probe_Mode, mode_word)
	if !mode_ok {
		system.log_fact(.Error, Probe_Bad_Mode{word = mode_word})
		system.stop(.Refused)
	}

	started := system.nanoseconds()
	checksum := mix_deterministic(started, COMPUTATION_ROUNDS)

	highest_leaf, _, _, _ := intrinsics.x86_cpuid(0, 0)
	_, _, leaf1_ecx, _ := intrinsics.x86_cpuid(1, 0)
	leaf7_ebx, leaf7_ecx: u32
	if highest_leaf >= 7 {
		_, leaf7_ebx, leaf7_ecx, _ = intrinsics.x86_cpuid(7, 0)
	}
	checksum = mix_deterministic(checksum ~ u64(leaf1_ecx) ~ (u64(leaf7_ebx) << 32) ~ u64(leaf7_ecx), 32)

	// Opt-in divergence paths for verifying replay divergence detection.
	switch mode {
	case .Deterministic:
	case .Diverge_Operation:
		system.log_fact(.Info, Probe_Divergence_Triggered{mode = u64(mode), value = checksum})
	case .Diverge_Cpuid:
		ext_eax, _, _, _ := intrinsics.x86_cpuid(0x8000_0001, 0)
		checksum = mix_deterministic(checksum ~ u64(ext_eax), 8)
		system.log_fact(.Info, Probe_Divergence_Triggered{mode = u64(mode), value = u64(ext_eax)})
	case .Diverge_Cycle_Counter:
		extra := system.nanoseconds()
		checksum = mix_deterministic(checksum ~ extra, 8)
		system.log_fact(.Info, Probe_Divergence_Triggered{mode = u64(mode), value = extra})
	}

	finished := system.nanoseconds()
	elapsed := finished >= started ? finished - started : 0
	checksum = mix_deterministic(checksum ~ elapsed, 16)

	system.log_fact(.Info, Probe_Summary {
		checksum            = checksum,
		elapsed_nanoseconds = elapsed,
		leaf1_ecx           = u64(leaf1_ecx),
		leaf7_ebx           = u64(leaf7_ebx),
		leaf7_ecx           = u64(leaf7_ecx),
	})
	system.stop(.Done)
}
