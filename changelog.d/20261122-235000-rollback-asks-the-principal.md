type: Security

**A rollback asks the principal.** `plans.rollback()` now shows the difference back to the older plan on the trusted display and gives a ticket; `plans.rollback_poll(ticket)` commits it only when the principal accepted, so a console that an agent drives can no longer take back a grant or swap the holder of a role in silence. The exports that read a generation take the principal of the caller, never a principal as an argument.
