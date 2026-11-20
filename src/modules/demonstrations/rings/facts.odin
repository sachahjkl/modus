package rings

import "modus:contract/value_kinds"

// The log facts of rings (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero.

// The context of the process holds no random seed.
@(log_fact = "rings: no random seed in the context")
No_Random_Seed :: struct {}

// The bytes of the Text field of the cause of a stop at the start: the
// longest, "no grant to read the boot image", has 31 bytes.
CAUSE_FIELD_BYTES :: 32

// The process stops at its start, for a cause that it names.
@(log_fact = "rings: {cause}")
Start_Failed :: struct {
	cause: [32]u8,
}

// A key stopped a node.
@(log_fact = "rings: node {node} stopped")
Node_Stopped :: struct {
	node: u64,
}

// A key started a node again.
@(log_fact = "rings: node {node} started")
Node_Started :: struct {
	node: u64,
}

// The nodes run, each with its ring, and the first records go round.
@(log_fact = "rings: ok, {processes} processes, {rings} rings, {records} records")
Nodes_Running :: struct {
	processes: u64,
	rings:     u64,
	records:   u64,
}

// The key a added a record.
@(log_fact = "rings: the key a adds a record: {records} records in all")
Record_Added :: struct {
	records: u64,
}

// The kernel stopped a node, not a key.
@(log_fact = "rings: node {node} stopped alone")
Node_Stopped_Alone :: struct {
	node: u64,
}

// Every record waits in the ring before a stopped node.
@(log_fact = "rings: node {node} does not run: {records} records wait in the ring before it")
Records_Wait_Before_Node :: struct {
	node:    u64,
	records: u64,
}

#assert(size_of(Start_Failed) == CAUSE_FIELD_BYTES)

// cause_field gives the Text field of the cause of a stop at the start.
cause_field :: proc "contextless" (cause: string) -> [CAUSE_FIELD_BYTES]u8 {
	return value_kinds.text_field(cause, CAUSE_FIELD_BYTES)
}
