package machine

import "core:fmt"
import "core:os"
import "core:strings"
import "modus:contract/blake3"
import "modustool:build"
import "modustool:foundation"

// A guest build (src/md/features/guest_build_image.md): one machine. Its
// data disk holds the private store of the service recipes with the kernel
// of Nixpkgs, the initial archive of a build, one input file and the recipe
// object, each by its hash, which the tool writes from the variables of the
// flake. The console builds the recipe with recipes.build_stored; the
// service runs the guest on its build thread, the init of the archive
// writes the output disk and gives the exit status 0, and the realisation
// names the tree hash that the tool computed on the host before the start.
//
// Each wait has the hang bound only: the boot of Linux and the build make
// many exits, and the time bound of the spec ends a guest that hangs.
//
// On a host that gives the test machine no SVM, as in the part guest, the
// machine checks only that the service says that no guest runs.

TEST_OUTPUT_GUEST_BUILD :: foundation.BUILD_FOLDER + "/test_output_guest_build.txt"
TEST_DISK_GUEST_BUILD :: foundation.BUILD_FOLDER + "/test_disk_guest_build.img"
// The blocks of the store recipes: the row of the start grant sets of
// recipes gives the same.
RECIPES_STORE_BLOCKS :: 16384

@(private = "file")
hexadecimal :: proc(hash: blake3.Hash) -> string {
	builder := strings.builder_make(context.allocator)
	for value in hash {
		fmt.sbprintf(&builder, "%02x", value)
	}
	return strings.to_string(builder)
}

// guest_build_owned formats a step string on the heap and tracks it so
// scenario_run's per-step free_all(context.temp_allocator) never frees
// step text still needed by later steps.
@(private = "file")
guest_build_owned :: proc(owned: ^[dynamic]string, format: string, args: ..any) -> string {
	text := fmt.aprintf(format, ..args)
	append(owned, text)
	return text
}

guest_build_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	kernel, archive := build.linux_build_image_read() or_return
	test := build.guest_build_test_make(kernel, archive) or_return
	image := build.data_disk_encode({name = "recipes", limit = RECIPES_STORE_BLOCKS, objects = test.objects[:]}, build.DATA_DISK_SIZE) or_return
	defer delete(image)
	if err := os.write_entire_file(TEST_DISK_GUEST_BUILD, image); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", TEST_DISK_GUEST_BUILD, err)
		return false
	}
	recipe := hexadecimal(test.recipe_hash)
	defer delete(recipe)
	expected := hexadecimal(test.expected_output)
	defer delete(expected)
	fmt.printfln("modustool: %s: the store recipes holds the kernel, %d bytes, the archive of a build, %d bytes, an input and the recipe %s, whose output must be %s", TEST_DISK_GUEST_BUILD, len(kernel), len(archive), recipe, expected)
	gives, reason := host_gives_guest_support()
	owned: [dynamic]string
	defer {
		for text in owned {
			delete(text)
		}
		delete(owned)
	}
	steps := make([dynamic]Step)
	defer delete(steps)
	append(&steps, Step{kind = .Wait, text = guest_build_owned(&owned, "storage: ok, generation 2: 1 stores, %d objects", len(test.objects)), any_order = true})
	append(&steps, Step{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true})
	append(&steps, Step{kind = .Front, text = "console"})
	append(&steps, Step{kind = .Type, text = guest_build_owned(&owned, "recipes.build_stored(\"%s\", 2)", recipe)})
	append(&steps, Step{kind = .Wait, text = guest_build_owned(&owned, "recipes: the guest build of the recipe %s started", recipe), fails_on = "recipes: the guest build was not started"})
	if !gives {
		fmt.printfln("modustool: the part guest_build runs NO guest on this host: %s; the machine checks only that the service says that no guest runs", reason)
		append(&steps, Step{kind = .Wait, text = "recipes: Guest_Run gave Unsupported"})
	} else {
		fmt.printfln("modustool: the part guest_build runs a guest: %s", reason)
		append(&steps, Step{kind = .Fact, process = "recipes", fact = "recipes_service.Guest_Build_Ended", condition = "exit_code = 0"})
		append(&steps, Step{kind = .Wait, text = guest_build_owned(&owned, "recipes: the recipe %s is realised with the output %s", recipe, expected), fails_on = "recipes: the guest build was refused before its run"})
	}
	append(&steps, Step{kind = .Front, text = "console"})
	append(&steps, Step{kind = .Type, text = "shutdown()"})
	append(&steps, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
	return machine_test(part, steps[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_GUEST_BUILD, exit_status = build.MACHINE_STOP_OK, data_disk = TEST_DISK_GUEST_BUILD})
}

// A binary of the tool runs the test part guest_build only when it holds
// this file (test_parts.odin, test_part_scenario_register).
@(init)
guest_build_test_part_register :: proc "contextless" () {
	test_part_scenario_register("guest_build", guest_build_tests_run)
}
