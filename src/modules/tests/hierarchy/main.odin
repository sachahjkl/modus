// A test of the trees of a store (docs/STORAGE.md): many entries in trees inside trees, a listing in pages, a rename, the removal of a tree, and a handle on a part of the store that reaches nothing outside it.
//
// The first run (an empty store) makes 100 trees of 10 trees of 100 objects, one commit for each 100 entries, and checks each case. The second run, on the same disk after a new start of the machine, checks the counts and the contents that the first run left. Each case ends with a line "...: as it must", or a line "...: WRONG". The times are measures: no case checks a speed.
//
// **What it is for.** It checks that a [store](term:store) holds a large
// [tree](term:tree) of entries across a restart of the machine, and that a
// handle on a part of the store reaches nothing outside that part. A
// process sees only its [private store](term:private-store); inside it, a
// tree is the unit that a process lends to a part of itself.
//
// **What a reader sees.** It has no window and no menu line: the machine
// test starts it with `start("hierarchy")` on a machine with a data disk,
// two times. Each case writes one log fact of its own type, `hierarchy:
// <case>: as it must`, or `hierarchy: <case>: WRONG` at the level error;
// `where(verdict = "WRONG")` keeps the cases that failed. The first run
// writes `hierarchy: a new store: the first run`, and the time to make the
// 100 000 objects.
//
// **Its grant**: **Store**, its private store in the storage service.
package hierarchy

import "modus:contract/errors"
import "modus:contract/storage_status"
import format "modus:contract/store"
import "modus:storage"
import "modus:system"

STORE_NAME :: "hierarchy" // Its private store: the root service names it after the process.
TOP_TREES :: 100
PARTS :: 10
OBJECTS_IN_PART :: 100
MADE_OBJECTS :: TOP_TREES * PARTS * OBJECTS_IN_PART // 100000
PAGE_ROWS :: 16

// The names that go into one tree in a scrambled order: enough leaves for
// the branches to split, and for the root to be a branch of branches.
SCRAMBLED_NAMES :: 6000
// The order of the adds: the name of the number (n * ADD_STEP + 17) mod
// SCRAMBLED_NAMES for n from 0. The order of the removes: (n * REMOVE_STEP)
// mod SCRAMBLED_NAMES, the even numbers only. Each step is a prime that does
// not divide SCRAMBLED_NAMES, so each order names each number once, with no
// random source: a run is the same at each start.
ADD_STEP :: 4099
REMOVE_STEP :: 1777
SCRAMBLED_LEFT :: SCRAMBLED_NAMES / 2

// What the first run leaves: the objects made, one object "content" in
// each top tree, one object written through a share, less the tree
// "tree_002" with its 10 trees, its 1000 objects and its content; and the
// tree "scrambled" with the odd half of its names.
OBJECTS_LEFT :: MADE_OBJECTS + TOP_TREES + 1 - (PARTS * OBJECTS_IN_PART + 1) + SCRAMBLED_LEFT
TREES_LEFT :: TOP_TREES + TOP_TREES * PARTS - (1 + PARTS) + 1

client: storage.Client
wrong_cases: int

// number_name writes a name of a prefix and a number of three digits, so
// that the order of the names is the order of the numbers.
number_name :: proc "contextless" (buffer: []u8, prefix: string, number: int) -> string {
	count := copy(buffer[:], prefix)
	buffer[count] = u8('0' + number / 100 % 10)
	buffer[count + 1] = u8('0' + number / 10 % 10)
	buffer[count + 2] = u8('0' + number % 10)
	return string(buffer[:count + 3])
}

// scrambled_name writes the name of a number of five digits.
scrambled_name :: proc "contextless" (buffer: []u8, number: int) -> string {
	count := copy(buffer[:], "s_")
	divisor := 10000
	for _ in 0 ..< 5 {
		buffer[count] = u8('0' + number / divisor % 10)
		count += 1
		divisor /= 10
	}
	return string(buffer[:count])
}

// refused_with says if a call failed with an error kind.
refused_with :: proc "contextless" (status: storage_status.Status, error: ^errors.Error_Record, kind: errors.Kind) -> bool {
	return status == .Failed && error.kind == i64(kind)
}

// count_entries counts the entries of the tree of a place, page by page,
// and checks that each page continues the order of the one before.
count_entries :: proc "contextless" (connection: ^storage.Client, place: storage.Place) -> (objects: int, trees: int, in_order: bool, status: storage_status.Status) {
	rows: [PAGE_ROWS]storage.Listed
	names: [PAGE_ROWS * 64]u8
	last: [64]u8
	last_count := 0
	in_order = true
	for {
		page: []storage.Listed
		page, status = storage.list(connection, place, string(last[:last_count]), rows[:], names[:])
		if status != .Ok {
			return
		}
		if len(page) == 0 {
			return
		}
		for row in page {
			name := names[row.name_offset:][:row.name_count]
			if last_count != 0 && !name_after(name, last[:last_count]) {
				in_order = false
			}
			last_count = copy(last[:], name)
			// A kind that names no entry is a fault of the service: it is
			// counted as neither.
			kind, kind_ok := storage.entry_kind_of_word(row.kind)
			if !kind_ok {
				status = .Failed
				return
			}
			switch kind {
			case .Tree:
				trees += 1
			case .Object:
				objects += 1
			case .None:
				status = .Failed
				return
			}
		}
	}
}

name_after :: proc "contextless" (name, before: []u8) -> bool {
	for index in 0 ..< min(len(name), len(before)) {
		if name[index] != before[index] {
			return name[index] > before[index]
		}
	}
	return len(name) > len(before)
}

// add_names makes entries of one kind under a place, in one commit.
add_names :: proc "contextless" (place: storage.Place, prefix: string, count: int, kind: storage.Entry_Kind) -> (storage_status.Status, i64) {
	rows: [OBJECTS_IN_PART]storage.Add_Row
	names: [OBJECTS_IN_PART * 16]u8
	used := 0
	for number in 0 ..< count {
		buffer: [16]u8
		name := number_name(buffer[:], prefix, number)
		rows[number] = {name_offset = i64(used), name_count = i64(len(name)), kind = i64(kind)}
		used += copy(names[used:], name)
	}
	error: errors.Error_Record
	generation, status := storage.add(&client, place, rows[:count], names[:used], &error)
	return status, generation
}

first_run :: proc "contextless" () {
	start := system.time()
	if status, _ := add_names(storage.ROOT, "tree_", TOP_TREES, .Tree); status != .Ok {
		verdict := outcome(false)
		system.log_fact(verdict.level, Top_Trees_Refused{status = storage_status.Status_Word(status), verdict = verdict.words})
		return
	}
	commits: u64 = 1
	for top in 0 ..< TOP_TREES {
		buffer: [16]u8
		top_place, status := storage.open_tree(&client, storage.ROOT, number_name(buffer[:], "tree_", top))
		if status != .Ok {
			verdict := outcome(false)
			system.log_fact(verdict.level, Top_Tree_Open_Refused{status = storage_status.Status_Word(status), verdict = verdict.words})
			return
		}
		add_names(top_place, "part_", PARTS, .Tree)
		commits += 1
		for part in 0 ..< PARTS {
			part_buffer: [16]u8
			part_place, part_status := storage.open_tree(&client, top_place, number_name(part_buffer[:], "part_", part))
			if part_status != .Ok {
				verdict := outcome(false)
				system.log_fact(verdict.level, Part_Open_Refused{status = storage_status.Status_Word(part_status), verdict = verdict.words})
				return
			}
			if add_status, _ := add_names(part_place, "object_", OBJECTS_IN_PART, .Object); add_status != .Ok {
				verdict := outcome(false)
				system.log_fact(verdict.level, Part_Objects_Refused{status = storage_status.Status_Word(add_status), verdict = verdict.words})
				return
			}
			commits += 1
			storage.close_tree(&client, part_place)
		}
		content_name: [32]u8
		content: [32]u8
		text := number_name(content_name[:], "content of tree_", top)
		count := copy(content[:], text)
		storage.write(&client, top_place, "content", content[:count])
		commits += 1
		storage.close_tree(&client, top_place)
		if (top + 1) % 10 == 0 {
			system.log_fact(.Info, Objects_Made{objects = i64((top + 1) * PARTS * OBJECTS_IN_PART), commits = commits, elapsed = elapsed_since(start)})
		}
	}
	counts, _ := storage.usage(&client)
	{
		verdict := outcome(counts.objects == MADE_OBJECTS + TOP_TREES && counts.trees == TOP_TREES + TOP_TREES * PARTS)
		system.log_fact(verdict.level, Trees_Made{objects = counts.objects, trees = counts.trees, commits = commits, elapsed = elapsed_since(start), blocks = counts.blocks, verdict = verdict.words})
	}

	// The listing: the root in pages, one part, then every part.
	listing_start := system.time()
	objects, trees, in_order, status := count_entries(&client, storage.ROOT)
	{
		verdict := outcome(status == .Ok && trees == TOP_TREES && objects == 0 && in_order)
		system.log_fact(verdict.level, Root_Listed{trees = i64(trees), verdict = verdict.words})
	}
	all_objects := 0
	all_in_order := true
	for top in 0 ..< TOP_TREES {
		buffer: [16]u8
		top_place, _ := storage.open_tree(&client, storage.ROOT, number_name(buffer[:], "tree_", top))
		for part in 0 ..< PARTS {
			part_buffer: [16]u8
			part_place, _ := storage.open_tree(&client, top_place, number_name(part_buffer[:], "part_", part))
			part_objects, _, part_in_order, _ := count_entries(&client, part_place)
			all_objects += part_objects
			all_in_order &&= part_in_order
			storage.close_tree(&client, part_place)
		}
		storage.close_tree(&client, top_place)
	}
	{
		verdict := outcome(all_objects == MADE_OBJECTS && all_in_order)
		system.log_fact(verdict.level, Parts_Listed{objects = i64(all_objects), trees = i64(TOP_TREES * PARTS), elapsed = elapsed_since(listing_start), verdict = verdict.words})
	}

	// Rename: an object up two trees, and a tree with all under it.
	tree_0, _ := storage.open_tree(&client, storage.ROOT, "tree_000")
	part_0, _ := storage.open_tree(&client, tree_0, "part_000")
	error: errors.Error_Record
	_, status = storage.rename(&client, part_0, "object_000", storage.ROOT, "moved", &error)
	moved_objects, _, _, _ := count_entries(&client, part_0)
	_, found_moved, _ := storage.read(&client, storage.ROOT, "moved", nil)
	{
		verdict := outcome(status == .Ok && moved_objects == OBJECTS_IN_PART - 1 && found_moved)
		system.log_fact(verdict.level, Object_Renamed{objects = i64(moved_objects), verdict = verdict.words})
	}
	_, status = storage.rename(&client, storage.ROOT, "tree_001", tree_0, "tree_001_moved", &error)
	moved_tree, tree_status := storage.open_tree(&client, tree_0, "tree_001_moved")
	_, moved_parts, _, _ := count_entries(&client, moved_tree)
	{
		verdict := outcome(status == .Ok && tree_status == .Ok && moved_parts == PARTS)
		system.log_fact(verdict.level, Tree_Renamed{trees = i64(PARTS), objects = i64(PARTS * OBJECTS_IN_PART), verdict = verdict.words})
	}
	storage.close_tree(&client, moved_tree)
	error = {}
	_, status = storage.rename(&client, storage.ROOT, "tree_000", part_0, "inside", &error)
	{
		verdict := outcome(refused_with(status, &error, .Bad_Value))
		system.log_fact(verdict.level, Move_Inside_Refused{verdict = verdict.words})
	}
	error = {}
	_, status = storage.rename(&client, storage.ROOT, "moved", storage.ROOT, "tree_003", &error)
	{
		verdict := outcome(refused_with(status, &error, .Exists))
		system.log_fact(verdict.level, Rename_Onto_Name_Refused{verdict = verdict.words})
	}
	storage.close_tree(&client, part_0)
	storage.close_tree(&client, tree_0)

	// The removal of a tree: one commit, then steps while no call waits.
	before, _ := storage.usage(&client)
	removal_start := system.time()
	_, status = storage.remove(&client, storage.ROOT, "tree_002", &error)
	after, _ := storage.usage(&client)
	_, top_trees, _, _ := count_entries(&client, storage.ROOT)
	{
		verdict := outcome(status == .Ok && top_trees == TOP_TREES - 2)
		system.log_fact(verdict.level, Tree_Removed{removing = after.removing, verdict = verdict.words})
	}
	for {
		counts, _ = storage.usage(&client)
		if counts.removing == 0 || system.time() - removal_start > system.TEST_HANG_BOUND_MILLISECONDS {
			break
		}
		system.sleep(system.time() + 1)
	}
	{
		verdict := outcome(counts.removing == 0 && counts.objects == before.objects - (PARTS * OBJECTS_IN_PART + 1) && counts.trees == before.trees - (1 + PARTS) && counts.blocks < before.blocks)
		system.log_fact(verdict.level, Removal_Freed{objects = before.objects - counts.objects, trees = before.trees - counts.trees, blocks = before.blocks - counts.blocks, elapsed = elapsed_since(removal_start), verdict = verdict.words})
	}

	scrambled_case()
	confinement()
	counts, _ = storage.usage(&client)
	{
		verdict := outcome(counts.objects == OBJECTS_LEFT && counts.trees == TREES_LEFT)
		system.log_fact(verdict.level, First_Run_Left{objects = counts.objects, trees = counts.trees, verdict = verdict.words})
	}
}

// scrambled_case adds names to one tree in an order that is not the order
// of the names, so that leaves and branches split in their middle and the
// root splits; reads each one back; then removes half of them in another
// order, so that leaves and branches merge and take records from their
// siblings.
scrambled_case :: proc "contextless" () {
	start := system.time()
	tree_row := [1]storage.Add_Row{{name_offset = 0, name_count = 9, kind = i64(storage.Entry_Kind.Tree)}}
	tree_name := "scrambled"
	_, status := storage.add(&client, storage.ROOT, tree_row[:], transmute([]u8)tree_name)
	place, open_status := storage.open_tree(&client, storage.ROOT, "scrambled")
	if status != .Ok || open_status != .Ok {
		verdict := outcome(false)
		system.log_fact(verdict.level, Scrambled_Tree_Refused{status = storage_status.Status_Word(status), open_status = storage_status.Status_Word(open_status), verdict = verdict.words})
		return
	}
	rows: [250]storage.Add_Row
	names: [250 * 8]u8
	commits: u64
	for first := 0; first < SCRAMBLED_NAMES; first += len(rows) {
		used := 0
		count := min(len(rows), SCRAMBLED_NAMES - first)
		for row in 0 ..< count {
			buffer: [8]u8
			name := scrambled_name(buffer[:], ((first + row) * ADD_STEP + 17) % SCRAMBLED_NAMES)
			rows[row] = {name_offset = i64(used), name_count = i64(len(name)), kind = i64(storage.Entry_Kind.Object)}
			used += copy(names[used:], name)
		}
		if _, add_status := storage.add(&client, place, rows[:count], names[:used]); add_status != .Ok {
			verdict := outcome(false)
			system.log_fact(verdict.level, Scrambled_Adds_Refused{status = storage_status.Status_Word(add_status), verdict = verdict.words})
			return
		}
		commits += 1
	}
	objects, _, in_order, _ := count_entries(&client, place)
	found_all := true
	for number in 0 ..< SCRAMBLED_NAMES {
		buffer: [8]u8
		_, found, _ := storage.read(&client, place, scrambled_name(buffer[:], number), nil)
		found_all &&= found
	}
	removed := 0
	for step in 0 ..< SCRAMBLED_NAMES {
		number := step * REMOVE_STEP % SCRAMBLED_NAMES
		if number % 2 != 0 {
			continue
		}
		buffer: [8]u8
		if _, remove_status := storage.remove(&client, place, scrambled_name(buffer[:], number)); remove_status == .Ok {
			removed += 1
		}
	}
	left, _, left_in_order, _ := count_entries(&client, place)
	even_buffer, odd_buffer: [8]u8
	_, even_found, _ := storage.read(&client, place, scrambled_name(even_buffer[:], 2), nil)
	_, odd_found, _ := storage.read(&client, place, scrambled_name(odd_buffer[:], 3), nil)
	storage.close_tree(&client, place)
	verdict := outcome(objects == SCRAMBLED_NAMES && in_order && found_all && removed == SCRAMBLED_LEFT && left == SCRAMBLED_LEFT && left_in_order && !even_found && odd_found)
	system.log_fact(verdict.level, Scrambled_Names_Checked{added = i64(objects), commits = commits, removed = i64(removed), left = i64(left), elapsed = elapsed_since(start), verdict = verdict.words})
}

// The bytes that the holder of a writable share of a tree writes, and that
// the maker writes too while the share is open (docs/STORAGE.md, "4.7 The
// same object one time"): three blocks of data under one object node.
GUESS_BLOCKS :: 3
GUESS_HELD :: GUESS_BLOCKS + 1
GUESS_SIZE :: GUESS_BLOCKS * format.BLOCK_SIZE

guess_bytes: [GUESS_SIZE]u8

// share_and_same_bytes: while a writable share of a tree is open, the holder
// writes bytes, and the maker writes the same bytes outside the tree. The
// share sees the count of its own tree only: its write adds the blocks of
// its object, the write of the maker adds nothing to it, and its removal
// takes its blocks back. The maker writes with no lookup, so its write
// takes its own blocks of the store. The maker removes its copy, so that
// the counts of the first run stay. Last, the holder writes a guess that
// stays after unshare (guess_hidden_after_unshare).
share_and_same_bytes :: proc "contextless" (writable: ^storage.Client, maker_place: storage.Place) {
	for &byte, index in guess_bytes {
		byte = u8(index % 251 + 1)
	}
	tree_before, tree_status := storage.usage(writable)
	_, share_write := storage.write(writable, storage.ROOT, "guess", guess_bytes[:])
	tree_after_share, _ := storage.usage(writable)
	store_after_share, store_status := storage.usage(&client)
	_, maker_write := storage.write(&client, maker_place, "same_bytes", guess_bytes[:])
	tree_after_maker, _ := storage.usage(writable)
	store_after_maker, _ := storage.usage(&client)
	_, share_remove := storage.remove(writable, storage.ROOT, "guess")
	tree_after_remove, _ := storage.usage(writable)
	_, maker_remove := storage.remove(&client, maker_place, "same_bytes")
	_, kept_write := storage.write(writable, storage.ROOT, "kept_guess", guess_bytes[:])
	statuses := tree_status == .Ok && store_status == .Ok && share_write == .Ok && maker_write == .Ok && share_remove == .Ok && maker_remove == .Ok && kept_write == .Ok
	share_took := tree_after_share.blocks - tree_before.blocks
	maker_took := store_after_maker.blocks - store_after_share.blocks
	share_saw := tree_after_maker.blocks - tree_after_share.blocks
	freed := tree_after_maker.blocks - tree_after_remove.blocks
	counted := tree_before.blocks != storage.USAGE_NOT_COUNTED && tree_before.removing == 0
	verdict := outcome(statuses && counted && share_took == GUESS_HELD && maker_took == GUESS_HELD && share_saw == 0 && freed == GUESS_HELD)
	system.log_fact(verdict.level, Share_Count_Checked{share_took = share_took, maker_took = maker_took, share_saw = share_saw, freed = freed, verdict = verdict.words})
}

// guess_hidden_after_unshare: the guess that the holder wrote while its
// share was open stays out of the hash index after unshare, so the same
// bytes written by the maker take their own blocks. Both objects go after
// it, so that the counts of the first run stay.
guess_hidden_after_unshare :: proc "contextless" (share_place: storage.Place, maker_place: storage.Place) {
	before, before_status := storage.usage(&client)
	_, maker_write := storage.write(&client, maker_place, "same_bytes", guess_bytes[:])
	after, _ := storage.usage(&client)
	_, maker_remove := storage.remove(&client, maker_place, "same_bytes")
	_, guess_remove := storage.remove(&client, share_place, "kept_guess")
	took := after.blocks - before.blocks
	verdict := outcome(before_status == .Ok && maker_write == .Ok && maker_remove == .Ok && guess_remove == .Ok && took == GUESS_HELD)
	system.log_fact(verdict.level, Guess_Hidden{maker_took = took, verdict = verdict.words})
}

// confinement: a share reaches the tree of its place and nothing outside
// it; a read-only share changes nothing; unshare ends it.
confinement :: proc "contextless" () {
	tree_3, _ := storage.open_tree(&client, storage.ROOT, "tree_003")
	tree_4, _ := storage.open_tree(&client, storage.ROOT, "tree_004")
	shared, number, status := storage.share(&client, tree_3, true)
	{
		verdict := outcome(status == .Ok)
		system.log_fact(verdict.level, Read_Only_Share_Made{verdict = verdict.words})
	}
	if status != .Ok {
		return
	}
	_, parts, _, _ := count_entries(&shared, storage.ROOT)
	{
		verdict := outcome(parts == PARTS)
		system.log_fact(verdict.level, Share_Listed{trees = i64(parts), verdict = verdict.words})
	}
	for name in ([]string{"..", ".", "/tree_004", "part_000/../..", "../tree_004"}) {
		error: errors.Error_Record
		_, _, read_status := storage.read(&shared, storage.ROOT, name, nil, &error)
		verdict := outcome(refused_with(read_status, &error, .Bad_Byte))
		system.log_fact(verdict.level, Name_Refused{name = name_field(name), verdict = verdict.words})
	}
	error: errors.Error_Record
	_, _, read_status := storage.read(&shared, tree_4, "content", nil, &error)
	{
		verdict := outcome(refused_with(read_status, &error, .Absent) && errors.Unit(error.unit) == .Places)
		system.log_fact(verdict.level, Foreign_Place_Refused{verdict = verdict.words})
	}
	// Another store: a share does not act for a principal.
	error = {}
	_, store_status := storage.open_store(&shared, "notes", &error)
	{
		verdict := outcome(refused_with(store_status, &error, .No_Grant) && errors.Unit(error.unit) == .Acts_For_Principal)
		system.log_fact(verdict.level, Foreign_Store_Refused{verdict = verdict.words})
	}
	error = {}
	_, write_status := storage.write(&shared, storage.ROOT, "written", transmute([]u8)string("no"), &error)
	{
		verdict := outcome(refused_with(write_status, &error, .No_Grant) && errors.Unit(error.unit) == .Changes)
		system.log_fact(verdict.level, Read_Only_Write_Refused{verdict = verdict.words})
	}
	error = {}
	_, remove_status := storage.remove(&shared, storage.ROOT, "part_000", &error)
	{
		verdict := outcome(refused_with(remove_status, &error, .No_Grant))
		system.log_fact(verdict.level, Read_Only_Remove_Refused{verdict = verdict.words})
	}
	storage.unshare(&client, number)
	_, _, ended_status := storage.read(&shared, storage.ROOT, "content", nil)
	{
		verdict := outcome(ended_status == .Gone)
		system.log_fact(verdict.level, Share_Handles_Revoked{verdict = verdict.words})
	}

	tree_5, _ := storage.open_tree(&client, storage.ROOT, "tree_005")
	writable, writable_number, writable_status := storage.share(&client, tree_5, false)
	_, written_status := storage.write(&writable, storage.ROOT, "written_through_a_share", transmute([]u8)string("kept"))
	text: [8]u8
	bytes, found, _ := storage.read(&client, tree_5, "written_through_a_share", text[:])
	{
		verdict := outcome(writable_status == .Ok && written_status == .Ok && found && string(bytes) == "kept")
		system.log_fact(verdict.level, Writable_Share_Written{verdict = verdict.words})
	}
	// A share of a tree never gets a place on the root of its store.
	error = {}
	_, own_status := storage.open_store(&writable, STORE_NAME, &error)
	{
		verdict := outcome(refused_with(own_status, &error, .No_Grant) && errors.Unit(error.unit) == .Acts_For_Principal)
		system.log_fact(verdict.level, Share_Root_Refused{verdict = verdict.words})
	}
	share_and_same_bytes(&writable, tree_4)
	storage.unshare(&client, writable_number)
	guess_hidden_after_unshare(tree_5, tree_4)
	storage.close_tree(&client, tree_3)
	storage.close_tree(&client, tree_4)
	storage.close_tree(&client, tree_5)
}

// second_run checks what the first run left, after a new start of the
// machine: the open of the disk read every tree again.
second_run :: proc "contextless" (counts: storage.Usage) {
	start := system.time()
	{
		verdict := outcome(counts.objects == OBJECTS_LEFT && counts.trees == TREES_LEFT && counts.removing == 0)
		system.log_fact(verdict.level, Remount_Counted{objects = counts.objects, trees = counts.trees, verdict = verdict.words})
	}
	total_objects := 0
	contents_good := 0
	for top in 0 ..< TOP_TREES {
		buffer: [16]u8
		top_place, status := storage.open_tree(&client, storage.ROOT, number_name(buffer[:], "tree_", top))
		if status != .Ok {
			continue
		}
		for part in 0 ..< PARTS {
			part_buffer: [16]u8
			part_place, part_status := storage.open_tree(&client, top_place, number_name(part_buffer[:], "part_", part))
			if part_status != .Ok {
				continue
			}
			part_objects, _, _, _ := count_entries(&client, part_place)
			total_objects += part_objects
			storage.close_tree(&client, part_place)
		}
		content: [32]u8
		bytes, found, _ := storage.read(&client, top_place, "content", content[:])
		expected_buffer: [32]u8
		if found && string(bytes) == number_name(expected_buffer[:], "content of tree_", top) {
			contents_good += 1
		}
		storage.close_tree(&client, top_place)
	}
	// The odd half of the scrambled names, in order.
	scrambled, _ := storage.open_tree(&client, storage.ROOT, "scrambled")
	scrambled_left, _, scrambled_in_order, _ := count_entries(&client, scrambled)
	{
		verdict := outcome(scrambled_left == SCRAMBLED_LEFT && scrambled_in_order)
		system.log_fact(verdict.level, Remount_Scrambled_Left{left = i64(scrambled_left), verdict = verdict.words})
	}
	// tree_001 is inside tree_000 now, with its parts.
	tree_0, _ := storage.open_tree(&client, storage.ROOT, "tree_000")
	moved, _ := storage.open_tree(&client, tree_0, "tree_001_moved")
	_, moved_parts, _, _ := count_entries(&client, moved)
	_, found_moved, _ := storage.read(&client, storage.ROOT, "moved", nil)
	// The parts of the 98 top trees, less the object that moved to the root.
	expected := (TOP_TREES - 2) * PARTS * OBJECTS_IN_PART - 1
	{
		verdict := outcome(total_objects == expected && contents_good == TOP_TREES - 2 && moved_parts == PARTS && found_moved)
		system.log_fact(verdict.level, Remount_Parts_Listed{objects = i64(total_objects), contents = i64(contents_good), elapsed = elapsed_since(start), verdict = verdict.words})
	}
}

// entry connects to the private store and reads its usage. On an empty
// store it runs the first run: it makes the trees, then checks each case.
// On a store that the first run filled it runs the second run: it checks
// the counts and the contents. Each case writes its line on the log. The
// process then stops with `Done` when each case held, else with `Failed`.
// With no store or no usage, it writes `hierarchy: WRONG: no store` (or `no
// usage`) at the level error, and stops with `Failed`.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	ok: bool
	if client, ok = storage.open(ctx); !ok {
		system.log_fact(.Error, Wrong_No_Store{})
		system.stop(.Failed)
	}
	counts, status := storage.usage(&client)
	if status != .Ok {
		system.log_fact(.Error, Wrong_No_Usage{})
		system.stop(.Failed)
	}
	if counts.objects == 0 {
		system.log_fact(.Info, First_Run{})
		first_run()
	} else {
		system.log_fact(.Info, Store_Remounted{objects = counts.objects})
		second_run(counts)
	}
	system.log_fact(.Info, Run_Done{wrong_cases = u64(wrong_cases)})
	if wrong_cases != 0 {
		system.stop(.Failed)
	}
	system.stop(.Done)
}
