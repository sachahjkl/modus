type: Added

**The script fonts named in the plan and mapped by the root service**: Hebrew, Arabic, the ideographs, the emoji and the geometric shapes now draw on a machine. The boot image names the script font set by its hash, and the plan of principal 0 can name another one; when the machine is usable, the root service reads the set from the store `script_fonts` of the data disk, checks its hash, and maps it into each process that starts after that. A machine with no set, or with a set whose hash does not match, keeps the replacement box for those scripts.
