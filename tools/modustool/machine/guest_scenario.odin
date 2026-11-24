package machine

import "core:fmt"
import "modustool:foundation"
import "modustool:build"

// A guest (src/md/features/guest.md; docs/ARCHITECTURE.md, "A guest"): one
// machine. The process guest_demo makes a guest process, maps one page of
// 16-bit code in it, and runs its guest processor: the `out` of the guest
// arrives as an exit record with the port 0x80 and the value 42, and its
// `hlt` ends it. An `int1` of the guest arrives as an exit Other with the
// exit code 0x88 (icebp). A switching mapping refuses a read-only and a part
// protection, and an instruction that writes the page that holds it ends
// its run with the exit Writes_Own_Page. Then a thread of the guest is
// refused.
//
// The kernel uses the AMD form of the support (SVM with nested paging). The
// test machine gets it from the host: from KVM on an AMD host whose module
// kvm_amd has nested virtualization on, or from the emulation of QEMU when
// the host has no KVM. The tool reads the host first. A host that gives no
// SVM (an Intel host gives VMX) runs the machine of the other outcome: the
// kernel says that no guest runs, and Guest_Run gives Unsupported. The tool
// then says that no guest ran, and why: the part is not a proof of a guest
// there.

TEST_OUTPUT_GUEST :: foundation.BUILD_FOLDER + "/test_output_guest.txt"

// The machine of a host that gives SVM to the test machine.
@(rodata)
scenario_guest := [?]Step {
	{kind = .Wait, text = "kernel: guest: AMD SVM with nested paging, ", fails_on = "kernel: guest: no guest runs: "},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"guest_demo\")"},
	{kind = .Wait, text = "guest_demo: Memory_Protect refused a read-only protection and a part of a switching mapping: as it must", fails_on = "guest_demo: failed: "},
	{kind = .Wait, text = "guest_demo: the guest wrote 42 to the port 0x80, then halted after it: as it must", fails_on = "guest_demo: failed: "},
	{kind = .Wait, text = "guest_demo: the int1 of the guest arrived as an exit Other with the exit code 0x88: as it must", fails_on = "guest_demo: failed: "},
	{kind = .Wait, text = "guest_demo: the instruction that writes its own page at 0x2010 ended the run with the exit Writes_Own_Page: as it must", fails_on = "guest_demo: failed: "},
	{kind = .Wait, text = "guest_demo: Process_Start of the guest gave Wrong_State: as it must", fails_on = "guest_demo: failed: "},
	{kind = .Wait, text = "guest_demo: ok"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// The machine of a host that gives no SVM to the test machine.
@(rodata)
scenario_guest_unsupported := [?]Step {
	{kind = .Wait, text = "kernel: guest: no guest runs: ", fails_on = "kernel: guest: AMD SVM with nested paging, "},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"guest_demo\")"},
	{kind = .Wait, text = "guest_demo: Guest_Run gave Operation_Unsupported with the error kind Unsupported: the processors of this machine have no virtualization support that the kernel uses, and no guest runs: as it must", fails_on = "guest_demo: failed: "},
	{kind = .Wait, text = "guest_demo: ok"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

guest_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	gives, reason := host_gives_guest_support()
	if gives {
		fmt.printfln("modustool: the part guest runs a guest: %s", reason)
		return machine_test(part, scenario_guest[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_GUEST, exit_status = build.MACHINE_STOP_OK})
	}
	fmt.printfln("modustool: the part guest runs NO guest on this host: %s; the machine checks only that Guest_Run refuses with Unsupported", reason)
	return machine_test(part, scenario_guest_unsupported[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_GUEST, exit_status = build.MACHINE_STOP_OK})
}

// A binary of the tool runs the test part guest only when it holds this file
// (test_parts.odin, test_part_scenario_register).
@(init)
guest_test_part_register :: proc "contextless" () {
	test_part_scenario_register("guest", guest_tests_run)
}
