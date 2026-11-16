package modustool

import "modus:contract/pointer_pictures"
import "modus:support/graphics"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// An image of an Xcursor file that the tests write.
@(private = "file")
Test_Image :: struct {
	nominal_size, width, height, hot_spot_x, hot_spot_y, delay: u32,
}

// xcursor_write writes an Xcursor file with a comment chunk first, then
// the images, each pixel 0xFF000000 + its index (opaque, premultiplied).
@(private = "file")
xcursor_write :: proc(images: []Test_Image) -> []u8 {
	bytes := make([dynamic]u8, context.temp_allocator)
	word :: proc(bytes: ^[dynamic]u8, value: u32) {
		append(bytes, u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24))
	}
	entries := u32(len(images) + 1)
	word(&bytes, XCURSOR_MAGIC)
	word(&bytes, XCURSOR_FILE_HEADER)
	word(&bytes, 0x10000)
	word(&bytes, entries)
	position := XCURSOR_FILE_HEADER + entries * 12
	comment := "made by a test"
	word(&bytes, 0xFFFE0001)
	word(&bytes, 3)
	word(&bytes, position)
	position += 20 + u32(len(comment))
	for image in images {
		word(&bytes, XCURSOR_IMAGE_TYPE)
		word(&bytes, image.nominal_size)
		word(&bytes, position)
		position += XCURSOR_IMAGE_HEADER + image.width * image.height * 4
	}
	word(&bytes, 20)
	word(&bytes, 0xFFFE0001)
	word(&bytes, 3)
	word(&bytes, 1)
	word(&bytes, u32(len(comment)))
	append(&bytes, ..transmute([]u8)comment)
	for image in images {
		for value in ([?]u32{XCURSOR_IMAGE_HEADER, XCURSOR_IMAGE_TYPE, image.nominal_size, 1, image.width, image.height, image.hot_spot_x, image.hot_spot_y, image.delay}) {
			word(&bytes, value)
		}
		for index in 0 ..< image.width * image.height {
			word(&bytes, 0xFF000000 + index)
		}
	}
	return bytes[:]
}

@(private = "file")
two_sizes := [?]Test_Image{{nominal_size = 4, width = 4, height = 3, hot_spot_x = 1, hot_spot_y = 2}, {nominal_size = 8, width = 8, height = 6, hot_spot_x = 2, hot_spot_y = 4}}

@(test)
xcursor_reader_reads_each_image :: proc(t: ^testing.T) {
	file := xcursor_write(two_sizes[:])
	images := make([dynamic]Xcursor_Image, context.temp_allocator)
	testing.expect_value(t, xcursor_read(file, &images), "")
	testing.expect_value(t, len(images), 2)
	testing.expect_value(t, images[1].nominal_size, 8)
	testing.expect_value(t, images[1].hot_spot_y, 4)
	testing.expect_value(t, len(images[1].pixels), 48)
	testing.expect_value(t, images[1].pixels[47], 0xFF000000 + 47)
	free_all(context.temp_allocator)
}

// Each field of an Xcursor file, damaged: the reader gives the sentence
// that names it, and reads no byte out of the file.
@(test)
xcursor_reader_refuses_each_damage :: proc(t: ^testing.T) {
	Damage :: struct {
		offset: int, // The byte of the word to change.
		value:  u32,
		says:   string, // A part of the sentence.
	}
	file := xcursor_write(two_sizes[:])
	first_image := XCURSOR_FILE_HEADER + 3 * 12 + 20 + len("made by a test")
	damages := [?]Damage {
		{0, 0x12345678, "not \"Xcur\""},
		{4, 8, "the header has 8 bytes"},
		{4, 100000, "the header has 100000 bytes"},
		{12, 1 << 20, "entries of the table of contents do not fit"},
		{12, 100, "entries of the table of contents do not fit"},
		{XCURSOR_FILE_HEADER + 12 + 8, 1 << 30, "past the end of the file"},
		{first_image, 40, "the image header has 40 bytes"},
		{first_image + 8, 5, "the table of contents says"},
		{XCURSOR_FILE_HEADER + 12 + 4, 5, "the table of contents says"},
		{first_image + 12, 2, "the version 2"},
		{first_image + 16, 0, "each side must be 1 to 32767"},
		{first_image + 20, 0x8000, "each side must be 1 to 32767"},
		{first_image + 24, 4, "is not a pixel of the image"},
		{first_image + 28, 3, "is not a pixel of the image"},
		{first_image + 20, 3000, "pass the end of the file"},
	}
	for damage in damages {
		changed := make([]u8, len(file), context.temp_allocator)
		copy(changed, file)
		for byte in 0 ..< 4 {
			changed[damage.offset + byte] = u8(damage.value >> uint(8 * byte))
		}
		images := make([dynamic]Xcursor_Image, context.temp_allocator)
		problem := xcursor_read(changed, &images)
		testing.expectf(t, strings.contains(problem, damage.says), "the word at %d set to %d: got \"%s\", not \"%s\"", damage.offset, damage.value, problem, damage.says)
	}
	// A file cut at each length.
	for length in 0 ..< len(file) {
		images := make([dynamic]Xcursor_Image, context.temp_allocator)
		testing.expectf(t, xcursor_read(file[:length], &images) != "", "a file of %d bytes was accepted", length)
	}
	images := make([dynamic]Xcursor_Image, context.temp_allocator)
	testing.expect_value(t, xcursor_read(xcursor_write(nil), &images), "the file has no image")
	free_all(context.temp_allocator)
}

@(private = "file")
OUTLINE_MANIFEST :: `# a test
theme Test theme
license MIT
attribution first line,
attribution second line
sizes 4 8
shape arrow hot 1 0
layer edge
contour 0 0 line 2 0 line 0 2   # a right triangle with legs of 2 units
shape wait hot 0 0
layer fill inside
contour 0 0 line 1 0 line 1 1 line 0 1
frame 100
layer edge
contour 0 0 line 0.5 0 line 0.5 1 line 0 1
frame 200
layer clear
contour 0 0 line 1 0 line 1 1 line 0 1
`

// painted gives a pixel after a paint of a color with a coverage over the
// pixel before it, premultiplied: the rule of the tool, by hand.
@(private = "file")
painted :: proc(color: u32, covered: u32, before: u32) -> u32 {
	paint := 0xFF000000 | color
	result: u32 = 0
	for shift in ([?]u32{0, 8, 16, 24}) {
		result |= (((paint >> shift) & 0xFF) * covered + ((before >> shift) & 0xFF) * (255 - covered) + 127) / 255 << shift
	}
	return result
}

// The golden pixels of an outline: the exact coverage of each pixel, the
// paint of each layer over the layers before, the box of the pictures of
// one size with the hot spot in it, the frames of an animation, and the
// colors of each form.
@(test)
manifest_of_outlines_makes_a_valid_file :: proc(t: ^testing.T) {
	manifest, problem := manifest_parse("test.manifest", OUTLINE_MANIFEST)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, manifest.attribution, "first line, second line")
	file, rows, made_problem := pointer_theme_make(manifest, "")
	testing.expect_value(t, made_problem, "")
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, pointer_pictures.validate(file).kind, pointer_pictures.Problem_Kind.None)
	head := pointer_pictures.header(file)
	testing.expect_value(t, pointer_pictures.text_of(head.theme_name[:]), "Test theme")
	testing.expect_value(t, head.form_count, u32(len(pointer_pictures.Pointer_Form)))
	testing.expect_value(t, head.shape_count, 2)
	// For each form: the arrow at 2 sizes, wait at 2 sizes with 2 frames.
	testing.expect_value(t, head.picture_count, 6 * u32(len(pointer_pictures.Pointer_Form)))
	for form in pointer_pictures.Pointer_Form {
		edge := POINTER_FORM_COLORS[form].edge
		fill := POINTER_FORM_COLORS[form].fill
		// The triangle at 4: the pixel 0,0 is whole, the pixels 1,0 and 0,1
		// are cut by the slanted side in two halves, and 1,1 is outside.
		// The box is 2 x 2; the hot spot 1,0 is in it.
		full, half := painted(edge, 255, 0), painted(edge, 128, 0)
		chosen := pointer_pictures.choose(file, form, .Arrow, 4, 0)
		testing.expect_value(t, chosen.picture.width, 2)
		testing.expect_value(t, chosen.picture.height, 2)
		testing.expect_value(t, chosen.picture.hot_spot_x, 1)
		testing.expect_value(t, chosen.picture.hot_spot_y, 0)
		golden := [4]u32{full, half, half, 0}
		for pixel, index in chosen.pixels {
			testing.expectf(t, pixel == golden[index], "%v: the pixel %d of the arrow at 4 is 0x%08x, not 0x%08x", form, index, pixel, golden[index])
		}
		// At 8 a unit is 2 pixels: the box is 4 x 4 and the hot spot is 2,0.
		chosen = pointer_pictures.choose(file, form, .Arrow, 8, 0)
		testing.expect_value(t, chosen.picture.width, 4)
		testing.expect_value(t, chosen.picture.height, 4)
		testing.expect_value(t, chosen.picture.hot_spot_x, 2)
		testing.expect_value(t, chosen.pixels[0], full)
		testing.expect_value(t, chosen.pixels[3], half)
		testing.expect_value(t, chosen.pixels[15], 0)
		// The first frame: half of the pixel in the edge color over the
		// fill. The second: the pixel cleared, with the edge of 1 pixel
		// around it; the box of the size holds both frames.
		chosen = pointer_pictures.choose(file, form, .Wait, 4, 0)
		testing.expect_value(t, chosen.picture.width, 2)
		testing.expect_value(t, chosen.picture.delay_milliseconds, 100)
		testing.expect_value(t, chosen.pixels[0], painted(edge, 128, painted(fill, 255, 0)))
		testing.expect_value(t, chosen.pixels[3], 0)
		chosen = pointer_pictures.choose(file, form, .Wait, 4, 150)
		testing.expect_value(t, chosen.picture.delay_milliseconds, 200)
		testing.expect_value(t, chosen.pixels[0], 0)
		testing.expect_value(t, chosen.pixels[1], full)
		testing.expect_value(t, chosen.pixels[3], full)
	}
	free_all(context.temp_allocator)
}

// The edge of a fill is 1 pixel at every size, inside the contour: a
// square of 6 units has 1 pixel of edge at 8 and at 16, and the fill grows.
@(test)
outline_edge_is_one_pixel_at_each_size :: proc(t: ^testing.T) {
	manifest, problem := manifest_parse("m", "theme T\nlicense MIT\nsizes 8 16\nshape arrow hot 1 1\nlayer fill\ncontour 1 1 line 7 1 line 7 7 line 1 7\n")
	testing.expect_value(t, problem, "")
	file, _, made_problem := pointer_theme_make(manifest, "")
	testing.expect_value(t, made_problem, "")
	for form in pointer_pictures.Pointer_Form {
		edge, fill := painted(POINTER_FORM_COLORS[form].edge, 255, 0), painted(POINTER_FORM_COLORS[form].fill, 255, 0)
		for size in ([?]u32{8, 16}) {
			chosen := pointer_pictures.choose(file, form, .Arrow, size, 0)
			side := int(size) * 6 / 8
			testing.expect_value(t, int(chosen.picture.width), side)
			testing.expect_value(t, chosen.picture.hot_spot_x, 0)
			for y in 0 ..< side {
				for x in 0 ..< side {
					border := x == 0 || y == 0 || x == side - 1 || y == side - 1
					testing.expectf(t, chosen.pixels[y * side + x] == (border ? edge : fill), "%v at %d: the pixel %d,%d is 0x%08x", form, size, x, y, chosen.pixels[y * side + x])
				}
			}
		}
	}
	free_all(context.temp_allocator)
}

// Two contours of one layer that overlap in opposite directions are a
// union: the tool adds each contour in one direction, so they do not cancel.
@(test)
outline_contours_of_one_layer_are_a_union :: proc(t: ^testing.T) {
	text := "theme T\nlicense MIT\nsizes 4\nshape arrow hot 0 0\nlayer edge\ncontour 0 0 line 2 0 line 2 1 line 0 1\ncontour 0 0 line 0 2 line 1 2 line 1 0\n"
	manifest, problem := manifest_parse("m", text)
	testing.expect_value(t, problem, "")
	file, _, made_problem := pointer_theme_make(manifest, "")
	testing.expect_value(t, made_problem, "")
	chosen := pointer_pictures.choose(file, .Dark, .Arrow, 4, 0)
	full_dark := painted(POINTER_FORM_COLORS[.Dark].edge, 255, 0)
	golden := [4]u32{full_dark, full_dark, full_dark, 0}
	testing.expect_value(t, len(chosen.pixels), 4)
	for pixel, index in chosen.pixels {
		testing.expectf(t, pixel == golden[index], "the pixel %d is 0x%08x, not 0x%08x", index, pixel, golden[index])
	}
	free_all(context.temp_allocator)
}

// The coverage of a circle is its area, less what the rasterizer loses when
// it cuts each curve into lines at most 1/8 pixel from it.
@(test)
outline_circle_covers_its_area :: proc(t: ^testing.T) {
	manifest, problem := manifest_parse("m", "theme T\nlicense MIT\nsizes 10\nshape arrow hot 5 5\nlayer fill inside\ncircle 5 5 4\n")
	testing.expect_value(t, problem, "")
	file, _, made_problem := pointer_theme_make(manifest, "")
	testing.expect_value(t, made_problem, "")
	chosen := pointer_pictures.choose(file, .Dark, .Arrow, 10, 0) // The fill of the dark form is white.
	testing.expect_value(t, chosen.picture.width, 8)
	testing.expect_value(t, chosen.picture.height, 8)
	sum := 0
	for pixel in chosen.pixels {
		sum += int(pixel >> 24)
		testing.expectf(t, pixel & 0xFF == pixel >> 24, "a light pixel is gray and premultiplied: 0x%08x", pixel)
	}
	radius := 4.0
	area := f64(sum) / 255
	least := math.PI * radius * radius - 2 * math.PI * radius / 8
	most := math.PI * radius * radius * 1.01
	testing.expectf(t, area >= least && area <= most, "the circle covers %.3f pixels: not %.3f to %.3f", area, least, most)
	free_all(context.temp_allocator)
}

// The theme of the system read from its manifest: the file of a theme of the
// system, as the build makes it.
@(private = "file")
system_theme_make :: proc(t: ^testing.T) -> (manifest: Manifest, file: []u8, ok: bool) {
	text, read_error := os.read_entire_file(SYSTEM_POINTER_MANIFEST, context.temp_allocator)
	testing.expect_value(t, read_error, nil)
	problem: string
	manifest, problem = manifest_parse(SYSTEM_POINTER_MANIFEST, string(text))
	testing.expect_value(t, problem, "")
	if problem != "" {
		return {}, nil, false
	}
	made_problem: string
	file, _, made_problem = pointer_theme_make(manifest, "")
	testing.expect_value(t, made_problem, "")
	return manifest, file, made_problem == ""
}

// Each shape of the enum is in each form of the theme of the system, at
// each size of the manifest, inside the square of its size with its hot
// spot, with an opaque pixel; the two animated shapes have frames.
@(test)
system_pointer_theme_draws_each_shape :: proc(t: ^testing.T) {
	manifest, file, ok := system_theme_make(t)
	if !ok {
		return
	}
	testing.expect_value(t, pointer_pictures.text_of(pointer_pictures.header(file).license[:]), "MIT")
	testing.expect_value(t, pointer_pictures.header(file).form_count, u32(len(pointer_pictures.Pointer_Form)))
	pictures := pointer_pictures.picture_entries(file)
	for item in manifest.shapes {
		name := pointer_pictures.SHAPE_NAMES[item.shape]
		testing.expectf(t, len(item.sources) == 0, "%s is an outline", name)
	}
	for form in pointer_pictures.Pointer_Form do for shape in pointer_pictures.Pointer_Shape {
		name := pointer_pictures.SHAPE_NAMES[shape]
		entry, found := pointer_pictures.shape_entry_of(file, form, shape)
		testing.expectf(t, found, "the theme of the system has the shape %s", name)
		if !found {
			continue
		}
		animated := shape == .Wait || shape == .Busy_With_Arrow
		testing.expectf(t, (entry.frame_count > 1) == animated, "%s has %d frames", name, entry.frame_count)
		testing.expectf(t, entry.size_count == u32(len(manifest.sizes)), "%s has %d sizes", name, entry.size_count)
		hot_spot: [2]u32
		for item in manifest.shapes {
			if item.shape == shape {
				hot_spot = item.hot_spot
			}
		}
		for picture_index in entry.first_picture ..< entry.first_picture + entry.size_count * entry.frame_count {
			picture := pictures[picture_index]
			size := picture.nominal_size
			// Where the box of the picture is in the square of its size: the
			// hot spot of the manifest less the hot spot in the box.
			left := int(hot_spot.x * size / manifest.sizes[0]) - int(picture.hot_spot_x)
			top := int(hot_spot.y * size / manifest.sizes[0]) - int(picture.hot_spot_y)
			inside := left >= 0 && top >= 0 && left + int(picture.width) <= int(size) && top + int(picture.height) <= int(size)
			testing.expectf(t, inside, "%s at %d: the box %d,%d of %d x %d is not inside the square", name, size, left, top, picture.width, picture.height)
			testing.expectf(t, picture.hot_spot_x < picture.width && picture.hot_spot_y < picture.height, "%s at %d: the hot spot is outside the picture", name, size)
			opaque := 0
			for pixel in pointer_pictures.pixels_of(file, picture) {
				if pixel >> 24 == 0xFF {
					opaque += 1
				}
			}
			testing.expectf(t, opaque > 0, "%s at %d: no opaque pixel", name, size)
		}
	}
	free_all(context.temp_allocator)
}

// is_fill_pixel says if an opaque pixel has the color of the fill of a form:
// white in the dark form, the dark of the desktop in the light form.
@(private = "file")
is_fill_pixel :: proc(pixel: u32, form: pointer_pictures.Pointer_Form) -> bool {
	if pixel >> 24 < 192 {
		return false
	}
	red := (pixel >> 16) & 0xFF
	return form == .Dark ? red >= 192 : red <= 64
}

// The edge goes all around the fill, in each form: no fill pixel of any
// picture touches a transparent pixel or the side of its picture. So the
// edge of each shape shows on a background of the color of the fill.
@(test)
system_pointer_theme_has_an_edge_around_its_fill :: proc(t: ^testing.T) {
	// The alpha of a pixel, 0 outside the picture.
	alpha_at :: proc(pixels: []u32, width, height, x, y: int) -> u32 {
		if x < 0 || y < 0 || x >= width || y >= height {
			return 0
		}
		return pixels[y * width + x] >> 24
	}
	_, file, ok := system_theme_make(t)
	if !ok {
		return
	}
	pictures := pointer_pictures.picture_entries(file)
	for form in pointer_pictures.Pointer_Form do for entry in pointer_pictures.shape_entries(file, form) {
		name := pointer_pictures.shape_name(entry.shape)
		for picture_index in entry.first_picture ..< entry.first_picture + entry.size_count * entry.frame_count {
			picture := pictures[picture_index]
			pixels := pointer_pictures.pixels_of(file, picture)
			width, height := int(picture.width), int(picture.height)
			for y in 0 ..< height {
				for x in 0 ..< width {
					if !is_fill_pixel(pixels[y * width + x], form) {
						continue
					}
					touches := alpha_at(pixels, width, height, x - 1, y) == 0 || alpha_at(pixels, width, height, x + 1, y) == 0 || alpha_at(pixels, width, height, x, y - 1) == 0 || alpha_at(pixels, width, height, x, y + 1) == 0
					testing.expectf(t, !touches, "%v %s, picture %d (size %d): the fill pixel %d,%d touches a transparent pixel", form, name, picture_index, picture.nominal_size, x, y)
				}
			}
		}
	}
	free_all(context.temp_allocator)
}

// Each form shows on the surfaces of its appearance: the fill has 7 to 1
// at least on each of them, and the edge and the fill 15 to 1. Each accent
// keeps 3 to 1 on the color around it: its value for a dark surround on the
// dark of the desktop, its value for a light surround on white.
@(test)
pointer_colors_show_on_the_surfaces_of_each_form :: proc(t: ^testing.T) {
	dark, light := graphics.DARK_COLOR_TOKENS, graphics.LIGHT_COLOR_TOKENS
	surfaces := [pointer_pictures.Pointer_Form][]graphics.Color {
		.Dark  = {dark.background, dark.card_top, dark.card_bottom, dark.track, dark.title_quiet, dark.title_end},
		.Light = {light.background, light.card_top, light.card_bottom, light.track, light.title_quiet},
	}
	for form in pointer_pictures.Pointer_Form {
		colors := POINTER_FORM_COLORS[form]
		testing.expectf(t, site_contrast_ratio(colors.edge, colors.fill) >= 15, "%v: the edge and the fill: %.2f to 1", form, site_contrast_ratio(colors.edge, colors.fill))
		for surface in surfaces[form] {
			ratio := site_contrast_ratio(colors.fill, surface)
			testing.expectf(t, ratio >= 7, "%v: the fill on 0x%06x has %.2f to 1", form, surface, ratio)
		}
	}
	accents := pointer_accents()
	for accent in accents {
		on_dark := site_contrast_ratio(accent.on_dark, POINTER_DARK_COLOR)
		on_light := site_contrast_ratio(accent.on_light, POINTER_LIGHT_COLOR)
		testing.expectf(t, on_dark >= 3 && on_light >= 3, "the accent %s: %.2f to 1 on the dark, %.2f to 1 on white", accent.name, on_dark, on_light)
	}
}

// The accents of the theme of the system, by shape: each other shape has
// none. The arrow stays neutral.
@(private = "file")
SYSTEM_ACCENTS := [pointer_pictures.Pointer_Shape]string {
	.Arrow                        = "",
	.Text                         = "",
	.Pointing_Hand                = "",
	.Move                         = "",
	.Grab                         = "",
	.Grabbing                     = "",
	.Wait                         = "title", // The dot that turns.
	.Busy_With_Arrow              = "title", // The dot that turns.
	.Forbidden                    = "stop_program", // The slash.
	.Help                         = "title", // The question mark.
	.Crosshair                    = "boot_program", // The dot at the hot spot.
	.Resize_Left_Right            = "",
	.Resize_Up_Down               = "",
	.Resize_Top_Left_Bottom_Right = "",
	.Resize_Top_Right_Bottom_Left = "",
}

// An accent is only on its parts: the manifest names the accent of the
// table for each shape and no other, and each picture of a shape with an
// accent has opaque pixels of a color that is not a mix of the edge and the
// fill, which no picture of another shape has.
@(test)
system_pointer_theme_has_accents_on_their_parts_only :: proc(t: ^testing.T) {
	manifest, file, ok := system_theme_make(t)
	if !ok {
		return
	}
	accents := pointer_accents()
	for item in manifest.shapes {
		named := make([dynamic]string, context.temp_allocator)
		layers := make([dynamic]Outline_Layer, context.temp_allocator)
		append(&layers, ..item.layers[:])
		for frame in item.frames {
			append(&layers, ..frame.layers[:])
		}
		for layer in layers {
			if layer.paint == .Accent && !slice.contains(named[:], accents[layer.accent].name) {
				append(&named, accents[layer.accent].name)
			}
		}
		expected := SYSTEM_ACCENTS[item.shape]
		right := expected == "" ? len(named) == 0 : len(named) == 1 && named[0] == expected
		testing.expectf(t, right, "%s has the accents %v, not %q", pointer_pictures.SHAPE_NAMES[item.shape], named[:], expected)
	}
	// A pixel off the line from the dark to white: each channel at another
	// part of its way from the dark to white.
	off_the_line :: proc(pixel: u32) -> bool {
		if pixel >> 24 != 0xFF {
			return false
		}
		part :: proc(pixel: u32, shift: u32) -> f64 {
			dark := f64((POINTER_DARK_COLOR >> shift) & 0xFF)
			return (f64((pixel >> shift) & 0xFF) - dark) / (255 - dark)
		}
		red, green, blue := part(pixel, 16), part(pixel, 8), part(pixel, 0)
		return max(red, green, blue) - min(red, green, blue) > 0.08
	}
	pictures := pointer_pictures.picture_entries(file)
	for form in pointer_pictures.Pointer_Form do for entry in pointer_pictures.shape_entries(file, form) {
		name := pointer_pictures.shape_name(entry.shape)
		has_accent := SYSTEM_ACCENTS[pointer_pictures.Pointer_Shape(entry.shape)] != ""
		for picture_index in entry.first_picture ..< entry.first_picture + entry.size_count * entry.frame_count {
			picture := pictures[picture_index]
			colored := 0
			for pixel in pointer_pictures.pixels_of(file, picture) {
				if off_the_line(pixel) {
					colored += 1
				}
			}
			testing.expectf(t, (colored > 0) == has_accent, "%v %s, picture %d (size %d): %d pixels of an accent", form, name, picture_index, picture.nominal_size, colored)
		}
	}
	free_all(context.temp_allocator)
}

// The theme file of the system: two makes give the same bytes, and the file
// written and read back is valid and gives each shape at each size.
@(test)
system_pointer_theme_file_round_trip :: proc(t: ^testing.T) {
	manifest, file, ok := system_theme_make(t)
	if !ok {
		return
	}
	again, _, again_problem := pointer_theme_make(manifest, "")
	testing.expect_value(t, again_problem, "")
	testing.expect(t, slice.equal(file, again), "two makes of the theme of the system give the same bytes")
	folder, err := os.make_directory_temp("", "pointers_test_*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(folder)
	path := fmt.tprintf("%s/system.pointers", folder)
	testing.expect_value(t, os.write_entire_file(path, file), nil)
	read, read_error := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, read_error, nil)
	testing.expect(t, slice.equal(file, read), "the file read back is the file written")
	// The validation reads the tables in place: an aligned copy, as the
	// compositor maps the file.
	aligned, _ := mem.alloc_bytes(len(read), pointer_pictures.PIXEL_ALIGNMENT, context.temp_allocator)
	copy(aligned, read)
	testing.expect_value(t, pointer_pictures.validate(aligned).kind, pointer_pictures.Problem_Kind.None)
	for form in pointer_pictures.Pointer_Form do for shape in pointer_pictures.Pointer_Shape {
		for size in manifest.sizes {
			chosen := pointer_pictures.choose(aligned, form, shape, size, 0)
			testing.expect_value(t, chosen.shape, shape)
			testing.expect_value(t, chosen.picture.nominal_size, size)
		}
	}
	// The two forms have their own pictures of the arrow.
	dark := pointer_pictures.choose(aligned, .Dark, .Arrow, manifest.sizes[0], 0)
	light := pointer_pictures.choose(aligned, .Light, .Arrow, manifest.sizes[0], 0)
	testing.expect(t, !slice.equal(dark.pixels, light.pixels), "the light form has its own arrow")
	free_all(context.temp_allocator)
}

// An error of the manifest gives the line, the column and what was
// expected, word for word.
@(test)
manifest_errors_name_the_place :: proc(t: ^testing.T) {
	Case :: struct {
		text:     string,
		sentence: string,
	}
	head :: "theme T\nlicense MIT\nsizes 12\n"
	triangle :: "layer edge\ncontour 0 0 line 1 0 line 0 1\n"
	coordinate :: "a coordinate from 0 to 12 with at most 3 decimals"
	paint :: "a paint \"fill\", \"accent\", \"edge\" or \"clear\""
	accent :: "the name of an accent: \"title\", \"stop_program\" or \"boot_program\""
	cases := [?]Case {
		{"license MIT\n", "m:1:1: expected the statement \"theme\" first; found \"license\""},
		{head + "shape arow hot 0 0\n", "m:4:7: expected a pointer shape name such as \"arrow\"; found \"arow\""},
		{head + "shape arrow hot 0 0\n" + triangle + "shape arrow hot 0 0\n", "m:7:7: expected a shape that line 4 does not name; found \"arrow\""},
		{head + "shape arrow hot 0 0\nlayer red\n", "m:5:7: expected " + paint + "; found \"red\""},
		{head + "shape arrow hot 0 0\nlayer\n", "m:5:6: expected " + paint + "; found the end of the line"},
		{head + "shape arrow hot 0 0\nlayer accent\n", "m:5:13: expected " + accent + "; found the end of the line"},
		{head + "shape arrow hot 0 0\nlayer accent 0x3F7CC4\n", "m:5:14: expected " + accent + "; found \"0x3F7CC4\""},
		{head + "shape arrow hot 0 0\nlayer edge inside\n", "m:5:12: expected the end of the line; found \"inside\""},
		{head + "shape arrow hot 0 0\nlayer fill inside more\n", "m:5:19: expected the end of the line; found \"more\""},
		{head + "shape arrow hot 0 0\nlayer accent title fade 0\n", "m:5:25: expected a strength of 1 to 100 percent after \"fade\"; found \"0\""},
		{head + "shape arrow hot 0 0\nlayer accent title inside fade\n", "m:5:31: expected a strength of 1 to 100 percent after \"fade\"; found the end of the line"},
		{head + "shape arrow hot 0 0\nlayer fill fade 50\n", "m:5:12: expected the end of the line; found \"fade\""},
		{head + "shape arrow hot 0 0\nlayer edge\ncontour 0 0 line 13 0\n", "m:6:18: expected " + coordinate + "; found \"13\""},
		{head + "shape arrow hot 0 0\nlayer edge\ncontour 0.0005 0\n", "m:6:9: expected " + coordinate + "; found \"0.0005\""},
		{head + "shape arrow hot 0 0\nlayer edge\ncontour 1. 0\n", "m:6:9: expected " + coordinate + "; found \"1.\""},
		{head + "shape arrow hot 0 0\nlayer edge\ncontour 0\n", "m:6:10: expected " + coordinate + "; found the end of the line"},
		{head + "shape arrow hot 0 0\nlayer edge\ncontour 0 0 move 1 1\n", "m:6:13: expected \"contour\", \"line\", \"curve\" or \"circle\"; found \"move\""},
		{head + "shape arrow hot 0 0\nlayer edge\ncircle 2 6 3\n", "m:6:12: expected a radius above 0 that keeps the circle inside the square of 12 units; found \"3\""},
		{head + "shape arrow hot 0 0\nlayer edge\ncircle 6 6 3 line 1 1\n", "m:6:14: expected a statement \"contour\" before \"line\"; found \"line\""},
		{head + "shape arrow hot 0 0\nla\tyer\n", "m:5:3: expected a character of ASCII 32 to 126; found the byte 9"},
		{head + "shape arrow hot 0 0\ncontour 0 0 line 1 0\n", "m:5:1: expected the statement \"layer\" before a contour; found \"contour\""},
		{head + "shape arrow hot 0 0\nlayer edge\nline 1 0\n", "m:6:1: expected a statement \"contour\" before \"line\"; found \"line\""},
		{head + "shape arrow hot 0 0\nlayer edge\ncontour 0 0 line 1 0\n", "m:6:1: expected a contour of 2 segments at least; found 1"},
		{head + "shape arrow hot 0 0\nlayer edge\n", "m:5:1: expected a contour after the statement \"layer\"; found none"},
		{"theme T\nlicense MIT\nsizes 24 12\n", "m:3:10: expected a size larger than 24; found \"12\""},
		{"theme T\nlicense MIT\nsizes\n", "m:3:6: expected a nominal size from 1 to 256; found the end of the line"},
		{"theme T\nlicense MIT\nsizes 300\n", "m:3:7: expected a nominal size from 1 to 256; found \"300\""},
		{head + "shape arrow\n" + triangle, "m:4:1: expected the option \"hot\" for an outline; found the shape arrow with none"},
		{head + "shape arrow hot 0 0\n", "m:4:1: expected a source file or an outline; found the shape arrow with none"},
		{head + "shape arrow hot 0 0\nframe 100\n" + triangle, "m:4:1: expected 2 statements \"frame\" at least for an animation; found the shape arrow with none"},
		{head + "shape arrow hot 0 0\nframe 100\n" + triangle + "frame 100\n", "m:4:1: expected the layers of an outline after each \"frame\"; found the shape arrow with none"},
		{head + "shape arrow hot 12 0\n" + triangle, "m:4:1: expected a hot spot inside the square of 12 units; found 12,0"},
		{head + "shape text hot 0 0\n" + triangle, "m:7:1: expected the shape \"arrow\": the shape that the compositor shows by default; found the end of the file"},
		{head + "shape arrow left_ptr hot 1\n", "m:4:26: expected two numbers after \"hot\"; found \"1\""},
		{head + "shape arrow hot 1 x\n", "m:4:19: expected a number from 0 to 255; found \"x\""},
		{head + "shape arrow left/ptr\n", "m:4:13: expected a file name of letters, digits, \"_\" and \"-\"; found \"left/ptr\""},
		{head + "shape arrow left_ptr hot 0 0 other\n", "m:4:30: expected an option \"hot\" or \"sizes\" after the options; found \"other\""},
		{head + "shape arrow left_ptr\nlayer edge\n", "m:5:1: expected an outline only after a statement \"shape\" with no source; found \"layer\""},
		{head + "colour red\n", "m:4:1: expected a statement \"theme\", \"license\", \"attribution\", \"sizes\", \"shape\", \"frame\", \"layer\", \"contour\", \"line\", \"curve\" or \"circle\"; found \"colour\""},
		{"theme T\nlicense MIT\nshape arrow\n", "m:3:1: expected the statement \"sizes\" before the shapes; found \"shape\""},
		{"theme T\nsizes 12\nshape arrow hot 0 0\n" + triangle, "m:6:1: expected the statement \"license\"; found the end of the file"},
	}
	for item in cases {
		_, problem := manifest_parse("m", item.text)
		testing.expectf(t, problem == item.sentence, "for %q:\n got      %s\n expected %s", item.text, problem, item.sentence)
	}
	free_all(context.temp_allocator)
}

// A manifest with sources: the first source that exists, through two
// links; two shapes of one file share their pictures; a hot spot override
// scales with the size; a link out of the folder is refused.
@(test)
manifest_of_sources_follows_the_links :: proc(t: ^testing.T) {
	folder, err := os.make_directory_temp("", "pointers_test_*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(folder)
	_ = os.write_entire_file(fmt.tprintf("%s/real", folder), xcursor_write(two_sizes[:]))
	_ = os.symlink("real", fmt.tprintf("%s/middle", folder))
	_ = os.symlink("middle", fmt.tprintf("%s/left_ptr", folder))
	_ = os.symlink("/etc/passwd", fmt.tprintf("%s/outside", folder))
	text := "theme T\nlicense MIT\nsizes 4 8\nshape arrow default left_ptr hot 2 1\nshape text real\nshape move left_ptr hot 2 1\n"
	manifest, problem := manifest_parse("m", text)
	testing.expect_value(t, problem, "")
	file, rows, made_problem := pointer_theme_make(manifest, folder)
	testing.expect_value(t, made_problem, "")
	testing.expect_value(t, rows[0].source, "real")
	testing.expect_value(t, rows[2].source, "real (shared)")
	testing.expect_value(t, pointer_pictures.header(file).picture_count, 4) // arrow 2, text 2; move shares the arrow.
	testing.expect_value(t, pointer_pictures.header(file).form_count, 1) // Pictures of a source have one form.
	chosen := pointer_pictures.choose(file, .Dark, .Move, 8, 0)
	testing.expect_value(t, chosen.picture.hot_spot_x, 4)
	testing.expect_value(t, chosen.picture.hot_spot_y, 2)
	chosen = pointer_pictures.choose(file, .Dark, .Text, 8, 0)
	testing.expect_value(t, chosen.picture.hot_spot_x, 2) // The hot spot of the file.

	manifest, _ = manifest_parse("m", "theme T\nlicense MIT\nsizes 4\nshape arrow outside\n")
	_, _, made_problem = pointer_theme_make(manifest, folder)
	testing.expect(t, strings.contains(made_problem, "out of the folder"))
	manifest, _ = manifest_parse("m", "theme T\nlicense MIT\nsizes 16\nshape arrow real\n")
	_, _, made_problem = pointer_theme_make(manifest, folder)
	testing.expectf(t, strings.contains(made_problem, "has no picture of the size 16; it has [4, 8]"), "got %s", made_problem)
	free_all(context.temp_allocator)
}
