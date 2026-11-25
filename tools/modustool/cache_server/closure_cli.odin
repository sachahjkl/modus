// Offline closure export and import CLI (`cache-export`, `cache-import`) for
// air-gapped USB transfer of MODTREE2 program trees and recipe closures
// (src/md/features/program_trees.md).
package cache_server

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "modus:contract/blake3"
import "modus:contract/object_cache"
import "modus:contract/plans_recipes"
import "modus:contract/tree_hash"
import "modustool:foundation"

// Summary returned by cache_closure_export.
Closure_Export_Stats :: struct {
	root_hash:       blake3.Hash,
	root_kind:       object_cache.Cache_Object_Kind,
	object_count:    u64,
	bytes_written:   u64,
	has_realisation: bool,
}

// Summary returned by cache_closure_import.
Closure_Import_Stats :: struct {
	root_hash:        blake3.Hash,
	root_kind:        object_cache.Cache_Object_Kind,
	objects_imported: u64,
	objects_existing: u64,
	bytes_read:       u64,
	has_realisation:  bool,
	recipe_hash:      blake3.Hash,
}

@(private = "file")
Closure_Plan_Item :: struct {
	hash: blake3.Hash,
	kind: object_cache.Cache_Object_Kind,
	size: u64,
}

@(private = "file")
closure_verify_ed25519_cb :: proc "contextless" (
	public_key: [object_cache.PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [object_cache.SIGNATURE_SIZE]u8,
	_: rawptr,
) -> bool {
	context = runtime.default_context()
	return cache_server_verify_ed25519(public_key, message, signature)
}

@(private = "file")
closure_hash_of_arg :: proc(text: string) -> (hash: blake3.Hash, ok: bool) {
	if !hex_hash_valid(text) {
		return {}, false
	}
	h, parsed := plans_recipes.hash_of_hexadecimal(transmute([]u8)text)
	if !parsed || object_cache.hash_is_zero(h) {
		return {}, false
	}
	return h, true
}

// closure_collect_bottom_up walks hash from server's objects/ directory in
// deterministic post-order DFS (MODTREE2 entries are strictly sorted in UTF-8
// byte order), verifies every object's hash, detects cycles and depth overflow,
// and appends each unique (hash, kind) into plan with children before parents.
@(private = "file")
closure_collect_bottom_up :: proc(
	server: ^Cache_Server,
	hash: blake3.Hash,
	kind: object_cache.Cache_Object_Kind,
	depth: int,
	visited: ^map[blake3.Hash]object_cache.Cache_Object_Kind,
	on_stack: ^[dynamic]blake3.Hash,
	plan: ^[dynamic]Closure_Plan_Item,
) -> string {
	if prev_kind, seen := visited[hash]; seen {
		if prev_kind != kind {
			hex := hash_to_hex(hash)
			return fmt.tprintf("object %s referenced as conflicting object kinds", string(hex[:]))
		}
		return ""
	}
	if depth > object_cache.CLOSURE_STREAM_MAX_DEPTH {
		return fmt.tprintf("tree closure exceeds maximum depth %d", object_cache.CLOSURE_STREAM_MAX_DEPTH)
	}
	for ancestor in on_stack^ {
		if ancestor == hash {
			hex := hash_to_hex(hash)
			return fmt.tprintf("cycle detected in tree closure at %s", string(hex[:]))
		}
	}

	hex := hash_to_hex(hash)
	hex_text := string(hex[:])
	obj_path, path_ok := store_path_for_hex(server.root_directory, .Objects, hex_text, context.temp_allocator)
	if !path_ok {
		return fmt.tprintf("invalid object hash %s", hex_text)
	}
	if !os.exists(obj_path) {
		return fmt.tprintf("object %s is missing from %s", hex_text, server.root_directory)
	}

	switch kind {
	case .Blob:
		// Stream-verify Blob in 1 MiB chunks so large blobs never load whole into RAM.
		file, open_err := os.open(obj_path)
		if open_err != nil {
			return fmt.tprintf("cannot open object %s: %v", hex_text, open_err)
		}
		defer os.close(file)

		raw_size, size_err := os.file_size(file)
		if size_err != nil || raw_size < 0 {
			return fmt.tprintf("cannot read size of object %s", hex_text)
		}
		total := u64(raw_size)
		if total > object_cache.MAX_OBJECT_BYTES {
			return fmt.tprintf("blob %s exceeds maximum object size", hex_text)
		}

		chunk := make([]u8, int(object_cache.FRAME_PAYLOAD_BYTES), context.allocator)
		defer delete(chunk)
		hasher := blake3.hasher_make()
		offset: u64 = 0
		for offset < total {
			want := int(min(u64(len(chunk)), total - offset))
			if !file_read_exact_at(file, chunk[:want], i64(offset)) {
				return fmt.tprintf("cannot read object %s at offset %d", hex_text, offset)
			}
			blake3.hasher_update(&hasher, chunk[:want])
			offset += u64(want)
		}
		if blake3.hasher_finish(&hasher) != hash {
			return fmt.tprintf("blob %s on disk does not match its BLAKE3 hash", hex_text)
		}
		if u64(len(plan^)) >= object_cache.CLOSURE_STREAM_MAX_OBJECTS {
			return fmt.tprintf("closure exceeds maximum object count %d", object_cache.CLOSURE_STREAM_MAX_OBJECTS)
		}
		visited[hash] = .Blob
		append(plan, Closure_Plan_Item{hash = hash, kind = .Blob, size = total})
		return ""

	case .Tree:
		raw, found, read_ok := store_read_by_hex(server, .Objects, hex_text, context.allocator)
		if !read_ok || !found {
			return fmt.tprintf("cannot read tree object %s", hex_text)
		}
		defer delete(raw)
		if len(raw) > object_cache.MAX_TREE_PAYLOAD_BYTES {
			return fmt.tprintf("tree %s exceeds maximum tree payload size", hex_text)
		}
		computed, h_ref := tree_hash.tree_hash(raw)
		if h_ref != .None || computed != hash {
			return fmt.tprintf("tree %s on disk is malformed or does not match its tree_hash", hex_text)
		}

		append(on_stack, hash)
		defer pop(on_stack)

		count := tree_hash.tree_entry_count(raw)
		offset := tree_hash.HEADER_SIZE
		for _ in 0 ..< count {
			entry, next_offset, entry_ok := tree_hash.tree_entry_next(raw, offset)
			if !entry_ok {
				return fmt.tprintf("tree %s has a damaged entry", hex_text)
			}
			offset = next_offset
			child_kind := object_cache.Cache_Object_Kind.Blob
			switch entry.kind {
			case .Object:
				child_kind = .Blob
			case .Tree, .Part:
				child_kind = .Tree
			}
			if problem := closure_collect_bottom_up(server, entry.hash, child_kind, depth + 1, visited, on_stack, plan); problem != "" {
				return problem
			}
		}

		if u64(len(plan^)) >= object_cache.CLOSURE_STREAM_MAX_OBJECTS {
			return fmt.tprintf("closure exceeds maximum object count %d", object_cache.CLOSURE_STREAM_MAX_OBJECTS)
		}
		visited[hash] = .Tree
		append(plan, Closure_Plan_Item{hash = hash, kind = .Tree, size = u64(len(raw))})
		return ""
	}
	return "unknown object kind"
}

// cache_closure_export writes root_hash (and its full MODTREE2 closure when
// root is a Tree) plus an optional signed Realisation_Record into out_path in
// deterministic bottom-up MODCLOS1 format using atomic temp-file rename.
cache_closure_export :: proc(
	cache_dir: string,
	root_hash: blake3.Hash,
	out_path: string,
	recipe_hash: blake3.Hash = {},
	has_recipe: bool = false,
) -> (stats: Closure_Export_Stats, problem: string) {
	if cache_dir == "" || out_path == "" {
		return {}, "cache directory and output file path are required"
	}
	if object_cache.hash_is_zero(root_hash) {
		return {}, "root hash must be non-zero"
	}
	if has_recipe && object_cache.hash_is_zero(recipe_hash) {
		return {}, "realisation recipe hash must be non-zero"
	}

	server, opened := cache_server_open(cache_dir, nil)
	if !opened {
		return {}, fmt.tprintf("cannot open cache store %s", cache_dir)
	}
	defer cache_server_destroy(&server)

	root_kind: object_cache.Cache_Object_Kind
	realisation_bytes: [object_cache.REALISATION_WIRE_SIZE]u8

	if has_recipe {
		recipe_hex := hash_to_hex(recipe_hash)
		raw_real, found, read_ok := store_read_by_hex(&server, .Realisations, string(recipe_hex[:]), context.temp_allocator)
		if !read_ok || !found {
			return {}, fmt.tprintf("realisation %s is absent from %s", string(recipe_hex[:]), cache_dir)
		}
		decoded, dec_ref := object_cache.decode_realisation_record(raw_real)
		if dec_ref != .None {
			return {}, fmt.tprintf("realisation %s is damaged (%v)", string(recipe_hex[:]), dec_ref)
		}
		if decoded.recipe_hash != recipe_hash || decoded.output_hash != root_hash {
			return {}, fmt.tprintf("realisation %s does not match root hash", string(recipe_hex[:]))
		}
		root_kind = decoded.output_kind
		copy(realisation_bytes[:], raw_real[:object_cache.REALISATION_WIRE_SIZE])
	} else {
		// Detect whether root_hash is a canonical MODTREE2 Tree or a plain Blob.
		root_hex := hash_to_hex(root_hash)
		root_path, path_ok := store_path_for_hex(server.root_directory, .Objects, string(root_hex[:]), context.temp_allocator)
		if !path_ok || !os.exists(root_path) {
			return {}, fmt.tprintf("root object %s is missing from %s", string(root_hex[:]), cache_dir)
		}
		// Check if it fits in MAX_TREE_PAYLOAD_BYTES and hashes as MODTREE2 first.
		file, open_err := os.open(root_path)
		if open_err != nil {
			return {}, fmt.tprintf("cannot open root object %s: %v", string(root_hex[:]), open_err)
		}
		raw_size, size_err := os.file_size(file)
		if size_err != nil || raw_size < 0 {
			_ = os.close(file)
			return {}, fmt.tprintf("cannot read size of root object %s", string(root_hex[:]))
		}
		if raw_size <= i64(object_cache.MAX_TREE_PAYLOAD_BYTES) {
			probe := make([]u8, int(raw_size), context.allocator)
			defer delete(probe)
			read_ok := raw_size == 0 || file_read_exact_at(file, probe, 0)
			_ = os.close(file)
			if !read_ok {
				return {}, fmt.tprintf("cannot read root object %s", string(root_hex[:]))
			}
			if tree_digest, t_ref := tree_hash.tree_hash(probe); t_ref == .None && tree_digest == root_hash {
				root_kind = .Tree
			} else {
				root_kind = .Blob
			}
		} else {
			_ = os.close(file)
			root_kind = .Blob
		}
	}

	visited := make(map[blake3.Hash]object_cache.Cache_Object_Kind)
	defer delete(visited)
	on_stack := make([dynamic]blake3.Hash)
	defer delete(on_stack)
	plan := make([dynamic]Closure_Plan_Item)
	defer delete(plan)

	if err_msg := closure_collect_bottom_up(&server, root_hash, root_kind, 0, &visited, &on_stack, &plan); err_msg != "" {
		return {}, err_msg
	}

	// Write stream atomically via <out_path>.tmp + fsync + durable rename.
	temp_path := strings.concatenate({out_path, ".tmp"}, context.temp_allocator)
	out_file, create_err := os.create(temp_path)
	if create_err != nil {
		return {}, fmt.tprintf("cannot create output file %s: %v", out_path, create_err)
	}
	committed := false
	defer if !committed {
		_ = os.remove(temp_path)
	}

	header := object_cache.Closure_Stream_Header {
		version         = object_cache.CLOSURE_STREAM_VERSION,
		has_realisation = has_recipe,
		root_kind       = root_kind,
		root_hash       = root_hash,
		object_count    = u64(len(plan)),
	}
	hdr_buf: [object_cache.CLOSURE_STREAM_HEADER_SIZE]u8
	if _, href := object_cache.closure_header_write(&header, hdr_buf[:]); href != .None {
		_ = os.close(out_file)
		return {}, fmt.tprintf("cannot encode closure header (%v)", href)
	}
	if !file_write_all(out_file, hdr_buf[:]) {
		_ = os.close(out_file)
		return {}, fmt.tprintf("cannot write closure header to %s", out_path)
	}
	bytes_written := u64(len(hdr_buf))

	stream_buf := make([]u8, int(object_cache.FRAME_PAYLOAD_BYTES), context.allocator)
	defer delete(stream_buf)

	for item in plan {
		rec_hdr := object_cache.Closure_Record_Header {
			kind = item.kind,
			size = item.size,
			hash = item.hash,
		}
		rec_buf: [object_cache.CLOSURE_RECORD_HEADER_SIZE]u8
		if _, rref := object_cache.closure_record_header_write(&rec_hdr, rec_buf[:]); rref != .None {
			_ = os.close(out_file)
			return {}, fmt.tprintf("cannot encode record header (%v)", rref)
		}
		if !file_write_all(out_file, rec_buf[:]) {
			_ = os.close(out_file)
			return {}, fmt.tprintf("cannot write record header to %s", out_path)
		}
		bytes_written += u64(len(rec_buf))

		item_hex := hash_to_hex(item.hash)
		item_path, path_ok := store_path_for_hex(server.root_directory, .Objects, string(item_hex[:]), context.temp_allocator)
		if !path_ok {
			_ = os.close(out_file)
			return {}, "invalid object path during export"
		}
		src_file, src_err := os.open(item_path)
		if src_err != nil {
			_ = os.close(out_file)
			return {}, fmt.tprintf("cannot open object %s: %v", string(item_hex[:]), src_err)
		}
		copied: u64 = 0
		for copied < item.size {
			want := int(min(u64(len(stream_buf)), item.size - copied))
			if !file_read_exact_at(src_file, stream_buf[:want], i64(copied)) {
				_ = os.close(src_file)
				_ = os.close(out_file)
				return {}, fmt.tprintf("object %s changed size during export", string(item_hex[:]))
			}
			if !file_write_all(out_file, stream_buf[:want]) {
				_ = os.close(src_file)
				_ = os.close(out_file)
				return {}, fmt.tprintf("cannot write object %s payload to %s", string(item_hex[:]), out_path)
			}
			copied += u64(want)
			bytes_written += u64(want)
		}
		_ = os.close(src_file)
	}

	if has_recipe {
		if !file_write_all(out_file, realisation_bytes[:]) {
			_ = os.close(out_file)
			return {}, fmt.tprintf("cannot write realisation to %s", out_path)
		}
		bytes_written += u64(len(realisation_bytes))
	}

	if !file_sync_and_close(out_file) {
		return {}, fmt.tprintf("cannot sync output file %s", out_path)
	}
	if !file_rename_durable(temp_path, out_path) {
		return {}, fmt.tprintf("cannot rename closure stream into %s", out_path)
	}
	committed = true

	return {
		root_hash       = root_hash,
		root_kind       = root_kind,
		object_count    = u64(len(plan)),
		bytes_written   = bytes_written,
		has_realisation = has_recipe,
	}, ""
}

// cache_closure_import streams a MODCLOS1 offline closure file, verifies every
// object's BLAKE3 / MODTREE2 hash, verifies bottom-up closure completeness and
// optional Ed25519 realisation signature (plus trusted_signers when provided),
// refuses any trailing bytes, and commits verified objects atomically into
// cache_dir.
cache_closure_import :: proc(
	cache_dir: string,
	in_path: string,
	trusted_signers: [][object_cache.PUBLIC_KEY_SIZE]u8 = nil,
) -> (stats: Closure_Import_Stats, problem: string) {
	if cache_dir == "" || in_path == "" {
		return {}, "cache directory and input file path are required"
	}

	server, opened := cache_server_open(cache_dir, trusted_signers)
	if !opened {
		return {}, fmt.tprintf("cannot open cache store %s", cache_dir)
	}
	defer cache_server_destroy(&server)

	in_file, open_err := os.open(in_path)
	if open_err != nil {
		return {}, fmt.tprintf("cannot open closure file %s: %v", in_path, open_err)
	}
	defer os.close(in_file)

	hdr_buf: [object_cache.CLOSURE_STREAM_HEADER_SIZE]u8
	if !file_read_exact_at(in_file, hdr_buf[:], 0) {
		return {}, fmt.tprintf("%s is truncated before the closure header", in_path)
	}
	header, hdr_ref := object_cache.closure_header_read(hdr_buf[:])
	if hdr_ref != .None {
		return {}, fmt.tprintf("%s has an invalid closure header (%v)", in_path, hdr_ref)
	}

	cursor := i64(object_cache.CLOSURE_STREAM_HEADER_SIZE)
	seen_in_stream := make(map[blake3.Hash]object_cache.Cache_Object_Kind)
	defer delete(seen_in_stream)

	chunk_buf := make([]u8, int(object_cache.FRAME_PAYLOAD_BYTES), context.allocator)
	defer delete(chunk_buf)

	last_hash: blake3.Hash
	last_kind: object_cache.Cache_Object_Kind
	objects_imported: u64 = 0
	objects_existing: u64 = 0

	for record_index in u64(0) ..< header.object_count {
		rec_buf: [object_cache.CLOSURE_RECORD_HEADER_SIZE]u8
		if !file_read_exact_at(in_file, rec_buf[:], cursor) {
			return {}, fmt.tprintf("%s truncated at record %d header", in_path, record_index)
		}
		cursor += object_cache.CLOSURE_RECORD_HEADER_SIZE
		rec, rec_ref := object_cache.closure_record_header_read(rec_buf[:])
		if rec_ref != .None {
			return {}, fmt.tprintf("%s record %d header refused (%v)", in_path, record_index, rec_ref)
		}

		obj_hex := hash_to_hex(rec.hash)
		obj_hex_text := string(obj_hex[:])
		final_path, path_ok := store_path_for_hex(server.root_directory, .Objects, obj_hex_text, context.temp_allocator)
		if !path_ok {
			return {}, "invalid object hash in closure stream"
		}

		switch rec.kind {
		case .Tree:
			tree_buf := make([]u8, int(rec.size), context.allocator)
			defer delete(tree_buf)
			if rec.size > 0 && !file_read_exact_at(in_file, tree_buf, cursor) {
				return {}, fmt.tprintf("%s truncated inside tree %s", in_path, obj_hex_text)
			}
			cursor += i64(rec.size)
			if ver_ref := object_cache.closure_record_verify(&rec, tree_buf); ver_ref != .None {
				return {}, fmt.tprintf("tree %s verification failed (%v)", obj_hex_text, ver_ref)
			}
			// Verify bottom-up closure integrity: every child hash must already be
			// verified earlier in this stream or present in the destination store.
			count := tree_hash.tree_entry_count(tree_buf)
			offset := tree_hash.HEADER_SIZE
			for _ in 0 ..< count {
				entry, next_offset, entry_ok := tree_hash.tree_entry_next(tree_buf, offset)
				if !entry_ok {
					return {}, fmt.tprintf("tree %s contains an unreadable entry", obj_hex_text)
				}
				offset = next_offset
				_, in_stream := seen_in_stream[entry.hash]
				if !in_stream && !cache_server_has(&server, entry.hash) {
					child_hex := hash_to_hex(entry.hash)
					return {}, fmt.tprintf("tree %s references missing child %s (not in stream or store)", obj_hex_text, string(child_hex[:]))
				}
			}
			written, added := store_write_atomic(&server, .Objects, obj_hex_text, tree_buf)
			if !written {
				return {}, fmt.tprintf("cannot store verified tree %s", obj_hex_text)
			}
			if added {
				objects_imported += 1
			} else {
				objects_existing += 1
			}

		case .Blob:
			if rec.size <= object_cache.FRAME_PAYLOAD_BYTES {
				payload := chunk_buf[:int(rec.size)]
				if rec.size > 0 && !file_read_exact_at(in_file, payload, cursor) {
					return {}, fmt.tprintf("%s truncated inside blob %s", in_path, obj_hex_text)
				}
				cursor += i64(rec.size)
				if ver_ref := object_cache.closure_record_verify(&rec, payload); ver_ref != .None {
					return {}, fmt.tprintf("blob %s verification failed (%v)", obj_hex_text, ver_ref)
				}
				written, added := store_write_atomic(&server, .Objects, obj_hex_text, payload)
				if !written {
					return {}, fmt.tprintf("cannot store verified blob %s", obj_hex_text)
				}
				if added {
					objects_imported += 1
				} else {
					objects_existing += 1
				}
			} else {
				// Stream large (> 1 MiB) blobs through tmp/ while verifying BLAKE3 incrementally.
				already_exists := os.exists(final_path)
				seq := sync.atomic_add(&server.temp_sequence, 1)
				temp_path := fmt.tprintf("%s/%s/%s.%d.tmp", server.root_directory, store_directory_name(.Temp), obj_hex_text, seq)
				temp_file, create_err := os.create(temp_path)
				if create_err != nil {
					return {}, fmt.tprintf("cannot create staging file for blob %s: %v", obj_hex_text, create_err)
				}
				hasher := blake3.hasher_make()
				read_total: u64 = 0
				for read_total < rec.size {
					want := int(min(u64(len(chunk_buf)), rec.size - read_total))
					if !file_read_exact_at(in_file, chunk_buf[:want], cursor) {
						_ = os.close(temp_file)
						_ = os.remove(temp_path)
						return {}, fmt.tprintf("%s truncated inside blob %s", in_path, obj_hex_text)
					}
					cursor += i64(want)
					read_total += u64(want)
					blake3.hasher_update(&hasher, chunk_buf[:want])
					if !file_write_all(temp_file, chunk_buf[:want]) {
						_ = os.close(temp_file)
						_ = os.remove(temp_path)
						return {}, fmt.tprintf("cannot stage blob %s", obj_hex_text)
					}
				}
				if blake3.hasher_finish(&hasher) != rec.hash {
					_ = os.close(temp_file)
					_ = os.remove(temp_path)
					return {}, fmt.tprintf("blob %s verification failed (Hash_Mismatch)", obj_hex_text)
				}
				if !file_sync_and_close(temp_file) || !file_rename_durable(temp_path, final_path) {
					_ = os.remove(temp_path)
					return {}, fmt.tprintf("cannot commit verified blob %s", obj_hex_text)
				}
				if already_exists {
					objects_existing += 1
				} else {
					objects_imported += 1
				}
			}
		}

		seen_in_stream[rec.hash] = rec.kind
		last_hash = rec.hash
		last_kind = rec.kind
	}

	if last_hash != header.root_hash || last_kind != header.root_kind {
		return {}, "final object in closure stream does not match header root hash and kind"
	}

	real_buf: [object_cache.REALISATION_WIRE_SIZE]u8
	realisation_rec: object_cache.Realisation_Record
	if header.has_realisation {
		if !file_read_exact_at(in_file, real_buf[:], cursor) {
			return {}, fmt.tprintf("%s truncated inside trailing realisation record", in_path)
		}
		cursor += object_cache.REALISATION_WIRE_SIZE
		decoded_real, real_ref := object_cache.closure_realisation_verify(
			&header,
			real_buf[:],
			trusted_signers,
			closure_verify_ed25519_cb,
		)
		if real_ref != .None {
			return {}, fmt.tprintf("realisation verification failed (%v)", real_ref)
		}
		realisation_rec = decoded_real
	}

	// Refuse any trailing garbage past the end of the closure stream before committing realisation.
	trailing_probe: [1]u8
	extra_n, _ := os.read_at(in_file, trailing_probe[:], cursor)
	if extra_n > 0 {
		return {}, fmt.tprintf("%s contains trailing bytes past the closure stream", in_path)
	}

	if header.has_realisation {
		recipe_hex := hash_to_hex(realisation_rec.recipe_hash)
		written, _ := store_write_atomic(&server, .Realisations, string(recipe_hex[:]), real_buf[:])
		if !written {
			return {}, fmt.tprintf("cannot store verified realisation %s", string(recipe_hex[:]))
		}
	}

	return {
		root_hash        = header.root_hash,
		root_kind        = header.root_kind,
		objects_imported = objects_imported,
		objects_existing = objects_existing,
		bytes_read       = u64(cursor),
		has_realisation  = header.has_realisation,
		recipe_hash      = header.has_realisation ? realisation_rec.recipe_hash : {},
	}, ""
}

// run_cache_export implements:
//   modustool cache-export --dir <cache_dir> <root_hash> <out_file> [--realisation <recipe_hash>]
run_cache_export :: proc(args: []string) -> int {
	usage :: "modustool: cache-export --dir <cache_dir> <root_hash> <out_file> [--realisation <recipe_hash>]"
	cache_dir := ""
	realisation_arg := ""
	positional := make([dynamic]string, context.temp_allocator)

	for index := 0; index < len(args); index += 1 {
		arg := args[index]
		switch arg {
		case "--dir":
			if index + 1 >= len(args) {
				fmt.eprintln(usage)
				return foundation.EXIT_USAGE
			}
			index += 1
			cache_dir = args[index]
		case "--realisation":
			if index + 1 >= len(args) {
				fmt.eprintln(usage)
				return foundation.EXIT_USAGE
			}
			index += 1
			realisation_arg = args[index]
		case:
			if strings.has_prefix(arg, "--") {
				fmt.eprintfln("modustool: cache-export: unknown option %s", arg)
				fmt.eprintln(usage)
				return foundation.EXIT_USAGE
			}
			append(&positional, arg)
		}
	}

	if cache_dir == "" || len(positional) != 2 {
		fmt.eprintln(usage)
		return foundation.EXIT_USAGE
	}

	root_hash, root_ok := closure_hash_of_arg(positional[0])
	if !root_ok {
		fmt.eprintfln("modustool: cache-export: root hash must be 64 non-zero lowercase hexadecimal digits")
		return foundation.EXIT_USAGE
	}
	out_path := positional[1]

	recipe_hash: blake3.Hash
	has_recipe := false
	if realisation_arg != "" {
		r_hash, r_ok := closure_hash_of_arg(realisation_arg)
		if !r_ok {
			fmt.eprintfln("modustool: cache-export: --realisation must be 64 non-zero lowercase hexadecimal digits")
			return foundation.EXIT_USAGE
		}
		recipe_hash = r_hash
		has_recipe = true
	}

	stats, problem := cache_closure_export(cache_dir, root_hash, out_path, recipe_hash, has_recipe)
	if problem != "" {
		fmt.eprintfln("modustool: cache-export: %s", problem)
		return foundation.EXIT_FAILURE
	}

	root_hex := hash_to_hex(stats.root_hash)
	fmt.printfln(
		"modustool: cache-export: wrote %s (%d objects, %d bytes, root %s%s)",
		out_path,
		stats.object_count,
		stats.bytes_written,
		string(root_hex[:]),
		stats.has_realisation ? ", with realisation" : "",
	)
	return 0
}

// run_cache_import implements:
//   modustool cache-import --dir <cache_dir> <in_file> [--signer <public_key_file>]
run_cache_import :: proc(args: []string) -> int {
	usage :: "modustool: cache-import --dir <cache_dir> <in_file> [--signer <public_key_file>]"
	cache_dir := ""
	in_path := ""
	signers := make([dynamic][object_cache.PUBLIC_KEY_SIZE]u8, context.temp_allocator)
	positional := make([dynamic]string, context.temp_allocator)

	for index := 0; index < len(args); index += 1 {
		arg := args[index]
		switch arg {
		case "--dir":
			if index + 1 >= len(args) {
				fmt.eprintln(usage)
				return foundation.EXIT_USAGE
			}
			index += 1
			cache_dir = args[index]
		case "--signer":
			if index + 1 >= len(args) {
				fmt.eprintln(usage)
				return foundation.EXIT_USAGE
			}
			index += 1
			pub, ok := read_public_key_file("cache-import", args[index])
			if !ok {
				return foundation.EXIT_FAILURE
			}
			append(&signers, pub)
		case:
			if strings.has_prefix(arg, "--") {
				fmt.eprintfln("modustool: cache-import: unknown option %s", arg)
				fmt.eprintln(usage)
				return foundation.EXIT_USAGE
			}
			append(&positional, arg)
		}
	}

	if cache_dir == "" || len(positional) != 1 {
		fmt.eprintln(usage)
		return foundation.EXIT_USAGE
	}
	in_path = positional[0]

	stats, problem := cache_closure_import(cache_dir, in_path, signers[:])
	if problem != "" {
		fmt.eprintfln("modustool: cache-import: %s", problem)
		return foundation.EXIT_FAILURE
	}

	root_hex := hash_to_hex(stats.root_hash)
	fmt.printfln(
		"modustool: cache-import: verified %s (%d imported, %d existing, %d bytes, root %s%s)",
		in_path,
		stats.objects_imported,
		stats.objects_existing,
		stats.bytes_read,
		string(root_hex[:]),
		stats.has_realisation ? ", with realisation" : "",
	)
	return 0
}
