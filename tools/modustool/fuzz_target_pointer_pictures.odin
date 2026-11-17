package modustool

import "core:mem"
import "modus:contract/pointer_pictures"

// The fuzz target of the pointer theme (src/md/infrastructure/fuzzing.md,
// "The targets, in order of value"): the compositor validates the file of
// a theme once, then reads its entries and its pixels with no check. The
// tool writes the file from a manifest at the build; the manifest is read
// by the tool only, so the reader of the system is the target.

// The sizes and the times that the target asks of each shape: the edges,
// and a size of a theme.
@(rodata, private = "file")
fuzz_pointer_sizes := [?]u32{0, 24, max(u32)}
@(rodata, private = "file")
fuzz_pointer_times := [?]u64{0, 1, 1 << 40}

// fuzz_pointer_pictures_execute: a file that validate accepts gives a
// picture of each shape in each form, at each size and each time, with
// its pixels in the file, and the arrow for a shape that the theme lacks.
fuzz_pointer_pictures_execute :: proc(input: []u8) -> Fuzz_Verdict {
	file := fuzz_aligned_input(input)
	problem := pointer_pictures.validate(file)
	if problem.kind > max(pointer_pictures.Problem_Kind) || problem.part > max(pointer_pictures.Part) || problem.field > max(pointer_pictures.Field) {
		return fuzz_broken(.Contract, "validate gives a problem out of its enumerations: %v", problem)
	}
	sentence: [256]u8
	_ = pointer_pictures.sentence(problem, sentence[:])
	if problem.kind != .None {
		return FUZZ_PASSED
	}
	for picture in pointer_pictures.picture_entries(file) {
		if len(pointer_pictures.pixels_of(file, picture)) != int(picture.width * picture.height) {
			return fuzz_broken(.Contract, "pixels_of gives another count than the picture names")
		}
	}
	for form in pointer_pictures.Pointer_Form {
		for shape in pointer_pictures.Pointer_Shape {
			_, has_shape := pointer_pictures.shape_entry_of(file, form, shape)
			for size in fuzz_pointer_sizes {
				for time in fuzz_pointer_times {
					chosen := pointer_pictures.choose(file, form, shape, size, time)
					switch {
					case len(chosen.pixels) != int(chosen.picture.width * chosen.picture.height):
						return fuzz_broken(.Contract, "choose gives %d pixels for a picture of %dx%d", len(chosen.pixels), chosen.picture.width, chosen.picture.height)
					case has_shape && chosen.shape != shape || !has_shape && chosen.shape != .Arrow:
						return fuzz_broken(.Contract, "choose gives the shape %v for %v", chosen.shape, shape)
					case chosen.next_frame != 0 && chosen.next_frame <= time:
						return fuzz_broken(.Contract, "the next frame starts at %d, before the time %d", chosen.next_frame, time)
					}
				}
			}
		}
	}
	return FUZZ_PASSED
}

// fuzz_pointer_theme_write writes a theme by the rules of validate: the
// arrow at two sizes, with an animation of `frames` frames, and the text
// pointer at one size, in each form; the forms share the pictures.
@(private = "file")
fuzz_pointer_theme_write :: proc(form_count: int, frames: int) -> []u8 {
	Picture :: pointer_pictures.Picture_Entry
	pictures := make([dynamic]Picture, context.temp_allocator)
	pixel_size: u64
	add :: proc(pictures: ^[dynamic]Picture, pixel_size: ^u64, nominal_size, side: u32, delay: u32) {
		append(pictures, Picture{nominal_size = nominal_size, width = side, height = side, hot_spot_x = side - 1, delay_milliseconds = delay, pixel_offset = pixel_size^})
		pixel_size^ += u64(side * side * 4)
	}
	delay := frames > 1 ? u32(100) : 0
	for nominal in ([?]u32{24, 32}) {
		for _ in 0 ..< frames {
			add(&pictures, &pixel_size, nominal, nominal / 12, delay)
		}
	}
	text_first := u32(len(pictures))
	add(&pictures, &pixel_size, 24, 1, 0)
	shapes := [2]pointer_pictures.Shape_Entry {
		{shape = u32(pointer_pictures.Pointer_Shape.Arrow), first_picture = 0, size_count = 2, frame_count = u32(frames)},
		{shape = u32(pointer_pictures.Pointer_Shape.Text), first_picture = text_first, size_count = 1, frame_count = 1},
	}
	pixel_offset := pointer_pictures.pixel_offset_for(u64(len(shapes) * form_count), u64(len(pictures)))
	file := make([]u8, pixel_offset + pixel_size)
	header := pointer_pictures.Header {
		magic         = pointer_pictures.MAGIC,
		version       = pointer_pictures.VERSION,
		shape_count   = len(shapes),
		picture_count = u32(len(pictures)),
		form_count    = u32(form_count),
		pixel_offset  = pixel_offset,
		pixel_size    = pixel_size,
		file_size     = u64(len(file)),
	}
	copy(header.theme_name[:], "fuzz")
	copy(header.license[:], "CC0-1.0")
	mem.copy(&file[0], &header, size_of(header))
	at := pointer_pictures.HEADER_SIZE
	for _ in 0 ..< form_count {
		mem.copy(&file[at], &shapes, size_of(shapes))
		at += size_of(shapes)
	}
	mem.copy(&file[at], raw_data(pictures), len(pictures) * size_of(Picture))
	for place := int(pixel_offset); place < len(file); place += 4 {
		// Premultiplied: no channel above its alpha.
		pixel := u32(0x8040_2010)
		mem.copy(&file[place], &pixel, size_of(pixel))
	}
	return file
}

fuzz_pointer_pictures_seeds :: proc(seeds: ^[dynamic][]u8) {
	append(seeds, fuzz_pointer_theme_write(1, 1), fuzz_pointer_theme_write(len(pointer_pictures.Pointer_Form), 3))
	append(seeds, make([]u8, pointer_pictures.HEADER_SIZE - 1))
}

fuzz_pointer_pictures_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	if len(input) < pointer_pictures.HEADER_SIZE {
		return
	}
	append(regions, Fuzz_Region{offset = 0, type = pointer_pictures.Header, count = 1})
	header: pointer_pictures.Header
	mem.copy(&header, raw_data(input), size_of(header))
	shapes := min(int(header.shape_count) * int(min(header.form_count, pointer_pictures.FORM_COUNT_LIMIT)), (len(input) - pointer_pictures.HEADER_SIZE) / pointer_pictures.SHAPE_ENTRY_SIZE)
	if shapes > 0 {
		append(regions, Fuzz_Region{offset = pointer_pictures.HEADER_SIZE, type = pointer_pictures.Shape_Entry, count = shapes})
	}
	pictures_at := pointer_pictures.HEADER_SIZE + max(shapes, 0) * pointer_pictures.SHAPE_ENTRY_SIZE
	pictures := min(int(header.picture_count), (len(input) - pictures_at) / pointer_pictures.PICTURE_ENTRY_SIZE)
	if pictures > 0 {
		append(regions, Fuzz_Region{offset = pictures_at, type = pointer_pictures.Picture_Entry, count = pictures})
	}
}
