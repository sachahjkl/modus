package visitor

import "modus:contract/call_outcome"
import "modus:contract/storage_status"

// The log facts of the disk process visitor (src/md/features/log_facts.md):
// each line, as a record of fields. Each fact template is the sentence
// that the line wrote before it was a fact, so a wait of a machine test on
// that sentence reads it as before; a status of the kernel or of the
// storage service that the line wrote as its number is now the name of its
// member. They are in a file of their own: the machine test of the disk
// processes names lines of main.odin, which must not move, so main.odin
// takes no new import and converts a status with storage_status_word.

// storage_status_word gives the word of a status of the storage service,
// for a field of a fact.
storage_status_word :: proc "contextless" (status: storage_status.Status) -> storage_status.Status_Word {
	return storage_status.Status_Word(status)
}
//
// The copies of this module that the test builds outside the sources
// (outsider, outsider_fault) write these facts with their own module hash:
// the machine of that test renders them with those module files.
//
// The lines that only a copy writes stay text: the line of a build
// outside the sources, and the two lines of the fault. Their calls are in
// a branch of `when` that the build of the system does not compile, and
// the build refuses a fact type of the package of a module whose key the
// code of the module does not hold.

// The process runs from the disk.
@(log_fact = "visitor: ok, a module that the boot image does not hold")
Running :: struct {}

// The context holds the grants of a disk process with the grant store.
@(log_fact = "visitor: the context holds the log, a window, the budget and a store, and no other handle of a grant: as it must")
Context_With_Store :: struct {}

// The context holds the grants of a disk process with no grant.
@(log_fact = "visitor: the context holds the log, a window and the budget, and no handle of a grant: as it must")
Context_Without_Grant :: struct {}

// The context holds handles of a grant: a disk process with no grant
// receives none.
@(log_fact = "visitor: the context holds {grant_handles} handles of a grant: WRONG")
Wrong_Grant_Handles :: struct {
	grant_handles: u64,
}

// The open of the handle of a ring to the root service is refused.
@(log_fact = "visitor: no ring to the root service: the open of its handle is refused: as it must")
Root_Ring_Refused :: struct {}

// A ring to the root service opened, or its open gave another status.
@(log_fact = "visitor: a ring to the root service opens with status {status}: WRONG")
Wrong_Root_Ring :: struct {
	status: call_outcome.Call_Outcome,
}

// The store did not give the count of the visits.
@(log_fact = "visitor: the store did not give the count: status {status}: WRONG")
Wrong_Count_Not_Read :: struct {
	status: storage_status.Status_Word,
}

// The count of the visits in the store is not 8 bytes.
@(log_fact = "visitor: the count in the store has {count_bytes} bytes, not 8: WRONG")
Wrong_Count_Size :: struct {
	count_bytes: u64,
}

// The store did not keep the new count.
@(log_fact = "visitor: the store did not keep the count: status {status}: WRONG")
Wrong_Count_Not_Kept :: struct {
	status: storage_status.Status_Word,
}

// The count read again is not the count written.
@(log_fact = "visitor: the count read again is not the count written: WRONG")
Wrong_Count_Read_Again :: struct {}

// The store of the nickname holds the new count of the visits, read again.
@(log_fact = "visitor: the store of its nickname holds the visit {visit}, read again: as it must")
Visit_Read_Again :: struct {
	visit: u64,
}
