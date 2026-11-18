package machine

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

// The input of the serial line of a machine: a FIFO beside its log, which
// QEMU reads as the input of its file chardev, and which the tool writes.
// On a machine with no screen, the console input of the firmware is the
// serial terminal (src/md/features/start_policy.md, "The rescue key").
//
// The order of the opens: QEMU opens the FIFO to read, and on Linux the
// open of a FIFO for one direction blocks until the other side opens it.
// The tool makes the FIFO and opens it with O_RDWR before QEMU starts: an
// open for read and write of a FIFO never blocks on Linux, and it is a
// writer from then on, so the open of QEMU ends at once, and no side waits
// for the other. The descriptor is non-blocking too: when QEMU reads no
// more, because the receiver of the serial port of the machine is full, a
// write gives EAGAIN at once in place of a hang of the tool.
Serial_Input :: struct {
	path:       string, // The FIFO. "": none.
	descriptor: linux.Fd,
	open:       bool,
}

// serial_input_open makes the FIFO of a machine and opens its writer.
serial_input_open :: proc(input: ^Serial_Input, path: string) -> bool {
	_ = os.remove(path)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if error := linux.mknodat(linux.AT_FDCWD, cpath, {.IFIFO, .IRUSR, .IWUSR}, 0); error != .NONE {
		fmt.eprintfln("modustool: cannot make the FIFO %s of the serial input: %v", path, error)
		return false
	}
	descriptor, open_error := linux.open(cpath, {.RDWR, .NONBLOCK, .CLOEXEC})
	if open_error != .NONE {
		fmt.eprintfln("modustool: cannot open the FIFO %s of the serial input: %v", path, open_error)
		_ = os.remove(path)
		return false
	}
	input^ = {path = strings.clone(path), descriptor = descriptor, open = true}
	return true
}

// serial_input_write writes bytes on the serial line of the machine. A
// FIFO that is full takes no byte now: that is no failure, the next press
// tries again. ok is false for another error.
serial_input_write :: proc(input: ^Serial_Input, text: string) -> (ok: bool) {
	if !input.open {
		return false
	}
	_, error := linux.write(input.descriptor, transmute([]u8)text)
	return error == .NONE || error == .EAGAIN
}

// serial_input_close closes the writer and removes the FIFO, at the end of
// the machine.
serial_input_close :: proc(input: ^Serial_Input) {
	if input.open {
		_ = linux.close(input.descriptor)
	}
	if input.path != "" {
		_ = os.remove(input.path)
		delete(input.path)
	}
	input^ = {}
}
