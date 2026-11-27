package machine

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "modus:contract/blake3"
import "modus:contract/fixed_addresses"
import "modus:contract/font_outlines"
import ilp "modus:contract/interface_language_pack"
import "modus:disk_process"
import "modustool:build"
import "modustool:cache_server"
import "modustool:foundation"
import "modus:text_rendering"
import "modustool:resources"

// The script font set on a machine (src/md/features/script_fonts.md): two
// machines of the main volume, whose boot image names the set by its hash
// (the resource script_fonts_name), each with a data disk whose store
// script_fonts of the machine holds the object script_fonts.
//
//   1. The object is the set that the build wrote. When the machine is
//      usable, the root service reads it through disk_processes, checks
//      its hash and its form, and maps it; interface_font, started after,
//      draws a line of Hebrew, Arabic, Thai, Devanagari, ideographs, an emoji and a
//      geometric shape with no replacement glyph, each base glyph with ink.
//      interface_font draws by hand, with no drawing module, and compiles
//      the fast part of the text only: the library module text_rendering
//      shapes that line and holds each font of the set.
//   2. The object has one changed byte: the root service refuses it by
//      its hash, maps nothing, and interface_font says that no set is
//      mapped: the box stays, and nothing faults.
//   3. The object is one block past SCRIPT_FONTS_BYTES_LIMIT (64 MiB): the
//      root service refuses it by its size, before a byte of it is lent,
//      and maps nothing.
//
// Then four machines of the volume plan_and_audit, whose image alone holds
// the test modules script_fonts_planner, script_fonts_cut_planner and
// script_fonts_writer. A planner names, in a plan of principal 0, a set
// that is not the set of the image: the font outlines of the boot image,
// which have the form of a set, whole or less their last 8 bytes. The
// tool writes the same bytes as the object of the disk.
//
//   4. The object is the font outlines; the set of the image is refused
//      by its hash. script_fonts_planner applies its plan, the principal
//      accepts it, and the root service says that the set holds at the
//      next start.
//   5. The same disk: the root service reads the set that the plan names,
//      checks it and maps it. script_fonts_writer writes to it, and the
//      kernel stops it on a page fault at the first byte of the set.
//   6. The object is the cut font outlines, and script_fonts_cut_planner
//      names them, as in 4.
//   7. The same disk: the hash of the object is the hash that the plan
//      names, and the root service refuses its form: its header gives
//      another size. Nothing is mapped.
//
// Then two machines of the main volume on a data disk that holds module_files
// with visitor and no script_fonts store (script_fonts_cache_fetch_run):
//
//   8. Principal 0 applies a plan setting root.script_fonts_cache_key and
//      root.script_fonts_manifest_hash to a local host QUIC object cache.
//   9. The host QUIC object cache holds the 21-font script font set open while
//      root fetches it through disk_processes; console runs
//      start_from_disk("visitor", <hash>) and verifies the busy refusal from
//      root and console with no start; Release_Cache_Hold releases the object
//      cache hold so root verifies, maps, and caches the 21-font set,
//      interface_font draws every script with no replacement glyph, and a
//      second start_from_disk("visitor", <hash>) then starts visitor cleanly.
//
// The main machine holds no set: its interface_font says so
// (main_scenario.odin).

TEST_OUTPUT_SCRIPT_FONTS :: foundation.BUILD_FOLDER + "/test_output_script_fonts_%d.txt"
TEST_DISK_SCRIPT_FONTS :: foundation.BUILD_FOLDER + "/test_disk_script_fonts.img"
// The set of today is about 40 MB, and the object of the third machine 64
// MiB and one block: the disk holds either, the blocks of its tree and
// room.
SCRIPT_FONTS_DISK_SIZE :: 96 << 20

@(private = "file")
script_fonts_disk_write :: proc(set: []u8) -> bool {
	objects := [?]build.Module_File{{font_outlines.SCRIPT_FONTS_OBJECT_NAME, set}}
	image := build.data_disk_encode({name = font_outlines.SCRIPT_FONTS_STORE_NAME, limit = font_outlines.SCRIPT_FONTS_STORE_BLOCKS, objects = objects[:]}, SCRIPT_FONTS_DISK_SIZE) or_return
	defer delete(image)
	if err := os.write_entire_file(TEST_DISK_SCRIPT_FONTS, image); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", TEST_DISK_SCRIPT_FONTS, err)
		return false
	}
	return true
}

@(private = "file")
script_fonts_read_owned :: proc(path: string) -> (data: []u8, ok: bool) {
	err: os.Error
	data, err = os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", path, err)
		return nil, false
	}
	return data, true
}

// script_fonts_owned formats a step string on the heap and tracks it so
// scenario_run's per-step free_all(context.temp_allocator) never frees step
// text or hashes still needed by later steps or machines.
@(private = "file")
script_fonts_owned :: proc(owned: ^[dynamic]string, format: string, args: ..any) -> string {
	text := fmt.aprintf(format, ..args)
	append(owned, text)
	return text
}

@(private = "file")
script_fonts_free_owned :: proc(owned: ^[dynamic]string) {
	for text in owned {
		delete(text)
	}
	delete(owned^)
}

script_fonts_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	owned: [dynamic]string
	defer script_fonts_free_owned(&owned)

	// The set that the build wrote, and whose hash the boot image names.
	// Heap-owned because machine_test frees context.temp_allocator after each
	// step.
	set := script_fonts_read_owned(resources.SCRIPT_FONTS_OUTPUT) or_return
	defer delete(set)
	named := script_fonts_read_owned(resources.SCRIPT_FONTS_NAME_OUTPUT) or_return
	defer delete(named)
	if len(named) != 32 {
		fmt.eprintfln("modustool: test failed: %s holds %d bytes, not one hash", resources.SCRIPT_FONTS_NAME_OUTPUT, len(named))
		return false
	}
	hash: [32]u8
	copy(hash[:], named)
	digits := script_fonts_owned(&owned, "%s", resources.hash_digits(hash))

	// 1. The set: mapped, and drawn with no replacement glyph.
	script_fonts_disk_write(set) or_return
	fmt.printfln("modustool: %s: the store %s holds the script font set, %d bytes, hash %s", TEST_DISK_SCRIPT_FONTS, font_outlines.SCRIPT_FONTS_STORE_NAME, len(set), digits)
	mapped := [?]Step {
		{kind = .Wait, text = "storage: ok, generation 2: 1 stores, 1 objects", any_order = true},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: the boot image names the script font set %s", digits), any_order = true},
		{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: reads the script font set %s from the store script_fonts of the machine", digits)},
		{kind = .Wait, text = "21 fonts) is checked: each process that starts from now maps it, read-only", fails_on = "root: the script font set was not read"},
		{kind = .Launch, text = "interface_font"},
		{kind = .Wait, text = "interface_font: 2 characters that no font of the chain has draw the replacement glyph: as it must", fails_on = "interface_font: the fallback chain of the interface is wrong: "},
		{kind = .Wait, text = "interface_font: the line of Hebrew, Arabic, Thai, Devanagari, the ideographs, an emoji and a geometric shape draws ", fails_on = "interface_font: the script font set is mapped, and the character "},
		// interface_font draws its window by hand, with the fast part of the
		// text only: the library module shaped the line and drew its glyphs
		// of the set from their outlines.
		{kind = .Wait, text = script_fonts_owned(&owned, "interface_font: the library module text_rendering shaped the line and holds the %d fonts of the set", card(text_rendering.SCRIPT_FONTS)), fails_on = "interface_font: WRONG: the font "},
		{kind = .Wait, text = "interface_font: ok, ", any_order = true},
		{kind = .Shot, text = "interface_font_script_fonts"},
		{kind = .Front, text = "console"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "kernel: the machine stops with code 0"},
	}
	machine_test(part, mapped[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_SCRIPT_FONTS, 1), exit_status = build.MACHINE_STOP_OK, data_disk = TEST_DISK_SCRIPT_FONTS}) or_return
	foundation.test_passed_print("the root service read the script font set %s from the disk, checked it and mapped it, and interface_font drew Hebrew, Arabic, Thai, Devanagari, the ideographs, an emoji and a geometric shape with no replacement glyph", digits)

	// 2. One changed byte: refused by its hash, and the box stays.
	changed := make([]u8, len(set))
	defer delete(changed)
	copy(changed, set)
	changed[len(changed) / 2] ~= 1
	script_fonts_disk_write(changed) or_return
	refused := [?]Step {
		{kind = .Wait, text = "storage: ok, generation 2: 1 stores, 1 objects", any_order = true},
		{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: reads the script font set %s from the store script_fonts of the machine", digits)},
		{kind = .Wait, text = "root: refused script_fonts from the disk: its bytes have the hash ", fails_on = " fonts) is checked: each process that starts from now maps it"},
		{kind = .Wait, text = "root: the script font set was not read: Argument_Refused:"},
		{kind = .Launch, text = "interface_font"},
		{kind = .Wait, text = "interface_font: no script font set is mapped: the line of Hebrew, Arabic, Thai, Devanagari, the ideographs and an emoji draws the replacement glyph", fails_on = "interface_font: the line of Hebrew, Arabic, Thai, Devanagari, the ideographs, an emoji and a geometric shape draws "},
		{kind = .Wait, text = "interface_font: ok, ", any_order = true},
		{kind = .Front, text = "console"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "kernel: the machine stops with code 0"},
	}
	machine_test(part, refused[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_SCRIPT_FONTS, 2), exit_status = build.MACHINE_STOP_OK, data_disk = TEST_DISK_SCRIPT_FONTS}) or_return
	foundation.test_passed_print("a script font set with one changed byte was refused by its hash: no set was mapped, and interface_font drew the replacement glyph for those scripts")

	// 3. An object one block past the bound of a set: refused by its size.
	large := make([]u8, font_outlines.SCRIPT_FONTS_BYTES_LIMIT + 4096)
	defer delete(large)
	script_fonts_disk_write(large) or_return
	too_large := [?]Step {
		{kind = .Wait, text = "storage: ok, generation 2: 1 stores, 1 objects", any_order = true},
		{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: reads the script font set %s from the store script_fonts of the machine", digits)},
		{kind = .Wait, text = "root: refused the script font set: the object has ", fails_on = " fonts) is checked: each process that starts from now maps it"},
		{kind = .Wait, text = "root: the script font set was not read: Data_Damaged:"},
		{kind = .Front, text = "console"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "kernel: the machine stops with code 0"},
	}
	machine_test(part, too_large[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_SCRIPT_FONTS, 3), exit_status = build.MACHINE_STOP_OK, data_disk = TEST_DISK_SCRIPT_FONTS}) or_return
	foundation.test_passed_print("an object of %d bytes, one block past the bound of a script font set, was refused by its size: no set was mapped", len(large))

	outlines := script_fonts_read_owned(resources.FONT_OUTLINES_OUTPUT) or_return
	defer delete(outlines)
	script_fonts_planned_run(part, digits, outlines, false) or_return
	script_fonts_planned_run(part, digits, outlines[:len(outlines) - SCRIPT_FONTS_CUT_BYTES], true) or_return
	return script_fonts_cache_fetch_run(part, set, hash, digits)
}

// Deterministic test-only Ed25519 seed for the ephemeral local QUIC cache
// bound to 127.0.0.1:0 during script_fonts_cache_fetch_run.
@(private = "file")
script_fonts_cache_seed :: proc() -> (seed: [32]u8) {
	for i in 0 ..< 32 {
		seed[i] = 0x57 + u8(i * 17 + 3)
	}
	return seed
}

// script_fonts_cache_fetch_run proves live QUIC object-cache fetch wiring and
// deterministic busy refusal for script fonts on a machine whose local data
// disk holds module_files with visitor and no script_fonts store:
//   - starts an ephemeral local host QUIC object cache seeded with the 21-font
//     script_fonts.bin blob and a MODSFP01 Script_Font_Pack_Manifest pointing
//     every script entry to it;
//   - Machine 8 (module_files disk with visitor, no script_fonts store):
//     principal 0 applies a plan setting root.script_fonts_cache_key and
//     root.script_fonts_manifest_hash;
//   - Machine 9 (same data disk, with cache_endpoint and cache_running wired,
//     and set_hash held open on the host QUIC cache server): root fetches and
//     resolves the MODSFP01 manifest, then begins fetching set_hash so
//     disk_load_running() is deterministically true; console runs
//     start_from_disk("visitor", <hash>) and receives the busy refusal without
//     starting visitor; Release_Cache_Hold releases set_hash so root verifies
//     the 21-font set, maps it read-only, and caches it on disk;
//     interface_font renders all scripts with zero replacement glyphs; then
//     start_from_disk("visitor", <hash>) runs again and visitor starts cleanly.
script_fonts_cache_fetch_run :: proc(part: ^Test_Part_Run, set: []u8, set_hash: blake3.Hash, set_digits: string) -> bool {
	owned: [dynamic]string
	defer script_fonts_free_owned(&owned)

	visitor_file := script_fonts_read_owned(foundation.module_path(foundation.DISK_MODULE_NAME)) or_return
	defer delete(visitor_file)
	visitor_hash := blake3.hash(visitor_file)
	visitor_digits := script_fonts_owned(&owned, "%s", resources.hash_digits(visitor_hash))

	work_dir := fmt.aprintf("%s/script_fonts_cache_%d", foundation.BUILD_FOLDER, os.get_pid())
	defer {
		_ = os.remove_all(work_dir)
		delete(work_dir)
	}
	if !foundation.reset_folder(work_dir) {
		fmt.eprintfln("modustool: script_fonts_cache_fetch_run: cannot prepare %s", work_dir)
		return false
	}

	// Build a valid MODSFP01 Script_Font_Pack_Manifest mapping every extra
	// script to the single deduplicated script font set hash and exact size.
	manifest: ilp.Script_Font_Pack_Manifest
	manifest.unicode_version = 16
	scripts := [?]ilp.Script_Code{.Hebrew, .Arabic, .Devanagari, .Thai, .Han_Cjk, .Emoji, .Symbols}
	manifest.entry_count = u32(len(scripts))
	for sc, index in scripts {
		manifest.entries[index] = {
			script      = sc,
			object_hash = set_hash,
			byte_size   = u64(len(set)),
		}
	}
	manifest_buf: [ilp.PACK_MANIFEST_HEADER_SIZE + ilp.SCRIPT_FONT_ENTRY_LIMIT * ilp.SCRIPT_FONT_ENTRY_SIZE]u8
	manifest_written, manifest_refusal := ilp.script_font_manifest_encode(&manifest, manifest_buf[:])
	if manifest_refusal != .None {
		fmt.eprintfln("modustool: script_fonts_cache_fetch_run: manifest encode failed: %v", manifest_refusal)
		return false
	}
	manifest_bytes := manifest_buf[:manifest_written]
	manifest_hash := blake3.hash(manifest_bytes)
	manifest_digits := script_fonts_owned(&owned, "%s", resources.hash_digits(manifest_hash))

	cache_dir := foundation.join(work_dir, "/cache")
	server, opened := cache_server.cache_server_open(cache_dir, nil)
	if !opened {
		fmt.eprintln("modustool: script_fonts_cache_fetch_run: cannot open local cache server")
		return false
	}
	defer cache_server.cache_server_destroy(&server)

	if ok, _ := cache_server.store_write_atomic(&server, .Objects, set_digits, set); !ok {
		fmt.eprintln("modustool: script_fonts_cache_fetch_run: cannot seed script font set in cache")
		return false
	}
	if ok, _ := cache_server.store_write_atomic(&server, .Objects, manifest_digits, manifest_bytes); !ok {
		fmt.eprintln("modustool: script_fonts_cache_fetch_run: cannot seed script font manifest in cache")
		return false
	}

	running, quic_err := cache_server.cache_quic_start(&server, net.Endpoint{address = net.IP4_Loopback, port = 0}, script_fonts_cache_seed())
	if quic_err != "" || running == nil {
		fmt.eprintfln("modustool: script_fonts_cache_fetch_run: cannot start local QUIC cache: %s", quic_err)
		return false
	}
	defer cache_server.cache_quic_stop(running)

	server_key_digits := script_fonts_owned(&owned, "%s", resources.hash_digits(running.public_key))
	cache_disk := script_fonts_owned(&owned, "%s/script_fonts_cache_disk.img", work_dir)
	visitor_objects := [?]build.Module_File{{foundation.DISK_MODULE_NAME, visitor_file}}
	cache_disk_image := build.data_disk_encode({name = disk_process.STORE_NAME, limit = disk_process.STORE_BLOCKS_LIMIT, objects = visitor_objects[:]}, SCRIPT_FONTS_DISK_SIZE) or_return
	defer delete(cache_disk_image)
	if write_err := os.write_entire_file(cache_disk, cache_disk_image); write_err != nil {
		fmt.eprintfln("modustool: script_fonts_cache_fetch_run: cannot write %s: %v", cache_disk, write_err)
		return false
	}

	// 8. Data disk holding module_files/visitor and no script_fonts store:
	// principal 0 applies the plan configuring root.script_fonts_cache_key and
	// root.script_fonts_manifest_hash.
	apply_line := strings.concatenate({
		`plans.apply("script fonts cache", plan { values = { root = { script_fonts_cache_key = "`,
		server_key_digits,
		`", script_fonts_manifest_hash = "`,
		manifest_digits,
		`" } } })`,
	})
	append(&owned, apply_line)
	configure := [?]Step {
		{kind = .Wait, text = "storage: ok, generation 2: 1 stores, 1 objects", any_order = true},
		{kind = .Wait, text = "root: the data disk holds no script font set ", any_order = true},
		{kind = .Wait, text = "display: console" + WINDOW_TAKEN},
		{kind = .Front, text = "console"},
		{kind = .Type, text = apply_line},
		{kind = .Wait, text = "compositor: the difference of the plan script fonts cache shows: "},
		{kind = .Key, text = "tab"},
		{kind = .Key_Again_Until, text = "ret", expected = "compositor: the difference of the plan script fonts cache is accepted", fails_on = "compositor: the difference of the plan script fonts cache is refused"},
		{kind = .Wait, text = "plans: applied generation 1 for principal 0", any_order = true},
		{kind = .Wait, text = " of Plan_Generation_Row"},
		{kind = .Front, text = "console"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "kernel: the machine stops with code 0"},
	}
	machine_test(part, configure[:], {
		volume      = build.BOOT_VOLUME,
		output      = self_test_file(TEST_OUTPUT_SCRIPT_FONTS, 8),
		exit_status = build.MACHINE_STOP_OK,
		data_disk   = cache_disk,
	}) or_return

	// 9. Same data disk (still no script_fonts object on disk), now with the
	// local QUIC object cache attached and set_hash deterministically held
	// open: root fetches and resolves the manifest, begins fetching the
	// 21-font set, refuses start_from_disk("visitor", <hash>) as busy while
	// the fetch stays open, resumes after Release_Cache_Hold, verifies and
	// maps the 21-font set, caches it on disk, draws every script through
	// interface_font, and then starts visitor cleanly from module_files.
	cache_server.cache_quic_hold_object(running, set_hash)
	defer cache_server.cache_quic_release_object(running)

	start_visitor_line := script_fonts_owned(&owned, `start_from_disk("%s", "%s")`, foundation.DISK_MODULE_NAME, visitor_digits)
	fetched := [?]Step {
		{kind = .Wait, text = "storage: ok, generation ", any_order = true},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: the plan of principal 0 names the script font manifest %s", manifest_digits), any_order = true},
		{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: fetches the script font set %s from the object cache", manifest_digits), fails_on = "root: the object cache did not provide the script font set"},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: the script font manifest %s names the script font set %s (", manifest_digits, set_digits), fails_on = "root: the script font manifest is refused"},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: fetches the script font set %s from the object cache", set_digits), fails_on = "root: the object cache did not provide the script font set"},
		// set_hash is held open on the host QUIC cache server, so
		// disk_load_running() stays true in root until Release_Cache_Hold.
		{kind = .Type, text = start_visitor_line},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: refused %s from the disk: another load from the disk runs", foundation.DISK_MODULE_NAME), fails_on = script_fonts_owned(&owned, "root: started %s from the disk", foundation.DISK_MODULE_NAME)},
		{kind = .Wait, text = "[console] error: start_from_disk: another load from the disk runs: try again after it", fails_on = "visitor: ok, a module that the boot image does not hold"},
		{kind = .Release_Cache_Hold},
		{kind = .Wait, text = "21 fonts) is checked: each process that starts from now maps it, read-only", fails_on = "root: the object cache did not provide the script font set"},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: cached the script font set %s (", set_digits), fails_on = "root: the fetched script font set stays in memory"},
		{kind = .Launch, text = "interface_font"},
		{kind = .Wait, text = "interface_font: 2 characters that no font of the chain has draw the replacement glyph: as it must", fails_on = "interface_font: the fallback chain of the interface is wrong: "},
		{kind = .Wait, text = "interface_font: the line of Hebrew, Arabic, Thai, Devanagari, the ideographs, an emoji and a geometric shape draws ", fails_on = "interface_font: the script font set is mapped, and the character "},
		{kind = .Wait, text = script_fonts_owned(&owned, "interface_font: the library module text_rendering shaped the line and holds the %d fonts of the set", card(text_rendering.SCRIPT_FONTS)), fails_on = "interface_font: WRONG: the font "},
		{kind = .Wait, text = "interface_font: ok, ", any_order = true},
		// With the script font fetch and disk persistence done, the same
		// start_from_disk succeeds and visitor runs cleanly.
		{kind = .Front, text = "console"},
		{kind = .Type, text = start_visitor_line},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: reads %s from the store module_files of the storage service, for principal 0", foundation.DISK_MODULE_NAME), fails_on = script_fonts_owned(&owned, "root: refused %s from the disk:", foundation.DISK_MODULE_NAME)},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: started %s from the disk, hash %s", foundation.DISK_MODULE_NAME, visitor_digits), any_order = true},
		{kind = .Wait, text = "visitor: ok, a module that the boot image does not hold"},
		{kind = .Type, text = script_fonts_owned(&owned, `stop("%s")`, foundation.DISK_MODULE_NAME)},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: %s stopped: ", foundation.DISK_MODULE_NAME)},
		{kind = .Front, text = "console"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "kernel: the machine stops with code 0"},
	}
	machine_test(part, fetched[:], {
		volume         = build.BOOT_VOLUME,
		output         = self_test_file(TEST_OUTPUT_SCRIPT_FONTS, 9),
		exit_status    = build.MACHINE_STOP_OK,
		data_disk      = cache_disk,
		cache_endpoint = running.bound_endpoint,
		cache_running  = running,
	}) or_return
	foundation.test_passed_print("root held script font fetch %s open, refused start_from_disk(visitor) as busy, then fetched, verified, mapped, and cached the 21-font set after release and started visitor cleanly", set_digits)
	return true
}

// The bytes that script_fonts_cut_planner cuts from the font outlines
// (src/modules/tests/script_fonts_planner, CUT_BYTES).
SCRIPT_FONTS_CUT_BYTES :: 8

// script_fonts_planned_run runs two machines on a disk whose object is set:
// the first applies the plan that names it, the second reads it. A whole
// set is mapped, and its writer faults; a cut set is refused by its form.
@(private = "file")
script_fonts_planned_run :: proc(part: ^Test_Part_Run, image_digits: string, set: []u8, cut: bool) -> bool {
	owned: [dynamic]string
	defer script_fonts_free_owned(&owned)

	digits := script_fonts_owned(&owned, "%s", resources.hash_digits(blake3.hash(set)))
	planner := cut ? "script_fonts_cut_planner" : "script_fonts_planner"
	plan := cut ? "the cut font outlines" : "the font outlines"
	first_number := cut ? 6 : 4
	script_fonts_disk_write(set) or_return
	fmt.printfln("modustool: %s: the store %s holds %s, %d bytes, hash %s", TEST_DISK_SCRIPT_FONTS, font_outlines.SCRIPT_FONTS_STORE_NAME, plan, len(set), digits)
	wrong := script_fonts_owned(&owned, "%s: WRONG", planner)
	planned := [?]Step {
		{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: reads the script font set %s from the store script_fonts of the machine", image_digits)},
		{kind = .Wait, text = "root: refused script_fonts from the disk: its bytes have the hash ", fails_on = " fonts) is checked: each process that starts from now maps it"},
		{kind = .Type, text = script_fonts_owned(&owned, "start(\"%s\")", planner)},
		{kind = .Wait, text = script_fonts_owned(&owned, "script_fonts_planner: names the script font set %s, ", digits), fails_on = wrong},
		{kind = .Wait, text = script_fonts_owned(&owned, "compositor: the difference of the plan %s shows: 1 added, 0 removed", plan), any_order = true},
		{kind = .Wait, text = script_fonts_owned(&owned, "script_fonts_planner: the dialog of the plan %s takes the decision of the principal now", plan), fails_on = wrong},
		{kind = .Key, text = "tab"},
		{kind = .Key, text = "ret"},
		{kind = .Wait, text = script_fonts_owned(&owned, "compositor: the difference of the plan %s is accepted", plan), fails_on = script_fonts_owned(&owned, "compositor: the difference of the plan %s is refused", plan)},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: the plan of principal 0 names the script font set %s: it holds at the next start of the machine", digits), any_order = true},
		{kind = .Wait, text = script_fonts_owned(&owned, "script_fonts_planner: the principal accepted the plan: generation 1, which names the script font set %s", digits), fails_on = wrong},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: %s stopped: itself, done", planner)},
		{kind = .Front, text = "console"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "kernel: the machine stops with code 0"},
	}
	machine_test(part, planned[:], {volume = build.BOOT_VOLUME_PLAN_AND_AUDIT, output = self_test_file(TEST_OUTPUT_SCRIPT_FONTS, first_number), exit_status = build.MACHINE_STOP_OK, data_disk = TEST_DISK_SCRIPT_FONTS}) or_return
	foundation.test_passed_print("%s applied a plan of principal 0 that names %s, %s, and the root service took it for the next start", planner, plan, digits)

	reading := [?]Step {
		{kind = .Wait, text = script_fonts_owned(&owned, "root: the plan of principal 0 names the script font set %s", digits), any_order = true},
		{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
		{kind = .Wait, text = script_fonts_owned(&owned, "root: reads the script font set %s from the store script_fonts of the machine", digits)},
	}
	read: [dynamic]Step
	defer delete(read)
	append(&read, ..reading[:])
	if cut {
		refused := [?]Step {
			{kind = .Wait, text = script_fonts_owned(&owned, "root: the script font set is refused: %s, value %d", font_outlines.problem_sentences[.Bad_Size], len(set) + SCRIPT_FONTS_CUT_BYTES), fails_on = " fonts) is checked: each process that starts from now maps it"},
		}
		append(&read, ..refused[:])
	} else {
		writer_fault := script_fonts_owned(&owned, " address %016x, in module ", fixed_addresses.SCRIPT_FONTS_ADDRESS)
		mapped := [?]Step {
			{kind = .Wait, text = script_fonts_owned(&owned, "root: the script font set %s (", digits), fails_on = "root: the script font set was not read"},
			{kind = .Type, text = "start(\"script_fonts_writer\")"},
			{kind = .Wait, text = script_fonts_owned(&owned, "script_fonts_writer: writes the byte at %016x, the first of the script font set", fixed_addresses.SCRIPT_FONTS_ADDRESS), fails_on = "script_fonts_writer: WRONG"},
			// The line of the kernel names the process, then the address of
			// the fault: the next wait searches the same line.
			{kind = .Wait, text = "kernel: process script_fonts_writer stopped: page fault vector 14 ", any_order = true, fails_on = "script_fonts_writer: WRONG"},
			{kind = .Wait, text = writer_fault, fails_on = "script_fonts_writer: WRONG"},
			{kind = .Wait, text = "root: script_fonts_writer stopped: "},
		}
		append(&read, ..mapped[:])
	}
	ending := [?]Step {
		{kind = .Front, text = "console"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "kernel: the machine stops with code 0"},
	}
	append(&read, ..ending[:])
	machine_test(part, read[:], {volume = build.BOOT_VOLUME_PLAN_AND_AUDIT, output = self_test_file(TEST_OUTPUT_SCRIPT_FONTS, first_number + 1), exit_status = build.MACHINE_STOP_OK, data_disk = TEST_DISK_SCRIPT_FONTS}) or_return
	if cut {
		foundation.test_passed_print("the next start read %s, whose hash the plan names, and refused its form: no set was mapped", plan)
	} else {
		foundation.test_passed_print("the next start read and mapped %s, which the plan names, and script_fonts_writer stopped on a page fault at its first byte", plan)
	}
	return true
}

// A binary of the tool runs the test part script_fonts only when it holds
// this file (test_parts.odin, test_part_scenario_register).
@(init)
script_fonts_test_part_register :: proc "contextless" () {
	test_part_scenario_register("script_fonts", script_fonts_tests_run)
}
