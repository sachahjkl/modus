// modustool: all the automation of the project, in one program.
//
//   nix develop -c modustool <command>
//
// The command of the development shell runs build/tool/modustool, which
// compiles itself again when its sources changed (tool_build.odin).
//
// The project has no scripts. Each build step, each test and each call to a
// third-party program is a command of this tool, so that the way a third-party
// program is run is written in one place.
//
// The development shell of flake.nix supplies what this tool needs:
//   on the path: odin, lld-link, ld.lld, nasm, qemu-system-x86_64, swtpm
//   OVMF_CODE, OVMF_VARS: the UEFI firmware image and its variable store
//   OVMF_TPM_CODE, OVMF_TPM_VARS: the same firmware with a TPM driver and
//     no system management mode, for the machines of the measure and the
//     machine of the TPM with Secure Boot off
//   OVMF_FULL_CODE, OVMF_FULL_VARS: the firmware with Secure Boot, a TPM
//     driver and system management mode, for the machines of Secure Boot
//     and the machines of the keys sealed by the TPM
//   SYSTEM_SIGNING_KEY (not set by the shell): the private key of the
//     principal that signs the system description; with none,
//     the test signing key of resources/keys (system_description.odin).
//     Its folder also holds the firmware signing key and the release
//     signing key (release_image.odin)
//   SYSTEM_SIGNING_KEY_TEXT, FIRMWARE_SIGNING_KEY_TEXT,
//     FIRMWARE_CERTIFICATE_TEXT, RELEASE_SIGNING_KEY_TEXT (not set by the
//     shell): the values of a key folder, for the command "key write"
//   on the path for "release image" and the release machine of
//     "test trusted_boot": zstd
//   MODUS_SYSTEM (not set by the shell): the folder of the system, for the
//     command "module-build" run from the folder of another project
//     (outside_module.odin)
//   FONT_SOURCE: the BDF file of the font, for the command "font"
//   POINTER_THEME_SOURCE: the folder of the Xcursor theme of the owner (docs/POINTERS.md);
//     only the default shell sets it, and `release image` ignores it
//   VECTOR_FONT_SOURCES: the font files of the vector font candidates, for the command "vector_fonts"
package modustool

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "modus:contract/remote"
import "modus:contract/timed_stream"
import "modus:support/pci"

EXIT_FAILURE :: 1
EXIT_USAGE :: 2

ROOT_MARK :: "flake.nix"

BUILD_FOLDER :: "build"

// The one source library of the project (docs/glossary/communication.md, "Source
// library"). An import names the library, then one of its two parts:
// "modus:contract/ring", "modus:support/system".
//   contract   what two parties agree on: records, numbers, and the code
//              that reads them. It uses no kernel operation. The kernel
//              imports these packages and its own kernel parts only.
//   support    what a program compiles in to use the contracts.
// The kernel parts are a second source library, "kernel:iommu". The names,
// the folders and the flags of the two libraries are in
// source_folders.odin; the rule of the kernel is held by
// library_imports_check.odin.

// The folders whose host tests `modustool check` runs: `odin test` on
// each, several at once (host_tests.odin). The pool starts them in this
// order, and reports them in it: the tool comes first, because its
// compile and its tests are the longest, and a long folder that starts
// last makes the whole run longer.
HOST_TEST_FOLDERS :: [?]string {
	TOOL_SOURCE_FOLDER,
	SOURCE_FOLDER_RUNTIME,
	SOURCE_FOLDER_CONTRACT + "/blake3",
	SOURCE_FOLDER_CONTRACT + "/module",
	SOURCE_FOLDER_CONTRACT + "/isolated",
	SOURCE_FOLDER_CONTRACT + "/pointer_pictures",
	SOURCE_FOLDER_CONTRACT + "/remote",
	SOURCE_FOLDER_CONTRACT + "/root_ring",
	SOURCE_FOLDER_CONTRACT + "/enum_word",
	SOURCE_FOLDER_SUPPORT + "/sentence",
	SOURCE_FOLDER_SUPPORT + "/cryptography/vectors",
	SOURCE_FOLDER_PRIVATE + "/cryptography/cryptography_primitives",
	SOURCE_FOLDER_SUPPORT + "/quic",
	SOURCE_FOLDER_CONTRACT + "/date",
	SOURCE_FOLDER_CONTRACT + "/disk_program_page",
	SOURCE_FOLDER_KERNEL + "/iommu",
	SOURCE_FOLDER_CONTRACT + "/bridge_requester",
	SOURCE_FOLDER_KERNEL + "/debug_exception",
	SOURCE_FOLDER_KERNEL + "/processor_counters",
	SOURCE_FOLDER_KERNEL + "/stolen_time",
	SOURCE_FOLDER_PRIVATE + "/storage/storage_mount",
	SOURCE_FOLDER_PRIVATE + "/storage/storage_object",
	SOURCE_FOLDER_PRIVATE + "/storage/storage_tree",
	SOURCE_FOLDER_PRIVATE + "/storage/storage_retention",
	SOURCE_FOLDER_SUPPORT + "/principals",
	SOURCE_FOLDER_SUPPORT + "/tpm2",
	SOURCE_FOLDER_SUPPORT + "/disk_program",
	SOURCE_FOLDER_SUPPORT + "/calendar",
	SOURCE_FOLDER_SUPPORT + "/line_editor",
	SOURCE_FOLDER_PRIVATE + "/console/console_language",
	SOURCE_FOLDER_PRIVATE + "/debugger/debugging",
	LIBRARY_MODULE_SOURCES + "interface_module",
	LIBRARY_MODULE_SOURCES + "drawing",
	DEMONSTRATION_MODULE_SOURCES + "sample",
	SOURCE_FOLDER_SUPPORT + "/system",
	SOURCE_FOLDER_SUPPORT + "/twins",
	SOURCE_FOLDER_PRIVATE + "/kernel_events/kernel_events_rounds",
	SOURCE_FOLDER_CONTRACT + "/tpm_service",
	SOURCE_FOLDER_SUPPORT + "/storage",
	SOURCE_FOLDER_PRIVATE + "/compositor/bar",
	SOURCE_FOLDER_PRIVATE + "/compositor/palette",
	SOURCE_FOLDER_PRIVATE + "/compositor/clipboard",
	SOURCE_FOLDER_CONTRACT + "/palette_table",
	SOURCE_FOLDER_SUPPORT + "/bootscreen/image_card",
	SOURCE_FOLDER_SUPPORT + "/graphics",
	SOURCE_FOLDER_SUPPORT + "/interface",
	SOURCE_FOLDER_PRIVATE + "/inspect/addresses",
	SOURCE_FOLDER_PRIVATE + "/manual/information",
	SOURCE_FOLDER_SUPPORT + "/vector_font",
	SOURCE_FOLDER_SUPPORT + "/network",
	SOURCE_FOLDER_SUPPORT + "/tcp",
	SOURCE_FOLDER_SUPPORT + "/virtio",
	SOURCE_FOLDER_SUPPORT + "/bochs_display",
	SOURCE_FOLDER_SUPPORT + "/web",
	SOURCE_FOLDER_SUPPORT + "/cryptography/chacha20",
	SOURCE_FOLDER_SUPPORT + "/random",
	SOURCE_FOLDER_CONTRACT + "/entropy_service",
	SOURCE_FOLDER_CONTRACT + "/fixed_addresses",
	SOURCE_FOLDER_CONTRACT + "/settings",
	LIBRARY_MODULE_SOURCES + "text_shaping",
	SOURCE_FOLDER_SUPPORT + "/text_shaping",
	SOURCE_FOLDER_SUPPORT + "/mark",
	SOURCE_FOLDER_SUPPORT + "/terminal",
	SOURCE_FOLDER_CONTRACT + "/cut_mark",
	SOURCE_FOLDER_CONTRACT + "/text_encoding",
	SOURCE_FOLDER_RUNTIME + "/without_vector_registers",
	SOURCE_FOLDER_SUPPORT + "/instruction_sets",
	SOURCE_FOLDER_CONTRACT + "/system_description",
	SOURCE_FOLDER_CONTRACT + "/replacement_list",
	SOURCE_FOLDER_PRIVATE + "/root/replacement_signature",
	SOURCE_FOLDER_CONTRACT + "/operation",
	SOURCE_FOLDER_CONTRACT + "/operation_sequence",
	SOURCE_FOLDER_CONTRACT + "/debug_object",
	SOURCE_FOLDER_CONTRACT + "/value_kinds",
	SOURCE_FOLDER_PRIVATE + "/manual/source_comment_markdown",
	SOURCE_FOLDER_PRIVATE + "/console/console_results",
	SOURCE_FOLDER_SUPPORT + "/key_path",
	SOURCE_FOLDER_SUPPORT + "/kind_icons",
	SOURCE_FOLDER_CONTRACT + "/manual_pages",
	SOURCE_FOLDER_PRIVATE + "/manual/manual_navigation",
	SOURCE_FOLDER_CONTRACT + "/ring",
	SOURCE_FOLDER_CONTRACT + "/glyph_cache",
	SOURCE_FOLDER_CONTRACT + "/datagram",
	SOURCE_FOLDER_CONTRACT + "/byte_order",
	SOURCE_FOLDER_CONTRACT + "/timed_stream",
	SOURCE_FOLDER_KERNEL + "/acpi_processors",
}
BOOT_OBJECT_FOLDER :: BUILD_FOLDER + "/boot"
// The boot program of the main boot volume, and its object: each boot
// volume has its own object folder (boot_volumes.odin).
BOOT_PROGRAM :: BOOT_OBJECT_FOLDER + "/" + MAIN_BOOT_VOLUME_NAME + "/" + BOOT_PROGRAM_FILE_NAME
BOOT_PROGRAM_OBJECT :: BOOT_OBJECT_FOLDER + "/" + MAIN_BOOT_VOLUME_NAME + "/" + BOOT_PROGRAM_OBJECT_FILE_NAME
BOOT_VOLUME :: BUILD_FOLDER + "/boot_volume.img"
BOOT_VOLUME_FAILS :: BUILD_FOLDER + "/boot_volume_fails.img"
BOOT_VOLUME_SHORTAGE :: BUILD_FOLDER + "/boot_volume_shortage.img"
BOOT_VOLUME_MEASURE :: BUILD_FOLDER + "/boot_volume_measure.img" // The boot image of a measure run: `modustool measure`.
BOOT_VOLUME_WITHOUT_RETURN_CHECK :: BUILD_FOLDER + "/boot_volume_without_return_check.img" // The kernel kernel_without_return_check: one machine of `test return_fault` only.
TEST_OUTPUT_SHORTAGE :: BUILD_FOLDER + "/test_output_shortage.txt"
// The machine of the operation sequences (operation_sequences.odin), with
// the kernel that ships.
BOOT_VOLUME_OPERATION_SEQUENCES :: BUILD_FOLDER + "/boot_volume_operation_sequences.img"
TEST_OUTPUT_OPERATION_SEQUENCES :: BUILD_FOLDER + "/test_output_operation_sequences.txt"
BOOT_VOLUME_SELF_TEST :: BUILD_FOLDER + "/boot_volume_self_test_%d.img"
// The volumes of `test trusted_boot` (trusted_boot_scenario.odin): one byte
// of a module changed after the system description was made; one bit of the
// description signature changed; one byte of a module changed before it was
// made (another system, signed, measured).
BOOT_VOLUME_CHANGED_MODULE :: BUILD_FOLDER + "/boot_volume_changed_module.img"
BOOT_VOLUME_WRONG_SIGNATURE :: BUILD_FOLDER + "/boot_volume_wrong_signature.img"
BOOT_VOLUME_OTHER_SYSTEM :: BUILD_FOLDER + "/boot_volume_other_system.img"
// More volumes that the boot program must refuse: one byte of the kernel
// changed; no system description; an entry that states another hash.
BOOT_VOLUME_CHANGED_KERNEL :: BUILD_FOLDER + "/boot_volume_changed_kernel.img"
BOOT_VOLUME_WITHOUT_DESCRIPTION :: BUILD_FOLDER + "/boot_volume_without_description.img"
BOOT_VOLUME_STATED_HASH :: BUILD_FOLDER + "/boot_volume_stated_hash.img"
// The boot program signed for Secure Boot, and the same with one byte
// changed after the signature (secure_boot.odin).
BOOT_VOLUME_SECURE_BOOT :: BUILD_FOLDER + "/boot_volume_secure_boot.img"
BOOT_VOLUME_SECURE_BOOT_CHANGED :: BUILD_FOLDER + "/boot_volume_secure_boot_changed.img"
// The volumes of the TPM floors, signed for Secure Boot: a newer system (a
// security version one above the repository), and a newer system whose
// boot program has a newer key (a key number one above too).
BOOT_VOLUME_NEWER_SYSTEM :: BUILD_FOLDER + "/boot_volume_newer_system.img"
BOOT_VOLUME_NEWER_KEY :: BUILD_FOLDER + "/boot_volume_newer_key.img"
// The path where the firmware looks for the boot program of a disk.
BOOT_PROGRAM_PATH :: "EFI/BOOT/BOOTX64.EFI"
// The private copy of the variable store of the firmware of `run`. A test
// machine has its own copy beside its log, with the same name after the
// name of its log (machine_command): two machines that run at the same
// time never write one store.
FIRMWARE_VARIABLES :: BUILD_FOLDER + "/ovmf_vars.fd"
FIRMWARE_FULL_VARIABLES :: BUILD_FOLDER + "/ovmf_full_vars.fd"
FIRMWARE_TPM_VARIABLES :: BUILD_FOLDER + "/ovmf_tpm_vars.fd"
FIRMWARE_VARIABLES_SUFFIX :: "_ovmf_vars.fd"
FIRMWARE_FULL_VARIABLES_SUFFIX :: "_ovmf_full_vars.fd"
FIRMWARE_TPM_VARIABLES_SUFFIX :: "_ovmf_tpm_vars.fd"
TEST_OUTPUT :: BUILD_FOLDER + "/test_output.txt"
TEST_OUTPUT_FAILS :: BUILD_FOLDER + "/test_output_fails.txt"
TEST_OUTPUT_SELF_TEST :: BUILD_FOLDER + "/test_output_self_test_%d.txt"
// The disks beside the boot volume (src/library/support/pci has their places on the
// bus). The data disk keeps the stores of the storage service: `run` uses
// one that stays from run to run; each part of the test makes a new one of
// its own (Test_Part_Run). The disk of the measures holds no data that a
// program keeps: `run` uses SCRATCH_DISK, and a test machine a new one
// beside its log.
DATA_DISK :: BUILD_FOLDER + "/data_disk.img"
SCRATCH_DISK :: BUILD_FOLDER + "/scratch_disk.img"
SCRATCH_DISK_SUFFIX :: "_scratch_disk.img"
// The processors of each machine (`-smp`). The whole test starts at most
// one part for each of these counts of processors of the host
// (test_parts_at_once).
MACHINE_PROCESSOR_COUNT :: 4
// The data disk of the three machines of the test of persistence: new
// before the first one, kept for the two others.
TEST_PERSIST_DISK :: BUILD_FOLDER + "/test_persist_disk.img"
TEST_OUTPUT_PERSIST :: BUILD_FOLDER + "/test_output_persist_%d.txt"
DATA_DISK_SIZE :: 64 << 20
SCRATCH_DISK_SIZE :: 32 << 20

DOCUMENT_SCREENSHOT_FOLDER :: "docs/screenshots"
// The pictures and other files of the repository that a build reads.
RESOURCE_FOLDER :: "resources"
// The development log: one folder of pictures per run of `screenshots`. It
// is beside the repository, not in it: no run replaces the pictures of
// another run. It is beside the main working tree: a run in a worktree
// writes there too, not beside the worktree.
DEVELOPMENT_LOG_NAME :: "kernel-devlog"

// development_log_folder gives the development log beside the main
// working tree.
development_log_folder :: proc() -> string {
	if !os.is_file(".git") {
		return "../" + DEVELOPMENT_LOG_NAME // The main working tree: .git is a folder.
	}
	content, _ := read_file(".git")
	return development_log_folder_of(string(content))
}

// development_log_folder_of gives the development log for the content of
// the file .git. In a worktree, it is "gitdir: <main>/.git/worktrees/<name>".
development_log_folder_of :: proc(git_file: string) -> string {
	text := strings.trim_space(git_file)
	if strings.has_prefix(text, "gitdir: ") {
		if at := strings.index(text, "/.git/worktrees/"); at > len("gitdir: ") {
			return join(text[len("gitdir: "):at], "/../", DEVELOPMENT_LOG_NAME)
		}
	}
	return "../" + DEVELOPMENT_LOG_NAME
}

Command :: struct {
	name, about: string,
	run:         proc(args: []string) -> int,
}

// The commands of the tool. The name is the first argument; the help after
// it is what `modustool help` prints, one line for each command. The comment
// above each command is its documentation on the site.
//
// `modustool` is the one program of the automation of the project: the
// build, the machine tests, the pictures, the measures, the changelog, the
// news and the site. The project has no script: each step of the work, by
// hand or in a workflow, is a command here, so each call of a third-party
// program (the compiler, the linker, QEMU) is written in one place.
//
// Run a command from the root of the repository, in the development shell
// of the flake, which gives the tool its compilers, QEMU and the firmware:
//
// ```
// nix develop -c modustool <command> <arguments>
// ```
//
// The tool writes into `build/`, which is not committed, and into the
// files of the repository that a command names (the pictures, the measure
// record, the changelog). A command ends with the status 0 when it
// succeeds, 1 when a step fails, and 2 when its arguments are wrong.
COMMANDS :: [?]Command {
	// Builds the whole system: each module, the boot image, and the boot
	// program that holds the kernel and the boot image.
	//
	// - `whole` (optional): a whole build: the tool ignores every build
	//   record and builds each module and each boot volume.
	// - `processes` (optional): the count of module builds at once; the count
	//   of the processors when it is absent.
	//
	// The build is incremental: a module whose inputs are the same as at
	// its last build is kept, and so is each boot volume. The command
	// prints the count of the modules and of the boot volumes that it kept,
	// and the measure of its time (docs/TOOLS.md, "The incremental build").
	//
	// Each module is built in its own process (the command `module`). The
	// command then builds the main boot volume, and the volumes that the tests
	// need: a start that must fail, a shortage of frames, the volumes that the
	// trusted boot must refuse (a changed module, a wrong signature, no
	// system description), the volumes of Secure Boot, and one volume for each
	// test of the kernel on itself. The volumes that must be built are built
	// at the same time, each in its own process (the command `volume`).
	// `run`, `test` and `measure` build first, with only the boot volumes
	// that they boot: run `build` alone to check that the whole system
	// compiles.
	//
	// ```
	// nix develop -c modustool build 8
	// ```
	{name = "build", about = "the modules, the boot image and the boot program, as " + BOOT_PROGRAM + "; one process for each module, as many at once as the processors, or `build <processes>`; a module or a boot volume whose inputs are the same is kept; `build whole`: ignore the build records and build all", run = run_build},
	// Builds one module of the table of modules in this process, with the
	// options of one build.
	//
	// - `name`: a module of the table (`module_builds`).
	// - `with_checks` or `without_checks`: the checks of the kernel (the order
	//   of the locks, the frames).
	// - `with_debug_information` or `without_debug_information`: the debug
	//   object beside the module.
	// - `compile` or `convert`: one step alone. `compile` writes the linked
	//   file; `convert` writes the module and its debug object from it.
	//
	// The parallel build of `build` runs this command once for each step of a module.
	// Run it by hand to see the errors of one module alone.
	{name = "module", about = "module <name> with_checks|without_checks with_debug_information|without_debug_information [compile|convert]: build one module of the table, and its debug object with the debug information, or run one of its two steps alone (the parallel build runs this command for each step)", run = run_module},
	// Builds one module from a folder outside the repository: the module
	// file and its debug object, with the two steps of a module of the
	// system.
	//
	// - `folder of the module`: a folder with one Odin package and the
	//   module build file `module.txt`: the name of the module, its imports,
	//   its settings of the compiler, and whether it is a library module.
	// - `--system <folder>`: the folder of the system. With none, the
	//   environment variable `MODUS_SYSTEM`, then the folder where the
	//   command runs.
	// - `--out <folder>`: the folder of the outputs. With none, the folder
	//   `build` in the folder of the module.
	//
	// It prints the hash of the module file, the hash of each import and
	// the names of the exports. A module with an import needs the built
	// modules of the system: run `build` in the folder of the system first
	// (docs/TOOLS.md, "A module from a source outside the repository").
	// Writes a data disk whose store of the programs holds module files: a
	// machine with that disk starts each one from its console, by its hash.
	{name = "program-disk", about = "program-disk <disk file to write> <module file> [<module file> ...]: write a data disk whose store `programs` holds each module file under the name of its file, with the debug object `<name>.debug` beside it under the hash of the module, and print the line of the console that starts each one", run = run_program_disk},
	{name = "module-build", about = "module-build <folder of the module> [--system <folder of the system>] [--out <folder of the outputs>]: build one module from a folder outside the repository, with its module build file `" + MODULE_BUILD_FILE_NAME + "`: write <name>.module and <name>.debug, and print the hash of the module and the names of its exports", run = run_module_build},
	// Builds one boot volume in this process: its boot image with the system
	// description, its boot program, and the volume file.
	//
	// - `name`: `main`, or the end of the name of the volume file:
	//   `shortage` for `build/boot_volume_shortage.img`.
	//
	// The build runs this command once for each boot volume that it must
	// build, several at once. Run it by hand, after a build, to see the
	// errors of one volume alone.
	{name = "volume", about = "volume <name>: build one boot volume, after a build wrote the modules and the boot images (the build runs this command for each volume that it must build)", run = run_volume},
	// Runs the machine tests: it builds, starts each test machine under QEMU,
	// plays its scenario, and checks its log.
	//
	// A scenario is a list of steps: press keys, move the pointer, wait for a
	// line of the log, save a picture of the screen. A step that waits ends at
	// the hang bound, never at a fixed delay: the test checks an order of
	// events, not a speed. Each machine writes its log in a file
	// `build/test_output*.txt` and its pictures in `build/screenshots`. The
	// whole run runs every part of the table of the parts, several at once,
	// each on a new data disk of its own, and prints the time of each part
	// (docs/TOOLS.md, "The parts of the machine test"). It ends with
	// "modustool: all tests passed".
	//
	// The build of the whole run builds every boot volume. The build of one
	// part builds only the boot volumes that the part boots
	// (docs/TOOLS.md, "The incremental build").
	//
	// - `part` (optional): one part only, for the work on it; a word that
	//   names no part is refused with the list of the parts.
	//
	// ```
	// nix develop -c modustool test network
	// ```
	{name = "test", about = "build, then run the parts of the machine test, several at once: start each machine under QEMU, press its keys and move its pointer, check the log, save pictures of the screen; `test <part>`: one part only", run = run_test},
	// Builds, then starts the machine under QEMU in a window, with the log of
	// the kernel on this terminal: the way to use the system by hand.
	//
	// - `without_checks` (optional): the build of the measures, with no check
	//   in the kernel.
	//
	// The data disk `build/data_disk.img` stays from run to run, so the
	// stores of the storage service keep their objects. The command also
	// starts the peer of the host that takes the calls of `modustool call`,
	// on a socket that only this user reaches. Close the window, or run
	// `shutdown()` in the console, to end it.
	{name = "run", about = "build, then start the machine under QEMU, with the log of the kernel on this terminal; `run without_checks`: the measure build", run = run_machine},
	// Takes the results of the check of the flake, which ran the whole
	// machine test and the second build, then publishes them into the
	// repository (src/md/infrastructure/full_check.md).
	//
	// It builds the check `boot-test` of the flake: Nix takes it from the
	// store when `nix flake check` passed on the same tree. It copies each
	// picture of the test to `docs/screenshots` and to a new dated folder of
	// the development log beside the repository, runs the measure runs on
	// the host, and writes the measure record (`docs/measures/measures.txt`):
	// the numbers of the logs of this run, with the commit, the host and the
	// count of checks. It is, with `nix flake check`, the full check before
	// a release.
	//
	// - `compress`: no machine; it compresses each PNG file of
	//   `docs/screenshots` and `resources` whose data is stored with no
	//   compression, and prints the bytes before and after.
	{name = "screenshots", about = "take the pictures and the logs of the check of the flake (its one run of the machine test), run the measure runs on the host, then write the measure record " + MEASURE_RECORD_FILE + " and copy the pictures to " + DOCUMENT_SCREENSHOT_FOLDER + " and to a new folder of the development log " + DEVELOPMENT_LOG_NAME + " beside the main working tree; `screenshots compress`: compress the PNG files of " + DOCUMENT_SCREENSHOT_FOLDER + " and " + RESOURCE_FOLDER + " whose data is stored, with no machine", run = run_screenshots},
	// Runs a machine that measures, with no other load: the numbers that it
	// prints are measures, never conditions of the test.
	//
	// Each machine is a measure run: its boot image holds the resource
	// `measure_run`, and a program then measures its rates over a duration.
	// The modules are those of the test.
	//
	// - no argument: the program `locks` on a machine where only the desktop
	//   runs: the kernel entries in one second with 1, 2 and 4 lockers, in
	//   `build/test_output_measure.txt`.
	// - `scheduler N`: N machines that run the program `scheduler` alone, in
	//   `build/test_output_scheduler_<n>.txt`.
	// - `clock`, `crowd`, `disk`, `flow`, `limits`: the program alone, in
	//   `build/test_output_measure_<program>.txt`; the command prints its
	//   lines.
	// - `windows`: each window of the interface package, alone, and a table of
	//   the time of its pictures.
	// - `address_space`, `shortage`: the machine of one measure.
	// - `without_checks ...`: the same, on the build with no check in the
	//   kernel.
	//
	// The tool checks no speed: a program checks its counts, and the numbers
	// are printed for a reader (docs/TOOLS.md, "The bounds of the tests").
	{name = "measure", about = "build, start the machine, run the measures of the locks of the kernel with no other program, then the frame at 1920x1080 of processor_frame, and stop: the numbers are in " + TEST_OUTPUT_MEASURE + "; `measure scheduler N`: the program scheduler N times; `measure clock|crowd|disk|flow|limits`: the program alone, and its lines; `measure windows`: each window that the interface package draws, alone, and a table of the time of its pictures; `measure without_checks ...`: the measure build, with no check in the kernel (no lock order check, no check of the frames)", run = run_measure},
	// Builds, starts a machine that runs the scenario of a film, and films
	// it: the pictures of the screen, taken while the scenario types, become
	// a film with ffmpeg, which must be on the path. The film is for the
	// development log and for a news entry that names it, not a test.
	//
	// - no argument, or `terminal`: the film of the terminal.
	// - `palette`: the film of the palette.
	// - `heron`: the film of the program heron.
	{name = "film", about = "build, start the machine, film a scenario (" + FILM_NAMES + "; no argument: terminal), and write " + FILM_FOLDER + "/<name>.mp4, " + FILM_FOLDER + "/<name>.webm, a copy of the MP4 file in a new folder of the development log " + DEVELOPMENT_LOG_NAME + " beside the main working tree, and " + FILM_DOCUMENT_FOLDER + "/<name>.webm when a news entry names the film (needs ffmpeg)", run = run_film},
	// Converts the BDF file of the font of the terminal (Spleen 8x16, from
	// `FONT_SOURCE`) to Odin data in `src/library/support/graphics/font.odin`. The result
	// is in the repository, so a build does not need the BDF file: run it only
	// to change the font.
	{name = "font", about = "convert the BDF file of the font to " + FONT_OUTPUT, run = run_font},
	// Converts the pointer manifests of `resources/pointers` to the pointer
	// theme files of the boot image, in `build/pointers`.
	//
	// - `folder` (optional): the Xcursor theme to read; else the folder of
	//   `POINTER_THEME_SOURCE`.
	//
	// It prints a table of each theme: each pointer, its size and its hot
	// spot (docs/POINTERS.md).
	{name = "pointers", about = "convert the pointer manifests of resources/pointers to pointer theme files in " + POINTER_BUILD_FOLDER + ", with the Xcursor folder of " + POINTER_THEME_SOURCE_VARIABLE + " or of the path after the command; print a table of each theme", run = run_pointers},
	// Takes the subset of each vector font candidate of `VECTOR_FONT_SOURCES`
	// that the system draws, writes it to `resources/fonts`, and draws one
	// picture that compares the candidates. Run it to change a font; a build
	// reads the files of the repository (docs/FONTS.md).
	{name = "vector_fonts", about = "subset the vector font candidates of " + VECTOR_FONT_SOURCES_VARIABLE + " to " + VECTOR_FONT_FOLDER + " and draw " + CANDIDATES_PICTURE, run = run_vector_fonts},
	// Draws the files of the mark of the system from its geometry in
	// `src/library/support/mark`: the icons in `resources/logo`, the font of the name of
	// the mark, the picture of the project, and one picture of every frame
	// of the animations of the mark.
	//
	// - `check`: draws them again and compares them with the files of the
	//   repository; `modustool check` runs it, so a mark that changed in
	//   the code and not in the files fails.
	{name = "logo", about = "draw the files of the mark of the system from " + MARK_SOURCE_FOLDER + ": " + LOGO_FOLDER + " and " + PROJECT_IMAGE + "; `check` verifies them; and " + MARK_ANIMATIONS_PICTURE + ", every frame of the animations of the mark", run = run_logo},
	// Draws one picture of the mark: the one entry to the generator of the
	// pictures of the mark, which `logo` and `site` also ask.
	//
	// - `still`: the still mark, a PNG file.
	// - `frame`: one frame of an animation (`--animation`, `--frame`).
	// - `tile_map`: the tile map of every animation, or of one (`--animation`):
	//   a tile for each distinct frame and, with `--forms yes`, a tile for
	//   each drawn form of the moves.
	// - `table`: the table of that tile map, as JSON: the place and the
	//   size of each tile, the times, the moves in cells.
	// - `uses`: prints the table of the uses: each file of the mark of the
	//   repository and of the site, with its variant.
	// - `developer`: the picture of every frame and form, with its texts.
	//
	// The options say how: `--variant smooth|cells`, `--cell <pixels>`,
	// `--scheme dark|light`, `--background none|scheme`, `--size <pixels>` or
	// `--size <width>x<height>`, `--name-cell <pixels>`, `--gap <pixels>`, `--width <pixels>` (the
	// widest tile map), `--out <file>`. A request with no sense is refused
	// with a sentence: the smooth variant at one pixel for a cell, a part
	// of a pixel, a picture smaller than its drawing (docs/TOOLS.md, "The
	// pictures of the mark").
	{name = "mark", about = "draw one file of the mark: still | frame | animation | tile_map | table | uses | developer, with --variant smooth|cells, --cell <pixels>, --scheme dark|light, --background none|scheme, --animation <name>, --frame <number>, --forms yes|no, --width <pixels>, --format png|ico|svg|apng|json, --entry <variant>:<cell>:<pixels>, --dark-rule yes|no, --out <file>", run = run_mark},
	// Converts each picture of `resources/hall_of_fame/CREDITS.md` to the
	// pixels of a portrait of the program `hall_of_fame`, in
	// `src/modules/demonstrations/hall_of_fame/portraits`. The result is in the
	// repository, so a build decodes no PNG file.
	{name = "portraits", about = "convert the pictures of " + HALL_OF_FAME_CREDITS_FILE + " to the portraits of " + HALL_OF_FAME_PORTRAIT_FOLDER, run = run_portraits},
	// Calls an export of a service of the machine that `modustool run`
	// started, from the host, and prints the typed result.
	//
	// - `key`: the public key of the program `remote`, as its window shows it.
	//   The QUIC client of the tool pins it: a machine with another key is
	//   refused.
	// - `call`: one call in the language of the console, in quotes.
	//
	// The call goes to the peer of `run` through a socket that only this user
	// reaches, then over QUIC to `remote`, which calls the service for the
	// principal. A table prints as rows, with its count.
	//
	// ```
	// nix develop -c modustool call <key> "monitor.counts_named([(\"programs\"), (\"processors\")])"
	// ```
	{name = "call", about = "call <key> \"service.export(arguments)\": call an export of a service of the machine that `run` started, through the program remote over QUIC (key: the public key of remote, from its window), and print the typed result; the peer of `run` takes the call on a socket that only this user reaches", run = run_call},
	// Builds one module again and again, with no machine, and counts the
	// distinct results: one distinct module, LLVM IR file and object each is a
	// build that gives the same bytes every time.
	//
	// - `module`, `count`: the module and the count of builds.
	// - `all count [processes]`: every module and the boot program, one row
	//   each.
	{name = "repeat", about = "repeat <module> <count>: build one module again and again, with no machine, and count the distinct modules, LLVM IR files and objects; `repeat all <count> [processes]`: every module and the boot program, one row each", run = run_repeat},
	// Copies a file of `core:crypto` of the Odin compiler into the repository
	// with the listed changes of its imports, and prints its line of the
	// manifest of the origin.
	//
	// - `origin`: the file, under the root of Odin.
	// - `file`: its path in the repository.
	{name = "cryptography-take", about = "cryptography-take <file under the root of Odin> <file of the repository>: copy a file of core:crypto with the listed import changes, and print its line of the manifest", run = run_cryptography_take},
	// Prints the line of the list of the system files for each `.odin` file of
	// `src/library/support/cryptography` that the manifest of the origin does not name:
	// the files that the project wrote, which a reviewer checks before the
	// lines go into the list.
	{name = "cryptography-system-hashes", about = "print the line of " + CRYPTOGRAPHY_SYSTEM_FILES + " for each .odin file of " + CRYPTOGRAPHY_FOLDER + " that is not taken from Odin", run = run_cryptography_system_hashes},
	// Checks that each file that the manifest of the origin names is its file
	// in Odin with the listed changes only. `modustool check` runs it.
	{name = "cryptography-origin", about = "check that each file of " + CRYPTOGRAPHY_MANIFEST + " is its origin in Odin with the listed changes only", run = run_cryptography_origin},
	// Checks that each import of each source file of src/ follows the rule
	// of its file: a source that is not a test imports no package of the
	// core library, the kernel and a contract package import no support
	// package, and a host test that imports a package of the core library
	// names its build line. Each build runs it before its first compiler
	// starts, and `modustool check` runs it.
	// Checks three rules of the system that a reader had to trust: the count
	// of the kernel operations against the properties, no call of an
	// allocator in a source of the system, and an error record from each
	// export that fails.
	{name = "rule-checks", about = "check that " + OPERATION_SOURCE + " declares the count of kernel operations that " + OPERATION_PROPERTY_DOCUMENT + " states, that no source file of the system that is not a test calls or names an allocator, that no export of a program or a module gives a negative number with no error record, that no family of integer constants is used as a closed set of choices, and that no cast of a word to an enum skips its border", run = run_rule_checks},
	{name = "library-imports", about = "check that each import of each source file of src/ follows the rule of its file, that the kernel and a contract package import no support package, and that each host test that imports a package of core: starts with the build line of the host", run = run_library_imports},
	// Measures how similar the code pieces of the Odin sources are, and
	// proposes where to factor them. It reads `src/` and `tools/`, gives a
	// similarity score from 0 to 1 to each pair that it compares, groups
	// the similar pieces in families with their factoring template, and
	// ranks the families by the nodes that a factoring saves
	// (docs/TOOLS.md, "The similarity finder").
	//
	// - no argument: the report on the terminal, and the whole report with
	//   two tables in `build/similarity/`.
	// - `near <file>:<line>`: the procedures most similar to the one that
	//   holds the line.
	// - `pair <file>:<line> <file>:<line>`: the score of two procedures and
	//   their template.
	//
	// It never edits a source and never fails on a similarity: a human or
	// an agent decides what to factor. A family that is kept on purpose is
	// a line of `tools/modustool/similarity_kept.txt`.
	{name = "similarity", about = "the similarity of the code pieces of src/ and tools/: families with their factoring template, ranked by the nodes that a factoring saves, in " + SIMILARITY_OUTPUT_FOLDER + "; `similarity near <file>:<line>`: the procedures most similar to one; `similarity pair <file>:<line> <file>:<line>`: the score of two procedures", run = run_similarity},
	// Works on the changelog: the fragments of `changelog.d/`, and the releases
	// of `CHANGELOG.md`.
	//
	// - `new <type> <subject> "<text>"`: writes one fragment; the type is
	//   Added, Changed, Deprecated, Removed, Fixed or Security. With `-` as the
	//   text, the text comes from the standard input.
	// - `check`: checks the form of each fragment and of the changelog.
	// - `assemble`: prints the next release from the fragments, with no
	//   change.
	// - `release <release number>`: moves the fragments into a new release of
	//   the changelog, with its release time in UTC and its release link, and
	//   deletes them. It copies the measure record to the measure history,
	//   unless the release before holds the same run.
	// - `notes <release number>`: prints the changes of one release.
	// - `times`: gives each old heading with its day alone the time of the
	//   commit of its release, and adds each missing release link.
	//
	// No one edits `CHANGELOG.md` by hand: this command writes it.
	{name = "changelog", about = "new <type> <subject> \"<text>\" (or - and the text on the standard input) | check | assemble | release <release number> | notes <release number> | times: the fragments of `" + FRAGMENT_FOLDER + "` and the releases of `" + CHANGELOG_FILE + "`", run = run_changelog},
	// Makes a release in one command: `changelog release`, a commit, a signed
	// release tag, and one atomic push of both to master. It refuses a branch
	// other than master, a tree with changes, and a master that does not hold
	// origin/master; when origin moved, it undoes, merges and tries again with
	// the next number (docs/TOOLS.md, "The release").
	{name = "ship", about = "step | correction | <release number> [--dry-run]: the release in one command: the changelog, a commit, a signed release tag v<number>, one atomic push to master", run = run_ship},
	// Gives each release tag whose tree holds a measure record its copy in
	// the measure history, for the releases from before the release command
	// copied the record. It changes no file that exists
	// (docs/TOOLS.md, "The release").
	{name = "measure-history", about = "the copy of the measure record of each release tag that holds one, in `" + MEASURE_HISTORY_FOLDER + "`, for the charts of each measure over the releases", run = run_measure_history},
	// Works on the news entries of `news/`, the dated reports of what a
	// reader can now see or use.
	//
	// - `new <subject>`: writes an entry with the date of today and no title
	//   and no text: the check fails until they are written.
	// - `check`: checks the head, the date, the picture, the release, the
	//   guide and the length of each entry. `modustool check` runs it.
	{name = "news", about = "new <subject> | check: the news entries of " + NEWS_FOLDER + ", dated reports in prose of what a reader can now see or use, for the page of the news of the site", run = run_news},
	// Checks the roadmap, `ROADMAP.md`: the planned work of the system, in
	// the sections Now, Next and Later.
	//
	// - `check`: checks the title, the three sections in their order, the
	//   form of each entry (a bold summary, then one or two sentences), the
	//   design link of an entry, and that the file gives no date. It refuses
	//   an entry whose summary is the summary of an entry of the changelog:
	//   that work is done. `modustool check` runs it.
	//
	// The file is written by hand: an entry is added when a work is planned,
	// and removed in the commit that ends the work
	// (docs/TOOLS.md, "The roadmap").
	{name = "roadmap", about = "check: the planned work of `" + ROADMAP_FILE + "`, in the sections Now, Next, Later and Maybe, for the page of the roadmap of the site", run = run_roadmap},
	// Works on the fences `byte-layout` of the guides, whose body is the
	// text form of the byte layout of a record of a format.
	//
	// - `write`: writes the body of each fence again from the code: the
	//   offsets and the sizes from the compiler, the types from the source.
	// - `check`: checks that each body is that text. `modustool check` runs
	//   it, and `modustool site` stops on such a fault too.
	//
	// The design: (docs/SITE.md, "The byte layouts").
	{name = "byte-layouts", about = "write | check: the text of each fence `" + BYTE_LAYOUT_FENCE_LANGUAGE + "` of the guides, the byte layout of a record of a format from the code", run = run_byte_layouts},
	// Writes the site in `build/site/`: the home, the guides, the reference
	// tables read from the code, the status, the news, the releases, the
	// roadmap, the index of the search and its script.
	//
	// - `--address https://<host>/<path>` (optional): the address of the
	//   published site, for the canonical addresses, the sitemap and the
	//   feeds.
	//
	// Before it writes a page, it checks every page: one title, each link to
	// a page or a file that it writes, each picture with its text. A failure
	// stops the command with the page and the reason, and writes nothing. The
	// design: (docs/SITE.md, "The command").
	{name = "site", about = "write the site of the system in " + SITE_FOLDER + ": the pages from the documents, the code, the news, the pictures and the logs of the last machine tests, an index and one small script for the search, and the feed of the news; no request to another server", run = run_site},
	// Prints the number of the newest release of `CHANGELOG.md`, as `0.91.0`:
	// the number that a workflow gives to a release.
	{name = "release_number", about = "print the release number of the system: the newest release of `" + CHANGELOG_FILE + "`", run = run_release_number},
	// Makes the files of a release: the disk image of the system that a
	// principal writes to a USB key, its checksum list and the release
	// signature of the list (docs/INSTALL.md).
	//
	// - `image`: a whole build with the keys of the publisher of the
	//   system, the release volume (the main boot image with its boot
	//   program signed for Secure Boot), then a GPT disk around it,
	//   compressed with zstd, `SHA256SUMS.txt` and `SHA256SUMS.txt.sig` in
	//   `dist/`, and the notes of the release in `build/release_notes.md`.
	//   It refuses the test keys, a release signing key whose public key is
	//   not `resources/keys/release_signing_key.public`, and every volume of
	//   a test.
	// - `tag-check <tag>`: checks that a tag is `v` and the release number.
	//
	// The workflow of a release runs it on each tag `v*`.
	{name = "release", about = "image: build the release volume with the keys of the publisher (" + SIGNING_KEY_VARIABLE + "), and write the compressed GPT disk image, " + RELEASE_CHECKSUM_FILE_NAME + " and its release signature in " + RELEASE_OUTPUT_FOLDER + "/; `release tag-check <tag>`: check that the tag is v and the release number", run = run_release},
	// Verifies the files of a release: the release signature of the
	// checksum list with the public key of the repository, then the SHA-256
	// of the image against its line. The signature file is beside the
	// checksum list, with the suffix `.sig`.
	//
	// ```
	// nix develop -c modustool verify modus-0.93.0-x86_64.img.zst SHA256SUMS.txt
	// ```
	{name = "verify", about = "verify <image> <" + RELEASE_CHECKSUM_FILE_NAME + ">: check the release signature of the checksum list with " + RELEASE_PUBLIC_KEY_FILE + ", then the SHA-256 of the image", run = run_verify},
	// Records the hash of the file of each module of the build, or compares
	// the build with such a record. It builds nothing: run `build` first.
	//
	// - `write <file>`: writes the record: one line for each module of
	//   `build/modules`, its BLAKE3 hash and its name.
	// - `compare <file>`: prints each module whose hash is not the hash of
	//   the record, each module that only one of the two has, and the count
	//   of the modules with the same hash. It fails when one differs.
	//
	// It is the proof of a change that must not change the system, such as
	// a move of the sources
	// (docs/TOOLS.md, "The hashes of the modules of two builds").
	{name = "module-hashes", about = "write <file> | compare <file>: record the hash of each module of " + MODULE_BUILD_FOLDER + ", or compare the build with such a record: print each module whose hash differs, and fail if one does", run = run_module_hashes},
	// Runs every check of the work tree, and writes no file of the
	// repository: the count of its checks goes to build/checks_passed.txt.
	// The full check of a batch is `nix flake check`, which runs this
	// command, with `screenshots`.
	//
	// In order: `odin check -vet` of the tool, each package of the contract
	// alone, the host tests of each folder (several at once, each with its
	// log in `build/host_tests/`), the origin of the cryptography,
	// the mark, the pictures of the README, the fixed addresses, the bounds
	// of the tests, the rule on comments, the form of the glossary, the
	// file index of the intent, the source paths in the documents, the
	// changelog, the news and the roadmap. Then the whole machine test
	// (`test`) and a second build that must give the same bytes.
	{name = "check", about = "odin check -vet and odin test of the host code, the fuzz targets (their corpus and a fixed count of new executions), the checks of the sources (among them the rule on comments and the form of the glossary), changelog check, news check, roadmap check, then test", run = run_check},
	// Fuzzes the readers of the system on the host: the module file, the
	// debug object, the storage format, QUIC and TLS, TCP and HTTP
	// (docs/TOOLS.md, "The fuzzing").
	//
	// - `list`: the fuzz targets, with the inputs of their corpus.
	// - `<target> [executions [processes [seed]]]`, `all [executions]`:
	//   builds the instrumented child, then runs the target until it is
	//   stopped, or for a count of executions; a fuzz finding is minimized
	//   into `build/fuzzing/<target>/findings`.
	// - `show <target> <file>`: runs one input, and prints its outcome and
	//   its bytes as an Odin array, for a host test.
	// - `minimize <target> <file>`: the smallest input with the same
	//   fuzz finding.
	// - `regression <target> <file>`: after a fix, adds the input to the
	//   regression inputs of the corpus.
	// - `corpus <target>`: writes the reach inputs of the corpus from the
	//   inputs that the long runs kept.
	{name = "fuzz", about = "list | <target> [executions [processes [seed]]] | all [executions] | show <target> <file> | minimize <target> <file> | regression <target> <file> | corpus <target>: fuzz the readers of the system on the host, guided by edge counters", run = run_fuzz},
	// The child process of `fuzz` and of `check`: it runs the engine on one
	// target. The parent starts it; it is not a command to run by hand.
	{name = "fuzz-child", about = "the child process of `fuzz` and of `check`, which the parent starts", run = run_fuzz_child},
	// Makes or shows the key that signs the system description.
	//
	// - `new <folder>`: writes a new private key, readable by its owner only,
	//   and its public key, in a folder outside the repository, with the
	//   firmware signing key of Secure Boot and the release signing key
	//   beside them.
	// - `write <folder>`: writes the same key folder from the variables
	//   `SYSTEM_SIGNING_KEY_TEXT`, `FIRMWARE_SIGNING_KEY_TEXT`,
	//   `FIRMWARE_CERTIFICATE_TEXT` and `RELEASE_SIGNING_KEY_TEXT`: the
	//   secrets of the workflow of a release (`secrets/README.md`).
	// - `show`: prints the public key that the build uses: the key of
	//   `SYSTEM_SIGNING_KEY`, or the test signing key of the repository.
	//
	// A system signed with the test key is for a test machine only: its
	// private key is published.
	{name = "key", about = "key new <folder outside the repository>: write a new signing key of the system description (the private key, readable by its owner only, and the public key), with the firmware signing key and the release signing key; `key write <folder>`: the same folder from the variables of the secrets of a workflow; `key show`: print the public key that the build uses (" + SIGNING_KEY_VARIABLE + ", or the test signing key)", run = run_key},
}

main :: proc() {
	// The development shell of Nix gives the linker a search path with the
	// folder of the build in it (NIX_LDFLAGS). The linker would write it in
	// each module, and the hash of a module would depend on that folder.
	_ = os.unset_env("NIX_LDFLAGS")
	when TOOL_BUILDS_ITSELF {
		tool_build_current()
	}
	if len(os.args) < 2 || os.args[1] == "help" || os.args[1] == "-h" || os.args[1] == "--help" {
		usage()
		return
	}
	// The command module-build runs from the folder of another project: it
	// finds the folder of the system by itself, and refuses a wrong one.
	if os.args[1] != "module-build" && !os.exists(ROOT_MARK) {
		fmt.eprintln("modustool: start it from the root of the repository")
		os.exit(EXIT_USAGE)
	}
	commands := COMMANDS
	for c in commands {
		if c.name == os.args[1] {
			os.exit(c.run(os.args[2:]))
		}
	}
	fmt.eprintfln("modustool: no command %s", os.args[1])
	usage()
	os.exit(EXIT_USAGE)
}

usage :: proc() {
	fmt.println("modustool <command>")
	commands := COMMANDS
	for c in commands {
		fmt.printfln("  %-14s %s", c.name, c.about)
	}
}

// run_build is the command `build`: the modules, the boot images, and
// every boot volume. A module whose inputs are the same is kept, and so is
// each boot volume (incremental_build.odin, boot_volumes.odin); `build
// whole` keeps nothing.
run_build :: proc(args: []string) -> int {
	// `build [whole] [processes]`: a whole build, and the count of module
	// processes at once.
	rest := args
	if len(rest) >= 1 && rest[0] == "whole" {
		build_whole = true
		rest = rest[1:]
	}
	if len(rest) > 1 || (len(rest) == 1 && !parse_module_build_processes(rest[0])) {
		fmt.eprintln("modustool: build [whole] [processes]")
		return EXIT_USAGE
	}
	return build_system(nil)
}

// build_system builds the modules, the boot images, and then the boot
// volumes that the caller boots: needed_volumes names them by their paths,
// and nil is every volume. A volume that the caller does not name is not
// built and not checked: no machine of this process starts from it
// (machine_command).
build_system :: proc(needed_volumes: []string) -> int {
	build_measure_start()
	if !build_modules() {
		return EXIT_FAILURE
	}
	volumes_started := time.tick_now()
	if !boot_volumes_build(needed_volumes) {
		return EXIT_FAILURE
	}
	build_measure_step("the boot volumes, in all", volumes_started)
	build_measure_print()
	return 0
}

run_machine :: proc(args: []string) -> int {
	if len(args) >= 1 && args[0] == "without_checks" {
		test_build_checks = false
	}
	if code := build_system(boot_volumes_of_command("run")); code != 0 {
		return code
	}
	if !disk_prepare(DATA_DISK, DATA_DISK_SIZE, false) {
		return EXIT_FAILURE
	}
	// The peer receives the calls of `modustool call` on a Unix socket of
	// the private folder of the user: `modustool call` finds it by its name.
	peer: Peer
	if !peer_start(&peer, CALL_SOCKET_RUN_NAME) {
		return EXIT_FAILURE
	}
	// The developer names the key of each start of remote in `modustool
	// call`: this peer takes it.
	peer.remote.keys_from_calls = true
	fmt.printfln("modustool: the peer takes the calls of `modustool call` at %s (only this user reaches it)", peer.call_socket)
	// remote takes the calls of a client whose key a principal allowed: a
	// key drawn for this run, which the developer allows in a console.
	client_key := peer_remote_client_key_draw(peer.remote)
	fmt.printfln("modustool: the key of the client of remote in the peer, for this run: %s; allow it in a console of the machine: remote_allow(\"%s\")", client_key, client_key)
	defer peer_stop(&peer)
	command, ok := machine_command(BOOT_VOLUME, "", DATA_DISK, &peer)
	if !ok {
		return EXIT_FAILURE
	}
	if !run(command) {
		return EXIT_FAILURE
	}
	return 0
}

// run_test runs the parts of the machine test (test_parts.odin): one part,
// or every part, several at once.
run_test :: proc(args: []string) -> int {
	if problem := test_arguments_problem(args); problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return EXIT_USAGE
	}
	// The times of the test are measures: the report never changes the result.
	test_started := time.tick_now()
	// One part boots only its own boot volumes: the build builds those.
	build_code := build_system(boot_volumes_of_test(args))
	build_duration := time.tick_since(test_started)
	if build_code != 0 {
		return build_code
	}
	if !reset_folder(SCREENSHOT_FOLDER) {
		return EXIT_FAILURE
	}
	parts := test_parts[:]
	if len(args) == 1 {
		for part, place in test_parts {
			if part.name == args[0] {
				parts = test_parts[place:][:1]
			}
		}
	}
	processors := test_processors_of(os.get_processor_core_count(), os.get_env("NIX_BUILD_CORES", context.temp_allocator))
	at_once := test_parts_at_once(len(parts), processors)
	picture_names_forget()
	if len(parts) > 1 {
		fmt.printfln("modustool: %d parts of the machine test, at most %d at once: %d processors, %d for each machine", len(parts), at_once, processors, MACHINE_PROCESSOR_COUNT)
	}
	runs, passed := test_parts_run(parts, at_once)
	defer {
		for &part_run in runs {
			test_part_run_free(&part_run)
		}
		delete(runs)
	}
	test_times_report(runs, build_duration, test_started)
	if !passed {
		return EXIT_FAILURE
	}
	fmt.println("modustool: all tests passed")
	return 0
}

// The count of the checks that passed in this process: the measure record
// states it. Each check that passes prints its line through
// test_passed_print. A peer thread can print one, so the count is atomic.
test_passed_count: int

test_passed_print :: proc(format: string, args: ..any) {
	sync.atomic_add(&test_passed_count, 1)
	fmt.printfln("modustool: test passed: %s", fmt.tprintf(format, ..args))
}

// The check of the flake that runs `modustool check` in the sandbox of Nix.
// The flake defines its checks for x86_64-linux only.
FLAKE_CHECK_ATTRIBUTE :: ".#checks.x86_64-linux.boot-test"
// The link to the output of that check: it keeps the output in the store
// while the link exists.
FLAKE_CHECK_LINK :: BUILD_FOLDER + "/flake_check"
// The folders of the output of the check (flake.nix, bootTest): the logs
// and the records of build/, and the pictures of the test.
FLAKE_CHECK_LOGS :: FLAKE_CHECK_LINK + "/logs"
FLAKE_CHECK_PICTURES :: FLAKE_CHECK_LINK + "/screenshots"
// The count of the checks that passed in `modustool check`: the measure
// record of `screenshots` adds it to the checks of its own measure runs.
CHECKS_PASSED_FILE :: BUILD_FOLDER + "/checks_passed.txt"

// run_screenshots takes the outputs of the one run of the machine test of
// the full check, the check of the flake (src/md/infrastructure/full_check.md):
// it builds that check, which Nix takes from the store when `nix flake
// check` passed on the same tree. It copies the pictures of the test to the
// documents and to a new folder of the development log, runs the measure
// runs on the host, and writes the measure record (measure_record.odin).
// `screenshots compress` runs no machine: it compresses each PNG file of
// the documents and of the resources whose data is stored (picture_files.odin).
run_screenshots :: proc(args: []string) -> int {
	if len(args) == 1 && args[0] == "compress" {
		count, compressed_all := pictures_compress([]string{DOCUMENT_SCREENSHOT_FOLDER, RESOURCE_FOLDER})
		fmt.printfln("modustool: %d PNG files, %d compressed: %d bytes before, %d bytes after", count.picture_count, count.compressed_count, count.bytes_before, count.bytes_after)
		return compressed_all ? 0 : EXIT_FAILURE
	}
	if len(args) != 0 {
		fmt.eprintln("modustool: screenshots takes no argument, or `compress`")
		return EXIT_USAGE
	}
	// The facts of the tree before the pass changes it: the pass writes the
	// pictures and the record into the repository. A log of the check is
	// copied after this time, so the record reads it as a log of this run.
	run_facts := measure_run_facts_read()
	// The check of the flake runs the host checks, the whole machine test
	// and the second build in the sandbox; it fails when one of them fails.
	if !run({"nix", "build", FLAKE_CHECK_ATTRIBUTE, "--out-link", FLAKE_CHECK_LINK, "--print-build-logs"}) {
		return EXIT_FAILURE
	}
	if !flake_check_outputs_take() {
		return EXIT_FAILURE
	}
	// The pictures are a fact of the machines, which all passed: they go
	// to the documents now.
	if !screenshots_copy() {
		return EXIT_FAILURE
	}
	// The rates of the record come from measure runs on the host, with no
	// other machine: the test measures none (measure_runs.odin).
	if code := build_system(boot_volumes_of_command("screenshots")); code != 0 {
		return code
	}
	if !measure_runs_of_the_record() {
		return EXIT_FAILURE
	}
	if !measure_record_write(run_facts) {
		return EXIT_FAILURE
	}
	return 0
}

// flake_check_outputs_take copies the outputs of the check of the flake
// into build/: its pictures into SCREENSHOT_FOLDER, and its logs and
// records beside the logs of the host. The files of the store are read-only:
// each copy is a new file. It adds the checks that passed in the check to
// the count of this process.
flake_check_outputs_take :: proc() -> bool {
	reset_folder(SCREENSHOT_FOLDER) or_return
	pictures := files_with_suffix(FLAKE_CHECK_PICTURES, ".png") or_return
	logs := files_with_suffix(FLAKE_CHECK_LOGS, ".txt") or_return
	if len(pictures) == 0 || len(logs) == 0 {
		fmt.eprintfln("modustool: the output of the check of the flake has %d pictures and %d logs: it is not the output of a whole test", len(pictures), len(logs))
		return false
	}
	for list, place in ([2][]string{pictures, logs}) {
		folder := place == 0 ? SCREENSHOT_FOLDER : BUILD_FOLDER
		for source in list {
			target := strings.concatenate({folder, source[strings.last_index_byte(source, '/'):]}, context.temp_allocator)
			file_copy_as_new(target, source) or_return
		}
	}
	text, read_error := os.read_entire_file(CHECKS_PASSED_FILE, context.temp_allocator)
	count, number_ok := strconv.parse_int(strings.trim_space(string(text)))
	if read_error != nil || !number_ok || count <= 0 {
		fmt.eprintfln("modustool: the check of the flake gave no count of its checks in %s", CHECKS_PASSED_FILE)
		return false
	}
	sync.atomic_add(&test_passed_count, count)
	fmt.printfln("modustool: took %d pictures and %d logs of the check of the flake (%d checks passed there)", len(pictures), len(logs), count)
	return true
}

// file_copy_as_new writes the bytes of source to a new file target, with
// the permissions of a new file: a copy of a file of the store keeps no
// read-only mode, so a later copy can write over it.
file_copy_as_new :: proc(target, source: string) -> bool {
	bytes, read_error := os.read_entire_file(source, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", source, read_error)
		return false
	}
	_ = os.remove(target)
	if write_error := os.write_entire_file(target, bytes); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", target, write_error)
		return false
	}
	return true
}

// screenshots_copy copies the pictures of the test to the documents and to
// a new folder of the development log.
screenshots_copy :: proc() -> bool {
	pictures, ok := files_with_suffix(SCREENSHOT_FOLDER, ".png")
	// The name of the folder is the time of the run, in UTC.
	year, month, day := time.date(time.now())
	hour, minute, second := time.clock(time.now())
	development_log := development_log_folder()
	log_folder := fmt.tprintf("%s/%04d-%02d-%02d_%02d%02d%02d", development_log, year, int(month), day, hour, minute, second)
	if !ok || !make_folder(DOCUMENT_SCREENSHOT_FOLDER) || !make_folder(development_log) || !make_folder(log_folder) {
		return false
	}
	for picture in pictures {
		for folder in ([]string{DOCUMENT_SCREENSHOT_FOLDER, log_folder}) {
			target := strings.concatenate({folder, picture[strings.last_index(picture, "/"):]}, context.temp_allocator)
			if err := os.copy_file(target, picture); err != nil {
				fmt.eprintfln("modustool: cannot write %s: %v", target, err)
				return false
			}
			fmt.printfln("modustool: wrote %s", target)
		}
	}
	return true
}

TEST_OUTPUT_MEASURE :: BUILD_FOLDER + "/test_output_measure.txt"

// run_measure runs the measures of the program `locks` on a machine where
// only the desktop runs: the numbers have no load of the other programs of
// the test. The program checks its counts; the tool does not check a speed.
// The same machine then runs processor_frame, whose lines the tool reads
// for their form only (processor_frame_measure.odin).
// The machine is a measure run: its boot image holds the resource
// `measure_run`, so each program measures its rates over a duration
// (measure_runs.odin). `measure <program>`: one program of
// `measure_programs`, alone, and its lines.
// `measure scheduler N`: N machines that run only the program scheduler
// with the desktop; the numbers are in build/test_output_scheduler_<n>.txt.
run_measure :: proc(args: []string) -> int {
	args := args
	if len(args) >= 1 && args[0] == "without_checks" {
		test_build_checks = false
		args = args[1:]
	}
	// `measure shortage` boots the volume of the shortage of frames; each
	// other form boots the volume of a measure run.
	shortage := len(args) >= 1 && args[0] == "shortage"
	if code := build_system(boot_volumes_of_command(shortage ? MEASURE_SHORTAGE_COMMAND : MEASURE_COMMAND)); code != 0 {
		return code
	}
	part := test_part_run_make(MEASURE_COMMAND)
	defer test_part_run_free(&part)
	if !make_folder(SCREENSHOT_FOLDER) || !test_part_run_start(&part) {
		return EXIT_FAILURE
	}
	if len(args) == 1 && args[0] == "windows" {
		return measure_windows(&part) ? 0 : EXIT_FAILURE
	}
	if len(args) >= 1 && args[0] == "address_space" {
		return machine_test(&part, scenario_measure_address_space[:], {volume = BOOT_VOLUME_MEASURE, output = TEST_OUTPUT_MEASURE, exit_status = MACHINE_STOP_OK}) ? 0 : EXIT_FAILURE
	}
	// `measure <program>`: one program that measures itself, alone.
	if len(args) == 1 {
		if program, found := measure_program_find(args[0]); found {
			return measure_program_run(&part, program) ? 0 : EXIT_FAILURE
		}
	}
	if shortage {
		return shortage_tests_run(&part) ? 0 : EXIT_FAILURE
	}
	if len(args) >= 1 && args[0] == "scheduler" {
		count := 1
		if len(args) == 2 {
			count = 0
			for character in args[1] {
				if character < '0' || character > '9' {
					fmt.eprintln("modustool: measure scheduler <count>: the count is a number")
					return EXIT_FAILURE
				}
				count = count * 10 + int(character - '0')
			}
		}
		for run in 1 ..= count {
			// Not in the temporary allocator: the scenario frees it after each step.
			output := fmt.aprintf("%s/test_output_scheduler_%d.txt", BUILD_FOLDER, run)
			defer delete(output)
			if !machine_test(&part, scenario_measure_scheduler[:], {volume = BOOT_VOLUME_MEASURE, output = output, exit_status = MACHINE_STOP_OK}) {
				return EXIT_FAILURE
			}
		}
		return 0
	}
	if len(args) != 0 {
		fmt.eprintln("modustool: measure [without_checks] [scheduler <count> | windows | address_space | shortage | clock | crowd | disk | flow | limits]")
		return EXIT_USAGE
	}
	if !machine_test(&part, scenario_measure[:], {volume = BOOT_VOLUME_MEASURE, output = TEST_OUTPUT_MEASURE, exit_status = MACHINE_STOP_OK}) || !processor_frame_lines_check(TEST_OUTPUT_MEASURE) {
		return EXIT_FAILURE
	}
	return 0
}

run_check :: proc(args: []string) -> int {
	// The full check proves the build: it keeps no output of an earlier build.
	build_whole = true
	if !run({"odin", "check", TOOL_SOURCE_FOLDER, "-vet", SOURCE_LIBRARY_FLAG, KERNEL_LIBRARY_FLAG}) {
		return EXIT_FAILURE
	}
	// The kernel and the contract packages import no support package. The
	// compiler does not refuse such an import: the library is one.
	if !library_imports_check() {
		return EXIT_FAILURE
	}
	// The count of the kernel operations is the count that the properties
	// state, no source of the system calls an allocator, each export that
	// fails gives an error record, and no family of integer constants is a
	// closed set of choices.
	if !operation_count_check() || !allocator_check() || !export_error_record_check() || !choice_constant_check() {
		return EXIT_FAILURE
	}
	host_test_folders := HOST_TEST_FOLDERS
	if !host_tests_run(host_test_folders[:]) {
		return EXIT_FAILURE
	}
	// The fuzz targets: their corpus, then a fixed count of new executions
	// with the seed of the sources (src/md/infrastructure/fuzzing.md).
	if !fuzz_check() {
		return EXIT_FAILURE
	}
	if !cryptography_origin_check() {
		return EXIT_FAILURE
	}
	if !logo_check() {
		return EXIT_FAILURE
	}
	if !readme_pictures_check() {
		return EXIT_FAILURE
	}
	if !fixed_addresses_check() {
		return EXIT_FAILURE
	}
	if !test_bound_check() {
		return EXIT_FAILURE
	}
	if !text_cut_check() {
		return EXIT_FAILURE
	}
	if !comment_rule_check() {
		return EXIT_FAILURE
	}
	if !glossary_check() {
		return EXIT_FAILURE
	}
	if !intent_index_check() {
		return EXIT_FAILURE
	}
	if !source_paths_check() {
		return EXIT_FAILURE
	}
	if !changelog_check() {
		return EXIT_FAILURE
	}
	if !news_check() {
		return EXIT_FAILURE
	}
	if !roadmap_check() {
		return EXIT_FAILURE
	}
	if !byte_layouts_check() {
		return EXIT_FAILURE
	}
	if !reuse_list_check() {
		return EXIT_FAILURE
	}
	if run_test(nil) != 0 {
		return EXIT_FAILURE
	}
	if !outputs_same_after_second_build() {
		return EXIT_FAILURE
	}
	// `screenshots` reads the count from the output of the check of the
	// flake, for its measure record.
	count_line := fmt.tprintf("%d\n", sync.atomic_load(&test_passed_count))
	if write_error := os.write_entire_file(CHECKS_PASSED_FILE, count_line); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", CHECKS_PASSED_FILE, write_error)
		return EXIT_FAILURE
	}
	return 0
}

// The processor of a test machine, as the -cpu of QEMU.
Processor_Model :: enum {
	Maximum, // Each feature that the host processor, or the emulation, has.
	Without_Random, // No rdrand and no rdseed: the fallback of the seed of the root service (`test random`).
	Without_Avx, // No AVX: the kernel saves x87 and SSE with xsaveopt (`test extended_state`).
	Without_Xsave, // No xsave: the kernel saves with fxsave (`test extended_state`).
}

@(rodata)
processor_models := [Processor_Model]string {
	.Maximum        = "max",
	.Without_Random = "max,-rdrand,-rdseed",
	.Without_Avx    = "max,-avx",
	.Without_Xsave  = "max,-xsave",
}

// machine_command gives the one QEMU command line of the project: the first
// fixed machine that the system targets (QEMU on x86-64 with virtio
// devices, UEFI firmware and a TPM). The boot volume is a virtio block device. If
// test_output is a path, the machine has no window and writes its log there.
// The network device sends each frame to the peer (peer.odin) on the
// loopback of the host, at peer_port, as one UDP datagram.
// The network device goes to the peer (`-netdev dgram`), or, when forward
// has a port, to QEMU user networking with its TCP (web_host.odin).
// processor gives the processor of the machine (Processor_Model).
// entropy_device gives the machine the entropy device of virtio at the place
// pci.ENTROPY_DEVICE (src/md/features/entropy_device.md).
// The IOMMU of a machine: none, the unit of Intel, or the unit of AMD
// (src/md/infrastructure/iommu.md).
Machine_Iommu :: enum {
	None,
	Intel,
	Amd,
}

// firmware_files names the files of a firmware: the variable of the
// environment that gives its code, the one that gives its variable store,
// the copy of that store outside a test, and the end of the name of the
// copy of a test machine. The start of a machine and the names of the
// addresses at a failure both read them, so the two name the same files.
firmware_files :: proc(firmware: Machine_Firmware) -> (code_variable, variables_variable, variables_copy, variables_suffix: string) {
	switch firmware {
	case .Usual:
		code_variable, variables_variable, variables_copy, variables_suffix = "OVMF_CODE", "OVMF_VARS", FIRMWARE_VARIABLES, FIRMWARE_VARIABLES_SUFFIX
	case .With_Tpm_Driver:
		code_variable, variables_variable, variables_copy, variables_suffix = "OVMF_TPM_CODE", "OVMF_TPM_VARS", FIRMWARE_TPM_VARIABLES, FIRMWARE_TPM_VARIABLES_SUFFIX
	case .With_Secure_Boot:
		code_variable, variables_variable, variables_copy, variables_suffix = "OVMF_FULL_CODE", "OVMF_FULL_VARS", FIRMWARE_FULL_VARIABLES, FIRMWARE_FULL_VARIABLES_SUFFIX
	}
	return
}

// The memory of a test machine, in MiB. Below the hole of PCI of q35, so an
// offset in the memory file of a machine is a physical address.
MACHINE_MEMORY_MIB :: 1024

// memory_file: "", or a file of the host that holds the memory of the
// machine, which the tool reads and writes (operation_sequences.odin); such
// a machine has one processor, so that a sequence gives the same answers at
// each run (src/md/infrastructure/kernel_fuzzing.md, "The machine").
machine_command :: proc(volume: string, test_output: string, data_disk: string, peer: ^Peer, forward: Forward = {}, processor: Processor_Model = .Maximum, firmware: Machine_Firmware = .Usual, vnc := false, paused := false, iommu: Machine_Iommu = .None, entropy_device := false, tpm_device := false, clock_argument := "base=utc", memory_file := "", sound_output := "") -> (command: []string, ok: bool) {
	// A machine starts only from a boot volume that this process built or
	// kept: a volume that the command did not ask for can be the volume of
	// older sources, and a test on it proves nothing. The variable store of
	// Secure Boot is an output of the build of one volume.
	if !boot_volume_is_ready(volume) || (firmware == .With_Secure_Boot && !boot_volume_is_ready(BOOT_VOLUME_SECURE_BOOT)) {
		fmt.eprintfln("modustool: the boot volume %s, or the variable store of Secure Boot, was not built or kept by the build of this command: add it to the volumes of the command (boot_volumes.odin)", volume)
		return nil, false
	}
	// Each machine starts from a new disk of the measures, of the first
	// size: the machine of AMD gives that disk a new size during its test
	// (iommu_scenario.odin), and a machine that kept the file would see that
	// size. The disk holds no data that a program keeps. A test machine has
	// its files beside its log: machines that run at the same time share no
	// file that QEMU writes.
	scratch_disk := test_output != "" ? machine_file(test_output, SCRATCH_DISK_SUFFIX) : SCRATCH_DISK
	if !disk_prepare(scratch_disk, SCRATCH_DISK_SIZE, true) {
		return nil, false
	}
	code_variable, variables_variable, variables_copy, variables_suffix := firmware_files(firmware)
	if test_output != "" {
		variables_copy = machine_file(test_output, variables_suffix)
	}
	firmware_code := os.get_env(code_variable, context.temp_allocator)
	firmware_variables := os.get_env(variables_variable, context.temp_allocator)
	// The machine with Secure Boot on starts from the variable store in
	// which the build enrolled the certificate of the firmware signing key
	// (secure_boot.odin), not from the empty store of the firmware.
	if firmware == .With_Secure_Boot {
		firmware_variables = SECURE_BOOT_VARIABLES
	}
	if firmware_code == "" || firmware_variables == "" {
		fmt.eprintfln("modustool: %s and %s are not set. Use the development shell: nix develop", code_variable, variables_variable)
		return nil, false
	}
	// The firmware writes its variables, so it gets a private copy.
	if err := os.copy_file(variables_copy, firmware_variables); err != nil {
		fmt.eprintfln("modustool: cannot copy %s: %v", firmware_variables, err)
		return nil, false
	}
	if !run({"chmod", "u+w", variables_copy}) {
		return nil, false
	}
	listener_port := forward.listener != nil ? forward.listener.port : 0
	// With the peer, QEMU uses a copy of the socket of the peer for the
	// machine; the caller closes the copy once QEMU started.
	machine_descriptor := 0
	if forward.host_port == 0 {
		machine_descriptor = peer_machine_socket_lend(peer) or_return
	}
	network_device := network_device_of(forward.host_port, listener_port, machine_descriptor)
	if problem := network_device_problem(network_device); problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		peer_machine_socket_lent_close(peer)
		return nil, false
	}
	list := make([dynamic]string, context.temp_allocator)
	append(
		&list,
		"qemu-system-x86_64",
		"-machine",
		// The firmware with Secure Boot needs the system management mode of
		// the processor: its variables are written only there. QEMU refuses
		// interrupt remapping when KVM holds the whole interrupt controller:
		// the machine with the IOMMU splits it. QEMU accepts both together.
		strings.concatenate({"q35", firmware == .With_Secure_Boot ? ",smm=on" : "", iommu != .None ? ",kernel-irqchip=split" : "", memory_file != "" ? ",memory-backend=machine_memory" : ""}, context.temp_allocator),
		"-accel",
		"kvm",
		"-accel",
		"tcg",
		"-cpu",
		processor_models[processor],
		// The main test keeps about 30 windows open, each with two
		// pictures, and then starts a program that maps 164 MiB.
		"-m",
		fmt.tprintf("%d", MACHINE_MEMORY_MIB),
		"-smp",
		fmt.tprintf("%d", memory_file != "" ? 1 : MACHINE_PROCESSOR_COUNT),
		"-device",
		"isa-debug-exit,iobase=0xf4,iosize=0x04",
		"-no-reboot",
		// The real-time clock of the machine: the clock of the host in UTC
		// for a machine that a principal runs; a fixed hour of the night for
		// a test machine (machine_clock.odin).
		"-rtc", clock_argument,
		"-net",
		"none", // No other network device than the one below.
		"-netdev",
		network_device,
	)
	// The machines of the parts iommu and iommu_amd: the remapping unit of
	// Intel or of AMD, before each device of PCI, which takes its place
	// behind it, with interrupt remapping (src/md/infrastructure/iommu.md,
	// "Interrupt remapping"). Without dma-remap, the unit of AMD translates
	// no access of an emulated device. Each virtio device sends its accesses
	// through the unit only with iommu_platform, which a device with the
	// legacy interface refuses.
	virtio_iommu := ""
	switch iommu {
	case .None:
	case .Intel:
		append(&list, "-device", "intel-iommu,intremap=on")
		virtio_iommu = ",iommu_platform=on"
	case .Amd:
		append(&list, "-device", "amd-iommu,dma-remap=on,intremap=on")
		virtio_iommu = ",iommu_platform=on"
	}
	if memory_file != "" {
		// The memory of the machine in a file that the tool reads and
		// writes while the machine runs: share=on gives the tool the pages
		// that the machine sees.
		append(&list, "-object", fmt.tprintf("memory-backend-file,id=machine_memory,size=%dM,mem-path=%s,share=on", MACHINE_MEMORY_MIB, memory_file))
	}
	if paused {
		// The machine waits for the step Monitor "cont" of the scenario: a
		// film catches each line of the start that a viewer must read.
		append(&list, "-S")
	}
	if forward.host_port != 0 {
		// Each frame of the device, with its time, for the tool after the run
		// (web_host.odin, frames_of_the_fetch_report).
		append(&list, "-object", strings.concatenate({"filter-dump,id=frames,netdev=network,file=", frames_of_user_network_file(test_output)}, context.temp_allocator))
	}
	append(
		&list,
		"-device",
		fmt.tprintf("virtio-net-pci,netdev=network,disable-legacy=on,mac=%s,addr=0x%x%s", MACHINE_HARDWARE, pci.NETWORK_DEVICE, virtio_iommu),
		"-drive",
		strings.concatenate({"if=pflash,format=raw,readonly=on,file=", firmware_code}, context.temp_allocator),
		"-drive",
		strings.concatenate({"if=pflash,format=raw,file=", variables_copy}, context.temp_allocator),
		"-drive",
		// Several machines boot one volume at the same time, and QEMU takes
		// a lock for writing on each image that it opens for writing: the
		// second machine would not start. With snapshot=on QEMU opens the
		// volume to read only, with a shared lock, and keeps each write of
		// the machine in a temporary file of its own. No program of the
		// system writes its boot volume (the block service serves the data
		// disk and the disk of the measures), and the firmware is not ours:
		// a write that it makes stays private, and no machine reads one.
		strings.concatenate({"if=none,id=boot,format=raw,snapshot=on,file=", volume}, context.temp_allocator),
		"-device",
		// The boot volume is the first boot option of the firmware: with no
		// bootindex, the order of its options follows its own enumeration,
		// and a firmware with a network stack can try a network boot first.
		// On the machine with the IOMMU, the boot disk has the modern
		// interface only, so that it too goes through the unit.
		iommu != .None ? "virtio-blk-pci,drive=boot,bootindex=0,disable-legacy=on,iommu_platform=on" : "virtio-blk-pci,drive=boot,bootindex=0",
		"-drive",
		strings.concatenate({"if=none,id=data,format=raw,file=", data_disk}, context.temp_allocator),
		"-device",
		fmt.tprintf("virtio-blk-pci,drive=data,disable-legacy=on,addr=0x%x%s", pci.DATA_DISK_DEVICE, virtio_iommu),
		"-drive",
		strings.concatenate({"if=none,id=scratch,format=raw,file=", scratch_disk}, context.temp_allocator),
	)
	switch iommu {
	case .Intel:
		// The disk of the measures behind a root port of PCI Express, on the
		// bus that the firmware gives the port: the kernel must give it a
		// context table of that bus (src/md/infrastructure/iommu.md,
		// "Bridges").
		append(
			&list,
			"-device",
			fmt.tprintf("pcie-root-port,id=scratch_port,bus=pcie.0,chassis=1,addr=0x%x", pci.SCRATCH_BRIDGE_DEVICE),
			"-device",
			fmt.tprintf("virtio-blk-pci,drive=scratch,disable-legacy=on,bus=scratch_port,addr=0x0%s", virtio_iommu),
		)
	case .Amd:
		// The disk of the measures and an entropy device behind a
		// conventional bridge with no capability of PCI Express: both give
		// their accesses the requester of the bridge, on bus 0, and the
		// kernel gives them one domain (src/md/infrastructure/iommu.md,
		// "Bridges"). QEMU 10 records the device of a page fault of AMD-Vi
		// by its device and its function only, with no bus, so the line of
		// a DMA fault names the device only on bus 0: the requester of the
		// bridge is there (src/md/infrastructure/iommu.md, "Two vendors
		// behind one kernel side"). With no ioevent file, QEMU takes or
		// refuses a request of the disk before the notify of its service
		// returns: the stop of the machine in the test then ends each read
		// that it took.
		append(
			&list,
			"-device",
			fmt.tprintf("i82801b11-bridge,id=conventional_bridge,bus=pcie.0,addr=0x%x", pci.SCRATCH_BRIDGE_DEVICE),
			"-device",
			fmt.tprintf("virtio-blk-pci,drive=scratch,disable-legacy=on,ioeventfd=off,bus=conventional_bridge,addr=0x0%s", virtio_iommu),
			"-device",
			fmt.tprintf("virtio-rng-pci,disable-legacy=on,bus=conventional_bridge,addr=0x1%s", virtio_iommu),
		)
	case .None:
		append(&list, "-device", fmt.tprintf("virtio-blk-pci,drive=scratch,disable-legacy=on,addr=0x%x", pci.SCRATCH_DISK_DEVICE))
	}
	if entropy_device {
		// The bytes come from the generator of QEMU. Two vectors give the
		// device a table of message interrupts: the root service gives a
		// device service its entry 0, and starts none for a device with no
		// table.
		append(&list, "-device", fmt.tprintf("virtio-rng-pci,disable-legacy=on,vectors=2,addr=0x%x%s", pci.ENTROPY_DEVICE, virtio_iommu))
	}
	if sound_output != "" {
		// The sound device writes each frame that its stream gives to a wave
		// file, in the one format of the timed stream: QEMU then converts no
		// rate, and the file holds the frames of the sound service in order
		// (src/md/features/timed_stream.md, "The proof").
		append(&list, "-audiodev", fmt.tprintf("wav,id=sound,path=%s,out.frequency=%d,out.channels=%d,out.format=s16", sound_output, timed_stream.FRAME_RATE, timed_stream.CHANNELS))
		append(&list, "-device", fmt.tprintf("virtio-sound-pci,audiodev=sound,disable-legacy=on,addr=0x%x%s", pci.SOUND_DEVICE, virtio_iommu))
	}
	if firmware != .Usual || tpm_device {
		if test_output == "" {
			fmt.eprintln("modustool: a machine with a TPM or with Secure Boot runs only as a test machine, with its own files")
			return nil, false
		}
		// The firmware writes its own log on the debug console port: the
		// tool shows its end when the boot program does not start.
		append(&list, "-debugcon", strings.concatenate({"file:", machine_file(test_output, FIRMWARE_LOG_SUFFIX)}, context.temp_allocator), "-global", "isa-debugcon.iobase=0x402")
	}
	if firmware == .With_Secure_Boot {
		// The flash of the firmware with Secure Boot is writable only in
		// system management mode.
		append(&list, "-global", "driver=cfi.pflash01,property=secure,value=on")
	}
	if tpm_device {
		// The software TPM that machine_test starts (trusted_boot_scenario.odin),
		// through the socket of this machine, on the CRB interface: the
		// command and its answer are in a buffer of memory, not moved byte
		// by byte through one register. The device does not depend on the
		// firmware: the firmware with Secure Boot has a TPM driver too.
		append(&list, "-chardev", strings.concatenate({"socket,id=tpm_socket,path=", tpm_socket_of(test_output)}, context.temp_allocator))
		append(&list, "-tpmdev", "emulator,id=tpm,chardev=tpm_socket", "-device", "tpm-crb,tpmdev=tpm")
		// The trace of QEMU for the TPM, with the time of each line: when the
		// device received each command of the firmware and when the firmware
		// wrote to the device (a start, a cancel). It shows whether an
		// abandoned command reached QEMU and when the firmware gave it up.
		append(&list, "-msg", "timestamp=on", "-D", machine_file(test_output, QEMU_TRACE_SUFFIX))
		append(&list, "-trace", "enable=tpm_emulator_handle_request", "-trace", "enable=tpm_crb_mmio_write", "-trace", "enable=tpm_emulator_set_locality")
	}
	if test_output != "" {
		// No window. The log of the kernel (the serial port) goes to a file.
		// The monitor of QEMU for a reader is on the standard input: the tool
		// ends QEMU through it. The machine protocol of QEMU is on a socket
		// beside the log: the tool sends the keys and the moves of the
		// pointer through it, and each command has a reply (qmp.odin).
		// A film takes its pictures of a display with no window too, but a
		// display: QEMU draws the console of the firmware and of the boot
		// program in text there, which no display draws.
		if vnc {
			append(&list, "-display", strings.concatenate({"vnc=unix:", film_vnc_socket_of(test_output)}, context.temp_allocator))
		} else {
			append(&list, "-display", "none")
		}
		append(&list, "-serial", strings.concatenate({"file:", test_output}, context.temp_allocator), "-monitor", "stdio")
		append(&list, "-qmp", strings.concatenate({"unix:", qmp_socket_of(test_output), ",server=on,wait=off"}, context.temp_allocator))
		// A second socket of the same protocol, for the worker of a film:
		// its pictures and the keys of the scenario never share a reply
		// (film.odin). A machine with no film leaves it with no connection.
		append(&list, "-qmp", strings.concatenate({"unix:", film_qmp_socket_of(test_output), ",server=on,wait=off"}, context.temp_allocator))
	} else {
		append(&list, "-serial", "stdio")
	}
	return list[:], true
}

// network_device_of gives the network device of a machine: QEMU user
// networking with its TCP when host_port is not 0 (web_host.odin), else the
// peer (`-netdev dgram`).
network_device_of :: proc(host_port, listener_port, machine_descriptor: int) -> string {
	if host_port != 0 {
		return fmt.tprintf("user,id=network,restrict=on,hostfwd=tcp:127.0.0.1:%d-10.0.2.15:80,guestfwd=tcp:%s:80-tcp:127.0.0.1:%d", host_port, GUEST_ADDRESS, listener_port)
	}
	// The socket is bound and connected to the peer: QEMU takes no
	// address of its own (peer_start).
	return fmt.tprintf("dgram,id=network,local.type=fd,local.str=%d", machine_descriptor)
}

// network_device_problem refuses a network device that forwards a UDP port
// of the host to the port of `remote`. QEMU user networking gives each
// forwarded datagram the address 10.0.2.2, the one address that the grant
// of `remote` admits: such a forward opens the calls as the principal to
// whoever reaches the port of the host (docs/QUIC.md, section 7). A
// forward is "hostfwd=[tcp|udp]:[address]:port-[address]:port"; with no
// protocol it is TCP.
network_device_problem :: proc(device: string) -> string {
	for part in strings.split(device, ",", context.temp_allocator) {
		if !strings.has_prefix(part, "hostfwd=") {
			continue
		}
		rule := part[len("hostfwd="):]
		if !strings.has_prefix(rule, "udp:") {
			continue
		}
		dash := strings.last_index_byte(rule, '-')
		colon := strings.last_index_byte(rule, ':')
		if dash < 0 || colon < dash {
			return fmt.tprintf("the network device has a UDP forward that the tool cannot read: %s", part)
		}
		if rule[colon + 1:] == fmt.tprintf("%d", remote.LISTEN_PORT) {
			return fmt.tprintf("the network device forwards a UDP port of the host to the port %d of remote: each sender would call as the principal of the session of remote (%s)", remote.LISTEN_PORT, part)
		}
	}
	return ""
}

// run starts a program with the terminal of this tool and waits for its end.
run :: proc(command: []string) -> bool {
	process, err := os.process_start({command = command, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if err != nil {
		fmt.eprintfln("modustool: cannot start %s: %v", command[0], err)
		return false
	}
	state, wait_err := os.process_wait(process)
	if wait_err != nil || !state.success {
		fmt.eprintfln("modustool: %s failed (code %d)", command[0], state.exit_code)
		return false
	}
	return true
}

// disk_prepare makes a disk of zero bytes when the file is absent, or always
// with fresh.
disk_prepare :: proc(path: string, size: int, fresh: bool) -> bool {
	if !fresh && os.exists(path) {
		return true
	}
	zero := make([]u8, size)
	defer delete(zero)
	if err := os.write_entire_file(path, zero); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, err)
		return false
	}
	return true
}

// make_folder makes a folder and each folder above it. Two processes of the
// parallel build can make the same folder above theirs at the same time:
// the one that loses gets "exists" for that folder before its own folder is
// made, so it tries again.
make_folder :: proc(path: string) -> bool {
	err: os.Error
	for _ in 0 ..< 4 {
		err = os.make_directory_all(path)
		if err == nil || os.exists(path) {
			return true
		}
	}
	fmt.eprintfln("modustool: cannot create %s: %v", path, err)
	return false
}

reset_folder :: proc(path: string) -> bool {
	if os.exists(path) {
		if err := os.remove_all(path); err != nil {
			fmt.eprintfln("modustool: cannot remove %s: %v", path, err)
			return false
		}
	}
	return make_folder(path)
}
