package modustool

// The IOMMU (src/md/infrastructure/iommu.md): one machine with the
// remapping unit of Intel (machine_command, the argument iommu). The
// whole system starts with translation on: the storage service runs on the
// data disk, so each page that its block service gives to the device is
// declared. Then the program iommu, a client of the disk of the measures,
// makes the root service start the test device service iommu_device: its
// write and its read through declared pages arrive; its read into a page
// that it declared and whose handle it then closed does not arrive, the kernel writes the line of
// the DMA fault with the device and the address, and the service still
// answers its client. The device of the disk of the measures is at the
// place 17 of bus 0 (pci.SCRATCH_DISK_DEVICE). Then `net` sends its
// datagrams: the network device at the place 18 reads their data from the
// datagram region of `net`, through the unit, with no DMA fault.

TEST_OUTPUT_IOMMU :: BUILD_FOLDER + "/test_output_iommu.txt"

@(rodata)
scenario_iommu := [?]Step {
	{kind = .Wait, text = "kernel: IOMMU: translation on, ", fails_on = "kernel: no IOMMU"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"iommu\")"},
	{kind = .Wait, text = "root: started iommu_device for the device at the place 17 of the bus"},
	{kind = .Wait, text = "iommu_device: a block written from a declared page and read into another declared page: the 4096 bytes arrived: as it must"},
	// The line of the kernel and the line of the service come from two
	// parties: either can be first.
	{kind = .Wait, text = "kernel: a DMA fault of the device at bus 0, device 17, function 0 (service iommu_device): a write of ", any_order = true},
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

iommu_tests_run :: proc() -> bool {
	return machine_test(scenario_iommu[:], BOOT_VOLUME, TEST_OUTPUT_IOMMU, MACHINE_STOP_OK, TEST_DATA_DISK, iommu = true)
}
