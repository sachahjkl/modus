type: Added

**A multi-principal machine test of the end of a wide grant by a lock.** The `wide_grant` test part now runs a second machine with named principal 1 `alice` whose session locks from principal 0's boot console without stopping that console, verifying `Session_Locked` revocation, `Revoked` disconnect of both `remote` and `remote_display`, deferred storage key erasure until the collector persists the end record and stops, and encrypted audit chain verification after unlock.
