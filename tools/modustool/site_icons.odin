// The icons of the site (docs/SITE.md, "The icons"), but for their
// drawing: which icons the manifest names, and the checks of the icons
// that the pages and the manifest name. Each icon is a row of the table of
// the uses of the mark, and the generator of the pictures of the mark
// makes its file (mark_pictures.odin, mark_formats.odin): this file holds
// no number of a picture. The link elements of the head of a page are in
// site_frame.odin.
package modustool

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "modustool:foundation"
import "modustool:resources"

// One icon of the manifest: a file of the table of the uses of the mark,
// for any use or for a phone that cuts the icon to a shape.
Site_Manifest_Icon :: struct {
	file_name: string, // In the picture folder: a row of the table of the uses.
	maskable:  bool, // A phone can cut it to a shape: it is opaque.
}

// The icons of the manifest, in the order of the manifest. favicon.ico,
// the vector icon and the icon of a phone are named by the head.
site_manifest_icons := [?]Site_Manifest_Icon {
	{file_name = resources.SITE_ICON_192},
	{file_name = resources.SITE_ICON_512},
	{file_name = resources.SITE_ICON_MASKABLE, maskable = true},
}

// site_icon_problems checks the icons that the pages and the manifest name:
//   favicon.ico is at the root, its directory reads back, and it has a
//   picture of 32 by 32;
//   each icon of the head of each page and of the manifest is a file of the
//   site, with the size that the page or the manifest states;
//   the icon of a phone and each maskable icon are opaque;
//   the manifest has an icon of 192 and of 512 for any use, and a maskable
//   one of 512.
// The icon files are each file of the site that the check reads: their path
// in the site and their bytes.
site_icon_problems :: proc(pages: []Site_Page, written: map[string]string, manifest: string, icon_files: map[string][]u8) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	if favicon, has_favicon := icon_files[resources.SITE_FAVICON]; !has_favicon {
		append(&problems, resources.SITE_FAVICON + " is not at the root of the site")
	} else {
		entries, problem := resources.mark_ico_read(favicon)
		if problem != "" {
			append(&problems, fmt.tprintf("%s: %s", resources.SITE_FAVICON, problem))
		}
		has_32 := false
		for entry in entries {
			has_32 ||= entry.width == 32 && entry.height == 32
		}
		if problem == "" && !has_32 {
			append(&problems, resources.SITE_FAVICON + " has no picture of 32 by 32")
		}
	}
	// size_problem checks one icon: it exists, a stated size is its size,
	// and an icon that must be opaque is.
	size_problem :: proc(icon_files: map[string][]u8, path, sizes: string, must_be_opaque: bool) -> string {
		data, found := icon_files[path]
		if !found {
			return fmt.tprintf("%s is not an icon that the command wrote", path)
		}
		if strings.has_suffix(path, ".png") {
			width, height, _ := foundation.site_png_size(data)
			if sizes != "" && sizes != fmt.tprintf("%dx%d", width, height) {
				return fmt.tprintf("%s is %d by %d, and its size is stated as %s", path, width, height, sizes)
			}
			if must_be_opaque && !site_png_is_opaque(data) {
				return fmt.tprintf("%s is not opaque", path)
			}
		} else if must_be_opaque {
			return fmt.tprintf("%s must be an opaque PNG file", path)
		}
		return ""
	}
	for page in pages {
		html := written[page.path]
		folder := page.path[:max(strings.last_index_byte(page.path, '/'), 0)]
		rest := html
		head_icons := 0
		for {
			start := strings.index(rest, "<link ")
			if start < 0 {
				break
			}
			end := strings.index_byte(rest[start:], '>')
			if end < 0 {
				break
			}
			tag := rest[start:start + end]
			rest = rest[start + end:]
			relation := site_first_attribute_value(tag, "rel=\"")
			if relation != "icon" && relation != "apple-touch-icon" {
				continue
			}
			head_icons += 1
			path := site_path_join(folder, site_first_attribute_value(tag, "href=\""))
			sizes := site_first_attribute_value(tag, "sizes=\"")
			if strings.has_suffix(path, ".ico") {
				sizes = "" // The ICO holds several sizes; its directory is checked above.
			}
			if problem := size_problem(icon_files, path, sizes, relation == "apple-touch-icon"); problem != "" {
				append(&problems, fmt.tprintf("%s: %s", page.path, problem))
			}
		}
		if head_icons == 0 {
			append(&problems, fmt.tprintf("%s: no icon in the head", page.path))
		}
	}
	value, err := json.parse_string(manifest, .JSON, false, context.temp_allocator)
	root, is_object := value.(json.Object)
	if err != .None || !is_object {
		append(&problems, SITE_MANIFEST + " does not parse")
		return problems[:]
	}
	icons, _ := root["icons"].(json.Array)
	any_192, any_512, maskable_512 := false, false, false
	for icon in icons {
		object, is_icon := icon.(json.Object)
		if !is_icon {
			continue
		}
		source, _ := object["src"].(json.String)
		sizes, _ := object["sizes"].(json.String)
		purpose, _ := object["purpose"].(json.String)
		maskable := purpose == "maskable"
		if problem := size_problem(icon_files, source, sizes, maskable); problem != "" {
			append(&problems, fmt.tprintf("%s: %s", SITE_MANIFEST, problem))
		}
		any_192 ||= !maskable && sizes == "192x192"
		any_512 ||= !maskable && sizes == "512x512"
		maskable_512 ||= maskable && sizes == "512x512"
	}
	if !any_192 || !any_512 || !maskable_512 {
		append(&problems, SITE_MANIFEST + " needs an icon of 192 and of 512 for any use, and a maskable icon of 512")
	}
	return problems[:]
}
