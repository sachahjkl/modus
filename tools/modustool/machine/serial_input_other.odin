#+build !linux
package machine

import "core:fmt"

// The input of the serial line of a machine needs a FIFO, which this tool
// makes on Linux only (serial_input_linux.odin).
Serial_Input :: struct {
	path: string,
	open: bool, // Always false here.
}

serial_input_open :: proc(input: ^Serial_Input, path: string) -> bool {
	fmt.eprintfln("modustool: a serial input (%s) needs a FIFO of Linux", path)
	return false
}

serial_input_write :: proc(input: ^Serial_Input, text: string) -> bool {
	return false
}

serial_input_close :: proc(input: ^Serial_Input) {
}
