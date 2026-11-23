type: Fixed

**The scaled window of TCP stays at its buffer**: with window scaling, the window that the machine gives a remote rounds up from its free room by less than one unit of its scale, a full buffer gives a window of 0, and a byte past the free room of the buffer is not taken.
