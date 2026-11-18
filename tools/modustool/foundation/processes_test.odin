package foundation

import "core:strings"
import "core:testing"
import "core:time"

// The pool of processes that the host tests share with the build. Its
// outputs are memory of the worker threads, outside the memory that the
// test runner follows: the tests do not free them.

// The pool gives one outcome for each command, in the order of the
// commands; a command that cannot start is a failure.
@(test)
build_host_processes_keep_the_outcome_of_each_command :: proc(t: ^testing.T) {
	commands := make([][]string, 1, context.temp_allocator)
	command := make([]string, 1, context.temp_allocator)
	command[0] = "/a program that is not there"
	commands[0] = command
	outcomes := build_host_processes_run(commands, 4, context.temp_allocator)
	testing.expect_value(t, len(outcomes), 1)
	testing.expect(t, outcomes[0].started && !outcomes[0].success, "a command that cannot start is a failure")
	testing.expect(t, outcomes[0].duration >= time.Duration(0), "the time of a host process is a measure")
	// The output is memory of the worker thread, outside the memory that
	// the test runner follows: the test does not free it.
	none := build_host_processes_run(nil, 4, context.temp_allocator)
	testing.expect_value(t, len(none), 0)
}

// A command that cannot start, and a command that ends with a failure,
// are failures; after a failure the pool starts no new host process. With
// one host process at once the order is fixed: the second and the third
// commands never start.
@(test)
host_test_pool_stops_after_a_failure :: proc(t: ^testing.T) {
	missing := []string{"/a program that is not there"}
	outcomes := build_host_processes_run([][]string{missing, []string{"true"}, []string{"true"}}, 1, context.temp_allocator)
	testing.expect_value(t, len(outcomes), 3)
	testing.expect(t, outcomes[0].started && !outcomes[0].success, "a command that cannot start is a failure")
	testing.expect(t, len(outcomes[0].output) > 0, "a command that cannot start says why")
	testing.expect(t, !outcomes[1].started && !outcomes[2].started, "no host process starts after a failure")
	// A host process that runs and ends with a status that is not 0: its
	// output is kept, and the next command does not start.
	absent := "/a folder that is not there/of a host test"
	outcomes = build_host_processes_run([][]string{[]string{"ls", absent}, []string{"true"}}, 1, context.temp_allocator)
	testing.expect(t, outcomes[0].started && !outcomes[0].success, "a status that is not 0 is a failure")
	testing.expect(t, strings.contains(string(outcomes[0].output), absent), "the output of a failure is kept: it names the folder")
	testing.expect(t, !outcomes[1].started, "no host process starts after a failure")
}

// No count of processes starts no process: the caller then counts each
// command as not started, never as passed. host_tests_run asks for one
// at the least.
@(test)
host_test_pool_with_no_host_process_starts_none :: proc(t: ^testing.T) {
	for host_processes in ([]int{0, -1}) {
		outcomes := build_host_processes_run([][]string{[]string{"true"}}, host_processes, context.temp_allocator)
		testing.expect_value(t, len(outcomes), 1)
		testing.expectf(t, !outcomes[0].started && !outcomes[0].success, "%d host processes at once start no command", host_processes)
	}
}

// The outcomes have the order of the commands, not the order of their
// ends, and each keeps its own output. The successful case is the last.
@(test)
host_test_pool_keeps_the_order_of_the_commands :: proc(t: ^testing.T) {
	outcomes := build_host_processes_run([][]string{[]string{"echo", "first"}, []string{"echo", "second"}, []string{"echo", "third"}}, 3, context.temp_allocator)
	testing.expect_value(t, len(outcomes), 3)
	for text, place in ([]string{"first\n", "second\n", "third\n"}) {
		testing.expectf(t, outcomes[place].started && outcomes[place].success, "the command %d passed", place)
		testing.expect_value(t, string(outcomes[place].output), text)
	}
}

// The count of processors: NIX_BUILD_CORES bounds it when it is a number
// above 0; any other text leaves the count of the host.
@(test)
the_sandbox_bounds_the_processors :: proc(t: ^testing.T) {
	testing.expect_value(t, test_processors_of(16, ""), 16)
	testing.expect_value(t, test_processors_of(16, "0"), 16)
	testing.expect_value(t, test_processors_of(16, "-4"), 16)
	testing.expect_value(t, test_processors_of(16, "four"), 16)
	testing.expect_value(t, test_processors_of(16, "4x"), 16)
	testing.expect_value(t, test_processors_of(16, "1"), 1)
	testing.expect_value(t, test_processors_of(16, "8"), 8)
	testing.expect_value(t, test_processors_of(16, "64"), 16)
}
