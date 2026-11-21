type: Added

**The uses of a viewer key across a restart.** The disk grant table (format 3, 1168 bytes) persists each client key's `Calls`, `View`, and `Input` uses alongside its Ed25519 key under the BLAKE2b tag, so an allowed viewer reconnects with its screen and input permissions after a machine restart until revoked.
