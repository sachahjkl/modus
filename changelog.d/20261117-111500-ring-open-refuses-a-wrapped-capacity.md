type: Fixed

**`ring.open` refuses a count of pages whose capacity wraps**: a count of pages near the top of its type made the capacity wrap to 0, with a mask of every bit, or to a small power of two, and `open` gave a ring. It now refuses each count past the ring of `CAPACITY_LIMIT` records.
