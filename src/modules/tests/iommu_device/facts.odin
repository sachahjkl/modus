package iommu_device_service

import "modus:contract/value_kinds"

// The log facts of the test device service of the IOMMU
// (src/md/features/log_facts.md): each line, as a record of fields. Each
// fact template is the sentence that the line wrote before it was a fact,
// so the waits of the machine test read them as before.
//
// The cause of a failure comes from a closed set of sentences, each a
// literal at a call of fail: one fact type keeps each failure, and its
// Text field holds the words of the cause, as the cause of a silent disk
// of the storage service. A Text field is the last field, and is [N]u8
// with N written out, as the tool reads it.

// The bytes of the Text field of the cause of a failure: the longest,
// "without the registers of the other device behind the conventional
// bridge, a declaration was not refused", has 103 bytes, and a zero byte.
CAUSE_FIELD_BYTES :: 104

// A step of the test failed: the service stops with Failed.
@(log_fact = "iommu_device: {cause}")
Failed :: struct {
	cause: [104]u8,
}

// A block went from a declared page to another declared page.
@(log_fact = "iommu_device: a block written from a declared page and read into another declared page: the 4096 bytes arrived: as it must")
Block_Arrived :: struct {}

// The message interrupt of the device arrived through its entry.
@(log_fact = "iommu_device: the message interrupt of the device arrived through its entry: as it must")
Interrupt_Arrived :: struct {}

// A read into the interrupt addresses went to no entry of this device.
@(log_fact = "iommu_device: a read into the interrupt addresses, to entries that the kernel did not give this device: the device gave the request back: as it must")
Interrupt_Addresses_Refused :: struct {}

// The device wrote a page that this service did not declare: the machine
// has no IOMMU.
@(log_fact = "iommu_device: a read into a page that was not declared: the device wrote the page: no IOMMU keeps the device in the memory of its service on this machine")
Undeclared_Page_Written :: struct {}

// The device needs a reset after a read into a page that this service did
// not declare, and the page kept its bytes.
@(log_fact = "iommu_device: a read into a page that was not declared: the device needs a reset, and the page keeps its 4096 bytes: as it must")
Undeclared_Read_Needs_Reset :: struct {}

// The device gave back a read into a page that this service did not
// declare, and the page kept its bytes. The status is the byte that the
// device wrote in the request: a word of the device, which keeps its
// number.
@(log_fact = "iommu_device: a read into a page that was not declared: the device gave the request back with the status {device_status}, and the page keeps its 4096 bytes: as it must")
Undeclared_Read_Given_Back :: struct {
	device_status: u64,
}

// The device did not end a read into a page that this service did not
// declare within the hang bound.
@(log_fact = "iommu_device: a read into a page that was not declared: the device did not end the request before the hang bound")
Undeclared_Read_Silent :: struct {}

// A declaration is refused while the service lacks the registers of the
// other device behind the conventional bridge.
@(log_fact = "iommu_device: without the registers of the other device behind the conventional bridge, a declaration is refused: as it must")
Declaration_Refused_Behind_Bridge :: struct {}

// The service waits for the new size of the disk after the end of the
// domain of the device.
@(log_fact = "iommu_device: a read given to the device after the end of its domain: the service waits for the new size of the disk")
Read_After_Domain_End :: struct {}

// After the end of its domain, the device reaches no page and sends no
// interrupt.
@(log_fact = "iommu_device: after the end of its domain, a read of the device into a page that this service declared before does not end, the page keeps its 4096 bytes, and no interrupt of the device arrives, also for its new size: as it must")
Domain_Ended :: struct {}

#assert(size_of(Failed) == CAUSE_FIELD_BYTES)

// cause_field gives the Text field of the cause of a failure.
cause_field :: proc "contextless" (cause: string) -> [CAUSE_FIELD_BYTES]u8 {
	return value_kinds.text_field(cause, CAUSE_FIELD_BYTES)
}
