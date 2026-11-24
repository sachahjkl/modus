package machine

import "core:fmt"
import "modus:contract/system_description"
import "modustool:build"
import "modustool:foundation"

// The machine test of the exact release boot image
// (src/md/infrastructure/release_image.md, "The release boot image holds no
// test module"): verifies that BOOT_VOLUME_SECURE_BOOT holds zero test modules
// and matches release_boot_image_of(BOOT_IMAGE), then boots it under Secure
// Boot with the test keys to "root: the machine is usable".

TEST_OUTPUT_RELEASE_BOOT_IMAGE :: foundation.BUILD_FOLDER + "/test_output_release_boot_image.txt"

scenario_release_boot_image := [?]Step {
	{kind = .Wait, text = "boot program: started", seconds = TPM_MACHINE_FIRST_WAIT_SECONDS},
	{kind = .Wait, text = SECURE_BOOT_VERIFIED_LINE, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "boot program: the kernel and each module and resource have the hash of the system description", seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "root: verified by the firmware (Secure Boot), then by the boot program", seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "root: the boot image agrees with the system description that the boot program verified: ", seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "root: the machine is usable, by the start policy ", any_order = true, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Quit},
}

// release_image_part_tests_run checks that the signed Secure Boot volume holds
// the exact release boot image derived from the build (zero test modules) and
// boots it under Secure Boot to a usable machine.
release_image_part_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	tested_image := foundation.read_file(build.BOOT_IMAGE) or_return
	kernel_module := foundation.read_file(foundation.module_path(system_description.KERNEL_ENTRY_NAME)) or_return
	if problem := build.release_volume_problem(build.BOOT_VOLUME_SECURE_BOOT, .Test_Keys_Allowed, tested_image, kernel_module); problem != "" {
		fmt.eprintfln("modustool: test failed: %s is not the exact release boot image: %s", build.BOOT_VOLUME_SECURE_BOOT, problem)
		return false
	}
	foundation.test_passed_print("%s holds the exact release boot image with no test module", build.BOOT_VOLUME_SECURE_BOOT)
	machine_test(part, scenario_release_boot_image[:], {volume = build.BOOT_VOLUME_SECURE_BOOT, output = TEST_OUTPUT_RELEASE_BOOT_IMAGE, exit_status = 0, firmware = .With_Secure_Boot}) or_return
	foundation.test_passed_print("the exact release boot image in %s booted with Secure Boot on to a usable machine", build.BOOT_VOLUME_SECURE_BOOT)
	return true
}

// A binary of the tool runs the test part release_image only when it holds
// this file (test_parts.odin, test_part_scenario_register).
@(init)
release_image_test_part_register :: proc "contextless" () {
	test_part_scenario_register("release_image", release_image_part_tests_run)
}
