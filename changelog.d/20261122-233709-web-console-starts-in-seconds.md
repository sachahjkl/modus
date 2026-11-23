type: Fixed

**The web console starts in seconds**: the kernel of the browser machine copies memory with one `memory.copy` in place of a loop of one byte, and the software processor copies its registers at each instruction. In Node on a loaded host, the console prompt came at 12.9 s in place of 76.6 s.
