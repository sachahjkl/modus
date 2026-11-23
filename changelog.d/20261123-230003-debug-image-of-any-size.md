type: Fixed

**The debug image of any size is read at the start.** The boot program refused a debug image past 32 MiB, and the debug image of the build had grown to 34 MB: the machine then started with no names in its stop reports and in the debugger. The boot program now reads a debug image of any size that the memory of the machine holds.
