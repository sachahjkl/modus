package c_builder

import "modus:contract/value_kinds"

// Log facts emitted by the C builder module.

@(log_fact = "c_builder: built {path} into module of {size}")
C_Module_Built :: struct {
	size: value_kinds.Size_In_Bytes,
	path: value_kinds.Text_View,
}

@(log_fact = "c_builder: step {step} failed with error kind {error_kind}, value {error_value}")
C_Builder_Failed :: struct {
	step:        u64,
	error_kind:  i64,
	error_value: i64,
}
