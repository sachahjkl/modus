type: Added

**The interrupt shadow of a guest in its record.** `Guest_Registers` carries `interrupt_shadow` (0 or 1) in and out, and `Guest_Run` refuses an external interrupt or the non-maskable interrupt to inject while it is 1; the machine of a Linux guest waits for the end of the shadow, so no interrupt of a modelled device comes one instruction early after `sti` or `mov ss`.
