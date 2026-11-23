type: Fixed

**A module file is replaced whole**: `module_files.receive` and `module_files.put` write a file into a staging object and make its nickname name it in one commit, so a body that ends early leaves the program before working, one file makes one version, and a failed write drops its pending changes in the storage service. The service removes each staging object that a stop left, at its start and before a listing. A receive ends when no piece of 32 KiB comes for 30 seconds, or past a total of 30 seconds and its bytes at 64 KiB each second.
