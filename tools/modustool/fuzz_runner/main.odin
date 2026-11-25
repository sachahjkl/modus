// Minimal entrypoint for instrumented fuzz children and sharded fuzz check
// derivations in flake.nix. Importing only foundation and fuzz (and
// transitively build/resources) keeps fuzz derivations independent of site,
// cache_server, machine, checks, docs, and news.
package fuzz_runner

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sync"
import "modustool:foundation"
import "modustool:fuzz"

CHECKS_PASSED_FILE :: foundation.BUILD_FOLDER + "/checks_passed.txt"

main :: proc() {
	_ = os.unset_env("NIX_LDFLAGS")
	if len(os.args) < 2 {
		fmt.eprintln("modustool-fuzz-runner: fuzz-child ... | check-fuzz <shard> <total>")
		os.exit(foundation.EXIT_USAGE)
	}
	switch os.args[1] {
	case "fuzz-child":
		os.exit(fuzz.run_fuzz_child(os.args[2:]))
	case "check-fuzz":
		if len(os.args) != 4 {
			fmt.eprintln("modustool-fuzz-runner: check-fuzz <shard> <total>")
			os.exit(foundation.EXIT_USAGE)
		}
		shard, shard_ok := strconv.parse_int(os.args[2], 10)
		total, total_ok := strconv.parse_int(os.args[3], 10)
		if !shard_ok || !total_ok || total < 1 || shard < 1 || shard > total {
			fmt.eprintln("modustool-fuzz-runner: check-fuzz <shard> <total>: shard must be in 1..total")
			os.exit(foundation.EXIT_USAGE)
		}
		if !fuzz.fuzz_check_shard(shard, total) {
			os.exit(foundation.EXIT_FAILURE)
		}
		if !foundation.make_folder(foundation.BUILD_FOLDER) {
			os.exit(foundation.EXIT_FAILURE)
		}
		count := sync.atomic_load(&foundation.test_passed_count)
		if write_err := os.write_entire_file(CHECKS_PASSED_FILE, fmt.tprintf("%d\n", count)); write_err != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", CHECKS_PASSED_FILE, write_err)
			os.exit(foundation.EXIT_FAILURE)
		}
		os.exit(0)
	}
	fmt.eprintfln("modustool-fuzz-runner: unknown command %s", os.args[1])
	os.exit(foundation.EXIT_USAGE)
}
