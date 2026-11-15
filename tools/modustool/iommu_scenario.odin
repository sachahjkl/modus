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
// place 17 of bus 0 (pci.SCRATCH_DISK_DEVICE).

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
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

iommu_tests_run :: proc() -> bool {
	return machine_test(scenario_iommu[:], BOOT_VOLUME, TEST_OUTPUT_IOMMU, MACHINE_STOP_OK, TEST_DATA_DISK, iommu = true)
}
