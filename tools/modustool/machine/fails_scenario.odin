package machine

import "modustool:build"

// A start that fails: the boot image has no start policy. The boot display
// stays on the screen with the failure, and the machine does not stop.
// Before it, the trusted boot of a machine with no TPM: the boot program
// verifies the system description and says that nothing verified it, and
// the root service checks the boot image.
scenario_fails := [?]Step {
	// The test signing key, or the key of SYSTEM_SIGNING_KEY.
	{kind = .Wait, text = "boot program: the signature is from the "},
	{kind = .Wait, text = "boot program: verified by the boot program, which the firmware did not verify"},
	{kind = .Wait, text = "boot program: the kernel and each module and resource have the hash of the system description"},
	{kind = .Wait, text = "boot program: the firmware has no TPM protocol: the system description is not measured"},
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "root: ok"},
	{kind = .Wait, text = "root: the boot image agrees with the system description that the boot program verified: "},
	{kind = .Wait, text = "root: the system description is not measured into the TPM"},
	// The image has no start policy: the rescue is the same module, so the
	// machine has no start policy at all, and the boot display says it.
	{kind = .Wait, text = "root: the start policy is absent from the boot image: the rescue start policy starts"},
	{kind = .Wait, text = "root: no start policy at all: the rescue start policy is absent from the boot image"},
	{kind = .Wait, text = "root: the boot display shows the failure"},
	{kind = .Shot, text = "boot_fails"},
	{kind = .Quit},
}

// A start that fails ends when the tool ends QEMU: status 0.
fails_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_fails[:], {volume = build.BOOT_VOLUME_FAILS, output = TEST_OUTPUT_FAILS, exit_status = 0})
}

// A binary of the tool runs the test part fails only when it holds this file
// (test_parts.odin, test_part_scenario_register).
@(init)
fails_test_part_register :: proc "contextless" () {
	test_part_scenario_register("fails", fails_tests_run)
}
