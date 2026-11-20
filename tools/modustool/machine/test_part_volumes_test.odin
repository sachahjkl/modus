package machine

import "core:os"
import "core:strings"
import "core:testing"
import "modustool:foundation"
import "modustool:build"

// row_has_volume says if a row has a volume. BOOT_VOLUME_SELF_TEST is the
// pattern of the self test volumes: a row has it when it has one of them.
@(private = "file")
row_has_volume :: proc(row: build.Volumes_Of_Part, path: string) -> bool {
	pattern: string = build.BOOT_VOLUME_SELF_TEST
	self_test_start := pattern[:strings.index(pattern, "%d")]
	for volume in row.volumes {
		if volume == path || (path == build.BOOT_VOLUME_SELF_TEST && strings.has_prefix(volume, self_test_start)) {
			return true
		}
	}
	return false
}

// The rows of the volumes of each part and of each command, with their
// names and their procedures: the parts of the machine test, then the
// commands that start a machine outside it. Of the temporary memory.
@(private = "file")
rows_of_volumes :: proc() -> []build.Volumes_Of_Part {
	rows := make([dynamic]build.Volumes_Of_Part, context.temp_allocator)
	for part in test_parts {
		append(&rows, build.Volumes_Of_Part{part = part.name, procedures = part.procedures, volumes = test_part_volumes_of(part)})
	}
	append(&rows, ..build.command_volumes[:])
	return rows[:]
}

// Each part of the machine test names its boot volumes, and each volume of
// a row is a volume of the build.
@(test)
each_test_part_has_its_boot_volumes :: proc(t: ^testing.T) {
	volumes := build.boot_volumes()
	for part in test_parts {
		needed := boot_volumes_of_test([]string{part.name})
		testing.expectf(t, len(needed) > 0, "the part %s names its volumes: a part with no volume would build none", part.name)
	}
	for row in rows_of_volumes() {
		testing.expectf(t, len(row.volumes) > 0 && len(row.procedures) > 0, "the row %s has its volumes and its procedures", row.part)
		for path in row.volumes {
			found := false
			for volume in volumes {
				found = found || volume.path == path
			}
			testing.expectf(t, found, "the volume %s of the row %s is a volume of the build", path, row.part)
		}
	}
	// The part of the self tests builds one volume for each self test, and
	// no other part builds one.
	self_test_part, found := test_part_find("self_tests")
	testing.expect(t, found, "the self tests of the kernel are a part")
	if found {
		testing.expect_value(t, len(boot_volumes_of_test([]string{self_test_part.name})), len(build.self_tests))
	}
	for part in test_parts {
		testing.expectf(t, part.self_test_volumes == (part.name == "self_tests"), "only the part self_tests builds the self test volumes, not %s", part.name)
	}
	// The whole test builds every volume.
	testing.expect(t, boot_volumes_of_test(nil) == nil, "the whole test builds every volume")
	testing.expect(t, boot_volumes_of_test([]string{"a part with no row"}) == nil, "a part with no row builds every volume")
	testing.expect(t, build.boot_volumes_of_command("a command with no row") == nil, "a command with no row builds every volume")
	// `trusted_boot` boots the volume of the other system for the measure.
	found_other_system, found_main := false, false
	for path in boot_volumes_of_test([]string{"trusted_boot"}) {
		found_other_system = found_other_system || path == build.BOOT_VOLUME_OTHER_SYSTEM
		found_main = found_main || path == build.BOOT_VOLUME
	}
	testing.expect(t, found_other_system && found_main, "trusted_boot builds the main volume and the other system")
	// `principals` builds the main volume, the signed main volume with the
	// variable store of Secure Boot, and the other system.
	found_other_system, found_main = false, false
	found_secure_boot := false
	for path in boot_volumes_of_test([]string{"principals"}) {
		found_other_system = found_other_system || path == build.BOOT_VOLUME_OTHER_SYSTEM
		found_secure_boot = found_secure_boot || path == build.BOOT_VOLUME_SECURE_BOOT
		found_main = found_main || path == build.BOOT_VOLUME
	}
	testing.expect(t, found_other_system && found_secure_boot && found_main, "principals builds the main volume, the signed main volume and the other system")
	for command in ([]string{"run", build.MEASURE_COMMAND, build.MEASURE_SHORTAGE_COMMAND, "screenshots", "film"}) {
		testing.expectf(t, len(build.boot_volumes_of_command(command)) > 0, "the command %s names its volumes", command)
	}
	// Each form of `measure` boots the volume of a measure run, but
	// `measure shortage`.
	measure := build.boot_volumes_of_command(build.MEASURE_COMMAND)
	testing.expect(t, len(measure) == 1 && measure[0] == build.BOOT_VOLUME_MEASURE, "measure builds the volume of a measure run only")
	measure_shortage := build.boot_volumes_of_command(build.MEASURE_SHORTAGE_COMMAND)
	testing.expect(t, len(measure_shortage) == 1 && measure_shortage[0] == build.BOOT_VOLUME_SHORTAGE, "measure shortage builds the volume of the shortage only")
	// `fuzz operations` boots the counted kernel, and a regression input
	// keeps the answers of the kernel that ships: one volume each.
	fuzzing := build.boot_volumes_of_command(build.OPERATION_FUZZING_COMMAND)
	testing.expect(t, len(fuzzing) == 1 && fuzzing[0] == build.BOOT_VOLUME_OPERATION_FUZZING && build.boot_volume_counts_kernel_edges(fuzzing[0]), "fuzz operations builds the volume of the counted kernel only")
	regression := build.boot_volumes_of_command(build.OPERATION_REGRESSION_COMMAND)
	testing.expect(t, len(regression) == 1 && regression[0] == build.BOOT_VOLUME_OPERATION_SEQUENCES && !build.boot_volume_counts_kernel_edges(regression[0]), "fuzz regression operations builds the volume of the kernel that ships only")
	for part in test_parts {
		for path in test_part_volumes_of(part) {
			testing.expectf(t, !build.boot_volume_counts_kernel_edges(path), "the part %s boots the counted kernel", part.name)
		}
	}
}

// The constants of the tool that name a boot volume, by their names in the
// sources. BOOT_VOLUME_SELF_TEST is the pattern of the self test volumes:
// only the whole test boots them.
@(private = "file")
volume_constants := [?][2]string {
	{"BOOT_VOLUME", build.BOOT_VOLUME},
	{"BOOT_VOLUME_FAILS", build.BOOT_VOLUME_FAILS},
	{"BOOT_VOLUME_SHORTAGE", build.BOOT_VOLUME_SHORTAGE},
	{"BOOT_VOLUME_MISSING_CONSOLE", build.BOOT_VOLUME_MISSING_CONSOLE},
	{"BOOT_VOLUME_OPERATION_SEQUENCES", build.BOOT_VOLUME_OPERATION_SEQUENCES},
	{"BOOT_VOLUME_OPERATION_FUZZING", build.BOOT_VOLUME_OPERATION_FUZZING},
	{"BOOT_VOLUME_MEASURE", build.BOOT_VOLUME_MEASURE},
	{"BOOT_VOLUME_WITHOUT_RETURN_CHECK", build.BOOT_VOLUME_WITHOUT_RETURN_CHECK},
	{"BOOT_VOLUME_SELF_TEST", build.BOOT_VOLUME_SELF_TEST},
	{"BOOT_VOLUME_CHANGED_MODULE", build.BOOT_VOLUME_CHANGED_MODULE},
	{"BOOT_VOLUME_WRONG_SIGNATURE", build.BOOT_VOLUME_WRONG_SIGNATURE},
	{"BOOT_VOLUME_OTHER_SYSTEM", build.BOOT_VOLUME_OTHER_SYSTEM},
	{"BOOT_VOLUME_CHANGED_KERNEL", build.BOOT_VOLUME_CHANGED_KERNEL},
	{"BOOT_VOLUME_WITHOUT_DESCRIPTION", build.BOOT_VOLUME_WITHOUT_DESCRIPTION},
	{"BOOT_VOLUME_STATED_HASH", build.BOOT_VOLUME_STATED_HASH},
	{"BOOT_VOLUME_KERNEL_MEMORY_RAISED", build.BOOT_VOLUME_KERNEL_MEMORY_RAISED},
	{"BOOT_VOLUME_SECURE_BOOT", build.BOOT_VOLUME_SECURE_BOOT},
	{"BOOT_VOLUME_SECURE_BOOT_CHANGED", build.BOOT_VOLUME_SECURE_BOOT_CHANGED},
	{"BOOT_VOLUME_NEWER_SYSTEM", build.BOOT_VOLUME_NEWER_SYSTEM},
	{"BOOT_VOLUME_NEWER_KEY", build.BOOT_VOLUME_NEWER_KEY},
	{"BOOT_VOLUME_RELEASE", build.BOOT_VOLUME_RELEASE},
}

// The procedures that only the whole test runs: it builds every volume.
@(private = "file")
whole_test_procedures := [?]string{"run_test"}

// The procedures that name a volume and start no machine from it by that
// name: the table of the volumes, the volumes of a part, the build of the
// main volume for the checks of two builds, in the build and in `check
// without_machines`, the refusal of a volume that is
// not ready, the comparison of the machine test, and the release volume,
// which only the release command builds and no machine starts.
@(private = "file")
procedures_that_start_no_machine := [?]string{"boot_volumes", "test_part_volumes_of", "main_boot_volume_build", "machine_command", "machine_test", "release_boot_volume", "run_check"}

// One volume constant in the body of one procedure of the tool.
@(private = "file")
Named_Volume :: struct {
	procedure: string,
	constant:  string,
}

@(private = "file")
is_identifier_byte :: proc(character: u8) -> bool {
	switch character {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_':
		return true
	}
	return false
}

// volumes_named_in_source finds each volume constant in the body of each
// procedure of one source file, and each procedure that the file declares.
// A procedure starts at a line `name :: proc` at the start of a line and
// ends at a line that is `}`. The text after `//` is a comment.
@(private = "file")
volumes_named_in_source :: proc(source: string, named: ^[dynamic]Named_Volume, declared: ^[dynamic]string) {
	procedure := ""
	rest := source
	for whole_line in strings.split_lines_iterator(&rest) {
		if whole_line == "}" {
			procedure = ""
			continue
		}
		line := whole_line
		if comment := strings.index(line, "//"); comment >= 0 {
			line = line[:comment]
		}
		if declaration := strings.index(line, " :: proc"); declaration > 0 && is_identifier_byte(line[0]) {
			procedure = line[:declaration]
			append(declared, procedure)
			continue
		}
		if procedure == "" {
			continue
		}
		for at := 0; at < len(line); {
			found := strings.index(line[at:], "BOOT_VOLUME")
			if found < 0 {
				break
			}
			start := at + found
			end := start
			for end < len(line) && is_identifier_byte(line[end]) {
				end += 1
			}
			// A longer name that holds these letters is another constant.
			if start == 0 || !is_identifier_byte(line[start - 1]) {
				append(named, Named_Volume{procedure = procedure, constant = line[start:end]})
			}
			at = end
		}
	}
}

// The reader of the sources finds a volume in a procedure, and not in a
// comment, in a table outside a procedure, or in a longer name.
@(test)
volume_constants_are_found_in_the_procedures_of_a_source :: proc(t: ^testing.T) {
	source := "BOOT_VOLUME :: \"a\"\ntable := [?]string {\n\tBOOT_VOLUME,\n}\n\n// first_run starts BOOT_VOLUME_FAILS.\nfirst_run :: proc() -> bool {\n\t// BOOT_VOLUME_SHORTAGE in a comment\n\treturn machine_test(steps[:], BOOT_VOLUME, output) && machine_test(steps[:], BOOT_VOLUME_SECURE_BOOT, MAIN_BOOT_VOLUME_NAME)\n}\n\nsecond_run :: proc() {\n\tx := self_test_file(BOOT_VOLUME_SELF_TEST, 1) // BOOT_VOLUME\n}\n"
	named := make([dynamic]Named_Volume, context.temp_allocator)
	declared := make([dynamic]string, context.temp_allocator)
	volumes_named_in_source(source, &named, &declared)
	testing.expect_value(t, len(declared), 2)
	testing.expect_value(t, len(named), 3)
	if len(named) == 3 {
		testing.expect_value(t, named[0], Named_Volume{procedure = "first_run", constant = "BOOT_VOLUME"})
		testing.expect_value(t, named[1], Named_Volume{procedure = "first_run", constant = "BOOT_VOLUME_SECURE_BOOT"})
		testing.expect_value(t, named[2], Named_Volume{procedure = "second_run", constant = "BOOT_VOLUME_SELF_TEST"})
	}
}

// Every boot volume that a procedure of the tool names is in the row of
// each part of that procedure: a part never boots a volume that its build
// did not build. The test reads the sources of the tool, from the root of
// the repository.
@(test)
each_volume_that_a_scenario_names_is_in_the_table_of_its_part :: proc(t: ^testing.T) {
	// Each package of the tool is a folder under the folder of the tool.
	listed_paths := make([dynamic]string, context.temp_allocator)
	listed := foundation.source_files_of_a_folder(foundation.TOOL_SOURCE_FOLDER, &listed_paths)
	paths := listed_paths[:]
	testing.expect(t, listed, "the test runs from the root of the repository")
	named := make([dynamic]Named_Volume, context.temp_allocator)
	declared := make([dynamic]string, context.temp_allocator)
	for path in paths {
		if strings.has_suffix(path, "_test.odin") {
			continue
		}
		source, error := os.read_entire_file(path, context.temp_allocator)
		testing.expectf(t, error == nil, "%s can be read", path)
		volumes_named_in_source(string(source), &named, &declared)
	}
	testing.expect(t, len(named) > 40, "the sources of the tool name the volumes in their procedures")
	is_declared :: proc(declared: []string, procedure: string) -> bool {
		for name in declared {
			if name == procedure {
				return true
			}
		}
		return false
	}
	// Each procedure of a table is a procedure of the tool: a name with a
	// mistake would check nothing.
	rows_of_parts_and_commands := rows_of_volumes()
	for row in rows_of_parts_and_commands {
		for procedure in row.procedures {
			testing.expectf(t, is_declared(declared[:], procedure), "the procedure %s of the row %s is a procedure of the tool", procedure, row.part)
		}
	}
	for procedure in whole_test_procedures {
		testing.expectf(t, is_declared(declared[:], procedure), "the procedure %s of the whole test is a procedure of the tool", procedure)
	}
	for procedure in procedures_that_start_no_machine {
		testing.expectf(t, is_declared(declared[:], procedure), "the procedure %s is a procedure of the tool", procedure)
	}
	for item in named {
		path := ""
		for constant in volume_constants {
			if constant[0] == item.constant {
				path = constant[1]
			}
		}
		testing.expectf(t, path != "", "%s, in %s, is a volume constant that this test knows", item.constant, item.procedure)
		outside_the_parts := false
		for procedure in whole_test_procedures {
			outside_the_parts = outside_the_parts || procedure == item.procedure
		}
		for procedure in procedures_that_start_no_machine {
			outside_the_parts = outside_the_parts || procedure == item.procedure
		}
		if outside_the_parts || path == "" {
			continue
		}
		rows := 0
		for row in rows_of_parts_and_commands {
			in_row := false
			for procedure in row.procedures {
				in_row = in_row || procedure == item.procedure
			}
			if !in_row {
				continue
			}
			rows += 1
			testing.expectf(t, row_has_volume(row, path), "the procedure %s of the part %s names %s, which is not in the volumes of the part: the part would boot a volume that its build did not build", item.procedure, row.part, item.constant)
		}
		testing.expectf(t, rows > 0, "the procedure %s names %s and is in no row of test_parts or command_volumes", item.procedure, item.constant)
	}
}
