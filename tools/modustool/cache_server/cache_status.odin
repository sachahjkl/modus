// The facts of the page of an object cache that the server keeps itself
// (src/md/infrastructure/public_object_cache.md, "The counts kept by the
// server"): one listing of the store at its open, then one change at each
// write, so a view of the page costs no work in proportion to the store.
package cache_server

import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "modus:contract/blake3"
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
	// The objects that left objects/ because their bytes do not hash to
	// their name.
	damaged_objects:      u64,
	realisations:         u64,
	realisation_bytes:    u64,
	last_write:           time.Time,
}

// A release pointer that the host keeps, the hash of its record (the name
// of its file), and when the host wrote it: the record holds no time.
Kept_Release_Pointer :: struct {
	pointer:     object_cache.Release_Pointer,
	record_hash: blake3.Hash,
	written:     time.Time,
}

// The facts that the thread of the protocol changes and the thread of the
// page reads, behind one lock.
Cache_Status :: struct {
	lock:              sync.Mutex,
	counts:            Store_Counts,
	recent:            [RECENT_REALISATION_COUNT]Recent_Realisation,
	recent_count:      int,
	// The names of the store, sorted, for the search: made by the listing
	// at the start, and changed at each write that adds a name, so a search
	// lists no folder (src/md/infrastructure/cache_browser.md, "The search").
	object_names:      [dynamic]blake3.Hash,
	realisation_names: [dynamic]blake3.Hash,
	// Each release pointer that the host keeps, in the order of its write.
	release_pointers:  [dynamic]Kept_Release_Pointer,
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

// hash_compare orders two hashes by their bytes, as their hexadecimal names
// sort.
hash_compare :: proc(left, right: blake3.Hash) -> slice.Ordering {
	for index in 0 ..< len(left) {
		if left[index] != right[index] {
			return left[index] < right[index] ? .Less : .Greater
		}
	}
	return .Equal
}

// sorted_names_insert puts a name in its place. A name that is there
// already is not put twice.
sorted_names_insert :: proc(names: ^[dynamic]blake3.Hash, name: blake3.Hash) {
	place, found := slice.binary_search_by(names[:], name, hash_compare)
	if found {
		return
	}
	inject_at(names, place, name)
}

// A prefix of a hash: its hexadecimal digits as values 0 to 15.
Hash_Prefix :: struct {
	digits: [64]u8,
	count:  int,
}

// hash_prefix_compare orders a hash against a prefix: 0 when the hash starts
// with the prefix.
hash_prefix_compare :: proc(hash: blake3.Hash, prefix: Hash_Prefix) -> int {
	for index in 0 ..< prefix.count {
		digit := index % 2 == 0 ? hash[index / 2] >> 4 : hash[index / 2] & 0x0F
		if digit != prefix.digits[index] {
			return digit < prefix.digits[index] ? -1 : 1
		}
	}
	return 0
}

// sorted_names_with_prefix gives the place of the first name that starts
// with the prefix and the count of those names: two binary searches.
sorted_names_with_prefix :: proc(names: []blake3.Hash, prefix: Hash_Prefix) -> (first: int, count: int) {
	low, high := 0, len(names)
	for low < high {
		middle := low + (high - low) / 2
		if hash_prefix_compare(names[middle], prefix) < 0 {
			low = middle + 1
		} else {
			high = middle
		}
	}
	first = low
	high = len(names)
	for low < high {
		middle := low + (high - low) / 2
		if hash_prefix_compare(names[middle], prefix) <= 0 {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return first, low - first
}

// The names of a search: at most BROWSE_SEARCH_ROWS of each, and the count
// of all that match.
Cache_Search_Result :: struct {
	objects:            [BROWSE_SEARCH_ROWS]blake3.Hash,
	object_count:       int,
	objects_shown:      int,
	realisations:       [BROWSE_SEARCH_ROWS]blake3.Hash,
	realisation_count:  int,
	realisations_shown: int,
}

// cache_status_search copies the names that start with the prefix, under the
// lock: no work in proportion to the store.
cache_status_search :: proc(status: ^Cache_Status, prefix: Hash_Prefix) -> (result: Cache_Search_Result) {
	sync.mutex_lock(&status.lock)
	defer sync.mutex_unlock(&status.lock)
	first, count := sorted_names_with_prefix(status.object_names[:], prefix)
	result.object_count = count
	result.objects_shown = min(count, BROWSE_SEARCH_ROWS)
	copy(result.objects[:result.objects_shown], status.object_names[first:first + result.objects_shown])
	first, count = sorted_names_with_prefix(status.realisation_names[:], prefix)
	result.realisation_count = count
	result.realisations_shown = min(count, BROWSE_SEARCH_ROWS)
	copy(result.realisations[:result.realisations_shown], status.realisation_names[first:first + result.realisations_shown])
	return result
}

// The release pointers of the page: the newest BROWSE_RELEASE_ROWS, newest
// first, and the count of all.
Cache_Release_Rows :: struct {
	rows:  [BROWSE_RELEASE_ROWS]Kept_Release_Pointer,
	shown: int,
	total: int,
}

cache_status_release_rows :: proc(status: ^Cache_Status) -> (rows: Cache_Release_Rows) {
	sync.mutex_lock(&status.lock)
	defer sync.mutex_unlock(&status.lock)
	rows.total = len(status.release_pointers)
	rows.shown = min(rows.total, BROWSE_RELEASE_ROWS)
	for index in 0 ..< rows.shown {
		rows.rows[index] = status.release_pointers[rows.total - 1 - index]
	}
	return rows
}

// The answer of the store to a put of a release pointer.
Release_Pointer_Put :: enum u8 {
	Added,
	Held_Already, // The same record: the put changes nothing.
	Number_Not_Higher, // The number is not higher than the highest of its publisher and name.
	Not_Written,
}

// cache_status_release_pointer_put checks the number of a pointer against
// the pointers of its publisher and name, writes its file and keeps it. The
// lock is held from the check to the keep, so two puts of one name cannot
// both pass the check.
cache_status_release_pointer_put :: proc(server: ^Cache_Server, pointer: object_cache.Release_Pointer, encoded: []u8, written: time.Time) -> Release_Pointer_Put {
	status := &server.status
	record_hash := blake3.hash(encoded)
	sync.mutex_lock(&status.lock)
	defer sync.mutex_unlock(&status.lock)
	pointer_copy := pointer
	for &kept in status.release_pointers {
		if kept.record_hash == record_hash {
			return .Held_Already
		}
	}
	for &kept in status.release_pointers {
		if kept.pointer.publisher_public_key == pointer.publisher_public_key && object_cache.release_pointer_name(&kept.pointer) == object_cache.release_pointer_name(&pointer_copy) && kept.pointer.number >= pointer.number {
			return .Number_Not_Higher
		}
	}
	hex := hash_to_hex(record_hash)
	file_written, _ := store_write_atomic(server, .Release_Pointers, string(hex[:]), encoded)
	if !file_written {
		return .Not_Written
	}
	append(&status.release_pointers, Kept_Release_Pointer{pointer = pointer, record_hash = record_hash, written = written})
	status.counts.last_write = time_later(status.counts.last_write, written)
	return .Added
}

// cache_status_release_pointer_highest gives the pointer of a publisher and
// a name with the highest number.
cache_status_release_pointer_highest :: proc(status: ^Cache_Status, publisher: [object_cache.PUBLIC_KEY_SIZE]u8, name: string) -> (pointer: object_cache.Release_Pointer, found: bool) {
	sync.mutex_lock(&status.lock)
	defer sync.mutex_unlock(&status.lock)
	for &kept in status.release_pointers {
		if kept.pointer.publisher_public_key != publisher || object_cache.release_pointer_name(&kept.pointer) != name {
			continue
		}
		if !found || kept.pointer.number > pointer.number {
			pointer = kept.pointer
			found = true
		}
	}
	return pointer, found
}

// cache_status_record_object counts one object that the server wrote. added
// is false when the store held the name: the same object again adds nothing.
cache_status_record_object :: proc(status: ^Cache_Status, name: blake3.Hash, size: u64, added: bool, written: time.Time) {
	sync.mutex_lock(&status.lock)
	defer sync.mutex_unlock(&status.lock)
	if added {
		status.counts.objects += 1
		status.counts.object_bytes += size
		sorted_names_insert(&status.object_names, name)
	}
	if size > status.counts.largest_object_bytes {
		status.counts.largest_object_bytes = size
	}
	status.counts.last_write = time_later(status.counts.last_write, written)
}

// cache_status_record_damaged counts one object that moved from objects/ to
// damaged/. The largest size stays: it is the largest object that the store
// held since the start, and the listing of the next start gives it again.
cache_status_record_damaged :: proc(status: ^Cache_Status, size: u64, moved: time.Time) {
	sync.mutex_lock(&status.lock)
	defer sync.mutex_unlock(&status.lock)
	if status.counts.objects > 0 {
		status.counts.objects -= 1
	}
	status.counts.object_bytes -= min(size, status.counts.object_bytes)
	status.counts.damaged_objects += 1
	status.counts.last_write = time_later(status.counts.last_write, moved)
}

// cache_status_record_realisation counts one realisation that the server
// wrote and puts it at the top of the list.
cache_status_record_realisation :: proc(status: ^Cache_Status, record: object_cache.Realisation_Record, added: bool, written: time.Time) {
	sync.mutex_lock(&status.lock)
	defer sync.mutex_unlock(&status.lock)
	if added {
		status.counts.realisations += 1
		status.counts.realisation_bytes += object_cache.REALISATION_WIRE_SIZE
		sorted_names_insert(&status.realisation_names, record.recipe_hash)
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
	object_names := make([dynamic]blake3.Hash)
	realisation_names := make([dynamic]blake3.Hash)
	release_pointers := make([dynamic]Kept_Release_Pointer)
	kept := false
	defer if !kept {
		delete(object_names)
		delete(realisation_names)
		delete(release_pointers)
	}

	for directory in ([3]Store_Directory{.Objects, .Realisations, .Damaged}) {
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
			name, _ := decode_hex_32(entry.name)
			switch directory {
			case .Objects:
				counts.objects += 1
				counts.object_bytes += u64(entry.size)
				append(&object_names, name)
				if u64(entry.size) > counts.largest_object_bytes {
					counts.largest_object_bytes = u64(entry.size)
				}
			case .Realisations:
				counts.realisations += 1
				counts.realisation_bytes += u64(entry.size)
				append(&realisation_names, name)
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
			case .Damaged:
				counts.damaged_objects += 1
			case .Temp, .Outboards, .Recipes, .Release_Pointers:
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

	// The listing gives the names in no order: one sort at the start.
	slice.sort_by_cmp(object_names[:], hash_compare)
	slice.sort_by_cmp(realisation_names[:], hash_compare)
	if !cache_status_scan_release_pointers(server, &release_pointers, &counts) {
		return false
	}

	sync.mutex_lock(&status.lock)
	defer sync.mutex_unlock(&status.lock)
	status.counts = counts
	status.recent = recent
	status.recent_count = recent_count
	delete(status.object_names)
	delete(status.realisation_names)
	delete(status.release_pointers)
	status.object_names = object_names
	status.realisation_names = realisation_names
	status.release_pointers = release_pointers
	kept = true
	return true
}

// cache_status_scan_release_pointers reads each file of the release
// pointers, at the start: a release adds one file of 208 bytes. A file whose
// name is not the hash of its bytes, that does not decode, or whose
// signature does not verify, is not kept. A listing cut short refuses the
// open, as for the other folders.
@(private = "file")
cache_status_scan_release_pointers :: proc(server: ^Cache_Server, release_pointers: ^[dynamic]Kept_Release_Pointer, counts: ^Store_Counts) -> bool {
	path := strings.concatenate({server.root_directory, "/", store_directory_name(.Release_Pointers)}, context.temp_allocator)
	folder, open_error := os.open(path)
	if open_error != nil {
		return false
	}
	defer os.close(folder)
	iterator := os.read_directory_iterator_create(folder)
	defer os.read_directory_iterator_destroy(&iterator)
	for entry in os.read_directory_iterator(&iterator) {
		if entry.type != .Regular || !hex_hash_valid(entry.name) || entry.size != object_cache.RELEASE_POINTER_WIRE_SIZE {
			continue
		}
		data, found, read_ok := store_read_by_hex(server, .Release_Pointers, entry.name, context.temp_allocator)
		if !read_ok || !found {
			continue
		}
		record_hash := blake3.hash(data)
		record_hex := hash_to_hex(record_hash)
		if string(record_hex[:]) != entry.name {
			continue
		}
		pointer, refusal := object_cache.decode_release_pointer(data)
		if refusal != .None {
			continue
		}
		signing_bytes, signing_ok := object_cache.release_pointer_signing_bytes(&pointer)
		if !signing_ok || !cache_server_verify_ed25519(pointer.publisher_public_key, signing_bytes[:], pointer.signature) {
			continue
		}
		append(release_pointers, Kept_Release_Pointer{pointer = pointer, record_hash = record_hash, written = entry.modification_time})
		counts.last_write = time_later(counts.last_write, entry.modification_time)
	}
	if _, iterator_error := os.read_directory_iterator_error(&iterator); iterator_error != nil {
		return false
	}
	slice.sort_by(release_pointers[:], proc(left, right: Kept_Release_Pointer) -> bool {
		return time.diff(left.written, right.written) > 0
	})
	return true
}

// cache_status_destroy frees the names and the pointers that the status
// keeps.
cache_status_destroy :: proc(status: ^Cache_Status) {
	delete(status.object_names)
	delete(status.realisation_names)
	delete(status.release_pointers)
	status.object_names = nil
	status.realisation_names = nil
	status.release_pointers = nil
}
