package builder_probe

import "modus:contract/value_kinds"

// The log facts of the test builder builder_probe
// (src/md/features/log_facts.md). A text view is the last field.

// The builder read an input from its input store.
@(log_fact = "builder_probe: read the input {name} from the input store: {size} bytes")
Input_Read :: struct {
	size: u64,
	name: value_kinds.Text_View,
}

// The input store refused a write, as it reads only: the kind of its error
// record (errors.Kind).
@(log_fact = "builder_probe: the input store refused a write: the error kind {kind}")
Input_Write_Refused :: struct {
	kind: i64,
}

// The input store took a write: the sandbox did not hold.
@(log_fact = "builder_probe: WRONG: the input store took a write")
Input_Write_Taken :: struct {}

// The store "out" refused a name above its root: the kind of its error record.
@(log_fact = "builder_probe: the store out refused a name above its root: the error kind {kind}")
Above_Out_Refused :: struct {
	kind: i64,
}

// The builder holds no handle past its context: none of the network, of
// the root ring, of a store of its own, of the boot image.
@(log_fact = "builder_probe: no handle past the context of a builder: the slots {first} to {last} are empty")
No_Other_Handle :: struct {
	first: u64,
	last:  u64,
}

// A slot past the context of a builder holds a handle: the sandbox did not hold.
@(log_fact = "builder_probe: WRONG: the slot {slot} holds a handle")
Other_Handle :: struct {
	slot: u64,
}

// The argument act names no act of the builder.
@(log_fact = "builder_probe: the argument act names no act")
Unknown_Act :: struct {}
