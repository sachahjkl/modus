package build

import module "modus:contract/module"
import "modus:contract/value_kinds"
import "modus:sentence"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The log facts of the storage service and of the block service against the
// lines that they replaced (src/md/features/log_facts.md, "The facts of the
// storage service and of the disk"). The fact types come from the
// extraction of the tool on the sources of each module: a host test does
// not depend on a build. Each sentence is compared with the parts of the
// old line written by sentence.format, at the edges of each field.

// The longest store name (store.NAME_CAPACITY) and the longest object name
// (store.ENTRY_NAME_CAPACITY), which a text view carries.
@(private = "file")
STORE_NAME_BYTES_MOST :: 32
@(private = "file")
OBJECT_NAME_BYTES_MOST :: 255
// The bytes of the Text field of the cause of a silent disk
// (storage_service.DISK_SILENT_CAUSE_BYTES).
@(private = "file")
DISK_SILENT_CAUSE_BYTES :: 72
// The end of the line of a silent disk, after its cause.
@(private = "file")
DISK_SILENT_END :: "; the service reads and changes nothing on the disk until its next start, and refuses each call that needs the disk"
// The three causes of a silent disk, as the service writes them, but for
// the bound of the third one, which the test gives.
@(private = "file")
DISK_SILENT_NO_ANSWER :: "the block service says that the device did not answer a request"
@(private = "file")
DISK_SILENT_SERVICE_STOPPED :: "the block service stopped before it answered"
// The end of each line of the stop of a removal, after its cause.
@(private = "file")
REMOVAL_END :: "; the next change of the store tries again"

// Each fact type of the storage service writes the line of before, byte for
// byte, at the edges of its fields: a store name of 32 bytes and an object
// name of 64, the longest that the service keeps; the counts 0, 1 and
// max(u64); a size or a time of max(i64), the largest that its field holds;
// each cause of a silent disk and of a stopped removal.
@(test)
the_facts_of_the_storage_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "storage")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "storage_service", type_name, values)
	}
	// A fact that names an object: the name is the text of its view.
	render_object :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field, object: string) -> string {
		rendered, written := views_render(t, file, "storage_service", type_name, values, {object})
		testing.expectf(t, len(written) == 1 && written[0] == object, "the view of %s holds the whole name of %d bytes", type_name, len(object))
		return rendered
	}
	store := strings.repeat("s", STORE_NAME_BYTES_MOST, context.temp_allocator)
	object := strings.repeat("o", OBJECT_NAME_BYTES_MOST, context.temp_allocator)
	most := max(u64)
	largest := u64(max(i64))
	counts := [3]u64{0, 1, most}

	// The silent disk: each cause, and the bound of the third at its edges.
	fixed_causes := [2]string{DISK_SILENT_NO_ANSWER, DISK_SILENT_SERVICE_STOPPED}
	for words in fixed_causes {
		testing.expect(t, len(words) < DISK_SILENT_CAUSE_BYTES)
		facts_expect_line(t, render(t, file, "Disk_Silent", {{"cause", words}}), line_of_before("storage: the disk does not answer: ", words, DISK_SILENT_END))
	}
	for bound in counts {
		words := line_of_before("no completion came in ", bound, " ms")
		testing.expect(t, len(words) < DISK_SILENT_CAUSE_BYTES)
		facts_expect_line(t, render(t, file, "Disk_Silent", {{"cause", words}}), line_of_before("storage: the disk does not answer: no completion came in ", bound, " ms", DISK_SILENT_END))
	}

	// The commits.
	facts_expect_line(t, render(t, file, "Tree_Node_Damaged", {{"store", store}}), line_of_before("storage: a node of a tree of the store ", store, " has a wrong check or breaks a rule of the format: the service changes nothing more in the store"))
	facts_expect_line(t, render(t, file, "Commit_Count_Below_Zero", {{"store", store}}), line_of_before("storage: a fault of the engine: a commit would take a count of names of a block below 0; the service makes no change in the store ", store, " until its next start, which counts again"))
	facts_expect_line(t, render(t, file, "Commit_Block_Dropped", {{"generation", most}, {"generation_before", u64(0)}}), line_of_before("storage: the read back of the commit of generation ", most, " found ", u64(1), " block with other bytes: the disk did not keep it", "; the commit is refused before its root, and the service goes on from generation ", u64(0)))
	for blocks in counts {
		facts_expect_line(t, render(t, file, "Commit_Blocks_Dropped", {{"generation", u64(1)}, {"blocks", blocks}, {"generation_before", most}}), line_of_before("storage: the read back of the commit of generation ", u64(1), " found ", blocks, " blocks with other bytes: the disk did not keep them", "; the commit is refused before its root, and the service goes on from generation ", most))
	}
	facts_expect_line(t, render(t, file, "Commit_Read_Back_Failed", {{"generation", most}}), line_of_before("storage: the read back of the commit of generation ", most, " failed on the device: the commit is refused before its root"))
	facts_expect_line(t, render(t, file, "Commit_Root_Dropped", {{"generation", u64(0)}, {"generation_before", most}}), line_of_before("storage: the read back of the root of the commit of generation ", u64(0), " found other bytes: the disk did not keep it; the commit is refused, and the service goes on from generation ", most))
	root_end :: "; the commit is not taken, the open of the next start decides, and the service makes no change until then"
	facts_expect_line(t, render(t, file, "Root_Write_Failed", {{"generation", most}}), line_of_before("storage: the root of the commit of generation ", most, ": ", "its write failed on the device", root_end))
	facts_expect_line(t, render(t, file, "Root_Read_Back_Failed", {{"generation", u64(0)}}), line_of_before("storage: the root of the commit of generation ", u64(0), ": ", "its read back failed on the device", root_end))
	// The limit of the roots in a row is 3; the field takes any count.
	root_commits := [2]u64{3, most}
	for commits in root_commits {
		facts_expect_line(t, render(t, file, "Root_Place_Drops_Writes", {{"commits", commits}}), line_of_before("storage: the disk did not keep the root of ", commits, " commits in a row: a place of the root drops its writes; the service makes no change until its next start, and its objects can still be read"))
	}
	facts_expect_line(t, render(t, file, "Versions_Dropped_At_Commit", {{"generation", most}, {"dropped", u64(0)}, {"store", store}}), line_of_before("storage: the commit of generation ", most, " dropped ", u64(0), " version indexes or leaves with a wrong check in the store ", store, ": those versions are lost, the objects stay"))

	// The shares: the number of a share is an i64 of the export, from 1.
	shares := [2]i64{1, max(i64)}
	for share in shares {
		facts_expect_line(t, render(t, file, "Share_Made", {{"share", u64(share)}, {"store", store}}), line_of_before("storage: a share of the store ", store, "", ", the share ", share))
		facts_expect_line(t, render(t, file, "Read_Only_Share_Made", {{"share", u64(share)}, {"store", "c"}}), line_of_before("storage: a share of the store ", "c", ", read only", ", the share ", share))
		facts_expect_line(t, render(t, file, "Share_Ended", {{"share", u64(share)}}), line_of_before("storage: the share ", share, " ended"))
	}

	// The open.
	disk_sizes := [3]u64{0, 16384, largest}
	for blocks in disk_sizes {
		facts_expect_line(t, render(t, file, "New_Disk_Formatted", {{"blocks", blocks}}), line_of_before("storage: ok, a new disk: generation 1, ", sentence.Size{blocks, .Blocks}))
	}
	facts_expect_line(t, render(t, file, "Cut_Root_Skipped", {{"generation", most}}), line_of_before("storage: the root of generation ", most, " has a wrong check: a write that a stop cut; the service uses the root before it"))
	facts_expect_line(t, render(t, file, "Blocks_Damaged", {{"blocks", most}, {"objects", u64(0)}, {"stores", u64(1)}}), line_of_before("storage: ", most, " blocks have a wrong check: ", u64(0), " objects and ", u64(1), " stores are damaged; the service serves the others, and a write or a remove replaces a damaged object"))
	facts_expect_line(t, render(t, file, "Versions_Damaged", {{"versions", most}}), line_of_before("storage: ", most, " versions have a wrong block: a read of them gives Damaged"))
	facts_expect_line(t, render(t, file, "Store_Counts_Differ", {{"stores_recounted", u64(0)}, {"stores_with_wrong_count", most}}), line_of_before("storage: the disk gives ", u64(0), " stores another count of blocks than the open counted; the service takes the counts of the open (", most, " stores with no damage have a wrong count: a fault of the engine that wrote it)"))
	facts_expect_line(t, render(t, file, "Disk_Opened", {{"generation", most}, {"stores", u64(0)}, {"objects", u64(1)}, {"trees", most}, {"versions", u64(0)}, {"in_use", largest}, {"shared", most}, {"checked", u64(1)}, {"wrong", u64(0)}, {"elapsed", largest}}), line_of_before("storage: ok, generation ", most, ": ", u64(0), " stores, ", u64(1), " objects, ", most, " trees, ", u64(0), " versions, ", sentence.Size{largest, .Blocks}, " in use, ", most, " shared, ", u64(1), " blocks checked, ", u64(0), " wrong, in ", sentence.Duration{largest, .Milliseconds}))
	facts_expect_line(t, render(t, file, "Disk_Opened", {{"generation", u64(1027)}, {"stores", u64(3)}, {"objects", u64(4)}, {"elapsed", u64(0)}}), line_of_before("storage: ok, generation ", u64(1027), ": ", u64(3), " stores, ", u64(4), " objects, ", u64(0), " trees, ", u64(0), " versions, ", sentence.Size{0, .Blocks}, " in use, ", u64(0), " shared, ", u64(0), " blocks checked, ", u64(0), " wrong, in ", sentence.Duration{0, .Milliseconds}))
	facts_expect_line(t, render(t, file, "Trees_Wait_To_Be_Freed", {{"trees", most}}), line_of_before("storage: ", most, " trees wait to be freed: the removal continues"))

	// The limit of a store: the generation is an i64 of the commit, from 1.
	facts_expect_line(t, render(t, file, "Store_At_Limit_Thinned_One_Version", {{"limit", largest}, {"generation", largest}, {"store", store}}), line_of_before("storage: the store ", store, " is at its limit of ", sentence.Size{largest, .Blocks}, ": the commit of generation ", max(i64), " thinned ", u64(1), " version", ", the oldest of the store first"))
	for thinned in counts {
		facts_expect_line(t, render(t, file, "Store_At_Limit_Thinned_Versions", {{"limit", u64(0)}, {"generation", u64(1)}, {"thinned", thinned}, {"store", "console"}}), line_of_before("storage: the store ", "console", " is at its limit of ", sentence.Size{0, .Blocks}, ": the commit of generation ", i64(1), " thinned ", thinned, " versions", ", the oldest of the store first"))
	}

	// The erase of the versions of an object.
	facts_expect_line(t, render_object(t, file, "Versions_Erased_One_Version", {{"zeroed", most}, {"kept", u64(0)}, {"generation", most}, {"store", store}}, object), line_of_before("storage: the versions of ", object, " in the store ", store, " are erased: ", u64(1), " version", " ended, ", most, " blocks written with zeros, ", u64(0), " blocks kept that another state names, generation ", most))
	for ended in counts {
		if ended == 1 {
			continue
		}
		facts_expect_line(t, render_object(t, file, "Versions_Erased", {{"ended", ended}, {"zeroed", u64(0)}, {"kept", most}, {"generation", u64(1)}, {"store", store}}, object), line_of_before("storage: the versions of ", object, " in the store ", store, " are erased: ", ended, " versions", " ended, ", u64(0), " blocks written with zeros, ", most, " blocks kept that another state names, generation ", u64(1)))
	}
	facts_expect_line(t, render_object(t, file, "Erase_Damaged_Left", {{"damaged", most}, {"store", store}}, object), line_of_before("storage: the erase of the versions of ", object, " in the store ", store, " ended ", most, " damaged version indexes, leaves or states with no zeros over them: their blocks keep their bytes, in use until the next start of the service and free after it"))

	// The stops of the removal of a tree: each cause.
	facts_expect_line(t, render(t, file, "Tree_Removal_No_First_Tree", {{"store", store}}), line_of_before("storage: the removal of a tree of the store ", store, " stops: ", "the removal queue gives no first tree", REMOVAL_END))
	facts_expect_line(t, render(t, file, "Tree_Removal_Step_Refused", {{"store", store}}), line_of_before("storage: the removal of a tree of the store ", store, " stops: ", "a step was refused", REMOVAL_END))
	facts_expect_line(t, render(t, file, "Tree_Removal_Commit_Failed", {{"store", store}}), line_of_before("storage: the removal of a tree of the store ", store, " stops: ", "its commit failed", REMOVAL_END))

	// The commit of the range writes of an object.
	facts_expect_line(t, render_object(t, file, "Ranges_Committed", {{"generation", most}, {"changed", u64(0)}, {"object_blocks", most}, {"hashed_blocks", u64(1)}, {"hashed_nodes", most}, {"written", u64(0)}, {"held", largest}, {"elapsed", largest}}, object), line_of_before("storage: the commit of generation ", most, " of ", object, ": ", u64(0), " blocks changed of ", most, ", ", u64(1), " blocks and ", most, " object nodes hashed, ", u64(0), " blocks written; the object holds ", sentence.Size{largest, .Blocks}, "; in ", sentence.Duration{largest, .Milliseconds}))
	facts_expect_line(t, render_object(t, file, "Ranges_Committed", {{"generation", u64(3)}, {"changed", u64(3)}, {"object_blocks", u64(2097152)}}, "sparse"), line_of_before("storage: the commit of generation ", u64(3), " of ", "sparse", ": ", u64(3), " blocks changed of ", u64(2097152), ", ", u64(0), " blocks and ", u64(0), " object nodes hashed, ", u64(0), " blocks written; the object holds ", sentence.Size{0, .Blocks}, "; in ", sentence.Duration{0, .Milliseconds}))
}

// Each fact type of the block service writes the line of before, byte for
// byte: no request in flight, the largest count of a u32, and a bound of
// max(i64).
@(test)
the_facts_of_the_block_service_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "block")
	if !ok {
		return
	}
	largest := u64(max(i64))
	in_flight_counts := [2]u64{0, u64(max(u32))}
	for in_flight in in_flight_counts {
		facts_expect_line(t, fact_test_render(t, file, "block_service", "Device_Silent", {{"bound", largest}, {"in_flight", in_flight}}), line_of_before("block: the device did not answer a request in ", largest, " ms: ", in_flight, " requests in flight fail, and the service stops"))
		facts_expect_line(t, fact_test_render(t, file, "block_service", "Device_Needs_Reset", {{"in_flight", in_flight}}), line_of_before("block: the device needs a reset: ", in_flight, " requests in flight fail, and the service stops"))
	}
	facts_expect_line(t, fact_test_render(t, file, "block_service", "Device_Silent", {{"bound", u64(0)}, {"in_flight", u64(1)}}), line_of_before("block: the device did not answer a request in ", u64(0), " ms: ", u64(1), " requests in flight fail, and the service stops"))
}

// Each fact type of the storage service with a store name ends with that
// Text field, before a text view of an object name only, and each Text
// field holds the longest name of its kind and a zero byte: the serial line
// of a short name then ends with the name, and no name is cut.
@(test)
the_names_of_the_storage_facts_come_last_and_whole :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, foundation.SYSTEM_MODULE_SOURCES + "storage")
	if !ok {
		return
	}
	rows := module.count(file, .Facts)
	testing.expect(t, rows > 1)
	for row_index in 1 ..< rows {
		_, description, row_ok := module.fact(file, row_index)
		if !testing.expect(t, row_ok) {
			continue
		}
		type_name := module.string_at(file, description.name_offset, description.name_count)
		last_end: u32 = 0
		last_is_text := false
		has_text := false
		for number in 0 ..< description.field_count {
			item, item_ok := module.field(file, description, number)
			if !testing.expect(t, item_ok) {
				continue
			}
			// A text view of an object name is the last field of all, after
			// the Text fields: the build refuses a field after a view.
			if item.kind == u8(value_kinds.Field_Kind.Text_View) {
				name := module.string_at(file, item.name_offset, item.name_count)
				testing.expectf(t, name == "object", "the text view %s of %s is no name that this test knows", name, type_name)
				continue
			}
			end := item.offset + module.field_size(item)
			is_text := item.type == u8(module.Type.Text)
			if is_text {
				has_text = true
				name := module.string_at(file, item.name_offset, item.name_count)
				switch name {
				case "store":
					testing.expectf(t, module.field_size(item) > STORE_NAME_BYTES_MOST, "the field store of %s holds no store name of %d bytes", type_name, STORE_NAME_BYTES_MOST)
				case "cause":
					testing.expectf(t, module.field_size(item) == DISK_SILENT_CAUSE_BYTES, "the field cause of %s has %d bytes", type_name, module.field_size(item))
				case:
					testing.expectf(t, false, "the Text field %s of %s is no name that this test knows", name, type_name)
				}
			}
			if end >= last_end {
				last_end, last_is_text = end, is_text
			}
		}
		testing.expectf(t, !has_text || last_is_text, "the fact type %s has a Text field that is not last", type_name)
	}
}
