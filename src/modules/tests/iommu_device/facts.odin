package iommu_device_service

// The log fact of the test device service of the IOMMU
// (src/md/features/log_facts.md): its one line with a value. The fact
// template is the sentence that the line wrote before it was a fact, so the
// wait of the machine test reads it as before.

// The device gave back a read into a page that this service did not
// declare, and the page kept its bytes. The status is the byte that the
// device wrote in the request: a word of the device, which keeps its
// number.
@(log_fact = "iommu_device: a read into a page that was not declared: the device gave the request back with the status {device_status}, and the page keeps its 4096 bytes: as it must")
Undeclared_Read_Given_Back :: struct {
	device_status: u64,
}
