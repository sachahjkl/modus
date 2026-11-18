package machine

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "modustool:foundation"

// The ports of these tests are under 1024: the system never gives one of
// them to a bind of port 0, so no machine of a test that runs at the same
// time holds one.
@(private = "file")
TEST_PORT_FIRST :: 7
@(private = "file")
TEST_PORT_SECOND :: 9

// A port is never given twice while it is in the list; a port that is not
// in the list, and the port 0, change nothing when taken back. The test has
// its own list: the list of the process outlives each test, and the tests
// run on several threads.
@(test)
a_given_port_is_not_given_again :: proc(t: ^testing.T) {
	ports: Given_Loopback_Ports
	defer loopback_ports_free(&ports)
	testing.expect(t, loopback_port_give(&ports, TEST_PORT_FIRST), "a port that is in no list is given")
	testing.expect(t, !loopback_port_give(&ports, TEST_PORT_FIRST), "a port of the list is refused")
	testing.expect(t, loopback_port_is_given(&ports, TEST_PORT_FIRST))
	// A port not in the list and 0: the list stays as it is.
	testing.expect(t, !loopback_port_is_given(&ports, TEST_PORT_SECOND))
	loopback_port_take_back(&ports, TEST_PORT_SECOND)
	loopback_port_take_back(&ports, 0)
	testing.expect_value(t, loopback_ports_given_count(&ports), 1)
	testing.expect(t, loopback_port_is_given(&ports, TEST_PORT_FIRST), "taking back another port leaves the port")
	testing.expect(t, !loopback_port_give(&ports, TEST_PORT_FIRST), "taking back another port does not free the port")
	loopback_port_take_back(&ports, TEST_PORT_FIRST)
	testing.expect(t, !loopback_port_is_given(&ports, TEST_PORT_FIRST))
	testing.expect(t, loopback_port_give(&ports, TEST_PORT_FIRST), "a port taken back is given again")
	// The memory of a list is the heap of the process, never the memory of
	// the test that adds the first port, which the runner frees when that
	// test ends.
	testing.expect(t, ports.ports.allocator.procedure == runtime.heap_allocator().procedure, "the list holds memory of its first caller")
}

@(private = "file")
Port_Tries :: struct {
	ports: []int, // The ports that each try gives, then the last one again.
	tries: int,
	fails: bool, // Each try fails.
}

@(private = "file")
port_of_the_next_try :: proc(data: rawptr) -> (int, bool) {
	state := (^Port_Tries)(data)
	state.tries += 1
	if state.fails {
		return 0, false
	}
	return state.ports[min(state.tries, len(state.ports)) - 1], true
}

// The search refuses when each try gives a port of the list, after
// FREE_PORT_TRIES tries and no more; it refuses at once when a try fails;
// it gives the first port that is not in the list.
@(test)
the_search_of_a_port_has_a_limit :: proc(t: ^testing.T) {
	ports: Given_Loopback_Ports
	defer loopback_ports_free(&ports)
	testing.expect(t, loopback_port_give(&ports, TEST_PORT_FIRST))
	always_given := Port_Tries{ports = {TEST_PORT_FIRST}}
	port, found := loopback_port_search(&ports, port_of_the_next_try, &always_given)
	testing.expect(t, !found, "each try gives a port of the list: refused")
	testing.expect_value(t, port, 0)
	testing.expect_value(t, always_given.tries, FREE_PORT_TRIES)
	failing := Port_Tries{fails = true}
	_, found = loopback_port_search(&ports, port_of_the_next_try, &failing)
	testing.expect(t, !found, "a try that fails ends the search")
	testing.expect_value(t, failing.tries, 1)
	// The last try of the limit gives a free port: it is given.
	at_the_limit := make([]int, FREE_PORT_TRIES, context.temp_allocator)
	for &value in at_the_limit {
		value = TEST_PORT_FIRST
	}
	at_the_limit[FREE_PORT_TRIES - 1] = TEST_PORT_SECOND
	late := Port_Tries{ports = at_the_limit}
	port, found = loopback_port_search(&ports, port_of_the_next_try, &late)
	testing.expect(t, found, "the last try gives a free port")
	testing.expect_value(t, port, TEST_PORT_SECOND)
	testing.expect(t, loopback_port_is_given(&ports, TEST_PORT_SECOND), "the port given is in the list")
	// A real port of the system: never one of the list, and in it after.
	real_port, real_found := free_port(&ports)
	testing.expect(t, real_found)
	if real_found {
		testing.expect(t, real_port != TEST_PORT_FIRST && real_port != TEST_PORT_SECOND)
		testing.expect(t, loopback_port_is_given(&ports, real_port))
		loopback_port_take_back(&ports, real_port)
		testing.expect(t, !loopback_port_is_given(&ports, real_port))
	}
}

// The flags of the parts of the pool tests: each test has its own.
@(private = "file")
pool_failure_seen: bool
@(private = "file")
pool_last_part_ran: bool

@(private = "file")
part_that_passes :: proc(_: ^Test_Part_Run) -> bool {
	return true
}

@(private = "file")
part_that_fails :: proc(_: ^Test_Part_Run) -> bool {
	sync.atomic_store(&pool_failure_seen, true)
	return false
}

@(private = "file")
part_that_notes_its_run :: proc(_: ^Test_Part_Run) -> bool {
	sync.atomic_store(&pool_last_part_ran, true)
	return true
}

// A part that runs while another part fails: it ends only after the
// failure, so the pool must wait for it. The bound only ends a hang.
@(private = "file")
part_that_waits_for_the_failure :: proc(_: ^Test_Part_Run) -> bool {
	for start := time.tick_now(); !sync.atomic_load(&pool_failure_seen); {
		if time.tick_since(start) > foundation.HANG_BOUND {
			return false
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	return true
}

@(private = "file")
no_data_disk :: proc(_: ^Test_Part_Run) -> bool {
	return true
}

@(private = "file")
part_that_cannot_start :: proc(_: ^Test_Part_Run) -> bool {
	return false
}

// After a failure no part starts: the result is a failure, the part after
// the failure did not start and is not reported as failed. A part that
// cannot prepare its start fails, and runs none of its machines.
@(test)
the_pool_starts_no_part_after_a_failure :: proc(t: ^testing.T) {
	sync.atomic_store(&pool_last_part_ran, false)
	parts := []Test_Part{{name = "first", run = part_that_passes}, {name = "second", run = part_that_fails}, {name = "third", run = part_that_notes_its_run}}
	runs, passed := test_parts_run(parts, 1, no_data_disk)
	defer {
		for &part_run in runs {
			test_part_run_free(&part_run)
		}
		delete(runs)
	}
	testing.expect(t, !passed, "one part failed: the run fails")
	testing.expect(t, runs[0].started && runs[0].passed)
	testing.expect(t, runs[1].started && !runs[1].passed)
	testing.expect(t, !runs[2].started && !runs[2].passed, "the part after the failure did not start")
	testing.expect(t, !sync.atomic_load(&pool_last_part_ran), "the part after the failure ran none of its machines")
	testing.expect_value(t, test_part_run_outcome_note(runs[0]), "")
	testing.expect_value(t, test_part_run_outcome_note(runs[1]), " (failed)")
	testing.expect_value(t, test_part_run_outcome_note(runs[2]), " (not started)")
	// A start that fails is a failure of its part, before its procedure.
	sync.atomic_store(&pool_last_part_ran, false)
	refused_runs, refused_passed := test_parts_run([]Test_Part{{name = "refused", run = part_that_notes_its_run}}, 1, part_that_cannot_start)
	defer {
		for &part_run in refused_runs {
			test_part_run_free(&part_run)
		}
		delete(refused_runs)
	}
	testing.expect(t, !refused_passed)
	testing.expect(t, refused_runs[0].started && !refused_runs[0].passed)
	testing.expect(t, !sync.atomic_load(&pool_last_part_ran), "a part that cannot start runs nothing")
}

// A part that runs when another part fails ends, and the pool waits for
// it: its result is in the runs, and the run is a failure.
@(test)
the_pool_waits_for_the_parts_that_run :: proc(t: ^testing.T) {
	sync.atomic_store(&pool_failure_seen, false)
	parts := []Test_Part{{name = "waiting", run = part_that_waits_for_the_failure}, {name = "failing", run = part_that_fails}}
	runs, passed := test_parts_run(parts, 2, no_data_disk)
	defer {
		for &part_run in runs {
			test_part_run_free(&part_run)
		}
		delete(runs)
	}
	testing.expect(t, !passed)
	testing.expect(t, runs[0].started && runs[0].passed, "the part that ran during the failure ended, and passed")
	testing.expect(t, runs[1].started && !runs[1].passed)
	// All parts pass: the run passes.
	all_runs, all_passed := test_parts_run([]Test_Part{{name = "one", run = part_that_passes}, {name = "two", run = part_that_passes}, {name = "three", run = part_that_passes}}, 2, no_data_disk)
	defer {
		for &part_run in all_runs {
			test_part_run_free(&part_run)
		}
		delete(all_runs)
	}
	testing.expect(t, all_passed)
	for part_run in all_runs {
		testing.expect(t, part_run.started && part_run.passed)
	}
}

// A picture name that a part took is refused to another part, and given
// again to the same part; a forgotten name is free again. The test has its
// own table: the table of the process outlives each test.
@(test)
two_parts_never_save_one_picture :: proc(t: ^testing.T) {
	NAME :: "a_picture_of_the_test_of_the_picture_names"
	names: Picture_Names
	defer picture_names_free(&names)
	owner, claimed := picture_name_claim(&names, "first", NAME)
	testing.expect(t, claimed)
	testing.expect_value(t, owner, "first")
	owner, claimed = picture_name_claim(&names, "second", NAME)
	testing.expect(t, !claimed, "another part is refused the name")
	testing.expect_value(t, owner, "first")
	_, claimed = picture_name_claim(&names, "first", NAME)
	testing.expect(t, claimed, "the same part saves the name again")
	_, claimed = picture_name_claim(&names, "second", NAME + "_other")
	testing.expect(t, claimed, "another name is free")
	picture_names_forget(&names)
	owner, claimed = picture_name_claim(&names, "second", NAME)
	testing.expect(t, claimed, "a forgotten name is free again")
	testing.expect_value(t, owner, "second")
}

// paths_first_repeat gives the first path that two names hold, or "".
@(private = "file")
paths_first_repeat :: proc(paths: [][2]string) -> string {
	for path, place in paths {
		for other in paths[place + 1:] {
			if path[1] == other[1] {
				return fmt.tprintf("%s and %s are both %s", path[0], other[0], path[1])
			}
		}
	}
	return ""
}

// The largest number that a pattern of a machine file takes (%d): more
// than the machines of any part.
@(private = "file")
PATTERN_NUMBERS :: 40

// The log files and the data disks of the parts, from the constants of the
// sources of the tool (`TEST_OUTPUT... :: BUILD_FOLDER + "..."` and
// `TEST_..._DISK :: BUILD_FOLDER + "..."`), each pattern with each number,
// and the data disk of each part. The measures and the films run alone, as
// commands: their files are not files of a part.
@(private = "file")
part_paths_of_the_sources :: proc(t: ^testing.T) -> [][2]string {
	paths := make([dynamic][2]string, context.temp_allocator)
	// Each package of the tool is a folder under the folder of the tool.
	listed_files := make([dynamic]string, context.temp_allocator)
	listed := foundation.source_files_of_a_folder(foundation.TOOL_SOURCE_FOLDER, &listed_files)
	files := listed_files[:]
	testing.expect(t, listed, "the test runs from the root of the repository")
	for path in files {
		if strings.has_suffix(path, "_test.odin") {
			continue
		}
		bytes, error := os.read_entire_file(path, context.temp_allocator)
		testing.expect(t, error == nil)
		rest := string(bytes)
		for line in strings.split_lines_iterator(&rest) {
			// The package foundation holds BUILD_FOLDER, so a constant of
			// the main package names it with its package.
			MARK :: " :: BUILD_FOLDER + \""
			QUALIFIED_MARK :: " :: foundation.BUILD_FOLDER + \""
			at := strings.index(line, MARK)
			mark_length := len(MARK)
			if at < 0 {
				at = strings.index(line, QUALIFIED_MARK)
				mark_length = len(QUALIFIED_MARK)
			}
			if at <= 0 || !strings.has_prefix(line, "TEST_") {
				continue
			}
			name := line[:at]
			if !(strings.has_prefix(name, "TEST_OUTPUT") || strings.has_suffix(name, "_DISK")) || strings.contains(name, "MEASURE") || strings.contains(name, "FILM") {
				continue
			}
			value := line[at + mark_length:]
			value = value[:max(strings.index_byte(value, '"'), 0)]
			if strings.contains(value, "%d") {
				for number in 0 ..= PATTERN_NUMBERS {
					expanded, _ := strings.replace_all(value, "%d", fmt.tprintf("%d", number), context.temp_allocator)
					append(&paths, [2]string{fmt.tprintf("%s(%d)", name, number), expanded})
				}
			} else {
				append(&paths, [2]string{name, value})
			}
		}
	}
	for part in test_parts {
		disk := fmt.tprintf("/test_data_disk_%s.img", part.name)
		append(&paths, [2]string{fmt.tprintf("the data disk of the part %s", part.name), disk})
	}
	return paths[:]
}

// No two log files of the machines and no two data disks of the parts are
// one file: two parts that run at once never write one file. The check
// refuses a list with one path two times first.
@(test)
the_files_of_the_parts_are_distinct :: proc(t: ^testing.T) {
	testing.expect(t, paths_first_repeat([][2]string{{"A", "/a.txt"}, {"B", "/b.txt"}, {"C", "/a.txt"}}) != "", "a path that two names hold is refused")
	testing.expect(t, paths_first_repeat([][2]string{{"A", "/x_1.txt"}, {"B", "/x_1.txt"}}) != "", "a pattern and a name that give one path are refused")
	testing.expect_value(t, paths_first_repeat([][2]string{{"A", "/a.txt"}, {"B", "/b.txt"}}), "")
	paths := part_paths_of_the_sources(t)
	testing.expect(t, len(paths) > 60, "the sources of the tool name the log files and the disks of the parts")
	testing.expect_value(t, paths_first_repeat(paths), "")
	// The data disk of `run` is never the disk of a part.
	for path in paths {
		whole := strings.concatenate({foundation.BUILD_FOLDER, path[1]}, context.temp_allocator)
		testing.expectf(t, whole != DATA_DISK && whole != SCRATCH_DISK, "%s is a disk of a command", path[0])
	}
}
