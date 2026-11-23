# The boot volume and the debug image on it

## Purpose

The boot volume is the disk from which the firmware starts the machine. It holds two files: the boot program (`EFI/BOOT/BOOTX64.EFI`), and the debug image (`DEBUG/OBJECTS.IMG`). The tool writes the volume itself (`tools/modustool/build/volume.odin`), so no third-party program takes part.

## Constraints

- The boot program and the boot image must stay the same bytes with and without the debug image, so a debug object changes no signature and no TPM measure.
- The debug image is unsigned and unmeasured. A missing, empty, damaged, or oversized debug image must never stop the machine from starting or exhaust the free physical memory that the kernel and root service need.
- The root service maps the debug image into one fixed range of `fixed_addresses.RANGE_SPAN` bytes (1 TiB).

## The chosen form

- **The size of the volume is computed from its files** (`volume_layout_of`). It is at least 64 MiB, and it grows with the files. Its tables grow with it and never shrink below 1024 sectors.
- **Why 64 MiB is the least size.** This is a format property: FAT32 needs at least 65 525 clusters, and a cluster is one sector. 64 MiB holds these clusters and their tables. A volume of small files keeps this layout.
- **The debug image stays on the boot volume**, beside the boot program and outside the boot image. A reader of a stop report needs no service to name a frame: a stop of the storage service has names, and the console needs no connection. The boot program and the boot image are the same bytes with and without the debug image, so it changes no signature and no measure (`docs/MODULE_CONTRACT.md`, "Where the debug objects are").
- **The bound of the debug image is computed from free physical memory** (`boot_info.debug_image_bound`): at most one quarter of the `.Free` physical memory reported by the firmware, capped at `fixed_addresses.RANGE_SPAN` (1 TiB). Because `DEBUG/OBJECTS.IMG` is unsigned, leaving three quarters of free physical memory ensures an oversized or tampered file cannot starve the kernel or root service. Then the kernel checks that the range is non-empty, page-aligned, at most `fixed_addresses.RANGE_SPAN`, has no address wrap, and lies wholly inside one `.Boot` range (`boot_info.debug_image_pages`).

## The refused forms

- **A fixed size of the volume (64 MiB).** It refused the build once the boot program and the debug image grew past it: the volume of the test `fails` needs about 67 MiB. A larger fixed size only delays the same refusal.
- **A fixed bound of the debug image (32 MiB).** The debug image of the build grew to 34 MB. The boot program then read no debug image, and the machine had no names in a stop report and in the debugger, with no failure of the build.
- **No memory share bound on the unsigned debug image.** Allowing `DEBUG/OBJECTS.IMG` to consume arbitrary `.Free` memory lets an oversized or tampered file starve the kernel and root service at start.
- **Fewer bytes to fit the bound.** To strip debug objects or to compress them only delays the same refusal, and it removes names that a reader needs.
- **The debug image out of the boot volume.** On the data disk, a reader would need the storage service, so a stop of that service would have no names. On the network, a reader would need a network grant. On the host, the machine would have no names. The module of a disk process has no place on the boot volume: its debug object is on the data disk ([../features/debug_object_of_a_disk_process.md](../features/debug_object_of_a_disk_process.md)).

## The subtle points

- **The pages of the debug image stay taken for the whole run.** The cost in memory is the size of the debug image. The build prints it ("modustool: the debug image has ..."). The boot program reads the debug image after its last allocation that stops the machine on a failure, and caps it at one quarter of free physical memory, so the debug image never takes the memory that the start needs.
- **The root service maps the debug image in one fixed range of 1 TiB** (`fixed_addresses.RANGE_SPAN`). That is a format property of the band of fixed ranges, and caps the computed bound.

## State

Built: computed FAT32 volume sizing (`volume_layout_of`), computed debug image bound in `boot_info.debug_image_bound` and `src/boot/debug_image.odin`, and pure kernel range validation in `boot_info.debug_image_pages` with host tests.
