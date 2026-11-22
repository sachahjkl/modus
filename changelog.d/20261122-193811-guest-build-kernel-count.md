type: Security

**A guest build refuses a kernel image larger than the memory of the guest before any arithmetic on its size**: a count near the largest 64-bit value no longer wraps the size of the copy to 0, and an absent spec or kernel buffer is refused.
