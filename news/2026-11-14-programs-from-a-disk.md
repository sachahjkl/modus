title: A program starts from the data disk
date: 2026-11-14
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

Until now, each program of the system was a file of the boot image. A new program needed a new boot image. A program can now be an object of the storage service, in a store named `programs`. In the console, the command `start_from_disk` takes the name of the program and the hash of its file. The root service reads the bytes from the storage service and computes their hash. It starts the program only when that hash is the hash of the command. So the storage service carries the bytes and does not choose what runs. Bytes with another hash are refused, and the log shows both hashes. A program from the disk receives the log and a window, and no grant. Its name gives it nothing: a file named `notes` does not get the store of `notes`, because the root service refuses that name. The root service does not wait for the storage service: it serves each other program while the bytes come, and a load ends after 30 seconds at most. The tool writes the data disk of the test and prints the hash of each file.
