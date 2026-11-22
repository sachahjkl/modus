type: Added

**NVMe 1.4+ queue pair and command protocol contract.** Added freestanding `modus:contract/nvme` defining exact 64-byte submission and 16-byte completion entries, closed opcode and status enums, `Queue_Pair_State` with phase-tag wraparound and in-flight command ID tracking, doorbell offset overflow guards, and validated Admin and I/O command builders.
