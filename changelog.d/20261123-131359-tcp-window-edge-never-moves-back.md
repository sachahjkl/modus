type: Fixed

**The window of TCP never moves back**: with window scaling, the right edge that the machine gives a remote no longer moves back by part of a unit of its scale as bytes arrive, and a byte past the free room of the buffer is not taken.
