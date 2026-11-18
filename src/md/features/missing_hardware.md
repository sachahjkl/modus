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
| No PIT | The first processor hangs before its first line | Built. The calibration wait is bounded by the cycle counter; an output of the 8254 that is high before its count starts is no 8254. The frequency of the cycle counter that CPUID leaf 0x15 or 0x16 states is then the time base, and the timer is measured against the cycle counter; with none, the line and `Start_Failed`. The start of the other processors waits with the cycle counter, never with the 8254 |
| No PS/2 controller | The input service spins on one processor for ever | The input service writes its line and stops; the root service starts the other services |
| A frame service that stops after it maps its ring | The network service waits with no end | The network service holds the handle of the frame service, writes its line and stops |
| An IOMMU unit that does not finish its first invalidation | The machine stops | Built. No device service holds memory yet, so the units go off and the machine runs as a machine with no IOMMU, with its line. The first invalidations are each one that the start of the units makes: the global one, the interrupt entries of VT-d, and the entries of each requester of AMD-Vi |
| A stop of the boot program for memory or for the map of the firmware | A message on the firmware console, then a power off at once | The message stays on the boot display, the watchdog is off, and the boot program waits, as for a refusal of trust |
| An xsave area that the processor does not read back | `Start_Failed` | Built. One more proof with the form `fxsave`, x87 and SSE only, with its line; `Start_Failed` when that proof fails too |
| No table of the APIC | One processor, with no line | Built. One processor, with its line, for a table that is absent, shorter than its header, or that lists no usable processor. A table that lists one processor gets no line: that machine has one |
| A serial port that does not take bytes | Each writer of the serial port waits with no end | Built. A wait for the transmit register is bounded; past it the port is silent, and each writer drops its bytes with no wait until the register is empty again. The log keeps each record; the count of the dropped bytes is a line of the log |
| An interrupt to another processor that the controller does not send | The sender waits with no end, with its locks | Built. The wait for the delivery bit is bounded and the send is counted; a processor whose reset was not sent keeps its record, and no other processor starts |
| An entropy read that never completes | The fresh bytes stop with no line | A deadline; the read counts as refused |

## The tests

Each absence has a machine test that removes the part from QEMU, and checks its line and a later step that still works. The hang bound is the only time in it:

- no PS/2: `-machine q35,i8042=off`;
- no PIT: `-machine q35,pit=off`, with a processor whose highest leaf of CPUID is 0x14 (`-cpu max,level=0x14`, the part `no_pit`). QEMU fills no leaf 0x15, so with a leaf 0x15 the outcome would depend on the host; with no leaf it is the stop on every host. The path of a stated frequency, the bounds of the waits, the absence of a table of the APIC and the second proof of the extended state reach no QEMU machine: the host tests of the kernel parts `time_base` and `acpi_processors` hold their decisions;
- no screen: `-vga none`, then a call through `remote`;
- no network device, no data disk: the machine leaves the device out;
- a disk that stops to answer: the NBD server of the tool stops to answer after a count of requests.

## The refused forms

- **A silent fallback.** A part that is absent with no line is a fault that nobody can find: one processor with no word of the missing table, a screen of another size with no word of the mode. The line is part of the form.
- **A stop of the machine for an absence.** A stop hides the cause when the message is on a console that nobody sees, and it removes each capability that did not need the part.
- **A retry for ever.** A loop that tries again with no bound is a hang with more work.
- **A part that the system pretends to have.** A service that answers `ok` with no device gives wrong data to its clients. An absent capability is refused, never simulated.

## The subtle points

- **The wait of a client is the hazard, not the fault of the device.** The device service already stops on a fault; the hang comes from the processes that wait for it. Each wait for another process holds its handle or has a deadline.
- **The deadline of a device request** comes from the hang bound of the system, not from a measure of the speed of a device, so that a slow disk is not called absent.
- **At the start, before a device service holds memory, the IOMMU can go off.** After it, it cannot: the reason of the stop is a page that a device can still reach.
- **A bound before the kernel knows the frequency.** The 8254 and the serial port are waited for before the calibration, when the frequency of the cycle counter is 0. The bound then takes the highest frequency that the kernel accepts, 10 GHz: on a slower processor the wait is longer, never shorter, so a working part is not called absent. The wait of the 8254 is one second at that frequency, a hundred times the count of the calibration, so a host that stops the machine for a while does not end it.
- **A high output before the count.** A port with no device reads with each bit set, so the output of channel 2 reads high at once and a wait would end at once, with a time base of 0. The write of the mode makes the output low until the end of the count; a high output there is no 8254. A host that stops the machine between the write of the count and the read gives the same, so the start tries three times.
- **A silent serial port is a state.** Without it, each byte of a dead port would wait the whole bound, and a start that drains each line at once would take minutes. The first read that finds the register empty ends the state.
- **A count that a locked path cannot write.** A writer of the serial port and a sender of an interrupt can hold any lock, and the log lock comes before the run lock. So they count, and the tick, which holds none, writes the count each time it reaches a new power of two: a part that stays broken writes about one line for each doubling. The line is a record of the log: the serial port shows it when it takes bytes again, and the log shows it when the port never does.
- **A reset that was not sent.** A processor that did not start is reset before its record and its stacks are freed. When the controller does not send the reset, the processor can still run from that memory: it stays taken, with the page table of the start, and the next processor would take the same index, so no other processor starts.
- **A machine check or an NMI** still stops the machine. To read the error and stop only the process whose memory it touches is planned work.
