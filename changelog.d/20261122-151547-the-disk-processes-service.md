type: Changed

**The disk processes service.** The service `disk_processes` reads the module file of `start_from_disk`, and the files of its import scan, from the store `module_files` through a connection that reads only, into memory that the root service lends. The root service ends each loan before it checks the hash, so it reads no module file from a disk and waits for no storage service during a load; a module file of up to 4 MiB loads as before, and each line of the log of a load keeps its words.
