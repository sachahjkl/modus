type: Added

**The processors at a failed step.** When a step of a machine test fails while QEMU runs, the tool first reads the registers of each processor through the monitor of QEMU, writes them beside the log of the machine (`<log>_processors.txt`), and prints for each processor its instruction address, whether it is halted, and the code that holds the address: the procedure of the kernel from its debug object, the firmware, the firmware in system management mode, a program, or no known code. A step that ended at its bound then says where the machine stalled.
