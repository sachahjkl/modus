package bootstrap_probe

import "modus:contract/value_kinds"

// Log facts emitted by the live QEMU bootstrap verification probe
// (src/md/features/bootstrap.md).

@(log_fact = "bootstrap_probe: WRONG: {what} (got {got}, expected {expected})")
Wrong :: struct {
	got:      u64,
	expected: u64,
	what:     value_kinds.Text_View,
}

@(log_fact = "bootstrap_probe: refusals checked")
Refusals_Checked :: struct {}

@(log_fact = "bootstrap_probe: chibicc stage {stage} assembled: {size} bytes, hash {hash}")
Chibicc_Stage_Built :: struct {
	stage: u64,
	size:  u64,
	hash:  value_kinds.Hash_Field,
}

@(log_fact = "bootstrap_probe: chibicc self-host fixed point verified across {units} units: {size} bytes, hash {hash}")
Chibicc_Self_Host_Verified :: struct {
	units: u64,
	size:  u64,
	hash:  value_kinds.Hash_Field,
}

@(log_fact = "bootstrap_probe: sqlite {version} verified (sum={sum}, rows={rows}), module hash {module_hash}")
Sqlite_Verified :: struct {
	version:     u64,
	sum:         u64,
	rows:        u64,
	module_hash: value_kinds.Hash_Field,
}

@(log_fact = "bootstrap_probe: lua 5.4.7 verified ({output_bytes} bytes, zero leaked heap), module hash {module_hash}")
Lua_Verified :: struct {
	output_bytes: u64,
	module_hash:  value_kinds.Hash_Field,
}

@(log_fact = "bootstrap_probe: zstd {version} verified ({compressed_bytes} compressed bytes, frame hash {frame_hash}), module hash {module_hash}")
Zstd_Verified :: struct {
	version:          u64,
	compressed_bytes: u64,
	frame_hash:       value_kinds.Hash_Field,
	module_hash:      value_kinds.Hash_Field,
}

@(log_fact = "bootstrap_probe: ok, live chibicc self-host and C libraries verified")
Probe_Passed :: struct {}
