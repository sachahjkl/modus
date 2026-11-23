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

// The store "out" refused a way out of its root: the kind of its error
// record, and what the builder tried.
@(log_fact = "builder_probe: the store out refused {what}: the error kind {kind}")
Above_Out_Refused :: struct {
	kind: i64,
	what: value_kinds.Text_View,
}

// The store "out" took a way out of its root: the sandbox did not hold.
@(log_fact = "builder_probe: WRONG: the store out took {what}")
Above_Out_Taken :: struct {
	what: value_kinds.Text_View,
}

// The store "out" refused each share that the builder asked: their count,
// and the kind of the error record of the last one.
@(log_fact = "builder_probe: the store out refused {count} shares: the error kind {kind}")
Shares_Refused :: struct {
	count: u64,
	kind:  i64,
}

// The store "out" made a share: a builder could hold the shares of the service.
@(log_fact = "builder_probe: WRONG: the store out made a share")
Share_Made :: struct {}

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
