// A demonstration of threads (docs/ARCHITECTURE.md, "Open questions about
// the architecture", item 6).
//
// One process, one address space, five threads. Each square is drawn by its
// own thread, in a picture that the threads share with the first thread:
// the threads share all the memory. The first thread shows the pictures in
// the window. The same procedure runs in the four threads; only the
// parameter record differs. The kernel gives the processor to each thread in
// turn: no thread calls another.
//
// Each thread computes with floating point numbers. The kernel keeps the
// registers of each thread: a wrong picture means a lost register.
//
//   1 to 4: stop the thread of a square, or start it again
//
// **What it is for.** It shows that a thread is cheap and that the kernel
// keeps its state whole: each square must stay correct while threads stop,
// start and share the processors. A thread that ends is a value that the
// first thread waits for: one thread first adds the numbers to 1000, and
// the first thread reads the sum in the shared memory.
//
// **Start**: `start("threads")` in the console, or the bar of the desktop.
// Its row of `start_grant_sets` has no grant; its budget has room for 6 threads.
//
// **What a reader sees**: four squares, each with its thread and its count
// of frames, or "stopped". The log has "threads: a thread added the numbers
// to 1000: 500500", then "threads: ok, 4 threads draw in one surface" when
// each square has a frame, and "threads: thread N stopped at frame F" or
// "started" after a key.
package threads

import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"
import "base:intrinsics"

// The working memory: the rest of the pages that the root service gave it
// by its name, once the tool counts its module, its threads and its
// window: 1389 pages. And the glyph memory of the copy of the text
// rendering of the drawing module, which draws its text: 354 pages
// (display.TEXT_MEMORY_PAGES). 1389 + 354 = 1743.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1743, processes = 1, threads = 6, window_width = WIDTH, window_height = HEIGHT}

SQUARE :: 176
MARGIN :: 12
LABEL :: 20
HEADER :: 28
// The size is two literals, because the tool counts the pictures of the
// window from them; each assertion keeps a literal equal to its layout.
WIDTH :: 388
#assert(WIDTH == 2 * SQUARE + 3 * MARGIN)
HEIGHT :: 456
#assert(HEIGHT == HEADER + 2 * (SQUARE + LABEL) + 3 * MARGIN)
FRAME_TIME :: 33
WORKER_COUNT :: 4
ITERATIONS :: 28

// The parameter record of one thread. The thread writes `frames`; the first
// thread reads it.
Worker :: struct {
	canvas: graphics.Canvas, // The square of the thread: its picture.
	number: int,
	frames: u64,
	thread: system.Thread,
	runs:   bool,
}

workers: [WORKER_COUNT]Worker

// The picture of each square, in the memory that the threads share. The
// window shows each one with a picture record; the count of frames of its
// thread is its generation, so a square that did not change is not copied
// again.
square_pixels: [WORKER_COUNT][SQUARE * SQUARE]graphics.Color
square_pictures: [WORKER_COUNT]graphics.Canvas
// The one picture memory of the draw tables: the pixels of the four
// squares follow each other, so the drawing module reads each square there.
picture_memories: [1][]graphics.Color
window_memory: interface.Window_Memory(64, 512)

// The center of the path of the constant of each Julia set, and its tint.
@(rodata)
centers := [WORKER_COUNT][2]f32{{-0.76, 0.12}, {0.30, 0.52}, {-0.12, 0.76}, {-0.40, -0.59}}
@(rodata)
tints := [WORKER_COUNT][3]u32{{2, 5, 9}, {9, 5, 2}, {3, 9, 4}, {8, 3, 9}}

// draw_square is the entry of the four drawing threads.
draw_square :: proc "c" (parameter: rawptr) -> ! {
	worker := (^Worker)(parameter)
	center := centers[worker.number]
	tint := tints[worker.number]
	// A triangle wave moves the constant: no table and no library. Its
	// phase is in turns: the part of a period.
	wave :: proc "contextless" (step: u64, period: u64) -> f32 {
		phase_turns := f32(step % period) / f32(period)
		return phase_turns < 0.5 ? 4 * phase_turns - 1 : 3 - 4 * phase_turns
	}
	for {
		now := system.time()
		cx := center.x + 0.06 * wave(now, 5000 + u64(worker.number) * 700)
		cy := center.y + 0.06 * wave(now + 1250, 7000 - u64(worker.number) * 500)
		for y in 0 ..< SQUARE {
			row := worker.canvas.pixels[y * worker.canvas.stride:]
			for x in 0 ..< SQUARE {
				zx := (f32(x) - SQUARE / 2) * (3.0 / SQUARE)
				zy := (f32(y) - SQUARE / 2) * (3.0 / SQUARE)
				count: u32
				for count < ITERATIONS && zx * zx + zy * zy < 4 {
					zx, zy = zx * zx - zy * zy + cx, 2 * zx * zy + cy
					count += 1
				}
				row[x] = graphics.rgb(min(count * tint[0], 255), min(count * tint[1], 255), min(count * tint[2], 255))
			}
		}
		worker.frames += 1
		// Each thread has its own kernel ring: it waits alone.
		system.sleep(system.time() + FRAME_TIME)
	}
}

// The sum that a thread computes for the first thread.
Sum :: struct {
	last:   u64,
	result: u64,
}

add_numbers :: proc "c" (parameter: rawptr) -> ! {
	sum := (^Sum)(parameter)
	for number in 1 ..= sum.last {
		sum.result += number
	}
	system.thread_stop()
}

worker_start :: proc "contextless" (index: int) -> bool {
	worker := &workers[index]
	status: system.Status
	worker.thread, status = system.thread_start(draw_square, worker)
	worker.runs = status == .Ok
	return worker.runs
}

// The entry of threads: one thread that ends, then four threads that draw,
// and a loop that shows their squares and stops or starts them on a key.
//
// With no window, or when a thread does not start, it stops with the code
// 1. The first thread never draws a pixel of a square: it only shows the
// pictures that the four threads wrote, at the rate of the screen. A key 1
// to 4 ends the thread of that square (`thread_end`), or starts a new one.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "threads")
	if !ok {
		system.stop(.Failed)
	}

	// A thread that ends: the first thread waits for it, then reads the
	// result in the memory that the two threads share.
	sum := Sum {
		last = 1000,
	}
	if adder, status := system.thread_start(add_numbers, &sum); status == .Ok {
		system.thread_wait(adder)
	}
	system.log_fact(.Info, Sum_Added{result = sum.result})

	for &worker, index in workers {
		// A square shows the background until its thread draws it.
		square_pictures[index] = {pixels = raw_data(square_pixels[index][:]), width = SQUARE, height = SQUARE, stride = SQUARE}
		graphics.clear(square_pictures[index], graphics.colors.background)
		worker.number = index
		worker.canvas = square_pictures[index]
		if !worker_start(index) {
			system.log_fact(.Info, Thread_Not_Started{})
			system.stop(.Failed)
		}
	}

	picture_memories[0] = ([^]graphics.Color)(&square_pixels[0][0])[:WORKER_COUNT * SQUARE * SQUARE]
	window_memory.drawing.now.picture_memories = picture_memories[:]
	window_memory.drawing.before.picture_memories = picture_memories[:]
	ready := false
	for {
		for event in display.next_event(&window) {
			if event.kind != .Key || !event.pressed || event.character < '1' || event.character >= '1' + WORKER_COUNT {
				continue
			}
			index := int(event.character - '1')
			worker := &workers[index]
			if worker.runs {
				system.thread_end(worker.thread)
				worker.runs = false
				system.log_fact(.Info, Thread_Stopped{thread = u64(index + 1), frame = worker.frames})
			} else if worker_start(index) {
				system.log_fact(.Info, Thread_Started{thread = u64(index + 1)})
			}
		}
		drawn := 0
		frame := interface.window_frame_start(&window_memory, &window)
		table := frame.table
		interface.draw_text(table, MARGIN, 8, "One process. Each square is one thread.", graphics.colors.text)
		for &worker, index in workers {
			x := MARGIN + (index % 2) * (SQUARE + MARGIN)
			y := HEADER + MARGIN + (index / 2) * (SQUARE + LABEL + MARGIN)
			// The thread writes frames after a whole square: one read, so
			// the generation and the label say the same count.
			frames := intrinsics.volatile_load(&worker.frames)
			interface.draw_picture(table, x, y, square_pictures[index], u32(frames))
			y += SQUARE
			after := interface.draw_text(table, x, y + 3, "thread ", graphics.colors.text)
			after = interface.draw_unsigned(table, after, y + 3, u64(index + 1), graphics.colors.text)
			if worker.runs {
				after = interface.draw_text(table, after, y + 3, "  frame ", graphics.colors.dim)
				interface.draw_unsigned(table, after, y + 3, frames, graphics.colors.dim)
			} else {
				// A stopped thread is not a failure: the principal stopped
				// it. The word, in the text color, has more weight than
				// the dim count of frames of a thread that runs.
				interface.draw_text(table, after, y + 3, "  stopped", graphics.colors.text)
			}
			if frames > 0 {
				drawn += 1
			}
		}
		if drawn == WORKER_COUNT && !ready {
			ready = true
			system.log_fact(.Info, Threads_Drawing{threads = u64(WORKER_COUNT)})
		}
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
		display.wait(&window, system.time() + FRAME_TIME)
	}
}
