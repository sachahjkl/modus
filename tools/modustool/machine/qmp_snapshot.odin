// QMP machine snapshot command builders, reply parser, and save/restore helpers
// for usable-boot VM snapshots (src/md/infrastructure/fast_build.md).
package machine

import "core:fmt"
import "core:strings"
import "modus:contract/blake3"
import "modus:disk_process"

// Format property: upper bound on QEMU snapshot tag length keeping tags safe
// for QMP and HMP command lines.
QMP_SNAPSHOT_TAG_MAX_BYTES :: 64

// Plan value: leading hex digits of the boot-image BLAKE3 hash included in
// deterministic usable-boot snapshot tags and filenames.
QMP_SNAPSHOT_HASH_PREFIX_HEX :: 16

// Closed border refusal set for QMP snapshot naming, commands, and replies.
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
