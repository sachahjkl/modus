// Host unit tests for QMP usable-boot machine snapshots (qmp_snapshot.odin).
package machine

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modustool:foundation"

@(test)
qmp_snapshot_refuses_bad_tags_hashes_and_sockets :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Empty, overlong, and injection-bearing tags are refused.
	testing.expect_value(t, qmp_snapshot_tag_validate(""), Qmp_Snapshot_Refusal.Empty_Tag)
	overlong := strings.repeat("a", QMP_SNAPSHOT_TAG_MAX_BYTES + 1, context.temp_allocator)
	testing.expect_value(t, qmp_snapshot_tag_validate(overlong), Qmp_Snapshot_Refusal.Tag_Too_Long)
	for bad in ([]string{"tag with space", "tag\"quote", "tag;quit", "tag\nline", "../escape", "a/b"}) {
		testing.expect_value(t, qmp_snapshot_tag_validate(bad), Qmp_Snapshot_Refusal.Invalid_Tag)
		_, save_ref := qmp_savevm_command(bad)
		testing.expect_value(t, save_ref, Qmp_Snapshot_Refusal.Invalid_Tag)
		_, load_ref := qmp_loadvm_command(bad)
		testing.expect_value(t, load_ref, Qmp_Snapshot_Refusal.Invalid_Tag)
	}

	// Zero boot hash and empty folder are refused.
	zero_hash: blake3.Hash
	_, tag_ref := qmp_snapshot_tag_for_boot_image(zero_hash, allocator = context.temp_allocator)
	testing.expect_value(t, tag_ref, Qmp_Snapshot_Refusal.Zero_Boot_Hash)
	_, path_ref := qmp_snapshot_file_path("build", zero_hash, context.temp_allocator)
	testing.expect_value(t, path_ref, Qmp_Snapshot_Refusal.Zero_Boot_Hash)

	sample_hash := blake3.hash(transmute([]u8)string("boot-image-bytes"))
	_, empty_folder_ref := qmp_snapshot_file_path("", sample_hash, context.temp_allocator)
	testing.expect_value(t, empty_folder_ref, Qmp_Snapshot_Refusal.Empty_Folder)

	// Closed or nil QMP sockets fail cleanly without touching file descriptors.
	closed_qmp: Qmp
	testing.expect_value(t, qmp_snapshot_save(nil, "usable_boot"), Qmp_Snapshot_Refusal.Socket_Not_Open)
	testing.expect_value(t, qmp_snapshot_save(&closed_qmp, "usable_boot"), Qmp_Snapshot_Refusal.Socket_Not_Open)
	testing.expect_value(t, qmp_snapshot_restore(nil, "usable_boot"), Qmp_Snapshot_Refusal.Socket_Not_Open)
	testing.expect_value(t, qmp_snapshot_restore(&closed_qmp, "usable_boot"), Qmp_Snapshot_Refusal.Socket_Not_Open)
}

@(test)
qmp_snapshot_commands_and_replies_round_trip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Deterministic tag and path generation keyed by boot-image BLAKE3 hash.
	hash_a := blake3.hash(transmute([]u8)string("boot-image-a"))
	hash_b := blake3.hash(transmute([]u8)string("boot-image-b"))

	tag_a1, ref_a1 := qmp_snapshot_tag_for_boot_image(hash_a, allocator = context.temp_allocator)
	tag_a2, ref_a2 := qmp_snapshot_tag_for_boot_image(hash_a, allocator = context.temp_allocator)
	tag_b, ref_b := qmp_snapshot_tag_for_boot_image(hash_b, allocator = context.temp_allocator)
	testing.expect_value(t, ref_a1, Qmp_Snapshot_Refusal.None)
	testing.expect_value(t, ref_a2, Qmp_Snapshot_Refusal.None)
	testing.expect_value(t, ref_b, Qmp_Snapshot_Refusal.None)
	testing.expect_value(t, tag_a1, tag_a2)
	testing.expect(t, tag_a1 != tag_b, "distinct boot hashes yield distinct snapshot tags")
	testing.expect(t, strings.has_prefix(tag_a1, "usable_boot-"), "tag carries usable_boot prefix")

	path_a, path_ref := qmp_snapshot_file_path("build/snapshots/", hash_a, context.temp_allocator)
	testing.expect_value(t, path_ref, Qmp_Snapshot_Refusal.None)
	testing.expect(t, strings.has_prefix(path_a, "build/snapshots/vm_snapshot_") && strings.has_suffix(path_a, ".qcow2"), "snapshot path uses qcow2 naming")

	// QMP command builders emit exact JSON-line commands.
	testing.expect_value(t, qmp_capabilities_command(), "{\"execute\":\"qmp_capabilities\"}")
	testing.expect_value(t, qmp_stop_command(), "{\"execute\":\"stop\"}")
	testing.expect_value(t, qmp_cont_command(), "{\"execute\":\"cont\"}")
	testing.expect_value(t, qmp_query_status_command(), "{\"execute\":\"query-status\"}")

	save_cmd, save_ref := qmp_savevm_command(tag_a1)
	testing.expect_value(t, save_ref, Qmp_Snapshot_Refusal.None)
	save_needle := strings.concatenate({"savevm ", tag_a1}, context.temp_allocator)
	testing.expect(t, strings.contains(save_cmd, "human-monitor-command") && strings.contains(save_cmd, save_needle), "savevm command wraps tag")

	load_cmd, load_ref := qmp_loadvm_command(tag_a1)
	testing.expect_value(t, load_ref, Qmp_Snapshot_Refusal.None)
	load_needle := strings.concatenate({"loadvm ", tag_a1}, context.temp_allocator)
	testing.expect(t, strings.contains(load_cmd, "human-monitor-command") && strings.contains(load_cmd, load_needle), "loadvm command wraps tag")

	// Malformed JSON and error replies are refused.
	for malformed in ([]string{"", "not-json", "{", "{}", "{\"unknown\":1}", "{\"return\":}"}) {
		parsed := qmp_snapshot_reply_parse(malformed)
		testing.expectf(t, parsed.refusal == .Malformed_Reply, "line %q must be refused as Malformed_Reply (got %v)", malformed, parsed.refusal)
	}

	err_reply := qmp_snapshot_reply_parse("{\"error\":{\"class\":\"GenericError\",\"desc\":\"Snapshot failed\"}}")
	testing.expect_value(t, err_reply.kind, Qmp_Reply_Kind.Error)
	testing.expect_value(t, err_reply.refusal, Qmp_Snapshot_Refusal.Qmp_Error)
	testing.expect_value(t, err_reply.text, "Snapshot failed")

	hmp_err := qmp_snapshot_reply_parse("{\"return\":\"Error: Could not find snapshot 'missing'\"}")
	testing.expect_value(t, hmp_err.kind, Qmp_Reply_Kind.Return)
	testing.expect_value(t, hmp_err.refusal, Qmp_Snapshot_Refusal.Qmp_Error)

	// Valid return, query-status, greeting, and event lines parse cleanly.
	ok_reply := qmp_snapshot_reply_parse("{\"return\":{}}")
	testing.expect_value(t, ok_reply.kind, Qmp_Reply_Kind.Return)
	testing.expect_value(t, ok_reply.refusal, Qmp_Snapshot_Refusal.None)

	status_reply := qmp_snapshot_reply_parse("{\"return\":{\"running\":true,\"singlestep\":false,\"status\":\"running\"}}")
	testing.expect_value(t, status_reply.refusal, Qmp_Snapshot_Refusal.None)
	testing.expect(t, status_reply.has_status && status_reply.running, "query-status reports running state")
	testing.expect_value(t, status_reply.status, "running")

	paused_reply := qmp_snapshot_reply_parse("{\"return\":{\"running\":false,\"status\":\"paused\"}}")
	testing.expect_value(t, paused_reply.refusal, Qmp_Snapshot_Refusal.None)
	testing.expect(t, paused_reply.has_status && !paused_reply.running, "query-status reports paused state")
	testing.expect_value(t, paused_reply.status, "paused")

	greeting := qmp_snapshot_reply_parse("{\"QMP\":{\"version\":{}}}")
	testing.expect_value(t, greeting.kind, Qmp_Reply_Kind.Greeting)
	testing.expect_value(t, greeting.refusal, Qmp_Snapshot_Refusal.None)
}

@(test)
qmp_snapshot_meta_and_folder_validation :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Closed socket refusal for save_paused.
	closed_qmp: Qmp
	testing.expect_value(t, qmp_snapshot_save_paused(nil, "usable_boot"), Qmp_Snapshot_Refusal.Socket_Not_Open)
	testing.expect_value(t, qmp_snapshot_save_paused(&closed_qmp, "usable_boot"), Qmp_Snapshot_Refusal.Socket_Not_Open)

	// Malformed metadata strings are refused before any machine starts.
	zero_hex := strings.repeat("0", 64, context.temp_allocator)
	hash_hex := strings.repeat("a", 64, context.temp_allocator)
	for bad_meta in ([]string {
		"",
		fmt.tprintf("wrong header\ntag a\nboot_hash %s\nguest_clock_unix 1\nprelude_steps 1\n", zero_hex),
		fmt.tprintf("%s\ntag bad tag\nboot_hash %s\nguest_clock_unix 10\nprelude_steps 5\n", QMP_SNAPSHOT_META_HEADER, hash_hex),
		fmt.tprintf("%s\ntag ok\nboot_hash short\nguest_clock_unix 10\nprelude_steps 5\n", QMP_SNAPSHOT_META_HEADER),
		fmt.tprintf("%s\ntag ok\nboot_hash %s\nguest_clock_unix 0\nprelude_steps 5\n", QMP_SNAPSHOT_META_HEADER, hash_hex),
		fmt.tprintf("%s\ntag ok\nboot_hash %s\nguest_clock_unix 10\nprelude_steps 0\n", QMP_SNAPSHOT_META_HEADER, hash_hex),
		fmt.tprintf("%s\ntag ok\nboot_hash %s\nguest_clock_unix 10\nprelude_steps 5\nunknown 1\n", QMP_SNAPSHOT_META_HEADER, hash_hex),
	}) {
		_, ref := qmp_snapshot_meta_parse(bad_meta)
		testing.expect_value(t, ref, Qmp_Snapshot_Refusal.Malformed_Meta)
	}

	// Valid metadata round-trips cleanly.
	sample := Qmp_Snapshot_Meta {
		tag              = "usable_boot-0123456789abcdef",
		boot_hash        = hash_hex,
		guest_clock_unix = 1795000000,
		prelude_steps    = len(MAIN_BOOT_PRELUDE),
	}
	encoded, fmt_ref := qmp_snapshot_meta_format(sample, context.temp_allocator)
	testing.expect_value(t, fmt_ref, Qmp_Snapshot_Refusal.None)
	parsed, parse_ref := qmp_snapshot_meta_parse(encoded)
	testing.expect_value(t, parse_ref, Qmp_Snapshot_Refusal.None)
	testing.expect_value(t, parsed.tag, sample.tag)
	testing.expect_value(t, parsed.boot_hash, sample.boot_hash)
	testing.expect_value(t, parsed.guest_clock_unix, sample.guest_clock_unix)
	testing.expect_value(t, parsed.prelude_steps, sample.prelude_steps)

	// Folder validation refuses empty path, missing files, and hash mismatches.
	_, empty_ref, _ := qmp_snapshot_folder_validate("", hash_hex)
	testing.expect_value(t, empty_ref, Qmp_Snapshot_Refusal.Empty_Folder)

	test_dir := foundation.BUILD_FOLDER + "/qmp_snapshot_validate_test"
	_ = os.remove_all(test_dir)
	defer {
		_ = os.remove_all(test_dir)
	}
	testing.expect(t, foundation.make_folder(test_dir))
	_, missing_ref, _ := qmp_snapshot_folder_validate(test_dir, hash_hex)
	testing.expect_value(t, missing_ref, Qmp_Snapshot_Refusal.Missing_File)

	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", test_dir, QMP_SNAPSHOT_META_FILE), transmute([]u8)encoded) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", test_dir, QMP_SNAPSHOT_BOOT_LOG_FILE), transmute([]u8)string("boot program: ok\n")) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", test_dir, QMP_SNAPSHOT_VARS_FILE), transmute([]u8)string("v")) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", test_dir, QMP_SNAPSHOT_DATA_FILE), transmute([]u8)string("d")) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", test_dir, QMP_SNAPSHOT_SCRATCH_FILE), transmute([]u8)string("s")) == nil)

	wrong_hash := strings.repeat("b", 64, context.temp_allocator)
	_, mismatch_ref, _ := qmp_snapshot_folder_validate(test_dir, wrong_hash)
	testing.expect_value(t, mismatch_ref, Qmp_Snapshot_Refusal.Boot_Hash_Mismatch)

	valid_meta, valid_ref, valid_problem := qmp_snapshot_folder_validate(test_dir, hash_hex)
	testing.expect_value(t, valid_ref, Qmp_Snapshot_Refusal.None)
	testing.expect_value(t, valid_problem, "")
	testing.expect_value(t, valid_meta.tag, sample.tag)
}
