package role_policy

import "modus:contract/blake3"
import "modus:contract/font_outlines"
import ilp "modus:contract/interface_language_pack"

// The choice and live object-cache fallback state machine of the script font
// set of a start (src/md/features/script_fonts.md).
//
// The plan of principal 0 names a set with its roles (Script_Fonts), or a
// content-addressed Script_Font_Pack_Manifest (root.script_fonts_manifest_hash),
// and a plan with no entry gives the set back to the boot image. Before the
// read of this start, the choice holds at once; after it, at the next start.
// When the local data disk lacks the set (or holds a stale hash, or no data
// disk exists) and principal 0 configured a pinned QUIC object-cache server
// key, the machine transitions once to Fetch_Pending -> Fetching, never
// looping on cache failure.

// Where the set of this start stands.
Script_Fonts_Stage :: enum u8 {
	Unnamed, // Neither the plan nor the boot image names a set.
	Named, // A set (or manifest) is named; its read waits until the machine is usable.
	Reading, // The delegated service reads it from the local data disk.
	Fetch_Pending, // Waiting for disk_processes to be idle before starting a QUIC object-cache fetch.
	Fetching, // The delegated service fetches it from the configured QUIC object cache.
	Mapped, // Checked: each process that starts maps it read-only.
	Absent, // The machine does not hold it, or it was refused: the box stays until the next start.
}

// What a plan did to the set.
Script_Fonts_Outcome :: enum u8 {
	Unchanged, // The plan names the set of this start already.
	Named_By_Plan, // The plan names another set, which this start reads.
	Back_To_Image, // The plan names none: this start reads the set of the boot image again.
	Unnamed_Again, // The plan names none, and the boot image names none: no set this start.
	Next_Start, // The read of this start began: the choice holds at the next start.
}

// Next asynchronous action that root takes on script_fonts_step.
Script_Fonts_Step_Action :: enum u8 {
	Wait,
	Read_Disk,
	Fetch_Cache,
	Store_Disk,
	Absent_Without_Disk,
	Absent_Without_Cache,
}

// Why a local disk read did not produce the named script font set.
Script_Fonts_Disk_Miss :: enum u8 {
	Not_On_Disk,
	Hash_Differs,
	Read_Failed,
}

// Which source named the active script font target hash.
Script_Fonts_Source_Kind :: enum u8 {
	None,
	Boot_Image,
	Plan_Entry,
	Plan_Manifest,
}

// Why resolving a Script_Font_Pack_Manifest blob was refused.
Script_Fonts_Manifest_Refusal :: enum u8 {
	None,
	Manifest_Chain_Forbidden, // A manifest referenced another manifest (max depth 1).
	Decode_Failed, // MODSFP01 wire validation failed (see decode_refusal).
	Empty_Manifest, // Manifest carries zero script entries.
	Size_Over_Limit, // Declared byte_size exceeds font_outlines.SCRIPT_FONTS_BYTES_LIMIT.
	Multiple_Distinct_Objects, // Entries name more than one distinct object hash.
	Size_Mismatch, // Entries naming the same object hash disagree on byte_size.
}

// script_fonts_plan_choice gives the set and the stage after a plan of
// principal 0 that names planned (all zero: no entry), at a stage of the
// start, with the set named now and the set that the boot image names.
script_fonts_plan_choice :: proc "contextless" (stage: Script_Fonts_Stage, named, image, planned: blake3.Hash) -> (next_stage: Script_Fonts_Stage, next_named: blake3.Hash, outcome: Script_Fonts_Outcome) {
	wanted := planned == {} ? image : planned
	if wanted == named {
		return stage, named, .Unchanged
	}
	switch stage {
	case .Unnamed, .Named:
		switch {
		case planned != {}:
			return .Named, wanted, .Named_By_Plan
		case wanted != {}:
			return .Named, wanted, .Back_To_Image
		}
		return .Unnamed, {}, .Unnamed_Again
	case .Reading, .Fetch_Pending, .Fetching, .Mapped, .Absent:
	}
	return stage, named, .Next_Start
}

// script_fonts_effective_target selects the target hash and whether it must
// decode as a MODSFP01 Script_Font_Pack_Manifest: explicit Script_Fonts plan
// entry > root.script_fonts_manifest_hash > boot image resource.
script_fonts_effective_target :: proc "contextless" (plan_entry, plan_manifest, image_named: blake3.Hash) -> (target: blake3.Hash, expect_manifest: bool, source: Script_Fonts_Source_Kind) {
	if plan_entry != {} {
		return plan_entry, false, .Plan_Entry
	}
	if plan_manifest != {} {
		return plan_manifest, true, .Plan_Manifest
	}
	if image_named != {} {
		return image_named, false, .Boot_Image
	}
	return {}, false, .None
}

// script_fonts_step_decide gives the next non-blocking action for root's
// event loop given the current stage, whether the machine is usable, whether
// disk_processes is busy, and whether a data disk, cache key, or pending
// local disk write is present.
script_fonts_step_decide :: proc "contextless" (
	stage: Script_Fonts_Stage,
	usable: bool,
	load_running: bool,
	has_data_disk: bool,
	has_cache_key: bool,
	store_pending: bool,
) -> Script_Fonts_Step_Action {
	if !usable || load_running {
		return .Wait
	}
	switch stage {
	case .Unnamed, .Reading, .Fetching, .Absent:
		return .Wait
	case .Mapped:
		if store_pending && has_data_disk {
			return .Store_Disk
		}
		return .Wait
	case .Named:
		if has_data_disk {
			return .Read_Disk
		}
		if has_cache_key {
			return .Fetch_Cache
		}
		return .Absent_Without_Disk
	case .Fetch_Pending:
		if has_cache_key {
			return .Fetch_Cache
		}
		return .Absent_Without_Cache
	}
	return .Wait
}

// script_fonts_after_disk_miss decides whether a disk read that did not
// provide the expected script font set falls back to the configured object
// cache or settles into Absent.
script_fonts_after_disk_miss :: proc "contextless" (
	stage: Script_Fonts_Stage,
	has_cache_key: bool,
	miss: Script_Fonts_Disk_Miss,
) -> (next_stage: Script_Fonts_Stage, fallback: bool) {
	if stage != .Reading {
		return stage, false
	}
	switch miss {
	case .Not_On_Disk, .Hash_Differs:
		if has_cache_key {
			return .Fetch_Pending, true
		}
		return .Absent, false
	case .Read_Failed:
		return .Absent, false
	}
	return .Absent, false
}

// script_fonts_after_cache_failure settles a failed object-cache fetch into
// Absent so the root loop never retries endlessly.
script_fonts_after_cache_failure :: proc "contextless" (stage: Script_Fonts_Stage) -> Script_Fonts_Stage {
	if stage == .Fetching {
		return .Absent
	}
	return stage
}

// script_fonts_is_manifest_bytes reports whether bytes start with the 8-byte
// MODSFP01 Script_Font_Pack_Manifest magic.
script_fonts_is_manifest_bytes :: proc "contextless" (bytes: []u8) -> bool {
	magic := ilp.SCRIPT_FONT_MANIFEST_MAGIC
	if len(bytes) < len(magic) {
		return false
	}
	for index in 0 ..< len(magic) {
		if bytes[index] != magic[index] {
			return false
		}
	}
	return true
}

// script_fonts_manifest_resolve decodes and validates a MODSFP01
// Script_Font_Pack_Manifest blob and resolves the single content-addressed
// script font set hash and byte size. Enforces max depth 1, non-empty entries,
// SCRIPT_FONTS_BYTES_LIMIT, and a single deduplicated target object hash.
script_fonts_manifest_resolve :: proc "contextless" (
	bytes: []u8,
	already_resolved: bool,
) -> (
	resolved_hash: blake3.Hash,
	resolved_size: u64,
	script_count: u32,
	decode_refusal: ilp.Pack_Manifest_Refusal,
	refusal: Script_Fonts_Manifest_Refusal,
) {
	if already_resolved {
		return {}, 0, 0, .None, .Manifest_Chain_Forbidden
	}
	manifest: ilp.Script_Font_Pack_Manifest
	if dec := ilp.script_font_manifest_decode(bytes, &manifest); dec != .None {
		return {}, 0, 0, dec, .Decode_Failed
	}
	if manifest.entry_count == 0 {
		return {}, 0, 0, .None, .Empty_Manifest
	}
	wanted_scripts: [ilp.SCRIPT_FONT_ENTRY_LIMIT]ilp.Script_Code
	for i in u32(0) ..< manifest.entry_count {
		wanted_scripts[i] = manifest.entries[i].script
	}
	collected: [2]blake3.Hash
	unique_count, collect_refusal := ilp.plan_fetch_hashes_collect(nil, nil, &manifest, wanted_scripts[:manifest.entry_count], collected[:])
	if collect_refusal == .Buffer_Too_Small || unique_count > 1 {
		return {}, 0, 0, .None, .Multiple_Distinct_Objects
	}
	if collect_refusal != .None || unique_count != 1 {
		return {}, 0, 0, collect_refusal, .Decode_Failed
	}
	expected_size := manifest.entries[0].byte_size
	if expected_size == 0 || expected_size > font_outlines.SCRIPT_FONTS_BYTES_LIMIT {
		return {}, 0, 0, .None, .Size_Over_Limit
	}
	for i in u32(1) ..< manifest.entry_count {
		if manifest.entries[i].byte_size != expected_size {
			return {}, 0, 0, .None, .Size_Mismatch
		}
	}
	return collected[0], expected_size, manifest.entry_count, .None, .None
}
