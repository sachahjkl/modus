package build

import "modus:contract/blake3"
import "modus:contract/system_description"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The table of the boot volumes: 20 fixed volumes and one for each test of
// the kernel on itself, each with its own name and its own files.
@(test)
boot_volume_table_gives_each_volume_its_own_files :: proc(t: ^testing.T) {
	volumes := boot_volumes()
	testing.expect_value(t, len(volumes), 20 + len(self_tests))
	testing.expect_value(t, len(volumes), 27)
	// The volumes of the TPM floors are signed for Secure Boot: only a start
	// with the PCR 7 of Secure Boot raises a floor. The newer key differs
	// from the newer system by its key number alone.
	for volume in volumes {
		if volume.path == BOOT_VOLUME_NEWER_SYSTEM || volume.path == BOOT_VOLUME_NEWER_KEY {
			testing.expect_value(t, volume.firmware_signature, Firmware_Signature.Signed)
			testing.expect_value(t, volume.change.security_version_raised, 1)
			testing.expect_value(t, volume.key_number_raised, volume.path == BOOT_VOLUME_NEWER_KEY ? 1 : 0)
		} else {
			testing.expect_value(t, volume.change.security_version_raised, 0)
			testing.expect_value(t, volume.key_number_raised, 0)
		}
		// The boot program of a raised key number holds a key file of its
		// volume; every other holds the key file of the build.
		if volume.key_number_raised != 0 {
			testing.expect(t, strings.contains(boot_volume_system_key_path(volume), boot_volume_name(volume.path)), "the raised key file has the name of its volume")
		} else {
			testing.expect_value(t, boot_volume_system_key_path(volume), SYSTEM_KEY_FILE)
		}
	}
	// The machines of the TPM start the other system with Secure Boot on:
	// its boot program is signed, and its boot image is the main one, so
	// its root service keeps the rule of the seal.
	for volume in volumes {
		if volume.path == BOOT_VOLUME_OTHER_SYSTEM {
			testing.expect_value(t, volume.firmware_signature, Firmware_Signature.Signed)
			testing.expect_value(t, volume.image, BOOT_IMAGE)
		}
	}
	files := make([dynamic]string, context.temp_allocator)
	main_found := false
	for volume in volumes {
		testing.expectf(t, strings.has_prefix(volume.path, foundation.BUILD_FOLDER + "/boot_volume") && strings.has_suffix(volume.path, ".img"), "%s is a volume file of the build folder", volume.path)
		if volume.path == BOOT_VOLUME {
			main_found = true
			testing.expect_value(t, boot_volume_name(volume.path), MAIN_BOOT_VOLUME_NAME)
			testing.expect_value(t, boot_volume_program_path(volume), BOOT_PROGRAM)
			testing.expect_value(t, boot_volume_object_path(volume), BOOT_PROGRAM_OBJECT)
		}
		// What only this volume writes: its folder, its record, the list of
		// its compiler, and each recorded output.
		append(&files, boot_volume_name(volume.path), boot_volume_folder(volume), boot_volume_record_path(volume), boot_volume_dependency_file(volume), boot_volume_program_path(volume), boot_volume_object_path(volume), boot_volume_signed_program_path(volume))
		append(&files, ..boot_volume_recorded_outputs(volume))
		if volume.key_number_raised != 0 {
			append(&files, boot_volume_system_key_path(volume))
		}
		// The kernel module that the build key names is the module of the
		// table, or the changed copy of this volume.
		if volume.change.kernel_changed_after_description || volume.change.kernel_memory_raised {
			testing.expect(t, strings.contains(boot_volume_kernel_module_path(volume), boot_volume_name(volume.path)), "the changed kernel has the name of its volume")
			testing.expect(t, !(volume.change.kernel_changed_after_description && volume.change.kernel_memory_raised), "one volume changes its kernel in one way")
		} else {
			testing.expect_value(t, boot_volume_kernel_module_path(volume), foundation.module_path(volume.kernel))
		}
	}
	testing.expect(t, main_found, "the main boot volume is in the table")
	for file, index in files {
		for other in files[index + 1:] {
			testing.expectf(t, file != other, "%s belongs to one volume only", file)
		}
	}
	testing.expect_value(t, boot_volume_name(foundation.BUILD_FOLDER + "/boot_volume_self_test_3.img"), "self_test_3")
	testing.expect_value(t, boot_volume_name(BOOT_VOLUME_SHORTAGE), "shortage")
	testing.expect_value(t, boot_volume_name(BOOT_VOLUME_MEASURE), "measure")
	// The volume of a measure run has its own boot image.
	for volume in volumes {
		testing.expectf(t, (volume.path == BOOT_VOLUME_MEASURE) == (volume.image == BOOT_IMAGE_MEASURE), "only the volume of a measure run holds the boot image of a measure run: %s", volume.path)
	}
	// The variable store of Secure Boot is an output of one volume.
	stores := 0
	for volume in volumes {
		if volume.with_secure_boot_variables {
			stores += 1
			testing.expect_value(t, volume.path, BOOT_VOLUME_SECURE_BOOT)
		}
	}
	testing.expect_value(t, stores, 1)
}

// A release ships no volume of a test: no kernel of a test, no raised key
// number, no raised security version, no other change, no test of the
// kernel on itself. The boot program has no setting for a test, so the
// release volume holds the key file of the build.
@(test)
a_release_ships_no_volume_of_a_test :: proc(t: ^testing.T) {
	release := release_boot_volume()
	testing.expect_value(t, boot_volume_release_problem(release), "")
	testing.expect_value(t, boot_volume_system_key_path(release), SYSTEM_KEY_FILE)
	// The counted kernel and the kernel with a check skipped, each as the
	// kernel of the release volume, with nothing else changed.
	for test_kernel in ([]string{foundation.KERNEL_EDGE_COUNTERS_MODULE, "kernel_without_return_check", "", "kernel "}) {
		with_test_kernel := release
		with_test_kernel.kernel = test_kernel
		testing.expectf(t, boot_volume_release_problem(with_test_kernel) != "", "the release volume with the kernel %s is refused", test_kernel)
	}
	counted_found := false
	for volume in boot_volumes() {
		if volume.path == BOOT_VOLUME_OPERATION_FUZZING {
			counted_found = true
			testing.expect_value(t, volume.kernel, foundation.KERNEL_EDGE_COUNTERS_MODULE)
			testing.expect(t, boot_volume_counts_kernel_edges(volume.path), "the volume of the fuzzing has a counted kernel")
		} else {
			testing.expectf(t, !boot_volume_counts_kernel_edges(volume.path), "only the volume of the fuzzing has a counted kernel, not %s", volume.path)
		}
		tested := volume.kernel != system_description.KERNEL_ENTRY_NAME || volume.key_number_raised != 0 || volume.change != (Image_Change{}) || volume.self_test != 0
		testing.expectf(t, (boot_volume_release_problem(volume) != "") == tested, "the release check of %s", volume.path)
		if volume.path == BOOT_VOLUME_NEWER_KEY || volume.path == BOOT_VOLUME_NEWER_SYSTEM {
			testing.expect(t, boot_volume_release_problem(volume) != "")
		}
		for flag in boot_program_compile_command(volume) {
			testing.expectf(t, !strings.contains(flag, "KEY_NUMBER"), "the boot program of %s has a setting of its key number: %s", volume.path, flag)
		}
	}
	testing.expect(t, counted_found, "the volume of the fuzzing is in the table")
}

// A small tree with the sources of a boot program, its assembly files and
// the test signing key, as the build key of a volume names them.
@(private = "file")
boot_tree_make :: proc(t: ^testing.T) -> (root: string) {
	folder, error := os.make_directory_temp("", "boot_volumes_test_*", context.temp_allocator)
	testing.expect_value(t, error, nil)
	for name in ([]string{foundation.SOURCE_FOLDER_BOOT, foundation.SOURCE_FOLDER_RUNTIME, "resources/keys"}) {
		_ = os.make_directory_all(fmt.tprintf("%s/%s", folder, name))
	}
	boot_tree_file_write(folder, foundation.SOURCE_FOLDER_BOOT + "/main.odin", "package boot\n\nefi_main :: proc() {}\n")
	boot_tree_file_write(folder, BOOT_PROGRAM_JUMP_SOURCE, "global jump\njump: ret\n")
	boot_tree_file_write(folder, RUNTIME_MEMORY, "global copy\ncopy: ret\n")
	boot_tree_file_write(folder, TEST_SIGNING_KEY_FILE, "00\n")
	boot_tree_file_write(folder, TEST_FIRMWARE_SIGNING_KEY_FILE, "a key\n")
	boot_tree_file_write(folder, TEST_FIRMWARE_CERTIFICATE_FILE, "a certificate\n")
	return folder
}

@(private = "file")
boot_tree_file_write :: proc(root, name, text: string) {
	_ = os.write_entire_file(fmt.tprintf("%s/%s", root, name), text)
}

@(private = "file")
hash_of_text :: proc(text: string) -> blake3.Hash {
	return blake3.hash(transmute([]u8)text)
}

// The built files that the volumes of the tests read, with the hash of a
// text in place of the hash of a file.
@(private = "file")
shared_inputs_of_a_test :: proc(image_content: string) -> Boot_Volume_Shared_Inputs {
	built_files := make([dynamic]Record_Output, context.temp_allocator)
	append(&built_files, Record_Output{path = BOOT_IMAGE, hash = hash_of_text(image_content)})
	append(&built_files, Record_Output{path = BOOT_IMAGE_SHORTAGE, hash = hash_of_text("the image of the shortage")})
	append(&built_files, Record_Output{path = BOOT_IMAGE_MEASURE, hash = hash_of_text("the image of a measure run")})
	append(&built_files, Record_Output{path = foundation.module_path("kernel"), hash = hash_of_text("the kernel")})
	append(&built_files, Record_Output{path = DEBUG_IMAGE, hash = hash_of_text("the debug image")})
	append(&built_files, Record_Output{path = SYSTEM_KEY_FILE, hash = hash_of_text("the public key")})
	settings := make([]string, 1, context.temp_allocator)
	settings[0] = "host program odin: /store/odin"
	return {settings = settings, built_files = built_files[:]}
}

@(private = "file")
boot_sources :: proc(root: string) -> []string {
	sources := make([]string, 1, context.temp_allocator)
	sources[0] = fmt.tprintf("%s/%s/main.odin", root, foundation.SOURCE_FOLDER_BOOT)
	return sources
}

// The key of a volume, with a new table: as a new build computes it.
@(private = "file")
volume_key_of_a_new_build :: proc(t: ^testing.T, root: string, volume: Boot_Volume, shared: Boot_Volume_Shared_Inputs) -> blake3.Hash {
	inputs, readable := boot_volume_key_inputs(volume, shared, boot_sources(root), nil)
	testing.expect(t, readable, "each built file of the volume has its hash")
	table := input_file_table_make(root, {foundation.SOURCE_FOLDER_BOOT})
	defer input_file_table_destroy(table)
	key, complete := build_key(inputs, table)
	testing.expect(t, complete, "each input of the tree can be read")
	return key
}

// The key of a volume changes with its boot image, its kernel, a flag of
// its compiler, what the volume is, a source of the boot program and an
// assembly file; two volumes never have the same key.
@(test)
boot_volume_key_changes_with_each_input :: proc(t: ^testing.T) {
	root := boot_tree_make(t)
	defer os.remove_all(root)
	main_volume := Boot_Volume{path = BOOT_VOLUME, image = BOOT_IMAGE, kernel = "kernel"}
	shared := shared_inputs_of_a_test("the boot image")
	first := volume_key_of_a_new_build(t, root, main_volume, shared)
	testing.expect_value(t, volume_key_of_a_new_build(t, root, main_volume, shared), first)

	testing.expect(t, volume_key_of_a_new_build(t, root, main_volume, shared_inputs_of_a_test("the boot image with one changed module")) != first, "another boot image changes the key")

	other_kernel := shared_inputs_of_a_test("the boot image")
	for &file in other_kernel.built_files {
		if file.path == foundation.module_path("kernel") {
			file.hash = hash_of_text("another kernel")
		}
	}
	testing.expect(t, volume_key_of_a_new_build(t, root, main_volume, other_kernel) != first, "another kernel changes the key")

	other_tool := shared
	other_tool.tool_identity[0] = 1
	testing.expect(t, volume_key_of_a_new_build(t, root, main_volume, other_tool) != first, "another identity of the tool changes the key")

	other_compiler := shared
	compiler_settings := make([]string, 1, context.temp_allocator)
	compiler_settings[0] = "host program odin: /store/another_odin"
	other_compiler.settings = compiler_settings
	testing.expect(t, volume_key_of_a_new_build(t, root, main_volume, other_compiler) != first, "another compiler changes the key")

	// The same volume file with the flag of a self test: one flag of the
	// compiler differs.
	with_self_test := main_volume
	with_self_test.self_test = 3
	testing.expect(t, volume_key_of_a_new_build(t, root, with_self_test, shared) != first, "a flag of the compiler changes the key")

	with_change := main_volume
	with_change.change.signature_changed = true
	testing.expect(t, volume_key_of_a_new_build(t, root, with_change, shared) != first, "a change of the boot image changes the key")

	signed := main_volume
	signed.firmware_signature = .Signed
	testing.expect(t, volume_key_of_a_new_build(t, root, signed, shared) != first, "a firmware signature changes the key")

	shortage := Boot_Volume{path = BOOT_VOLUME_SHORTAGE, image = BOOT_IMAGE_SHORTAGE, kernel = "kernel"}
	testing.expect(t, volume_key_of_a_new_build(t, root, shortage, shared) != first, "another volume has another key")

	measure_volume := Boot_Volume{path = BOOT_VOLUME_MEASURE, image = BOOT_IMAGE_MEASURE, kernel = "kernel"}
	measure_key := volume_key_of_a_new_build(t, root, measure_volume, shared)
	testing.expect(t, measure_key != first, "the volume of a measure run has another key")
	// The boot image of a measure run is an input of its volume only.
	other_measure_image := shared_inputs_of_a_test("the boot image")
	for &file in other_measure_image.built_files {
		if file.path == BOOT_IMAGE_MEASURE {
			file.hash = hash_of_text("the image of a measure run with another resource")
		}
	}
	testing.expect(t, volume_key_of_a_new_build(t, root, measure_volume, other_measure_image) != measure_key, "another boot image of a measure run changes the key of its volume")
	testing.expect_value(t, volume_key_of_a_new_build(t, root, main_volume, other_measure_image), first)

	boot_tree_file_write(root, foundation.SOURCE_FOLDER_BOOT + "/main.odin", "package boot\n\nefi_main :: proc() {_ = 1}\n")
	after_source := volume_key_of_a_new_build(t, root, main_volume, shared)
	testing.expect(t, after_source != first, "a byte of a source of the boot program changes the key")

	boot_tree_file_write(root, BOOT_PROGRAM_JUMP_SOURCE, "global jump\njump: nop\nret\n")
	after_assembly := volume_key_of_a_new_build(t, root, main_volume, shared)
	testing.expect(t, after_assembly != after_source, "a byte of an assembly file changes the key")

	boot_tree_file_write(root, TEST_SIGNING_KEY_FILE, "01\n")
	testing.expect(t, volume_key_of_a_new_build(t, root, main_volume, shared) != after_assembly, "another test signing key changes the key")

	// A volume whose boot image has no hash has no key: it is built.
	without_return_check := Boot_Volume{path = BOOT_VOLUME_WITHOUT_RETURN_CHECK, image = BOOT_IMAGE, kernel = "kernel_without_return_check"}
	_, readable := boot_volume_key_inputs(without_return_check, shared, boot_sources(root), nil)
	testing.expect(t, !readable, "a kernel that cannot be read gives no key")
}

// A kept volume whose file changed is built again; so is a volume whose
// boot image or whose source changed, and a volume with no record.
@(test)
kept_boot_volume_with_a_changed_file_is_built_again :: proc(t: ^testing.T) {
	root := boot_tree_make(t)
	defer os.remove_all(root)
	volume_file := fmt.tprintf("%s/boot_volume.img", root)
	image_file := fmt.tprintf("%s/boot_volume.image", root)
	record_file := fmt.tprintf("%s/main%s", root, BUILD_RECORD_SUFFIX)
	_ = os.write_entire_file(volume_file, "the volume")
	_ = os.write_entire_file(image_file, "the signed boot image")
	main_volume := Boot_Volume{path = BOOT_VOLUME, image = BOOT_IMAGE, kernel = "kernel"}
	shared := shared_inputs_of_a_test("the boot image")
	sources := boot_sources(root)
	inputs, readable := boot_volume_key_inputs(main_volume, shared, nil, nil)
	testing.expect(t, readable, "each built file of the volume has its hash")
	key := volume_key_of_a_new_build(t, root, main_volume, shared)
	testing.expect(t, build_record_write(record_file, key, {volume_file, image_file}, sources, nil), "the record is written")

	decision :: proc(root, record_file: string, inputs: Build_Key_Inputs, outputs: []string) -> (kept: bool, reason: string) {
		table := input_file_table_make(root, {foundation.SOURCE_FOLDER_BOOT})
		defer input_file_table_destroy(table)
		return recorded_build_is_kept(record_file, inputs, table, outputs)
	}
	kept, reason := decision(root, record_file, inputs, {volume_file, image_file})
	testing.expectf(t, kept, "the volume is kept with the same inputs and the same files: %s", reason)

	_ = os.write_entire_file(volume_file, "the volume with one changed byte")
	kept, reason = decision(root, record_file, inputs, {volume_file, image_file})
	testing.expect(t, !kept, "a volume file that changed is built again")
	testing.expect_value(t, reason, "an output is absent or changed")

	_ = os.write_entire_file(volume_file, "the volume")
	kept, _ = decision(root, record_file, inputs, {volume_file, image_file})
	testing.expect(t, kept, "the same bytes again are the recorded volume")

	_ = os.remove(image_file)
	kept, reason = decision(root, record_file, inputs, {volume_file, image_file})
	testing.expect(t, !kept, "a missing boot image of the volume forces a build")
	testing.expect_value(t, reason, "an output is absent or changed")
	_ = os.write_entire_file(image_file, "the signed boot image")

	kept, reason = decision(root, record_file, inputs, {volume_file, image_file, fmt.tprintf("%s/BOOTX64.EFI", root)})
	testing.expect(t, !kept, "an output that the record does not name forces a build")

	other_image, other_readable := boot_volume_key_inputs(main_volume, shared_inputs_of_a_test("the boot image with one changed module"), nil, nil)
	testing.expect(t, other_readable)
	kept, reason = decision(root, record_file, other_image, {volume_file, image_file})
	testing.expect(t, !kept, "a volume whose boot image changed is built again")
	testing.expect_value(t, reason, "an input changed")

	boot_tree_file_write(root, foundation.SOURCE_FOLDER_BOOT + "/main.odin", "package boot\n\nefi_main :: proc() {_ = 2}\n")
	kept, reason = decision(root, record_file, inputs, {volume_file, image_file})
	testing.expect(t, !kept, "a volume whose boot program changed is built again")
	testing.expect_value(t, reason, "an input changed")
	boot_tree_file_write(root, foundation.SOURCE_FOLDER_BOOT + "/main.odin", "package boot\n\nefi_main :: proc() {}\n")
	kept, _ = decision(root, record_file, inputs, {volume_file, image_file})
	testing.expect(t, kept, "the same source again gives the recorded key")

	// The two parts of the decision, as the build of all the volumes uses
	// them: the key first, then the hashes of the outputs read at once.
	{
		table := input_file_table_make(root, {foundation.SOURCE_FOLDER_BOOT})
		defer input_file_table_destroy(table)
		record, same, _ := recorded_build_has_its_key(record_file, inputs, table)
		testing.expect(t, same, "the record has the key of the inputs")
		testing.expect(t, record_names_each_output(record, {volume_file, image_file}), "the record names each output")
		contents := file_contents_read_in_parallel({volume_file, image_file}, context.temp_allocator)
		testing.expect(t, record_outputs_have_their_hashes(record, contents), "each output has its recorded hash")
		testing.expect(t, !record_outputs_have_their_hashes(record, contents[:1]), "a list with one output less proves nothing")
		contents[0].hash[0] ~= 1
		testing.expect(t, !record_outputs_have_their_hashes(record, contents), "another hash of the volume file forces a build")
		testing.expect(t, !build_record_write_of_contents(fmt.tprintf("%s/other%s", root, BUILD_RECORD_SUFFIX), record.key, {volume_file, image_file}, contents[:1], sources, nil), "no record with a hash less than the outputs")
	}

	_ = os.write_entire_file(record_file, "a damaged record")
	kept, reason = decision(root, record_file, inputs, {volume_file, image_file})
	testing.expect(t, !kept, "a damaged record is no record")
	testing.expect_value(t, reason, "no build record")
	_ = os.remove(record_file)
	kept, reason = decision(root, record_file, inputs, {volume_file, image_file})
	testing.expect(t, !kept, "a volume with no record is built")
	testing.expect_value(t, reason, "no build record")
}

// A file with zero bytes at its end reads as the whole bytes, with any
// older content gone.
@(test)
file_with_a_hole_at_its_end_reads_as_its_whole_bytes :: proc(t: ^testing.T) {
	root := boot_tree_make(t)
	defer os.remove_all(root)
	path := fmt.tprintf("%s/volume.img", root)
	// An older, longer file with other bytes.
	older := make([]u8, 3 << 20, context.temp_allocator)
	for &value in older {
		value = 0xEE
	}
	_ = os.write_entire_file(path, older)
	cases := [?][2]int{{1 << 20, 4097}, {1 << 20, 0}, {4096, 4096}, {0, 0}}
	for one in cases {
		data := make([]u8, one[0], context.temp_allocator)
		for index in 0 ..< one[1] {
			data[index] = u8(index % 251 + 1)
		}
		testing.expect(t, file_write_with_a_hole_at_its_end(path, data), "the file is written")
		read, error := os.read_entire_file(path, context.temp_allocator)
		testing.expect(t, error == nil, "the file is read")
		testing.expect_value(t, len(read), len(data))
		same := len(read) == len(data)
		for index := 0; same && index < len(data); index += 1 {
			same = read[index] == data[index]
		}
		testing.expectf(t, same, "a file of %d bytes with %d bytes that are not zero reads as its bytes", one[0], one[1])
		// The hash of the build record is the hash of the content.
		content := file_content_read(path)
		testing.expect(t, content.readable && content.hash == blake3.hash(data), "the hash of the file is the hash of its whole bytes")
	}
}

// The count of volume processes at once: the count that the command gives,
// or the processors up to the bound, and never more than the volumes.
@(test)
boot_volume_host_processes_follow_the_processors_up_to_the_bound :: proc(t: ^testing.T) {
	testing.expect_value(t, boot_volume_host_processes(18, 0, 4), 4)
	testing.expect_value(t, boot_volume_host_processes(18, 0, 16), MOST_BOOT_VOLUME_HOST_PROCESSES)
	testing.expect_value(t, boot_volume_host_processes(2, 0, 16), 2)
	testing.expect_value(t, boot_volume_host_processes(18, 3, 16), 3)
	testing.expect_value(t, boot_volume_host_processes(18, 12, 16), 12)
	testing.expect_value(t, boot_volume_host_processes(1, 0, 0), 1)
}

// A machine starts only from a volume that the build of the process built
// or kept; a new build forgets the volumes of the build before.
@(test)
only_a_volume_of_this_build_is_ready :: proc(t: ^testing.T) {
	boot_volumes_ready_forget()
	testing.expect(t, !boot_volume_is_ready(BOOT_VOLUME), "no volume is ready before a build")
	boot_volume_ready_note(BOOT_VOLUME)
	boot_volume_ready_note(BOOT_VOLUME)
	testing.expect(t, boot_volume_is_ready(BOOT_VOLUME), "a volume that the build built or kept is ready")
	testing.expect(t, !boot_volume_is_ready(BOOT_VOLUME_SHORTAGE), "a volume that the command did not ask for is not ready")
	testing.expect_value(t, len(boot_volumes_ready), 1)
	boot_volumes_ready_forget()
	testing.expect(t, !boot_volume_is_ready(BOOT_VOLUME), "a new build forgets the volumes of the build before")
}
