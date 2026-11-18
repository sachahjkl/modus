## Devices

### Physical address

A physical address is the number that the memory and the devices use for a byte of memory, before the page tables translate anything.

A process sees only virtual addresses. A device sees only physical addresses: it reads and writes memory by itself, with no page table between. So only a device service needs one. It calls `Memory_Physical` with the machine handle and the right **Physical**, which the root service gives to device services only. Example: the block service gives its device the physical address of the data region of its client. A physical address is not a handle: a process that knows one cannot map it.

The design: `docs/ARCHITECTURE.md`, "K5. Device grant and interrupts".

Do not use: real address, bus address.

### Device memory

Device memory is a memory object over the registers of a device, at physical addresses that are not memory of the kernel, and mapped with no cache.

Device memory gives a device service the registers of its device as an ordinary memory object, with a handle and its rights. The root service makes one with `Device_Create`, the kind `Memory`, for each base address register of the device. The kernel refuses a range that meets free or loaded memory. A mapping uses no cache, because a read of a register has an effect. Device memory is not the memory where a device moves data, such as the data region. It pays nothing from a budget.

The design: `docs/ARCHITECTURE.md`, "K5. Device grant and interrupts".

Do not use: MMIO region, BAR mapping.

### Message interrupt

A message interrupt is an interrupt that a device sends as a write of a value to an address of the interrupt controller of a processor (MSI-X).

The old interrupt lines are few and shared; a message interrupt belongs to one device. The root service makes one with `Device_Create`, the kind `Message`, writes it in the table of the device, and gives the handle to the device service. When the device writes the value, the kernel counts it and wakes the threads of the holder. The service reads the count with `Interrupt_Read`, then reads its queues. A message interrupt is not a vector: a process never sees the vector.

The design: `docs/ARCHITECTURE.md`, "K5. Device grant and interrupts".

Do not use: MSI, vector.

### IOMMU

The IOMMU is the unit of the machine that translates each address that a device gives before the access reaches memory, through tables that the kernel writes.

Without an IOMMU, a device service with a fault can make its device write any page of the machine. With it, the kernel maps in the tables of a device only the pages that its service declared with `Memory_Physical`. The kernel drives the units of Intel (VT-d) and of AMD (AMD-Vi), with one boot image for both. A machine with no IOMMU writes one line at its start and runs with no such isolation. The IOMMU is not the page table of a process: a process never sees it.

The design: `src/md/infrastructure/iommu.md`.

Do not use: DMA remapper, SMMU.

### Remapping unit

A remapping unit is one part of the IOMMU, with its own registers and tables, that translates the accesses of the devices that the table DMAR or IVRS gives it.

A machine of Intel has several units: often one for its graphics device and one that covers every other device. The kernel gives each device the unit that names it, else the unit that covers every device. The domain, the invalidations and the DMA faults of the device are on that unit. A device that no unit covers reaches all memory, and `Device_Create` of its registers writes one line that says so. A remapping unit is not a device domain: one unit holds the domains of many devices.

The design: `src/md/infrastructure/iommu.md`, "The hardware".

Do not use: DRHD, IOMMU unit.

### Device domain

A device domain is the memory that one device can reach through the IOMMU: the pages that its service declared, at their device addresses.

The kernel keeps one domain for each device that has a service: an entry for its requester on its remapping unit, and page tables of the declared pages. The first process that declares memory to the device owns the domain and pays for its tables. The device writes a page only while the service holds a handle with **Write**. A device with no service has an empty domain, which refuses each access. Example: the device of the data disk reaches its queue and the data region of the storage service only.

The design: `src/md/infrastructure/iommu.md`, "Mechanism in the kernel, policy outside".

Do not use: IOMMU domain, DMA window.

### Shared requester

A shared requester is the one requester that a conventional bridge of PCI gives the accesses of each device behind it.

The IOMMU sees only the shared requester, so the devices behind the bridge have one device domain. The kernel makes it only for a service that holds the registers of each of those devices; else the declaration gives `Bad_State`, with one line. So the root service gives all of them to one service. Example: in the part `iommu_amd` of the machine test, the disk of the measures and an entropy device share the requester 0:1C.0. A device of PCI Express behind a root port keeps its own requester.

The design: `src/md/infrastructure/iommu.md`, "The domain of a conventional bridge".

Do not use: alias requester, DMA alias.

### Device address

A device address is the address that a device gives for a page of a memory object, which the IOMMU translates to the frame of that page.

`Memory_Physical` gives it. For a contiguous object, it is the physical address of the page, with and without an IOMMU. For an object that is not contiguous, on a machine with an IOMMU, the kernel gives the object a device window: the device sees one run, and the service gives one address. Example: the network device reads the data of a send from the datagram region of an endpoint through its device window. A device address is not a physical address: only the IOMMU knows the frame behind a device window.

The design: `src/md/infrastructure/iommu.md`, "Device addresses".

Do not use: bus address, IOVA, DMA address.

### Device window

A device window is the run of device addresses where the IOMMU shows the pages of a memory object that is not contiguous, in their order.

`Memory_Physical` from a device service gives an object its window, and gives each page its frame until the object ends. The slot of the object fixes the window, so it is the same in every device domain. A large object, an `Uncommitted` object, or an object for a unit with too few address bits gets no window. Example: a datagram region of 128 pages anywhere in memory is one run of 512 KiB for the network device. A device window is not a mapping of a process: no process reads through it.

The design: `src/md/infrastructure/iommu.md`, "Device addresses".

Do not use: aperture.

### Reserved memory range

A reserved memory range is memory that the firmware keeps for a device, listed in the table DMAR or IVRS, which the device keeps reading and writing after the start.

The firmware uses one, for example, to emulate a USB keyboard, or as the memory of an integrated graphics device. The kernel maps each range at its own address in a standing domain of each device that the range names, before translation is on, so the device keeps working. The domain of a service of that device maps the ranges too. `Device_Create` refuses a range that meets one, and no declaration maps it: no process gets it. A reserved memory range is not device memory: it is memory, not registers.

The design: `src/md/infrastructure/iommu.md`, "Reserved memory ranges".

Do not use: RMRR.

### DMA fault

A DMA fault is an access of a device to an address that its device domain does not map, which the IOMMU refuses.

The unit records the requester, the page and the kind of access, and sends its fault event to the first processor. The kernel writes one line with the device, its service, the address and the count of faults of that device. After the first 4 faults of a device, it writes a line only at each power of two. A DMA fault stops no process, and the page does not change. It is not a page fault: no thread caused it. It is not a refused interrupt either, which has its own count.

The design: `src/md/infrastructure/iommu.md`, "A DMA fault".

Do not use: IOMMU fault, DMAR fault.

### Queue of invalidations

The queue of invalidations is a ring of descriptors in memory of the kernel through which the kernel tells a remapping unit to forget the entries that it keeps.

A unit keeps the entries that it read. When the kernel clears or changes one, it writes descriptors that name the domain or the interrupt entry, then a wait descriptor, and waits until the unit writes the number of the wait. The unit then forgot each entry and drained the accesses in flight, so a page can become free. A unit that does not reach the wait in one second stops the machine. On a unit of AMD, the queue is a ring of commands. No process sees the queue.

The design: `src/md/infrastructure/iommu.md`, "The end of a grant".

Do not use: QI, invalidation queue, IQ.

### Device table

The device table is the table of a remapping unit of AMD that holds one entry of 32 bytes for each requester: the tables of its device domain, its domain identifier, and its interrupt table.

One device table serves every unit of AMD. An entry of zeros passes every access with no translation, so the kernel writes each entry at the start as the empty domain: one empty table and neither read nor write. A device domain writes the entry of its device, and its end writes the empty entry again. After each change, the unit forgets the entry. A device table is not the context table of Intel, which holds the entries of one bus: it holds those of every bus.

The design: `src/md/infrastructure/iommu.md`, "Two vendors behind one kernel side".

Do not use: DTE, dev table.

### Event log

The event log is a ring of records of 16 bytes in memory of the kernel where a remapping unit of AMD writes each access that it refused, and each fault of its own.

The unit writes a record, then sends the message interrupt of its function to the first processor. The kernel reads each record: a page fault becomes the line of a DMA fault or of a refused interrupt; another record is a line with a count of its own. A full log stops the records: the kernel counts it, empties the log and starts it again. An event log is not the log of the system: the kernel writes the lines of the log from it.

The design: `src/md/infrastructure/iommu.md`, "Two vendors behind one kernel side".

Do not use: PPR log, event buffer.

### Interrupt remapping

Interrupt remapping is the check by the IOMMU of each message interrupt of a device against an interrupt table that the kernel writes, so a device sends only the message interrupts that its service was given.

A message interrupt is a write of 4 bytes: without remapping, a device service can make its device send any vector of any processor. With remapping, the kernel writes one interrupt entry for each message interrupt that `Device_Create` makes, bound to the requester of its device, and the unit refuses every other message. A refused interrupt is a line of the log with its own count; nothing stops. Interrupt remapping is not a route of the lines of the 8259: those lines do not go through the IOMMU.

The design: `src/md/infrastructure/iommu.md`, "Interrupt remapping".

Do not use: IR, IRTE, interrupt translation.

### Bus

The bus is the PCI bus of the machine: each device has a place on it (bus, device, function) and a configuration of 256 bytes or more.

A process that can write the configuration of any device can make any device read or write any memory. So only the root service holds the ports of the configuration. It checks the device at each fixed place, enables it, and starts its device service with a read-only copy of the configuration, the device memory of its registers and one message interrupt. The kernel finds no device; with an IOMMU, it only reads the bus. The code of the bus is `src/library/support/pci`.

The design: `docs/ARCHITECTURE.md`, "U4. Device services".

Do not use: PCI tree.

### Class protocol

A class protocol is the ring and the records that every device service of one device class serves, whatever the vendor of its device.

A class protocol hides the vendor: the storage service reads the block ring the same way for a virtio disk and for an NVMe disk. The device service translates between the registers of its device and the class protocol. The block ring, the frame ring, the input records and the timed stream are class protocols; the display and the handle of one USB device have none yet. A class protocol is not a queue of a device: only the device service sees those.

The design: `src/md/features/device_services.md`.

Do not use: device interface, HAL, ioctl.

### Timed stream

A timed stream is a class protocol whose records carry the time at which their content must reach the device: the samples of sound, later the frames of a video.

A ring of the block or the frame class says what to do; a timed stream also says when. Each record names the time of its first frame by the system clock, its format, its count and the place of its samples. A record whose time is past is refused whole, with the earliest time that it could take. Sound through virtio-snd is its first user, served by the sound service of the group Sound.

The design: `src/md/features/timed_stream.md`.

Do not use: audio stream, media pipe.

### Disk

A disk is a device that keeps blocks when the machine stops.

A disk is the one place where data survives a stop of the machine. The system reads and writes a disk only through its block service, as a row of blocks numbered from 0. The test machine has three disks: the boot volume, which the firmware reads and no block service serves; the data disk; and the disk of the measures. A disk is not a volume with a file system: the storage service writes its own format on the whole data disk, with no partition table.

The design: `docs/STORAGE.md`, "3. The format on the disk".

Do not use: drive, volume (except the boot volume), LUN.

### Block

A block is 4096 bytes of a disk at a number from 0: the unit of each read and write of the block contract.

A block service reads and writes whole blocks (`BLOCK_SIZE` in `src/library/contract/block`). A request names its first block, a count of blocks and a place in the data region; a device with smaller sectors still serves whole blocks. The storage service builds everything that it writes from blocks: a node, an object node, a block of data, a root block. A block has the size of a page, but a block is on the disk and a page is in memory: the two words are not exchangeable.

The design: `docs/STORAGE.md`, "3.1 The blocks".

Do not use: sector, page (for a disk).

### Block service

A block service is the device service of one disk: it serves read, write and flush of blocks to one client through a block ring.

A block service keeps the code that knows a disk device out of the kernel and out of the storage service. The first one is the process `block`, for a virtio block device. The client sends `Attach` with its data region, then reads, writes and flushes. The device moves the bytes with no copy and no kernel entry for each request. A write is on the disk only after a later `Flush`. A block service is not a block layer: it has no cache, no scheduler and no partition.

The design: `src/library/contract/block`.

Do not use: disk driver, block layer.

### Block ring

The block ring is the ring between a block service and its one client: one command record is one request on blocks, and its completion record has the tag of the command and a status.

The block ring carries each request of a client to its disk with no kernel entry for each request. The root service makes it and gives it to the block service and to its client. A command has a kind (`Attach`, `Info`, `Read`, `Write`, `Flush`, `Statistics`), a tag and values. Many requests are in flight, and the device does them in any order. A completion that is not `Ok` carries an error record. A block ring is not a queue of the device: only the block service sees those.

The design: `src/library/contract/block`.

Do not use: I/O queue, submission queue.

### Data region

The data region is the memory object of the client of a block service where the device reads and writes the bytes of the blocks, with no copy.

The device moves the bytes of a block to and from memory of the client, so no process copies them. The client makes the region `Contiguous` and gives it to the block service with `Attach`. A request names a place in the region in bytes, never an address, and the service checks that each byte is in the region: a client cannot make the device write outside its own memory. The data region is not a cache: the client decides what it holds. The frame region is the same idea for a frame service.

The design: `src/library/contract/block`.

Do not use: DMA buffer, bounce buffer.

### Data disk

The data disk is the disk of the storage service: it holds the private stores of each process.

The data disk is the one disk whose content the system keeps. The root service starts its block service when the storage service starts, and gives the block ring to the storage service only. The storage service writes its own format on the whole disk. The modus tool makes a disk of 64 MiB for a run, and a new one for each machine test. The data disk is not a disk of the user: a process sees only its own private store.

The design: `docs/STORAGE.md`, "3. The format on the disk".

Do not use: data drive, home disk.

### Disk of the measures

The disk of the measures is a disk that holds no data that a process keeps: the process `disk` measures the block service on it.

A measure of the block service writes blocks, and a measure on the data disk destroys the stores. So the test machine has a second disk, and the root service gives its block ring to a test module only, such as `disk`. The process `disk` measures reads and writes with one request in flight and then with many, counts the kernel entries for each request, checks a pattern that it wrote, and shows the result. The storage service never uses this disk.

The design: `src/modules/demonstrations/disk`.

Do not use: scratch disk, test disk.

### Network device

A network device is a device that sends and receives frames on a link.

The test machine has one virtio network device, whose link goes to the peer of the modus tool or to the user network of QEMU. The root service starts its frame service when the first process that needs the network starts. The frame service is the only process that touches the device, and the network service is its only client: no other process can send a frame. A network device is not an interface with an address: the IPv4 address belongs to the network service.

The design: `docs/ARCHITECTURE.md`, "U4. Device services".

Do not use: NIC, network card, network adapter.

### Frame

In the group Devices, a frame is one Ethernet frame: the bytes from the destination hardware address to the end of the data, with no check sequence, 1514 bytes at most.

A frame is the unit that a network device sends and receives, and the unit of the frame contract: 14 bytes of header and 1500 bytes of data. The device adds and removes the check sequence. The network service builds and reads each frame with `src/library/support/network`. A datagram or a segment fits one frame, so the system never fragments. A frame is not a datagram and not a packet of IPv4: those are its content. It is not the frame of QUIC either, which has its own entry.

The design: `src/library/contract/frame`.

Do not use: packet (for this), datagram (for this), message.

### Hardware address

A hardware address is the 6 bytes that name a network device on its link.

A frame names its destination and its source by hardware addresses. The network service learns the hardware address of its own device from the completion of the command `Info` of the frame ring, and learns the hardware address of each other machine of the link by ARP, as a neighbor. The device of the test machine has 52:54:00:12:34:56.

A hardware address has meaning on one link only: it is not an address of IPv4 and it does not cross the gateway.

The design: `src/library/contract/frame`.

Do not use: MAC address, physical address (for this).

### Frame service

A frame service is the device service of one network device: it sends and receives frames for one client through a frame ring, and it does not read a frame.

The frame service keeps the code that knows a network device out of the kernel and out of the network service. The first one is the process `frame`, for a virtio network device. Its one client, the network service, sends `Attach` with its frame region, then `Send` for each frame and `Receive` for each place where a frame can arrive. The device reads and writes the frames with no copy, and drops a frame when no `Receive` waits. A frame service is not a network stack: it knows no protocol.

The design: `src/library/contract/frame`.

Do not use: NIC driver, network driver.

### Frame ring

The frame ring is the ring between a frame service and its one client: one command record is the send of one frame, or a place for one frame that arrives.

The frame ring carries the requests of the client to its device with no kernel entry for each request. Its commands are `Attach`, `Info`, `Send`, `Receive`, `Statistics`, `Read_Region_Add` and `Read_Region_Remove`. Many requests are in flight. A `Receive` stays in flight until a frame arrives: the client gives the places before the frames come, so the service allocates no memory for a frame. A frame ring is not one queue for each direction: one ring carries both, and the tag of the command says which request completed.

The design: `src/library/contract/frame`.

Do not use: TX queue, RX queue, descriptor ring (for this).

### Frame region

The frame region is the memory object of the client of a frame service where the device reads and writes the frames, with no copy.

It is the data region of the frame contract: contiguous, and given to the service with `Attach`. A request names a place in the region in bytes, never an address; a byte outside it gives `Out_Of_Range`. The network service owns the frame region. It copies each datagram that arrives one time, from the frame region to the datagram region of a process, and writes only the headers of a datagram to send. A frame region is not a socket buffer: a process with an endpoint never sees it.

The design: `src/library/contract/frame`.

Do not use: DMA buffer, skb, mbuf.

### Read region

A read region is a memory object that the client of a frame service gives with the right Read only, where the device reads the second part of a frame to send.

The read region lets the device read data where its writer put it, so that no service copies it. The network service gives the datagram region of each endpoint as a read region. A `Send` then names the headers in the frame region and the data in the read region. The frame service refuses a read region with the right **Write**, and keeps its handle until the last `Send` that reads the region is complete. A read region is not a frame region: the device never writes it.

The design: `src/md/infrastructure/network_data_path.md`, "The send with no copy".

Do not use: send buffer, transmit buffer, scatter list.

### Virtio

Virtio is the standard of devices that work through queues in shared memory, which the first machine uses for its disks and its network device.

A virtio device is already a set of queues in memory, so a device service translates between these queues and a ring with little code. The system uses virtio 1 over PCI, the modern interface only. `src/library/support/virtio` holds what each virtio device service does the same way: the capabilities, the features and the split queues. The block service and the frame service use it. Virtio is not a part of the kernel: the kernel has no code for any device.

The design: `docs/ARCHITECTURE.md`, "U4. Device services".

Do not use: paravirtual device.
