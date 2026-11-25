// Minimal entrypoint for narrow Nix check derivations (system host unit tests
// and the reproducible second build). Importing only foundation, build, and
// checks keeps these derivations independent of site, cache_server, machine,
// fuzz, docs, and news.
package repro_runner

import "core:fmt"
import "core:os"
import "core:sync"
import "modustool:build"
import "modustool:checks"
import "modustool:foundation"

CHECKS_PASSED_FILE :: foundation.BUILD_FOLDER + "/checks_passed.txt"

@(private = "file")
write_checks_passed :: proc() -> bool {
	if !foundation.make_folder(foundation.BUILD_FOLDER) {
		return false
	}
	count := sync.atomic_load(&foundation.test_passed_count)
	if write_err := os.write_entire_file(CHECKS_PASSED_FILE, fmt.tprintf("%d\n", count)); write_err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", CHECKS_PASSED_FILE, write_err)
		return false
	}
	return true
}

reproducible_build_run :: proc() -> int {
	build.build_whole = true
	build.build_optimization_mode = .Speed
	build.build_cache_folder_set("")
	if code := build.build_system([]string{build.BOOT_VOLUME}); code != 0 {
		return code
	}
	if !checks.test_debug_objects() {
		return foundation.EXIT_FAILURE
	}
	if !build.outputs_same_after_second_build() {
		return foundation.EXIT_FAILURE
	}
	if !write_checks_passed() {
		return foundation.EXIT_FAILURE
	}
	return 0
}

main :: proc() {
	_ = os.unset_env("NIX_LDFLAGS")
	if len(os.args) < 2 {
		fmt.eprintln("modustool-repro-runner: host-tests-system | reproducible-build | module ... | volume ...")
		os.exit(foundation.EXIT_USAGE)
	}
	switch os.args[1] {
	case "module":
		os.exit(build.run_module(os.args[2:]))
	case "volume":
		os.exit(build.run_volume(os.args[2:]))
	case "host-tests-system":
		if len(os.args) != 2 {
			fmt.eprintln("modustool-repro-runner: host-tests-system takes no argument")
			os.exit(foundation.EXIT_USAGE)
		}
		if !checks.host_tests_run(checks.host_test_folders_for_scope(.System)) {
			os.exit(foundation.EXIT_FAILURE)
		}
		if !write_checks_passed() {
			os.exit(foundation.EXIT_FAILURE)
		}
		os.exit(0)
	case "reproducible-build":
		if len(os.args) != 2 {
			fmt.eprintln("modustool-repro-runner: reproducible-build takes no argument")
			os.exit(foundation.EXIT_USAGE)
		}
		os.exit(reproducible_build_run())
	}
	fmt.eprintfln("modustool-repro-runner: unknown command %s", os.args[1])
	os.exit(foundation.EXIT_USAGE)
}
