package machine

import "core:fmt"
import "core:strings"
import rd "modus:contract/root_delegation"
import "modus:contract/system_description"
import "modustool:build"
import "modustool:foundation"

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
	machine_test(part, scenario_fails[:], {volume = build.BOOT_VOLUME_FAILS, output = TEST_OUTPUT_FAILS, exit_status = 0}) or_return
	return role_contract_hashes_check(TEST_OUTPUT_FAILS)
}

// role_contract_hashes_check compares the hash of the role contracts that
// the root service wrote at its start with the hash that the same
// procedure gives on the host: a contract that a machine reads in another
// form is refused before any plan names a holder of its role.
role_contract_hashes_check :: proc(output: string) -> bool {
	text, readable := log_file_rendered(output)
	if !readable {
		return false
	}
	digest, contracts, encoded := rd.role_contracts_digest()
	if encoded != contracts {
		fmt.eprintfln("modustool: test failed: %d of the %d role contracts pass their canonical encoding on the host", encoded, contracts)
		return false
	}
	digits := system_description.hexadecimal(digest)
	wanted := fmt.tprintf("root: the role contracts: %d of %d encoded, digest %s", encoded, contracts, string(digits[:]))
	if !strings.contains(text, wanted) {
		marker := "root: the role contracts: "
		at := strings.index(text, marker)
		found := at < 0 ? "no line" : text[at:][:min(len(text) - at, len(marker) + 120)]
		fmt.eprintfln("modustool: test failed: the root service computes the role contracts in another form than the host: %s; the host: %s", found, wanted)
		return false
	}
	foundation.test_passed_print("the root service computes the hash of each of the %d role contracts as the host does", contracts)
	return true
}

// A binary of the tool runs the test part fails only when it holds this file
// (test_parts.odin, test_part_scenario_register).
@(init)
fails_test_part_register :: proc "contextless" () {
	test_part_scenario_register("fails", fails_tests_run)
}