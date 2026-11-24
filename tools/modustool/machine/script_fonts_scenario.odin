package machine

import "core:fmt"
import "core:os"
import "modus:contract/blake3"
import "modus:contract/fixed_addresses"
import "modus:contract/font_outlines"
import "modustool:build"
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
// A start from the disk refused as busy during the read of the set has no
// case: the test would have to place the start inside the read, and the
// time of the read depends on the speed of the host.
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
	return script_fonts_planned_run(part, digits, outlines[:len(outlines) - SCRIPT_FONTS_CUT_BYTES], true)
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
