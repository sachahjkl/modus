package build

import "modus:contract/blake3"
import module "modus:contract/module"
import "core:fmt"
import info "modus:contract/boot_info"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "modustool:foundation"
import "modustool:resources"

// The modules of the build with no debug information: the check that the
// debug objects change no byte of a module builds every module there
// (repeat.odin, modules_same_without_debug_information).
MODULE_BUILD_FOLDER_WITHOUT_DEBUG_INFORMATION :: foundation.BUILD_FOLDER + "/modules_without_debug_information"
BOOT_IMAGE :: foundation.BUILD_FOLDER + "/boot.image"
BOOT_IMAGE_FAILS :: foundation.BUILD_FOLDER + "/boot_fails.image"
BOOT_IMAGE_SHORTAGE :: foundation.BOOT_IMAGE_SHORTAGE
// The boot image of the test of the rescue: the modules of the boot image,
// with a start list whose row of the console names no module, and a rescue
// list with the two rows of the test of the restarts (start_lists.odin).
BOOT_IMAGE_MISSING_CONSOLE :: foundation.BOOT_IMAGE_MISSING_CONSOLE
// The boot image of the test of the plan of principal 0 and of the audit
// of the collector: the modules of the boot image, and its three test
// modules, with the default lists.
BOOT_IMAGE_PLAN_AND_AUDIT :: foundation.BOOT_IMAGE_PLAN_AND_AUDIT
// The boot image of a measure run: the usual one, with one resource more,
// which the root service looks for (docs/TOOLS.md, "A check by count, a measure by time").
BOOT_IMAGE_MEASURE :: foundation.BUILD_FOLDER + "/boot_measure.image"
MEASURE_RUN_RESOURCE_NAME :: "measure_run" // system.MEASURE_RUN_RESOURCE.
MEASURE_RUN_RESOURCE_FILE :: foundation.BUILD_FOLDER + "/measure_run.resource"
// The bytes of the resource: the root service reads its name only.
MEASURE_RUN_RESOURCE_TEXT :: "This machine runs for a measure.\n"
// The copy and the fill of every module, of the kernel and of the boot
// program: copy_bytes_without_overlap, copy_bytes_with_overlap,
// fill_bytes_with_value, and the names that the compiler calls (memcpy,
// memmove, memset). The builds do not use -no-crt: with it, the Odin runtime
// gives its own functions under these names (loops of one byte, two with no
// optimization), and a symbol of another object cannot replace them.
RUNTIME_MEMORY :: foundation.SOURCE_FOLDER_RUNTIME + "/memory.asm"

// The features of llc for the kernel: no x87, MMX, SSE or AVX instruction,
// as the Linux kernel is built (-mno-80387 -mno-mmx -mno-sse -mno-sse2
// -mno-avx -msoft-float). soft-float passes the floating point values of
// the few runtime procedures that have them in general registers, and
// makes their arithmetic calls: no code of the kernel calls those
// procedures, and the link drops them (--gc-sections). The check after
// the link (vector_check.odin) is the proof.
KERNEL_TARGET_FEATURES :: "-mattr=-x87,-mmx,-sse,-sse2,-sse3,-ssse3,-sse4.1,-sse4.2,-avx,-avx2,-avx512f,+soft-float"

debug_information := true

// The folder of the source of the module that this process builds, when
// that source is outside the repository: an absolute path with its links
// resolved, as the compiler names a file. "": the module is a module of
// the system. A source of that folder is in no folder of the system, so
// the readers of the list of the compiler and the writer of the debug
// object ask for it (outside_module.odin).
outside_source_folder := ""

build_modules :: proc() -> bool {
	// Each module file states its category: a row whose category disagrees
	// with its group stops the build before any module is written.
	for row in foundation.module_builds {
		if _, problem := foundation.module_category_of_row(row); problem != "" {
			fmt.eprintfln("modustool: %s", problem)
			return false
		}
	}
	// The lists of the start menu come from the table of the modules: the
	// compositor that this build compiles lists them.
	start_menu_names_write() or_return
	// One process for each module, several at once (parallel_build.odin).
	// A module whose inputs are the same is kept (incremental_build.odin).
	build_modules_in_parallel() or_return
	// The line of a log fact names its module by its module tag, the first
	// 4 bytes of its hash: two module files that share it would make one
	// line two facts.
	if _, problem := fact_catalog_of_build(context.temp_allocator); problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return false
	}
	// The release refuses a test kernel by a text of its bytes: the kernel
	// that ships must not hold it, and each test kernel must.
	kernel_test_texts_check() or_return
	library_modules_measure_print()
	kernel_stack_measure_print()
	// The steps below run at each build: each one reads outputs of the
	// modules or files of the repository, and its time is in the measure of
	// the build.
	step_started := time.tick_now()
	// The debug objects, beside the modules, in one file for the boot volumes.
	debug_image_write() or_return
	build_measure_step("the debug image", step_started)
	step_started = time.tick_now()
	// The pointer themes: the resources of the boot image (pointers.odin).
	pointer_themes := resources.build_pointer_themes(resources.pointer_theme_source_of_the_build(), false) or_return
	build_measure_step("the pointer themes", step_started)
	step_started = time.tick_now()
	// The font outlines: one more resource, from which each process draws
	// each glyph of its text (vector_fonts.odin).
	outlines_resource := resources.font_outlines_write() or_return
	build_measure_step("the font outlines", step_started)
	step_started = time.tick_now()
	// The name of the script font set: 32 bytes in the boot image, the
	// set of a machine whose plan names none. The set itself is an object
	// of a data disk (script_fonts.odin).
	script_fonts_name := resources.script_fonts_name_write() or_return
	build_measure_step("the script font set", step_started)
	step_started = time.tick_now()
	// The pages of the links of the documentation of the modules: one more
	// resource, for the process manual (manual_link_pages.odin).
	link_pages := build_manual_pages() or_return
	build_measure_step("the link pages of the manual", step_started)
	step_started = time.tick_now()
	all_resources := make([dynamic]resources.Resource_File, context.temp_allocator)
	append(&all_resources, ..pointer_themes)
	append(&all_resources, outlines_resource)
	append(&all_resources, script_fonts_name)
	append(&all_resources, link_pages)
	// The start policy reads a list and asks for the starts, and nothing
	// more: its source is checked before any image holds it.
	start_policy_source_check() or_return
	// The second boot image has no start policy: with it, the start fails.
	// The third has no input service, and its start list starts only the
	// process shortage (the test of the shortage of frames).
	// The fifth holds the module of the operation sequences, which no
	// other image holds. The sixth has a start list whose row of the
	// console names no module: the rescue takes over. The seventh holds the
	// test modules of the plan of principal 0 and of the audit.
	images_built := build_boot_image(BOOT_IMAGE, "", all_resources[:]) && build_boot_image(BOOT_IMAGE_FAILS, foundation.START_POLICY_MODULE, all_resources[:]) && build_boot_image(BOOT_IMAGE_SHORTAGE, "input", all_resources[:]) && build_boot_image(foundation.BOOT_IMAGE_OPERATION_SEQUENCES, "", all_resources[:]) && build_boot_image(BOOT_IMAGE_MISSING_CONSOLE, "", all_resources[:]) && build_boot_image(BOOT_IMAGE_PLAN_AND_AUDIT, "", all_resources[:])
	if images_built {
		// The fourth is the image of a measure run: the same modules and one
		// resource more, so a measure runs the code that a test checked.
		resource_text: string = MEASURE_RUN_RESOURCE_TEXT
		if err := os.write_entire_file(MEASURE_RUN_RESOURCE_FILE, transmute([]u8)resource_text); err != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", MEASURE_RUN_RESOURCE_FILE, err)
			return false
		}
		append(&all_resources, resources.Resource_File{name = MEASURE_RUN_RESOURCE_NAME, path = MEASURE_RUN_RESOURCE_FILE})
		images_built = build_boot_image(BOOT_IMAGE_MEASURE, "", all_resources[:]) && release_boot_image_write() && qemu_console_boot_image_write()
	}
	build_measure_step("the nine boot images", step_started)
	if !images_built {
		return false
	}
	step_started = time.tick_now()
	system_catalogs_write() or_return
	build_measure_step("the system catalog declarations", step_started)
	return true
}

// library_modules_measure_print prints, for each library module of the
// table, the size of its file, then the size of the file of each module
// that imports it and their sum: a measure, to compare with the build
// before a module became an importer. It checks nothing, and a file that
// cannot be read only ends the line of its library.
library_modules_measure_print :: proc() {
	for library in foundation.module_builds {
		if !library.library {
			continue
		}
		file, readable := foundation.read_file(foundation.module_path(library.name))
		if !readable {
			continue
		}
		line := strings.builder_make(context.temp_allocator)
		sum, count := 0, 0
		for build in foundation.module_builds {
			if !slice.contains(build.imports, library.name) {
				continue
			}
			importer, importer_readable := foundation.read_file(foundation.module_path(build.name))
			if !importer_readable {
				return
			}
			fmt.sbprintf(&line, "%s%s %d", count == 0 ? "" : ", ", build.name, len(importer))
			sum += len(importer)
			count += 1
		}
		fmt.printfln("modustool: measure: the library module %s has %d bytes; the files of the %d modules that import it have %d bytes in all: %s", library.name, len(file), count, sum, strings.to_string(line))
	}
}

// The checks of the kernel: the lock order at each take (TEST_BUILD_CHECKS_LOCK_ORDER),
// the sums of the frames at each report and each drain, with a drain
// of all the frame caches at each 64th refill (TEST_BUILD_CHECKS_FRAME_SUMS), and the
// placement of each thread that enters a run queue (TEST_BUILD_CHECKS_PLACEMENT). The test
// build has them (`check`, `test`, `screenshots`, `measure`, `run`); the
// measure build has none (`measure without_checks`, `run without_checks`). The tool
// passes the three defines in each build: the defaults of the source never
// decide. The source of the check of the placement has it off, so a build
// outside the tool has none. The defines are a part of the compile command,
// which the key of the incremental build holds: a change of one builds the
// kernel again.
test_build_checks := true

// module_compile_command gives the command of the compiler for a module,
// with each flag of its build: the checks of the kernel, the debug
// information, the settings of the module. The build key of the module
// holds this command (incremental_build.odin), so a flag is written here
// and nowhere else.
module_compile_command :: proc(build: foundation.Module_Build) -> []string {
	llvm_ir_folder := foundation.join(foundation.module_build_folder, "/", build.name, "/llvm_ir")
	compile := make([dynamic]string, context.temp_allocator)
	append(
		&compile,
		"odin",
		"build",
		build.source,
		"-target:freestanding_amd64_sysv",
		// LLVM IR, then llc: Odin has no option that keeps the frame pointers
		// (rule 8 of docs/MODULE_CONTRACT.md); llc has one.
		"-build-mode:llvm-ir",
		"-reloc-mode:pic",
		"-no-entry-point",
		"-default-to-nil-allocator",
		"-o:speed",
		"-vet",
		// The file name and the line in a message of a check, not the full path:
		// the hash of a module does not depend on the folder of the build.
		"-source-code-locations:filename",
		// The compiler writes the list of the files that it read: the inputs
		// of the next build of this module.
		"-export-dependencies:json",
		foundation.join("-export-dependencies-file:", module_dependency_file(build.name)),
		// The public source library, which ships in the SDK.
		foundation.SOURCE_LIBRARY_FLAG,
		// The attribute of a fact type, which the compiler ignores
		// (src/md/features/log_facts.md).
		foundation.CUSTOM_ATTRIBUTES_FLAG,
		foundation.join("-out:", llvm_ir_folder),
	)
	// Internal parts belong to modules of the system only: the compiler
	// refuses internal: in the kernel and in an outside module.
	if !build.kernel && outside_source_folder == "" {
		append(&compile, foundation.INTERNAL_LIBRARY_FLAG)
	}
	// The line program of DWARF, for the line table of the debug object.
	// The module itself has no byte of it: the converter copies the
	// segments only, and `check` proves that each module is the same bytes
	// without it.
	// The kind of debug information that never changes the code: the compiler
	// makes the same module as a build with none. A plain
	// `-debug` adds aids for a debugger that are instructions, and it sets
	// a constant that a source can read.
	if debug_information {
		append(&compile, "-debug-info:same-code")
	}
	for define in build.defines {
		append(&compile, strings.concatenate({"-define:", define}, context.temp_allocator))
	}
	if build.kernel {
		// The kernel parts: no other module gets this source library, so
		// the compiler refuses a kernel part in a module.
		append(&compile, foundation.KERNEL_LIBRARY_FLAG)
		append(&compile, "-disable-red-zone")
		append(&compile, test_build_checks ? "-define:TEST_BUILD_CHECKS_LOCK_ORDER=true" : "-define:TEST_BUILD_CHECKS_LOCK_ORDER=false")
		append(&compile, test_build_checks ? "-define:TEST_BUILD_CHECKS_FRAME_SUMS=true" : "-define:TEST_BUILD_CHECKS_FRAME_SUMS=false")
		append(&compile, test_build_checks ? "-define:TEST_BUILD_CHECKS_PLACEMENT=true" : "-define:TEST_BUILD_CHECKS_PLACEMENT=false")
		// Each kernel but the counted kernel says that it has no edge
		// counter: the default of the source never decides.
		if !foundation.module_counts_kernel_edges(build) {
			append(&compile, "-define:" + foundation.KERNEL_EDGE_COUNTERS_SETTING + "=false")
		}
	}
	return compile[:]
}

// module_object_command gives the command of llc for a module: the LLVM
// of the Odin compiler (18) makes the object. Each function keeps its
// frame pointer: the kernel walks them for the stack trace of a fault.
// The build key of the module holds this command.
module_object_command :: proc(build: foundation.Module_Build) -> []string {
	folder := foundation.join(foundation.module_build_folder, "/", build.name)
	llc := make([dynamic]string, context.temp_allocator)
	// -misched-topdown: with debug instructions in a block, the instruction
	// scheduler of this LLVM (18) orders some register copies in another
	// way in its bottom-up direction, so the code differs with and without
	// debug information. The top-down direction gives the same code for
	// both (docs/REPRODUCIBLE_BUILD.md, section 8).
	append(&llc, "llc", "-O3", "-misched-topdown", "--frame-pointer=all", "-relocation-model=pic", "--function-sections", "--data-sections", "-filetype=obj")
	if build.kernel {
		// The kernel has no x87, SSE or AVX instruction: the registers of a
		// process stay live through each kernel entry, and only the switch
		// of threads saves them (docs/ARCHITECTURE.md, "The extended state
		// of the processor").
		append(&llc, KERNEL_TARGET_FEATURES)
		// The frame of each procedure, in a section that no segment holds:
		// the measure of the kernel stack reads it from the linked file
		// (kernel_stack.odin), and the module file does not change.
		append(&llc, "-stack-size-section")
	}
	append(&llc, "-o", foundation.join(folder, "/objects/", build.name, ".o"), foundation.join(folder, "/", build.name, ".ll"))
	return llc[:]
}

// module_assembly_files gives the assembly files that a module links: the
// copies and the fills, the files of its folder, and for a module with an
// entry the files of the system library, which has instructions of its own.
module_assembly_files :: proc(build: foundation.Module_Build) -> (files: []string, ok: bool) {
	assembly := make([dynamic]string, context.temp_allocator)
	append(&assembly, RUNTIME_MEMORY)
	own_files := foundation.files_with_suffix(build.source, ".asm") or_return
	for source in own_files {
		// The callback of the edge counters: the counted kernel only.
		if source == KERNEL_EDGE_COUNTERS_ASSEMBLY && !foundation.module_counts_kernel_edges(build) {
			continue
		}
		append(&assembly, source)
	}
	if build.image {
		append(&assembly, ..(foundation.files_with_suffix(foundation.SYSTEM_LIBRARY_FOLDER, ".asm") or_return))
	}
	return assembly[:], true
}

// The flags of clang for each C file of an outside source, after the
// command name. The reason of each one is in
// src/md/infrastructure/outside_source.md, "The compile of a C file". The
// wrapper of clang in Nix adds the protections of a program of the host
// before them; a later flag of the same kind wins, so each one is written.
@(rodata)
c_compile_flags := [?]string {
	"--target=x86_64-unknown-none-elf",
	"-std=gnu11",
	"-O2",
	"-ffreestanding",
	"-nostdinc",
	"-fPIC",
	"-fvisibility=hidden",
	"-fno-omit-frame-pointer",
	"-mno-omit-leaf-frame-pointer",
	"-mlong-double-64",
	"-fno-stack-protector",
	"-fno-stack-clash-protection",
	"-fcf-protection=none",
	"-fzero-call-used-regs=skip",
	"-U_FORTIFY_SOURCE",
	"-Wno-format-security",
	"-fno-asynchronous-unwind-tables",
	"-fno-unwind-tables",
	"-fno-common",
	"-ffunction-sections",
	"-fdata-sections",
}

// module_c_commands gives the command of clang for each C file of the
// outside source of a module, in the order of the names, and an empty list
// for a module with no C part. Each command names the folder of the store,
// which Nix names by the hash of its content: the build key of the module
// holds the commands, so a change of a patch or of a file of the system
// builds the module again. The objects go into the folder of the objects of
// the module, which the link reads whole.
module_c_commands :: proc(build: foundation.Module_Build) -> (commands: [][]string, ok: bool) {
	if build.c_source.folder == "" {
		return nil, true
	}
	objects := foundation.join(foundation.module_build_folder, "/", build.name, "/objects")
	return outside_source_c_commands(build.c_source, foundation.join("the module ", build.name), objects)
}

// c_source_folder gives the folder of the store of an outside source,
// which its variable names. user names the one who compiles it, for the
// message when the variable is not set.
c_source_folder :: proc(c_source: foundation.Outside_Source, user: string) -> (folder: string, ok: bool) {
	folder = os.get_env(c_source.variable, context.temp_allocator)
	if folder == "" {
		fmt.eprintfln("modustool: %s compiles in the C files of %s, and the variable %s is not set: run the tool in a shell of the flake (src/md/infrastructure/outside_source.md)", user, c_source.work, c_source.variable)
		return "", false
	}
	return folder, true
}

// outside_source_c_commands gives the command of clang for each C file at
// the top of the folder of an outside source, in the order of the names,
// with each object in the folder objects.
outside_source_c_commands :: proc(c_source: foundation.Outside_Source, user: string, objects: string) -> (commands: [][]string, ok: bool) {
	folder := c_source_folder(c_source, user) or_return
	sources := foundation.files_with_suffix(folder, ".c") or_return
	if len(sources) == 0 {
		fmt.eprintfln("modustool: the folder %s of %s (the variable %s) has no C file", folder, c_source.work, c_source.variable)
		return nil, false
	}
	list := make([dynamic][]string, context.temp_allocator)
	for source in sources {
		name := strings.trim_suffix(source[strings.last_index(source, "/") + 1:], ".c")
		command := make([dynamic]string, context.temp_allocator)
		append(&command, "clang")
		append(&command, ..c_compile_flags[:])
		// The headers of the thin libc first: a folder of -I comes before
		// each folder of -isystem that the wrapper adds.
		append(&command, foundation.join("-I", folder, "/libc/include"), foundation.join("-I", folder))
		// __FILE__ names the work, not a folder of the store.
		append(&command, foundation.join("-ffile-prefix-map=", folder, "=", c_source.work))
		append(&command, "-c", "-o", foundation.join(objects, "/c_", name, ".o"), source)
		append(&list, command[:])
	}
	return list[:], true
}

// module_linked_file gives the path of the linked file of a module: the
// output of its compile step, and the input of its conversion.
module_linked_file :: proc(name: string) -> string {
	return foundation.join(foundation.module_build_folder, "/", name, "/linked.elf")
}

// build_module runs the two steps of the build of a module, one after the
// other: the compile step, then the conversion.
build_module :: proc(build: foundation.Module_Build) -> bool {
	return module_compile(build) && module_convert(build)
}

// module_compile is the compile step of a module: it compiles a package
// to objects, assembles its .asm files, compiles the C files of its
// outside source when it has one, and links all with lld into one
// position-independent object, the linked file.
//
// The step reads no file of an import. A source names an export of an
// import in a `foreign` block, with no file behind it: the compiler makes
// a call to a symbol that is not defined, and the link leaves it not
// defined. So the linked file is the same for every file of an import,
// and the build key of this step holds none (incremental_build.odin).
module_compile :: proc(build: foundation.Module_Build) -> bool {
	folder := foundation.join(foundation.module_build_folder, "/", build.name)
	objects := foundation.join(folder, "/objects")
	foundation.reset_folder(objects) or_return
	llvm_ir_folder := foundation.join(folder, "/llvm_ir")
	foundation.reset_folder(llvm_ir_folder) or_return
	// The list of an earlier build must not stay when this compiler fails.
	_ = os.remove(module_dependency_file(build.name))
	compile := module_compile_command(build)
	foundation.run(compile[:]) or_return
	// Odin writes the IR in the folder of -out, with the name of the first
	// package of the module. The folder was empty: its one .ll file is the IR.
	llvm_ir_files := foundation.files_with_suffix(llvm_ir_folder, ".ll") or_return
	if len(llvm_ir_files) != 1 {
		fmt.eprintfln("modustool: the compiler wrote %d LLVM IR files for %s; one module is one file", len(llvm_ir_files), build.name)
		return false
	}
	if err := foundation.file_move(llvm_ir_files[0], foundation.join(folder, "/", build.name, ".ll")); err != nil {
		fmt.eprintfln("modustool: cannot move the LLVM IR of %s: %v", build.name, err)
		return false
	}
	{
		// The time of the compile leaves the IR: a build is the same bytes
		// as the build before (compile_time.odin).
		path := foundation.join(folder, "/", build.name, ".ll")
		ir := foundation.read_file(path) or_return
		if without, changed := llvm_ir_without_compile_time(string(ir), context.temp_allocator); changed > 0 {
			if err := os.write_entire_file(path, without); err != nil {
				fmt.eprintfln("modustool: cannot write the LLVM IR of %s: %v", build.name, err)
				return false
			}
		}
		// The key of each fact type that the module writes is an immediate
		// of its code: the typeid that this compiler gives the type
		// (src/md/features/log_facts.md, "The fact key: why the typeid").
		// A fact type of a support package whose call the code does not
		// reach has no immediate, and no row: the list names the others.
		// The facts are read from the sources that the compiler read: its
		// list, with no path of the store, is written first.
		module_source_list_write(build.name) or_return
		facts := module_facts_of_sources(build) or_return
		reached, problem := facts_reached(string(ir), facts, build.source)
		if problem != "" {
			fmt.eprintfln("modustool: log facts of %s: %s", build.name, problem)
			return false
		}
		module_reached_facts_write(build.name, reached) or_return
	}
	if build.kernel {
		// The features of llc for the kernel hold for all of the IR only
		// while no function of it has target features of its own: a
		// function attribute would take the place of -mattr for that
		// function. The disassembly after the link would find its vector
		// instructions; this test gives the cause first.
		ir := foundation.read_file(foundation.join(folder, "/", build.name, ".ll")) or_return
		if strings.contains(string(ir), "\"target-features\"") {
			fmt.eprintfln("modustool: the LLVM IR of %s has functions with target features of their own: the features of llc for the kernel would not hold for them", build.name)
			return false
		}
	}
	// The counted kernel: the edge counters, after each check of the IR of
	// the source, and the count of its guards for nasm.
	edge_count := 0
	if foundation.module_counts_kernel_edges(build) {
		edge_count = kernel_edge_counters_instrument(build) or_return
	}
	foundation.run(module_object_command(build)) or_return
	{
		// No unwind table in the object. No part of the system reads one:
		// the converter leaves it out of the module, and a stack trace
		// walks the frame pointers. With debug information llc writes an
		// entry for more functions, so the table has another size, and
		// the code and the data after it have other addresses: the module
		// would not be the same bytes with and without debug information.
		object := foundation.join(folder, "/objects/", build.name, ".o")
		foundation.run({"llvm-objcopy", "--remove-section=.eh_frame", "--remove-section=.rela.eh_frame", object}) or_return
	}
	assembly := module_assembly_files(build) or_return
	for source in assembly {
		name := source[strings.last_index(source, "/") + 1:]
		if build.kernel && source == RUNTIME_MEMORY {
			// The kernel form of the copies: no vector register.
			foundation.run({"nasm", "-f", "elf64", "-DWITHOUT_VECTOR_REGISTERS", "-o", foundation.join(objects, "/", name, ".o"), source}) or_return
		} else if source == KERNEL_EDGE_COUNTERS_ASSEMBLY {
			// The array of the counters has the count of the guards.
			foundation.run({"nasm", "-f", "elf64", fmt.tprintf("-DEDGE_COUNT=%d", edge_count), "-o", foundation.join(objects, "/", name, ".o"), source}) or_return
		} else {
			foundation.run({"nasm", "-f", "elf64", "-o", foundation.join(objects, "/", name, ".o"), source}) or_return
		}
	}
	// The C files of an outside source join the same link.
	c_commands := module_c_commands(build) or_return
	for command in c_commands {
		foundation.run(command) or_return
	}

	description := describe_package(build.source) or_return
	export_names := make([dynamic]string, context.temp_allocator)
	for export in description.exports {
		append(&export_names, export.name)
	}
	linked := module_linked_file(build.name)
	module_objects_link(folder, objects, export_names[:], linked) or_return
	if build.kernel {
		listing := kernel_listing(linked) or_return
		kernel_has_no_vector_instruction(listing) or_return
		kernel_stack_check(build, linked, listing) or_return
	}
	return true
}

// module_objects_link links each object of the folder objects with lld
// into one position-independent object, linked. Only the exports are
// visible in it: the version script of the folder makes each other symbol
// local.
module_objects_link :: proc(folder: string, objects: string, export_names: []string, linked: string) -> bool {
	script := strings.builder_make(context.temp_allocator)
	strings.write_string(&script, "{ global: ")
	for name in export_names {
		fmt.sbprintf(&script, "%s; ", name)
	}
	strings.write_string(&script, "local: *; };\n")
	script_path := foundation.join(folder, "/exports.version")
	if err := os.write_entire_file(script_path, strings.to_string(script)); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", script_path, err)
		return false
	}
	link := make([dynamic]string, context.temp_allocator)
	append(
		&link,
		"ld.lld",
		"-shared",
		"-nostdlib",
		"-Bsymbolic",
		"--gc-sections",
		"--build-id=none",
		"-z",
		"now",
		"-z",
		"relro",
		foundation.join("--version-script=", script_path),
		"-o",
		linked,
	)
	append(&link, ..(foundation.files_with_suffix(objects, ".o") or_return))
	return foundation.run(link[:])
}

// module_convert is the conversion of a module: it writes the module file
// from the linked file, with the description of the exports and the hash
// of the file of each import, then the debug object.
//
// It is the one step that reads the file of an import: for its hash, and
// for the number of each export that an import slot names. It runs no compiler.
module_convert :: proc(build: foundation.Module_Build) -> bool {
	description := describe_package(build.source) or_return
	// The category of the row, from the row itself and never from its name:
	// a module from outside the repository can have the name of a module of
	// the system, and its folder is in no module group, so it states none.
	category_problem: string
	description.category, category_problem = foundation.module_category_of_row(build)
	if category_problem != "" {
		fmt.eprintfln("modustool: %s", category_problem)
		return false
	}
	description.tags = build.tags
	// The log facts of the sources that the compiler read and that the
	// code of the module reaches: the table Facts and the records of their
	// types.
	sources := module_sources(build) or_return
	facts := module_facts(build, sources) or_return
	facts_merge(&description, facts) or_return
	// The record outputs and the record inputs that the package declares:
	// the tables Record_Outputs and Record_Inputs and their records.
	outputs, inputs := record_streams_of_sources(build.source, sources) or_return
	record_streams_merge(&description, outputs, inputs) or_return
	// The floor of the table Floor counts the load of each import, at each
	// level, the start objects of the packages that the compiler read, and
	// the floors of the children.
	description.budget.has_entry = build.entry
	if build.entry || description.budget.stated {
		description.budget.import_costs = floor_import_costs(build) or_return
		description.budget.start_objects = start_objects_of_sources(build.source, sources) or_return
		description.budget.children = floor_children_of(build) or_return
		description.budget.start_budgets = start_budgets_of_sources(build.source, sources) or_return
		description.budget.wiring_derived = floor_wiring_derived(build.name, build.source, sources) or_return
	}
	elf := foundation.read_file(module_linked_file(build.name)) or_return
	imports := make([dynamic]Import_File, context.temp_allocator)
	for name in build.imports {
		append(&imports, Import_File{name = name, file = foundation.read_file(foundation.module_import_path(name)) or_return})
	}
	import_slot_symbols := make([dynamic]string, context.temp_allocator)
	file := convert(build.name, elf, description, imports[:], &import_slot_symbols) or_return
	defer delete(file)
	// The linked file holds the name of each imported export and no type:
	// the declarations of the sources are compared with the descriptions
	// here, where both are at hand, and each symbol that became an import slot must
	// have one compared declaration (import_declarations.odin). The module
	// file is written only after the check.
	import_declarations_check(build, imports[:], import_slot_symbols[:]) or_return
	if build.library {
		module_is_a_library_check(build.name, file) or_return
	}
	if err := os.write_entire_file(foundation.module_path(build.name), file); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", foundation.module_path(build.name), err)
		return false
	}
	if debug_information {
		debug_object_write(build.name, elf, file) or_return
	}
	return true
}

// build_boot_image writes the modules that have `image` set, then the
// resources, into one block (boot_info/boot_info.odin). It leaves out the
// module `without`. A resource has its name and the hash of its bytes, as a
// module. This image has no system description: each boot
// volume gets a copy with its own (system_description.odin).
build_boot_image :: proc(path: string, without: string, resource_files: []resources.Resource_File) -> bool {
	files := make([dynamic]Image_File, context.temp_allocator)
	for build in foundation.module_builds {
		in_this_image := foundation.module_in_boot_image(build) && build.name != without || foundation.module_in_a_boot_image(build) && build.only_in_image == path
		if !in_this_image {
			continue
		}
		append(&files, Image_File{name = build.name, file = foundation.read_file(foundation.module_path(build.name)) or_return})
	}
	module_count := len(files)
	for resource in resource_files {
		append(&files, Image_File{name = resource.name, file = foundation.read_file(resource.path) or_return})
	}
	// The start list and the rescue list of this image, checked against
	// its modules (start_lists.odin).
	lists := start_list_resources(path, without) or_return
	for resource in lists {
		append(&files, Image_File{name = resource.name, file = foundation.read_file(resource.path) or_return})
	}
	image := boot_image_encode(files[:], module_count)
	if err := os.write_entire_file(path, image); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, err)
		return false
	}
	return true
}

// One file of a boot image: a module or a resource.
Image_File :: struct {
	name: string,
	file: []u8,
}

// boot_image_encode gives the bytes of a boot image: the header, the table
// of the first module_count files (the modules), the table of the others
// (the resources), then each file on a page boundary, each entry with the
// BLAKE3 hash of its file.
boot_image_encode :: proc(files: []Image_File, module_count: int) -> []u8 {
	entries := make([]info.Image_Entry, len(files), context.temp_allocator)
	image := make([dynamic]u8, context.temp_allocator)
	resize(&image, size_of(info.Image_Header) + len(files) * size_of(info.Image_Entry))
	for item, index in files {
		entries[index].hash = blake3.hash(item.file)
		entries[index].size = u64(len(item.file))
		copy(entries[index].name[:info.IMAGE_NAME_SIZE - 1], item.name)
		resize(&image, mem.align_forward_int(len(image), info.PAGE_SIZE))
		entries[index].offset = u64(len(image))
		append(&image, ..item.file)
	}
	header := info.Image_Header{magic = info.IMAGE_MAGIC, count = u32(module_count), resource_count = u32(len(files) - module_count)}
	mem.copy(&image[0], &header, size_of(header))
	if len(entries) > 0 {
		mem.copy(&image[size_of(header)], &entries[0], len(entries) * size_of(info.Image_Entry))
	}
	return image[:]
}

// A module that the tool loaded in its own address space.
Host_Module :: struct {
	file:   []u8,
	memory: []u8,
}

// load_on_host loads a module in the address space of this tool, with the
// loader code that the system uses (package module). imports are the loaded
// modules of the import table, in order.
load_on_host :: proc(name: string, imports: []Host_Module) -> (loaded: Host_Module, ok: bool) {
	fail :: proc(name: string, format: string, args: ..any) -> (Host_Module, bool) {
		fmt.eprintf("modustool: load %s: ", name)
		fmt.eprintfln(format, ..args)
		return {}, false
	}
	file := foundation.read_file(foundation.module_path(name)) or_return
	if error := module.validate(file); error != .None {
		return fail(name, "%v", error)
	}
	head, _ := module.header(file)
	if int(module.count(file, .Imports)) != len(imports) + 1 {
		return fail(name, "the module has %d imports; %d were given", module.count(file, .Imports) - 1, len(imports))
	}
	bound := make([dynamic]module.Bound_Import, context.temp_allocator)
	for item, index in imports {
		record, _ := module.record(file, .Imports, u32(index + 1), module.Import)
		if record.hash != blake3.hash(item.file) {
			return fail(name, "import %d does not have the hash that the module names", index + 1)
		}
		append(&bound, module.Bound_Import{file = item.file, base = uintptr(raw_data(item.memory))})
	}

	address, map_error := linux.mmap(0, uint(head.memory_size), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	if map_error != .NONE {
		return fail(name, "cannot reserve %d bytes: %v", head.memory_size, map_error)
	}
	memory := ([^]u8)(address)[:head.memory_size]
	module.copy_segments(file, memory)
	if error := module.rebase(file, memory, uintptr(address)); error != .None {
		return fail(name, "rebase: %v", error)
	}
	if error: module.Load_Error; !module.bind(file, memory, bound[:], &error) {
		return fail(name, "bind: %v of import slot %d", error.stage, error.import_slot)
	}
	// Each loader writes the hash of the module at its own-hash place.
	if !module.own_hash_write(file, memory, blake3.hash(file)) {
		return fail(name, "the own-hash place is not in writable data")
	}
	if !module.record_stream_indexes_write(file, memory) {
		return fail(name, "the place of a record stream is not in writable data")
	}
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		protection: linux.Mem_Protection
		if .Read in segment.flags {protection += {.READ}}
		if .Write in segment.flags && .Read_Only_After_Load not_in segment.flags {protection += {.WRITE}}
		if .Execute in segment.flags {protection += {.EXEC}}
		if error := linux.mprotect(raw_data(memory[segment.memory_offset:]), uint(segment.memory_size), protection); error != .NONE {
			return fail(name, "cannot protect segment %d: %v", index, error)
		}
	}
	return {file = file, memory = memory}, true
}

// test_descriptions reads the description of each export from a module
// file, and compares it with the source of the module.
test_descriptions :: proc() -> bool {
	type_names := [module.Type]string {
		.None    = "None",
		.Integer = "Integer",
		.Text    = "Text",
		.Record  = "Record",
		.Handle  = "Handle",
		.Table   = "Table",
		.Bytes   = "Bytes",
		.Enum    = "Enum",
	}
	for build in foundation.module_builds {
		file := foundation.read_file(foundation.module_path(build.name)) or_return
		described := describe_package(build.source) or_return
		sources := module_sources(build) or_return
		facts := module_facts(build, sources) or_return
		facts_merge(&described, facts) or_return
		outputs, inputs := record_streams_of_sources(build.source, sources) or_return
		record_streams_merge(&described, outputs, inputs) or_return
		exports := described.exports
		about, text := module.documentation(file)
		if about != described.about || text != described.text || about == "" {
			fmt.eprintfln("modustool: test failed: the documentation of %s does not agree with its source", build.name)
			return false
		}
		if int(module.count(file, .Exports)) != len(exports) + 1 {
			fmt.eprintfln("modustool: test failed: %s has %d exports, its source has %d", build.name, module.count(file, .Exports) - 1, len(exports))
			return false
		}
		last := strings.builder_make(context.temp_allocator)
		for description, index in exports {
			function, ok := module.function(file, u32(index + 1))
			agree :=
				ok &&
				module.string_at(file, function.name_offset, function.name_count) == description.name &&
				module.string_at(file, function.about_offset, function.about_count) == description.about &&
				module.string_at(file, function.text_offset, function.text_count) == description.text &&
				int(function.parameter_count) == len(description.parameters) &&
				function.result == u8(description.result) &&
				function.result_detail == description.result_detail &&
				function.error_record == description.error_record
			strings.builder_reset(&last)
			fmt.sbprintf(&last, "%s(", description.name)
			for parameter in 0 ..< (agree ? len(description.parameters) : 0) {
				parameter_name := module.string_at(file, function.parameter_names[parameter], u32(function.parameter_name_counts[parameter]))
				agree &&= function.parameters[parameter] == u8(description.parameters[parameter]) && parameter_name == description.names[parameter]
				agree &&= function.parameter_details[parameter] == description.details[parameter]
				agree &&= function.parameter_directions[parameter] == u8(description.directions[parameter])
				fmt.sbprintf(&last, "%s%s: %s", parameter > 0 ? ", " : "", parameter_name, type_names[description.parameters[parameter]])
			}
			fmt.sbprintf(&last, ") -> %s", type_names[description.result])
			if !agree {
				fmt.eprintfln("modustool: test failed: the description of %s in %s does not agree with its source", description.name, build.name)
				return false
			}
		}
		// The records: the file has the layout that the tool read in the source.
		if int(max(module.count(file, .Records), 1)) != len(described.records) + 1 {
			fmt.eprintfln("modustool: test failed: %s has %d records, its source has %d", build.name, int(module.count(file, .Records)) - 1, len(described.records))
			return false
		}
		for item, index in described.records {
			record, ok := module.record_type(file, u32(index + 1))
			agree := ok && module.string_at(file, record.name_offset, record.name_count) == item.name && record.size == item.size && int(record.field_count) == len(item.fields)
			layout := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&layout, "%s {{", item.name)
			for field, number in (agree ? item.fields : nil) {
				stored, _ := module.field(file, record, u32(number))
				agree &&= module.string_at(file, stored.name_offset, stored.name_count) == field.name && stored.offset == field.offset && stored.type == u8(field.type) && stored.detail == field.detail && stored.unsigned == field.unsigned
				fmt.sbprintf(&layout, "%s%s: %s at %d", number > 0 ? ", " : "", field.name, type_names[field.type], field.offset)
			}
			if !agree {
				fmt.eprintfln("modustool: test failed: the record %s in %s does not agree with its source", item.name, build.name)
				return false
			}
			foundation.test_passed_print("the record %s}}, %d bytes, of %s comes from its source", strings.to_string(layout), item.size, build.name)
		}
		// The floor of the module: the table Floor of each module with an
		// entry holds the parts that the source states and the counted
		// parts, computed here again from the sources and the files; a
		// library has no table.
		floor, has_floor := module.floor_read(file)
		if has_floor != (build.entry || described.budget.stated) {
			fmt.eprintfln("modustool: test failed: %s has %s table Floor, and it %s", build.name, has_floor ? "a" : "no", build.entry ? "has an entry" : "has no entry")
			return false
		}
		if has_floor {
			inputs := Floor_Inputs{stated = described.budget.parts}
			own, own_ok := module_cost_of_file(file)
			if !own_ok {
				return false
			}
			modules := make([dynamic]Module_Cost, context.temp_allocator)
			append(&modules, own)
			append(&modules, ..(floor_import_costs(build) or_return))
			inputs.modules = modules[:]
			inputs.start_objects = start_objects_of_sources(build.source, sources) or_return
			inputs.children = floor_children_of(build) or_return
			inputs.start_budgets = start_budgets_of_sources(build.source, sources) or_return
			inputs.wiring_derived = floor_wiring_derived(build.name, build.source, sources) or_return
			counted, counted_ok := floor_count(inputs)
			if !counted_ok || floor != counted.floor {
				fmt.eprintfln("modustool: test failed: the floor of %s, %d pages, %d processes, %d threads, is not its stated parts and its counted parts: %s", build.name, floor.pages, floor.processes, floor.threads, floor_count_line(counted))
				return false
			}
			foundation.test_passed_print("the floor of %s is its stated parts and its counted parts: %s", build.name, floor_count_line(counted))
		}
		// The log facts: each row of the table Facts is the fact type of its
		// source, in the order of the keys, and the template is valid.
		if int(max(module.count(file, .Facts), 1)) != len(described.facts) + 1 {
			fmt.eprintfln("modustool: test failed: %s has %d log facts, its sources write %d", build.name, int(module.count(file, .Facts)) - 1, len(described.facts))
			return false
		}
		for item, index in described.facts {
			row, row_record, row_ok := module.fact(file, u32(index + 1))
			agree := row_ok && row.key == item.key && row.record == item.record_index && module.string_at(file, row.template_offset, row.template_count) == item.template && module.string_at(file, row.package_offset, row.package_count) == item.package_name
			if !agree || module.fact_template_valid(file, row, row_record) != .None {
				fmt.eprintfln("modustool: test failed: the log fact %s.%s in %s does not agree with its source", item.package_name, item.type_name, build.name)
				return false
			}
			foundation.test_passed_print("the log fact %s.%s of %s, key %d, comes from its source: \"%s\"", item.package_name, item.type_name, build.name, item.key, item.template)
		}
		// The record outputs and the record inputs: each row is the
		// declaration of its source, in the order of the names, and the
		// tables keep the rules of a reader.
		if fault, place := module.record_streams_check(file); fault != .None {
			fmt.eprintfln("modustool: test failed: the record streams of %s break a rule: %v at the row %d", build.name, fault, place)
			return false
		}
		if int(max(module.count(file, .Record_Outputs), 1)) != len(described.record_outputs) + 1 || int(max(module.count(file, .Record_Inputs), 1)) != len(described.record_inputs) + 1 {
			fmt.eprintfln("modustool: test failed: %s has %d record outputs and %d record inputs, its source declares %d and %d", build.name, int(max(module.count(file, .Record_Outputs), 1)) - 1, int(max(module.count(file, .Record_Inputs), 1)) - 1, len(described.record_outputs), len(described.record_inputs))
			return false
		}
		for item, index in described.record_outputs {
			row, pairing, _, row_ok := module.record_output(file, u32(index + 1))
			if !row_ok || module.string_at(file, row.name_offset, row.name_count) != item.name || module.string_at(file, row.about_offset, row.about_count) != item.about || row.record != item.record_index || pairing != item.pairing {
				fmt.eprintfln("modustool: test failed: the record output %s of %s does not agree with its source", item.name, build.name)
				return false
			}
			foundation.test_passed_print("the record output %s.%s of the record %s comes from its source", build.name, item.name, item.generic ? "Any_Record" : item.record.name)
		}
		for item, index in described.record_inputs {
			row, wirings, _, _, row_ok := module.record_input(file, u32(index + 1))
			if !row_ok || module.string_at(file, row.name_offset, row.name_count) != item.name || module.string_at(file, row.about_offset, row.about_count) != item.about || row.record != item.record_index || row.terms != item.terms_index || wirings != item.wirings {
				fmt.eprintfln("modustool: test failed: the record input %s of %s does not agree with its source", item.name, build.name)
				return false
			}
			foundation.test_passed_print("the record input %s.%s of the record %s, %v, comes from its source", build.name, item.name, item.generic ? "Any_Record" : item.record.name, item.wirings)
		}
		if build.name == "math" {
			foundation.test_passed_print("the documentation of %s comes from its source: \"%s\", and %d bytes of text", build.name, about, len(text))
		}
		if len(exports) > 1 {
			foundation.test_passed_print("the %d descriptions of %s come from its source; the last is %s", len(exports), build.name, strings.to_string(last))
		}
	}
	return true
}

MODULE_TEST_RESULT :: (10 * 3 + 1) + (10 * 2 + 2)

// test_modules loads test_callee and test_caller on the host, and calls the
// entry of test_caller. The entry calls test_callee through an import slot.
test_modules :: proc() -> bool {
	callee := load_on_host("test_callee", nil) or_return
	caller := load_on_host("test_caller", {callee}) or_return
	head, _ := module.header(caller.file)
	address, ok := module.export_address(caller.file, uintptr(raw_data(caller.memory)), head.entry_export)
	if !ok {
		fmt.eprintln("modustool: test failed: test_caller has no entry")
		return false
	}
	entry := cast(proc "c" (context_address: rawptr) -> i64)rawptr(address)
	result := entry(nil)
	if result != MODULE_TEST_RESULT {
		fmt.eprintfln("modustool: test failed: the entry of test_caller gave %d, not %d", result, MODULE_TEST_RESULT)
		return false
	}
	hash := blake3.hash(callee.file)
	foundation.test_passed_print(
		"test_caller called test_callee (%d bytes, %d rebase words, hash %x...) and got %d",
		len(callee.file),
		module.count(callee.file, .Rebases),
		hash[:4],
		result,
	)
	return true
}

// build_system builds the modules, the boot images, and then the boot
// volumes that the caller boots: needed_volumes names them by their paths,
// and nil is every volume. A volume that the caller does not name is not
// built and not checked: no machine of this process starts from it
// (machine_command).
build_system :: proc(needed_volumes: []string) -> int {
	build_measure_start()
	if !build_modules() {
		return foundation.EXIT_FAILURE
	}
	volumes_started := time.tick_now()
	if !boot_volumes_build(needed_volumes) {
		return foundation.EXIT_FAILURE
	}
	build_measure_step("the boot volumes, in all", volumes_started)
	build_measure_print()
	return 0
}

// run_build is the command `build`: the modules, the boot images, and
// every boot volume. A module whose inputs are the same is kept, and so is
// each boot volume (incremental_build.odin, boot_volumes.odin); `build
// whole` keeps nothing.
run_build :: proc(args: []string) -> int {
	// `build [whole] [host_processes]`: a whole build, and the count of module
	// processes at once.
	rest := args
	if len(rest) >= 1 && rest[0] == "whole" {
		build_whole = true
		rest = rest[1:]
	}
	if len(rest) > 1 || (len(rest) == 1 && !parse_module_build_host_processes(rest[0])) {
		fmt.eprintln("modustool: build [whole] [host_processes]")
		return foundation.EXIT_USAGE
	}
	return build_system(nil)
}
