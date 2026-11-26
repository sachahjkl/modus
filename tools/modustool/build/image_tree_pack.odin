// Canonical IMGTREE1 manifest packing for boot images
// (src/md/features/objects_by_hash.md).
//
// Maps every non-boot-record data resource of a boot image into its structured
// '/' path in the canonical read-only image tree, strictly excluding all
// root-only boot and trust records, and cross-checks the encoded manifest
// against the generated Image_Entry table.
package build

import "core:fmt"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/font_outlines"
import "modus:contract/image_tree"
import "modus:contract/manual_pages"
import "modus:contract/pointer_pictures"
import "modus:contract/store"
import "modus:contract/system_description"

// image_tree_object_path maps a boot-image resource name to its canonical
// structured object path in the image tree. Root-only boot and trust records
// return include = false and never enter the tree.
image_tree_object_path :: proc(resource_name: string) -> (path: string, include: bool, problem: string) {
	if image_tree.is_reserved_boot_record(resource_name) {
		return "", false, ""
	}
	switch resource_name {
	case pointer_pictures.RESOURCE_OF_THE_OWNER:
		return "pointer_themes/posy", true, ""
	case pointer_pictures.RESOURCE_OF_THE_SYSTEM:
		return "pointer_themes/system", true, ""
	case font_outlines.RESOURCE_NAME:
		return "fonts/font_outlines", true, ""
	case font_outlines.SCRIPT_FONTS_NAME_RESOURCE:
		return "fonts/script_fonts_name", true, ""
	case manual_pages.RESOURCE_NAME:
		return "manual/pages", true, ""
	}
	if _, path_problem, _, _ := store.object_path_validate(resource_name); path_problem != .None {
		return "", false, fmt.tprintf("resource %q is not a valid image-tree path (%v)", resource_name, path_problem)
	}
	return resource_name, true, ""
}

// image_tree_manifest_of_resources encodes the canonical IMGTREE1 manifest for
// resource_files (whose 0-based indices match the resource table of the boot
// image). All root-only boot and trust records are strictly excluded.
image_tree_manifest_of_resources :: proc(resource_files: []Image_File, allocator := context.temp_allocator) -> (manifest: []u8, problem: string) {
	specs := make([dynamic]image_tree.Object_Spec, 0, len(resource_files), context.temp_allocator)
	max_segments := 0
	total_path_bytes := 0

	for item, index in resource_files {
		object_path, include, map_problem := image_tree_object_path(item.name)
		if map_problem != "" {
			return nil, map_problem
		}
		if !include {
			continue
		}
		seg_count, path_problem, _, _ := store.object_path_validate(object_path)
		if path_problem != .None {
			return nil, fmt.tprintf("mapped path %q for resource %q failed validation (%v)", object_path, item.name, path_problem)
		}
		append(&specs, image_tree.Object_Spec {
			path              = object_path,
			image_entry_index = u32(index),
			size              = u64(len(item.file)),
			hash              = blake3.hash(item.file),
		})
		max_segments += seg_count
		total_path_bytes += len(object_path)
	}

	// Format property: each path segment can create at most one entry and at
	// most one non-root subtree node, plus the root node.
	node_scratch_cap := max(1, min(1 + max_segments, image_tree.NODE_CAPACITY))
	entry_scratch_cap := max(1, min(max_segments, image_tree.ENTRY_CAPACITY))
	nodes_scratch := make([]image_tree.Draft_Node, node_scratch_cap, context.temp_allocator)
	entries_scratch := make([]image_tree.Draft_Entry, entry_scratch_cap, context.temp_allocator)

	out_cap := image_tree.HEADER_SIZE + node_scratch_cap * image_tree.NODE_RECORD_SIZE + entry_scratch_cap * image_tree.ENTRY_RECORD_SIZE + total_path_bytes
	raw := make([]u8, out_cap, allocator)

	written, encode_problem := image_tree.encode_from_objects(specs[:], nodes_scratch, entries_scratch, raw)
	if encode_problem != .None {
		return nil, fmt.tprintf("cannot encode image_tree manifest: %v", encode_problem)
	}
	encoded := raw[:written]
	if _, validate_problem := image_tree.validate(encoded); validate_problem != .None {
		return nil, fmt.tprintf("encoded image_tree manifest failed validation: %v", validate_problem)
	}
	return encoded, ""
}

// image_tree_append_to_files builds the canonical IMGTREE1 manifest for
// files[module_count:] and appends it as the resource named image_tree.RESOURCE_NAME.
image_tree_append_to_files :: proc(files: ^[dynamic]Image_File, module_count: int, allocator := context.temp_allocator) -> string {
	if module_count < 0 || module_count > len(files) {
		return "module_count is out of range for image_tree packing"
	}
	manifest, problem := image_tree_manifest_of_resources(files[module_count:], allocator)
	if problem != "" {
		return problem
	}
	append(files, Image_File{name = image_tree.RESOURCE_NAME, file = manifest})
	return ""
}

// boot_image_verify_image_tree finds the image_tree resource inside an encoded
// boot image and validates it against the image's Image_Entry resource table.
boot_image_verify_image_tree :: proc(image: []u8) -> string {
	_, resources, valid := info.image_tables(image)
	if !valid {
		return "encoded bytes are not a valid boot image"
	}
	manifest_bytes: []u8
	found_count := 0
	for &entry in resources {
		if system_description.name_of(&entry.name) != image_tree.RESOURCE_NAME {
			continue
		}
		bytes, inside := info.image_entry_bytes(image, &entry)
		if !inside {
			return "image_tree entry points outside the boot image"
		}
		manifest_bytes = bytes
		found_count += 1
	}
	if found_count == 0 {
		return "boot image holds no image_tree manifest"
	}
	if found_count > 1 {
		return "boot image holds duplicate image_tree manifests"
	}
	if _, problem := image_tree.validate_against_resources(manifest_bytes, resources); problem != .None {
		return fmt.tprintf("image_tree manifest failed validate_against_resources: %v", problem)
	}
	return ""
}
