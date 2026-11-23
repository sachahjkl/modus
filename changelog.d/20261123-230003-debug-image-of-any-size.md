type: Fixed

**The debug image bound is computed from free memory.** The boot program refused a debug image past 32 MiB, and the debug image of the build had grown to 34 MB: the machine then started with no names in its stop reports and in the debugger. The boot program now reads a debug image up to one quarter of free physical memory (capped at 1 TiB), leaving memory for the kernel and root service.
