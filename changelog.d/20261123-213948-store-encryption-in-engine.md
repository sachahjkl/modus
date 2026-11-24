type: Added

**The blocks of the stores of a principal encrypted.** Each store of a named principal now encrypts its data blocks and secret metadata with vector XChaCha20, authenticates every metadata and store block with a 128-bit keyed BLAKE3 SIV tag, verifies data blocks against their authenticated parent node values or entry hash and check, rejects older store block generations within a session, and erases the principal's keys, cached blocks, hash-index entries, pending pools, and transient buffers at lock.
