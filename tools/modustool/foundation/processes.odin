// The host processes of the tool: the run of one program, the pool that
// runs several at once, the status of a command, the print of a passed
// check and the bound of a hang
// (src/md/infrastructure/repository_layout.md, "The tool in packages").
package foundation

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:time"

// run starts a host process with the terminal of this tool and waits for its end.
run :: proc(command: []string) -> bool {
	host_process, err := os.process_start({command = command, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if err != nil {
		fmt.eprintfln("modustool: cannot start %s: %v", command[0], err)
		return false
	}
	state, wait_err := os.process_wait(host_process)
	if wait_err != nil || !state.success {
		fmt.eprintfln("modustool: %s failed (code %d)", command[0], state.exit_code)
		return false
	}
	return true
}

EXIT_FAILURE :: 1

EXIT_USAGE :: 2

// A command of the tool: its name is the first argument, and about is the
// line of `modustool help`. The table of the commands is in the command
// package; the site reads it as an argument, because no package of the
// tool imports the command package.
Command :: struct {
	name, about: string,
	run:         proc(args: []string) -> int,
}

// The count of the checks that passed in this process: the measure record
// states it. Each check that passes prints its line through
// test_passed_print. A peer thread can print one, so the count is atomic.
test_passed_count: int

test_passed_print :: proc(format: string, args: ..any) {
	sync.atomic_add(&test_passed_count, 1)
	fmt.printfln("modustool: test passed: %s", fmt.tprintf(format, ..args))
}

// What one process of a build gave.
Build_Host_Process_Outcome :: struct {
	started:  bool,
	success:  bool,
	output:   []u8, // Its standard output, then its standard error.
	duration: time.Duration, // From its start to its end: a measure.
}

// The processes of one step of a build, which the worker threads share:
// the modules of one level, or the boot volumes that must be built.
Build_Host_Process_Pool :: struct {
	commands: [][]string, // One command for each process.
	next:     int, // The next place in commands to take (atomic).
	failed:   bool, // A process failed: no new process starts (atomic).
	outcomes: []Build_Host_Process_Outcome, // By place in commands.
}

// build_host_processes_run runs each command in its own process, at most
// `processes` at once, and keeps the output of each one. After a failure no
// new process starts; the processes that run end. The outcomes have the
// order of the commands; the caller frees the output of each one.
build_host_processes_run :: proc(commands: [][]string, host_processes: int, allocator := context.allocator) -> []Build_Host_Process_Outcome {
	pool := Build_Host_Process_Pool {
		commands = commands,
		outcomes = make([]Build_Host_Process_Outcome, len(commands), allocator),
	}
	workers := make([]^thread.Thread, max(0, min(host_processes, len(commands))), context.temp_allocator)
	for &worker in workers {
		worker = thread.create_and_start_with_data(&pool, build_host_process_worker)
	}
	thread.join_multiple(..workers)
	for worker in workers {
		thread.destroy(worker)
	}
	return pool.outcomes
}

// build_host_process_worker takes the commands of a pool one at a time and runs
// each one.
build_host_process_worker :: proc(data: rawptr) {
	pool := (^Build_Host_Process_Pool)(data)
	for {
		place := sync.atomic_add(&pool.next, 1)
		if place >= len(pool.commands) || sync.atomic_load(&pool.failed) {
			return
		}
		command := pool.commands[place]
		started := time.tick_now()
		state, standard_output, standard_error, error := os.process_exec({command = command}, context.allocator)
		output := make([]u8, len(standard_output) + len(standard_error))
		copy(output, standard_output)
		copy(output[len(standard_output):], standard_error)
		if error != nil {
			delete(output)
			output = transmute([]u8)fmt.aprintfln("modustool: cannot start %s: %v", command[0], error)
		}
		delete(standard_output)
		delete(standard_error)
		success := error == nil && state.exited && state.success
		pool.outcomes[place] = {
			started  = true,
			success  = success,
			output   = output,
			duration = time.tick_since(started),
		}
		if !success {
			sync.atomic_store(&pool.failed, true)
		}
	}
}

// test_processors_of gives the processors that the test counts on: the
// processors of the host, or fewer when the sandbox of Nix gives the build
// fewer (NIX_BUILD_CORES, a number; 0, empty or not a number: no bound).
test_processors_of :: proc(host_processors: int, nix_build_cores: string) -> int {
	cores, is_number := strconv.parse_int(nix_build_cores, 10)
	if !is_number || cores <= 0 {
		return host_processors
	}
	return min(host_processors, cores)
}

// The one role of a time in a test of the tool: it ends a test that hangs.
// A test checks a condition (a line, a value, a state), never a speed, so
// this bound is generous and the same for each wait of the tool that has no
// reason of its own: a loaded host runs the machine many times slower, and
// that says nothing about the system. It is larger than the bound of a hang
// in the checks of a process (TEST_HANG_BOUND_MILLISECONDS in
// src/library/support/system, 60 s), so that the process writes its own report first.
HANG_BOUND :: 120 * time.Second

// The calls and the names of an allocator. A call is the name, then "(",
// with no letter, digit, "_" or "." before the name: `caller_grant_make(`
// and `ring.make(` are procedures of the system, not the built-in `make`.
ALLOCATOR_CALLS :: [?]string{"make", "new", "new_clone", "delete", "free", "free_all"}
