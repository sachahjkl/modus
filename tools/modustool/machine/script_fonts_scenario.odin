package machine

import "core:fmt"
import "core:os"
import "modus:contract/font_outlines"
import "modustool:build"
import "modustool:foundation"
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
//   2. The object has one changed byte: the root service refuses it by
//      its hash, maps nothing, and interface_font says that no set is
//      mapped: the box stays, and nothing faults.
//
// The main machine holds no set: its interface_font says so
// (main_scenario.odin).

TEST_OUTPUT_SCRIPT_FONTS :: foundation.BUILD_FOLDER + "/test_output_script_fonts_%d.txt"
TEST_DISK_SCRIPT_FONTS :: foundation.BUILD_FOLDER + "/test_disk_script_fonts.img"
// The set of today is 35.8 MB: the disk holds it, the blocks of its tree
// and room.
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

script_fonts_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	// The set that the build wrote, and whose hash the boot image names.
	set := foundation.read_file(resources.SCRIPT_FONTS_OUTPUT) or_return
	named := foundation.read_file(resources.SCRIPT_FONTS_NAME_OUTPUT) or_return
	if len(named) != 32 {
		fmt.eprintfln("modustool: test failed: %s holds %d bytes, not one hash", resources.SCRIPT_FONTS_NAME_OUTPUT, len(named))
		return false
	}
	hash: [32]u8
	copy(hash[:], named)
	digits := resources.hash_digits(hash)

	// 1. The set: mapped, and drawn with no replacement glyph.
	script_fonts_disk_write(set) or_return
	fmt.printfln("modustool: %s: the store %s holds the script font set, %d bytes, hash %s", TEST_DISK_SCRIPT_FONTS, font_outlines.SCRIPT_FONTS_STORE_NAME, len(set), digits)
	mapped := [?]Step {
		{kind = .Wait, text = "storage: ok, generation 2: 1 stores, 1 objects", any_order = true},
		{kind = .Wait, text = fmt.tprintf("root: the boot image names the script font set %s", digits), any_order = true},
		{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
		{kind = .Wait, text = fmt.tprintf("root: reads the script font set %s from the store script_fonts of the machine", digits)},
		{kind = .Wait, text = "7 fonts) is checked: each process that starts from now maps it, read-only", fails_on = "root: the script font set was not read"},
		{kind = .Launch, text = "interface_font"},
		{kind = .Wait, text = "interface_font: 2 characters that no font of the chain has draw the replacement glyph: as it must", fails_on = "interface_font: the fallback chain of the interface is wrong: "},
		{kind = .Wait, text = "interface_font: the line of Hebrew, Arabic, Thai, Devanagari, the ideographs, an emoji and a geometric shape draws ", fails_on = "interface_font: the script font set is mapped, and the character "},
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
		{kind = .Wait, text = fmt.tprintf("root: reads the script font set %s from the store script_fonts of the machine", digits)},
		{kind = .Wait, text = fmt.tprintf("root: refused script_fonts from the disk: its bytes have the hash "), fails_on = " fonts) is checked: each process that starts from now maps it"},
		{kind = .Wait, text = "root: the script font set was not read: status "},
		{kind = .Launch, text = "interface_font"},
		{kind = .Wait, text = "interface_font: no script font set is mapped: the line of Hebrew, Arabic, Thai, Devanagari, the ideographs and an emoji draws the replacement glyph", fails_on = "interface_font: the line of Hebrew, Arabic, Thai, Devanagari, the ideographs, an emoji and a geometric shape draws "},
		{kind = .Wait, text = "interface_font: ok, ", any_order = true},
		{kind = .Front, text = "console"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "kernel: the machine stops with code 0"},
	}
	machine_test(part, refused[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_SCRIPT_FONTS, 2), exit_status = build.MACHINE_STOP_OK, data_disk = TEST_DISK_SCRIPT_FONTS}) or_return
	foundation.test_passed_print("a script font set with one changed byte was refused by its hash: no set was mapped, and interface_font drew the replacement glyph for those scripts")
	return true
}

// A binary of the tool runs the test part script_fonts only when it holds
// this file (test_parts.odin, test_part_scenario_register).
@(init)
script_fonts_test_part_register :: proc "contextless" () {
	test_part_scenario_register("script_fonts", script_fonts_tests_run)
}
