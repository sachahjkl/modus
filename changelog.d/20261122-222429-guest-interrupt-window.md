type: Added

**The interrupt window of a guest**: `Guest_Run` now delivers an `External_Interrupt` only when the guest takes interrupts; with the interrupt flag of the guest clear or in its interrupt shadow, the kernel opens the interrupt window, and the run ends with the new exit `Interrupt_Window` when the guest takes interrupts again, with the request still in the record. An external interrupt below the vector 32 is refused, an external interrupt in the shadow is no longer refused, and the record gives `event_pending`: 1 when the guest processor holds an event that an exit interrupted.
