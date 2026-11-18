package modustool

import "modustool:foundation"
import "modustool:build"

// The IOMMU (src/md/infrastructure/iommu.md): one machine with the
// remapping unit of Intel (machine_command, the argument iommu). The
// whole system starts with translation and interrupt remapping on: the
// storage service runs on the data disk, so each page that its block
// service gives to the device is declared, and each interrupt of a device
// comes through its entry. Then the process iommu, a client of the disk of
// the measures, makes the root service start the test device service
// iommu_device: its write and its read through declared pages arrive, with
// its message interrupt; its read into the interrupt addresses is a set of
// messages to entries that it was not given, and the kernel writes the line
// of the refused interrupt; its read into a page that it declared and whose
// handle it then closed does not arrive, the kernel writes the line of the
// DMA fault with the device and the address, and the service still answers
// its client. The disk of the measures is behind a root port of PCI
// Express at the place 28 of bus 0 (pci.SCRATCH_BRIDGE_DEVICE), at the
// place 0 of bus 1: its accesses go through the context table of bus 1.
// Then `net` sends its datagrams: the network device at the place 18 reads
// their data from the datagram region of `net`, which is not contiguous,
// through its window in the unit, with no DMA fault. The machine also has
// the entropy device at the place 19: its two reads arrive through the unit
// with no DMA fault.

TEST_OUTPUT_IOMMU :: foundation.BUILD_FOLDER + "/test_output_iommu.txt"

@(rodata)
scenario_iommu := [?]Step {
	// One unit; the walk found bus 0 and the bus behind the root port.
	{kind = .Wait, text = "kernel: IOMMU: translation on, 1 units, 2 buses, ", fails_on = "kernel: no IOMMU"},
	{kind = .Wait, text = "kernel: IOMMU: interrupt remapping on: a device sends only the message interrupts that its service was given", fails_on = "kernel: IOMMU: no interrupt remapping"},
	{kind = .Wait, text = "kernel: ok"},
	// The entropy device writes its bytes through the unit into the queue
	// memory that its service declared (src/md/features/entropy_device.md).
	// Its lines come while the desktop starts, in no fixed order.
	{kind = .Wait, text = "root: started entropy for the device at the place 19 of the bus", any_order = true},
	{kind = .Wait, text = "root: the entropy device gave 64 bytes in 2 reads: 64 bytes mixed into the random generator of the system; refused reads: 0", fails_on = "kernel: a DMA fault of the device at bus 0, device 19, ", any_order = true},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"iommu\")"},
	{kind = .Wait, text = "root: started iommu_device for the device at the place 0 of the bus 1, behind a bridge"},
	{kind = .Wait, text = "iommu_device: a block written from a declared page and read into another declared page: the 4096 bytes arrived: as it must"},
	{kind = .Wait, text = "iommu_device: the message interrupt of the device arrived through its entry: as it must"},
	// QEMU gives a DMA write to the interrupt addresses no requester: the
	// record names 0xFFFF, the device 255:31.7. The entry 0x7800 is the
	// first remappable message of the read, past the table of 16 entries.
	{kind = .Wait, text = "kernel: an interrupt of the device at bus 255, device 31, function 7 (service no service) is refused: entry 30720; reason 0000000000000021; refused interrupts of this device: 1", any_order = true},
	{kind = .Wait, text = "iommu_device: a read into the interrupt addresses, to entries that the kernel did not give this device: the device gave the request back: as it must", any_order = true},
	// The line of the kernel and the line of the service come from two
	// parties: either can be first.
	{kind = .Wait, text = "kernel: a DMA fault of the device at bus 1, device 0, function 0 (service iommu_device): a write of ", any_order = true},
	// A virtio device of QEMU that the unit refuses needs a reset; the line
	// names what the device did, and the bytes of the page are the check.
	{kind = .Wait, text = ", and the page keeps its 4096 bytes: as it must", fails_on = "iommu_device: a read into a page that was not declared: the device wrote the page", any_order = true},
	{kind = .Wait, text = "iommu: the test device service answered after its read into a page that was not declared: the machine goes on: as it must"},
	// The send with no copy through the unit: the device of the network
	// reads the data of each datagram of `net` from its datagram region,
	// which the frame service declared with the right Read only
	// (src/md/infrastructure/network_data_path.md, "The send with no copy").
	{kind = .Launch, text = "net"},
	{kind = .Wait, text = "frame: a read region of 128 pages at the place 0, held with the right Read only: the device reads the data of the frames to send there", any_order = true},
	{kind = .Wait, text = "net: UDP to 10.0.2.2 port 7, 41 bytes: the same 41 bytes came back from 10.0.2.2 port 7 in ", fails_on = "kernel: a DMA fault of the device at bus 0, device 18, "},
	{kind = .Wait, text = "net: the measures are done", fails_on = "kernel: a DMA fault of the device at bus 0, device 18, "},
	{kind = .Front, text = "net"},
	{kind = .Close, text = "net"},
	{kind = .Wait, text = "root: net stopped with code 0"},
	{kind = .Wait, text = "network: the endpoint of net, UDP: this service read each payload byte one time on receive, for the copy, and on send only the 8 bytes of each header that it checks, and 0 bytes of the data; it computed no checksum: as it must"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

iommu_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_iommu[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_IOMMU, exit_status = build.MACHINE_STOP_OK, iommu = .Intel, entropy_device = true})
}

// The IOMMU of AMD (src/md/infrastructure/iommu.md, "Two vendors behind
// one kernel side"): the same system on the machine with the unit of AMD
// (machine_command, the argument iommu), with translation and interrupt
// remapping on. The disk of the measures and an entropy device are behind
// a conventional bridge at the place 28 of bus 0 (pci.SCRATCH_BRIDGE_DEVICE),
// at the places 0 and 1 of bus 1: both give their accesses the requester
// of the bridge, 0:1C.0, and the table IVRS of QEMU names them by an alias
// to it (src/md/infrastructure/iommu.md, "Bridges"). The root service
// gives the test device service iommu_device the disk and the registers of
// the entropy device, and the kernel makes their one domain. QEMU 10
// records the device of a page fault of AMD by its device and its function
// only, so the line names the device only on bus 0: the requester of the
// bridge is there. The write and the read of the service through declared
// pages arrive, with its message interrupt through the interrupt table of
// the requester of the bridge; its read into the interrupt addresses ends,
// and QEMU 10 records no event for a message that it refuses, so no line
// of a refused interrupt is waited for; its read into a page that it no
// longer declares does not arrive, and the kernel writes the line of the
// DMA fault with the requester of the bridge from the event log. Then the
// service starts its disk again and closes the registers of the entropy
// device: its domain ends, its next declaration is refused, with the line
// of the kernel that names the entropy device, and a read of the disk into
// a page that it declared before does not end: the tool stops the machine,
// gives the disk a new size and starts it again, and the service, which
// waits for that size, finds the page as it was and no interrupt. Then `net` sends its datagrams through the window of
// its datagram region.

TEST_OUTPUT_IOMMU_AMD :: foundation.BUILD_FOLDER + "/test_output_iommu_amd.txt"

// The command of the monitor that gives the disk of the measures (the
// drive `scratch`) twice its size: a size that it does not have, as the
// machine of AMD makes the disk new at SCRATCH_DISK_SIZE.
SCRATCH_DISK_RESIZE :: "block_resize scratch 64M"
#assert(SCRATCH_DISK_SIZE == 32 << 20)

@(rodata)
scenario_iommu_amd := [?]Step {
	// One unit; the walk found bus 0 and the bus behind the conventional
	// bridge.
	{kind = .Wait, text = "kernel: IOMMU: an I/O virtualization table of AMD, 1 units, ", fails_on = "kernel: no IOMMU"},
	{kind = .Wait, text = "kernel: IOMMU: translation on, 1 units, 2 buses, ", fails_on = "kernel: no IOMMU"},
	{kind = .Wait, text = "kernel: IOMMU: interrupt remapping on: a device sends only the message interrupts that its service was given", fails_on = "kernel: IOMMU: no interrupt remapping"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"iommu\")"},
	// The service can make its first declaration before the root service
	// writes its lines: the three lines come in no fixed order.
	{kind = .Wait, text = "root: started iommu_device for the device at the place 0 of the bus 1, behind a bridge", any_order = true},
	{kind = .Wait, text = "root: iommu_device also holds the registers of each other device behind the conventional bridge in front of the bus 1, which shares its requester; other devices: 1", any_order = true},
	{kind = .Wait, text = "kernel: IOMMU: the service iommu_device holds the registers of each of the 2 devices that share the requester at bus 0, device 28, function 0 behind a conventional bridge: they have one domain", fails_on = "kernel: IOMMU: the service iommu_device does not hold the registers", any_order = true},
	{kind = .Wait, text = "iommu_device: a block written from a declared page and read into another declared page: the 4096 bytes arrived: as it must"},
	{kind = .Wait, text = "iommu_device: the message interrupt of the device arrived through its entry: as it must"},
	{kind = .Wait, text = "iommu_device: a read into the interrupt addresses, to entries that the kernel did not give this device: the device gave the request back: as it must"},
	// The line of the kernel and the line of the service come from two
	// parties: either can be first. QEMU 10 gives the access of a page
	// fault in other flags than the specification, so the line names it a
	// read: the test does not wait for the word.
	// The fault names the requester that the bridge gives the disk.
	{kind = .Wait, text = "kernel: a DMA fault of the device at bus 0, device 28, function 0 (service iommu_device): a ", any_order = true},
	{kind = .Wait, text = ", and the page keeps its 4096 bytes: as it must", fails_on = "iommu_device: a read into a page that was not declared: the device wrote the page", any_order = true},
	// Without the registers of the entropy device, the service gets no
	// domain: the entropy device would reach what it declares.
	{kind = .Wait, text = "kernel: IOMMU: the service iommu_device does not hold the registers of the device at bus 1, device 1, function 0, which shares the requester at bus 0, device 28, function 0 behind a conventional bridge: the declaration is refused, and they get no domain", any_order = true},
	{kind = .Wait, text = "iommu_device: without the registers of the other device behind the conventional bridge, a declaration is refused: as it must", any_order = true},
	// The domain ended. QEMU 10 keeps the read that the service then gives
	// its disk: it neither ends it nor says that the device needs a reset,
	// and the count of the faults of the requester of the bridge is past
	// the lines that the kernel writes whole. So neither bounds the wait:
	// the tool does. The stop of the machine ends each read that QEMU took,
	// then the disk gets a new size, which the service waits for; then it
	// checks that the read did not end, that the page keeps its bytes, and
	// that no interrupt of the device arrived, the configuration interrupt
	// of the new size too.
	{kind = .Wait, text = "iommu_device: a read given to the device after the end of its domain: the service waits for the new size of the disk", fails_on = "iommu_device: after the end of its domain, the device "},
	{kind = .Monitor, text = "stop"},
	{kind = .Monitor, text = SCRATCH_DISK_RESIZE},
	{kind = .Monitor, text = "cont"},
	{kind = .Wait, text = "iommu_device: after the end of its domain, a read of the device into a page that this service declared before does not end, the page keeps its 4096 bytes, and no interrupt of the device arrives, also for its new size: as it must", fails_on = "iommu_device: after the end of its domain, the device "},
	{kind = .Wait, text = "iommu: the test device service answered after its read into a page that was not declared: the machine goes on: as it must"},
	{kind = .Launch, text = "net"},
	{kind = .Wait, text = "frame: a read region of 128 pages at the place 0, held with the right Read only: the device reads the data of the frames to send there", any_order = true},
	{kind = .Wait, text = "net: UDP to 10.0.2.2 port 7, 41 bytes: the same 41 bytes came back from 10.0.2.2 port 7 in ", fails_on = "kernel: a DMA fault of the device at bus 0, device 18, "},
	{kind = .Wait, text = "net: the measures are done", fails_on = "kernel: a DMA fault of the device at bus 0, device 18, "},
	{kind = .Front, text = "net"},
	{kind = .Close, text = "net"},
	{kind = .Wait, text = "root: net stopped with code 0"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

iommu_amd_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_iommu_amd[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_IOMMU_AMD, exit_status = build.MACHINE_STOP_OK, iommu = .Amd})
}
