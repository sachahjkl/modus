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
//   FONT_SOURCE: the folder of the BDF files of the font, for the command "font"
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
import "modustool:foundation"
import "modustool:resources"
import "modustool:build"
import "modustool:checks"
import "core:slice"
import "modustool:fuzz"
import "modustool:similarity"
import "modustool:machine"
import "modustool:site"
import "modustool:cache_server"
import "modustool:agent_bridge"
import "modustool:agent_runner"

// The three source libraries of the system (docs/glossary/communication.md,
// "Source library"):
//   modus      the public library (src/library/modus), shipped in the SDK:
//              "modus:contract/ring" (what two parties agree on, no kernel
//              operation) and "modus:system" (what two modules or more
//              compile in, or what a program outside needs).
//   internal   the internal parts (src/library/internal): what one module
//              alone compiles in ("internal:storage/storage_tree"). The
//              compiler refuses it in the kernel and in an outside module.
//   modulus    the kernel parts (src/modulus): pure packages that the kernel
//              alone compiles in ("modulus:iommu").
// The names, folders and flags are in source_folders.odin; the import rules
// are held by library_imports_check.odin.

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
COMMANDS :: [?]foundation.Command {
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
	{name = "build", about = "the modules, the boot image and the boot program, as " + build.BOOT_PROGRAM + "; one host process for each module, as many at once as the processors, or `build <host_processes>`; a module or a boot volume whose inputs are the same is kept; `build whole`: ignore the build records and build all; `build --fast [volume]`: build user modules without full optimization, and build only the named boot volume when given", run = build.run_build},
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
	{name = "module", about = "module <name> with_checks|without_checks with_debug_information|without_debug_information speed|none [compile|convert]: build one module of the table, and its debug object with the debug information, or run one of its two steps alone (the parallel build runs this command for each step)", run = build.run_module},
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
	// Writes a data disk whose store of the module files holds module files: a
	// machine with that disk starts each one from its console, by its hash.
	// Packs a self-contained, deterministic SDK directory containing the public
	// `modus:` library, runtime assembly, public module catalog and verified
	// `.module` files, minimal freestanding Odin and C examples, and a canonical
	// `SDK_MANIFEST.txt` with BLAKE3 root digest and optional Ed25519 signature.
	//
	// - `output-dir`: target directory to write the unpacked SDK.
	// - `--sign-key <path>` (optional): 32-byte Ed25519 private key seed (64 hex
	//   digits or unpadded base64url) used to sign the manifest root digest.
	// - `--modules-dir <path>` (optional): directory containing built `.module`
	//   files; defaults to `build/modules` when present.
	{name = "sdk-pack", about = "sdk-pack <output-dir> [--sign-key <path>] [--modules-dir <path>]: assemble a deterministic, self-contained SDK directory with public library, runtime, module catalog, examples, and signed or unsigned SDK_MANIFEST.txt", run = build.run_sdk_pack},
	// Verifies an unpacked SDK directory against its `SDK_MANIFEST.txt`: checks
	// every file's BLAKE3 hash, rejects missing or stray unlisted files, rejects
	// symbolic links and any `internal` or `modulus` path, and verifies the
	// Ed25519 signature when present or required by `--public-key`.
	//
	// - `sdk-dir`: directory of the unpacked SDK.
	// - `--public-key <path>` (optional): 32-byte Ed25519 public key (64 hex
	//   digits or unpadded base64url); requires a valid signature by this key.
	{name = "sdk-verify", about = "sdk-verify <sdk-dir> [--public-key <path>]: verify every file hash, absence of stray or internal/modulus paths, and Ed25519 signature of an unpacked SDK directory", run = build.run_sdk_verify},
	// Converts a freestanding x86-64 relocatable ELF object (`.o`, from C, Rust,
	// Zig, Odin, or assembly) paired with a language-neutral `module.manifest`
	// into a verified modus module file with no repository checkout.
	//
	// - `object.o`: freestanding System V AMD64 `ET_REL` relocatable object.
	// - `module.manifest`: plain-text language-neutral module description.
	// - `output.modus`: destination path for the validated modus module file.
	// - `--sdk <sdk-dir>` (optional): verified SDK directory whose modules folder
	//   resolves declared imports.
	// - `--import-dir <dir>` (optional, repeatable): extra directory searched for
	//   imported `.module` or `.modus` files.
	{name = "sdk-convert", about = "sdk-convert <object.o> <module.manifest> <output.modus> [--sdk <sdk-dir>] [--import-dir <dir>]: convert a freestanding ET_REL object and language-neutral module.manifest into a validated modus module file", run = build.run_sdk_convert},
	// Generates six self-contained C11 contract headers (`modus_types.h`,
	// `modus_operation.h`, `modus_errors.h`, `modus_call_outcome.h`,
	// `modus_ring.h`, `modus_module.h`)
	// with fixed-width types, explicit enum values, struct layouts, and
	// `_Static_assert` size and offset checks derived from Odin's `size_of` and `offset_of`.
	//
	// - `output-dir`: target directory where the C11 header files are written.
	{name = "c-headers", about = "c-headers <output-dir>: generate self-contained C11 contract headers (modus_types.h, modus_operation.h, modus_errors.h, modus_call_outcome.h, modus_ring.h, modus_module.h) with _Static_assert sizeof and offsetof checks", run = build.run_c_headers},
	{name = "module-disk", about = "module-disk <disk file to write> <module file> [<module file> ...]: write a data disk whose store `module_files` holds each module file under the name of its file, with the debug object `<name>.debug` beside it under the hash of the module, and print the line of the console that starts each one", run = build.run_module_disk},
	{name = "module-build", about = "module-build <folder of the module> [--system <folder of the system>] [--out <folder of the outputs>]: build one module from a folder outside the repository, with its module build file `" + build.MODULE_BUILD_FILE_NAME + "`: write <name>.module and <name>.debug, and print the hash of the module and the names of its exports", run = build.run_module_build},
	// Builds one boot volume in this process: its boot image with the system
	// description, its boot program, and the volume file.
	//
	// - `name`: `main`, or the end of the name of the volume file:
	//   `shortage` for `build/boot_volume_shortage.img`.
	//
	// The build runs this command once for each boot volume that it must
	// build, several at once. Run it by hand, after a build, to see the
	// errors of one volume alone.
	{name = "volume", about = "volume <name> [speed|none]: build one boot volume, after a build wrote the modules and the boot images (the build runs this command for each volume that it must build)", run = build.run_volume},
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
	// - `from <folder>` (optional, after a part): the part on the test
	//   inputs of a folder, with no build: the command of a part derivation
	//   of the flake. It writes the count of its checks in
	//   build/checks_passed.txt.
	// - `steps <first> to <last>` (optional, after a part): the boot steps,
	//   the setup steps of each `with <first> to <last>`, and the steps of
	//   the range, of the first machine of the part or of the machine that
	//   `of <log name>` names; then the part ends.
	//
	// ```
	// nix develop -c modustool test network
	// ```
	{name = "test", about = "build, then run the parts of the machine test, several at once: start each machine under QEMU, press its keys and move its pointer, check the log, save pictures of the screen; `test [--fast] <part>`: one part only (with `--fast`, build user modules without full optimization and only the boot volumes of the part); `test <part> from <folder>`: one part on the test inputs of a folder, with no build; `test [--fast] <part> steps <first> to <last> [of <machine>] [with <first> to <last>]...`: the boot steps, the setup steps and the steps of a range of one machine", run = run_test},
	// Copies the test inputs of the build folder (the files of a whole build
	// that the machine test reads) into `<folder>/test_inputs`, and writes
	// the names of the test parts into `<folder>/test_parts.json`: the
	// derivation of the whole build of the flake runs it
	// (src/md/infrastructure/full_check.md, "The derivations of the check").
	{name = "test_inputs", about = "copy the test inputs of the build folder into <folder>/test_inputs, and the names of the test parts into <folder>/test_parts.json, for the derivations of the check of the flake", run = run_test_inputs},
	// Joins the output of the host checks and of each part derivation into
	// the output of the check `boot-test` of the flake: the logs, the
	// pictures, and the count of the checks of all. It refuses a join that
	// lacks a part, has a part twice, or where two outputs write one file.
	{name = "test_join", about = "<target> <host checks> <part>=<folder> ...: join the outputs of the derivations of the check of the flake into its output", run = run_test_join},
	// Proves that a change of a document, or of a host test of the tool,
	// leaves the derivation of each test part the same: three copies of the
	// tracked files in build/part_cache, two of them changed, and the
	// derivations of the parts of each. Each evaluation builds the test
	// inputs of its tree, so it costs two whole builds.
	{name = "part_cache", about = "check that a change of a document or of a host test of the tool leaves the derivation of each test part the same, so Nix runs no part again", run = run_part_cache},
	// Builds the modules, then holds each text of the log that a step of a
	// scenario waits for against the fact templates of the module files:
	// a fact wait that no template renders fails here, before any machine
	// (src/md/infrastructure/scenario_fault_loop.md). `check` and `test`
	// run the same check after their build.
	{name = "fact_waits", about = "build the modules, then check that each fact wait of the scenarios is the start of a sentence that a fact template of the build renders, with no machine", run = run_fact_waits},
	// After a build of the check of the flake with --keep-going: the host
	// checks and each part whose output is not in the store, with its first
	// failed step and its whole build log in build/failed_parts/.
	// `screenshots` runs it after a failed build.
	{name = "failed_parts", about = "list the host checks and each test part of the check of the flake that failed or did not run, with the first failed step and the path of the whole log of each", run = run_failed_parts},
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
	{name = "run", about = "build, then start the machine under QEMU, with the log of the kernel on this terminal; `run without_checks`: the measure build; `run --remote-display <viewer key>`: a machine with no window for a viewer on the host, through the UDP relay of the peer to remote_display", run = run_machine},
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
	{name = "screenshots", about = "take the pictures and the logs of the check of the flake (its one run of the machine test), run the measure runs on the host, then write the measure record " + checks.MEASURE_RECORD_FILE + " and copy the pictures to " + foundation.DOCUMENT_SCREENSHOT_FOLDER + " and to a new folder of the development log " + foundation.DEVELOPMENT_LOG_NAME + " beside the main working tree; `screenshots compress`: compress the PNG files of " + foundation.DOCUMENT_SCREENSHOT_FOLDER + " and " + foundation.RESOURCE_FOLDER + " whose data is stored, with no machine", run = run_screenshots},
	// Runs a machine that measures, with no other load: the numbers that it
	// prints are measures, never conditions of the test.
	//
	// Each machine is a measure run: its boot image holds the resource
	// `measure_run`, and a process then measures its rates over a duration.
	// The modules are those of the test.
	//
	// - no argument: the process `locks` on a machine where only the desktop
	//   runs: the kernel entries in one second with 1, 2 and 4 lockers, in
	//   `build/test_output_measure.txt`.
	// - `scheduler N`: N machines that run the process `scheduler` alone, in
	//   `build/test_output_scheduler_<n>.txt`.
	// - `time_page`, `crowd`, `disk`, `flow`, `limits`: the process alone, in
	//   `build/test_output_measure_<process>.txt`; the command prints its
	//   lines.
	// - `windows`: each window of the interface package, alone, and a table of
	//   the time of its pictures.
	// - `address_space`, `shortage`: the machine of one measure.
	// - `without_checks ...`: the same, on the build with no check in the
	//   kernel.
	//
	// The tool checks no speed: a process checks its counts, and the numbers
	// are printed for a reader (docs/TOOLS.md, "The bounds of the tests").
	{name = "measure", about = "build, start the machine, run the measures of the locks of the kernel with no other process, then the frame at 1920x1080 of processor_frame, and stop: the numbers are in " + checks.TEST_OUTPUT_MEASURE + "; `measure scheduler N`: the process scheduler N times; `measure time_page|crowd|disk|flow|limits`: the process alone, and its lines; `measure windows`: each window that the interface package draws, alone, and a table of the time of its pictures; `measure without_checks ...`: the measure build, with no check in the kernel (no lock order check, no check of the frames)", run = run_measure},
	// Builds, starts a machine that runs the scenario of a film, and films
	// it: the pictures of the screen, taken while the scenario types, become
	// a film with ffmpeg, which must be on the path. The film is for the
	// development log and for a news entry that names it, not a test.
	//
	// - no argument, or `terminal`: the film of the terminal.
	// - `palette`: the film of the palette.
	// - `heron`: the film of the process heron.
	{name = "film", about = "build, start the machine, film a scenario (" + machine.FILM_NAMES + "; no argument: terminal), and write " + machine.FILM_FOLDER + "/<name>.mp4, " + machine.FILM_FOLDER + "/<name>.webm, the film cues " + machine.FILM_FOLDER + "/<name>" + machine.FILM_CUES_SUFFIX + ", a copy of the MP4 file in a new folder of the development log " + foundation.DEVELOPMENT_LOG_NAME + " beside the main working tree, and " + checks.FILM_DOCUMENT_FOLDER + "/<name>.webm when a news entry names the film (needs ffmpeg)", run = machine.run_film},
	// Converts the BDF files of Spleen (8x16, 12x24, 16x32 and 32x64, from the
	// folder `FONT_SOURCE`) to Odin data in `src/library/modus/graphics/font.odin`
	// and `src/library/modus/bootscreen/spleen_sizes.odin`. The results are
	// in the repository, so a build does not need the BDF files: run it only
	// to change the font.
	{name = "font", about = "convert the BDF files of the font to " + foundation.FONT_OUTPUT + " and " + foundation.BOOT_DISPLAY_FONT_OUTPUT, run = resources.run_font},
	// Converts the pointer manifests of `resources/pointers` to the pointer
	// theme files of the boot image, in `build/pointers`.
	//
	// - `folder` (optional): the Xcursor theme to read; else the folder of
	//   `POINTER_THEME_SOURCE`.
	//
	// It prints a table of each theme: each pointer, its size and its hot
	// spot (docs/POINTERS.md).
	{name = "pointers", about = "convert the pointer manifests of resources/pointers to pointer theme files in " + resources.POINTER_BUILD_FOLDER + ", with the Xcursor folder of " + resources.POINTER_THEME_SOURCE_VARIABLE + " or of the path after the command; print a table of each theme", run = resources.run_pointers},
	// Takes the subset of each vector font candidate of `VECTOR_FONT_SOURCES`
	// that the system draws, writes it to `resources/fonts`, and draws one
	// picture that compares the candidates. Run it to change a font; a build
	// reads the files of the repository (docs/FONTS.md).
	// Writes the tables of the written shaper from the Unicode Character
	// Database of `UNICODE_DATA_SOURCE` (src/md/features/written_shaping.md).
	// The result is in the repository: run it to change the version of
	// Unicode.
	// Writes the script font set, the fonts past the boot image, from
	// `SCRIPT_FONT_SOURCES`, and prints its hash, which a plan names
	// (src/md/features/script_fonts.md).
	{name = "script_fonts", about = "write the script font set of " + resources.SCRIPT_FONT_SOURCES_VARIABLE + " to " + resources.SCRIPT_FONTS_OUTPUT + " and print its hash", run = resources.run_script_fonts},
	{name = "unicode_tables", about = "write the tables of the written shaper from the Unicode Character Database of " + resources.UNICODE_DATA_SOURCE_VARIABLE + " to " + resources.UNICODE_TABLES_OUTPUT, run = resources.run_unicode_tables},
	{name = "vector_fonts", about = "subset the vector font candidates of " + resources.VECTOR_FONT_SOURCES_VARIABLE + " to " + resources.VECTOR_FONT_FOLDER + " and draw " + resources.CANDIDATES_PICTURE, run = resources.run_vector_fonts},
	// Draws the files of the mark of the system from its geometry in
	// `src/library/modus/mark`: the icons in `resources/logo`, the font of the name of
	// the mark, the picture of the project, and one picture of every frame
	// of the animations of the mark.
	//
	// - `check`: draws them again and compares them with the files of the
	//   repository; `modustool check` runs it, so a mark that changed in
	//   the code and not in the files fails.
	{name = "logo", about = "draw the files of the mark of the system from " + resources.MARK_SOURCE_FOLDER + ": " + resources.LOGO_FOLDER + " and " + resources.PROJECT_IMAGE + "; `check` verifies them; and " + resources.MARK_ANIMATIONS_PICTURE + ", every frame of the animations of the mark", run = resources.run_logo},
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
	{name = "mark", about = "draw one file of the mark: still | frame | animation | tile_map | table | uses | developer, with --variant smooth|cells, --cell <pixels>, --scheme dark|light, --background none|scheme, --animation <name>, --frame <number>, --forms yes|no, --width <pixels>, --format png|ico|svg|apng|json, --entry <variant>:<cell>:<pixels>, --dark-rule yes|no, --out <file>", run = resources.run_mark},
	// Converts each picture of `resources/hall_of_fame/CREDITS.md` to the
	// pixels of a portrait of the process `hall_of_fame`, in
	// `src/modules/demonstrations/hall_of_fame/portraits`. The result is in the
	// repository, so a build decodes no PNG file.
	{name = "portraits", about = "convert the pictures of " + resources.HALL_OF_FAME_CREDITS_FILE + " to the portraits of " + resources.HALL_OF_FAME_PORTRAIT_FOLDER, run = resources.run_portraits},
	// Calls an export of a service of the machine that `modustool run`
	// started, from the host, and prints the typed result.
	//
	// - `key`: the public key of the process `remote`, as its window shows it.
	//   The QUIC client of the tool pins it: a machine with another key is
	//   refused.
	// - `call`: one call in the language of the console, in quotes.
	//
	// The call goes to the peer of `run` through a socket that only this user
	// reaches, then over QUIC to `remote`, which calls the service for the
	// principal. A table prints as rows, with its count.
	//
	// ```
	// nix develop -c modustool call <key> "monitor.counts_named([(\"processes\"), (\"processors\")])"
	// ```
	{name = "call", about = "call <key> \"service.export(arguments)\": call an export of a service of the machine that `run` started, through the process remote over QUIC (key: the public key of remote, from its window), and print the typed result; the peer of `run` takes the call on a socket that only this user reaches", run = machine.run_call},
	// Builds one module again and again, with no machine, and counts the
	// distinct results: one distinct module, LLVM IR file and object each is a
	// build that gives the same bytes every time.
	//
	// - `module`, `count`: the module and the count of builds.
	// - `all count [host_processes]`: every module and the boot program, one row
	//   each.
	{name = "repeat", about = "repeat <module> <count>: build one module again and again, with no machine, and count the distinct modules, LLVM IR files and objects; `repeat all <count> [host_processes]`: every module and the boot program, one row each", run = build.run_repeat},
	// Proves two-stage self-hosting fixed-point determinism of modustool:
	// builds `tools/modustool` into `stage1/modustool`, invokes that binary to
	// build `stage2/modustool` with identical deterministic flags, compares
	// their BLAKE3 hashes, and reports the first diverging byte offset if they
	// differ (docs/TOOLS.md, "The self-hosting check").
	//
	// - `--staging-dir <folder>` (optional): isolated staging directory root;
	//   defaults to `build/self_host`.
	// - `--emit-binary <path>` (optional): compile `tools/modustool` once with
	//   deterministic self-host flags into `<path>` (invoked by stage1).
	// - `--verify-chains` (optional): also verify the C compiler self-host,
	//   live-bootstrap seed, and SQLite/Lua/zstd C-world recipe chains.
	{name = "self-host", about = "self-host [--staging-dir <folder>] [--emit-binary <path>] [--verify-chains]: build stage1/modustool, invoke stage1 to build stage2/modustool with deterministic flags, and prove blake3(stage1) == blake3(stage2)", run = build.run_self_host},
	// Proves that the C compiler builds itself: chibicc built by clang
	// compiles the sources of chibicc, the assembler of modus makes stage 1
	// of the texts, stage 1 compiles the same sources on the host, and the
	// module of stage 2 has the hash of stage 1 (docs/TOOLS.md, "The
	// self-hosting of the C compiler"). It needs the variable CHIBICC_SOURCE
	// of the shell of the flake, and writes into build/c_self_host.
	{name = "c-self-host", about = "c-self-host: build chibicc with clang, then with itself twice through the assembler of modus, and prove blake3(stage 1) == blake3(stage 2)", run = build.run_c_self_host},
	// Copies a file of `core:crypto` of the Odin compiler into the repository
	// with the package name of the copy and the listed changes of its imports,
	// and prints its line of the manifest of the origin.
	//
	// - `origin`: the file, under the root of Odin.
	// - `file`: its path in the repository.
	{name = "cryptography-take", about = "cryptography-take <file under the root of Odin> <file of the repository>: copy a file of core:crypto with the listed import changes, and print its line of the manifest", run = checks.run_cryptography_take},
	// Prints the line of the list of the system files for each `.odin` file of
	// `src/library/modus/cryptography` that the manifest of the origin does not name:
	// the files that the project wrote, which a reviewer checks before the
	// lines go into the list.
	{name = "cryptography-system-hashes", about = "print the line of " + checks.CRYPTOGRAPHY_SYSTEM_FILES + " for each .odin file of " + foundation.CRYPTOGRAPHY_FOLDER + " that is not taken from Odin", run = checks.run_cryptography_system_hashes},
	// Checks that each file that the manifest of the origin names is its file
	// in Odin with the listed changes only. `modustool check` runs it.
	{name = "cryptography-origin", about = "check that each file of " + foundation.CRYPTOGRAPHY_MANIFEST + " is its origin in Odin with the listed changes only", run = checks.run_cryptography_origin},
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
	{name = "rule-checks", about = "check that " + foundation.OPERATION_SOURCE + " declares the count of kernel operations that " + checks.OPERATION_PROPERTY_DOCUMENT + " states, that no source file of the system that is not a test calls or names an allocator, that no export of a module gives a negative number with no error record, that no family of integer constants is used as a closed set of choices, that no cast of a word to an enum skips its border, that only the loader and the root service name the field image_checks of a load source, that module display texts follow docs/WRITING.md, and that no service or library names a bound of the tests", run = checks.run_rule_checks},
	{name = "library-imports", about = "check that each import of each source file of src/ follows the rule of its file, that the kernel and a contract package import no support package, and that each host test that imports a package of core: starts with the build line of the host", run = build.run_library_imports},
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
	// a line of `tools/modustool/similarity/similarity_kept.txt`.
	{name = "similarity", about = "the similarity of the code pieces of src/ and tools/: families with their factoring template, ranked by the nodes that a factoring saves, in " + similarity.SIMILARITY_OUTPUT_FOLDER + "; `similarity near <file>:<line>`: the procedures most similar to one; `similarity pair <file>:<line> <file>:<line>`: the score of two procedures", run = similarity.run_similarity},
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
	{name = "changelog", about = "new <type> <subject> \"<text>\" (or - and the text on the standard input) | check | assemble | release <release number> | notes <release number> | times: the fragments of `" + checks.FRAGMENT_FOLDER + "` and the releases of `" + checks.CHANGELOG_FILE + "`", run = checks.run_changelog},
	// Makes a release in one command: `changelog release`, a commit, a signed
	// release tag, and one atomic push of both to master. It refuses a branch
	// other than master, a tree with changes, and a master that does not hold
	// origin/master; when origin moved, it undoes, merges and tries again with
	// the next number (docs/TOOLS.md, "The release").
	{name = "ship", about = "step | correction | <release number> [--dry-run]: the release in one command: the changelog, a commit, a signed release tag v<number>, one atomic push to master", run = checks.run_ship},
	// Merges a batch of branches into master after one full check, in the
	// order of its arguments, each with its own merge commit. When the check
	// fails, it checks the two halves of the batch, to name the branch at
	// fault, and merges the halves that pass; it stops after two branches at
	// fault, and never passes its budget of full checks. Then it pushes
	// master and removes each merged branch and its worktree. It refuses a
	// wrong list, a branch that git does not allow and an identity that is
	// not the configured git user, with nothing changed
	// (docs/TOOLS.md, "The merge queue").
	{name = "queue", about = "<branch>...: merge a batch of branches into master after one full check in a worktree beside the main tree, split the batch in halves to name a branch at fault, push master, and remove the merged branches and their worktrees", run = checks.run_queue},
	// Moves the folders of the source library into the two source libraries
	// and rewrites the import lines, the comments and the documents. A
	// second run changes nothing, so a branch runs it after its merge of
	// master. It prints each move, each file changed and each string of a
	// source that still holds an old form, for a hand change
	// (docs/TOOLS.md, "The rename of the library").
	{name = "rename-library", about = "move the folders of the source library into its two source libraries with git mv, and rewrite the import lines, the comments and the documents; idempotent, for each branch after its merge of master", run = checks.run_rename_library},
	// Gives each release tag whose tree holds a measure record its copy in
	// the measure history, for the releases from before the release command
	// copied the record. It changes no file that exists
	// (docs/TOOLS.md, "The release").
	{name = "measure-history", about = "the copy of the measure record of each release tag that holds one, in `" + checks.MEASURE_HISTORY_FOLDER + "`, for the charts of each measure over the releases", run = checks.run_measure_history},
	// Compares two measure records, as the record of a build before a
	// change and the record after it (docs/TOOLS.md, "The comparison of two
	// measure records"). It asserts nothing.
	{name = "measure-compare", about = "<record before> <record after>: the line of each measure in two measure records, and the number of each series with its ratio", run = checks.run_measure_compare},
	// Works on the news entries of `news/`, the dated reports of what a
	// reader can now see or use.
	//
	// - `new <subject>`: writes an entry with the date of today and no title
	//   and no text: the check fails until they are written.
	// - `check`: checks the head, the date, the picture, the release, the
	//   guide and the length of each entry. `modustool check` runs it.
	{name = "news", about = "new <subject> | check: the news entries of " + checks.NEWS_FOLDER + ", dated reports in prose of what a reader can now see or use, for the page of the news of the site", run = checks.run_news},
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
	// Reads the peaks of the budgets at the first state of work in the logs
	// of machine runs, and prints the working memory that each source
	// states so that its floor is its peak
	// (src/md/features/module_budget_request.md, "The first state of work").
	{name = "floors", about = "measured <log> ...: the peak of each module at its first state of work, its floor, and the working memory that its source states", run = build.run_floors},
	{name = "roadmap", about = "check: the planned work of `" + checks.ROADMAP_FILE + "`, in the sections Now, Next, Later and Maybe, for the page of the roadmap of the site", run = checks.run_roadmap},
	// Works on the fences `byte-layout` of the guides, whose body is the
	// text form of the byte layout of a record of a format.
	//
	// - `write`: writes the body of each fence again from the code: the
	//   offsets and the sizes from the compiler, the types from the source.
	// - `check`: checks that each body is that text. `modustool check` runs
	//   it, and `modustool site` stops on such a fault too.
	//
	// The design: (docs/SITE.md, "The byte layouts").
	{name = "byte-layouts", about = "write | check: the text of each fence `" + site.BYTE_LAYOUT_FENCE_LANGUAGE + "` of the guides, the byte layout of a record of a format from the code", run = site.run_byte_layouts},
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
	{name = "site", about = "write the site of the system in " + site.SITE_FOLDER + ": the pages from the documents, the code, the news, the pictures and the logs of the last machine tests, an index and one small script for the search, and the feed of the news; no request to another server", run = run_site},
	// Builds the kernel of a browser machine: `src/modulus` for
	// `freestanding_wasm64p32`, in `build/browser_machine/modulus_kernel.wasm`.
	// It checks the border of the file: each import is one of the six
	// functions of the module `modus_page` that the page gives, and the
	// exports are `memory`, `entry` and `modus_processor_loop_run`. It
	// writes the page, its worker and the host of the kernel beside it, and
	// the boot image of the build when there is one: the folder is a site
	// that a static server serves.
	//
	// - `boot` (optional): then start the kernel in Node with the host of
	//   the page, print each line of its serial port, and check the mark of
	//   the kernel and, with a boot image, the start of the root service.
	//   The run ends when the machine stops, or at the hang bound. Node 24
	//   or later must be on the path.
	// - `<boot image>` (optional, after `boot`): the boot image to start, in
	//   place of the one of the build.
	// - `console`: then write the console page,
	//   `browser_machine_console.html`, and its boot image, `console.image`,
	//   from the boot image of the build: the console with `dom_terminal`
	//   on the second serial port, and no compositor, drawing module or font.
	//
	// ```
	// nix develop -c modustool browser-machine boot
	// nix develop -c modustool browser-machine console
	// ```
	//
	// The design: src/md/features/browser_machine.md, "The page and its host".
	{name = "browser-machine", about = "build the kernel for WebAssembly in " + build.BROWSER_MACHINE_FOLDER + ", check its imports and its exports, and write the page of the browser machine beside it; `browser-machine boot [<boot image>]`: then start it in Node and print its serial port; `browser-machine console`: then write the console page and its console image, with dom_terminal on the second serial port and no desktop", run = build.run_browser_machine},
	// Prints the number of the newest release of `CHANGELOG.md`, as `0.91.0`:
	// the number that a workflow gives to a release.
	{name = "release_number", about = "print the release number of the system: the newest release of `" + checks.CHANGELOG_FILE + "`", run = checks.run_release_number},
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
	{name = "release", about = "image: build the release volume with the keys of the publisher (" + build.SIGNING_KEY_VARIABLE + "), and write the compressed GPT disk image, " + build.RELEASE_CHECKSUM_FILE_NAME + " and its release signature in " + build.RELEASE_OUTPUT_FOLDER + "/; `release tag-check <tag>`: check that the tag is v and the release number", run = build.run_release},
	// Verifies the files of a release: the release signature of the
	// checksum list with the public key of the repository, then the SHA-256
	// of the image against its line. The signature file is beside the
	// checksum list, with the suffix `.sig`.
	//
	// ```
	// nix develop -c modustool verify modus-0.93.0-x86_64.img.zst SHA256SUMS.txt
	// ```
	{name = "verify", about = "verify <image> <" + build.RELEASE_CHECKSUM_FILE_NAME + ">: check the release signature of the checksum list with " + build.RELEASE_PUBLIC_KEY_FILE + ", then the SHA-256 of the image", run = build.run_verify},
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
	{name = "module-hashes", about = "write <file> | compare <file>: record the hash of each module of " + foundation.MODULE_BUILD_FOLDER + ", or compare the build with such a record: print each module whose hash differs, and fail if one does", run = build.run_module_hashes},
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
	// (`test`), the test of the debug objects against the linked files of
	// the build, and a second build that must give the same bytes.
	//
	// - `without_machines` (optional): no machine test; a whole build of the
	//   main volume before the second build. The check of the flake runs
	//   this form, and each test part in a derivation of its own.
	{name = "check", about = "odin check -vet and odin test of the host code, the fuzz targets (their corpus and a fixed count of new executions), the checks of the sources (among them the rule on comments and the form of the glossary), changelog check, news check, roadmap check, then test; `check without_machines`: no machine test", run = run_check},
	// Fuzzes the readers of the system on the host: the module file, the
	// debug object, the storage format, QUIC and TLS, TCP and HTTP
	// (docs/TOOLS.md, "The fuzzing").
	//
	// - `list`: the fuzz targets, with the inputs of their corpus.
	// - `<target> [executions [host_processes [seed]]]`, `all [executions]`:
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
	{name = "fuzz", about = "list | <target> [executions [host_processes [seed]]] | all [executions] | show <target> <file> | minimize <target> <file> | regression <target> <file> | corpus <target>: fuzz the readers of the system on the host, guided by edge counters", run = run_fuzz},
	// The child process of `fuzz` and of `check`: it runs the engine on one
	// target. The parent starts it; it is not a command to run by hand.
	{name = "fuzz-child", about = "the child process of `fuzz` and of `check`, which the parent starts", run = fuzz.run_fuzz_child},
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
	{name = "key", about = "key new <folder outside the repository>: write a new signing key of the system description (the private key, readable by its owner only, and the public key), with the firmware signing key and the release signing key; `key write <folder>`: the same folder from the variables of the secrets of a workflow; `key show`: print the public key that the build uses (" + build.SIGNING_KEY_VARIABLE + ", or the test signing key)", run = build.run_key},
	// Serves a content-addressed object cache on the host over framed streams:
	// objects by BLAKE3 or tree hash, and signed realisations.
	//
	// - `--dir <path>`: the folder of the store (`objects/` and `realisations/`).
	// - `--listen <host:port>` (optional): the address to listen on; defaults to
	//   `127.0.0.1:7200`.
	// - `--signer-key <path>` (optional, repeatable): a 64-hex-digit Ed25519
	//   private key file whose derived public key may upload objects and signed
	//   realisations.
	// - `--authorized-key <path>` (optional, repeatable): a 64-hex-digit Ed25519
	//   public key file allowed to upload objects and signed realisations.
	{name = "cache-serve", about = "cache-serve --dir <path> [--listen <host:port>] [--signer-key <path>] [--authorized-key <path>] [--status-listen <host:port>] [--endpoint <host:port>] [--site <address>]: serve an object cache of blobs, canonical trees and signed realisations, and with --status-listen its page and status.json over HTTP", run = cache_server.run_cache_serve},
	// The client of an object cache (src/md/infrastructure/cache_publication.md).
	//
	// - `blob <file>...`: puts each file as a blob and prints its hash.
	// - `release <boot image>`: puts each file of the image that the cache
	//   does not hold, then the cache test recipe, its output and its
	//   realisation signed with the key. The release workflow runs it.
	{name = "cache-put", about = "cache-put <host:port> --key <seed file> blob <file>... | release <boot image>: put files, or each file of a boot image and the signed realisation of the cache test recipe, on an object cache", run = cache_server.run_cache_put},
	// Gets from an object cache and checks: a blob against its hash, a
	// realisation against a trusted signer, each file of a boot image and the
	// cache test recipe. The signer is resources/keys/cache_signing_key.public
	// unless --signer names another. It needs the network for a public cache:
	//
	// ```
	// nix develop -c modustool cache-get cache.modus.systems:5010 test-recipe
	// ```
	{name = "cache-get", about = "cache-get <host:port> blob <hash> [<output file>] | realisation <recipe hash> --signer <public key file> | release <boot image> [--signer <file>] | test-recipe [--signer <file>]: take from an object cache and refuse what does not verify", run = cache_server.run_cache_get},
	// Serves the typed host agent bridge over line-delimited JSON-RPC 2.0 on
	// standard input and output, enforcing client-key permissions, remote key
	// uses, active wide-grant window scopes, append-only BLAKE3 act recording,
	// and explicit principal approval for grant-adding plans.
	//
	// - `--remote-key <64-hex>`: public key of `remote` pinned by the transport.
	// - `--client-key <64-hex>`: client public key authorized by the principal.
	// - `--socket <path>` (optional): path to the call socket of the peer.
	// - `--principal <id>` (optional): principal identifier; defaults to `0`.
	// - `--permissions <csv>` (optional): comma-separated subset of
	//   `eval_lex,read_screen,send_input,read_log_facts`.
	// - `--wide-grant-serial <u64>`, `--wide-grant-windows <id,...>`,
	//   `--wide-grant-duration-ms <u64>` (optional): active wide-grant window
	//   scope required for synthetic input.
	{name = "assistant", about = "assistant --remote-key <64-hex> --client-key <64-hex> [--socket <path>] [--principal <id>] [--key-variable <NAME>] [--fake <script>] [--once]: the agent runner of the window assistant: it answers each request through remote, a language model and the host agent bridge", run = agent_runner.run_assistant},
	{name = "agent-bridge", about = "agent-bridge --remote-key <64-hex> --client-key <64-hex> [--socket <path>] [--principal <id>] [--permissions <csv>] [--snapshot-dir <folder>] [--wide-grant-serial <u64> --wide-grant-windows <id,...> [--wide-grant-duration-ms <u64>]]: serve the typed host agent bridge over stdio JSON-RPC 2.0", run = agent_bridge.run_agent_bridge},
}

main :: proc() {
	// The development shell of Nix gives the linker a search path with the
	// folder of the build in it (NIX_LDFLAGS). The linker would write it in
	// each module, and the hash of a module would depend on that folder.
	_ = os.unset_env("NIX_LDFLAGS")
	when build.TOOL_BUILDS_ITSELF {
		build.tool_build_current()
	}
	if len(os.args) < 2 || os.args[1] == "help" || os.args[1] == "-h" || os.args[1] == "--help" {
		usage()
		return
	}
	// Commands that operate on external directories or unpacked SDKs can run
	// outside a repository checkout.
	outside_repo_ok := os.args[1] == "module-build" || os.args[1] == "cache-serve" || os.args[1] == "cache-put" || os.args[1] == "cache-get" || os.args[1] == "sdk-verify" || os.args[1] == "sdk-convert" || os.args[1] == "agent-bridge" || os.args[1] == "assistant"
	if !outside_repo_ok && !os.exists(foundation.ROOT_MARK) {
		fmt.eprintln("modustool: start it from the root of the repository")
		os.exit(foundation.EXIT_USAGE)
	}
	commands := COMMANDS
	for c in commands {
		if c.name == os.args[1] {
			os.exit(c.run(os.args[2:]))
		}
	}
	fmt.eprintfln("modustool: no command %s", os.args[1])
	usage()
	os.exit(foundation.EXIT_USAGE)
}

usage :: proc() {
	fmt.println("modustool <command>")
	commands := COMMANDS
	for c in commands {
		fmt.printfln("  %-14s %s", c.name, c.about)
	}
}

// run_site is the command `site`: the page of the commands shows this
// table, and the package site cannot import the command package.
run_site :: proc(args: []string) -> int {
	commands := COMMANDS
	return site.run_site(args, commands[:])
}

run_machine :: proc(args: []string) -> int {
	if len(args) >= 1 && args[0] == "--remote-display" {
		// A machine for a viewer on the host: no window, the relay of the
		// peer to remote_display (machine/remote_display_run.odin).
		if len(args) != 2 {
			fmt.eprintln("modustool: run --remote-display <viewer key>: the viewer key is the 64 hexadecimal digits that `modus-viewer -print-key` prints")
			return foundation.EXIT_USAGE
		}
		if code := build.build_system(build.boot_volumes_of_command("run")); code != 0 {
			return code
		}
		return machine.remote_display_run(args[1]) ? 0 : foundation.EXIT_FAILURE
	}
	if len(args) >= 1 && args[0] == "without_checks" {
		build.test_build_checks = false
	}
	if code := build.build_system(build.boot_volumes_of_command("run")); code != 0 {
		return code
	}
	if !machine.disk_prepare(machine.DATA_DISK, build.DATA_DISK_SIZE, false) {
		return foundation.EXIT_FAILURE
	}
	// The peer receives the calls of `modustool call` on a Unix socket of
	// the private folder of the user: `modustool call` finds it by its name.
	peer: machine.Peer
	if !machine.peer_start(&peer, machine.CALL_SOCKET_RUN_NAME) {
		return foundation.EXIT_FAILURE
	}
	// The developer names the key of each start of remote in `modustool
	// call`: this peer takes it.
	peer.remote.keys_from_calls = true
	fmt.printfln("modustool: the peer takes the calls of `modustool call` at %s (only this user reaches it)", peer.call_socket)
	// remote takes the calls of a client whose key a principal allowed: a
	// key drawn for this run, which the developer allows in a console.
	client_key := machine.peer_remote_client_key_draw(peer.remote)
	fmt.printfln("modustool: the key of the client of remote in the peer, for this run: %s; allow it in a console of the machine: remote_allow(\"%s\")", client_key, client_key)
	defer machine.peer_stop(&peer)
	command, ok := machine.machine_command(build.BOOT_VOLUME, "", machine.DATA_DISK, &peer)
	if !ok {
		return foundation.EXIT_FAILURE
	}
	if !machine.run_with_rendered_serial(command) {
		return foundation.EXIT_FAILURE
	}
	return 0
}

// run_test runs the parts of the machine test (test_parts.odin): one part,
// or every part, several at once.
run_test :: proc(args: []string) -> int {
	if problem := machine.test_arguments_problem(args); problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return foundation.EXIT_USAGE
	}
	optimization, part_args := machine.test_arguments_optimization(args)
	build.build_optimization_mode = optimization
	// The times of the test are measures: the report never changes the result.
	test_started := time.tick_now()
	build_duration: time.Duration
	inputs_folder, inputs_given := machine.test_arguments_give_inputs(args)
	if inputs_given {
		// A part derivation of the flake: the part on the test inputs of
		// the whole build, with no build of its own.
		part, _ := machine.test_part_find(part_args[0])
		if !machine.test_inputs_take(inputs_folder, part^) {
			return foundation.EXIT_FAILURE
		}
	} else {
		// One part boots only its own boot volumes: the build builds those.
		build_code := build.build_system(machine.boot_volumes_of_test(args))
		build_duration = time.tick_since(test_started)
		if build_code != 0 {
			return build_code
		}
		// A wait on a fact that no module renders fails here, not at the
		// end of a hang bound. A part derivation has no source of the tool:
		// the host checks of the flake run this check there.
		if !checks.scenario_waits_check() {
			return foundation.EXIT_FAILURE
		}
	}
	if !foundation.reset_folder(machine.SCREENSHOT_FOLDER) {
		return foundation.EXIT_FAILURE
	}
	parts := machine.test_parts[:]
	if len(part_args) >= 1 {
		for part, place in machine.test_parts {
			if part.name == part_args[0] {
				parts = machine.test_parts[place:][:1]
			}
		}
	}
	// One part runs alone: the bound and its line are for the whole test.
	at_once := 1
	if len(parts) > 1 {
		processors := foundation.test_processors_of(os.get_processor_core_count(), os.get_env("NIX_BUILD_CORES", context.temp_allocator))
		at_once = machine.test_parts_at_once_on_this_host(parts, processors)
	}
	machine.picture_names_forget(&machine.picture_names)
	// A step range: some steps of one machine of the part
	// (src/md/infrastructure/scenario_fault_loop.md, "A step range").
	step_range, range_given := machine.test_arguments_give_step_range(args)
	defer delete(step_range.setup)
	defer delete(step_range.machine)
	runs, passed := machine.test_parts_run(parts, at_once, step_range = step_range)
	defer {
		for &part_run in runs {
			machine.test_part_run_free(&part_run)
		}
		delete(runs)
	}
	machine.test_times_report(runs, build_duration, test_started)
	if !passed {
		return foundation.EXIT_FAILURE
	}
	// The join of the check of the flake adds up the counts of the parts.
	if inputs_given && !machine.checks_passed_write(sync.atomic_load(&foundation.test_passed_count)) {
		return foundation.EXIT_FAILURE
	}
	if range_given {
		// A range proves its steps after their setup, not the part.
		fmt.println("modustool: the step range passed; the part is proved by its whole run")
		return 0
	}
	fmt.println("modustool: all tests passed")
	return 0
}

// run_test_inputs is the command `test_inputs <folder>` (test_derivations.odin).
run_test_inputs :: proc(args: []string) -> int {
	if len(args) != 1 || args[0] == "" {
		fmt.eprintln("modustool: test_inputs <folder>")
		return foundation.EXIT_USAGE
	}
	return machine.test_inputs_write(args[0]) ? 0 : foundation.EXIT_FAILURE
}

// run_test_join is the command `test_join` (test_derivations.odin).
run_test_join :: proc(args: []string) -> int {
	return machine.test_join(args) ? 0 : foundation.EXIT_FAILURE
}

// run_failed_parts is the command `failed_parts` (failed_parts.odin): the
// list after a `nix flake check --keep-going` by hand. It evaluates the
// work tree as it is now: a tree that changed after the check names other
// derivations, and the list then says that none of them was built.
run_failed_parts :: proc(args: []string) -> int {
	if len(args) != 0 {
		fmt.eprintln("modustool: failed_parts takes no argument")
		return foundation.EXIT_USAGE
	}
	evaluation, evaluated := machine.flake_check_evaluate(FLAKE_CHECK_ATTRIBUTE)
	if !evaluated {
		return foundation.EXIT_FAILURE
	}
	return machine.failed_parts_report(evaluation) ? 0 : foundation.EXIT_FAILURE
}

// run_fact_waits is the command `fact_waits` (scenario_waits_check.odin):
// the module files of the main volume are the catalog of the check.
run_fact_waits :: proc(args: []string) -> int {
	if len(args) != 0 {
		fmt.eprintln("modustool: fact_waits takes no argument")
		return foundation.EXIT_USAGE
	}
	if code := build.build_system(build.boot_volumes_of_command("fact_waits")); code != 0 {
		return code
	}
	return checks.scenario_waits_check() ? 0 : foundation.EXIT_FAILURE
}

// run_part_cache is the command `part_cache` (test_derivations.odin).
run_part_cache :: proc(args: []string) -> int {
	if len(args) != 0 {
		fmt.eprintln("modustool: part_cache takes no argument")
		return foundation.EXIT_USAGE
	}
	return machine.part_cache_check(FLAKE_CHECK_ATTRIBUTE) ? 0 : foundation.EXIT_FAILURE
}

// The check of the flake that joins the host checks and one derivation for
// each test part (src/md/infrastructure/full_check.md, "The derivations of
// the check"). The flake defines its checks for x86_64-linux only.
FLAKE_CHECK_ATTRIBUTE :: ".#checks.x86_64-linux.boot-test"
// The link to the output of that check: it keeps the output in the store
// while the link exists.
FLAKE_CHECK_LINK :: foundation.BUILD_FOLDER + "/flake_check"
// The folders of the output of the check (flake.nix, bootTest): the logs
// and the records of build/, and the pictures of the test.
FLAKE_CHECK_LOGS :: FLAKE_CHECK_LINK + "/logs"
FLAKE_CHECK_PICTURES :: FLAKE_CHECK_LINK + "/screenshots"
// The count of the checks that passed in `modustool check`: the measure
// record of `screenshots` adds it to the checks of its own measure runs.
CHECKS_PASSED_FILE :: machine.CHECKS_PASSED_FILE

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
		count, compressed_all := resources.pictures_compress([]string{foundation.DOCUMENT_SCREENSHOT_FOLDER, foundation.RESOURCE_FOLDER})
		fmt.printfln("modustool: %d PNG files, %d compressed: %d bytes before, %d bytes after", count.picture_count, count.compressed_count, count.bytes_before, count.bytes_after)
		return compressed_all ? 0 : foundation.EXIT_FAILURE
	}
	if len(args) != 0 {
		fmt.eprintln("modustool: screenshots takes no argument, or `compress`")
		return foundation.EXIT_USAGE
	}
	// The facts of the tree before the pass changes it: the pass writes the
	// pictures and the record into the repository. A log of the check is
	// copied after this time, so the record reads it as a log of this run.
	run_facts := checks.measure_run_facts_read()
	// How many test parts Nix takes from the store, and how many run: a
	// measure. The evaluation builds the test inputs of the tree first.
	fmt.println("modustool: the evaluation of the check of the flake builds its test inputs first: a whole build when the tree changed")
	// One evaluation: the build builds its derivation path, and the list of
	// the failed parts reads its derivations. A second evaluation would read
	// the work tree again, which can change while the check runs.
	evaluation, evaluated := machine.flake_check_evaluate(FLAKE_CHECK_ATTRIBUTE)
	if !evaluated {
		return foundation.EXIT_FAILURE
	}
	in_store, to_run := machine.test_parts_in_store_count(evaluation)
	fmt.printfln("modustool: measure: the test parts of the check of the flake: %d taken from the store, %d run", in_store, to_run)
	// Each machine has its processors and its memory, and a part runs its
	// machines one after the other: Nix runs at most as many part
	// derivations at once as the pool of `modustool test` would run parts,
	// by the processors and by the available memory of the host.
	processors := foundation.test_processors_of(os.get_processor_core_count(), "")
	most_jobs := machine.test_parts_at_once_on_this_host(machine.test_parts[:], processors)
	// The check of the flake runs the host checks, each test part and the
	// second build in the sandbox; it fails when one of them fails. Nix
	// goes on past a failed part, so one run lists every failed part.
	if !foundation.run({"nix", "build", foundation.join(evaluation.check_derivation, "^out"), "--out-link", FLAKE_CHECK_LINK, "--print-build-logs", "--keep-going", "--max-jobs", fmt.tprintf("%d", most_jobs)}) {
		_ = machine.failed_parts_report(evaluation)
		return foundation.EXIT_FAILURE
	}
	if !flake_check_outputs_take() {
		return foundation.EXIT_FAILURE
	}
	// The pictures are a fact of the machines, which all passed: they go
	// to the documents now.
	if !screenshots_copy() {
		return foundation.EXIT_FAILURE
	}
	// The rates of the record come from measure runs on the host, with no
	// other machine: the test measures none (measure_runs.odin).
	if code := build.build_system(build.boot_volumes_of_command("screenshots")); code != 0 {
		return code
	}
	if !machine.measure_runs_of_the_record() {
		return foundation.EXIT_FAILURE
	}
	if !checks.measure_record_write(run_facts) {
		return foundation.EXIT_FAILURE
	}
	return 0
}

// flake_check_outputs_take copies the outputs of the check of the flake
// into build/: its pictures into SCREENSHOT_FOLDER, and its logs and
// records beside the logs of the host. The files of the store are read-only:
// each copy is a new file. It adds the checks that passed in the check to
// the count of this process.
flake_check_outputs_take :: proc() -> bool {
	foundation.reset_folder(machine.SCREENSHOT_FOLDER) or_return
	pictures := foundation.files_with_suffix(FLAKE_CHECK_PICTURES, ".png") or_return
	logs := foundation.files_with_suffix(FLAKE_CHECK_LOGS, ".txt") or_return
	if len(pictures) == 0 || len(logs) == 0 {
		fmt.eprintfln("modustool: the output of the check of the flake has %d pictures and %d logs: it is not the output of a whole test", len(pictures), len(logs))
		return false
	}
	for list, place in ([2][]string{pictures, logs}) {
		folder := place == 0 ? machine.SCREENSHOT_FOLDER : foundation.BUILD_FOLDER
		for source in list {
			target := strings.concatenate({folder, source[strings.last_index_byte(source, '/'):]}, context.temp_allocator)
			foundation.file_copy_as_new(target, source) or_return
		}
	}
	text, read_error := os.read_entire_file(CHECKS_PASSED_FILE, context.temp_allocator)
	count, number_ok := strconv.parse_int(strings.trim_space(string(text)))
	if read_error != nil || !number_ok || count <= 0 {
		fmt.eprintfln("modustool: the check of the flake gave no count of its checks in %s", CHECKS_PASSED_FILE)
		return false
	}
	sync.atomic_add(&foundation.test_passed_count, count)
	fmt.printfln("modustool: took %d pictures and %d logs of the check of the flake (%d checks passed there)", len(pictures), len(logs), count)
	return true
}

// screenshots_copy copies the pictures of the test to the documents and to
// a new folder of the development log.
screenshots_copy :: proc() -> bool {
	pictures, ok := foundation.files_with_suffix(machine.SCREENSHOT_FOLDER, ".png")
	// The name of the folder is the time of the run, in UTC.
	year, month, day := time.date(time.now())
	hour, minute, second := time.clock(time.now())
	development_log := foundation.development_log_folder()
	log_folder := fmt.tprintf("%s/%04d-%02d-%02d_%02d%02d%02d", development_log, year, int(month), day, hour, minute, second)
	if !ok || !foundation.make_folder(foundation.DOCUMENT_SCREENSHOT_FOLDER) || !foundation.make_folder(development_log) || !foundation.make_folder(log_folder) {
		return false
	}
	for picture in pictures {
		for folder in ([]string{foundation.DOCUMENT_SCREENSHOT_FOLDER, log_folder}) {
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

// run_measure runs the measures of the process `locks` on a machine where
// only the desktop runs: the numbers have no load of the other processes of
// the test. The process checks its counts; the tool does not check a speed.
// The same machine then runs processor_frame, whose lines the tool reads
// for their form only (processor_frame_measure.odin).
// The machine is a measure run: its boot image holds the resource
// `measure_run`, so each process measures its rates over a duration
// (measure_runs.odin). `measure <process>`: one process of
// `measure_processes`, alone, and its lines.
// `measure scheduler N`: N machines that run only the process scheduler
// with the desktop; the numbers are in build/test_output_scheduler_<n>.txt.
run_measure :: proc(args: []string) -> int {
	args := args
	if len(args) >= 1 && args[0] == "without_checks" {
		build.test_build_checks = false
		args = args[1:]
	}
	// `measure shortage` boots the volume of the shortage of frames; each
	// other form boots the volume of a measure run.
	shortage := len(args) >= 1 && args[0] == "shortage"
	if code := build.build_system(build.boot_volumes_of_command(shortage ? build.MEASURE_SHORTAGE_COMMAND : build.MEASURE_COMMAND)); code != 0 {
		return code
	}
	part := machine.test_part_run_make(build.MEASURE_COMMAND)
	defer machine.test_part_run_free(&part)
	if !foundation.make_folder(machine.SCREENSHOT_FOLDER) || !machine.test_part_run_start(&part) {
		return foundation.EXIT_FAILURE
	}
	if len(args) == 1 && args[0] == "windows" {
		return machine.measure_windows(&part) ? 0 : foundation.EXIT_FAILURE
	}
	if len(args) >= 1 && args[0] == "address_space" {
		return machine.machine_test(&part, machine.scenario_measure_address_space[:], {volume = build.BOOT_VOLUME_MEASURE, output = checks.TEST_OUTPUT_MEASURE, exit_status = build.MACHINE_STOP_OK}) ? 0 : foundation.EXIT_FAILURE
	}
	// `measure <process>`: one process that measures itself, alone.
	if len(args) == 1 {
		if process, found := machine.measure_process_find(args[0]); found {
			return machine.measure_process_run(&part, process) ? 0 : foundation.EXIT_FAILURE
		}
	}
	if shortage {
		return machine.shortage_tests_run(&part) ? 0 : foundation.EXIT_FAILURE
	}
	if len(args) >= 1 && args[0] == "scheduler" {
		count := 1
		if len(args) == 2 {
			count = 0
			for character in args[1] {
				if character < '0' || character > '9' {
					fmt.eprintln("modustool: measure scheduler <count>: the count is a number")
					return foundation.EXIT_FAILURE
				}
				count = count * 10 + int(character - '0')
			}
		}
		for run in 1 ..= count {
			// Not in the temporary allocator: the scenario frees it after each step.
			output := fmt.aprintf("%s/test_output_scheduler_%d.txt", foundation.BUILD_FOLDER, run)
			defer delete(output)
			if !machine.machine_test(&part, machine.scenario_measure_scheduler[:], {volume = build.BOOT_VOLUME_MEASURE, output = output, exit_status = build.MACHINE_STOP_OK}) {
				return foundation.EXIT_FAILURE
			}
		}
		return 0
	}
	if len(args) != 0 {
		fmt.eprintln("modustool: measure [without_checks] [scheduler <count> | windows | address_space | shortage | time_page | crowd | disk | flow | limits]")
		return foundation.EXIT_USAGE
	}
	if !machine.machine_test(&part, machine.scenario_measure[:], {volume = build.BOOT_VOLUME_MEASURE, output = checks.TEST_OUTPUT_MEASURE, exit_status = build.MACHINE_STOP_OK}) || !checks.processor_frame_lines_check(checks.TEST_OUTPUT_MEASURE) || !checks.quality_lines_check(checks.TEST_OUTPUT_MEASURE) {
		return foundation.EXIT_FAILURE
	}
	return 0
}

run_check :: proc(args: []string) -> int {
	// The check of the flake runs each test part in a derivation of its own
	// (src/md/infrastructure/full_check.md, "The derivations of the check").
	without_machines := len(args) == 1 && args[0] == "without_machines"
	if len(args) != 0 && !without_machines {
		fmt.eprintln("modustool: check takes no argument, or `without_machines`")
		return foundation.EXIT_USAGE
	}
	// The full check proves the build: it keeps no output of an earlier build.
	build.build_whole = true
	build.build_optimization_mode = .Speed
	if !foundation.run({"odin", "check", foundation.TOOL_SOURCE_FOLDER, "-vet", foundation.SOURCE_LIBRARY_FLAG, foundation.INTERNAL_LIBRARY_FLAG, foundation.KERNEL_LIBRARY_FLAG, foundation.TOOL_LIBRARY_FLAG, foundation.CUSTOM_ATTRIBUTES_FLAG}) {
		return foundation.EXIT_FAILURE
	}
	// The kernel and the contract packages import no support package. The
	// compiler does not refuse such an import: the library is one.
	if !build.library_imports_check() {
		return foundation.EXIT_FAILURE
	}
	// The kernel of a browser machine is the source of the kernel of x86-64
	// with other arch files, and no build of the image compiles it: this
	// check keeps it compiling (src/md/features/browser_machine.md).
	if !foundation.run({"odin", "check", foundation.SOURCE_FOLDER_KERNEL, "-target:freestanding_wasm64p32", "-no-entry-point", "-default-to-nil-allocator", "-vet", foundation.SOURCE_LIBRARY_FLAG, foundation.INTERNAL_LIBRARY_FLAG, foundation.KERNEL_LIBRARY_FLAG, foundation.CUSTOM_ATTRIBUTES_FLAG}) {
		return foundation.EXIT_FAILURE
	}
	// The count of the kernel operations is the count that the properties
	// state, no source of the system calls an allocator, each binding of an
	// export that can fail gives the call outcome and forces its read, and
	// no family of integer constants is a
	// closed set of choices; only the loader and the root service name the
	// field image_checks of a load source.
	if !checks.operation_count_check() || !checks.allocator_check() || !checks.outcome_binding_check() || !checks.choice_constant_check() || !checks.processor_random_check() || !checks.image_checks_field_check() || !checks.display_text_check() || !checks.service_deadline_check() || !checks.joint_processes_check() {
		return foundation.EXIT_FAILURE
	}
	// The stage tracker of the host of the browser machine, in Node: the
	// stages that a page shows come from it.
	if !build.browser_machine_host_tests_run() {
		return foundation.EXIT_FAILURE
	}
	host_test_folders := checks.HOST_TEST_FOLDERS
	if !checks.host_tests_run(host_test_folders[:]) {
		return foundation.EXIT_FAILURE
	}
	// The fuzz targets: their corpus, then a fixed count of new executions
	// with the seed of the sources (src/md/infrastructure/fuzzing.md).
	if !fuzz.fuzz_check() {
		return foundation.EXIT_FAILURE
	}
	if !checks.cryptography_origin_check() {
		return foundation.EXIT_FAILURE
	}
	if !resources.logo_check() {
		return foundation.EXIT_FAILURE
	}
	if !site.readme_pictures_check() {
		return foundation.EXIT_FAILURE
	}
	if !checks.fixed_addresses_check() {
		return foundation.EXIT_FAILURE
	}
	if !checks.test_bound_check() {
		return foundation.EXIT_FAILURE
	}
	if !checks.text_cut_check() {
		return foundation.EXIT_FAILURE
	}
	if !checks.cut_line_mark_check() {
		return foundation.EXIT_FAILURE
	}
	if !checks.comment_rule_check() {
		return foundation.EXIT_FAILURE
	}
	if !build.glossary_check() {
		return foundation.EXIT_FAILURE
	}
	if !checks.intent_index_check() {
		return foundation.EXIT_FAILURE
	}
	if !checks.source_paths_check() {
		return foundation.EXIT_FAILURE
	}
	if !checks.changelog_check() {
		return foundation.EXIT_FAILURE
	}
	if !checks.news_check() {
		return foundation.EXIT_FAILURE
	}
	if !checks.roadmap_check() {
		return foundation.EXIT_FAILURE
	}
	if !site.byte_layouts_check() {
		return foundation.EXIT_FAILURE
	}
	if !checks.reuse_list_check() {
		return foundation.EXIT_FAILURE
	}
	if without_machines {
		// The second build compares its bytes with a first whole build:
		// the modules and the main volume, whose boot program it compares.
		if code := build.build_system([]string{build.BOOT_VOLUME}); code != 0 {
			return code
		}
		// The waits of the scenarios against the module files of this
		// build: the check of the flake runs no machine in this form.
		if !checks.scenario_waits_check() {
			return foundation.EXIT_FAILURE
		}
	} else if run_test(nil) != 0 {
		return foundation.EXIT_FAILURE
	}
	// The debug objects against the linked files: the linked files name the
	// compiler in the store, so only a build holds them, and no test part
	// of the flake reads them.
	if !machine.test_debug_objects() {
		return foundation.EXIT_FAILURE
	}
	if !build.outputs_same_after_second_build() {
		return foundation.EXIT_FAILURE
	}
	// `screenshots` reads the count from the output of the check of the
	// flake, for its measure record.
	if !machine.checks_passed_write(sync.atomic_load(&foundation.test_passed_count)) {
		return foundation.EXIT_FAILURE
	}
	return 0
}

// run_fuzz is the command `fuzz` (docs/TOOLS.md, "The fuzzing").
run_fuzz :: proc(args: []string) -> int {
	usage_text :: "modustool: fuzz list | <target> [<executions> [<host_processes> [<seed>]]] | all [<executions>] | show <target> <file> | minimize <target> <file> | regression <target> <file> | corpus <target> | operations <executions> [<seed>] | regression operations <finding folder> | replay operations <file>"
	if len(args) == 0 {
		fmt.eprintln(usage_text)
		return foundation.EXIT_USAGE
	}
	targets := fuzz.fuzz_targets()
	switch args[0] {
	case "operations":
		// The kernel operations on machines of the counted kernel
		// (operation_fuzzing.odin).
		code := machine.operation_fuzzing_run(args[1:])
		if code == foundation.EXIT_USAGE {
			fmt.eprintln(usage_text)
		}
		return code
	case "replay":
		// One operation sequence on a machine of the kernel that ships
		// (operation_sequences.odin).
		if len(args) != 3 || args[1] != "operations" {
			fmt.eprintln(usage_text)
			return foundation.EXIT_USAGE
		}
		return machine.operation_sequences_replay(args[2])
	case "list":
		for target in targets {
			regression := fuzz.fuzz_inputs_read(fuzz.fuzz_corpus_folder(target.name, fuzz.FUZZ_REGRESSION_PART), context.temp_allocator)
			reach := fuzz.fuzz_inputs_read(fuzz.fuzz_corpus_folder(target.name, fuzz.FUZZ_REACH_PART), context.temp_allocator)
			fmt.printfln("  %-26s %-9v %3d regression, %3d reach  %s", target.name, target.kind, len(regression), len(reach), target.about)
		}
		operation_regressions := fuzz.fuzz_inputs_read(machine.OPERATION_REGRESSION_FOLDER, context.temp_allocator)
		operation_reach := fuzz.fuzz_inputs_read(machine.OPERATION_REACH_FOLDER, context.temp_allocator)
		fmt.printfln("  %-26s %-9s %3d regression, %3d reach  %s", fuzz.OPERATION_CORPUS_NAME, "machine", len(operation_regressions), len(operation_reach), "The kernel operations on a machine: `fuzz operations` on the counted kernel, `fuzz regression operations` on the kernel that ships")
		return 0
	case "show", "minimize", "regression":
		if len(args) != 3 {
			fmt.eprintln(usage_text)
			return foundation.EXIT_USAGE
		}
		if args[0] == "regression" && args[1] == fuzz.OPERATION_CORPUS_NAME {
			// A minimized finding of the kernel operations, run on a machine
			// of the kernel that ships (operation_corpus.odin).
			return machine.operation_regression_add(args[2])
		}
		target, found := fuzz.fuzz_target_find(targets, args[1])
		if !found {
			fmt.eprintfln("modustool: no fuzz target %s; `modustool fuzz list` names them", args[1])
			return foundation.EXIT_USAGE
		}
		input, error := os.read_entire_file(args[2], context.allocator)
		if error != nil {
			fmt.eprintfln("modustool: cannot read %s: %v", args[2], error)
			return foundation.EXIT_FAILURE
		}
		// This binary: no instrumentation is needed to replay one input.
		binary := os.args[0]
		outcome, started := fuzz.fuzz_child_run(binary, .Replay, target, 0, 0, args[2])
		if !started {
			return foundation.EXIT_FAILURE
		}
		switch args[0] {
		case "show":
			if outcome.oracle == .None {
				fmt.printfln("modustool: fuzz %s: %s breaks no oracle", target.name, args[2])
			} else {
				fmt.printfln("modustool: fuzz %s: %s: %s", target.name, outcome.signature, outcome.text)
			}
			fuzz.fuzz_print_literal(fuzz.fuzz_input_name(input), input)
		case "minimize":
			if outcome.oracle == .None {
				fmt.printfln("modustool: fuzz %s: %s breaks no oracle: nothing to minimize", target.name, args[2])
				return 0
			}
			if _, kept := fuzz.fuzz_finding_keep(binary, target, outcome); !kept {
				return foundation.EXIT_FAILURE
			}
		case "regression":
			// A regression input enters the corpus after the fix of its
			// fault: it must break no oracle now.
			if outcome.oracle != .None {
				fmt.eprintfln("modustool: fuzz %s: %s still breaks an oracle (%s): fix the fault first", target.name, args[2], outcome.signature)
				return foundation.EXIT_FAILURE
			}
			path, written := fuzz.fuzz_input_write(fuzz.fuzz_corpus_folder(target.name, fuzz.FUZZ_REGRESSION_PART), input)
			if !written {
				return foundation.EXIT_FAILURE
			}
			fmt.printfln("modustool: fuzz %s: the regression input %s", target.name, path)
		}
		return 0
	case "corpus":
		if len(args) != 2 {
			fmt.eprintln(usage_text)
			return foundation.EXIT_USAGE
		}
		target, found := fuzz.fuzz_target_find(targets, args[1])
		if !found {
			fmt.eprintfln("modustool: no fuzz target %s; `modustool fuzz list` names them", args[1])
			return foundation.EXIT_USAGE
		}
		if !fuzz.fuzz_instrumented_build(target.packages) {
			return foundation.EXIT_FAILURE
		}
		outcome, started := fuzz.fuzz_child_run(fuzz.FUZZ_INSTRUMENTED_BINARY, .Corpus, target, 0, 0)
		if !started || outcome.state != .Done {
			if started && outcome.oracle != .None {
				_, _ = fuzz.fuzz_finding_keep(fuzz.FUZZ_INSTRUMENTED_BINARY, target, outcome)
			}
			return foundation.EXIT_FAILURE
		}
		return 0
	}
	// A run: one target, or all of them in turn.
	// A run always has a count: a forgotten argument must not start a run
	// with no end, so the default is the count of the check, and 0 is
	// refused. A long run names its count.
	executions := u64(fuzz.FUZZ_CHECK_EXECUTIONS)
	host_processes := 1
	seed := fuzz.fuzz_sources_seed() ~ u64(time.time_to_unix_nano(time.now()))
	if len(args) >= 2 {
		value, ok := strconv.parse_u64(args[1])
		if !ok || value == 0 {
			fmt.eprintln("modustool: the count of executions is a number of 1 or more; a long run names its count, as 100000000")
			fmt.eprintln(usage_text)
			return foundation.EXIT_USAGE
		}
		executions = value
	}
	if len(args) >= 3 {
		value, ok := strconv.parse_int(args[2])
		if !ok || value < 1 {
			fmt.eprintln(usage_text)
			return foundation.EXIT_USAGE
		}
		host_processes = value
	}
	if len(args) >= 4 {
		value, ok := strconv.parse_u64(args[3])
		if !ok {
			fmt.eprintln(usage_text)
			return foundation.EXIT_USAGE
		}
		seed = value
	}
	chosen := make([dynamic]^fuzz.Fuzz_Target, context.temp_allocator)
	if args[0] == "all" {
		for &target in targets {
			append(&chosen, &target)
		}
	} else {
		target, found := fuzz.fuzz_target_find(targets, args[0])
		if !found {
			fmt.eprintfln("modustool: no fuzz target %s; `modustool fuzz list` names them", args[0])
			return foundation.EXIT_USAGE
		}
		append(&chosen, target)
	}
	packages := make([dynamic]string, context.temp_allocator)
	for target in chosen {
		for item in target.packages {
			if !slice.contains(packages[:], item) {
				append(&packages, item)
			}
		}
	}
	if !fuzz.fuzz_instrumented_build(packages[:]) {
		return foundation.EXIT_FAILURE
	}
	for target in chosen {
		fmt.printfln("modustool: fuzz %s: the seed %d, %d processes", target.name, seed, host_processes)
		children := make([]fuzz.Fuzz_Running_Child, host_processes)
		defer delete(children)
		for &child, number in children {
			started: bool
			child, started = fuzz.fuzz_child_start(fuzz.FUZZ_INSTRUMENTED_BINARY, .Run, target, seed + u64(number), executions, number)
			if !started {
				return foundation.EXIT_FAILURE
			}
		}
		fuzz.fuzz_children_watch(children)
		for &child in children {
			outcome := fuzz.fuzz_child_outcome(&child)
			if outcome.oracle != .None {
				_, _ = fuzz.fuzz_finding_keep(fuzz.FUZZ_INSTRUMENTED_BINARY, target, outcome)
				return foundation.EXIT_FAILURE
			}
		}
	}
	return 0
}
