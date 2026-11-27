package root

import "modus:contract/call_outcome"
import "modus:contract/value_kinds"

// The facts of the script font set of the machine (script_fonts.odin).

@(log_fact = "root: no plan and no resource of the boot image names a script font set: Hebrew, Arabic, the ideographs and the emoji draw the replacement glyph")
Script_Fonts_Unnamed :: struct {}

@(log_fact = "root: the resource script_fonts_name holds {name_bytes}, not one hash of 32 bytes: it names no script font set")
Script_Fonts_Name_Refused :: struct {
	name_bytes: value_kinds.Size_In_Bytes,
}

@(log_fact = "root: the boot image names the script font set {hash}")
Script_Fonts_Named_By_Image :: struct {
	hash: value_kinds.Hash_Field,
}

@(log_fact = "root: the plan of principal 0 names the script font set {hash}")
Script_Fonts_Named_By_Plan :: struct {
	hash: value_kinds.Hash_Field,
}

@(log_fact = "root: the plan of principal 0 names no script font set: the set {hash} of the boot image is the set of this start again")
Script_Fonts_Back_To_Image :: struct {
	hash: value_kinds.Hash_Field,
}

@(log_fact = "root: the plan of principal 0 names no script font set: the set {hash} of the boot image holds at the next start of the machine")
Script_Fonts_Back_To_Image_Next_Start :: struct {
	hash: value_kinds.Hash_Field,
}

@(log_fact = "root: the plan of principal 0 names the script font set {hash}: it holds at the next start of the machine")
Script_Fonts_Next_Start :: struct {
	hash: value_kinds.Hash_Field,
}

@(log_fact = "root: the machine has no data disk, so it holds no script font set: Hebrew, Arabic, the ideographs and the emoji draw the replacement glyph")
Script_Fonts_Without_Data_Disk :: struct {}

@(log_fact = "root: reads the script font set {hash} from the store script_fonts of the machine")
Script_Fonts_Reading :: struct {
	hash: value_kinds.Hash_Field,
}

@(log_fact = "root: the script font set {hash} ({set_size}, {fonts} fonts) is checked: each process that starts from now maps it, read-only")
Script_Fonts_Mapped :: struct {
	hash:     value_kinds.Hash_Field,
	set_size: value_kinds.Size_In_Bytes,
	fonts:    u64,
}

@(log_fact = "root: the script font set is refused: {problem}, value {problem_value}: Hebrew, Arabic, the ideographs and the emoji draw the replacement glyph until the next start")
Script_Fonts_Refused_Form :: struct {
	problem_value: u64,
	problem:       [80]u8,
}

@(log_fact = "root: the data disk holds no script font set {hash}: Hebrew, Arabic, the ideographs and the emoji draw the replacement glyph")
Script_Fonts_Not_On_Disk :: struct {
	hash: value_kinds.Hash_Field,
}

@(log_fact = "root: refused the script font set: the object has {object_bytes} bytes, and a script font set has at most {set_bytes_limit}")
Script_Fonts_Refused_Too_Large :: struct {
	object_bytes:    u64,
	set_bytes_limit: u64,
}

@(log_fact = "root: the script font set was not read: {outcome}: Hebrew, Arabic, the ideographs and the emoji draw the replacement glyph until the next start")
Script_Fonts_Not_Read :: struct {
	outcome: call_outcome.Call_Outcome,
}

@(log_fact = "root: the plan of principal 0 names the script font manifest {hash}")
Script_Fonts_Manifest_Named_By_Plan :: struct {
	hash: value_kinds.Hash_Field,
}

@(log_fact = "root: the data disk lacks the script font set {hash}: fetching it from the configured object cache")
Script_Fonts_Cache_Fallback :: struct {
	hash: value_kinds.Hash_Field,
}

@(log_fact = "root: fetches the script font set {hash} from the object cache")
Script_Fonts_Fetching :: struct {
	hash: value_kinds.Hash_Field,
}

@(log_fact = "root: the script font manifest {manifest_hash} names the script font set {set_hash} ({set_size}, {scripts} scripts)")
Script_Fonts_Manifest_Resolved :: struct {
	manifest_hash: value_kinds.Hash_Field,
	set_hash:      value_kinds.Hash_Field,
	set_size:      value_kinds.Size_In_Bytes,
	scripts:       u64,
}

@(log_fact = "root: the script font manifest is refused: refusal {refusal}, decode {decode_refusal}: Hebrew, Arabic, the ideographs and the emoji draw the replacement glyph until the next start")
Script_Fonts_Refused_Manifest :: struct {
	refusal:        u64,
	decode_refusal: u64,
}

@(log_fact = "root: the script font set has {got_size}, and its manifest names {expected_size}: Hebrew, Arabic, the ideographs and the emoji draw the replacement glyph until the next start")
Script_Fonts_Refused_Manifest_Size :: struct {
	got_size:      value_kinds.Size_In_Bytes,
	expected_size: value_kinds.Size_In_Bytes,
}

@(log_fact = "root: the object cache did not provide the script font set: refusal {refusal}: Hebrew, Arabic, the ideographs and the emoji draw the replacement glyph until the next start")
Script_Fonts_Cache_Refused :: struct {
	refusal: u64,
}

@(log_fact = "root: cached the script font set {hash} ({set_size}) on the data disk")
Script_Fonts_Cached_On_Disk :: struct {
	hash:     value_kinds.Hash_Field,
	set_size: value_kinds.Size_In_Bytes,
}

@(log_fact = "root: the fetched script font set stays in memory: writing it to the data disk did not finish ({outcome})")
Script_Fonts_Not_Cached_On_Disk :: struct {
	outcome: call_outcome.Call_Outcome,
}
