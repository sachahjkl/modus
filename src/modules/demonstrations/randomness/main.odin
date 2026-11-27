// The random bytes of the system, where they come from, shown. The design:
// docs/RANDOMNESS.md.
//
// The root service gathers the seed of the system at its start, from the
// sources of the processor, mixes in the bytes of the entropy device when
// the machine has one, and gives this process the facts of that gathering
// (the values 0 to 7 of its context): which sources were there,
// how many values each one gave, how many it refused, and the strength
// that the seed can claim. Like each process, this one has its own
// generator, seeded by its starter (the values 9 to 12). The window shows
// both, a live draw of the stream, the counts of each byte value in 1 MiB,
// and the speed of the generator.
//
// **What it is for.** It shows where the random bytes of a process come
// from, and what the system claims of them: the strength of the seed is a
// fact that the root service measured, not a promise. A process that makes
// a key (`remote`, `quic_echo`, `unlock`) refuses a seed under the strength
// that it needs; this process shows that strength.
//
// **Start**: `start("randomness")` in the console, or the bar of the
// desktop. Its row of `start_grant_sets` has no grant: the root service writes the
// facts of the seed into its context because of its name, and these are
// facts, not the seed.
//
// **What a reader sees**: the sources of the seed (rdseed, rdrand, the
// jitter of the cycle counter, the entropy device) with their counts, the
// strength, a live draw of the stream every 500 ms, the mixes of the fresh
// bytes page, the 16 bars of 1 MiB counted by the high 4 bits of each
// byte, and the speed. The log has:
//
// - "randomness: the seed of the system: strength ...; the first bytes of
//   the stream of this process: ...";
// - "randomness: the entropy device: N bytes mixed after the gathering;
//   refused reads: N", or "randomness: the entropy device: absent";
// - "randomness: 1 MiB by the high 4 bits of each byte: from A to B in each
//   of 16 (the mean is 65536)";
// - "randomness: the generator: 4 MiB in T us, R MB/s";
// - "randomness: the fresh bytes of the root service are mixed into the
//   generator of this process, at the change C of its page", once, at the
//   first mix (src/md/features/fresh_bytes.md).
//
// **What it does not prove**: even bars are no test of quality; a weak
// generator gives them too. The quality of the seed rests on the sources of
// the processor (docs/RANDOMNESS.md, section 3).
package randomness

import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:random"
import "modus:system"

LINE :: interface.TABLE_LINE
WIDTH :: 896
HEIGHT :: 584 // One more line for the fresh bytes than the cards had: the bars keep their height.
// The tool counts the module, its load, its stacks and its window at the largest scale.
MODULE_BUDGET :: system.Stated_Budget{window_width = WIDTH, window_height = HEIGHT}
MEASURE_SIZE :: 4 << 20 // The bytes of the measure of the speed.
HISTOGRAM_SIZE :: 1 << 20 // The bytes whose values the window counts.

process_generator: random.Generator
report: random.Entropy_Report
first_bytes: [16]u8 // The first bytes of the stream of this process: the log has them, so a test compares two processes and two boots.
live_bytes: [32]u8 // A draw of each picture.
byte_counts: [16]u64 // The bytes of HISTOGRAM_SIZE by their high 4 bits.
megabytes_per_second_hundredths: u64 // The rate of the generator: the window and the log write it with two decimals.
measure_microseconds: u64
measured: bool

window_memory: interface.Window_Memory(512, 8192)

hex_text :: proc "contextless" (builder: ^interface.Text_Builder, bytes: []u8) -> string {
	digits := "0123456789abcdef"
	builder.count = 0
	for byte, index in bytes {
		if index > 0 && index % 4 == 0 {
			interface.text_put(builder, " ")
		}
		pair := [2]u8{digits[byte >> 4], digits[byte & 15]}
		interface.text_put(builder, string(pair[:]))
	}
	return interface.text_of(builder)
}

strength_color :: proc "contextless" (strength: random.Seed_Strength) -> graphics.Color {
	switch strength {
	case .Entropy:
		return graphics.colors.process
	case .Processor:
		return graphics.colors.text
	case .None, .Weak:
		return graphics.colors.failed
	}
	return graphics.colors.failed
}

source_line :: proc "contextless" (frame: ^interface.Frame, column: ^interface.Column, name: string, present: bool, good, refused: u32, wanted: u32) {
	builder: interface.Text_Builder
	if !present {
		interface.label_value_line(frame, interface.column_take(column, LINE), name, "absent: the processor does not have it", graphics.colors.dim, 168)
		return
	}
	interface.text_put(&builder, "present, ")
	interface.text_put_number(&builder, u64(good))
	interface.text_put(&builder, " good values of ")
	interface.text_put_number(&builder, u64(wanted))
	interface.text_put(&builder, ", ")
	interface.text_put_number(&builder, u64(refused))
	interface.text_put(&builder, " refused")
	interface.label_value_line(frame, interface.column_take(column, LINE), name, interface.text_of(&builder), good == wanted ? graphics.colors.text : graphics.colors.failed, 168)
}

// device_line shows the entropy device: absent, or the bytes that the root
// service mixed in before this process started, and the reads that added
// nothing.
device_line :: proc "contextless" (frame: ^interface.Frame, column: ^interface.Column) {
	if !report.device_present {
		interface.label_value_line(frame, interface.column_take(column, LINE), "entropy device", "absent: the machine does not have one", graphics.colors.dim, 168)
		return
	}
	builder: interface.Text_Builder
	interface.text_put(&builder, "present, ")
	interface.text_put_number(&builder, u64(report.device_bytes))
	interface.text_put(&builder, " bytes mixed after the gathering; refused reads: ")
	interface.text_put_number(&builder, u64(report.device_reads_refused))
	interface.label_value_line(frame, interface.column_take(column, LINE), "entropy device", interface.text_of(&builder), report.device_reads_refused == 0 ? graphics.colors.text : graphics.colors.failed, 168)
}

// fresh_bytes_line shows the fresh bytes page of this process: the changes
// that the generator mixed, or why there are none.
fresh_bytes_line :: proc "contextless" (frame: ^interface.Frame, column: ^interface.Column) {
	area := interface.column_take(column, LINE)
	mixes, change_count := random.fresh_bytes_mixes(&process_generator)
	switch {
	case process_generator.fresh_page == nil:
		interface.label_value_line(frame, area, "fresh bytes", "none: the root service gave this process no page", graphics.colors.dim, 168)
	case !report.device_present:
		interface.label_value_line(frame, area, "fresh bytes", "none: the machine has no entropy device", graphics.colors.dim, 168)
	case mixes == 0:
		interface.label_value_line(frame, area, "fresh bytes", "none yet: the root service writes the page every 30 s", graphics.colors.dim, 168)
	case:
		builder: interface.Text_Builder
		interface.text_put(&builder, "mixed ")
		interface.text_put_number(&builder, mixes)
		interface.text_put(&builder, mixes == 1 ? " time, the last at the change " : " times, the last at the change ")
		interface.text_put_number(&builder, u64(change_count))
		interface.text_put(&builder, " of the page")
		interface.label_value_line(frame, area, "fresh bytes", interface.text_of(&builder), graphics.colors.process, 168)
	}
}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	builder: interface.Text_Builder

	// The seed of the system: the facts of the root service.
	content := interface.card(&frame, {8, 8, WIDTH - 16, 196}, "THE SEED OF THE SYSTEM", "Entropy_Report of the root service, at its start", graphics.colors.kernel)
	column := interface.column_of(content)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "strength", op.seed_strength_names[report.strength], strength_color(report.strength), 168)
	source_line(&frame, &column, "rdseed", report.rdseed_present, report.rdseed_good, report.rdseed_refused, random.PROCESSOR_VALUES)
	source_line(&frame, &column, "rdrand", report.rdrand_present, report.rdrand_good, report.rdrand_refused, random.PROCESSOR_VALUES)
	builder.count = 0
	interface.text_put_number(&builder, u64(report.jitter_samples))
	interface.text_put(&builder, " samples, ")
	interface.text_put_number(&builder, u64(report.jitter_distinct))
	interface.text_put(&builder, " distinct low bytes; counted as 0 bits")
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "cycle counter", interface.text_of(&builder), graphics.colors.text, 168)
	device_line(&frame, &column)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "mixed by", "BLAKE3 of each value, with its length", graphics.colors.text, 168)

	// The generator of this process.
	content = interface.card(&frame, {8, 212, WIDTH - 16, HEIGHT - 220}, "THE GENERATOR OF THIS PROCESS", "random.Generator: ChaCha20, fast key erasure", graphics.colors.process)
	column = interface.column_of(content)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "seed", "32 bytes from its starter (the context values 9 to 12), erased after", graphics.colors.text, 168)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "first bytes", hex_text(&builder, first_bytes[:]), graphics.colors.text, 168)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "now", hex_text(&builder, live_bytes[:]), graphics.colors.process, 168)
	builder.count = 0
	interface.text_put_number(&builder, process_generator.served)
	interface.text_put(&builder, " bytes served, ")
	interface.text_put_number(&builder, process_generator.refills)
	interface.text_put(&builder, " refills of 832 bytes")
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "drawn", interface.text_of(&builder), graphics.colors.text, 168)
	fresh_bytes_line(&frame, &column)
	if measured {
		builder.count = 0
		// Two decimals, as the log writes the rate.
		interface.text_put_number(&builder, megabytes_per_second_hundredths / 100)
		interface.text_put(&builder, megabytes_per_second_hundredths % 100 < 10 ? ".0" : ".")
		interface.text_put_number(&builder, megabytes_per_second_hundredths % 100)
		interface.text_put(&builder, " MB/s, 4 MiB in ")
		interface.text_put_number(&builder, measure_microseconds)
		interface.text_put(&builder, " us, no kernel entry")
		interface.label_value_line(&frame, interface.column_take(&column, LINE), "speed", interface.text_of(&builder), graphics.colors.machine, 168)
	}
	interface.column_take(&column, 8)
	interface.cell_text(&frame, interface.column_take(&column, LINE), "1 MiB of the stream, by the high 4 bits of each byte: each bar is near 1/16", graphics.colors.dim)
	most: u64 = 1
	for count in byte_counts {
		most = max(most, count)
	}
	bars := interface.column_take(&column, 120)
	bar_width := (bars.width - 15 * 6) / 16
	for count, index in byte_counts {
		x := bars.x + index * (bar_width + 6)
		height := int(count * u64(bars.height - LINE) / most)
		interface.draw_rectangle(frame.table, x, bars.y + bars.height - LINE - height, bar_width, height, graphics.colors.memory)
		digits := "0123456789abcdef"
		digit := [1]u8{digits[index]}
		interface.draw_text(frame.table, x + bar_width / 2 - 4, bars.y + bars.height - LINE + 4, string(digit[:]), graphics.colors.dim)
	}
	interface.window_frame_end(&window_memory.drawing, &frame, window)
}

// The entry of randomness: it shows the seed, counts 1 MiB, measures 4 MiB,
// then draws a live stream every 500 ms for ever.
//
// With no seed in its context, it writes "randomness: no random seed in the
// context" and stops with `Refused`, as for a seed strength that names no
// strength; with no window, it stops with `Failed`. The counts and the measure run once, in the main thread, after
// the first picture.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if !random.generator_from_context(&process_generator, ctx) {
		system.log_fact(.Info, No_Random_Seed{})
		system.stop(.Refused)
	}
	report_ok: bool
	if report, report_ok = random.report_values_read(&ctx.values); !report_ok {
		system.log_fact(.Info, Seed_Strength_Unknown{strength_word = ctx.values[0] & 0xFF})
		system.stop(.Refused)
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "randomness")
	if !ok {
		system.stop(.Failed)
	}
	random.fill(&process_generator, first_bytes[:])
	hex: interface.Text_Builder
	system.log_fact(.Info, Seed_Shown{strength = value_kinds.text_field(op.seed_strength_names[report.strength], STRENGTH_FIELD_BYTES), first_bytes = value_kinds.text_field(hex_text(&hex, first_bytes[:]), FIRST_BYTES_FIELD_BYTES)})
	if report.device_present {
		system.log_fact(.Info, Entropy_Device_Shown{device_bytes = value_kinds.Size_In_Bytes(report.device_bytes), refused_reads = u64(report.device_reads_refused)})
	} else {
		system.log_fact(.Info, Entropy_Device_Absent{})
	}
	draw(&window)

	// The counts of the byte values of 1 MiB, then the speed on 4 MiB.
	chunk: [4096]u8
	for _ in 0 ..< HISTOGRAM_SIZE / len(chunk) {
		random.fill(&process_generator, chunk[:])
		for byte in chunk {
			byte_counts[byte >> 4] += 1
		}
	}
	least, most: u64 = max(u64), 0
	for count in byte_counts {
		least, most = min(least, count), max(most, count)
	}
	system.log_fact(.Info, Byte_Counts_Shown{least = least, most = most})
	start := system.nanoseconds()
	for _ in 0 ..< MEASURE_SIZE / len(chunk) {
		random.fill(&process_generator, chunk[:])
	}
	took := max(system.nanoseconds() - start, 1)
	measure_microseconds = took / 1000
	megabytes_per_second_hundredths = u64(MEASURE_SIZE) * 100_000 / took
	measured = true
	system.log_fact(.Info, Generator_Measured{elapsed = value_kinds.Time_In_Microseconds(measure_microseconds), rate = value_kinds.Hundredths(megabytes_per_second_hundredths)})
	deadline := system.time()
	// The line of the first mix comes after the picture that shows it, so a
	// test that waits for the line finds the row in the window.
	fresh_bytes_logged := false
	for {
		random.fill(&process_generator, live_bytes[:])
		draw(&window)
		if mixes, change_count := random.fresh_bytes_mixes(&process_generator); mixes > 0 && !fresh_bytes_logged {
			fresh_bytes_logged = true
			system.log_fact(.Info, Fresh_Bytes_Mixed{change = u64(change_count)})
		}
		deadline += 500
		display.wait(&window, deadline)
		interface.window_events(&window_memory.drawing, &window)
	}
}
