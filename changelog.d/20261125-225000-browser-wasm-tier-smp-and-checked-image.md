type: Added

**Browser machine compiled WebAssembly tier, worker SMP coordination, and checked boot-image wait gate**: hot decoded x86-64 blocks compile into bounded WebAssembly 1.0 modules after crossing the execution threshold, multi-worker SharedArrayBuffer CPUs coordinate IPIs and generation-counted TLB shootdowns, and boot-image readers wait for first-use BLAKE3 verification and fail closed on any hash mismatch.
