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
| No screen | The root service stops to serve its ring | Built. The root service tests the framebuffer as the compositor does; with none, or when the compositor stopped, it writes its line once and starts no input service, no compositor and no console. A later start gives no window, refuses the grant `Terminal`, and the root service starts `remote` |
| No PIT | The first processor hangs before its first line | The calibration wait is bounded; the TSC frequency of CPUID is used when the processor states it |
| No PS/2 controller | The input service spins on one processor for ever | Built. A status of all ones, or a drain past `CONTROLLER_POLLS` bytes: the input service writes its line and stops; a device of the controller that the kernel refuses: the root service writes its line and starts no input service |
| A frame service that stops after it maps its ring | The network service waits with no end | The network service holds the handle of the frame service, writes its line and stops |
| An IOMMU unit that does not finish its first invalidation | The machine stops | No device service holds memory yet, so the units go off and the machine runs as a machine with no IOMMU, with its line |
| A stop of the boot program for memory or for the map of the firmware | A message on the firmware console, then a power off at once | The message stays on the boot display, the watchdog is off, and the boot program waits, as for a refusal of trust |
| An xsave area that the processor does not read back | `Start_Failed` | One more proof with the form `fxsave`, with its line |
| No table of the APIC | One processor, with no line | One processor, with its line |
| An entropy read that never completes | The fresh bytes stop with no line | Built. A deadline of the hang bound from the ask; past it, the reads in flight count as refused, the root service stops the entropy service, and one line says both |

## The tests

Each absence has a machine test that removes the part from QEMU, and checks its line and a later step that still works. The hang bound is the only time in it:

- no PS/2: `-machine q35,i8042=off`, then the desktop with its console;
- no PIT: `-machine q35,pit=off`;
- no screen: `-vga none`, then a call through `remote`. A client key is allowed in a console only, so a machine with a screen first seals the machine key by the TPM and allows the key of the peer; the machine with no screen starts on that disk and that TPM, which give the key back with no typing;
- an entropy read that never completes: the entropy device with the source `rng-egd` over a socket that no process connects to, so the device takes each read and never ends it, then a process that shows the refused reads;
- no network device, no data disk: the machine leaves the device out;
- a disk that stops to answer: the NBD server of the tool stops to answer after a count of requests.

## The refused forms

- **A silent fallback.** A part that is absent with no line is a fault that nobody can find: one processor with no word of the missing table, a screen of another size with no word of the mode. The line is part of the form.
- **A stop of the machine for an absence.** A stop hides the cause when the message is on a console that nobody sees, and it removes each capability that did not need the part.
- **A retry for ever.** A loop that tries again with no bound is a hang with more work.
- **A part that the system pretends to have.** A service that answers `ok` with no device gives wrong data to its clients. An absent capability is refused, never simulated.
- **No screen: a wait for the stop of the compositor.** The compositor finds no framebuffer and stops, but a wait for that stop has no end when it runs. The root service makes the same test on its own context before it starts anything, and keeps the stop of a compositor as the second sign, at the start of the console and at the reap.
- **No screen: a terminal with no window.** Its process would write into a ring that no process reads, and wait when it is full. A start of a process with the grant `Terminal` is refused; a process with no window gets no surface and runs.
- **No screen: the input service with no compositor.** Its records would fill a ring that no process reads. It does not start.
- **No PS/2: a drain with no bound only.** A bound alone spins 100 000 reads of a port before the line; the status of all ones names the absence at the first read, as the i8042 driver of Linux reads it, and the bound stays for a controller that gives bytes with no end.
- **An entropy read past its deadline: a second read.** The entropy service serves one read at a time, so a second read waits behind the first for ever. The service stops; a late answer of the device is not counted.

## The subtle points

- **The wait of a client is the hazard, not the fault of the device.** The device service already stops on a fault; the hang comes from the processes that wait for it. Each wait for another process holds its handle or has a deadline.
- **The deadline of a device request** comes from the hang bound of the system, not from a measure of the speed of a device, so that a slow disk is not called absent.
- **At the start, before a device service holds memory, the IOMMU can go off.** After it, it cannot: the reason of the stop is a page that a device can still reach.
- **With no screen, `remote` is started by the root service.** No principal can start it from a desktop that does not exist. It acts only for a client key that a principal allowed, and a key that no disk grant table keeps gives no call: the machine with no screen gives no access that a machine with a screen does not give.
- **The no-screen line is written once.** The start, a console that does not start and the reap of the compositor can each find the absence; the first writes the line, and each refusal after it adds none.
- **A machine check or an NMI** still stops the machine. To read the error and stop only the process whose memory it touches is planned work.
