// The facts of the page of an object cache that the server keeps itself
// (src/md/infrastructure/public_object_cache.md, "The counts kept by the
// server"): one listing of the store at its open, then one change at each
// write, so a view of the page costs no work in proportion to the store.
package cache_server

import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "modus:contract/object_cache"

// The realisations that the page lists, newest first.
RECENT_REALISATION_COUNT :: 10

// A realisation of the list of the page, and when the server wrote it (the
// time of its file for one written before the start).
Recent_Realisation :: struct {
	record:  object_cache.Realisation_Record,
	written: time.Time,
}

// The counts of the store. A zero last_write means that the store holds no
// entry and the server wrote none.
Store_Counts :: struct {
	objects:              u64,
	object_bytes:         u64,
	largest_object_bytes: u64,
	realisations:         u64,
	realisation_bytes:    u64,
	last_write:           time.Time,
}

// The facts that the thread of the protocol changes and the thread of the
// page reads, behind one lock.
Cache_Status :: struct {
	lock:         sync.Mutex,
	counts:       Store_Counts,
	recent:       [RECENT_REALISATION_COUNT]Recent_Realisation,
	recent_count: int,
	// The date of the start, for the page; the monotonic time of the start,
	// for the uptime, which a step of the date must not make negative.
	started:      time.Time,
	started_tick: time.Tick,
}

// A copy of the facts, taken under the lock, that the page and the status
// record are written from with no lock held.
Cache_Status_Snapshot :: struct {
	counts:       Store_Counts,
	recent:       [RECENT_REALISATION_COUNT]Recent_Realisation,
	recent_count: int,
	started:      time.Time,
	started_tick: time.Tick,
}

@(private = "file")
time_later :: proc(a, b: time.Time) -> time.Time {
	return time.diff(a, b) > 0 ? b : a
}

// cache_status_recent_put puts a realisation at the top of the list. An
// entry of the same recipe leaves the list: the file of a recipe holds one
// realisation, the last one written.
cache_status_recent_put :: proc(status: ^Cache_Status, entry: Recent_Realisation) {
	kept := 0
	kept_entries: [RECENT_REALISATION_COUNT]Recent_Realisation
	for index in 0 ..< status.recent_count {
		old := status.recent[index]
		if old.record.recipe_hash == entry.record.recipe_hash {
			continue
		}
		kept_entries[kept] = old
		kept += 1
	}
	status.recent[0] = entry
	count := 1
	for index in 0 ..< kept {
		if count == RECENT_REALISATION_COUNT {
			break
		}
		status.recent[count] = kept_entries[index]
		count += 1
	}
	status.recent_count = count
}

// cache_status_record_object counts one object that the server wrote. added
// is false when the store held the name: the same object again adds nothing.
cache_status_record_object :: proc(status: ^Cache_Status, size: u64, added: bool, written: time.Time) {
	sync.mutex_lock(&status.lock)
	defer sync.mutex_unlock(&status.lock)
	if added {
		status.counts.objects += 1
		status.counts.object_bytes += size
	}
	if size > status.counts.largest_object_bytes {
		status.counts.largest_object_bytes = size
	}
	status.counts.last_write = time_later(status.counts.last_write, written)
}

// cache_status_record_realisation counts one realisation that the server
// wrote and puts it at the top of the list.
cache_status_record_realisation :: proc(status: ^Cache_Status, record: object_cache.Realisation_Record, added: bool, written: time.Time) {
	sync.mutex_lock(&status.lock)
	defer sync.mutex_unlock(&status.lock)
	if added {
		status.counts.realisations += 1
		status.counts.realisation_bytes += object_cache.REALISATION_WIRE_SIZE
	}
	status.counts.last_write = time_later(status.counts.last_write, written)
	cache_status_recent_put(status, Recent_Realisation{record = record, written = written})
}

// cache_status_snapshot copies the facts under the lock.
cache_status_snapshot :: proc(status: ^Cache_Status) -> (snapshot: Cache_Status_Snapshot) {
	sync.mutex_lock(&status.lock)
	defer sync.mutex_unlock(&status.lock)
	snapshot.counts = status.counts
	snapshot.recent = status.recent
	snapshot.recent_count = status.recent_count
	snapshot.started = status.started
	snapshot.started_tick = status.started_tick
	return snapshot
}

// A realisation file found by the listing at the start, before its read.
@(private = "file")
Listed_Realisation :: struct {
	name:    [64]u8,
	written: time.Time,
}

// cache_status_scan counts the store once, at its open: one listing of each
// folder, with the size and the time of each entry from the listing. Only a
// name of 64 lowercase hexadecimal digits counts, as only such a name is a
// path that the server reads. The newest realisations are then read and
// decoded for the list of the page; a file that does not decode, or whose
// record names another recipe, is not listed.
cache_status_scan :: proc(server: ^Cache_Server) -> bool {
	status := &server.status
	counts: Store_Counts
	newest: [RECENT_REALISATION_COUNT]Listed_Realisation
	newest_count := 0

	for directory in ([2]Store_Directory{.Objects, .Realisations}) {
		path := strings.concatenate({server.root_directory, "/", store_directory_name(directory)}, context.temp_allocator)
		folder, open_error := os.open(path)
		if open_error != nil {
			return false
		}
		defer os.close(folder)
		// One entry at a time: the memory of the listing does not grow with
		// the folder.
		iterator := os.read_directory_iterator_create(folder)
		defer os.read_directory_iterator_destroy(&iterator)
		for entry in os.read_directory_iterator(&iterator) {
			if entry.type != .Regular || !hex_hash_valid(entry.name) || entry.size < 0 {
				continue
			}
			counts.last_write = time_later(counts.last_write, entry.modification_time)
			switch directory {
			case .Objects:
				counts.objects += 1
				counts.object_bytes += u64(entry.size)
				if u64(entry.size) > counts.largest_object_bytes {
					counts.largest_object_bytes = u64(entry.size)
				}
			case .Realisations:
				counts.realisations += 1
				counts.realisation_bytes += u64(entry.size)
				// Keep the newest names in order, newest first: at most
				// RECENT_REALISATION_COUNT moves for each entry.
				place := newest_count
				for place > 0 && time.diff(newest[place - 1].written, entry.modification_time) > 0 {
					place -= 1
				}
				if place < RECENT_REALISATION_COUNT {
					last := min(newest_count, RECENT_REALISATION_COUNT - 1)
					for index := last; index > place; index -= 1 {
						newest[index] = newest[index - 1]
					}
					copy(newest[place].name[:], entry.name)
					newest[place].written = entry.modification_time
					newest_count = min(newest_count + 1, RECENT_REALISATION_COUNT)
				}
			case .Temp, .Outboards:
			}
		}
		// A listing cut short gives counts that are too low: the open is refused,
		// as for a folder that does not open.
		if _, iterator_error := os.read_directory_iterator_error(&iterator); iterator_error != nil {
			return false
		}
	}

	recent: [RECENT_REALISATION_COUNT]Recent_Realisation
	recent_count := 0
	for index in 0 ..< newest_count {
		listed := newest[index]
		data, found, read_ok := store_read_by_hex(server, .Realisations, string(listed.name[:]), context.temp_allocator)
		if !read_ok || !found {
			continue
		}
		record, refusal := object_cache.decode_realisation_record(data)
		if refusal != .None {
			continue
		}
		recipe_hex := hash_to_hex(record.recipe_hash)
		if recipe_hex != listed.name {
			continue
		}
		recent[recent_count] = Recent_Realisation{record = record, written = listed.written}
		recent_count += 1
	}

	sync.mutex_lock(&status.lock)
	defer sync.mutex_unlock(&status.lock)
	status.counts = counts
	status.recent = recent
	status.recent_count = recent_count
	return true
}
