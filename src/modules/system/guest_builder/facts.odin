package guest_builder_module

import "modus:contract/call_outcome"
import "modus:contract/value_kinds"

// Log facts of the freestanding sandboxed guest builder module.
// Every record has zero padding and uses literal byte array sizes so module
// description extraction validates each layout deterministically.

// A guest build finished cleanly with exit code 0 and produced a verified
// canonical MODTREE1 output tree.
@(log_fact = "guest_builder: build succeeded in {guest_exits} exits, wrote {tree_bytes} canonical tree bytes, hash {output_hash}")
Build_Completed :: struct {
	guest_exits: u64,
	tree_bytes:  u64,
	output_hash: value_kinds.Hash_Field,
}

// A guest build was refused or failed (spec refusal, sandbox violation,
// non-zero guest exit, timeout, or corrupt output disk).
@(log_fact = "guest_builder: build refused with refusal {refusal_code}, exit code {exit_code}, sandbox violations {violations}")
Build_Refused :: struct {
	refusal_code: u64,
	exit_code:    u64,
	violations:   u64,
}

// The kernel image of a build is not one that the boot protocol of Linux
// loads: the word of a guest_os.Linux_Boot_Refusal.
@(log_fact = "guest_builder: the kernel image is refused by the Linux boot protocol: refusal {refusal_code}")
Kernel_Refused :: struct {
	refusal_code: u64,
}

// The initial archive of a build is refused before its guest runs: the word
// of a guest_builder.Guest_Builder_Refusal (a size, a place or a hash that
// does not match the spec).
@(log_fact = "guest_builder: the initial archive of {archive_bytes} bytes is refused: refusal {refusal_code}")
Initial_Archive_Refused :: struct {
	refusal_code:  u64,
	archive_bytes: u64,
}

// The host processor lacks kernel-supported virtualization for Guest_Run.
@(log_fact = "guest_builder: Guest_Run gave Unsupported: this processor has no virtualization support for guest builds")
Guests_Unsupported :: struct {}

// A kernel operation returned an unexpected status while setting up or
// running the guest processor.
@(log_fact = "guest_builder: failed: {step} gave {status_word}")
Step_Failed :: struct {
	status_word: call_outcome.Call_Outcome_Word,
	step:        [40]u8,
}
