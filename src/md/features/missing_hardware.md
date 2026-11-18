# A missing or silent part of the machine

The system keeps running when a part of the machine is absent, or stops to answer: a device, a timer, a table of the firmware, a screen, a disk. It writes one line that names the part and what the system does without it, and the rest of the system works. A stop of the whole machine is kept for a refusal of security and for a broken invariant of the kernel.

## The constraints

- **The fixed machine.** The system targets one fixed machine at a time ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "7. No drivers in the kernel, and fixed hardware first"). A part that the first machine always has can still be absent: a firmware that gates the PIT off, a machine with no screen, a disk that a host stops to serve. The second machine is a real one, where such absences are usual.
- **A device service is a process.** A fault of the code that drives a device stops that process, not the machine. A client that waits for that process with no bound undoes this: the fault then stops every client, and the machine looks stopped.
- **Security refusals stay stops.** A refused signature or a refused version stops the boot program, with its message on the boot display ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "17. Trusted boot: UEFI program, Secure Boot, TPM"). An IOMMU unit that does not finish an invalidation after the start stops the machine, because a page that a device can still reach must never become free ([iommu.md](../infrastructure/iommu.md)). These are not absences.

## The chosen form

Each absence has the same three parts:

1. **A bounded wait.** No wait for a device, a register or a process has no bound. A register poll is bounded by the cycle counter; a wait for a record of a ring is bounded by a deadline, or ends when the process that writes the ring stops: the waiter holds the handle of that process with the right `.Read`, so its stop ends the wait.
2. **One line.** The line names the part and what the system does without it: `input: no PS/2 controller: no keyboard and no mouse`. A line is written once, at the place where the absence is found, by the process that found it.
3. **A smaller system.** The capability is absent and the rest runs:
   - a service that cannot serve stops with its code; its clients get `Gone`;
   - the root service refuses a start that needs the absent part, and starts the others;
   - a kernel part that is absent at the start is off, with its line, when a safe form without it exists. With no time base, the kernel stops with `Start_Failed` and the line.

The places, by the risk for a user:

| Part | Today | The form |
|---|---|---|
| A disk that stops to answer | The storage service and each client of the store wait with no end | A deadline for each block request; the storage service holds the handle of the block service; past the deadline it is broken, writes its line and refuses changes |
| No screen | The root service stops to serve its ring | The root service starts no console, writes its line and starts the other services |
| No PIT | The first processor hangs before its first line | The calibration wait is bounded; the TSC frequency of CPUID is used when the processor states it |
| No PS/2 controller | The input service spins on one processor for ever | The input service writes its line and stops; the root service starts the other services |
| A frame service that stops after it maps its ring | The network service waits with no end | The network service holds the handle of the frame service, writes its line and stops |
| An IOMMU unit that does not finish its first invalidation | The machine stops | No device service holds memory yet, so the units go off and the machine runs as a machine with no IOMMU, with its line |
| A stop of the boot program for memory or for the map of the firmware | A message on the firmware console, then a power off at once | Built: the message stays on the boot display, the watchdog is off, and the boot program waits, as for a refusal of trust; the buffer of the map takes the size that the firmware asks; past the room of the boot record, only reserved ranges are left out, with their line ("The stop of the boot program") |
| An xsave area that the processor does not read back | `Start_Failed` | One more proof with the form `fxsave`, with its line |
| No table of the APIC | One processor, with no line | One processor, with its line |
| An entropy read that never completes | The fresh bytes stop with no line | A deadline; the read counts as refused |

## The stop of the boot program

The boot program cannot run a smaller system: with no memory for the kernel, or no map of the memory, no kernel starts. Its stop is needed; the fault was its silence. The code is `stop` and `boot_stop` in `src/boot/main.odin`, and the arithmetic of the map in `src/library/private/boot_program/firmware_memory_map`, which the host tests run.

- **One stop for each failure.** A refusal of trust and a stop for memory, for the map or for the kernel module take the same path: the line on the log, the failure in red on the boot display with its step, the watchdog off, then a wait. With no screen, or before the boot record has its pages, the line stays on the console of the firmware, and a second line says so. A power off is refused: it removes the message before anyone reads it, and a machine whose firmware restarts it would run the same failure again.
- **A stop after a failed exit.** Once the boot program has called ExitBootServices, the specification allows only the services of the memory, also when the call fails. From that call on, each line goes to the serial port only, a stop draws on the screen (memory that the boot program writes itself) but calls no watchdog, and with no screen its second line says that the failure is on the serial port only.
- **The steps in their order.** The steps of the boot display follow the boot program: the boot image (its copy, its system description and the hash of each file), then the kernel module (its hash, then its load), then the memory map. The hash of the kernel is checked after the files of the image, so a failure of the kernel shows the boot image as done, which it is.
- **The buffer of the map.** The first read of the map asks its size with a buffer of no byte. The buffer then gets that size and a margin of 8 descriptors, because its own allocation, and the free of a smaller buffer, split ranges of the map. Each read that is too small again gets a larger buffer, up to 4 reads; then the boot program stops. A size past 4 MiB and a size of 0 stop it too.
- **The walk of the map.** A read that succeeds must give a size that fits its buffer, and a step between descriptors from the 40 bytes of the specification to one page, and not larger than the map. The walk goes by index, up to the size divided by the step: each descriptor that it reads ends inside the map. A walk by offset with a step near the largest u64 wraps, and reads descriptors before the buffer.
- **A usable range that the kernel can hold.** A `Free` or `Boot` range starts on a page and ends at or below 2^52, the physical addresses of the processor; else the boot program stops with its address. The kernel computes the end of each range (`device_range`, the size of the direct map): an end that wraps would make a range at the top cover the low addresses.
- **The room of the boot record.** The kernel receives at most 1024 ranges. It reads an address that no range lists as an address that a device can hold (`device_range`): a usable range left out could then be given to a device service, the pages of the kernel too. So each `Free` and `Boot` range is kept, and only `Reserved` ranges are left out, which the kernel reads as it reads an address of no range. A range that follows the last one, with the same kind, joins it, so a map has far fewer ranges than descriptors. The boot program counts the usable ranges first; when they alone pass the room, it stops. The reserved ranges left out give one line, on the serial port, after the end of the firmware services: `boot program: the memory map has more ranges than the 1024 of the boot record: <count> reserved ranges of <pages> pages are left out, and the kernel reads them as reserved`.
- **Refused: drop the ranges past the room in the order of the map.** That form was silent, and a usable range at the end of the map was lost: with the rule of `device_range`, that is a breach, not a smaller system.
- **Refused: a fixed buffer of more pages.** Any fixed size is a bet on the firmware; the firmware states the size it needs.

## The tests

Each absence has a machine test that removes the part from QEMU, and checks its line and a later step that still works. The hang bound is the only time in it:

- no PS/2: `-machine q35,i8042=off`;
- no PIT: `-machine q35,pit=off`;
- no screen: `-vga none`, then a call through `remote`;
- no network device, no data disk: the machine leaves the device out;
- a disk that stops to answer: the NBD server of the tool stops to answer after a count of requests;
- a stop of the boot program: a test volume of `test trusted_boot` whose kernel states 1 TiB more memory, signed as it is, so each check passes and the firmware gives no pages; the test waits for `boot program: the firmware gives no memory for ` and `boot program: the boot display shows the failure`, then the tool ends the machine, which waits. No firmware of the tests gives a map past 1024 ranges or a map that grows at each read: the host tests of `firmware_memory_map` cover those, with 0 ranges, exactly 1024, and 1025.

## The refused forms

- **A silent fallback.** A part that is absent with no line is a fault that nobody can find: one processor with no word of the missing table, a screen of another size with no word of the mode. The line is part of the form.
- **A stop of the machine for an absence.** A stop hides the cause when the message is on a console that nobody sees, and it removes each capability that did not need the part.
- **A retry for ever.** A loop that tries again with no bound is a hang with more work.
- **A part that the system pretends to have.** A service that answers `ok` with no device gives wrong data to its clients. An absent capability is refused, never simulated.

## The subtle points

- **The wait of a client is the hazard, not the fault of the device.** The device service already stops on a fault; the hang comes from the processes that wait for it. Each wait for another process holds its handle or has a deadline.
- **The deadline of a device request** comes from the hang bound of the system, not from a measure of the speed of a device, so that a slow disk is not called absent.
- **At the start, before a device service holds memory, the IOMMU can go off.** After it, it cannot: the reason of the stop is a page that a device can still reach.
- **A machine check or an NMI** still stops the machine. To read the error and stop only the process whose memory it touches is planned work.
