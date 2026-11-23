# The guest image of a build

A recipe of the guest builder names a Linux kernel and an initial archive by their hashes ([recipes.md](recipes.md), "The guest builder in the service"). This file is the design of the initial archive whose `init` follows the build protocol of [foreign_systems.md](foreign_systems.md), "The machine of a Linux guest": it reads the input disk, runs the command of the spec, writes the output disk and gives its exit status. The machine test part `guest_build` builds a recipe with it.

## Purpose

- A recipe builds with the tools of a Linux userland (busybox today, a toolchain later) and gets a tree hash that the host can compute.
- The protocol of a build has one implementation inside the guest, which the machine test runs end to end, not a scripted guest.

## Constraints

- The kernel of Nixpkgs builds virtio, its ring, the transport of the windows and the block device as modules: the archive carries them and `init` loads them before it reads a disk (`tools/modustool/build/linux_guest_modules.odin`).
- A file of the output disk carries the BLAKE3 hash of its bytes (MODGBD1): the writer of the disk computes BLAKE3. A shell script of busybox cannot.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function": the command of the spec is text that goes into the guest, a foreign world, and nowhere else.
- A source of `src/` that is not a test imports `base:` and `modus:` only: the guest program reaches Linux through its system calls, made by a few lines of assembly, not through the core library of Odin.

## The chosen form

### The program init

`src/guest/linux_build_init` is one Odin package, built for the target `freestanding_amd64_sysv` and linked as a static ELF of Linux with `ld.lld`. `linux_calls.asm` holds `_start`, the system call and the two port instructions. The package imports the contracts `guest_builder` (the MODGBD1 reader and the stream writer) and `blake3`, so the guest writes a disk with the same code that the host reads it with. It runs as process 1, with no allocator: its buffers are anonymous mappings of the sizes that the disks give.

Its steps:

1. Mount `/proc` and `/sys`. Load `virtio_ring`, `virtio`, `virtio_mmio` with the words `virtio_mmio.device=` of `/proc/cmdline` as its parameters, then `virtio_blk`, with `finit_module`.
2. Find the two disks by their identifiers in `/sys/block/vd*/serial` (`modus-inputs`, `modus-outputs`) and make their nodes from `/sys/block/vd*/dev`.
3. Read the input disk whole, check it (`validate_disk_image`, the role Inputs_Read_Only), and write each file under `/inputs/<path>`.
4. Read the frozen time from the ports of the build, install the applets of busybox, and run `/bin/sh -c <command>` in `/inputs`, with `SOURCE_DATE_EPOCH` the frozen time. The words after `--` on the command line are the arguments of `init`; it joins them with one space.
5. Walk `/outputs`, sort the paths by their bytes, and write the files with the stream writer into a disk of the size of the output device, then write that disk to the device and sync it.
6. Write the exit status of the command to the port Build_Exit_Status. A failure of `init` itself writes one line on the console that says what did not happen, and the status `INIT_FAILED_STATUS` (125).

Bounds: the files of a disk (MAX_DISK_ENTRIES), the bytes of a path (MAX_MOUNT_PATH_BYTES), the depth of a path (MAX_PATH_DEPTH), the size of the output device. Each is checked, and each refusal is a status, never a hang: the time bound of the spec ends a guest that hangs anyway.

### The archive and the recipe

The tool builds `init` and assembles the archive from the flake inputs: `init`, a static busybox, the virtio modules, the folders and `/dev/console` (`tools/modustool/build/linux_build_image.odin`). The archive is deterministic: the same inputs give the same bytes, so its hash names it. The machine test writes the kernel, the archive, the inputs and the recipe into the private store of `recipes` by their hashes, and computes on the host the tree hash that the output must have.

## Refused forms

- **A shell script as `init`.** It cannot compute the BLAKE3 hash of a file, and a reader of a disk in shell reads offsets with `dd`: a second implementation of the format, untested.
- **A C program with a libc of its own.** A second language and a second writer of MODGBD1, beside the contract that the host uses.
- **The target linux_amd64 of Odin.** `odin build` compiles the test files of each package, which import the core library, and the core library needs a C runtime. The freestanding target leaves them out by their build line.
- **A Nix derivation that builds `init` and the archive.** The automation of the project is the tool; the flake gives the inputs (busybox, the kernel, the modules).
- **The disks by their order on the command line.** Linux names the devices in the order that it probes them; the identifier of each disk names it whatever the order.

## Subtle points

- **The arguments of init.** The kernel splits the words after `--`; a run of spaces in the command becomes one space. A command that needs exact spaces quotes them for the shell.
- **The output disk is blank.** The runner zeroes it before the boot, and the writer zeroes each byte past the image, so the unpack of the host sees the bytes that `init` wrote and nothing else.
- **An empty folder of `/outputs` is not kept**: a MODGBD1 disk holds files.

## State

Built and checked by host tests: none of `init` runs on the host; it is built and linked by the tool. Built: the scenario of the test part `guest_build`, which the coordinator runs. Left: a toolchain in the image (the Odin compiler, `cargo`), the bootstrap of [bootstrap.md](bootstrap.md).
