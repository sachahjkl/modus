type: Added

**The conversation of the assistant kept.** The assistant stores its conversation in its private store off the interface thread in a BLAKE3-verified binary format, restores it on start, and recovers cleanly with an empty conversation if stored bytes are damaged.
