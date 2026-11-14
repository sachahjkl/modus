type: Added

**Programs from a disk**: the console command `start_from_disk(name, hash)` starts a program whose module file is an object of the store `programs` of the storage service, and not a file of the boot image. The root service reads the bytes without waiting for the storage service, starts them only when their BLAKE3 hash is the hash of the command, and gives the program the log and a window and no grant, whatever its name. `modustool test disk_programs` writes the data disk and runs the machine.
