#+build !freestanding
package sentence

import "modus:contract/errors"
import "core:testing"

// A program that unmaps the code of the module that its starter recorded:
// the sentence names the address, the module of the starter and who can
// change it, so the reader does not look for a missing right of a handle.
@(test)
a_change_of_a_module_of_the_starter :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	// The values of the test: a module of 5 pages, and an address in its
	// second page.
	module_base :: 0x40_0000
	module_size :: 0x5000
	unmapped_address :: module_base + 0x1000
	record := errors.error_make(.Starter_Module, .Bytes, 2, unmapped_address, module_base, module_size)
	error_text(&writer, &record, "Memory_Unmap", "address")
	testing.expect_value(t, written(&writer), "Memory_Unmap: the argument address, 0x401000, is in the module at 0x400000 with 20480 bytes, which the starter of the program recorded: only a holder of the program handle changes it")
}
