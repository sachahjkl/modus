// A demonstration of the lock and of the word wait.
//
// One process, five threads, one queue of work. The first thread cuts a
// picture in tiles and puts all the tiles in the queue. Four threads take
// the tiles: each tile is computed by the thread that took it, and has the
// tint of this thread. A lock keeps the queue correct. A thread with no
// work waits on a word of memory; the first thread changes the word and
// wakes the four threads.
//
// Before the picture, the four threads add to one number, first with the
// lock, then with no lock. With no lock, additions are lost.
//
// **What it is for.** It shows the two tools of the system for threads
// that share memory: the lock of the system library, which counts its
// waits, and the word wait of the kernel, where a thread sleeps on a word of
// memory with no kernel object. The sum with no lock shows why the lock
// exists.
//
// **Start**: `start("workers")` in the console, or the bar of the desktop.
// Its row of `process_roles` has no grant; its budget has room for 9 threads.
//
// **What a reader sees**: the picture in the tints of the four threads,
// which zooms in at each new picture, the tiles of each thread and the
// waits of the lock. The log has:
//
// - "workers: with the lock, 4 threads made N additions: the number is N,
//   W waits";
// - "workers: with no lock, ...: the number is M", where M is usually
//   smaller than N;
// - "workers: the lock lost no addition";
// - "workers: ok, 4 threads computed T tiles: A B C D" after the first
//   picture.
package workers

import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"
import "base:intrinsics"

// The working memory: the rest of the pages that the root service gave it
// by its name, once the tool counts its module, its threads and its
// window: 1154 pages. And the glyph memory of the copy of the text
// rendering of the drawing module, which draws its text: 354 pages
// (display.TEXT_MEMORY_PAGES). 1154 + 354 = 1508.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1508, processes = 1, threads = 9, window_width = WIDTH, window_height = HEIGHT}

TILE :: 32
COLUMNS :: 14
ROWS :: 10
PICTURE_WIDTH :: COLUMNS * TILE
PICTURE_HEIGHT :: ROWS * TILE
MARGIN :: 12
HEADER :: 28
PANEL :: 208
// The size is two literals, because the tool counts the pictures of the
// window from them; each assertion keeps a literal equal to its layout.
WIDTH :: 692
#assert(WIDTH == PICTURE_WIDTH + PANEL + 3 * MARGIN)
HEIGHT :: 372
#assert(HEIGHT == HEADER + PICTURE_HEIGHT + 2 * MARGIN)
FRAME_TIME :: 33
PICTURE_PAUSE :: 700 // Milliseconds between two pictures.
WORKER_COUNT :: 4
ITERATIONS :: 600
ADD_TIME :: 150 // Milliseconds: each thread adds for this time.

// The queue of work: the threads share it, the lock keeps it correct.
Queue :: struct {
	lock:    system.Lock,
	picture: u32, // The number of the picture. A thread with no work waits on this word.
	next:    u32, // The first tile that no thread took.
	done:    u32, // The tiles that are complete.
	zoom:    f32,
}

Worker :: struct {
	number: int,
	tiles:  u64, // The tiles that this thread computed, in all the pictures.
	share:  u32, // The same, in this picture.
	thread: system.Thread,
}

queue: Queue
workers: [WORKER_COUNT]Worker
picture: graphics.Canvas // The picture that the four threads compute, in the memory that they share.
picture_pixels: [PICTURE_WIDTH * PICTURE_HEIGHT]graphics.Color
// The one picture memory of the draw tables: the drawing module reads the
// picture there.
picture_memories: [1][]graphics.Color
window_memory: interface.Window_Memory(96, 512)
sum_locked, sum_free: u64
made_locked, made_free: u64
nothing: u64 // Always 0.
sum_lock: system.Lock

// The picture is in the series color of each thread in the dark appearance:
// a picture keeps its pixels in both appearances. The legend of a thread
// takes its series color of the appearance in force: the same hue.
#assert(WORKER_COUNT <= graphics.SERIES_COLOR_COUNT)
@(rodata)
picture_series := graphics.DARK_SERIES

// tint_color gives the color of a pixel of the picture: the series color of
// the thread, at the level 0 (black) to 255 (the color itself).
tint_color :: proc "contextless" (number: int, level: u32) -> graphics.Color {
	tint := picture_series[number]
	return graphics.rgb((tint >> 16 & 0xFF) * level / 255, (tint >> 8 & 0xFF) * level / 255, (tint & 0xFF) * level / 255)
}

// One thread that adds to the number, and the additions that it made.
Adder :: struct {
	with_lock: bool,
	count:     u64,
}

// add is the entry of the threads that add to one number, for ADD_TIME.
add :: proc "c" (parameter: rawptr) -> ! {
	adder := (^Adder)(parameter)
	target := adder.with_lock ? &sum_locked : &sum_free
	start := system.time()
	for system.time() < start + ADD_TIME {
		for _ in 0 ..< 4096 {
			if adder.with_lock {
				system.lock(&sum_lock)
			}
			// A read, then a write: another thread can run between the two.
			// Real code computes between the two: here, it reads 8 words.
			value := intrinsics.volatile_load(target)
			for _ in 0 ..< 8 {
				value += intrinsics.volatile_load(&nothing)
			}
			intrinsics.volatile_store(target, value + 1)
			if adder.with_lock {
				system.unlock(&sum_lock)
			}
		}
		adder.count += 4096
	}
	system.thread_stop()
}

// add_with_threads gives the additions that the four threads made.
add_with_threads :: proc "contextless" (with_lock: bool) -> (total: u64) {
	adders: [WORKER_COUNT]Adder
	threads: [WORKER_COUNT]system.Thread
	for &thread, index in threads {
		adders[index].with_lock = with_lock
		thread, _ = system.thread_start(add, &adders[index])
	}
	for thread, index in threads {
		system.thread_wait(thread)
		total += adders[index].count
	}
	return total
}

// compute is the entry of the four threads that take tiles.
compute :: proc "c" (parameter: rawptr) -> ! {
	worker := (^Worker)(parameter)
	for {
		system.lock(&queue.lock)
		if queue.next == COLUMNS * ROWS {
			number := queue.picture
			system.unlock(&queue.lock)
			system.word_wait(&queue.picture, number)
			continue
		}
		tile := int(queue.next)
		queue.next += 1
		zoom := queue.zoom
		system.unlock(&queue.lock)

		left := tile % COLUMNS * TILE
		top := tile / COLUMNS * TILE
		for y in top ..< top + TILE {
			row := picture.pixels[y * picture.stride:]
			for x in left ..< left + TILE {
				cx := -0.7436 + (f32(x) - PICTURE_WIDTH / 2) * zoom
				cy := 0.1318 + (f32(y) - PICTURE_HEIGHT / 2) * zoom
				zx, zy: f32
				count: u32
				for count < ITERATIONS && zx * zx + zy * zy < 4 {
					zx, zy = zx * zx - zy * zy + cx, 2 * zx * zy + cy
					count += 1
				}
				row[x] = count == ITERATIONS ? tint_color(worker.number, 40) : tint_color(worker.number, 70 + (count * 8) % 186)
			}
		}

		system.lock(&queue.lock)
		queue.done += 1
		worker.tiles += 1
		worker.share += 1
		system.unlock(&queue.lock)
	}
}

// The entry of workers: the two sums, then the four workers, then a loop
// that gives them a new picture after each pause.
//
// With no window, or when a thread does not start, it stops with the code
// 1. The first thread never computes a tile: it fills the queue, changes
// the word that the workers wait on, and draws at the rate of the screen.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "workers")
	if !ok {
		system.stop(.Failed)
	}
	// The window shows the picture with a picture record: until the first
	// tiles, the picture is the background.
	picture = {pixels = raw_data(picture_pixels[:]), width = PICTURE_WIDTH, height = PICTURE_HEIGHT, stride = PICTURE_WIDTH}
	graphics.clear(picture, graphics.colors.background)
	picture_memories[0] = picture_pixels[:]
	window_memory.drawing.now.picture_memories = picture_memories[:]
	window_memory.drawing.before.picture_memories = picture_memories[:]
	{
		frame := interface.window_frame_start(&window_memory, &window)
		interface.draw_text(frame.table, MARGIN, 8, "One queue of tiles, one lock, four threads.", graphics.colors.text)
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
	}

	made_locked = add_with_threads(true)
	made_free = add_with_threads(false)
	system.log(.Info, "workers: with the lock, 4 threads made ", made_locked, " additions: the number is ", sum_locked, ", ", u64(sum_lock.waits), " waits")
	system.log(.Info, "workers: with no lock, 4 threads made ", made_free, " additions: the number is ", sum_free)
	if made_locked == sum_locked {
		system.log(.Info, "workers: the lock lost no addition")
	}

	queue.next = COLUMNS * ROWS
	queue.done = COLUMNS * ROWS
	queue.zoom = 0.012
	for &worker, index in workers {
		worker.number = index
		status: system.Status
		worker.thread, status = system.thread_start(compute, &worker)
		if status != .Ok {
			system.log(.Info, "workers: cannot start a thread")
			system.stop(.Failed)
		}
	}

	pictures_made: u64
	complete_at: u64
	for {
		now := system.time()
		system.lock(&queue.lock)
		done := queue.done
		if done == COLUMNS * ROWS && complete_at == 0 {
			complete_at = now
			if pictures_made == 1 {
				system.log(.Info, "workers: ok, 4 threads computed ", u64(COLUMNS * ROWS), " tiles: ", workers[0].tiles, " ", workers[1].tiles, " ", workers[2].tiles, " ", workers[3].tiles)
			}
		}
		if done == COLUMNS * ROWS && now >= complete_at + (pictures_made == 0 ? 0 : PICTURE_PAUSE) {
			// A new picture: all the tiles go in the queue.
			queue.next = 0
			queue.done = 0
			queue.zoom *= 0.8
			if queue.zoom < 0.00002 {
				queue.zoom = 0.012
			}
			queue.picture += 1
			for &worker in workers {
				worker.share = 0
			}
			pictures_made += 1
			complete_at = 0
			done = 0
			system.unlock(&queue.lock)
			system.word_wake(&queue.picture, WORKER_COUNT)
		} else {
			system.unlock(&queue.lock)
		}

		frame := interface.window_frame_start(&window_memory, &window)
		table := frame.table
		interface.draw_text(table, MARGIN, 8, "One queue of tiles, one lock, four threads.", graphics.colors.text)
		// The pixels change when a tile is complete: the number of the
		// picture and its complete tiles are the generation.
		interface.draw_picture(table, MARGIN, HEADER + MARGIN, picture, u32(pictures_made) * 1024 + done)
		x := 2 * MARGIN + PICTURE_WIDTH
		y := HEADER + MARGIN
		interface.draw_rectangle(table, x, y, PANEL, PICTURE_HEIGHT, graphics.colors.card_top)
		after := interface.draw_text(table, x + 8, y + 8, "picture ", graphics.colors.text)
		interface.draw_unsigned(table, after, y + 8, pictures_made, graphics.colors.text)
		after = interface.draw_text(table, x + 8, y + 28, "tiles   ", graphics.colors.dim)
		after = interface.draw_unsigned(table, after, y + 28, u64(done), graphics.colors.dim)
		after = interface.draw_text(table, after, y + 28, "/", graphics.colors.dim)
		interface.draw_unsigned(table, after, y + 28, COLUMNS * ROWS, graphics.colors.dim)
		for &worker, index in workers {
			line := y + 60 + index * 44
			after = interface.draw_text(table, x + 8, line, "thread ", graphics.colors.series[index])
			after = interface.draw_unsigned(table, after, line, u64(index + 1), graphics.colors.series[index])
			interface.draw_unsigned(table, after + 16, line, u64(worker.share), graphics.colors.text)
			// The part of the tiles of this picture that the thread took.
			interface.draw_rectangle(table, x + 8, line + 20, PANEL - 16, 8, graphics.colors.background)
			interface.draw_rectangle(table, x + 8, line + 20, int(worker.share) * (PANEL - 16) / (COLUMNS * ROWS), 8, graphics.colors.series[index])
		}
		line := y + 60 + WORKER_COUNT * 44 + 4
		// A wait of the lock is a wait in the kernel.
		after = interface.draw_text(table, x + 8, line, "lock waits ", graphics.colors.kernel)
		interface.draw_unsigned(table, after, line, u64(queue.lock.waits), graphics.colors.kernel)
		interface.draw_text(table, x + 8, line + 24, "4 threads, 1 number", graphics.colors.dim)
		after = interface.draw_text(table, x + 8, line + 42, "lock:    lost ", graphics.colors.text)
		interface.draw_unsigned(table, after, line + 42, made_locked - sum_locked, graphics.colors.text)
		after = interface.draw_text(table, x + 8, line + 60, "no lock: lost ", graphics.colors.text)
		// The additions that the run with no lock lost: a sum that is wrong.
		interface.draw_unsigned(table, after, line + 60, made_free - sum_free, graphics.colors.failed)
		interface.window_frame_end(&window_memory.drawing, &frame, &window)
		display.wait(&window, now + FRAME_TIME)
	}
}
