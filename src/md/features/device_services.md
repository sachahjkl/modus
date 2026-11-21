# Device services for the hardware of a real machine

Today each device service of the system drives one virtio device, or one fixed device of the test machine, at a fixed place of the bus ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "U4. Device services"). A real machine has devices of many vendors, at places that the firmware chooses. This file records how a device service serves such a device: what it is, which handles it holds, how the root service chooses it and trusts it, what happens when it fails, and the devices that the system will never serve itself. Nothing of it is built.

The rules are [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "7. No drivers in the kernel, and fixed hardware first", and "5. Kernel off the data path". The mechanism of the kernel is [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "K5. Device grant and interrupts", and [../infrastructure/iommu.md](../infrastructure/iommu.md). The terms are in [`docs/glossary/running_code.md`](../../../docs/glossary/running_code.md), "Device service", and in [`docs/glossary/devices.md`](../../../docs/glossary/devices.md), "Class protocol".

## The term

The code that knows a device is a device service, whatever the vendor. Other systems call it a driver; the glossary keeps one term for one concept, so this file says "device service". The term "driver domain" stays: it names a guest that holds a driver of another system ([gpu_access.md](gpu_access.md)).

## The model: a translator between a vendor and a class

A device service is an ordinary process that translates. On one side it speaks the registers and the queues of the device of one vendor. On the other side it serves the class protocol of the device: the block ring for a disk, the frame ring for a network device, the input records for a keyboard and a pointer, the timed stream for sound ([timed_stream.md](timed_stream.md)), and the protocols still to write for a display and USB.

- No process but the device service sees the vendor. The storage service reads the block ring the same way for a virtio disk and for an NVMe disk.
- For virtio the translation is thin, because a virtio device is already a set of queues. For a device of a vendor it is thicker, and it stays in the one process.
- The class service (the storage service, the network service, the compositor) does not change when a device service of another vendor serves its class.

This is the "user-space translator" of property 7 in its general form.

## The handles of a device service

A device service holds the handles of its device and nothing else:

- the device memory of its registers (`Device_Create` of the kind `Memory`);
- its message interrupts (`Device_Create` of the kind `Message`);
- a budget of memory for its queues and its buffers, which it declares to the IOMMU with `Memory_Physical`, and the machine handle with the right Physical only;
- the ring of its class, which the root service connects to the class service.

It holds no network, no store, no surface and no grant of the principal. A device service that reads hostile data from its device can harm only its own process and the ring of its class.

## How the root service chooses a device service

The root service reads the bus, as today, and finds each device by its PCI identity: the vendor, the device, the class and the subclass. A table of identities gives, for each identity, the module of its device service, by hash. The root service starts that module with the handles above.

Trust follows the source of the module:

- **A device service of the boot image** is trusted by the signed system description, as each module of the boot image is. Its row in the table of identities is a part of the system description.
- **A device service from the disk** (a module of the store `module_files`, written by a third party) needs an explicit grant of a principal for that one device, in the disk grant table of the principal ([processes_from_a_disk.md](processes_from_a_disk.md)). The grant names the hash of the module and the identity and the place of the device. The name of a module gives nothing.

A device for which no row and no grant exist gets no device service. The root service writes one line that names its identity, and the device stays with no context entry in the IOMMU, so each of its accesses is refused.

## No IOMMU, no third party

With no IOMMU, a device reaches all memory, and the process that drives it holds the whole machine (property 7). So on a machine with no IOMMU, or for a device that no remapping unit covers, the root service refuses each device service from the disk, with one line. A device service of the boot image still starts there, because the publisher of the system signed it; that is the state of today.

## A device service that fails

A device service that stops is started again by the root service. The class service keeps its side of the ring and its own state, and takes the ring back from the new device service. For the block ring, the storage service sends again each request that had no completion; for the frame ring, a lost frame is a loss that the protocols above already accept.

Before calling `Process_Stop` on any device service, the root service clears PCI Bus Master on its device (`started_process_stop` and `internal:root/device_stop`), so the device makes no access to memory between the stop of its service and the reap, also on a machine with no IOMMU. When a device service stops on its own, `driver_end` turns Bus Master off at the reap before closing its queue memory. The kernel already ends the device domain of a stopped device service before its handles close ([../infrastructure/iommu.md](../infrastructure/iommu.md)). The new device service asks the device for a reset before it uses it. A device that does not reset is left with no service, with one line.

## Firmware blobs

Many devices need a firmware blob that the device service sends to the device at its start. A blob is a resource, named by its hash: in the boot image for a device service of the boot image, or in the store `module_files` beside its module for a device service from the disk, under the same grant. The device service receives it read-only and sends it to the device. The system never runs it on the processor.

## A driver domain for the devices that the system will never serve

Some devices have no public description, or a driver of a size that the project will never write: a GPU, a Wi-Fi card. For them, a driver domain runs Linux in a guest, with the device passed to the guest through the IOMMU, and with a small translator that serves the class protocol of the device to the system. Processes of the system see the class protocol only; they never see the guest. The form for the GPU is in [gpu_access.md](gpu_access.md); the guest is in [guest.md](guest.md) and [foreign_systems.md](foreign_systems.md).

## USB

USB adds one level. The device service of the xHCI controller owns the controller and the bus. For each USB device that it finds, it gives one handle to a class device service: the USB keyboard, the USB disk. That handle reaches the endpoints of that one USB device, and no other device of the bus. The class device service then serves its class protocol, as above. A grant for a USB device names that device, and the line of property 20 holds: a USB device is a device queue behind a grant.

## The refused forms

| Form | Why refused |
|---|---|
| A device service that holds more than its device (a store for its settings, the network for updates) | A fault in the code that reads the device then reaches that grant. A setting comes in its context; an update is a new module by hash |
| A device service that finds its device itself on the bus | The root service alone holds the configuration ports. A device service that reads the bus could take a device of another service |
| A device service from the disk on a machine with no IOMMU | It holds the whole machine by DMA |
| A device service from the disk trusted by its name or by a signature of its author | A name gives nothing in this system. The grant of a principal names the hash and the device |
| A firmware blob run on the processor, or a blob with no hash | A blob is data for the device. Its identity is its hash, as for a module |
| A Linux driver loaded into a process of the system, with a layer of its kernel interface | It brings the kernel interface of Linux into the system. A whole Linux in a driver domain keeps that interface inside the guest |
| One USB device service for every USB device | A fault in the code of one class reaches the devices of every class |

## The open points

- **The table of identities.** Its format, its place in the system description, and the rule for one identity that two modules serve.
- **The device grant.** The form of a grant of a principal for one device: the identity, the place on the bus (which changes when a card moves), the hash of the module and of its blob.
- **The restart protocol.** The state that a class service keeps for each ring, the request that it sends again, the count of restarts after which the root service stops trying.
- **The class protocols still to write**: the display (a scanout and its modes) and the handle of one USB device. Sound has the timed stream ([timed_stream.md](timed_stream.md)).

## State

Not built. The device services of today are of the boot image, at fixed places, for virtio and for the fixed devices of the test machine. The order of this work is in [desktop_to_browser.md](desktop_to_browser.md), phase G.
