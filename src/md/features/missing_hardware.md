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
| A disk that stops to answer | Built | A deadline for each block request: past it, the block service completes each request in flight with `Device_Error` and the record `No_Answer` of the device, writes its line and stops; it does the same, with the same record, when the device sets its needs-reset bit, as such a device answers none of them. The storage service holds the handle of the block service with `.Read`, and bounds each wait for a completion by a stall of the hang bound. A record `No_Answer`, the stop of the block service or its own bound make the disk silent: the storage service writes its line once, and from then on refuses each read and each change at once, with no request to the block service |
| No screen | The root service stops to serve its ring | The root service starts no console, writes its line and starts the other services |
| No PIT | The first processor hangs before its first line | The calibration wait is bounded; the TSC frequency of CPUID is used when the processor states it |
| No PS/2 controller | The input service spins on one processor for ever | The input service writes its line and stops; the root service starts the other services |
| A frame service that stops after it maps its ring | Built | The network service holds the handle of the frame service with `.Read`, and bounds its wait for an answer by the hang bound; at the stop of the frame service or at the bound it writes its line and stops. The root service writes one line when the network service stops or cannot start, and refuses each later start that needs an endpoint |
| An IOMMU unit that does not finish its first invalidation | The machine stops | No device service holds memory yet, so the units go off and the machine runs as a machine with no IOMMU, with its line |
| A stop of the boot program for memory or for the map of the firmware | A message on the firmware console, then a power off at once | The message stays on the boot display, the watchdog is off, and the boot program waits, as for a refusal of trust |
| An xsave area that the processor does not read back | `Start_Failed` | One more proof with the form `fxsave`, with its line |
| No table of the APIC | One processor, with no line | One processor, with its line |
| An entropy read that never completes | The fresh bytes stop with no line | A deadline; the read counts as refused |

## The tests

Each absence has a machine test that removes the part from QEMU, and checks its line and a later step that still works. The hang bound is the only time in it:

- no PS/2: `-machine q35,i8042=off`;
- no PIT: `-machine q35,pit=off`;
- no screen: `-vga none`, then a call through `remote`;
- no network device, no data disk: the machine leaves the device out;
- a disk that stops to answer: the NBD server of the tool reads each request from the first write of a block that starts with a marker, and answers none. A marker and not a count of requests: QEMU joins and splits requests, and the start writes a count that changes with each release, so a count would cut the boot. The scenario writes that block with the console, waits for the line of the block service and of the storage service, then runs a command that needs no store. Before its end the tool closes the connection, so QEMU fails the request that waits and can stop. The data disk of this machine has no ioevent file: with one, QEMU drains the requests of the disk when the root service turns the bus master off, and the request that never ends would stop every processor;
- a frame service that stops: QEMU has no form of a network device that the root service starts and the frame service then refuses after it maps its ring. The machine with no network device is the test: the root service writes its line, refuses `net`, and the console runs on. The wait of the network service for a frame service that stops has host tests of its decision only.

## The refused forms

- **A silent fallback.** A part that is absent with no line is a fault that nobody can find: one processor with no word of the missing table, a screen of another size with no word of the mode. The line is part of the form.
- **A stop of the machine for an absence.** A stop hides the cause when the message is on a console that nobody sees, and it removes each capability that did not need the part.
- **A retry for ever.** A loop that tries again with no bound is a hang with more work.
- **A part that the system pretends to have.** A service that answers `ok` with no device gives wrong data to its clients. An absent capability is refused, never simulated.

## The subtle points

- **The wait of a client is the hazard, not the fault of the device.** The device service already stops on a fault; the hang comes from the processes that wait for it. Each wait for another process holds its handle or has a deadline.
- **The deadline of a device request** comes from the hang bound of the system, not from a measure of the speed of a device, so that a slow disk is not called absent.
- **A request past its deadline is never given back to the device.** The device can still write the data region of that request. The block service therefore does not take a new request after a deadline: it completes each request in flight and stops, and the root service turns the bus master off. A service that went on would give the same place of the region to a new request that the late answer can overwrite.
- **The storage service and the block service have the same bound, and either can end first.** The block service counts from the moment that it gives the request to the device; the storage service counts a stall from its last completion. Both ends give the same line of the storage service: the record `No_Answer`, the stop of the block service and the bound of the storage service each make the disk silent. Once silent, the storage service never reads the block ring again, so a late completion cannot be taken for the answer of a later request.
- **The storage service does not stop on a silent disk, also before its open.** A stop makes the root service start it again for the next process with a store: a new block service, a reset of a device that still holds a request (which QEMU drains, and the machine freezes), a new wait and new lines. The device can also still write the data region, which a stop frees. So the service serves on with no store known, and refuses each call that names a store with `Device`.
- **A silent disk refuses reads too.** A read would wait for the same device. The storage service answers each call that needs a block with `Device` at once, and a call that needs no block is still served.
- **The root service refuses the network once.** After the network service stops or cannot start, each start of a process with an endpoint is refused with no new start of the frame service and no new line: a frame service that stops at each start would cost a start and a line for each process that asks.
- **At the start, before a device service holds memory, the IOMMU can go off.** After it, it cannot: the reason of the stop is a page that a device can still reach.
- **A machine check or an NMI** still stops the machine. To read the error and stop only the process whose memory it touches is planned work.
