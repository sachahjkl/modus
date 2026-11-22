type: Changed

**Live kernel fault-isolation hooks, sound mixer/capture/drift wiring, per-endpoint network RX queues, encrypted storage page wiring, test-free release filter, and tagged-union scenario steps.** Wired `kernel_fault_isolation` and `serial_ring` into `src/modulus`, `sound_mixer` into `sound`, per-endpoint RX into `network`, `store_crypto` into `storage`, and added test-free release filtering and tagged-union named-section scenario steps in `tools/modustool`.
