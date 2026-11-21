package log_reader

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:system"

// The measures of the log facts (src/md/features/log_facts.md, "The
// measures that decide it"), in a measure run only: the write of one line
// as text and as a fact, the operation Log of each form, and the render of
// a fact by the one render that the console and the window of the log
// call. Each is printed and none is asserted: a time is a measure, and a
// test checks a condition.

// The calls of one series of writes. The budget of this process holds
// op.LOG_RECORDS_OF_A_PROCESS log records of each second, and a line that
// it refuses returns early: each series starts in a second of its own, and
// writes less than that amount with the other lines of this process.
MEASURE_CALLS :: 200
#assert(2 * MEASURE_CALLS < op.LOG_RECORDS_OF_A_PROCESS)

// The renders of the measure of a reader: the records of a whole log.
MEASURE_RENDERS :: op.LOG_RECORD_CAPACITY

// The rows that the window of the log shows at once: the measure gives
// their render at the median, for a frame of 8.3 ms.
MEASURE_WINDOW_ROWS :: 30

// The values of the measured lines. The block of each call is its index,
// so no two calls write the same values.
MEASURED_CHECK :: 0x231A
MEASURED_EXPECTED :: 0x2B1A
MEASURED_CALLER :: "console"
MEASURED_SERVICE :: "storage"
MEASURED_PRINCIPAL :: 1

// The line of a bad block of the design, as a fact of this module.
@(log_fact = "log_reader: the block {block} has a wrong check {check}, expected {expected}")
Measured_Bad_Block :: struct {
	block:    u64,
	check:    value_kinds.Hexadecimal_32,
	expected: value_kinds.Hexadecimal_32,
}

// The line of a connection of the root service, as a fact of this module.
// The names are last: the serial line stops at the last byte that is not
// zero.
@(log_fact = "log_reader: connected {caller} to the service {service}, for principal {principal}")
Measured_Connected :: struct {
	principal: u64,
	caller:    value_kinds.Module_Name_Field,
	service:   value_kinds.Module_Name_Field,
}

// The measure of the write of one line: the least and the median of each
// series, in nanoseconds, as numbers: the sentence says the unit once.
@(log_fact = "log_reader: measure: the write of one line, in ns, the least and the median of {calls} calls: a bad block as text {bad_block_text_least} and {bad_block_text_median}, as a fact {bad_block_fact_least} and {bad_block_fact_median}; a connection as text {connected_text_least} and {connected_text_median}, as a fact {connected_fact_least} and {connected_fact_median}")
Write_Measured :: struct {
	calls:                 u64,
	bad_block_text_least:  u64,
	bad_block_text_median: u64,
	bad_block_fact_least:  u64,
	bad_block_fact_median: u64,
	connected_text_least:  u64,
	connected_text_median: u64,
	connected_fact_least:  u64,
	connected_fact_median: u64,
}

// The measure of the operation Log: the least and the median of each
// series, in nanoseconds.
@(log_fact = "log_reader: measure: the operation Log, in ns from the call to the return, the least and the median of {calls} calls: the text of a bad block {text_least} and {text_median}, its fact {fact_least} and {fact_median}, a call that the kernel refuses at the border of the form {refused_least} and {refused_median}")
Log_Operation_Measured :: struct {
	calls:          u64,
	text_least:     u64,
	text_median:    u64,
	fact_least:     u64,
	fact_median:    u64,
	refused_least:  u64,
	refused_median: u64,
}

// The measure of the render of a log fact, in nanoseconds, and the rows of
// the window of the log at the median.
@(log_fact = "log_reader: measure: the render of a log fact by module.fact_sentence_write, in ns, the least and the median of {renders} renders of two fact types of this module: {render_least} and {render_median}; {window_rows} rows of the window of the log at the median: {window_rows_time} ns")
Render_Measured :: struct {
	renders:          u64,
	render_least:     u64,
	render_median:    u64,
	window_rows:      u64,
	window_rows_time: u64,
}

// What one series writes or renders.
Measured_Call :: enum {
	Bad_Block_Text, // system.log of the line of a bad block: the support library formats it.
	Bad_Block_Fact, // system.log_fact of the same line.
	Connected_Text,
	Connected_Fact,
	Log_Text, // The operation Log of the text of a bad block, formatted before the series.
	Log_Fact, // The operation Log of the fact of a bad block, built before the series.
	Log_Refused, // The operation Log with a form word that names no member: the kernel entry, the border of the form and the error record.
}

// The time of each call of a series, in nanoseconds, then of each render.
// Not on the stack, which is small.
measure_times: [MEASURE_RENDERS]u64
// The text and the fact that the series of Log write, made before them.
measure_text: [op.LOG_TEXT_CAPACITY]u8
measure_text_count: int
measure_fact: op.Log_Fact
// The sentence and the value runs of one render.
measure_sentence: [module.FACT_SENTENCE_BYTES_MOST]u8
measure_runs: [op.LOG_CALL_RUN_LIMIT]value_kinds.Value_Run_In_Call

// bad_block_of gives the fact of a bad block of one call.
bad_block_of :: proc "contextless" (block: u64) -> Measured_Bad_Block {
	return Measured_Bad_Block{block = block, check = MEASURED_CHECK, expected = MEASURED_EXPECTED}
}

// measured_call makes one call of a series.
measured_call :: proc "contextless" (call: Measured_Call, log: u64, index: u64) {
	switch call {
	case .Bad_Block_Text:
		// The support library writes a hexadecimal number in 16 digits.
		system.log(.Info, "log_reader: the block ", index, " has a wrong check 0x", system.Hex(MEASURED_CHECK), ", expected 0x", system.Hex(MEASURED_EXPECTED))
	case .Bad_Block_Fact:
		system.log_fact(.Info, Measured_Bad_Block{block = index, check = MEASURED_CHECK, expected = MEASURED_EXPECTED})
	case .Connected_Text:
		system.log(.Info, "log_reader: connected ", MEASURED_CALLER, " to the service ", MEASURED_SERVICE, ", for principal ", index)
	case .Connected_Fact:
		system.log_fact(.Info, Measured_Connected{principal = index, caller = value_kinds.module_name_field(MEASURED_CALLER), service = value_kinds.module_name_field(MEASURED_SERVICE)})
	case .Log_Text:
		_, _ = system.call(.Log, log, u64(uintptr(&measure_text[0])), u64(measure_text_count), u64(op.Log_Level.Info), 0)
	case .Log_Fact:
		_, _ = system.call(.Log, log, u64(uintptr(&measure_fact)), u64(op.LOG_FACT_HEAD_BYTES + size_of(Measured_Bad_Block)), u64(op.Log_Level.Info), 0, u64(op.Log_Record_Form.Fact))
	case .Log_Refused:
		_, _ = system.call(.Log, log, u64(uintptr(&measure_fact)), u64(op.LOG_FACT_HEAD_BYTES + size_of(Measured_Bad_Block)), u64(op.Log_Level.Info), 0, u64(max(op.Log_Record_Form)) + 1)
	}
}

// least_and_median sorts the first `count` times and gives the least and
// the median.
least_and_median :: proc "contextless" (count: int) -> (least: u64, median: u64) {
	times := measure_times[:count]
	for index in 1 ..< len(times) {
		value := times[index]
		place := index
		for place > 0 && times[place - 1] > value {
			times[place] = times[place - 1]
			place -= 1
		}
		times[place] = value
	}
	return times[0], times[count / 2]
}

// measured_series times MEASURE_CALLS calls of one kind, from the start of
// a second, and gives the least and the median in nanoseconds.
measured_series :: proc "contextless" (call: Measured_Call, log: u64) -> (least: u64, median: u64) {
	next_second()
	for index in 0 ..< MEASURE_CALLS {
		started := system.nanoseconds()
		measured_call(call, log, u64(index))
		measure_times[index] = system.nanoseconds() - started
	}
	return least_and_median(MEASURE_CALLS)
}

// log_measures writes the lines of the measures, in a measure run. It gives
// the reason of a render that the one render refuses, or "".
log_measures :: proc "contextless" (ctx: ^system.Context) -> string {
	log := u64(ctx.handles[op.CONTEXT_LOG])
	// The text and the fact of a bad block for the series of Log, made
	// before them, so the series time the operation only.
	text := system.format(measure_text[:], "log_reader: the block ", u64(12), " has a wrong check 0x", system.Hex(MEASURED_CHECK), ", expected 0x", system.Hex(MEASURED_EXPECTED))
	measure_text_count = len(text)
	measure_fact = {module_hash = system.own_hash, key = transmute(u64)typeid_of(Measured_Bad_Block)}
	bad_block := bad_block_of(12)
	copy(measure_fact.values[:], ([^]u8)(&bad_block)[:size_of(Measured_Bad_Block)])

	least: [Measured_Call]u64
	median: [Measured_Call]u64
	for call in Measured_Call {
		least[call], median[call] = measured_series(call, log)
	}
	system.log_fact(.Info, Write_Measured{calls = u64(MEASURE_CALLS), bad_block_text_least = least[.Bad_Block_Text], bad_block_text_median = median[.Bad_Block_Text], bad_block_fact_least = least[.Bad_Block_Fact], bad_block_fact_median = median[.Bad_Block_Fact], connected_text_least = least[.Connected_Text], connected_text_median = median[.Connected_Text], connected_fact_least = least[.Connected_Fact], connected_fact_median = median[.Connected_Fact]})
	system.log_fact(.Info, Log_Operation_Measured{calls = u64(MEASURE_CALLS), text_least = least[.Log_Text], text_median = median[.Log_Text], fact_least = least[.Log_Fact], fact_median = median[.Log_Fact], refused_least = least[.Log_Refused], refused_median = median[.Log_Refused]})

	// The render: the module file of this process from the boot image that
	// check mapped, checked once, as a reader checks each module that it
	// finds.
	file := system.image_find(mapped_image, PROCESS_NAME)
	if file == nil || module.validate(file) != .None {
		return "the module file of log_reader is not in the boot image, or its checks refuse it"
	}
	connected := Measured_Connected{principal = MEASURED_PRINCIPAL, caller = value_kinds.module_name_field(MEASURED_CALLER), service = value_kinds.module_name_field(MEASURED_SERVICE)}
	bad_block_key := transmute(u64)typeid_of(Measured_Bad_Block)
	connected_key := transmute(u64)typeid_of(Measured_Connected)
	for index in 0 ..< MEASURE_RENDERS {
		key := bad_block_key
		values := ([^]u8)(&bad_block)[:size_of(Measured_Bad_Block)]
		if index % 2 == 1 {
			key = connected_key
			values = ([^]u8)(&connected)[:size_of(Measured_Connected)]
		}
		started := system.nanoseconds()
		_, _, refusal := module.fact_sentence_write(file, key, values, measure_sentence[:], measure_runs[:])
		measure_times[index] = system.nanoseconds() - started
		if refusal != .None {
			return "the one render refused a fact of this module"
		}
	}
	render_least, render_median := least_and_median(MEASURE_RENDERS)
	system.log_fact(.Info, Render_Measured{renders = u64(MEASURE_RENDERS), render_least = render_least, render_median = render_median, window_rows = u64(MEASURE_WINDOW_ROWS), window_rows_time = u64(MEASURE_WINDOW_ROWS) * render_median})
	return ""
}
