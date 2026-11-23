package linux_shell

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the process `linux` (src/md/features/linux_shell.md).

// The guest image was read and the guest starts.
@(log_fact = "linux: boots the kernel of {kernel_bytes} bytes and the initial archive of {archive_bytes} bytes of the store linux, in {memory_pages} pages of guest memory")
Guest_Boots :: struct {
	kernel_bytes:  u64,
	archive_bytes: u64,
	memory_pages:  u64,
}

// One line of the log of the kernel, which the guest writes on its serial
// port, at most 128 bytes of it: each byte of 128 or more is '?'.
@(log_fact = "linux: guest: {text}")
Guest_Line :: struct {
	text: [128]u8,
}

// One line of the shell, which the guest writes on its virtio console
// hvc0, at most 128 bytes of it: each byte of 128 or more is '?'.
@(log_fact = "linux: shell: {text}")
Shell_Line :: struct {
	text: [128]u8,
}

// The budget of the process holds less memory than a guest needs: the
// guest does not start.
@(log_fact = "linux: the budget has {pages} pages left, and a guest needs {least}: the guest does not start")
Guest_Memory_Too_Small :: struct {
	pages: u64,
	least: u64,
}

// The progress of the guest, at each power of two of its runs: the runs,
// the exits that the guest caused, the last exit and its address. A guest
// that boots shows where it is; a guest that loops shows where it loops.
@(log_fact = "linux: run {runs} of the guest, {exits} exits of its own: the last exit {exit_kind} with the code {exit_code} at {address}")
Guest_Progress :: struct {
	runs:      u64,
	exits:     u64,
	exit_kind: u64,
	exit_code: value_kinds.Hexadecimal_Sixteen_Digits,
	address:   value_kinds.Hexadecimal_Sixteen_Digits,
}

// The guest ran hlt with its interrupts off: its halt, or its poweroff.
@(log_fact = "linux: the guest halted after {exits} exits, with {own_page_writes} writes that the machine did for an instruction that writes its own page: the process ends")
Guest_Halted :: struct {
	exits:           u64,
	own_page_writes: u64,
}

// The machine stopped the guest: the word of a guest_os.Machine_Failure.
@(log_fact = "linux: the guest stopped with the failure {failure} of the machine, at the address {address}, after {exits} exits, the last with the exit code {exit_code}")
Guest_Failed :: struct {
	failure:   u64,
	address:   value_kinds.Hexadecimal_Sixteen_Digits,
	exits:     u64,
	exit_code: value_kinds.Hexadecimal_Sixteen_Digits,
}

// An instruction of the guest writes the page that holds it, and the
// machine cannot do that write for it: an instruction that is no mov to
// memory, or a write that can start in the page before.
@(log_fact = "linux: the guest stopped: the instruction at {address} writes the page that holds it at {page}, and the machine cannot do that write for it")
Guest_Writes_Own_Page :: struct {
	address: value_kinds.Hexadecimal_Sixteen_Digits,
	page:    value_kinds.Hexadecimal_Sixteen_Digits,
}

// An object of the guest image is not in the store, or cannot be read: the
// word of a storage_status.Status.
@(log_fact = "linux: the store linux gives no object {name}: status {status}")
Object_Missing :: struct {
	status: u64,
	name:   [16]u8,
}

// An object of the guest image does not fit the memory of the guest.
@(log_fact = "linux: the object {name} of the store linux has {bytes} bytes, and the memory of the guest holds at most {most}")
Object_Too_Large :: struct {
	bytes: u64,
	most:  u64,
	name:  [16]u8,
}

// The kernel is not one that the boot protocol of Linux loads, or the boot
// refused its archive or its command line: the word of a
// guest_os.Linux_Boot_Refusal.
@(log_fact = "linux: the kernel of the store linux is refused by the Linux boot protocol: refusal {refusal}")
Kernel_Refused :: struct {
	refusal: u64,
}

// The process has no terminal or no store.
@(log_fact = "linux: no terminal: the process writes the console of the guest to its terminal")
No_Terminal :: struct {}
@(log_fact = "linux: no store: the guest image is in the private store of the process")
No_Store :: struct {}

// The window of the guest changed its size: the width of the lines and the
// size of the virtio console. taken is 1 when the console line and the
// device took the size, 0 when one refused it. The shell learns the size
// from its terminal hvc0, and its answer is a line of the shell.
@(log_fact = "linux: the window has {columns} columns and {rows} rows: the console line and the virtio console took the size ({taken})")

Window_Resized :: struct {
	columns: u64,
	rows:    u64,
	taken:   u64,
}

// The processors of the machine have no guest support.
@(log_fact = "linux: Guest_Run gave Unsupported: the processors of this machine have no virtualization support that the kernel uses, and no guest runs")
Guests_Unsupported :: struct {}

// A kernel operation failed.
@(log_fact = "linux: failed: {step} gave {status_word}")
Step_Failed :: struct {
	status_word: op.Status_Word,
	step:        [40]u8,
}
