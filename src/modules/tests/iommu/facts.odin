package iommu_client

import "modus:contract/call_outcome"

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

// The test device service answered Info with another outcome than
// Succeeded. The outcome is the kind word of the answer of the block
// service, carried as it is: a reader writes the name of its member, or its
// number when it names none.
@(log_fact = "iommu: the test device service gave the outcome {outcome} to Info")
Info_Refused :: struct {
	outcome: call_outcome.Call_Outcome_Word,
}

// The test device service did not answer within the hang bound.
@(log_fact = "iommu: the test device service did not answer before the hang bound")
Device_Service_Silent :: struct {}
