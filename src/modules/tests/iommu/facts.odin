package iommu_client

// The log facts of the client of the test device service of the IOMMU
// (src/md/features/log_facts.md): each line, as a record of fields. Each
// fact template is the sentence that the line wrote before it was a fact,
// so the waits of the machine test read them as before.

// The context holds no ring to the block service.
@(log_fact = "iommu: no block ring")
No_Block_Ring :: struct {}

// The ring to the block service has no room for the first request.
@(log_fact = "iommu: the block ring has no room")
Block_Ring_Full :: struct {}

// The test device service answered after its read into a page that it did
// not declare.
@(log_fact = "iommu: the test device service answered after its read into a page that was not declared: the machine goes on: as it must")
Machine_Goes_On :: struct {}

// The test device service answered Info with another status than Ok. The
// status is the kind word of the answer of the block service: block.Status
// is no contract enum that a field can name, so the field keeps its
// number, as the line wrote it.
@(log_fact = "iommu: the test device service gave the status {block_status} to Info")
Info_Refused :: struct {
	block_status: u64,
}

// The test device service did not answer within the hang bound.
@(log_fact = "iommu: the test device service did not answer before the hang bound")
Device_Service_Silent :: struct {}
