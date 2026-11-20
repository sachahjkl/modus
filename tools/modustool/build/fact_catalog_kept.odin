package build

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "modus:contract/blake3"
import module "modus:contract/module"
import "modustool:foundation"

// The catalog of the module files of the build, kept for the whole run of
// the tool. A reader of a measured log renders the lines of facts with it
// (checks.measure_log_rendered): the measure record reads about 23 logs,
// and a catalog made for each one read and hashed each module file each
// time. The kept catalog reads a module file once, and again only when its
// size or its time of change differs from the ones that it read: a build
// in the same run of the tool changes the files, and a catalog of the
// files before it would render a fact with the template of another file.
//
// Several parts of a test run at once, each in its own thread: the kept
// catalog changes and renders under one lock, so no thread reads a module
// that another frees.

// What the kept catalog knows of a module file without reading it.
Module_File_Stamp :: struct {
	size:         i64,
	changed_time: i64, // Nanoseconds since the Unix epoch.
}

// The way a kept catalog reaches the module files: the file system for the
// build, the files of memory for a test. data is given to each procedure.
Module_File_Access :: struct {
	data:  rawptr,
	stamp: proc(data: rawptr, path: string) -> (stamp: Module_File_Stamp, ok: bool),
	read:  proc(data: rawptr, path: string) -> (file: []u8, ok: bool),
}

// One module file of a kept catalog: what its stamp was when it was read,
// its hash, and its bytes. file is nil for a file that module.validate
// refuses: its facts stay raw.
Kept_Module_File :: struct {
	path:  string,
	stamp: Module_File_Stamp,
	hash:  [module.HASH_SIZE]u8,
	file:  []u8,
}

// A catalog kept across calls, in an allocator of its own.
Kept_Fact_Catalog :: struct {
	files:     [dynamic]Kept_Module_File,
	catalog:   Fact_Catalog,
	allocator: runtime.Allocator,
	lock:      sync.Mutex,
}

// The kept catalog of the module files of the build.
@(private = "file")
kept_build_catalog: Kept_Fact_Catalog

// kept_fact_catalog_refresh makes the catalog hold each file of paths, in
// their order. It reads a file whose stamp is not the one of the file that
// it holds, and no other. problem: a file has no stamp or cannot be read,
// or two hashes share their module tag; the catalog then stays as it was.
// The caller holds the lock.
kept_fact_catalog_refresh :: proc(kept: ^Kept_Fact_Catalog, paths: []string, access: Module_File_Access) -> (problem: string) {
	if kept.allocator.procedure == nil {
		kept.allocator = runtime.heap_allocator()
	}
	stamps := make([]Module_File_Stamp, len(paths), context.temp_allocator)
	same := len(paths) == len(kept.files)
	for path, index in paths {
		stamp, stamped := access.stamp(access.data, path)
		if !stamped {
			return fmt.tprintf("the module file %s has no size or no time of change", path)
		}
		stamps[index] = stamp
		same = same && kept.files[index].path == path && kept.files[index].stamp == stamp
	}
	if same {
		return ""
	}
	// The new list: a file of the same path and the same stamp is kept, and
	// each other one is read. A refusal frees only the files that this
	// refresh read: the kept ones still belong to the old list, which stays.
	files := make([dynamic]Kept_Module_File, 0, len(paths), kept.allocator)
	kept_old := make([]bool, len(kept.files), context.temp_allocator)
	reused_new := make([]bool, len(paths), context.temp_allocator)
	for path, index in paths {
		found := false
		for old, old_index in kept.files {
			if old.path == path && old.stamp == stamps[index] {
				reused_new[len(files)] = true
				append(&files, old)
				kept_old[old_index] = true
				found = true
				break
			}
		}
		if found {
			continue
		}
		bytes, readable := access.read(access.data, path)
		if !readable {
			kept_fact_catalog_files_free(kept.allocator, files[:], reused_new[:len(files)])
			delete(files)
			return fmt.tprintf("the module file %s cannot be read", path)
		}
		item := Kept_Module_File{path = strings.clone(path, kept.allocator), stamp = stamps[index], hash = blake3.hash(bytes)}
		if module.validate(bytes) == .None {
			item.file = make([]u8, len(bytes), kept.allocator)
			copy(item.file, bytes)
		}
		append(&files, item)
	}
	catalog := Fact_Catalog{allocator = kept.allocator}
	for item in files {
		// path "": the catalog never reads the file again; a file that
		// validate refused has no bytes, and its facts stay raw.
		if problem = fact_catalog_add(&catalog, item.hash, "", item.file); problem != "" {
			kept_fact_catalog_list_free(&catalog)
			kept_fact_catalog_files_free(kept.allocator, files[:], reused_new[:len(files)])
			delete(files)
			return problem
		}
	}
	kept_fact_catalog_files_free(kept.allocator, kept.files[:], kept_old)
	delete(kept.files)
	kept_fact_catalog_list_free(&kept.catalog)
	kept.files = files
	kept.catalog = catalog
	return ""
}

// kept_fact_catalog_destroy frees each file and the list of a kept
// catalog: a test makes catalogs of its own.
kept_fact_catalog_destroy :: proc(kept: ^Kept_Fact_Catalog) {
	kept_fact_catalog_files_free(kept.allocator, kept.files[:], nil)
	delete(kept.files)
	kept_fact_catalog_list_free(&kept.catalog)
	kept.files = nil
}

// kept_fact_catalog_files_free frees the files of a list that the kept
// catalog read, but the ones that reused marks: the new list holds them.
@(private = "file")
kept_fact_catalog_files_free :: proc(allocator: runtime.Allocator, files: []Kept_Module_File, reused: []bool) {
	for item, index in files {
		if reused != nil && reused[index] {
			continue
		}
		delete(item.path, allocator)
		delete(item.file, allocator)
	}
}

// fact_catalog_free frees the list and the paths of a catalog, not the
// files, which a kept catalog owns.
@(private = "file")
kept_fact_catalog_list_free :: proc(catalog: ^Fact_Catalog) {
	for item in catalog.modules {
		delete(item.path, catalog.allocator)
	}
	delete(catalog.modules)
	catalog.modules = nil
}

// kept_fact_lines_render gives the text of a log with the line of each
// fact rendered by the kept catalog, which it refreshes first. A log with
// no line of a fact is given as it is, and no file is stamped or read. The
// text is in the temporary memory of the caller.
kept_fact_lines_render :: proc(kept: ^Kept_Fact_Catalog, paths: []string, access: Module_File_Access, text: string) -> (rendered: string, problem: string) {
	if !strings.contains(text, FACT_LINE_MARK) {
		return text, ""
	}
	sync.mutex_lock(&kept.lock)
	defer sync.mutex_unlock(&kept.lock)
	if problem = kept_fact_catalog_refresh(kept, paths, access); problem != "" {
		return text, problem
	}
	rendered, _ = fact_lines_render(&kept.catalog, text)
	return rendered, ""
}

// fact_lines_render_of_build gives the text of a log with the line of each
// fact rendered by the module files of the build, with the catalog that
// the run of the tool keeps.
fact_lines_render_of_build :: proc(text: string) -> (rendered: string, problem: string) {
	paths := make([]string, len(foundation.module_builds), context.temp_allocator)
	for build, index in foundation.module_builds {
		paths[index] = foundation.module_path(build.name)
	}
	return kept_fact_lines_render(&kept_build_catalog, paths, build_module_file_access(), text)
}

// build_module_file_access reaches the module files on the file system.
build_module_file_access :: proc() -> Module_File_Access {
	stamp :: proc(data: rawptr, path: string) -> (stamp: Module_File_Stamp, ok: bool) {
		information, error := os.stat(path, context.temp_allocator)
		if error != nil {
			return {}, false
		}
		return {size = information.size, changed_time = time.time_to_unix_nano(information.modification_time)}, true
	}
	read :: proc(data: rawptr, path: string) -> (file: []u8, ok: bool) {
		return foundation.read_file(path)
	}
	return {stamp = stamp, read = read}
}
