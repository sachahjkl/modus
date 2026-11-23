type: Added

**A data disk larger than the memory of the storage service.** The counts of the names of the blocks live on the disk in a count tree, which each commit writes with copy on write, so a disk of several terabytes opens with a small budget, from its count tree, with no walk of its blocks; when the memory holds a table of each block, the start still walks and checks each block and compares the tree with it. The format of the disk is `STORAGE6`: a disk of an earlier format is not read.
