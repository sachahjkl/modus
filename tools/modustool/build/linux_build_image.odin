// The guest image of a build and the recipe of the machine test of a guest
// build (src/md/features/guest_build_image.md): the tool builds the init of
// src/guest/linux_build_init as a static ELF of Linux, assembles the
// initial archive from it, a static busybox and the virtio modules, and
// makes a recipe of the guest builder whose output the host computes.
package build

import "core:fmt"
import "core:os"
import "core:strings"
import "modus:contract/blake3"
import gb "modus:contract/guest_builder"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"
import "modustool:foundation"

// The source of the init and the folder of its build.
LINUX_BUILD_INIT_SOURCE :: foundation.SOURCE_FOLDER_GUEST + "/linux_build_init"
LINUX_BUILD_INIT_FOLDER :: foundation.BUILD_FOLDER + "/linux_build_init"

// The modules that the init of a build loads: no console, which a build
// does not read.
LINUX_BUILD_MODULES :: [?]Linux_Guest_Module{.Virtio_Ring, .Virtio, .Virtio_Mmio, .Virtio_Block}

// linux_build_init_compile builds the init: the package for the target
// freestanding_amd64_sysv as objects, its assembly and the memory
// procedures of the runtime, linked as a static ELF that starts at _start.
// It gives the bytes of the ELF, in temporary memory.
linux_build_init_compile :: proc() -> (elf: []u8, ok: bool) {
	folder := LINUX_BUILD_INIT_FOLDER
	os.remove_all(folder)
	if error := os.make_directory_all(folder); error != nil {
		fmt.eprintfln("modustool: cannot make %s: %v", folder, error)
		return nil, false
	}
	foundation.run({"odin", "build", LINUX_BUILD_INIT_SOURCE, "-target:freestanding_amd64_sysv", "-no-entry-point", "-build-mode:obj", "-vet", foundation.SOURCE_LIBRARY_FLAG, strings.concatenate({"-out:", folder, "/init.o"}, context.temp_allocator)}) or_return
	calls := strings.concatenate({folder, "/calls.asm.o"}, context.temp_allocator)
	memory := strings.concatenate({folder, "/memory.asm.o"}, context.temp_allocator)
	foundation.run({"nasm", "-f", "elf64", "-o", calls, LINUX_BUILD_INIT_SOURCE + "/linux_calls.asm"}) or_return
	foundation.run({"nasm", "-f", "elf64", "-o", memory, RUNTIME_MEMORY}) or_return
	entries, list_error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if list_error != nil {
		fmt.eprintfln("modustool: cannot list %s: %v", folder, list_error)
		return nil, false
	}
	output := strings.concatenate({folder, "/init"}, context.temp_allocator)
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "ld.lld", "-static", "-e", "_start", "-o", output)
	for entry in entries {
		if strings.has_prefix(entry.name, "init-") && strings.has_suffix(entry.name, ".o") {
			append(&command, entry.fullpath)
		}
	}
	append(&command, calls, memory)
	foundation.run(command[:]) or_return
	bytes, read_error := os.read_entire_file(output, context.temp_allocator)
	if read_error != nil || !strings.has_prefix(string(bytes), "\x7fELF") {
		fmt.eprintfln("modustool: cannot read the init %s, or it is no ELF file", output)
		return nil, false
	}
	return bytes, true
}

// linux_build_initial_archive gives the archive of a guest build, in
// temporary memory: the init, a static busybox for the shell of the
// command, the modules of the disks, the folders and the console. The same
// inputs give the same bytes.
linux_build_initial_archive :: proc(init: []u8, busybox: []u8, modules: [Linux_Guest_Module][]u8) -> []u8 {
	entries := [?]Cpio_Entry {
		{name = "bin", kind = .Directory, permissions = 0o755},
		{name = "dev", kind = .Directory, permissions = 0o755},
		{name = "inputs", kind = .Directory, permissions = 0o755},
		{name = "lib", kind = .Directory, permissions = 0o755},
		{name = LINUX_GUEST_MODULES_FOLDER, kind = .Directory, permissions = 0o755},
		{name = "outputs", kind = .Directory, permissions = 0o755},
		{name = "proc", kind = .Directory, permissions = 0o755},
		{name = "sys", kind = .Directory, permissions = 0o755},
		{name = "tmp", kind = .Directory, permissions = 0o1777},
		{name = "init", kind = .File, permissions = 0o755, data = init},
		{name = "bin/busybox", kind = .File, permissions = 0o755, data = busybox},
		{name = "bin/sh", kind = .Link, permissions = 0o777, data = transmute([]u8)string("busybox")},
		{name = "dev/console", kind = .Character, permissions = 0o600, major = 5, minor = 1},
	}
	out := make([dynamic]u8, context.temp_allocator)
	inode := 1
	for entry in entries {
		cpio_entry_write(&out, entry, inode)
		inode += 1
	}
	files := LINUX_GUEST_MODULE_FILES
	for module in LINUX_BUILD_MODULES {
		name := strings.concatenate({LINUX_GUEST_MODULES_FOLDER, "/", files[module]}, context.temp_allocator)
		cpio_entry_write(&out, {name = name, kind = .File, permissions = 0o644, data = modules[module]}, inode)
		inode += 1
	}
	cpio_entry_write(&out, {name = "TRAILER!!!", kind = .File}, 0)
	return out[:]
}

// linux_build_image_read builds the init and gives the kernel and the
// archive of a guest build, in temporary memory.
linux_build_image_read :: proc() -> (kernel: []u8, archive: []u8, ok: bool) {
	kernel_path := os.get_env(LINUX_KERNEL_IMAGE_VARIABLE, context.temp_allocator)
	busybox_path := os.get_env(LINUX_GUEST_BUSYBOX_VARIABLE, context.temp_allocator)
	if kernel_path == "" || busybox_path == "" {
		fmt.eprintfln("modustool: a guest build needs the variables %s and %s: run the tool in a shell of the flake (src/md/features/guest_build_image.md)", LINUX_KERNEL_IMAGE_VARIABLE, LINUX_GUEST_BUSYBOX_VARIABLE)
		return nil, nil, false
	}
	kernel_bytes, kernel_error := os.read_entire_file(kernel_path, context.temp_allocator)
	busybox_bytes, busybox_error := os.read_entire_file(busybox_path, context.temp_allocator)
	if kernel_error != nil || busybox_error != nil {
		fmt.eprintfln("modustool: cannot read the kernel %s or the busybox %s", kernel_path, busybox_path)
		return nil, nil, false
	}
	modules := linux_guest_modules_read() or_return
	init := linux_build_init_compile() or_return
	return kernel_bytes, linux_build_initial_archive(init, busybox_bytes, modules), true
}

// The recipe of the machine test of a guest build: one input file, and a
// command of busybox whose output the host knows.
GUEST_BUILD_TEST_EPOCH :: u64(1_700_000_000)
GUEST_BUILD_TEST_MESSAGE :: "modus builds in a guest\n"
GUEST_BUILD_TEST_COMMAND :: "mkdir -p /outputs/share && cat message.txt > /outputs/share/greeting.txt && echo built > /outputs/status.txt"
GUEST_BUILD_TEST_OUTPUT_BYTES :: u64(1024 * 1024)
GUEST_BUILD_TEST_MEMORY_PAGES :: u64(32_768)
// The exits of a Linux boot and a small build pass a million; the bound
// of the exits ends a guest that loops, and the time bound one that hangs.
GUEST_BUILD_TEST_EXITS_MOST :: u64(200_000_000)

// The objects that the private store of recipes holds for the test, by
// their names, and the hashes that the test checks.
Guest_Build_Test :: struct {
	objects:         [dynamic]Module_File,
	recipe_hash:     blake3.Hash,
	expected_output: blake3.Hash,
}

// guest_build_test_make gives the store and the recipe of the machine test
// of a guest build, and the tree hash that its output must have, which the
// host computes with the contract of the guest builder.
guest_build_test_make :: proc(kernel: []u8, archive: []u8) -> (test: Guest_Build_Test, ok: bool) {
	test.objects = make([dynamic]Module_File, context.temp_allocator)
	blob_add :: proc(test: ^Guest_Build_Test, bytes: []u8) -> blake3.Hash {
		hash := blake3.hash(bytes)
		name := pr.blob_object_name(hash)
		append(&test.objects, Module_File{name = strings.clone(pr.private_object_name_text(&name), context.temp_allocator), bytes = bytes})
		return hash
	}
	kernel_hash := blob_add(&test, kernel)
	_ = blob_add(&test, archive)
	message := transmute([]u8)string(GUEST_BUILD_TEST_MESSAGE)
	message_hash := blob_add(&test, message)

	guest: gb.Guest_Build_Spec
	guest.kernel_hash = kernel_hash
	guest.root_image_hash = kernel_hash // The build has no root image: the kernel names its world.
	guest.frozen_epoch_seconds = GUEST_BUILD_TEST_EPOCH
	guest.memory_pages = GUEST_BUILD_TEST_MEMORY_PAGES
	guest.output_size_bound = GUEST_BUILD_TEST_OUTPUT_BYTES
	guest.max_guest_exits = GUEST_BUILD_TEST_EXITS_MOST
	gb.build_spec_set_command(&guest, GUEST_BUILD_TEST_COMMAND)
	if refusal := gb.build_spec_set_initial_archive(&guest, archive); refusal != .None {
		fmt.eprintfln("modustool: the archive of a guest build is refused by the spec: %v", refusal)
		return {}, false
	}
	spec: pr.Recipe_Spec
	spec.builder_hash = pr.guest_builder_hash()
	spec.output_kind = .Tree
	spec.source_date_unix = GUEST_BUILD_TEST_EPOCH
	spec.output_block_limit = GUEST_BUILD_TEST_OUTPUT_BYTES / gb.GUEST_PAGE_BYTES
	spec.input_count = 1
	input_refusal: pr.Recipe_Refusal
	spec.inputs[0], input_refusal = pr.recipe_input_make("message.txt", .Blob, message_hash)
	written, spec_refusal := gb.encode_build_spec(&guest, spec.arguments[:])
	if input_refusal != .None || spec_refusal != .None {
		fmt.eprintfln("modustool: the recipe of a guest build is refused: %v %v", input_refusal, spec_refusal)
		return {}, false
	}
	spec.arguments_length = u32(written)
	recipe_refusal: pr.Recipe_Refusal
	test.recipe_hash, recipe_refusal = pr.recipe_hash(&spec)
	recipe_bytes := make([]u8, pr.MAX_RECIPE_OBJECT_BYTES, context.temp_allocator)
	recipe_written, encode_refusal := pr.recipe_object_encode(&spec, recipe_bytes)
	if recipe_refusal != .None || encode_refusal != .None {
		fmt.eprintfln("modustool: the recipe of a guest build does not encode: %v %v", recipe_refusal, encode_refusal)
		return {}, false
	}
	recipe_name := pr.recipe_object_name(test.recipe_hash)
	append(&test.objects, Module_File{name = strings.clone(pr.private_object_name_text(&recipe_name), context.temp_allocator), bytes = recipe_bytes[:recipe_written]})

	test.expected_output, ok = guest_build_test_expected_output()
	return test, ok
}

// guest_build_test_expected_output gives the tree hash of the output of the
// test command: the files that it writes, packed and unpacked as the
// guest builder does.
guest_build_test_expected_output :: proc() -> (output: blake3.Hash, ok: bool) {
	files := [2]gb.Disk_File_Input{{path = "share/greeting.txt", content = transmute([]u8)string(GUEST_BUILD_TEST_MESSAGE)}, {path = "status.txt", content = transmute([]u8)string("built\n")}}
	image := make([]u8, 8192, context.temp_allocator)
	if _, refusal := gb.pack_disk_image(.Output_Writable, files[:], GUEST_BUILD_TEST_EPOCH, image); refusal != .None {
		return {}, false
	}
	workspace := new(gb.Disk_Unpack_Workspace, context.temp_allocator)
	tree := make([]u8, tree_hash.MAX_ENCODED_TREE_BYTES, context.temp_allocator)
	_, unpacked, refusal := gb.unpack_output_disk(image, u64(len(image)), workspace, tree)
	return unpacked, refusal == .None
}
