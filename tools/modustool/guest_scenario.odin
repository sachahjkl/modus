package modustool

import "core:fmt"
import "core:os"
import "core:strings"

// A guest (src/md/features/guest.md; docs/ARCHITECTURE.md, "A guest"): one
// machine. The program guest_demo makes a guest program, maps one page of
// 16-bit code in it, and runs its guest processor: the `out` of the guest
// arrives as an exit record with the port 0x80 and the value 42, and its
// `hlt` ends it. An `int1` of the guest arrives as an exit Other with the
// exit code 0x88 (icebp). Then a thread of the guest is refused.
//
// The kernel uses the AMD form of the support (SVM with nested paging). The
// test machine gets it from the host: from KVM on an AMD host whose module
// kvm_amd has nested virtualization on, or from the emulation of QEMU when
// the host has no KVM. The tool reads the host first. A host that gives no
// SVM (an Intel host gives VMX) runs the machine of the other outcome: the
// kernel says that no guest runs, and Guest_Run gives Unsupported. The tool
// then says that no guest ran, and why: the part is not a proof of a guest
// there.

TEST_OUTPUT_GUEST :: BUILD_FOLDER + "/test_output_guest.txt"

// The machine of a host that gives SVM to the test machine.
@(rodata)
scenario_guest := [?]Step {
	{kind = .Wait, text = "kernel: guest: AMD SVM with nested paging, ", fails_on = "kernel: guest: no guest runs: "},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"guest_demo\")"},
	{kind = .Wait, text = "guest_demo: the guest wrote 42 to the port 0x80, then halted after it: as it must", fails_on = "guest_demo: failed: "},
	{kind = .Wait, text = "guest_demo: the int1 of the guest arrived as an exit Other with the exit code 0x88: as it must", fails_on = "guest_demo: failed: "},
	{kind = .Wait, text = "guest_demo: Program_Start of the guest gave Bad_State: as it must", fails_on = "guest_demo: failed: "},
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
	{kind = .Wait, text = "guest_demo: Guest_Run gave Bad_Operation with the error kind Unsupported: the processors of this machine have no virtualization support that the kernel uses, and no guest runs: as it must", fails_on = "guest_demo: failed: "},
	{kind = .Wait, text = "guest_demo: ok"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// host_gives_guest_support says if the test machine of this host has SVM
// with nested paging, and why. Without KVM, QEMU emulates the processor of
// `-cpu max`, which has both. With KVM, the machine has SVM only on an AMD
// host whose module kvm_amd has nested virtualization on.
host_gives_guest_support :: proc() -> (gives: bool, reason: string) {
	if !os.exists("/dev/kvm") {
		return true, "QEMU emulates the processor (no KVM), with SVM and nested paging"
	}
	bytes, err := os.read_entire_file("/proc/cpuinfo", context.temp_allocator)
	if err != nil {
		return false, "the tool cannot read /proc/cpuinfo"
	}
	text := string(bytes)
	svm := false
	for line in strings.split_lines_iterator(&text) {
		if !strings.has_prefix(line, "flags") {
			continue
		}
		flags := line
		for flag in strings.fields_iterator(&flags) {
			svm = svm || flag == "svm"
		}
		break
	}
	if !svm {
		return false, "the host processor has no SVM: KVM gives the test machine the form of the host only, and the kernel does not use the form of Intel (VMX) yet"
	}
	nested, nested_err := os.read_entire_file("/sys/module/kvm_amd/parameters/nested", context.temp_allocator)
	if nested_err != nil {
		// The build sandbox of Nix shows /dev/kvm and the flags of the
		// processor, and hides /sys: the module of the host is unknown
		// there. A KVM that the sandbox hands on is the KVM of the host,
		// with its nested virtualization: the boot line of the kernel shows
		// what the test machine gets.
		if !os.exists("/sys/module") {
			return true, "KVM on an AMD host, in a sandbox that hides /sys: the kernel reads the support of the test machine"
		}
		return false, "the host has no module kvm_amd loaded (/sys/module/kvm_amd/parameters/nested)"
	}
	value := strings.trim_space(string(nested))
	if value != "1" && value != "Y" {
		return false, "the module kvm_amd of the host has nested virtualization off (/sys/module/kvm_amd/parameters/nested is not 1)"
	}
	return true, "KVM on an AMD host with nested virtualization on"
}

guest_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	gives, reason := host_gives_guest_support()
	if gives {
		fmt.printfln("modustool: the part guest runs a guest: %s", reason)
		return machine_test(part, scenario_guest[:], {volume = BOOT_VOLUME, output = TEST_OUTPUT_GUEST, exit_status = MACHINE_STOP_OK})
	}
	fmt.printfln("modustool: the part guest runs NO guest on this host: %s; the machine checks only that Guest_Run refuses with Unsupported", reason)
	return machine_test(part, scenario_guest_unsupported[:], {volume = BOOT_VOLUME, output = TEST_OUTPUT_GUEST, exit_status = MACHINE_STOP_OK})
}
