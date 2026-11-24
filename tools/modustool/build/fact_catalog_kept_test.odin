package build

import "modus:contract/blake3"
import "core:testing"
import "modustool:foundation"

// The kept catalog of the module files (fact_catalog_kept.odin): it reads
// a file once, and again only when its stamp changed. The files are in
// memory, and the test counts the stamps and the reads through the access
// of the catalog: no file system, no time.

@(private = "file")
Memory_Module_Files :: struct {
	paths:    [3]string,
	files:    [3][]u8,
	stamps:   [3]Module_File_Stamp,
	stamped:  [3]bool, // false: the file has no stamp.
	readable: [3]bool, // false: the file cannot be read.
	reads:    int,
	stamp_calls: int,
}

@(private = "file")
memory_access :: proc(files: ^Memory_Module_Files) -> Module_File_Access {
	place :: proc(files: ^Memory_Module_Files, path: string) -> int {
		for candidate, index in files.paths {
			if candidate == path {
				return index
			}
		}
		return -1
	}
	stamp :: proc(data: rawptr, path: string) -> (stamp: Module_File_Stamp, ok: bool) {
		files := (^Memory_Module_Files)(data)
		files.stamp_calls += 1
		index := place(files, path)
		if index < 0 || !files.stamped[index] {
			return {}, false
		}
		return files.stamps[index], true
	}
	read :: proc(data: rawptr, path: string) -> (file: []u8, ok: bool) {
		files := (^Memory_Module_Files)(data)
		index := place(files, path)
		if index < 0 || !files.readable[index] {
			return nil, false
		}
		files.reads += 1
		return files.files[index], true
	}
	return {data = files, stamp = stamp, read = read}
}

// Three files of distinct bytes, so of distinct hashes and module tags;
// none is a module file that validate takes.
@(private = "file")
memory_module_files :: proc() -> Memory_Module_Files {
	files: Memory_Module_Files
	files.paths = {"a.module", "b.module", "c.module"}
	files.files = {transmute([]u8)string("the first file"), transmute([]u8)string("the second file"), transmute([]u8)string("the third file")}
	for index in 0 ..< 3 {
		files.stamps[index] = {size = i64(len(files.files[index])), changed_time = i64(index + 1)}
		files.stamped[index] = true
		files.readable[index] = true
	}
	return files
}

// Two refreshes with the same stamps read each file once; a changed stamp
// reads that file again, and no other.
@(test)
the_kept_catalog_reads_a_module_file_once :: proc(t: ^testing.T) {
	files := memory_module_files()
	access := memory_access(&files)
	kept: Kept_Fact_Catalog
	defer kept_fact_catalog_destroy(&kept)

	testing.expect_value(t, kept_fact_catalog_refresh(&kept, files.paths[:], access), "")
	testing.expect_value(t, files.reads, 3)
	testing.expect_value(t, kept_fact_catalog_refresh(&kept, files.paths[:], access), "")
	testing.expect_value(t, files.reads, 3)
	testing.expect_value(t, len(kept.catalog.modules), 3)

	// The second file changes: one read more, and the catalog has its new
	// hash.
	files.files[1] = transmute([]u8)string("the second file, changed")
	files.stamps[1] = {size = i64(len(files.files[1])), changed_time = 9}
	testing.expect_value(t, kept_fact_catalog_refresh(&kept, files.paths[:], access), "")
	testing.expect_value(t, files.reads, 4)
	testing.expect(t, kept.files[1].hash == blake3.hash(files.files[1]))
	testing.expect(t, kept.files[0].hash == blake3.hash(files.files[0]))
	testing.expect_value(t, len(kept.catalog.modules), 3)

	// A size that changes alone is a change too.
	files.stamps[2].size += 1
	testing.expect_value(t, kept_fact_catalog_refresh(&kept, files.paths[:], access), "")
	testing.expect_value(t, files.reads, 5)
}

// A file with no stamp, and a changed file that cannot be read, are
// refused, and the catalog stays as it was.
@(test)
the_kept_catalog_refuses_a_file_that_it_cannot_reach :: proc(t: ^testing.T) {
	files := memory_module_files()
	access := memory_access(&files)
	kept: Kept_Fact_Catalog
	defer kept_fact_catalog_destroy(&kept)
	testing.expect_value(t, kept_fact_catalog_refresh(&kept, files.paths[:], access), "")
	hashes := [3][32]u8{kept.files[0].hash, kept.files[1].hash, kept.files[2].hash}

	files.stamped[0] = false
	testing.expect(t, kept_fact_catalog_refresh(&kept, files.paths[:], access) != "")
	testing.expect_value(t, files.reads, 3)
	files.stamped[0] = true

	files.files[2] = transmute([]u8)string("the third file, changed")
	files.stamps[2].changed_time = 10
	files.readable[2] = false
	testing.expect(t, kept_fact_catalog_refresh(&kept, files.paths[:], access) != "")
	testing.expect_value(t, files.reads, 3)
	testing.expect_value(t, len(kept.files), 3)
	for index in 0 ..< 3 {
		testing.expect(t, kept.files[index].hash == hashes[index])
	}
}

// A log with no line of a fact is given as it is: no file is stamped or
// read. A file that validate refuses keeps no bytes, so its facts stay raw.
@(test)
the_kept_catalog_reads_nothing_for_a_log_with_no_fact :: proc(t: ^testing.T) {
	files := memory_module_files()
	access := memory_access(&files)
	kept: Kept_Fact_Catalog
	defer kept_fact_catalog_destroy(&kept)
	text := "[console] > shutdown()\nkernel: ok\n"
	rendered, problem := kept_fact_lines_render(&kept, files.paths[:], access, text)
	testing.expect_value(t, rendered, text)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, files.reads, 0)
	testing.expect_value(t, files.stamp_calls, 0)

	testing.expect_value(t, kept_fact_catalog_refresh(&kept, files.paths[:], access), "")
	for item in kept.files {
		testing.expect(t, item.file == nil)
	}
}

// A nil module filter includes every module of foundation.module_builds; a
// non-nil filter omits excluded modules (such as test_caller during a
// filtered --fast build) so fact rendering does not fail on unbuilt files.
@(test)
fact_build_module_paths_respects_module_filter :: proc(t: ^testing.T) {
	all_paths := fact_build_module_paths(nil, context.temp_allocator)
	testing.expect_value(t, len(all_paths), len(foundation.module_builds))

	filter := make([]bool, len(foundation.module_builds), context.temp_allocator)
	kept_index := -1
	excluded_index := -1
	for row, index in foundation.module_builds {
		if row.name == "kernel" {
			filter[index] = true
			kept_index = index
		} else if row.name == "test_caller" {
			excluded_index = index
		}
	}
	testing.expect(t, kept_index >= 0)
	testing.expect(t, excluded_index >= 0)

	filtered := fact_build_module_paths(filter, context.temp_allocator)
	testing.expect_value(t, len(filtered), 1)
	testing.expect_value(t, filtered[0], foundation.module_path("kernel"))
}
