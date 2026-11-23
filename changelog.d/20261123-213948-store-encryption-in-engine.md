type: Added

**The blocks of the stores of a principal encrypted.** Each store of a named principal now encrypts its data blocks and secret metadata with vector XChaCha20, authenticates every block with a 128-bit keyed BLAKE3 SIV tag, rejects older store block generations within a session, and erases the principal's keys, cached blocks, hash-index entries, and pending buffers at lock.
