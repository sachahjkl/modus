package checks

import "core:strings"
import "core:testing"

// The writer and the reader: the record reads back field by field, and a
// second write gives the same bytes.
@(test)
measure_record_round_trip :: proc(t: ^testing.T) {
	record := measure_record_example()
	text := measure_record_format(record)
	testing.expect(t, strings.has_prefix(text, MEASURE_RECORD_FIRST_LINE + "\ntime 2026-11-12 02:09 UTC\nrelease 0.91.0\n"))
	testing.expect(t, strings.has_suffix(text, "boot kernel: boot: kernel: root service: 2096 us\nend\n"))
	read, problem := measure_record_parse(text)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, read.time, record.time)
	testing.expect_value(t, read.release, record.release)
	testing.expect_value(t, read.commit, record.commit)
	testing.expect_value(t, read.tree, Measure_Tree_State.Changed)
	testing.expect_value(t, read.host, record.host)
	testing.expect_value(t, read.checks_passed, 1234)
	testing.expect_value(t, len(read.numbers), 2)
	testing.expect_value(t, len(read.boot_lines), 2)
	if len(read.numbers) == 2 {
		testing.expect_value(t, read.numbers[0], record.numbers[0])
		testing.expect_value(t, read.numbers[1], record.numbers[1])
	}
	testing.expect_value(t, measure_record_format(read), text)

	// An unknown commit reads back as unknown.
	no_commit := record
	no_commit.commit = ""
	read_no_commit, no_commit_problem := measure_record_parse(measure_record_format(no_commit))
	testing.expect_value(t, no_commit_problem, "")
	testing.expect_value(t, read_no_commit.commit, "")

	// A file that is not whole, of another form, or with a key out of place
	// is refused.
	cut := text[:strings.index(text, "boot ")]
	_, cut_problem := measure_record_parse(cut)
	testing.expect(t, strings.contains(cut_problem, "not whole"))
	_, form_problem := measure_record_parse("measure record 2\ntime x\nrelease y\nend\n")
	testing.expect(t, strings.contains(form_problem, "first line"))
	_, key_problem := measure_record_parse("measure record 1\ntime x\nrelease y\nspeed 3\nend\n")
	testing.expect(t, strings.contains(key_problem, "speed"))
	_, orphan_problem := measure_record_parse("measure record 1\ntime x\nrelease y\nline 3\nend\n")
	testing.expect(t, strings.contains(orphan_problem, "before the first line"))
	_, both_problem := measure_record_parse("measure record 1\ntime x\nrelease y\nnumber n\nlog a\nline 1\nmatching 1\ntext t\nabsent no\nend\n")
	testing.expect(t, strings.contains(both_problem, "not both"))
	_, count_problem := measure_record_parse("measure record 1\ntime x\nrelease y\nnumber n\nlog a\nline zero\nmatching 1\ntext t\nend\n")
	testing.expect(t, strings.contains(count_problem, "count"))
}

// A path of the host in a log line becomes relative to the repository; the
// home folder, the user name and the host name do not stay in a line.
@(test)
measure_record_cuts_the_private_texts :: proc(t: ^testing.T) {
	names := Measure_Private_Names {
		repository_folder = "/home/someone/Projects/kernel",
		home_folder       = "/home/someone",
		user_name         = "someone",
		host_name         = "workstation",
	}
	line := "[tool] tool: read /home/someone/Projects/kernel/build/test_output.txt, /home/someone/.cache/x and /home/someone/Projects/kernel on workstation for someone"
	testing.expect_value(t, measure_text_without_private(line, names), "[tool] tool: read build/test_output.txt, ~/.cache/x and . on <host> for <user>")
	testing.expect_value(t, measure_text_without_private("net: 64 bytes in 12 us", names), "net: 64 bytes in 12 us")
	// A short name matches parts of words: it is not replaced.
	short := Measure_Private_Names{user_name = "al"}
	testing.expect_value(t, measure_text_without_private("all values", short), "all values")

	// The writer cuts the line that it takes from a log.
	measure := Site_Measure{sentence = "One read", files = {TEST_OUTPUT, ""}, pattern = "disk: read", choice = .First}
	number := Measure_Record_Number{sentence = measure.sentence}
	log := "[a] a: start\n[disk] disk: read /home/someone/Projects/kernel/build/scratch_disk.img: 12 us\n"
	testing.expect(t, measure_record_number_from_log(&number, measure, TEST_OUTPUT, log, names))
	testing.expect_value(t, number.line, "[disk] disk: read build/scratch_disk.img: 12 us")
	testing.expect_value(t, number.line_number, 2)
	testing.expect_value(t, number.matching_lines, 1)
	testing.expect_value(t, number.log, TEST_OUTPUT)
	testing.expect(t, !measure_record_number_from_log(&number, Site_Measure{pattern = "absent"}, TEST_OUTPUT, log, names))
	boot := measure_boot_lines("kernel: boot: firmware: 1 us\n[x] x: y\nkernel: boot: kernel: /home/someone/a: 2 us\n", names)
	testing.expect_value(t, len(boot), 2)
	if len(boot) == 2 {
		testing.expect_value(t, boot[1], "kernel: boot: kernel: ~/a: 2 us")
	}

	// The host line names the processor and the accelerator only.
	information := "processor\t: 0\nmodel name\t: AMD Ryzen 7 5800X 8-Core Processor\nprocessor\t: 1\nmodel name\t: AMD Ryzen 7 5800X 8-Core Processor\n"
	testing.expect_value(t, measure_host_text(information, true), "AMD Ryzen 7 5800X 8-Core Processor, 2 logical processors; QEMU with KVM")
	testing.expect_value(t, measure_host_text("", false), "a processor whose model the tool cannot read, 0 logical processors; QEMU with TCG, with no KVM")
}
