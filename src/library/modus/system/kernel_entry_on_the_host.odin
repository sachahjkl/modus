#+build !freestanding
package system

import "base:intrinsics"
import "modus:contract/operation"

// A host test links the procedures of a module that can enter the kernel,
// when the test drives a procedure that calls them on another path. The
// host has no kernel: these two procedures give the linker the names, and
// stop the test at once if a test takes such a path by mistake. A stop here
// is a fault of the test, never a result.

@(export, link_name = "system_enter")
kernel_entry_on_the_host :: proc "c" (wait: u64) -> u64 {
	intrinsics.trap()
}

@(export, link_name = "thread_record")
thread_record_on_the_host :: proc "c" () -> ^operation.Thread_Record {
	intrinsics.trap()
}

// The context of a host test: empty, as context_record gives it. No
// handle is given, so each procedure that reads one sees 0.
host_context: Context
