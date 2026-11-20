package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "core:fmt"
import "core:strings"
import "core:testing"

// The measures of a serial log count the records of each line in each
// shape of a record. The edges: the lines of the firmware and of the boot
// program, which are no log records, a head with no space after it (no
// record), an empty line (no line), a text of 0 bytes, of the text
// capacity and of one more, a text past the largest class of a body, a fact
// with no value byte and a fact of the whole capacity, which a record of
// 128 bytes cannot hold. The line of the start policy with the words of
// the root service, before it, is not the line of the root service; a
// second line of the root service is not counted again.
@(test)
log_measures_count_the_records_of_each_shape :: proc(t: ^testing.T) {
	hash: [module.HASH_SIZE]u8
	full: [op.LOG_FACT_VALUE_CAPACITY]u8
	for &value in full {
		value = 0xAB
	}
	text_of_capacity := strings.repeat("a", op.LOG_TEXT_CAPACITY, context.temp_allocator)
	text_past_capacity := strings.repeat("a", op.LOG_TEXT_CAPACITY + 1, context.temp_allocator)
	text_past_classes := strings.repeat("a", log_body_class_bounds[len(log_body_class_bounds) - 1] + 1, context.temp_allocator)
	log := strings.concatenate(
		{
			"BdsDxe: starting Boot0002\r\n",
			"boot program: started\r\n",
			"boot program: ok\r\n",
			"kernel: 4 processors\r\n",
			"kernel: ok\r\n",
			"\r\n",
			"[root]text with no space\r\n",
			"[root] \r\n",
			"[root] ", text_of_capacity, "\r\n",
			"[root] ", text_past_capacity, "\r\n",
			"[root] ", text_past_classes, "\r\n",
			"[root] ", fact_render_line(hash, FACT_RENDER_KEY, nil), "\r\n",
			"[root] ", fact_render_line(hash, FACT_RENDER_KEY, full[:]), "\r\n",
			"[start_policy] start_policy: each needed row runs: the machine is usable\r\n",
			"[root] root: the machine is usable, by the start policy\r\n",
			"[root] root: the machine is usable again\n",
		},
		context.temp_allocator,
	)
	measures := log_measures_read(log)
	testing.expect_value(t, measures.lines, 11)
	testing.expect_value(t, measures.fact_lines, 2)
	// The records of today: 1 for each line, 2 for the text past the
	// capacity and for the text past the classes. The boot program writes
	// before the log: its lines count no record.
	testing.expect_value(t, measures.records_to_kernel_ready, 2)
	testing.expect_value(t, measures.records_to_machine_usable, 12)
	testing.expect_value(t, measures.shape_records[0], 13)
	testing.expect_value(t, measures.shape_refused[0], 0)
	// 128 bytes with the head of today: 40 bytes of text in a record, and
	// the fact of 192 bytes does not fit.
	testing.expect_value(t, measures.shape_records[1], 1 + 1 + 1 + 5 + 5 + 5 + 1 + 1 + 2 + 2 + 1)
	testing.expect_value(t, measures.shape_refused[1], 1)
	// 128 bytes with no name in the head: 72 bytes of text in a record.
	testing.expect_value(t, measures.shape_records[2], 1 + 1 + 1 + 3 + 3 + 3 + 1 + 1 + 1 + 1 + 1)
	testing.expect_value(t, measures.shape_refused[2], 1)
	// At most 64 bytes: the two kernel lines, the empty text, the fact
	// with no value, the line of the start policy and the two lines of the
	// root service; at most 192: the two texts of the capacity and the
	// whole fact; more: one text.
	testing.expect_value(t, measures.body_classes, [LOG_BODY_CLASS_COUNT]int{7, 0, 3, 1})
	testing.expect_value(t, log_measures_missing_line("build/test_output.txt", measures), "")

	// A log with no line of the start, or with the words only in another
	// process or in the boot program, gives no count, and the write names
	// the missing line.
	none := log_measures_read("")
	testing.expect(t, none.lines == 0 && none.records_to_kernel_ready == -1 && none.records_to_machine_usable == -1)
	testing.expect(t, strings.contains(log_measures_missing_line("build/test_output.txt", none), "\"kernel: ok\""))
	others := log_measures_read("boot program: kernel: ok\r\n[root] kernel: ok\r\nkernel: ok, and more\r\n[start_policy] root: the machine is usable\r\n")
	testing.expect(t, others.lines == 3 && others.records_to_kernel_ready == -1 && others.records_to_machine_usable == -1)
	kernel_only := log_measures_read("kernel: ok\r\n[start_policy] start_policy: the machine is usable\r\n")
	testing.expect(t, kernel_only.records_to_kernel_ready == 1 && kernel_only.records_to_machine_usable == -1)
	testing.expect(t, strings.contains(log_measures_missing_line("build/test_output.txt", kernel_only), "\"root: the machine is usable\""))

	// The lines: a module file that cannot be read says so, and the shape
	// of today keeps the records of the whole log.
	lines := log_measures_lines("build/test_output.txt", measures, {})
	testing.expect_value(t, len(lines), 3 + LOG_RECORD_SHAPE_COUNT)
	if len(lines) == 3 + LOG_RECORD_SHAPE_COUNT {
		testing.expect_value(t, lines[0], "modustool: measure: the records of the log of build/test_output.txt: 2 up to \"kernel: ok\", 12 up to \"root: the machine is usable\"")
		testing.expect_value(t, lines[1], "modustool: measure: the module files: root cannot be read; compositor cannot be read")
		testing.expect(t, strings.has_prefix(lines[3], fmt.tprintf("modustool: measure: a log record of %d bytes with a head of %d: the whole log keeps %d records;", size_of(op.Log_Record), LOG_RECORD_HEAD_BYTES, op.LOG_RECORD_CAPACITY)))
	}
}
