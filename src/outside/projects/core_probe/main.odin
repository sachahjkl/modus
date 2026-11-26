// Exercises base:runtime and core packages on target modus.
package core_probe

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import "modus:system"

// Plan value: 2048 pages hold heap slabs, temporary allocator spill, the 16-page
// virtual memory reservation test, two worker thread stacks, and an 80 KiB
// storage transfer buffer; 3 threads cover the initial thread and two workers.
MODULE_BUDGET :: system.Stated_Budget {
	working_memory_pages = 2048,
	processes            = 1,
	threads              = 3,
}

// Hardware page size on x86-64.
PAGE_SIZE :: 4096

// Transfer size past one 64 KiB storage call region to test multi-chunk I/O.
LARGE_FILE_BYTES :: 80 * 1024

Worker_State :: struct {
	mutex:    sync.Mutex,
	cond:     sync.Cond,
	wg:       sync.Wait_Group,
	ready:    bool,
	counter:  int,
	main_tid: int,
	bad_tid:  bool,
}

joined_worker :: proc(t: ^thread.Thread) {
	s := (^Worker_State)(t.data)
	tid := sync.current_thread_id()
	sync.mutex_lock(&s.mutex)
	if tid == 0 || tid == s.main_tid {
		s.bad_tid = true
	}
	for !s.ready {
		sync.cond_wait(&s.cond, &s.mutex)
	}
	s.counter += 100
	sync.mutex_unlock(&s.mutex)
	sync.wait_group_done(&s.wg)
}

detached_worker :: proc(t: ^thread.Thread) {
	s := (^Worker_State)(t.data)
	tid := sync.current_thread_id()
	sync.mutex_lock(&s.mutex)
	if tid == 0 || tid == s.main_tid {
		s.bad_tid = true
	}
	s.counter += 100
	sync.mutex_unlock(&s.mutex)
	sync.wait_group_done(&s.wg)
}

check_zero_ambient_authority :: proc() {
	if len(os.args) != 0 {
		panic("core_probe: os.args must be empty")
	}
	if _, found := os.lookup_env("PATH", context.temp_allocator); found {
		panic("core_probe: PATH must be absent")
	}
	if _, found := os.lookup_env("HOME", context.temp_allocator); found {
		panic("core_probe: HOME must be absent")
	}
}

check_heap_and_temp_allocators :: proc() {
	sizes := [?]int{32, 128, 1024, 8192, 24576}
	for iter in 0 ..< 32 {
		for sz, idx in sizes {
			buf := make([]u8, sz)
			fill := u8((iter * 13 + idx * 7 + 1) & 0xFF)
			for i in 0 ..< sz {
				buf[i] = fill ~ u8(i & 0xFF)
			}
			for i in 0 ..< sz {
				if buf[i] != (fill ~ u8(i & 0xFF)) {
					panic("core_probe: heap buffer byte mismatch")
				}
			}
			delete(buf)
		}
	}

	// Cross the 64 KiB inline temporary block into page-backed spillover and reset.
	for round in 0 ..< 4 {
		chunks: [5][]u8
		for c in 0 ..< len(chunks) {
			chunks[c] = make([]u8, 16 * 1024, context.temp_allocator)
			tag := u8((round * 11 + c * 5 + 3) & 0xFF)
			chunks[c][0] = tag
			chunks[c][len(chunks[c]) - 1] = ~tag
		}
		for c in 0 ..< len(chunks) {
			tag := u8((round * 11 + c * 5 + 3) & 0xFF)
			if chunks[c][0] != tag || chunks[c][len(chunks[c]) - 1] != ~tag {
				panic("core_probe: temp allocator byte mismatch")
			}
		}
		free_all(context.temp_allocator)
	}
}

check_virtual_memory :: proc() {
	reserved, res_err := virtual.reserve(16 * PAGE_SIZE)
	if res_err != nil || len(reserved) != 16 * PAGE_SIZE {
		panic("core_probe: virtual.reserve failed")
	}
	commit_err := virtual.commit(raw_data(reserved), 8 * PAGE_SIZE)
	if commit_err != nil {
		panic("core_probe: virtual.commit failed")
	}

	for page in 0 ..< 8 {
		val := u8(0xA0 + page)
		reserved[page * PAGE_SIZE] = val
		reserved[page * PAGE_SIZE + PAGE_SIZE - 1] = ~val
	}
	for page in 0 ..< 8 {
		val := u8(0xA0 + page)
		if reserved[page * PAGE_SIZE] != val || reserved[page * PAGE_SIZE + PAGE_SIZE - 1] != ~val {
			panic("core_probe: virtual committed page mismatch")
		}
	}

	// Refuse W+X protection requests.
	if virtual.protect(raw_data(reserved), 8 * PAGE_SIZE, {.Read, .Write, .Execute}) {
		panic("core_probe: virtual.protect accepted Write+Execute")
	}
	if !virtual.protect(raw_data(reserved), 8 * PAGE_SIZE, {.Read}) {
		panic("core_probe: virtual.protect Read failed")
	}
	for page in 0 ..< 8 {
		val := u8(0xA0 + page)
		if reserved[page * PAGE_SIZE] != val {
			panic("core_probe: virtual read-only page mismatch")
		}
	}
	if !virtual.protect(raw_data(reserved), 8 * PAGE_SIZE, {.Read, .Write}) {
		panic("core_probe: virtual.protect Read+Write failed")
	}
	for page in 0 ..< 8 {
		val := u8(0x50 + page)
		reserved[page * PAGE_SIZE] = val
		if reserved[page * PAGE_SIZE] != val {
			panic("core_probe: virtual restored Read+Write mismatch")
		}
	}

	virtual.decommit(raw_data(reserved), 8 * PAGE_SIZE)
	virtual.release(raw_data(reserved), uint(len(reserved)))
}

check_time :: proc() {
	t0 := time.tick_now()
	time.sleep(10 * time.Millisecond)
	t1 := time.tick_now()
	if time.tick_diff(t0, t1) <= 0 {
		panic("core_probe: monotonic tick did not advance after sleep")
	}
	wall := time.now()
	if wall._nsec <= 0 {
		panic("core_probe: time.now returned non-positive value")
	}
}

check_sync_and_threads :: proc() {
	main_tid := sync.current_thread_id()
	if main_tid == 0 {
		panic("core_probe: initial thread id must be non-zero")
	}

	state := Worker_State{main_tid = main_tid}
	sync.wait_group_add(&state.wg, 2)

	t1 := thread.create(joined_worker)
	if t1 == nil {
		panic("core_probe: joined thread.create failed")
	}
	t1.data = &state
	thread.start(t1)

	t2 := thread.create(detached_worker)
	if t2 == nil {
		panic("core_probe: detached thread.create failed")
	}
	t2.data = &state
	t2.flags += {.Self_Cleanup}
	thread.start(t2)

	sync.mutex_lock(&state.mutex)
	state.ready = true
	sync.cond_signal(&state.cond)
	sync.mutex_unlock(&state.mutex)

	sync.wait_group_wait(&state.wg)
	thread.destroy(t1)

	if state.bad_tid {
		panic("core_probe: worker thread id was zero or collided with initial thread")
	}
	if state.counter != 200 {
		panic("core_probe: worker counter mismatch")
	}
}

check_private_store_io :: proc() {
	// Path refusals first: leading '/' and '..' must be refused.
	for bad in ([]string{"/etc/passwd", "../escape", "probe_dir/../escape"}) {
		if f, err := os.open(bad); err == nil {
			_ = os.close(f)
			panic("core_probe: os.open accepted refused path")
		}
		if err := os.mkdir(bad); err == nil {
			panic("core_probe: os.mkdir accepted refused path")
		}
		if _, err := os.stat(bad, context.temp_allocator); err == nil {
			panic("core_probe: os.stat accepted refused path")
		}
		if err := os.remove(bad); err == nil {
			panic("core_probe: os.remove accepted refused path")
		}
	}

	// Clean any leftover directory from an earlier run.
	if os.exists("probe_dir") {
		_ = os.remove_all("probe_dir")
	}

	if err := os.mkdir("probe_dir"); err != nil {
		panic("core_probe: os.mkdir probe_dir failed")
	}

	payload := make([]u8, LARGE_FILE_BYTES)
	defer delete(payload)
	for i in 0 ..< LARGE_FILE_BYTES {
		payload[i] = u8((i * 31 + 7) & 0xFF)
	}

	wf, werr := os.open("probe_dir/data.bin", {.Read, .Write, .Create, .Trunc})
	if werr != nil || wf == nil {
		panic("core_probe: os.open for write failed")
	}
	written, write_err := os.write(wf, payload)
	if write_err != nil || written != LARGE_FILE_BYTES {
		panic("core_probe: os.write failed")
	}
	if sync_err := os.sync(wf); sync_err != nil {
		panic("core_probe: os.sync failed")
	}
	if close_err := os.close(wf); close_err != nil {
		panic("core_probe: os.close after write failed")
	}

	rf, rerr := os.open("probe_dir/data.bin", {.Read})
	if rerr != nil || rf == nil {
		panic("core_probe: os.open for read failed")
	}
	finfo, fstat_err := os.fstat(rf, context.temp_allocator)
	if fstat_err != nil || finfo.type != .Regular || finfo.size != LARGE_FILE_BYTES {
		panic("core_probe: os.fstat mismatch")
	}

	read_buf := make([]u8, LARGE_FILE_BYTES)
	defer delete(read_buf)
	total := 0
	for total < LARGE_FILE_BYTES {
		n, read_err := os.read(rf, read_buf[total:])
		if read_err != nil && read_err != .EOF {
			panic("core_probe: os.read failed")
		}
		if n == 0 {
			break
		}
		total += n
	}
	if total != LARGE_FILE_BYTES {
		panic("core_probe: os.read short count")
	}
	for i in 0 ..< LARGE_FILE_BYTES {
		if read_buf[i] != payload[i] {
			panic("core_probe: os.read byte mismatch")
		}
	}

	// Read across the 64 KiB boundary with os.read_at.
	cross_offset :: 65000
	cross: [1024]u8
	cross_n, cross_err := os.read_at(rf, cross[:], cross_offset)
	if cross_err != nil || cross_n != len(cross) {
		panic("core_probe: os.read_at across 64 KiB boundary failed")
	}
	for i in 0 ..< len(cross) {
		if cross[i] != payload[cross_offset + i] {
			panic("core_probe: os.read_at byte mismatch")
		}
	}
	if close_err := os.close(rf); close_err != nil {
		panic("core_probe: os.close after read failed")
	}

	file_st, file_st_err := os.stat("probe_dir/data.bin", context.temp_allocator)
	if file_st_err != nil || file_st.type != .Regular || file_st.size != LARGE_FILE_BYTES {
		panic("core_probe: os.stat on file mismatch")
	}
	dir_st, dir_st_err := os.stat("probe_dir", context.temp_allocator)
	if dir_st_err != nil || dir_st.type != .Directory {
		panic("core_probe: os.stat on directory mismatch")
	}

	df, derr := os.open("probe_dir")
	if derr != nil || df == nil {
		panic("core_probe: os.open on directory failed")
	}
	entries, rd_err := os.read_dir(df, -1, context.temp_allocator)
	if rd_err != nil || len(entries) != 1 || entries[0].name != "data.bin" || entries[0].type != .Regular || entries[0].size != LARGE_FILE_BYTES {
		panic("core_probe: os.read_dir mismatch")
	}
	if close_err := os.close(df); close_err != nil {
		panic("core_probe: os.close on directory failed")
	}

	if err := os.rename("probe_dir/data.bin", "probe_dir/renamed.bin"); err != nil {
		panic("core_probe: os.rename failed")
	}
	if os.exists("probe_dir/data.bin") || !os.exists("probe_dir/renamed.bin") {
		panic("core_probe: os.rename did not move entry")
	}
	if err := os.remove("probe_dir/renamed.bin"); err != nil {
		panic("core_probe: os.remove file failed")
	}
	if os.exists("probe_dir/renamed.bin") {
		panic("core_probe: removed file still exists")
	}
	if err := os.remove("probe_dir"); err != nil {
		panic("core_probe: os.remove directory failed")
	}
	if os.exists("probe_dir") {
		panic("core_probe: removed directory still exists")
	}
	free_all(context.temp_allocator)
}

main :: proc() {
	fmt.println("core_probe: start")
	fmt.println()

	check_zero_ambient_authority()

	// When started without a Store grant, confirm refusal and stay alive so a
	// principal can grant Store and restart the process.
	_, root_stat_err := os.stat(".", context.temp_allocator)
	if root_stat_err == .Permission_Denied {
		fmt.println("core_probe: no store grant, waiting for store")
		for {
			time.sleep(time.Hour)
		}
	}
	if root_stat_err != nil {
		panic("core_probe: unexpected error on root store stat")
	}

	check_heap_and_temp_allocators()
	check_virtual_memory()
	check_time()
	check_sync_and_threads()
	check_private_store_io()

	fmt.println("core_probe: ok, all core packages passed")
}
