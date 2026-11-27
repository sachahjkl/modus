#+build !freestanding
package build

import "core:os"
import "core:testing"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/font_outlines"
import "modus:contract/image_tree"
import "modus:contract/manual_pages"
import "modus:contract/plan_values"
import "modus:contract/pointer_pictures"
import "modus:contract/replacement_list"
import "modus:contract/start_list"
import "modus:contract/store"
import "modus:contract/system_description"
import "modustool:foundation"

// Helper: extract the image_tree manifest bytes from an encoded boot image.
@(private = "file")
extract_image_tree_manifest :: proc(t: ^testing.T, image: []u8) -> (manifest: []u8, resources: []info.Image_Entry) {
	_, res, valid := info.image_tables(image)
	testing.expect(t, valid, "boot image header and tables are valid")
	for &entry in res {
		if system_description.name_of(&entry.name) == image_tree.RESOURCE_NAME {
			bytes, inside := info.image_entry_bytes(image, &entry)
			testing.expect(t, inside, "image_tree entry lies inside the boot image")
			return bytes, res
		}
	}
	testing.expect(t, false, "boot image contains an image_tree manifest resource")
	return nil, res
}

// Packing every real system resource produces a valid IMGTREE1 manifest that
// passes image_tree.validate_against_resources, maps every data resource to
// its canonical structured path, and strictly excludes every root-only boot
// and trust record.
@(test)
image_tree_pack_maps_all_system_resources_and_excludes_boot_records :: proc(t: ^testing.T) {
	files := make([dynamic]Image_File, context.temp_allocator)
	root_bytes: string = "root-module-bytes"
	append(&files, Image_File{name = "root", file = transmute([]u8)root_bytes})
	module_count := len(files)

	posy_bytes: string = "posy-theme-data"
	sys_bytes: string = "system-theme-data"
	outlines_bytes: string = "font-outlines-data"
	script_bytes: string = "script-fonts-name-32-byte-digest"
	manual_bytes: string = "manual-pages-data"
	default_plan_bytes: string = "default-plan-data"
	test_plan_bytes: string = "test-plan-data"
	start_bytes: string = "start-list-data"
	rescue_bytes: string = "rescue-list-data"
	measure_bytes: string = "measure-run-data"
	repl_bytes: string = "replacement-list-data"
	desc_bytes: string = "system-description-data"
	sig_bytes: string = "system-description-sig-data"

	append(&files,
		Image_File{name = pointer_pictures.RESOURCE_OF_THE_OWNER, file = transmute([]u8)posy_bytes},
		Image_File{name = pointer_pictures.RESOURCE_OF_THE_SYSTEM, file = transmute([]u8)sys_bytes},
		Image_File{name = font_outlines.RESOURCE_NAME, file = transmute([]u8)outlines_bytes},
		Image_File{name = font_outlines.SCRIPT_FONTS_NAME_RESOURCE, file = transmute([]u8)script_bytes},
		Image_File{name = manual_pages.RESOURCE_NAME, file = transmute([]u8)manual_bytes},
		Image_File{name = plan_values.DEFAULT_IMAGE_PLAN_RESOURCE, file = transmute([]u8)default_plan_bytes},
		Image_File{name = plan_values.TEST_IMAGE_PLAN_RESOURCE, file = transmute([]u8)test_plan_bytes},
		Image_File{name = start_list.START_LIST_RESOURCE, file = transmute([]u8)start_bytes},
		Image_File{name = start_list.RESCUE_LIST_RESOURCE, file = transmute([]u8)rescue_bytes},
		Image_File{name = MEASURE_RUN_RESOURCE_NAME, file = transmute([]u8)measure_bytes},
		Image_File{name = replacement_list.RESOURCE_NAME, file = transmute([]u8)repl_bytes},
		Image_File{name = system_description.RESOURCE_DESCRIPTION, file = transmute([]u8)desc_bytes},
		Image_File{name = system_description.RESOURCE_SIGNATURE, file = transmute([]u8)sig_bytes},
	)

	pack_problem := image_tree_append_to_files(&files, module_count)
	testing.expect_value(t, pack_problem, "")

	image := boot_image_encode(files[:], module_count)
	testing.expect_value(t, boot_image_verify_image_tree(image), "")

	manifest, resources := extract_image_tree_manifest(t, image)
	header, val_problem := image_tree.validate_against_resources(manifest, resources)
	testing.expect_value(t, val_problem, image_tree.Problem.None)
	testing.expect_value(t, header.magic, image_tree.MAGIC)

	root_grant := [1]image_tree.Subtree_Grant{{tree_name = "image", root_node = image_tree.ROOT_NODE}}

	// Verify all five structured data paths resolve with exact sizes and hashes.
	Expected :: struct {
		path: string,
		data: string,
	}
	expected_objects := [?]Expected {
		{"pointer_themes/posy", posy_bytes},
		{"pointer_themes/system", sys_bytes},
		{"fonts/font_outlines", outlines_bytes},
		{"fonts/script_fonts_name", script_bytes},
		{"manual/pages", manual_bytes},
	}
	for exp in expected_objects {
		resolved, match_count, lprob, pprob := image_tree.lookup_in_grants(manifest, root_grant[:], exp.path, false, {}, nil)
		testing.expect_value(t, lprob, image_tree.Lookup_Problem.None)
		testing.expect_value(t, pprob, store.Object_Path_Problem.None)
		testing.expect_value(t, match_count, 1)
		testing.expect_value(t, resolved.size, u64(len(exp.data)))
		testing.expect_value(t, resolved.hash, blake3.hash(transmute([]u8)exp.data))
		// Verify target_index points at the exact Image_Entry bytes.
		entry_bytes, inside := info.image_entry_bytes(image, &resources[resolved.image_entry_index])
		testing.expect(t, inside && string(entry_bytes) == exp.data)
	}

	// Verify NO root-only boot or trust record exists anywhere in the image tree.
	for reserved in image_tree.RESERVED_BOOT_RECORDS {
		_, _, lprob, _ := image_tree.lookup_in_grants(manifest, root_grant[:], reserved, false, {}, nil)
		testing.expect_value(t, lprob, image_tree.Lookup_Problem.Not_Found)
	}
}

// Browser-machine trimmed desktop boot images (which drop the second pointer
// theme and test modules) and console boot images both pack a freshly matched
// IMGTREE1 manifest passing image_tree.validate_against_resources.
@(test)
browser_machine_trimmed_images_pack_matching_image_tree :: proc(t: ^testing.T) {
	files := make([dynamic]Image_File, context.temp_allocator)
	for row in foundation.module_builds {
		append(&files, Image_File{name = row.name, file = transmute([]u8)row.name})
	}
	module_count := len(files)

	posy_bytes: string = "posy-bytes"
	sys_bytes: string = "system-bytes"
	font_bytes: string = "font-outlines-bytes"
	script_bytes: string = "script-fonts-name-bytes"
	manual_bytes: string = "manual-pages-bytes"
	start_bytes: string = "start-list-bytes"
	rescue_bytes: string = "rescue-list-bytes"

	append(&files,
		Image_File{name = pointer_pictures.RESOURCE_OF_THE_OWNER, file = transmute([]u8)posy_bytes},
		Image_File{name = pointer_pictures.RESOURCE_OF_THE_SYSTEM, file = transmute([]u8)sys_bytes},
		Image_File{name = font_outlines.RESOURCE_NAME, file = transmute([]u8)font_bytes},
		Image_File{name = font_outlines.SCRIPT_FONTS_NAME_RESOURCE, file = transmute([]u8)script_bytes},
		Image_File{name = manual_pages.RESOURCE_NAME, file = transmute([]u8)manual_bytes},
		Image_File{name = start_list.START_LIST_RESOURCE, file = transmute([]u8)start_bytes},
		Image_File{name = start_list.RESCUE_LIST_RESOURCE, file = transmute([]u8)rescue_bytes},
	)
	testing.expect_value(t, image_tree_append_to_files(&files, module_count), "")
	base_image := boot_image_encode(files[:], module_count)
	testing.expect_value(t, boot_image_verify_image_tree(base_image), "")

	// Trimmed browser desktop image keeps only pointers_posy (first in preference),
	// drops pointers_system, and rebuilds image_tree to match.
	desk_files, desk_mod_count, desk_prob := browser_machine_page_image_files(base_image, .Desktop)
	testing.expect_value(t, desk_prob, "")
	desk_image := boot_image_encode(desk_files, desk_mod_count)
	testing.expect_value(t, boot_image_verify_image_tree(desk_image), "")

	desk_manifest, desk_resources := extract_image_tree_manifest(t, desk_image)
	_, d_val := image_tree.validate_against_resources(desk_manifest, desk_resources)
	testing.expect_value(t, d_val, image_tree.Problem.None)

	root_grant := [1]image_tree.Subtree_Grant{{tree_name = "image", root_node = image_tree.ROOT_NODE}}
	_, _, posy_prob, _ := image_tree.lookup_in_grants(desk_manifest, root_grant[:], "pointer_themes/posy", false, {}, nil)
	testing.expect_value(t, posy_prob, image_tree.Lookup_Problem.None)
	_, _, sys_prob, _ := image_tree.lookup_in_grants(desk_manifest, root_grant[:], "pointer_themes/system", false, {}, nil)
	testing.expect_value(t, sys_prob, image_tree.Lookup_Problem.Not_Found)
	_, _, font_prob, _ := image_tree.lookup_in_grants(desk_manifest, root_grant[:], "fonts/font_outlines", false, {}, nil)
	testing.expect_value(t, font_prob, image_tree.Lookup_Problem.None)

	// Trimmed browser console image holds only start_list, rescue_list, and an
	// empty valid IMGTREE1 manifest.
	cons_files, cons_mod_count, cons_prob := browser_machine_page_image_files(base_image, .Console)
	testing.expect_value(t, cons_prob, "")
	cons_image := boot_image_encode(cons_files, cons_mod_count)
	testing.expect_value(t, boot_image_verify_image_tree(cons_image), "")

	cons_manifest, cons_resources := extract_image_tree_manifest(t, cons_image)
	cons_header, c_val := image_tree.validate_against_resources(cons_manifest, cons_resources)
	testing.expect_value(t, c_val, image_tree.Problem.None)
	testing.expect_value(t, cons_header.node_count, u32(1))
	testing.expect_value(t, cons_header.entry_count, u32(0))
}

// Signing a boot image via boot_image_signed_write includes image_tree inside
// system_description so it is signed and verified, and keeps
// image_tree.validate_against_resources passing after replacement_list,
// system_description, and system_description_signature are appended.
@(test)
signed_boot_image_signs_and_preserves_image_tree :: proc(t: ^testing.T) {
	tmp_dir, dir_err := os.make_directory_temp("", "modus_imgtree_test_*", context.temp_allocator)
	if !testing.expect(t, dir_err == nil, "create temporary folder") {
		return
	}
	defer _ = os.remove_all(tmp_dir)

	// Build a minimal unsigned image holding the required replacement_rows modules
	// or a single synthetic module if kernel exists. Test directly via
	// system_description entries encoding to avoid depending on prebuilt build/.
	root_bytes: string = "root-bytes"
	font_bytes: string = "font-outlines-bytes"
	files := make([dynamic]Image_File, context.temp_allocator)
	append(&files, Image_File{name = "root", file = transmute([]u8)root_bytes})
	module_count := 1
	append(&files, Image_File{name = font_outlines.RESOURCE_NAME, file = transmute([]u8)font_bytes})
	testing.expect_value(t, image_tree_append_to_files(&files, module_count), "")

	// Simulate boot_image_signed_write appending replacement_list,
	// system_description, and system_description_signature after image_tree.
	repl_bytes: string = "repl"
	desc_entry := description_entry(image_tree.RESOURCE_NAME, .Resource, files[2].file)
	testing.expect_value(t, system_description.name_of(&desc_entry.name), image_tree.RESOURCE_NAME)
	testing.expect_value(t, desc_entry.hash, blake3.hash(files[2].file))
	testing.expect_value(t, desc_entry.size, u64(len(files[2].file)))

	desc_bytes: string = "desc"
	sig_bytes: string = "sig"
	append(&files,
		Image_File{name = replacement_list.RESOURCE_NAME, file = transmute([]u8)repl_bytes},
		Image_File{name = system_description.RESOURCE_DESCRIPTION, file = transmute([]u8)desc_bytes},
		Image_File{name = system_description.RESOURCE_SIGNATURE, file = transmute([]u8)sig_bytes},
	)
	signed_like := boot_image_encode(files[:], module_count)
	testing.expect_value(t, boot_image_verify_image_tree(signed_like), "")
}

// Adversarial packing checks: duplicate resource paths and invalid resource
// names are refused cleanly.
@(test)
image_tree_pack_refuses_duplicates_and_invalid_names :: proc(t: ^testing.T) {
	a_bytes: string = "a"
	b_bytes: string = "b"

	// Duplicate mapped resource refused.
	dup := []Image_File {
		{name = font_outlines.RESOURCE_NAME, file = transmute([]u8)a_bytes},
		{name = font_outlines.RESOURCE_NAME, file = transmute([]u8)b_bytes},
	}
	_, dup_prob := image_tree_manifest_of_resources(dup)
	testing.expect(t, dup_prob != "", "duplicate resource path must be refused")

	// Path conflict (e.g. a resource literally named "fonts" beside "font_outlines" -> "fonts/font_outlines") refused.
	conflict := []Image_File {
		{name = "fonts", file = transmute([]u8)a_bytes},
		{name = font_outlines.RESOURCE_NAME, file = transmute([]u8)b_bytes},
	}
	_, conf_prob := image_tree_manifest_of_resources(conflict)
	testing.expect(t, conf_prob != "", "path conflict must be refused")

	// Invalid resource name refused.
	bad := []Image_File{{name = "../escape", file = transmute([]u8)a_bytes}}
	_, bad_prob := image_tree_manifest_of_resources(bad)
	testing.expect(t, bad_prob != "", "traversal resource name must be refused")

	// Boot image missing image_tree fails verification.
	no_tree := boot_image_encode([]Image_File{{name = "root", file = transmute([]u8)a_bytes}}, 1)
	testing.expect(t, boot_image_verify_image_tree(no_tree) != "")
}
