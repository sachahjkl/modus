type: Fixed

**A fault of the software processor changes no register and no flag.** An add, a shift, a negation, an increment, an exchange and an add or compare and exchange whose write to memory faults left the flags or a register changed; the processor now gives back the state before the instruction, as an x86-64 processor does. A `cmpxchg` whose compare fails now writes its destination back, so a destination that the user cannot write faults in both cases. The fuzz target `software_machine` found the first fault.
