package root

// The script font set of the machine (src/md/features/script_fonts.md):
// the fonts of Hebrew, Arabic, Thai, Devanagari, the ideographs, the emoji
// and the geometric shapes, which the boot image does not hold. The plan of
// principal 0 names the set by its hash (the entry Script_Fonts), or names a
// content-addressed Script_Font_Pack_Manifest (root.script_fonts_manifest_hash);
// with neither, the resource script_fonts_name of the boot image names it.
// When the machine is usable, this service reads the set once, through the
// delegated service disk_processes, from the object script_fonts of the
// store script_fonts of the machine. When the disk lacks the set (or holds
// another hash, or no data disk is present) and principal 0 configured
// root.script_fonts_cache_key, this service fetches the object over QUIC from
// the configured object cache through disk_processes, checks the BLAKE3 hash
// on its own mapping after loan end, resolves one MODSFP01 manifest hop if
// named, validates font_outlines, maps the set read-only at Script_Fonts, and
// persists the verified bytes asynchronously to the local script_fonts store
// when a data disk is present.

import "internal:root/role_policy"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/font_outlines"
import rd "modus:contract/root_delegation"
import "modus:contract/value_kinds"
import "modus:system"

// Where the set of this start stands (role_policy.Script_Fonts_Stage).
Script_Fonts_Stage :: role_policy.Script_Fonts_Stage

script_fonts_stage: Script_Fonts_Stage
// The active target hash of this start (a font_outlines set or a MODSFP01
// Script_Font_Pack_Manifest before resolution).
script_fonts_named: blake3.Hash
// The set that the boot image names: a plan with no entry gives it back.
script_fonts_image_named: blake3.Hash
// The explicit Script_Fonts entry from principal 0's role plan, if any.
script_fonts_plan_entry: blake3.Hash
// True when script_fonts_named came from root.script_fonts_manifest_hash and
// must decode as a MODSFP01 Script_Font_Pack_Manifest.
script_fonts_expect_manifest: bool
// True after one MODSFP01 manifest has resolved to its target set hash:
// enforces maximum indirection depth 1.
script_fonts_manifest_resolved: bool
// Exact byte size declared by a resolved manifest (0 when not from manifest).
script_fonts_expected_size: u64
// The room of the records of the font outlines and of the set, which this
// service checks one at a time: any count that the format allows.
font_records_room: font_outlines.Record_Room
// The memory of the set, which this service made, checked and keeps, its
// exact unpadded byte count, and the mapping that each process receives.
script_fonts_memory: system.Handle
script_fonts_bytes: []u8
script_fonts_size: u64
script_fonts_mapping: system.Mapping
// True after a cache fetch succeeds on a machine with a data disk, until
// disk_processes finishes persisting the verified bytes to script_fonts.
script_fonts_store_pending: bool

// script_fonts_cache_key returns principal 0's pinned QUIC object-cache server
// public key from root_plan_in_force (all zero when unset).
@(private = "file")
script_fonts_cache_key :: proc "contextless" () -> [32]u8 {
	return root_plan_in_force.script_fonts_cache_key
}

// script_fonts_has_cache_key says whether principal 0 configured a non-zero
// pinned object-cache server public key.
@(private = "file")
script_fonts_has_cache_key :: proc "contextless" () -> bool {
	return script_fonts_cache_key() != {}
}

// script_fonts_name_read reads the name of the set that the boot image
// gives: the 32 bytes of the resource script_fonts_name. The hash of the
// image was checked with the whole image (trust_check).
script_fonts_name_read :: proc "contextless" () {
	entry := system.image_resource_find(image, font_outlines.SCRIPT_FONTS_NAME_RESOURCE)
	if entry == nil {
		system.log_fact(.Info, Script_Fonts_Unnamed{})
		return
	}
	if entry.size != size_of(blake3.Hash) {
		system.log_fact(.Warning, Script_Fonts_Name_Refused{name_bytes = value_kinds.Size_In_Bytes(entry.size)})
		return
	}
	named: blake3.Hash
	copy(named[:], image[entry.offset:][:size_of(blake3.Hash)])
	if named == {} {
		system.log_fact(.Warning, Script_Fonts_Name_Refused{name_bytes = value_kinds.Size_In_Bytes(entry.size)})
		return
	}
	script_fonts_named = named
	script_fonts_image_named = named
	script_fonts_stage = .Named
	system.log_fact(.Info, Script_Fonts_Named_By_Image{hash = value_kinds.Hash_Field(named)})
}

// script_fonts_planned takes the set that the plan of principal 0 names,
// with its roles: all zero for none, which gives the set back to the plan
// manifest hash or the boot image. Before the read of this start, the plan
// names the set of this start; after it, the next start
// (role_policy.script_fonts_plan_choice).
script_fonts_planned :: proc "contextless" (planned: blake3.Hash) {
	script_fonts_plan_entry = planned
	fallback_target := root_plan_in_force.script_fonts_manifest_hash != {} ? root_plan_in_force.script_fonts_manifest_hash : script_fonts_image_named
	stage, named, outcome := role_policy.script_fonts_plan_choice(script_fonts_stage, script_fonts_named, fallback_target, planned)
	script_fonts_stage, script_fonts_named = stage, named
	if outcome == .Named_By_Plan || outcome == .Back_To_Image || outcome == .Unnamed_Again {
		script_fonts_expect_manifest = planned == {} && root_plan_in_force.script_fonts_manifest_hash != {}
		script_fonts_manifest_resolved = false
		script_fonts_expected_size = 0
	}
	switch outcome {
	case .Unchanged:
	case .Named_By_Plan:
		system.log_fact(.Info, Script_Fonts_Named_By_Plan{hash = value_kinds.Hash_Field(named)})
	case .Back_To_Image:
		if script_fonts_expect_manifest {
			system.log_fact(.Info, Script_Fonts_Manifest_Named_By_Plan{hash = value_kinds.Hash_Field(named)})
		} else {
			system.log_fact(.Info, Script_Fonts_Back_To_Image{hash = value_kinds.Hash_Field(named)})
		}
	case .Unnamed_Again:
		system.log_fact(.Info, Script_Fonts_Unnamed{})
	case .Next_Start:
		if planned == {} {
			system.log_fact(.Info, Script_Fonts_Back_To_Image_Next_Start{hash = value_kinds.Hash_Field(fallback_target)})
		} else {
			system.log_fact(.Info, Script_Fonts_Next_Start{hash = value_kinds.Hash_Field(planned)})
		}
	}
}

// script_fonts_plan_values_changed applies root.script_fonts_manifest_hash
// from root_plan_in_force when no read has begun yet on this start.
script_fonts_plan_values_changed :: proc "contextless" () {
	if script_fonts_stage != .Unnamed && script_fonts_stage != .Named {
		return
	}
	if script_fonts_manifest_resolved {
		return
	}
	target, expect_manifest, source := role_policy.script_fonts_effective_target(
		script_fonts_plan_entry,
		root_plan_in_force.script_fonts_manifest_hash,
		script_fonts_image_named,
	)
	if target == script_fonts_named && expect_manifest == script_fonts_expect_manifest {
		return
	}
	script_fonts_named = target
	script_fonts_expect_manifest = expect_manifest
	script_fonts_expected_size = 0
	if target == {} {
		script_fonts_stage = .Unnamed
		system.log_fact(.Info, Script_Fonts_Unnamed{})
		return
	}
	script_fonts_stage = .Named
	switch source {
	case .None:
	case .Boot_Image:
		system.log_fact(.Info, Script_Fonts_Back_To_Image{hash = value_kinds.Hash_Field(target)})
	case .Plan_Entry:
		system.log_fact(.Info, Script_Fonts_Named_By_Plan{hash = value_kinds.Hash_Field(target)})
	case .Plan_Manifest:
		system.log_fact(.Info, Script_Fonts_Manifest_Named_By_Plan{hash = value_kinds.Hash_Field(target)})
	}
}

// script_fonts_step advances the non-blocking script font loader state
// machine once the machine is usable and disk_processes is idle.
script_fonts_step :: proc "contextless" () {
	has_disk := .Data_Disk in machine_parts
	has_cache := script_fonts_has_cache_key()
	action := role_policy.script_fonts_step_decide(
		script_fonts_stage,
		start_policy_stage == .Usable,
		disk_load_running(),
		has_disk,
		has_cache,
		script_fonts_store_pending,
	)
	switch action {
	case .Wait:
		return
	case .Absent_Without_Disk:
		script_fonts_stage = .Absent
		system.log_fact(.Info, Script_Fonts_Without_Data_Disk{})
	case .Absent_Without_Cache:
		script_fonts_stage = .Absent
		system.log_fact(.Info, Script_Fonts_Not_On_Disk{hash = value_kinds.Hash_Field(script_fonts_named)})
	case .Read_Disk:
		refusal: [7]u64
		failure, outcome := disk_load_begin(nil, 0, font_outlines.SCRIPT_FONTS_OBJECT_NAME, script_fonts_named, 0, false, &refusal, .Script_Fonts)
		if failure != .None {
			script_fonts_stage = .Absent
			system.log_fact(.Warning, Script_Fonts_Not_Read{outcome = outcome})
			return
		}
		script_fonts_stage = .Reading
		system.log_fact(.Info, Script_Fonts_Reading{hash = value_kinds.Hash_Field(script_fonts_named)})
	case .Fetch_Cache:
		refusal: [7]u64
		failure, outcome := disk_load_cache_begin(font_outlines.SCRIPT_FONTS_OBJECT_NAME, script_fonts_named, script_fonts_cache_key(), &refusal)
		if failure != .None {
			script_fonts_stage = .Absent
			system.log_fact(.Warning, Script_Fonts_Not_Read{outcome = outcome})
			return
		}
		script_fonts_stage = .Fetching
		system.log_fact(.Info, Script_Fonts_Fetching{hash = value_kinds.Hash_Field(script_fonts_named)})
	case .Store_Disk:
		if script_fonts_memory == 0 || script_fonts_size == 0 {
			script_fonts_store_pending = false
			return
		}
		refusal: [7]u64
		failure, outcome := disk_load_store_begin(font_outlines.SCRIPT_FONTS_OBJECT_NAME, script_fonts_named, script_fonts_memory, script_fonts_size, &refusal)
		if failure != .None {
			script_fonts_store_pending = false
			system.log_fact(.Warning, Script_Fonts_Not_Cached_On_Disk{outcome = outcome})
		}
	}
}

// script_fonts_take keeps the bytes of a load whose hash this service
// checked on its own mapping, after the end of the loan: either a MODSFP01
// Script_Font_Pack_Manifest (resolved once to its target font_outlines hash)
// or the font_outlines set itself. Its form is checked here, once; each
// process validates its header again at its open.
script_fonts_take :: proc "contextless" (file: ^Lent_File, from_cache: bool) {
	bytes := file.bytes[:file.size]
	if script_fonts_expect_manifest || role_policy.script_fonts_is_manifest_bytes(bytes) {
		manifest_hash := script_fonts_named
		resolved_hash, resolved_size, script_count, decode_refusal, refusal := role_policy.script_fonts_manifest_resolve(bytes, script_fonts_manifest_resolved)
		if refusal != .None {
			script_fonts_stage = .Absent
			system.log_fact(.Warning, Script_Fonts_Refused_Manifest{refusal = u64(refusal), decode_refusal = u64(decode_refusal)})
			return
		}
		script_fonts_named = resolved_hash
		script_fonts_expected_size = resolved_size
		script_fonts_expect_manifest = false
		script_fonts_manifest_resolved = true
		script_fonts_stage = .Named
		system.log_fact(.Info, Script_Fonts_Manifest_Resolved{
			manifest_hash = value_kinds.Hash_Field(manifest_hash),
			set_hash      = value_kinds.Hash_Field(resolved_hash),
			set_size      = value_kinds.Size_In_Bytes(resolved_size),
			scripts       = u64(script_count),
		})
		return
	}
	if script_fonts_expected_size != 0 && u64(len(bytes)) != script_fonts_expected_size {
		script_fonts_stage = .Absent
		system.log_fact(.Warning, Script_Fonts_Refused_Manifest_Size{
			got_size      = value_kinds.Size_In_Bytes(len(bytes)),
			expected_size = value_kinds.Size_In_Bytes(script_fonts_expected_size),
		})
		return
	}
	outlines, problem := font_outlines.validate(bytes, font_records_room[:])
	if problem.kind != .None {
		script_fonts_stage = .Absent
		system.log_fact(.Warning, Script_Fonts_Refused_Form{problem_value = problem.value, problem = text_field(font_outlines.problem_sentences[problem.kind], 80)})
		return
	}
	script_fonts_memory, script_fonts_bytes = file.memory, file.bytes
	script_fonts_size = file.size
	file^ = {}
	pages := u64(len(script_fonts_bytes)) / system.PAGE_SIZE
	script_fonts_mapping = {memory = script_fonts_memory, address = font_outlines.SCRIPT_FONTS_ADDRESS, first = 0, page_count = pages}
	script_fonts_stage = .Mapped
	script_fonts_store_pending = from_cache && (.Data_Disk in machine_parts)
	system.log_fact(.Info, Script_Fonts_Mapped{hash = value_kinds.Hash_Field(script_fonts_named), set_size = value_kinds.Size_In_Bytes(len(bytes)), fonts = u64(outlines.count)})
}

// script_fonts_not_on_disk takes a data disk that holds no set: falls back
// to the configured object cache when principal 0 pinned a server key, else
// leaves the replacement glyph.
script_fonts_not_on_disk :: proc "contextless" () {
	next_stage, fallback := role_policy.script_fonts_after_disk_miss(script_fonts_stage, script_fonts_has_cache_key(), .Not_On_Disk)
	if next_stage == script_fonts_stage {
		return
	}
	script_fonts_stage = next_stage
	if fallback {
		system.log_fact(.Info, Script_Fonts_Cache_Fallback{hash = value_kinds.Hash_Field(script_fonts_named)})
	} else {
		system.log_fact(.Info, Script_Fonts_Not_On_Disk{hash = value_kinds.Hash_Field(script_fonts_named)})
	}
}

// script_fonts_disk_hash_differs handles a local script_fonts object whose
// BLAKE3 hash differs from script_fonts_named: falls back to the configured
// object cache when principal 0 pinned a server key, else leaves existing
// refusal handling to script_fonts_load_ended.
script_fonts_disk_hash_differs :: proc "contextless" () {
	next_stage, fallback := role_policy.script_fonts_after_disk_miss(script_fonts_stage, script_fonts_has_cache_key(), .Hash_Differs)
	if fallback {
		script_fonts_stage = next_stage
		system.log_fact(.Info, Script_Fonts_Cache_Fallback{hash = value_kinds.Hash_Field(script_fonts_named)})
	}
}

// script_fonts_cache_refused settles a refused object-cache fetch into
// Absent and records the closed Disk_Load_Refusal code.
script_fonts_cache_refused :: proc "contextless" (refusal: rd.Disk_Load_Refusal) {
	if script_fonts_stage != .Fetching {
		return
	}
	script_fonts_stage = role_policy.script_fonts_after_cache_failure(script_fonts_stage)
	system.log_fact(.Warning, Script_Fonts_Cache_Refused{refusal = u64(refusal)})
}

// script_fonts_store_finished records the end of the asynchronous write of a
// cache-fetched script font set into the machine's local script_fonts store.
script_fonts_store_finished :: proc "contextless" (ok: bool, outcome: call_outcome.Call_Outcome) {
	if !script_fonts_store_pending {
		return
	}
	script_fonts_store_pending = false
	if ok {
		system.log_fact(.Info, Script_Fonts_Cached_On_Disk{
			hash     = value_kinds.Hash_Field(script_fonts_named),
			set_size = value_kinds.Size_In_Bytes(script_fonts_size),
		})
	} else {
		system.log_fact(.Warning, Script_Fonts_Not_Cached_On_Disk{outcome = outcome})
	}
}

// script_fonts_load_ended takes the end of a load of the set that did not
// already settle its stage: its cause has its own line before this one.
script_fonts_load_ended :: proc "contextless" (kind: rd.Load_Kind, outcome: call_outcome.Call_Outcome) {
	switch kind {
	case .None, .Module:
		return
	case .Script_Fonts:
		if script_fonts_stage != .Reading {
			return
		}
		script_fonts_stage = .Absent
		system.log_fact(.Warning, Script_Fonts_Not_Read{outcome = outcome})
	case .Script_Fonts_Cache:
		if script_fonts_stage != .Fetching {
			return
		}
		script_fonts_stage = role_policy.script_fonts_after_cache_failure(script_fonts_stage)
		system.log_fact(.Warning, Script_Fonts_Not_Read{outcome = outcome})
	case .Script_Fonts_Store:
		script_fonts_store_finished(false, outcome)
	}
}

// script_fonts_give adds the set, read-only, to the mappings of a process
// that gets the font outlines, and sets the bit of its range.
script_fonts_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^system.Context_Values) {
	if script_fonts_stage != .Mapped {
		return
	}
	if count^ + 1 > len(mappings) {
		mapping_dropped_log("the script font set", len(mappings))
		return
	}
	mappings[count^] = script_fonts_mapping
	mappings[count^].flags = {}
	count^ += 1
	system.range_mapped_put(values, .Script_Fonts)
}
