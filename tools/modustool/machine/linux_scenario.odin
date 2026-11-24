package machine

import "core:fmt"
import "core:os"
import "modustool:build"
import "modustool:foundation"

// A shell of Linux in a terminal window (src/md/features/linux_shell.md):
// one machine. Its data disk holds the private store linux with the
// bzImage of Nixpkgs and an initial archive with a static busybox, which
// the tool writes from the two variables of the flake. The start menu
// starts linux; Linux boots in a guest, its init loads the virtio modules
// and writes modus-guest-ready on the serial port, the log of the kernel,
// and runs a shell on hvc0, the virtio console. The tool types a command in
// the terminal window and waits for its output on the lines of the shell,
// starts a program that waits for SIGWINCH, resizes the window and waits
// for the size that the program reads from hvc0, then types poweroff, and
// linux ends with the halt of the guest.
//
// Each wait has the hang bound only: the boot of Linux makes many exits, and
// the waits on the lines of its boot are the progress of the part.
//
// On a host that gives the test machine no SVM, as in the part guest, the
// machine checks only that linux says that no guest runs, and the tool
// writes that no guest ran, and why.

TEST_OUTPUT_LINUX :: foundation.BUILD_FOLDER + "/test_output_linux.txt"
TEST_DISK_LINUX :: foundation.BUILD_FOLDER + "/test_disk_linux.img"
// The blocks of the store linux: the row of the start grant sets of
// linux gives the same.
LINUX_STORE_BLOCKS :: 8192

linux_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	kernel, archive := build.linux_guest_image_read() or_return
	objects := [?]build.Module_File{{"kernel", kernel}, {"initial_archive", archive}}
	image := build.data_disk_encode({name = "linux", limit = LINUX_STORE_BLOCKS, objects = objects[:]}, build.DATA_DISK_SIZE) or_return
	defer delete(image)
	if err := os.write_entire_file(TEST_DISK_LINUX, image); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", TEST_DISK_LINUX, err)
		return false
	}
	fmt.printfln("modustool: %s: the store linux holds the kernel, %d bytes, and the initial archive, %d bytes", TEST_DISK_LINUX, len(kernel), len(archive))
	// The memory of the guest comes from the granted budget: the wait names
	// the objects, which the tool knows, and not the pages. Heap-owned so
	// scenario_run's per-step free_all(context.temp_allocator) never frees
	// step text still needed by later steps.
	owned: [dynamic]string
	defer {
		for text in owned {
			delete(text)
		}
		delete(owned)
	}
	boots := fmt.aprintf("linux: boots the kernel of %d bytes and the initial archive of %d bytes of the store linux, in ", len(kernel), len(archive))
	append(&owned, boots)
	gives, reason := host_gives_guest_support()
	steps := make([dynamic]Step)
	defer delete(steps)
	append(&steps, Step{kind = .Wait, text = "storage: ok, generation 2: 1 stores, 2 objects", any_order = true})
	append(&steps, Step{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true})
	append(&steps, Step{kind = .Launch, text = "linux"})
	append(&steps, Step{kind = .Wait, text = "root: started linux, with a terminal", any_order = true})
	append(&steps, Step{kind = .Wait, text = boots, any_order = true})
	if !gives {
		fmt.printfln("modustool: the part linux runs NO guest on this host: %s; the machine checks only that linux says that no guest runs", reason)
		append(&steps, Step{kind = .Wait, text = "linux: Guest_Run gave Unsupported: the processors of this machine have no virtualization support that the kernel uses, and no guest runs"})
	} else {
		fmt.printfln("modustool: the part linux runs a guest: %s", reason)
		// The lines of the boot: each is progress, and names the stage that
		// a failure stopped at.
		// The kernel writes no time in its lines once it read printk.time=0,
		// so each line reads the same in each run; its first lines, before
		// it reads the command line, have the time 0.
		for line in ([?]string{"[    0.000000] Linux version ", "Memory: ", "NET: Registered PF_INET protocol family", "Freeing initrd memory", "Run /init as init process", "modus-guest-ready"}) {
			wait_text := fmt.aprintf("linux: guest: %s", line)
			append(&owned, wait_text)
			append(&steps, Step{kind = .Wait, text = wait_text, fails_on = "linux: the guest stopped with the failure "})
		}
		append(&steps, Step{kind = .Front, text = "linux"})
		append(&steps, Step{kind = .Type, text = "echo modus-guest-ok"})
		// The echo of the command is the line "... # echo modus-guest-ok":
		// only the output of the command starts with the word.
		append(&steps, Step{kind = .Wait, text = "linux: shell: modus-guest-ok", fails_on = "linux: the guest stopped with the failure "})
		// A resize of the window reaches the shell as SIGWINCH: a program in
		// the foreground of hvc0 waits for it, and prints the size that hvc0
		// then has. The tool cannot know the rows and the columns of the
		// window in advance: the fact says that the machine took them, and
		// the line of the shell says that the program got the signal.
		append(&steps, Step{kind = .Type, text = "sh -c 'trap \"echo modus-winch $(stty size); exit\" WINCH; while :; do sleep 1; done'"})
		append(&steps, Step{kind = .Resize, text = "linux", to_x = 880, to_y = 520})
		append(&steps, Step{kind = .Fact, process = "linux", fact = "linux_shell.Window_Resized", condition = "taken = 1"})
		append(&steps, Step{kind = .Wait, text = "linux: shell: modus-winch ", fails_on = "linux: the guest stopped with the failure "})
		append(&steps, Step{kind = .Type, text = "poweroff"})
		append(&steps, Step{kind = .Wait, text = "linux: the guest halted after ", fails_on = "linux: the guest stopped with the failure "})
	}
	append(&steps, Step{kind = .Front, text = "console"})
	append(&steps, Step{kind = .Type, text = "shutdown()"})
	append(&steps, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
	return machine_test(part, steps[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_LINUX, exit_status = build.MACHINE_STOP_OK, data_disk = TEST_DISK_LINUX})
}

// A binary of the tool runs the test part linux only when it holds this file
// (test_parts.odin, test_part_scenario_register).
@(init)
linux_test_part_register :: proc "contextless" () {
	test_part_scenario_register("linux", linux_tests_run)
}
