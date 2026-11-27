// QMP machine snapshot command builders, reply parser, and save/restore helpers
// for usable-boot VM snapshots (src/md/infrastructure/fast_build.md).
package machine

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "modus:contract/blake3"
import "modus:disk_process"
import "modustool:build"
import "modustool:foundation"

// Format property: upper bound on QEMU snapshot tag length keeping tags safe
// for QMP and HMP command lines.
QMP_SNAPSHOT_TAG_MAX_BYTES :: 64

// Plan value: leading hex digits of the boot-image BLAKE3 hash included in
// deterministic usable-boot snapshot tags and filenames.
QMP_SNAPSHOT_HASH_PREFIX_HEX :: 16

// Files stored inside a captured usable-boot QMP snapshot folder.
QMP_SNAPSHOT_META_FILE :: "snapshot.meta"
QMP_SNAPSHOT_BOOT_LOG_FILE :: "boot_log.txt"
QMP_SNAPSHOT_VARS_FILE :: "ovmf_vars.qcow2"
QMP_SNAPSHOT_DATA_FILE :: "data_disk.qcow2"
QMP_SNAPSHOT_SCRATCH_FILE :: "scratch_disk.qcow2"
QMP_SNAPSHOT_META_HEADER :: "modus qmp snapshot 1"

// Suffixes of per-machine writable qcow2 copies staged when restoring a
// snapshot inside a test part.
QMP_SNAPSHOT_STAGE_VARS_SUFFIX :: "_snap_ovmf_vars.qcow2"
QMP_SNAPSHOT_STAGE_DATA_SUFFIX :: "_snap_data.qcow2"
QMP_SNAPSHOT_STAGE_SCRATCH_SUFFIX :: "_snap_scratch.qcow2"

// Closed border refusal set for QMP snapshot naming, commands, metadata, and replies.
Qmp_Snapshot_Refusal :: enum u8 {
	None,
	Empty_Tag,
	Invalid_Tag,
	Tag_Too_Long,
	Zero_Boot_Hash,
	Empty_Folder,
	Malformed_Reply,
	Qmp_Error,
	Socket_Not_Open,
	Command_Failed,
	Malformed_Meta,
	Missing_File,
	Boot_Hash_Mismatch,
}

// Metadata recorded alongside a captured usable-boot QMP snapshot so each
// restoring derivation verifies boot-image identity and restores clock offset.
Qmp_Snapshot_Meta :: struct {
	tag:              string,
	boot_hash:        string,
	guest_clock_unix: i64,
	prelude_steps:    int,
}

// Parsed QMP line reply for snapshot control and query-status commands.
Qmp_Snapshot_Reply :: struct {
	kind:       Qmp_Reply_Kind,
	text:       string,
	status:     string,
	running:    bool,
	has_status: bool,
	refusal:    Qmp_Snapshot_Refusal,
}

// qmp_snapshot_hash_is_zero reports whether every byte of hash is zero.
@(private = "file")
qmp_snapshot_hash_is_zero :: proc(hash: blake3.Hash) -> bool {
	for b in hash {
		if b != 0 {
			return false
		}
	}
	return true
}

// qmp_snapshot_tag_validate checks that tag is non-empty, within
// QMP_SNAPSHOT_TAG_MAX_BYTES, and contains only ASCII [A-Za-z0-9._-] so it
// cannot inject whitespace, quotes, or monitor separators into QMP/HMP.
qmp_snapshot_tag_validate :: proc(tag: string) -> Qmp_Snapshot_Refusal {
	if len(tag) == 0 {
		return .Empty_Tag
	}
	if len(tag) > QMP_SNAPSHOT_TAG_MAX_BYTES {
		return .Tag_Too_Long
	}
	for b in transmute([]u8)tag {
		is_alpha := (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
		is_digit := b >= '0' && b <= '9'
		is_punct := b == '.' || b == '_' || b == '-'
		if !is_alpha && !is_digit && !is_punct {
			return .Invalid_Tag
		}
	}
	return .None
}

// qmp_snapshot_tag_for_boot_image returns a deterministic snapshot tag keyed
// by the boot image's BLAKE3 hash (for example `usable_boot-<16-hex>`).
qmp_snapshot_tag_for_boot_image :: proc(boot_hash: blake3.Hash, prefix := "usable_boot", allocator := context.allocator) -> (tag: string, refusal: Qmp_Snapshot_Refusal) {
	if qmp_snapshot_hash_is_zero(boot_hash) {
		return "", .Zero_Boot_Hash
	}
	if prefix_ref := qmp_snapshot_tag_validate(prefix); prefix_ref != .None {
		return "", prefix_ref
	}
	digits: [disk_process.HASH_DIGITS]u8
	disk_process.hash_write(&digits, boot_hash)
	candidate := fmt.aprintf("%s-%s", prefix, string(digits[:QMP_SNAPSHOT_HASH_PREFIX_HEX]), allocator = allocator)
	if tag_ref := qmp_snapshot_tag_validate(candidate); tag_ref != .None {
		delete(candidate, allocator)
		return "", tag_ref
	}
	return candidate, .None
}

// qmp_snapshot_file_path returns the deterministic qcow2 snapshot backing file
// path inside folder keyed by boot_hash.
qmp_snapshot_file_path :: proc(folder: string, boot_hash: blake3.Hash, allocator := context.allocator) -> (path: string, refusal: Qmp_Snapshot_Refusal) {
	if len(folder) == 0 {
		return "", .Empty_Folder
	}
	if qmp_snapshot_hash_is_zero(boot_hash) {
		return "", .Zero_Boot_Hash
	}
	digits: [disk_process.HASH_DIGITS]u8
	disk_process.hash_write(&digits, boot_hash)
	clean_folder := strings.trim_right(folder, "/")
	return fmt.aprintf("%s/vm_snapshot_%s.qcow2", clean_folder, string(digits[:QMP_SNAPSHOT_HASH_PREFIX_HEX]), allocator = allocator), .None
}

// qmp_capabilities_command returns the QMP capability negotiation line.
qmp_capabilities_command :: proc() -> string {
	return "{\"execute\":\"qmp_capabilities\"}"
}

// qmp_stop_command returns the QMP command pausing guest vCPU execution.
qmp_stop_command :: proc() -> string {
	return "{\"execute\":\"stop\"}"
}

// qmp_cont_command returns the QMP command resuming guest vCPU execution.
qmp_cont_command :: proc() -> string {
	return "{\"execute\":\"cont\"}"
}

// qmp_query_status_command returns the QMP command querying guest run state.
qmp_query_status_command :: proc() -> string {
	return "{\"execute\":\"query-status\"}"
}

// qmp_savevm_command builds the QMP line saving a VM snapshot under tag.
qmp_savevm_command :: proc(tag: string) -> (command: string, refusal: Qmp_Snapshot_Refusal) {
	if tag_ref := qmp_snapshot_tag_validate(tag); tag_ref != .None {
		return "", tag_ref
	}
	hmp := strings.concatenate({"savevm ", tag}, context.temp_allocator)
	return qmp_monitor_command(hmp), .None
}

// qmp_loadvm_command builds the QMP line restoring a VM snapshot named tag.
qmp_loadvm_command :: proc(tag: string) -> (command: string, refusal: Qmp_Snapshot_Refusal) {
	if tag_ref := qmp_snapshot_tag_validate(tag); tag_ref != .None {
		return "", tag_ref
	}
	hmp := strings.concatenate({"loadvm ", tag}, context.temp_allocator)
	return qmp_monitor_command(hmp), .None
}

// qmp_snapshot_extract_json_string extracts the unescaped string value for key
// from a compact QMP JSON object fragment.
@(private = "file")
qmp_snapshot_extract_json_string :: proc(body, key: string) -> (value: string, found: bool) {
	needle := strings.concatenate({"\"", key, "\":\""}, context.temp_allocator)
	at := strings.index(body, needle)
	if at < 0 {
		return "", false
	}
	rest := body[at + len(needle):]
	for i in 0 ..< len(rest) {
		if rest[i] == '"' && (i == 0 || rest[i - 1] != '\\') {
			return rest[:i], true
		}
	}
	return "", false
}

// qmp_snapshot_hmp_has_error reports whether a human-monitor-command return
// string carries a QEMU HMP snapshot failure message.
@(private = "file")
qmp_snapshot_hmp_has_error :: proc(return_text: string) -> bool {
	return strings.contains(return_text, "Error:") ||
	       strings.contains(return_text, "Could not find snapshot") ||
	       strings.contains(return_text, "Device '") && strings.contains(return_text, "does not support snapshots")
}

// qmp_snapshot_reply_parse validates a single QMP JSON line and distinguishes
// "return", "error", greeting, event, and malformed lines cleanly.
qmp_snapshot_reply_parse :: proc(line: string) -> Qmp_Snapshot_Reply {
	trimmed := strings.trim_space(line)
	if len(trimmed) < 2 || trimmed[0] != '{' || trimmed[len(trimmed) - 1] != '}' {
		return {kind = .Unknown, refusal = .Malformed_Reply}
	}
	kind, text := qmp_reply_parse(trimmed)
	reply := Qmp_Snapshot_Reply{kind = kind, text = text}
	switch kind {
	case .Return:
		if len(text) == 0 {
			reply.refusal = .Malformed_Reply
			return reply
		}
		if qmp_snapshot_hmp_has_error(text) {
			reply.refusal = .Qmp_Error
			return reply
		}
		if status_text, ok := qmp_snapshot_extract_json_string(text, "status"); ok {
			reply.status = status_text
			reply.has_status = true
			reply.running = strings.contains(text, "\"running\":true") || strings.contains(text, "\"running\": true")
		}
		reply.refusal = .None
	case .Error:
		reply.refusal = .Qmp_Error
	case .Greeting, .Event:
		reply.refusal = .None
	case .Unknown:
		reply.refusal = .Malformed_Reply
	}
	return reply
}

// qmp_snapshot_save pauses the guest, saves a usable-boot VM snapshot under
// tag over the open QMP socket, and resumes execution.
qmp_snapshot_save :: proc(qmp: ^Qmp, tag: string) -> Qmp_Snapshot_Refusal {
	if qmp == nil || !qmp.open || qmp.ended {
		return .Socket_Not_Open
	}
	save_cmd, tag_ref := qmp_savevm_command(tag)
	if tag_ref != .None {
		return tag_ref
	}
	if _, ok := qmp_command(qmp, qmp_stop_command(), print_failure = false); !ok {
		return .Command_Failed
	}
	save_reply, save_ok := qmp_command(qmp, save_cmd, print_failure = false)
	if !save_ok {
		_, _ = qmp_command(qmp, qmp_cont_command(), print_failure = false)
		return .Command_Failed
	}
	if qmp_snapshot_hmp_has_error(save_reply) {
		_, _ = qmp_command(qmp, qmp_cont_command(), print_failure = false)
		return .Qmp_Error
	}
	if _, ok := qmp_command(qmp, qmp_cont_command(), print_failure = false); !ok {
		return .Command_Failed
	}
	return .None
}

// qmp_snapshot_restore pauses the guest, loads the usable-boot VM snapshot
// named tag over the open QMP socket, and resumes execution.
qmp_snapshot_restore :: proc(qmp: ^Qmp, tag: string) -> Qmp_Snapshot_Refusal {
	if qmp == nil || !qmp.open || qmp.ended {
		return .Socket_Not_Open
	}
	load_cmd, tag_ref := qmp_loadvm_command(tag)
	if tag_ref != .None {
		return tag_ref
	}
	if _, ok := qmp_command(qmp, qmp_stop_command(), print_failure = false); !ok {
		return .Command_Failed
	}
	load_reply, load_ok := qmp_command(qmp, load_cmd, print_failure = false)
	if !load_ok {
		return .Command_Failed
	}
	if qmp_snapshot_hmp_has_error(load_reply) {
		return .Qmp_Error
	}
	if _, ok := qmp_command(qmp, qmp_cont_command(), print_failure = false); !ok {
		return .Command_Failed
	}
	return .None
}

// qmp_snapshot_save_paused pauses the guest and saves a usable-boot VM
// snapshot under tag without resuming execution, so the caller can quit QEMU
// immediately with zero guest instructions after the snapshot point.
qmp_snapshot_save_paused :: proc(qmp: ^Qmp, tag: string) -> Qmp_Snapshot_Refusal {
	if qmp == nil || !qmp.open || qmp.ended {
		return .Socket_Not_Open
	}
	save_cmd, tag_ref := qmp_savevm_command(tag)
	if tag_ref != .None {
		return tag_ref
	}
	if _, ok := qmp_command(qmp, qmp_stop_command(), print_failure = false); !ok {
		return .Command_Failed
	}
	save_reply, save_ok := qmp_command(qmp, save_cmd, print_failure = false)
	if !save_ok {
		return .Command_Failed
	}
	if qmp_snapshot_hmp_has_error(save_reply) {
		return .Qmp_Error
	}
	return .None
}

// qmp_snapshot_hex_valid reports whether text is a lowercase hex string of
// exact length disk_process.HASH_DIGITS (64 hex digits for BLAKE3).
@(private = "file")
qmp_snapshot_hex_valid :: proc(text: string) -> bool {
	if len(text) != disk_process.HASH_DIGITS {
		return false
	}
	for b in transmute([]u8)text {
		is_digit := b >= '0' && b <= '9'
		is_hex := b >= 'a' && b <= 'f'
		if !is_digit && !is_hex {
			return false
		}
	}
	return true
}

// qmp_snapshot_meta_format encodes Qmp_Snapshot_Meta into its canonical
// plain-text form.
qmp_snapshot_meta_format :: proc(meta: Qmp_Snapshot_Meta, allocator := context.allocator) -> (text: string, refusal: Qmp_Snapshot_Refusal) {
	if tag_ref := qmp_snapshot_tag_validate(meta.tag); tag_ref != .None {
		return "", tag_ref
	}
	if !qmp_snapshot_hex_valid(meta.boot_hash) || meta.guest_clock_unix <= 0 || meta.prelude_steps <= 0 {
		return "", .Malformed_Meta
	}
	return fmt.aprintf(
		"%s\ntag %s\nboot_hash %s\nguest_clock_unix %d\nprelude_steps %d\n",
		QMP_SNAPSHOT_META_HEADER,
		meta.tag,
		meta.boot_hash,
		meta.guest_clock_unix,
		meta.prelude_steps,
		allocator = allocator,
	), .None
}

// qmp_snapshot_meta_parse parses and validates a snapshot.meta text file.
qmp_snapshot_meta_parse :: proc(text: string) -> (meta: Qmp_Snapshot_Meta, refusal: Qmp_Snapshot_Refusal) {
	lines := strings.split_lines(strings.trim_right(text, "\r\n"), context.temp_allocator)
	if len(lines) < 5 || lines[0] != QMP_SNAPSHOT_META_HEADER {
		return {}, .Malformed_Meta
	}
	seen_tag, seen_hash, seen_clock, seen_steps := false, false, false, false
	for line in lines[1:] {
		space := strings.index_byte(line, ' ')
		if space <= 0 || space + 1 >= len(line) {
			return {}, .Malformed_Meta
		}
		key := line[:space]
		value := line[space + 1:]
		switch key {
		case "tag":
			if seen_tag || qmp_snapshot_tag_validate(value) != .None {
				return {}, .Malformed_Meta
			}
			meta.tag = value
			seen_tag = true
		case "boot_hash":
			if seen_hash || !qmp_snapshot_hex_valid(value) {
				return {}, .Malformed_Meta
			}
			meta.boot_hash = value
			seen_hash = true
		case "guest_clock_unix":
			parsed, ok := strconv.parse_i64(value, 10)
			if seen_clock || !ok || parsed <= 0 {
				return {}, .Malformed_Meta
			}
			meta.guest_clock_unix = parsed
			seen_clock = true
		case "prelude_steps":
			parsed, ok := strconv.parse_int(value, 10)
			if seen_steps || !ok || parsed <= 0 {
				return {}, .Malformed_Meta
			}
			meta.prelude_steps = parsed
			seen_steps = true
		case:
			return {}, .Malformed_Meta
		}
	}
	if !seen_tag || !seen_hash || !seen_clock || !seen_steps {
		return {}, .Malformed_Meta
	}
	return meta, .None
}

// qmp_snapshot_boot_hash_of_file computes the BLAKE3 hash and 64-digit hex
// text of a boot image file.
qmp_snapshot_boot_hash_of_file :: proc(path: string, allocator := context.allocator) -> (hash: blake3.Hash, hex: string, ok: bool) {
	bytes, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil || len(bytes) == 0 {
		delete(bytes)
		return {}, "", false
	}
	defer delete(bytes)
	hash = blake3.hash(bytes)
	digits: [disk_process.HASH_DIGITS]u8
	disk_process.hash_write(&digits, hash)
	return hash, strings.clone(string(digits[:]), allocator), true
}

// qmp_snapshot_folder_validate verifies that folder holds every file of a
// captured usable-boot snapshot and that its boot_hash matches expected_hex.
qmp_snapshot_folder_validate :: proc(folder: string, expected_boot_hash_hex: string) -> (meta: Qmp_Snapshot_Meta, refusal: Qmp_Snapshot_Refusal, problem: string) {
	if folder == "" {
		return {}, .Empty_Folder, "the snapshot folder path is empty"
	}
	required_files := [5]string {
		QMP_SNAPSHOT_META_FILE,
		QMP_SNAPSHOT_BOOT_LOG_FILE,
		QMP_SNAPSHOT_VARS_FILE,
		QMP_SNAPSHOT_DATA_FILE,
		QMP_SNAPSHOT_SCRATCH_FILE,
	}
	clean_folder := strings.trim_right(folder, "/")
	for file_name in required_files {
		full_path := foundation.join(clean_folder, "/", file_name)
		if !os.exists(full_path) {
			return {}, .Missing_File, fmt.tprintf("the snapshot folder %s lacks %s", folder, file_name)
		}
	}
	meta_path := foundation.join(clean_folder, "/", QMP_SNAPSHOT_META_FILE)
	meta_bytes, read_err := os.read_entire_file(meta_path, context.temp_allocator)
	if read_err != nil {
		return {}, .Missing_File, fmt.tprintf("cannot read %s: %v", meta_path, read_err)
	}
	parsed, parse_ref := qmp_snapshot_meta_parse(string(meta_bytes))
	if parse_ref != .None {
		return {}, parse_ref, fmt.tprintf("the snapshot metadata %s is malformed", meta_path)
	}
	if expected_boot_hash_hex != "" && parsed.boot_hash != expected_boot_hash_hex {
		return {}, .Boot_Hash_Mismatch, fmt.tprintf("the snapshot %s has boot hash %s, not the current boot image hash %s", folder, parsed.boot_hash, expected_boot_hash_hex)
	}
	return parsed, .None, ""
}

// qmp_snapshot_prepare_qcow2 creates fresh writable qcow2 images for OVMF
// variables, the data disk, and the scratch disk using qemu-img.
qmp_snapshot_prepare_qcow2 :: proc(ovmf_vars_src, vars_qcow2, data_qcow2, scratch_qcow2: string) -> bool {
	if !foundation.run({"qemu-img", "convert", "-f", "raw", "-O", "qcow2", ovmf_vars_src, vars_qcow2}) {
		return false
	}
	if !foundation.run({"qemu-img", "create", "-f", "qcow2", data_qcow2, fmt.tprintf("%d", build.DATA_DISK_SIZE)}) {
		return false
	}
	if !foundation.run({"qemu-img", "create", "-f", "qcow2", scratch_qcow2, fmt.tprintf("%d", SCRATCH_DISK_SIZE)}) {
		return false
	}
	return true
}

// qmp_snapshot_copy_writable copies source to target and makes target
// user-writable (store paths in Nix sandboxes are read-only).
@(private = "file")
qmp_snapshot_copy_writable :: proc(target, source: string) -> bool {
	_ = os.remove(target)
	if copy_err := os.copy_file(target, source); copy_err != nil {
		fmt.eprintfln("modustool: cannot copy %s to %s: %v", source, target, copy_err)
		return false
	}
	if mode_err := os.change_mode(target, os.perm(0o644)); mode_err != nil {
		fmt.eprintfln("modustool: cannot make %s writable: %v", target, mode_err)
		return false
	}
	return true
}

// qmp_snapshot_stage_from_folder validates snapshot_folder against
// expected_boot_hash_hex, copies writable qcow2 images to vars_dst, data_dst,
// and scratch_dst, and seeds output_log_dst from boot_log.txt.
qmp_snapshot_stage_from_folder :: proc(snapshot_folder, expected_boot_hash_hex, vars_dst, data_dst, scratch_dst, output_log_dst: string) -> (meta: Qmp_Snapshot_Meta, ok: bool) {
	parsed, _, problem := qmp_snapshot_folder_validate(snapshot_folder, expected_boot_hash_hex)
	if problem != "" {
		fmt.eprintfln("modustool: test failed: %s", problem)
		return {}, false
	}
	clean_folder := strings.trim_right(snapshot_folder, "/")
	qmp_snapshot_copy_writable(vars_dst, foundation.join(clean_folder, "/", QMP_SNAPSHOT_VARS_FILE)) or_return
	qmp_snapshot_copy_writable(data_dst, foundation.join(clean_folder, "/", QMP_SNAPSHOT_DATA_FILE)) or_return
	qmp_snapshot_copy_writable(scratch_dst, foundation.join(clean_folder, "/", QMP_SNAPSHOT_SCRATCH_FILE)) or_return
	qmp_snapshot_copy_writable(output_log_dst, foundation.join(clean_folder, "/", QMP_SNAPSHOT_BOOT_LOG_FILE)) or_return
	return parsed, true
}

// boot_snapshot_capture boots build.BOOT_VOLUME through MAIN_BOOT_PRELUDE,
// pauses the guest at MAIN_SHARD_PRELUDE_END, saves a QMP internal snapshot
// across the writable qcow2 drives, and writes the snapshot folder to
// target_folder. When inputs_folder is non-empty, takes test inputs from it
// with no prior build (used by the Nix bootSnapshot derivation).
boot_snapshot_capture :: proc(target_folder: string, inputs_folder: string) -> bool {
	if target_folder == "" {
		fmt.eprintln("modustool: boot-snapshot requires a target folder path")
		return false
	}
	if os.exists(target_folder) {
		fmt.eprintfln("modustool: %s exists: boot-snapshot writes to a new folder", target_folder)
		return false
	}
	if inputs_folder != "" {
		synthetic_part := Test_Part {
			name    = "boot_snapshot",
			volumes = {build.BOOT_VOLUME},
		}
		if !test_inputs_take(inputs_folder, synthetic_part) {
			return false
		}
	}
	boot_hash, boot_hash_hex, hash_ok := qmp_snapshot_boot_hash_of_file(build.BOOT_IMAGE, context.allocator)
	if !hash_ok {
		fmt.eprintfln("modustool: boot-snapshot cannot hash %s", build.BOOT_IMAGE)
		return false
	}
	defer delete(boot_hash_hex)
	tag, tag_ref := qmp_snapshot_tag_for_boot_image(boot_hash, allocator = context.allocator)
	if tag_ref != .None {
		fmt.eprintfln("modustool: boot-snapshot refused tag generation (%v)", tag_ref)
		return false
	}
	defer delete(tag)

	if !foundation.make_folder(target_folder) {
		return false
	}
	clean_target := strings.trim_right(target_folder, "/")
	vars_qcow2 := strings.clone(foundation.join(clean_target, "/", QMP_SNAPSHOT_VARS_FILE))
	defer delete(vars_qcow2)
	data_qcow2 := strings.clone(foundation.join(clean_target, "/", QMP_SNAPSHOT_DATA_FILE))
	defer delete(data_qcow2)
	scratch_qcow2 := strings.clone(foundation.join(clean_target, "/", QMP_SNAPSHOT_SCRATCH_FILE))
	defer delete(scratch_qcow2)
	boot_log_dst := strings.clone(foundation.join(clean_target, "/", QMP_SNAPSHOT_BOOT_LOG_FILE))
	defer delete(boot_log_dst)
	meta_dst := strings.clone(foundation.join(clean_target, "/", QMP_SNAPSHOT_META_FILE))
	defer delete(meta_dst)

	ovmf_vars_src := os.get_env("OVMF_VARS", context.temp_allocator)
	if ovmf_vars_src == "" {
		fmt.eprintln("modustool: OVMF_VARS is not set. Use the development shell: nix develop")
		return false
	}
	if !qmp_snapshot_prepare_qcow2(ovmf_vars_src, vars_qcow2, data_qcow2, scratch_qcow2) {
		return false
	}

	part_run := test_part_run_make("boot_snapshot")
	defer test_part_run_free(&part_run)
	capture_log := foundation.BUILD_FOLDER + "/test_output_boot_snapshot.txt"
	guest_clock_unix: i64 = 0
	prelude := MAIN_BOOT_PRELUDE
	passed := machine_test(
		&part_run,
		prelude[:],
		{
			volume                       = build.BOOT_VOLUME,
			output                       = capture_log,
			exit_status                  = QEMU_QUIT_STATUS,
			snapshot_capture_tag         = tag,
			snapshot_capture_vars        = vars_qcow2,
			snapshot_capture_data        = data_qcow2,
			snapshot_capture_scratch     = scratch_qcow2,
			snapshot_capture_guest_clock = &guest_clock_unix,
		},
	)
	if !passed {
		return false
	}
	if !qmp_snapshot_copy_writable(boot_log_dst, capture_log) {
		return false
	}
	meta := Qmp_Snapshot_Meta {
		tag              = tag,
		boot_hash        = boot_hash_hex,
		guest_clock_unix = guest_clock_unix,
		prelude_steps    = len(prelude),
	}
	meta_text, meta_ref := qmp_snapshot_meta_format(meta, context.temp_allocator)
	if meta_ref != .None {
		fmt.eprintfln("modustool: boot-snapshot produced invalid metadata (%v)", meta_ref)
		return false
	}
	if write_err := os.write_entire_file(meta_dst, transmute([]u8)meta_text); write_err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", meta_dst, write_err)
		return false
	}
	fmt.printfln("modustool: captured usable-boot QMP snapshot %s in %s (%d prelude steps)", tag, target_folder, len(prelude))
	return true
}
