package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:foundation"

// The measures of the log that the tool reads after the main machine
// (src/md/features/log_facts.md, "The measures that decide it"): the
// records up to two lines of the start, the module files of the root
// service and of the compositor, and the lines of the log by the bytes of
// their body, for a smaller record. Each is printed, and written to
// LOG_MEASURES_RECORD, whose lines the measure record keeps. None is
// asserted: a measure says what is, not what must be.

// The file of the lines of the measures of the log of the main machine.
LOG_MEASURES_RECORD :: foundation.BUILD_FOLDER + "/log_measures.txt"

// The lines of the start where the count of the records stops.
LOG_MEASURE_KERNEL_READY :: "kernel: ok"
LOG_MEASURE_MACHINE_USABLE :: "the machine is usable"

// The modules whose files the measures of the code bytes name: the first
// two writers of log facts.
LOG_MEASURE_MODULE_COUNT :: 2
@(rodata)
log_measure_modules := [LOG_MEASURE_MODULE_COUNT]string{"root", "compositor"}

// The head of a record today: each byte before its value runs, the name of
// the process included.
LOG_RECORD_HEAD_BYTES :: int(offset_of(op.Log_Record, runs))
// The head with no name of the process: a smaller record can leave it out.
LOG_RECORD_HEAD_WITHOUT_NAME_BYTES :: int(offset_of(op.Log_Record, name))
// The bytes of the value runs of a text record, before its text.
LOG_RECORD_RUN_BYTES :: int(offset_of(op.Log_Record, text) - offset_of(op.Log_Record, runs))
#assert(size_of(op.Log_Record) - LOG_RECORD_HEAD_BYTES - LOG_RECORD_RUN_BYTES == op.LOG_TEXT_CAPACITY)

// A size of a log record and the bytes of its head.
Log_Record_Shape :: struct {
	size: int,
	head: int,
}

LOG_RECORD_SHAPE_COUNT :: 3

// The record of today first, then the smaller records that measure 8
// weighs.
@(rodata)
log_record_shapes := [LOG_RECORD_SHAPE_COUNT]Log_Record_Shape{{size_of(op.Log_Record), LOG_RECORD_HEAD_BYTES}, {128, LOG_RECORD_HEAD_BYTES}, {128, LOG_RECORD_HEAD_WITHOUT_NAME_BYTES}}

// The bounds of the classes of the bytes of a body: at most 64, at most
// 128, at most 192, and more.
LOG_BODY_CLASS_COUNT :: 4
@(rodata)
log_body_class_bounds := [LOG_BODY_CLASS_COUNT - 1]int{64, 128, 192}

// The body of one line of a serial log: what its record holds after its
// head.
Log_Line_Body :: struct {
	is_fact: bool,
	bytes:   int, // A fact: the head of a fact and its values up to their last byte that is not zero. A text: its bytes. The runs of a text are not on the serial line, so they are not counted.
}

// log_line_body gives the body of one line of a serial log, with no end of
// line. ok is false for an empty line.
log_line_body :: proc(line: string) -> (body: Log_Line_Body, ok: bool) {
	if line == "" {
		return {}, false
	}
	text := line
	// The head of a process is "[name] ", and a name holds no "]".
	if line[0] == '[' {
		if close := strings.index_byte(line, ']'); close > 0 && close + 1 < len(line) && line[close + 1] == ' ' {
			text = line[close + 2:]
		}
	}
	if fact, is_fact := fact_line_parse(text); is_fact {
		return {is_fact = true, bytes = op.LOG_FACT_HEAD_BYTES + fact.value_count}, true
	}
	return {bytes = len(text)}, true
}

// log_line_records gives the records that the body of a line takes in a
// record of a shape: a fact takes one, and fits is false when its body
// passes the room after the head; a text takes one for each part of its
// room after the runs, at least one, and fits is false when a record of
// the shape has no room for text.
log_line_records :: proc(body: Log_Line_Body, shape: Log_Record_Shape) -> (records: int, fits: bool) {
	room := shape.size - shape.head
	if body.is_fact {
		return 1, body.bytes <= room
	}
	text_room := room - LOG_RECORD_RUN_BYTES
	if text_room <= 0 {
		return 0, false
	}
	return max(1, (body.bytes + text_room - 1) / text_room), true
}

// What the measures read from one serial log.
Log_Measures :: struct {
	records_to_kernel_ready:   int, // The records of today up to the line LOG_MEASURE_KERNEL_READY, that line included; -1: the log has no such line.
	records_to_machine_usable: int, // The same up to the first line that holds LOG_MEASURE_MACHINE_USABLE.
	lines:                     int,
	fact_lines:                int,
	body_classes:              [LOG_BODY_CLASS_COUNT]int, // The lines by the bytes of their body (log_body_class_bounds).
	shape_records:             [LOG_RECORD_SHAPE_COUNT]int, // The records that the lines take in each shape.
	shape_refused:             [LOG_RECORD_SHAPE_COUNT]int, // The lines that one record of the shape cannot hold.
}

// log_measures_read reads the measures of a serial log, as QEMU wrote it:
// one line for each record of a fact, and each text whole on one line.
log_measures_read :: proc(log: string) -> (measures: Log_Measures) {
	measures.records_to_kernel_ready, measures.records_to_machine_usable = -1, -1
	records := 0
	for raw_line in strings.split_lines(log, context.temp_allocator) {
		line := strings.trim_right(raw_line, "\r")
		body, has_body := log_line_body(line)
		if !has_body {
			continue
		}
		measures.lines += 1
		if body.is_fact {
			measures.fact_lines += 1
		}
		class := LOG_BODY_CLASS_COUNT - 1
		for bound, index in log_body_class_bounds {
			if body.bytes <= bound {
				class = index
				break
			}
		}
		measures.body_classes[class] += 1
		for shape, index in log_record_shapes {
			taken, fits := log_line_records(body, shape)
			measures.shape_records[index] += taken
			if !fits {
				measures.shape_refused[index] += 1
			}
		}
		today, _ := log_line_records(body, log_record_shapes[0])
		records += today
		if measures.records_to_kernel_ready < 0 && line == LOG_MEASURE_KERNEL_READY {
			measures.records_to_kernel_ready = records
		}
		if measures.records_to_machine_usable < 0 && strings.contains(line, LOG_MEASURE_MACHINE_USABLE) {
			measures.records_to_machine_usable = records
		}
	}
	return measures
}

// log_measures_lines gives the lines of the measures of a serial log and
// of the module files of the build. A module file that cannot be read, or
// that the checks of the module format refuse, gives its cause in place of
// its sizes.
log_measures_lines :: proc(log_path: string, measures: Log_Measures, module_files: [LOG_MEASURE_MODULE_COUNT][]u8) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, fmt.tprintf("modustool: measure: the records of the log of %s: %d up to \"%s\", %d up to \"%s\"", log_path, measures.records_to_kernel_ready, LOG_MEASURE_KERNEL_READY, measures.records_to_machine_usable, LOG_MEASURE_MACHINE_USABLE))
	modules := strings.builder_make(context.temp_allocator)
	strings.write_string(&modules, "modustool: measure: the module files:")
	for name, index in log_measure_modules {
		if index > 0 {
			strings.write_string(&modules, ";")
		}
		strings.write_string(&modules, " ")
		file := module_files[index]
		if file == nil || module.validate(file) != .None {
			fmt.sbprintf(&modules, "%s cannot be read", name)
			continue
		}
		fmt.sbprintf(&modules, "%s %d bytes, %d bytes of code", name, len(file), module_code_bytes(file))
	}
	append(&lines, strings.to_string(modules))
	append(&lines, fmt.tprintf("modustool: measure: the lines of the log of %s by the bytes of their body, with no runs of a text: %d lines, %d of them facts; %d of at most %d bytes, %d of at most %d, %d of at most %d, %d of more", log_path, measures.lines, measures.fact_lines, measures.body_classes[0], log_body_class_bounds[0], measures.body_classes[1], log_body_class_bounds[1], measures.body_classes[2], log_body_class_bounds[2], measures.body_classes[3]))
	for shape, index in log_record_shapes {
		kept := op.LOG_PAGES * 4096 / shape.size - 1
		append(&lines, fmt.tprintf("modustool: measure: a log record of %d bytes with a head of %d: the whole log keeps %d records; the lines of %s take %d records, and %d facts do not fit one record", shape.size, shape.head, kept, log_path, measures.shape_records[index], measures.shape_refused[index]))
	}
	return lines[:]
}

// module_code_bytes gives the bytes of the segments of a module file that
// hold instructions. The caller validated the file.
module_code_bytes :: proc(file: []u8) -> u64 {
	total: u64
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		if .Execute in segment.flags {
			total += segment.memory_size
		}
	}
	return total
}

// log_measures_write reads the serial log of the main machine and the
// module files of the build, prints the lines of the measures and writes
// them to LOG_MEASURES_RECORD. false: the log or the record cannot be read
// or written.
log_measures_write :: proc(log_path: string) -> bool {
	log, read_error := os.read_entire_file(log_path, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: the measures of the log: cannot read %s: %v", log_path, read_error)
		return false
	}
	module_files: [LOG_MEASURE_MODULE_COUNT][]u8
	for name, index in log_measure_modules {
		file, readable := foundation.read_file(foundation.module_path(name))
		if readable {
			module_files[index] = file
		}
	}
	lines := log_measures_lines(log_path, log_measures_read(string(log)), module_files)
	text := strings.builder_make(context.temp_allocator)
	for line in lines {
		fmt.println(line)
		strings.write_string(&text, line)
		strings.write_byte(&text, '\n')
	}
	if write_error := os.write_entire_file(LOG_MEASURES_RECORD, transmute([]u8)strings.to_string(text)); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", LOG_MEASURES_RECORD, write_error)
		return false
	}
	return true
}
