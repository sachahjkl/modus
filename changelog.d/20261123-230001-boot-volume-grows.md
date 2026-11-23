type: Fixed

**A boot volume holds its files**: the tool sizes each boot volume to its boot program and its debug image, from 64 MiB, the least of FAT32, upward; a volume no longer fails to build when the two pass 64 MiB together.
