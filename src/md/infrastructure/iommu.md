# The IOMMU

A device reads and writes memory by itself, with physical addresses (direct memory access). Without an IOMMU, a device service with a fault, or a service that a device obeys, makes its device write any page of the machine. The IOMMU translates each address that a device gives, through tables that the kernel writes. With it, a device reaches only the memory that its service declared, and a device service with a fault damages no other program. Property 5 names it as a requirement on real hardware ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "5. Kernel off the data path"); property 7 keeps the code of each device out of the kernel.

The terms are in [`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md), "IOMMU" and "Device domain". The guide is [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "K5. Device grant and interrupts".

## The irreducible constraints

1. **The IOMMU names a device by its requester identifier**: the bus, the device and the function of PCI. The kernel must know which requester a service drives, or it cannot build the tables of that device.
2. **A device service already asks the kernel for each physical address that it gives to its device** (`Memory_Physical`). No other path gives a physical address to a program. So that call is the declaration: no new kernel operation is needed.
3. **A page must leave the tables of a device before the page is free again**, and the IOMMU must have forgotten its cached translation (the IOTLB) before then.
4. **A fault of a device must stop nothing.** The device service is a program; its device is its part. A DMA fault is a line of the log and a count.
5. **The kernel holds no driver.** It writes the tables of one standard unit, and it holds no code of a device class.

## The hardware

The first form is Intel VT-d, which the test machine emulates: QEMU with `-device intel-iommu`, which needs the machine type q35. The machine of the tests is q35 today (`tools/modustool/main.odin`, `machine_command`), with no IOMMU device. The part `iommu` of the test adds `-device intel-iommu,intremap=off` first among the devices, and `iommu_platform=on` on each virtio device: without that property, the virtio devices of QEMU do not send their accesses through the IOMMU.

The firmware lists the units in the ACPI table DMAR. The kernel reads one form: one unit of segment 0, that covers every device (the flag `INCLUDE_PCI_ALL`) or lists the functions that it covers. QEMU lists each function of bus 0, with no flag. A function of bus 0 that the list names with a path of one pair is covered. A function that the unit does not cover gives its accesses past the unit: the kernel gives its registers no requester, so it has no domain, and its service declares nothing. Such a device reaches every page, the tables of the unit and the kernel too, so its service can end the isolation of every other device: `Device_Create` of its registers writes one line on the log that says so. Refusing that `Device_Create` was weighed: the machine would lose a device that it has with no IOMMU, and the root service already chooses which service drives which device. A function behind a bridge has no domain in this form (see "The refused binding"), and a bridge gets none either: a device of conventional PCI behind it gives the requester of the bridge, so a domain of the bridge would be the domain of each device behind it. Another form (several units, another segment, a reserved range of memory for a device) leaves the IOMMU off, with one line that says why. The machine then runs as a machine with no IOMMU. The same holds for:

- **a unit that the firmware left in a mode**: translation, the queue of invalidations or interrupt remapping already on (the global status). The kernel does not take over a unit that it does not know: its register invalidations do not work with the queue on, and with remapping on each interrupt needs an entry that does not exist;
- **registers or a configuration memory that are not device memory**: the registers of the unit (64 KiB) and the configuration of bus 0 (1 MiB) must be ranges that the firmware gave as reserved, never memory that it gave as free or loaded, so a table that lies cannot make the kernel write a frame;
- **a unit with no drain of reads and writes** at an invalidation (see "The end of a grant").

While the IOMMU is in use, `Device_Create` refuses a range that meets the registers of the unit or the configuration of bus 0: the kernel owns both, and the root service could otherwise turn translation off.

AMD-Vi (the table IVRS) is left. It has the same parts (a device table by requester, page tables, a log of faults), so the kernel side of this design holds; the formats and the registers differ.

## Mechanism in the kernel, policy outside

The kernel owns the root table, the context table of bus 0 and the second-level page tables of each device. The policy (which device a service drives, which memory a client lends) stays outside: the root service gives a service its device, and a service declares what it gives to its device.

- **The requester of a handle.** When the IOMMU is in use, `Device_Create` of the kind `Memory` reads the base address registers of each function of bus 0 through the memory of the configuration of PCI (the ACPI table MCFG). A function whose memory register starts at the first page of the range is the requester of the new memory object. The kernel reads the bus; it finds no device and starts none: the root service does that.
- **The service of a device** is a program that holds a handle to a memory object with a requester. That is the program to which the root service gave the registers.
- **The declaration.** `Memory_Physical` from a service gives the address as before, and maps each page of the object in the domain of each device whose registers the caller holds by a handle. A call from a program that holds no such handle declares nothing. Device memory (registers, the framebuffer) is never declared: a device reaches the memory of programs only, not the registers of another device. Either each device of the call gets the object, or none that did not have it before.
- **The rights of the handle.** The device writes a page while the service holds a handle with Write to its object; else it only reads it. The kernel creates no right that the handle does not carry (property 2). A declaration through a handle with Write adds the write bit. The close or the revocation of the last handle with Write of the service takes the write bit out of each page in each domain of the service, while a handle with Read keeps the pages; a declaration through a Read handle when the service holds no handle with Write does the same. Example: a client attaches an object with Write, then attaches it again with Read only; the block service declares the new handle and closes the old one, and the device then only reads the object.
- **The record of a declaration.** Each memory object keeps one bit for each slot of a device whose domain maps it, and one bit for the write. There is no table of declarations: a table of fixed size, shared by all services, would let one service fill it and refuse every other one. The cost of a declaration is then paid by the budget of the service alone: the object, and the tables of its domain.
- **The bounds of a service.** A service declares to at most 4 devices whose registers it holds; one more gives `No_Slot`. The kernel has 32 slots of devices, and a slot is free again when its service stops. The count of the faults of a device is apart from its slot: 256 counts by the function of bus 0, and one count for the other buses, so it outlives the service.
- **The refused binding.** A third value of `Device_Create`, the requester that the root service read, would bind a handle to a device with no read of the bus in the kernel. It is a change of the contract for a value that the kernel can read itself, and the root service could then name a wrong device: the read of the registers was chosen. A device on a bus behind a bridge has no domain in this form. The kernel reads the registers once, at `Device_Create`, and trusts that they do not move after: the root service holds the ports of the configuration and could move a register, and a handle would then name a device that is not its requester. The root service is trusted with the bus, as with the choice of the device of each service.
- **The domain.** A device with a declared page has a context entry that names its tables. A device with no service, or whose service has declared nothing, has no context entry: its empty domain. Each of its accesses is refused and recorded.
- **One owner for each domain.** The first program whose declaration to a device succeeds owns its domain until that program stops, or until it closes or loses its last handle to the registers of that device: the domain then ends (its pages, its context entry, the invalidation, its tables, its slot), so a device that the root service gives to another service reaches nothing of the first. The declaration of another program for the same device gives `Bad_State` while the domain lives: the root service gives one device to one service, and the budget of the owner pays for the tables. A failed first declaration leaves no owner; a later failure of the same call leaves the owner with no page of that object, and takes back a write that the call added.
- **The address width.** The kernel takes 4 levels when the unit has 48 bits (the field SAGAW), else 3 levels for 39 bits. An object past the addresses that the tables map gives `Bad_Operation`: an index of a table would wrap and name another page.

## Identity mapping

The address that a device gives is the physical address of the page (device address = physical address). A service then gives its device the address that `Memory_Physical` gave, as on a machine with no IOMMU, and the code of a service has one form for both. The other form, an address space of the device with addresses that the kernel chooses, needs a second result of `Memory_Physical` and a choice of addresses for each device: a contract change for no gain in isolation, because the isolation is in what the tables map, not in which numbers.

The cost: a table of the last level maps 2 MiB of physical addresses, so the declared pages of a device spread over the physical memory take more tables than pages packed at low addresses. The tables of one device are at most one page for each 2 MiB of the machine, plus the upper levels: 2 MiB of tables for each GiB in the worst case, paid by the budget of the owner.

## The end of a grant

- **The service closes or loses its last handle** (`handle_close`, which a revocation also reaches): the device of the service reaches what the service holds, so the kernel clears the pages of the object in each domain that the service owns, and invalidates, before the close returns. The object can live on in its client, which then uses it for its own data: every gift can be taken back (property 2). The block service closes the region before when a client attaches a new one, and the device then loses the old one. A mapping does not keep the declaration: the handle does. The close of a handle of an object that is neither declared nor registers costs two loads.
- **The memory object ends** (`region_release`): under the frame lock, before its frames return, the kernel clears the entries of its pages in each domain, and invalidates.
- **The service stops** (`program_cleanup`): before its handles close, the kernel clears the context entry of each device that it owns, clears its bits in each memory object (one pass over the table of the objects), invalidates, gives the pages of the tables back to its budget, and frees the slots.
- **The invalidation** is register-based and global: one write of the context command register, one write of the IOTLB register with the drains of reads and writes, and a wait until the unit is done. The kernel refuses a unit that does not offer both drains: without them, a write that the unit translated before the invalidation can still reach a page after it, and the specification gives no other way to wait for it. After each command, the granularity that the unit made (CAIG, IAIG) must not be 0. A queue of invalidations, and an invalidation of one domain or one page, are left: an end of a grant is rare.
- **The invalidation runs only when a domain changed**: a clear, a write bit added or taken, an undo, or a new entry on a unit with the caching mode (a unit without it keeps no entry that is not present) or on a unit that asks for a flush of its write buffer (the flush comes first in the invalidation).
- **A mapping of the registers that outlives the handle.** A service that closes its handle of the registers and keeps the mapping can still drive the device, whose domain ended. The root service revokes the registers handle before it gives the device to another service: a revocation ends the mappings that came from the handle, so the device then has no driver and no domain. A device given with no revocation first could write the memory of the next service through the old driver. A loop of declarations and closes runs a global invalidation at each close, a cost that the service pays with its own time; an invalidation of one domain is left. A service that calls `Memory_Physical` again for an object that it declared costs no wait on the unit and drops no translation of another device.
- **The wait** is bounded by one second of the cycle counter for each command, not by a count of reads; an invalidation has at most three commands (the write buffer, the context cache, the IOTLB), so the frame lock is held at most three seconds before the machine stops: each read of a register can be an exit to the hypervisor. The waiter answers `processor_sync` at each turn, as a waiter for a lock does. A unit that does not end a command, or ends it with no invalidation made, stops the machine, as a machine check: a page that a device can still reach must not become free.

The entries change under the frame lock, which already orders the frames of a memory object and the pages of the budgets: no new kind of lock. The lock order is program, then frame: a declaration and a close hold the program lock first. A change walks one table of the last level for each 2 MiB, not the upper levels for each page, so the time under the lock is one pass over the entries of the object. A declaration while the frame lock is held reads no memory of a program.

## A DMA fault

The unit records each refused access in its fault recording registers, and sends the fault event, a message interrupt to the vector `VECTOR_IOMMU_FAULT` of the first processor. The kernel reads each record (the requester, the page, read or write, the reason), clears it, adds 1 to the count of the device, and writes one line on the log:

`kernel: a DMA fault of the device at bus 0, device 17, function 0 (service iommu_device): a write of 000000003f2a5000; reason 0000000000000006; faults of this device: 1`

The kernel stops nothing. A virtio device of QEMU that cannot translate a buffer sets its status "needs a reset" and does no more requests: its service sees that, and the other programs go on.

- **A storm of faults.** A service can make its device fault in a loop. The kernel writes the line of each of the first 4 faults of a device, then one line of the count when the count is a power of two (8, 16, 32...), and counts every fault: the log keeps the first faults whole, and the first processor writes about one line for each doubling. Refused: the bit FPD of the context entry after a count, which needs a change of the entry from the handler and hides the faults that follow.
- **No lost event.** While a record holds a fault, the unit sends no new fault event. The handler reads the fault status again after each pass over the records, and passes again while a record is pending, at most twice in one call: with interrupts off, a call reads at most 2 passes of the records (512 records for the largest unit, 3 reads each). A record that is still pending after the second pass is read at the next tick of the first processor, which reads one word when no record was left: the reports go on under a storm. The handler reads the word with the bit F of a record first, then the other words, so the line names the fault that set it.
- **The name of the service** in the line is read with no lock: in a race with the end of the service, the line can name the program of the slot before or after. It is a line of the log, not a record that a program reads.

The count is in the kernel, and in the line. A report of the devices for a program (a kind of `Inspect` with a row for each device, and its count of faults) is a contract change that is not made: the line of the log is the record until a program needs the count.

## A machine with no IOMMU

One line at the start: `kernel: no IOMMU: the firmware lists no DMA remapping table; each device reaches all memory`. The machine runs as before. The status of property 5 says that the isolation of a device is not held on such a machine ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "5. Kernel off the data path").

## Interrupt remapping

Left. With the bit IRE off, the unit passes a message interrupt (an address of 0xFEEx_xxxx) as before, and the machine q35 with `intel-iommu,intremap=off` needs no remapping. A device service writes the table of the message interrupts through the root service only, so a service cannot send another vector today. A device that writes to the interrupt addresses as a DMA write can still send any vector of the first processor: that is the hazard that remapping removes.

## The proof

The part `iommu` of the test runs the whole system on the machine with the IOMMU: the storage service on the data disk and the network service run with translation on, so each page that a service gives to its device is declared. Then the program `iommu`, a client of the disk of the measures, makes the root service start the test device service `iommu_device` for that disk in place of the block service. The test device service:

1. declares its queue and a data object of two pages, writes a block from the first page and reads it into the second: the bytes arrive;
2. declares a new page with a known pattern, notes its address, then closes its handle and keeps its mapping: the kernel takes the page out of the domain at the close;
3. puts the address of that page in a descriptor of a read;
4. waits for the condition "the device needs a reset" or "the device used the request", with the hang bound, and checks that the page keeps its pattern.

The kernel writes the line of the DMA fault with the device and the address, and the client then gets an answer from the service: the machine goes on.

The step 2 is the means of the test, and the rule of the close at the same time: a page that the service can read after the write, at an address that it no longer holds by a handle. A real fault gives the device a wrong address by a wrong computation; the result is the same refusal. A close of the handles of the registers would not serve: it ends the whole domain, and the device would then fault on its own queue.

The main test does not move to the machine with the IOMMU yet. Its risks: every virtio device of the main test then goes through the emulated unit (a cost in time for each access of the disk and of the network, which is a measure, not a check), and a page that a service forgets to declare stops a part of the main test with a DMA fault, which is the purpose. The part `iommu` finds such a page first.

## Built and left

Built: the reading of the DMAR and MCFG tables; translation with identity domains for the devices with a service; the end of a grant before the frames are free; the fault event and the line of the log; the part `iommu` of the test.

Left: AMD-Vi; interrupt remapping; a queue of invalidations and a narrower invalidation; a device behind a bridge (a bus other than 0); a report of the devices for a program; the main test on the machine with the IOMMU.
