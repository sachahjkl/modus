// Self-contained chaptered video composition for `modustool film tutorial`
// (src/md/infrastructure/tutorial_film.md).
//
// Splices 1920x1080 modus-styled chapter title cards directly into the
// ffconcat stream at exact cue boundaries from build/films/tutorial.cues,
// generates an ASS subtitle track (burned with libass using resources/fonts/)
// with shifted timestamps and safe lower-third caption geometry that never
// overlaps any application window or status bar, and encodes native 1920x1080
// 30 fps H.264 MP4 and <= 4 MiB AV1 WebM outputs.
package machine

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "modus:contract/reference_screen"
import "modustool:checks"
import "modustool:foundation"

// Native 1080p tutorial output dimensions matching the reference screen.
TUTORIAL_VIDEO_WIDTH :: int(reference_screen.WIDTH)
TUTORIAL_VIDEO_HEIGHT :: int(reference_screen.HEIGHT)
#assert(TUTORIAL_VIDEO_WIDTH == 1920 && TUTORIAL_VIDEO_HEIGHT == 1080)

TUTORIAL_FONTS_FOLDER :: "resources/fonts"
TUTORIAL_FONT_BOLD :: "B612 ASCII Bold"
TUTORIAL_FONT_REGULAR :: "B612 ASCII"
TUTORIAL_FONT_MONO :: "JetBrains Mono ASCII"
TUTORIAL_ASS_NAME :: "tutorial.ass"

// Safe lower-third caption card bounds on the 1920x1080 canvas.
// The compositor renders at 1.25x UI scale (1536x864 logical). All tutorial
// windows stay within physical y = 45..805 (db_browser at logical y=36,
// resized to 1080x580 -> physical bottom ~805 px; edit and grants at logical
// y=44, 560 tall -> physical bottom ~790 px; console at logical y=44 ->
// physical bottom ~660 px), leaving y = 856..1036 completely clear.
TUTORIAL_CAPTION_LEFT :: 180
TUTORIAL_CAPTION_TOP :: 856
TUTORIAL_CAPTION_RIGHT :: 1740
TUTORIAL_CAPTION_BOTTOM :: 1036
#assert(TUTORIAL_CAPTION_TOP >= (36 + 28 + 580) * 5 / 4 + 48)
#assert(TUTORIAL_CAPTION_BOTTOM <= TUTORIAL_VIDEO_HEIGHT - 32)
#assert(TUTORIAL_CAPTION_LEFT >= 64 && TUTORIAL_CAPTION_RIGHT <= TUTORIAL_VIDEO_WIDTH - 64)

// Centered chapter card panel bounds on the 1920x1080 dark canvas.
TUTORIAL_CARD_LEFT :: 180
TUTORIAL_CARD_TOP :: 240
TUTORIAL_CARD_RIGHT :: 1740
TUTORIAL_CARD_BOTTOM :: 840

// Modus dark palette colors matching docs/DESIGN.md.
Tutorial_Rgb :: struct {
	r, g, b: u8,
}

TUTORIAL_BG_CANVAS :: Tutorial_Rgb{17, 21, 27} // #11151B
TUTORIAL_BG_CARD :: Tutorial_Rgb{22, 27, 34} // #161B22
TUTORIAL_BORDER_CARD :: Tutorial_Rgb{48, 54, 61} // #30363D
TUTORIAL_TEXT_PRIMARY :: Tutorial_Rgb{240, 246, 252} // #F0F6FC
TUTORIAL_TEXT_BODY :: Tutorial_Rgb{201, 209, 217} // #C9D1D9
TUTORIAL_TEXT_DIM :: Tutorial_Rgb{139, 148, 158} // #8B949E

Tutorial_Accent :: enum u8 {
	System  = 0, // #58A6FF — Lex, declarations, recipes
	Process = 1, // #3FB950 — verified delivery, live SQLite
	Grant   = 2, // #D29922 — sandbox by default, capability grants
	Version = 3, // #A371F7 — copy-on-write version history
}

@(rodata)
tutorial_accent_rgb := [Tutorial_Accent]Tutorial_Rgb {
	.System  = {88, 166, 255},
	.Process = {63, 185, 80},
	.Grant   = {210, 153, 34},
	.Version = {163, 113, 247},
}

// Bounded AV1 CRF step-up ladder guaranteeing tutorial.webm fits <= 4 MiB.
@(rodata)
TUTORIAL_WEBM_CRF_LADDER := [4]string{"42", "46", "50", "54"}

Tutorial_Card_Anchor :: enum u8 {
	Start_Of_Film = 0,
	Before_Cue    = 1,
	End_Of_Film   = 2,
}

Tutorial_Chapter_Card :: struct {
	id:          string,
	anchor:      Tutorial_Card_Anchor,
	cue_name:    string,
	duration_ms: i64,
	accent:      Tutorial_Accent,
	kicker:      string,
	title:       string,
	lines:       []string,
	footer:      string,
}

Tutorial_Caption :: struct {
	cue_name: string,
	accent:   Tutorial_Accent,
	kicker:   string,
	heading:  string,
	body:     string,
}

Tutorial_Spliced_Entry :: struct {
	file_name:   string,
	duration_us: i64,
}

Tutorial_Card_Span :: struct {
	card_index: int,
	start_ms:   i64,
	end_ms:     i64,
}

Tutorial_Caption_Span :: struct {
	caption_index: int,
	start_ms:      i64,
	end_ms:        i64,
}

Tutorial_Timeline :: struct {
	entries:       []Tutorial_Spliced_Entry,
	card_spans:    []Tutorial_Card_Span,
	caption_spans: []Tutorial_Caption_Span,
	total_ms:      i64,
}

// Seven-chapter card deck for the db_browser developer tutorial.
@(private = "file", rodata)
tutorial_ch1_lines := [1]string{"Lex declarations, signed cache recipes, capability grants, and copy-on-write versions"}
@(private = "file", rodata)
tutorial_ch2_lines := [1]string{"Opening db_browser/project.lex inside the modus editor"}
@(private = "file", rodata)
tutorial_ch3_lines := [1]string{"Content-addressed ingestion, QUIC object cache pull, and Ed25519 provenance"}
@(private = "file", rodata)
tutorial_ch4_lines := [1]string{"Zero ambient access, explicit store grants, and the desktop Grants window"}
@(private = "file", rodata)
tutorial_ch5_lines := [1]string{"Isolated SQLite child call host, atomic 4 KiB commits, and off-thread sorting"}
@(private = "file", rodata)
tutorial_ch6_lines := [1]string{"Zero Save button: preview and restore any past database generation"}
@(private = "file", rodata)
tutorial_ch7_lines := [4]string{
	"Lex declarations: one typed language for the console and project files",
	"Signed object cache: BLAKE3 content addressing and Ed25519 provenance",
	"Sandbox by default: explicit, revocable capability grants",
	"Automatic CoW versions: atomic persistence with no Save button",
}

tutorial_chapter_cards := [7]Tutorial_Chapter_Card {
	{
		id          = "card_ch1",
		anchor      = .Start_Of_Film,
		duration_ms = 3500,
		accent      = .System,
		kicker      = "MODUS DEVELOPER TUTORIAL",
		title       = "Building a sandboxed SQLite GUI app on modus",
		lines       = tutorial_ch1_lines[:],
		footer      = "db_browser - content-addressed and capability-isolated",
	},
	{
		id          = "card_ch2",
		anchor      = .Before_Cue,
		cue_name    = "tutorial.project_start",
		duration_ms = 2800,
		accent      = .System,
		kicker      = "CHAPTER 1",
		title       = "Project Declaration (project.lex)",
		lines       = tutorial_ch2_lines[:],
	},
	{
		id          = "card_ch3",
		anchor      = .Before_Cue,
		cue_name    = "tutorial.cache_start",
		duration_ms = 2800,
		accent      = .System,
		kicker      = "CHAPTER 2",
		title       = "Signed Cache & Recipes",
		lines       = tutorial_ch3_lines[:],
	},
	{
		id          = "card_ch4",
		anchor      = .Before_Cue,
		cue_name    = "tutorial.sandbox_start",
		duration_ms = 2800,
		accent      = .Grant,
		kicker      = "CHAPTER 3",
		title       = "Sandbox by Default & Grants",
		lines       = tutorial_ch4_lines[:],
	},
	{
		id          = "card_ch5",
		anchor      = .Before_Cue,
		cue_name    = "tutorial.sqlite_open",
		duration_ms = 2800,
		accent      = .Process,
		kicker      = "CHAPTER 4",
		title       = "Live SQLite GUI",
		lines       = tutorial_ch5_lines[:],
	},
	{
		id          = "card_ch6",
		anchor      = .Before_Cue,
		cue_name    = "tutorial.versions_start",
		duration_ms = 2800,
		accent      = .Version,
		kicker      = "CHAPTER 5",
		title       = "Automatic CoW Versions",
		lines       = tutorial_ch6_lines[:],
	},
	{
		id          = "card_ch7",
		anchor      = .End_Of_Film,
		duration_ms = 4000,
		accent      = .Process,
		kicker      = "RECAP",
		title       = "modus",
		lines       = tutorial_ch7_lines[:],
		footer      = "modus.systems",
	},
}

// Lower-third captions anchored directly to scenario_tutorial_film cues.
@(rodata)
tutorial_captions := [15]Tutorial_Caption {
	{
		cue_name = "tutorial.intro",
		accent   = .System,
		kicker   = "INTRO / LEX CONSOLE",
		heading  = "One typed language for the desktop console and project files",
		body     = "Every command in modus is a typed function that returns values, records, or tables - never text pipes.",
	},
	{
		cue_name = "tutorial.project_start",
		accent   = .System,
		kicker   = "01 / PROJECT DECLARATION",
		heading  = "Opening db_browser/project.lex in the modus editor",
		body     = "edit(\"db_browser\", \"project.lex\") opens the project declaration directly from its store.",
	},
	{
		cue_name = "tutorial.project_lex",
		accent   = .System,
		kicker   = "01 / PROJECT DECLARATION",
		heading  = "Pure Lex v3: here(), typed units, and strict with overrides",
		body     = "here() binds the source tree by BLAKE3 hash; default_build with { heap = 4 MiB } overrides a typed size unit.",
	},
	{
		cue_name = "tutorial.project_grants",
		accent   = .Grant,
		kicker   = "01 / PROJECT DECLARATION",
		heading  = "Declared outputs and least-privilege store access",
		body     = "recipe(...) pins the builder and inputs; store(\"db_browser\", .read, .write) states exact storage scope.",
	},
	{
		cue_name = "tutorial.cache_start",
		accent   = .System,
		kicker   = "02 / SIGNED CACHE & RECIPES",
		heading  = "Freezing the project tree into content-addressed objects",
		body     = "tree = \"db_browser\" |> recipes.ingest_tree hashes every file into canonical BLAKE3 tree objects.",
	},
	{
		cue_name = "tutorial.cache_pull",
		accent   = .Process,
		kicker   = "02 / SIGNED CACHE & RECIPES",
		heading  = "Pulling a signed realisation over QUIC as a typed Record",
		body     = "recipes.build_project returns a Project_Build record (outcome, recipe, output) - no raw hashes to copy.",
	},
	{
		cue_name = "tutorial.provenance",
		accent   = .Process,
		kicker   = "02 / SIGNED CACHE & RECIPES",
		heading  = "Verifying Ed25519 signer provenance through Lex field access",
		body     = "pkg.recipe |> recipes.provenance reports the remote_cache origin and trusted Ed25519 signer key.",
	},
	{
		cue_name = "tutorial.deliver",
		accent   = .Process,
		kicker   = "02 / SIGNED CACHE & RECIPES",
		heading  = "Validating and delivering the module into module_files",
		body     = "mod = pkg.output |> recipes.deliver_module(\"module\", \"db_browser\") checks format and binds its hash.",
	},
	{
		cue_name = "tutorial.sandbox_start",
		accent   = .Grant,
		kicker   = "03 / SANDBOX & GRANTS",
		heading  = "Launching a disk process by verified BLAKE3 hash",
		body     = "start_from_disk(\"db_browser\", mod) checks the module bytes against mod and starts with zero grants.",
	},
	{
		cue_name = "tutorial.sandboxed",
		accent   = .Grant,
		kicker   = "03 / SANDBOX & GRANTS",
		heading  = "Sandboxed by default: zero ambient disk or network access",
		body     = "Without a store grant, db_browser cannot touch any store on disk and stays confined to memory.",
	},
	{
		cue_name = "tutorial.grants_window",
		accent   = .Grant,
		kicker   = "03 / SANDBOX & GRANTS",
		heading  = "Explicit, revocable store grant and the Grants window",
		body     = "allow(\"db_browser\", \"store\") grants one private store; the Grants window lists and revokes any active grant.",
	},
	{
		cue_name = "tutorial.sqlite_open",
		accent   = .Process,
		kicker   = "04 / LIVE SQLITE GUI",
		heading  = "SQLite isolated inside a zero-grant child call host",
		body     = "db_browser opens main.db on a worker thread; SQLite has zero kernel grants and the UI thread never blocks.",
	},
	{
		cue_name = "tutorial.sqlite_query",
		accent   = .Process,
		kicker   = "04 / LIVE SQLITE GUI",
		heading  = "Atomic 4 KiB page commits and off-thread column sorting",
		body     = "INSERT commits dirty pages atomically to the CoW store; clicking a column header sorts off-thread.",
	},
	{
		cue_name = "tutorial.versions_start",
		accent   = .Version,
		kicker   = "05 / AUTOMATIC COW VERSIONS",
		heading  = "Opening automatic copy-on-write version history",
		body     = "Ctrl+H opens the VERSIONS list; every database commit is kept automatically with no Save button.",
	},
	{
		cue_name = "tutorial.versions_preview",
		accent   = .Version,
		kicker   = "05 / AUTOMATIC COW VERSIONS",
		heading  = "Previewing and restoring an earlier generation atomically",
		body     = "Down previews the earlier snapshot read-only; Enter restores it atomically while keeping full history.",
	},
}

// tutorial_cues_parse parses build/films/<name>.cues (one "<sec>.<ms> <name>" per line).
// Refuses malformed timestamps, invalid cue names, duplicate cues, or decreasing times.
tutorial_cues_parse :: proc(text: string, allocator := context.allocator) -> (cues: []Film_Cue, ok: bool) {
	list := make([dynamic]Film_Cue, allocator)
	defer if !ok {
		for cue in list {
			delete(cue.name, allocator)
		}
		delete(list)
	}
	rest := text
	prev_ms: i64 = -1
	for line in strings.split_lines_iterator(&rest) {
		if line == "" {
			continue
		}
		space := strings.index_byte(line, ' ')
		if space <= 0 || space + 1 >= len(line) {
			return nil, false
		}
		time_text := line[:space]
		name := line[space + 1:]
		if film_cue_name_problem(name) != "" {
			return nil, false
		}
		dot := strings.index_byte(time_text, '.')
		if dot <= 0 || dot + 4 != len(time_text) {
			return nil, false
		}
		secs, secs_ok := strconv.parse_i64(time_text[:dot])
		millis, ms_ok := strconv.parse_i64(time_text[dot + 1:])
		if !secs_ok || !ms_ok || secs < 0 || millis < 0 || millis >= 1000 {
			return nil, false
		}
		total_ms := secs * 1000 + millis
		if total_ms < prev_ms {
			return nil, false
		}
		for existing in list {
			if existing.name == name {
				return nil, false
			}
		}
		prev_ms = total_ms
		append(&list, Film_Cue{
			since_start = time.Duration(total_ms) * time.Millisecond,
			name        = strings.clone(name, allocator),
		})
	}
	return list[:], true
}

tutorial_cues_free :: proc(cues: []Film_Cue, allocator := context.allocator) {
	for cue in cues {
		delete(cue.name, allocator)
	}
	delete(cues, allocator)
}

// tutorial_ass_color formats an RGB color and ASS transparency byte (0x00 opaque,
// 0xFF transparent) into ASS &HAABBGGRR notation.
tutorial_ass_color :: proc(color: Tutorial_Rgb, alpha_transparency: u8 = 0) -> string {
	return fmt.tprintf("&H%02X%02X%02X%02X", alpha_transparency, color.b, color.g, color.r)
}

// tutorial_ass_timestamp formats milliseconds into ASS H:MM:SS.cc (centiseconds,
// truncated so captions never appear early).
tutorial_ass_timestamp :: proc(ms: i64) -> string {
	clamped := max(ms, 0)
	cs := (clamped % 1000) / 10
	total_seconds := clamped / 1000
	secs := total_seconds % 60
	mins := (total_seconds / 60) % 60
	hours := total_seconds / 3600
	return fmt.tprintf("%d:%02d:%02d.%02d", hours, mins, secs, cs)
}

// tutorial_ass_escape escapes ASS control characters and converts newlines to \N.
tutorial_ass_escape :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for index in 0 ..< len(text) {
		ch := text[index]
		switch ch {
		case '\\':
			strings.write_string(&builder, "\\\\")
		case '{':
			strings.write_string(&builder, "\\{")
		case '}':
			strings.write_string(&builder, "\\}")
		case '\n':
			strings.write_string(&builder, "\\N")
		case:
			strings.write_byte(&builder, ch)
		}
	}
	return strings.to_string(builder)
}

// tutorial_ffmpeg_filter_escape escapes paths embedded inside ffmpeg filter options.
tutorial_ffmpeg_filter_escape :: proc(path: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for index in 0 ..< len(path) {
		ch := path[index]
		switch ch {
		case '\\', ':', '\'', ',', '[', ']':
			strings.write_byte(&builder, '\\')
			strings.write_byte(&builder, ch)
		case:
			strings.write_byte(&builder, ch)
		}
	}
	return strings.to_string(builder)
}

// tutorial_card_ppm_encode writes a binary P6 PPM background for one chapter
// title card: modus dark canvas, centered rectangular card with 1 px border,
// and a 6 px left accent bar in the chapter's semantic color.
tutorial_card_ppm_encode :: proc(width, height: int, accent: Tutorial_Accent, allocator := context.allocator) -> (bytes: []u8, ok: bool) {
	if width < 64 || height < 64 {
		return nil, false
	}
	header := fmt.tprintf("P6\n%d %d\n255\n", width, height)
	total := len(header) + width * height * 3
	out := make([]u8, total, allocator)
	copy(out[:len(header)], header)
	pixels := out[len(header):]

	// Scale card geometry proportionally if a test passes a smaller size.
	left := width * TUTORIAL_CARD_LEFT / TUTORIAL_VIDEO_WIDTH
	right := width * TUTORIAL_CARD_RIGHT / TUTORIAL_VIDEO_WIDTH
	top := height * TUTORIAL_CARD_TOP / TUTORIAL_VIDEO_HEIGHT
	bottom := height * TUTORIAL_CARD_BOTTOM / TUTORIAL_VIDEO_HEIGHT
	bar_w := max(width * 6 / TUTORIAL_VIDEO_WIDTH, 2)
	accent_color := tutorial_accent_rgb[accent]

	for y in 0 ..< height {
		row := pixels[y * width * 3:][:width * 3]
		in_y := y >= top && y < bottom
		border_y := in_y && (y == top || y == bottom - 1)
		for x in 0 ..< width {
			color := TUTORIAL_BG_CANVAS
			if in_y && x >= left && x < right {
				if x < left + bar_w {
					color = accent_color
				} else if border_y || x == right - 1 {
					color = TUTORIAL_BORDER_CARD
				} else {
					color = TUTORIAL_BG_CARD
				}
			}
			at := x * 3
			row[at] = color.r
			row[at + 1] = color.g
			row[at + 2] = color.b
		}
	}
	return out, true
}

@(private = "file")
tutorial_cue_find_ms :: proc(cues: []Film_Cue, name: string) -> (ms: i64, found: bool) {
	for cue in cues {
		if cue.name == name {
			return i64(cue.since_start) / i64(time.Millisecond), true
		}
	}
	return 0, false
}

// tutorial_timeline_build splices chapter title cards into the timed picture
// runs at exact cue boundaries and maps every chapter card and lower-third
// caption to non-overlapping output-timeline timestamps.
tutorial_timeline_build :: proc(
	names: []string,
	runs: []Film_Run,
	cues: []Film_Cue,
	cards: []Tutorial_Chapter_Card,
	captions: []Tutorial_Caption,
	allocator := context.allocator,
) -> (timeline: Tutorial_Timeline, ok: bool) {
	if len(names) == 0 || len(runs) == 0 {
		return {}, false
	}
	total_slots := film_slot_count(runs)
	raw_total_us := film_slot_microseconds(total_slots)
	if raw_total_us <= 0 {
		return {}, false
	}

	Splice :: struct {
		card_index:  int,
		raw_us:      i64,
		duration_us: i64,
		file_name:   string,
	}
	splices := make([]Splice, len(cards), context.temp_allocator)
	for card, idx in cards {
		if card.duration_ms <= 0 || card.id == "" {
			return {}, false
		}
		raw_us: i64
		switch card.anchor {
		case .Start_Of_Film:
			raw_us = 0
		case .Before_Cue:
			cue_ms, found := tutorial_cue_find_ms(cues, card.cue_name)
			if !found {
				return {}, false
			}
			raw_us = clamp(cue_ms * 1000, 0, raw_total_us)
		case .End_Of_Film:
			raw_us = raw_total_us
		}
		if idx > 0 && raw_us < splices[idx - 1].raw_us {
			return {}, false
		}
		splices[idx] = {
			card_index  = idx,
			raw_us      = raw_us,
			duration_us = card.duration_ms * 1000,
			file_name   = fmt.tprintf("%s%s", card.id, FILM_PICTURE_SUFFIX),
		}
	}

	// Verify all caption cues exist and are non-decreasing in raw time.
	caption_raw_us := make([]i64, len(captions), context.temp_allocator)
	for cap, idx in captions {
		cue_ms, found := tutorial_cue_find_ms(cues, cap.cue_name)
		if !found {
			return {}, false
		}
		raw_us := clamp(cue_ms * 1000, 0, raw_total_us)
		if idx > 0 && raw_us < caption_raw_us[idx - 1] {
			return {}, false
		}
		caption_raw_us[idx] = raw_us
	}

	entries := make([dynamic]Tutorial_Spliced_Entry, allocator)
	card_spans := make([]Tutorial_Card_Span, len(cards), allocator)
	caption_spans := make([]Tutorial_Caption_Span, len(captions), allocator)
	defer if !ok {
		for e in entries {
			delete(e.file_name, allocator)
		}
		delete(entries)
		delete(card_spans, allocator)
		delete(caption_spans, allocator)
	}

	// Emit spliced ffconcat entries and record exact output start/end for each card.
	out_us: i64 = 0
	next_splice := 0
	emit_splices_at_or_before :: proc(
		limit_raw_us: i64,
		splices: []Splice,
		next_splice: ^int,
		out_us: ^i64,
		entries: ^[dynamic]Tutorial_Spliced_Entry,
		card_spans: []Tutorial_Card_Span,
		allocator := context.allocator,
	) {
		for next_splice^ < len(splices) && splices[next_splice^].raw_us <= limit_raw_us {
			sp := splices[next_splice^]
			append(entries, Tutorial_Spliced_Entry{
				file_name   = strings.clone(sp.file_name, allocator),
				duration_us = sp.duration_us,
			})
			card_spans[sp.card_index] = {
				card_index = sp.card_index,
				start_ms   = out_us^ / 1000,
				end_ms     = (out_us^ + sp.duration_us) / 1000,
			}
			out_us^ += sp.duration_us
			next_splice^ += 1
		}
	}

	for run in runs {
		run_start := film_slot_microseconds(run.first_slot)
		run_end := film_slot_microseconds(run.first_slot + run.slot_count)
		cursor := run_start
		for {
			emit_splices_at_or_before(cursor, splices, &next_splice, &out_us, &entries, card_spans, allocator)
			if next_splice < len(splices) && splices[next_splice].raw_us < run_end {
				seg_end := splices[next_splice].raw_us
				if seg_end > cursor {
					append(&entries, Tutorial_Spliced_Entry{
						file_name   = strings.clone(names[run.picture], allocator),
						duration_us = seg_end - cursor,
					})
					out_us += seg_end - cursor
					cursor = seg_end
				}
				continue
			}
			if run_end > cursor {
				append(&entries, Tutorial_Spliced_Entry{
					file_name   = strings.clone(names[run.picture], allocator),
					duration_us = run_end - cursor,
				})
				out_us += run_end - cursor
			}
			break
		}
	}
	emit_splices_at_or_before(raw_total_us, splices, &next_splice, &out_us, &entries, card_spans, allocator)

	// Map raw timestamp to output timestamp:
	// - after_cards = true: after any card spliced AT raw_us (caption start)
	// - after_cards = false: before any card spliced AT raw_us (caption end)
	map_raw_to_out_ms :: proc(raw_us: i64, splices: []Splice, after_cards: bool) -> i64 {
		shift: i64 = 0
		for sp in splices {
			if after_cards {
				if sp.raw_us <= raw_us {
					shift += sp.duration_us
				}
			} else {
				if sp.raw_us < raw_us {
					shift += sp.duration_us
				}
			}
		}
		return (raw_us + shift) / 1000
	}

	for idx in 0 ..< len(captions) {
		start_raw := caption_raw_us[idx]
		end_raw := idx + 1 < len(captions) ? caption_raw_us[idx + 1] : raw_total_us
		// Clamp end_raw so a caption never spans across a subsequent chapter card.
		for sp in splices {
			if sp.raw_us > start_raw && sp.raw_us < end_raw {
				end_raw = sp.raw_us
			}
		}
		start_ms := map_raw_to_out_ms(start_raw, splices, after_cards = true)
		end_ms := map_raw_to_out_ms(end_raw, splices, after_cards = false)
		if end_ms < start_ms {
			end_ms = start_ms
		}
		caption_spans[idx] = {
			caption_index = idx,
			start_ms      = start_ms,
			end_ms        = end_ms,
		}
	}

	return Tutorial_Timeline{
		entries       = entries[:],
		card_spans    = card_spans,
		caption_spans = caption_spans,
		total_ms      = out_us / 1000,
	}, true
}

tutorial_timeline_free :: proc(timeline: ^Tutorial_Timeline, allocator := context.allocator) {
	if timeline == nil {
		return
	}
	for e in timeline.entries {
		delete(e.file_name, allocator)
	}
	delete(timeline.entries, allocator)
	delete(timeline.card_spans, allocator)
	delete(timeline.caption_spans, allocator)
	timeline^ = {}
}

// tutorial_ffconcat_text serializes spliced ffconcat entries into pictures.ffconcat.
// FFmpeg's concat demuxer ignores the duration directive on the final entry
// unless the final file line is repeated once without a duration line.
tutorial_ffconcat_text :: proc(entries: []Tutorial_Spliced_Entry) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "ffconcat version 1.0\n")
	for entry in entries {
		fmt.sbprintf(&builder, "file '%s'\nduration %d.%06d\n", entry.file_name, entry.duration_us / 1_000_000, entry.duration_us % 1_000_000)
	}
	if len(entries) > 0 {
		fmt.sbprintf(&builder, "file '%s'\n", entries[len(entries) - 1].file_name)
	}
	return strings.to_string(builder)
}

// tutorial_ass_generate builds the complete 1920x1080 ASS subtitle script for
// chapter title cards and safe lower-third explanatory captions using the
// modus repository fonts in resources/fonts/.
tutorial_ass_generate :: proc(
	timeline: Tutorial_Timeline,
	cards: []Tutorial_Chapter_Card,
	captions: []Tutorial_Caption,
	allocator := context.allocator,
) -> string {
	builder := strings.builder_make(allocator)

	// Header & Styles.
	fmt.sbprintf(&builder, "[Script Info]\n")
	fmt.sbprintf(&builder, "ScriptType: v4.00+\n")
	fmt.sbprintf(&builder, "PlayResX: %d\n", TUTORIAL_VIDEO_WIDTH)
	fmt.sbprintf(&builder, "PlayResY: %d\n", TUTORIAL_VIDEO_HEIGHT)
	fmt.sbprintf(&builder, "ScaledBorderAndShadow: yes\n")
	fmt.sbprintf(&builder, "WrapStyle: 2\n\n")

	primary_col := tutorial_ass_color(TUTORIAL_TEXT_PRIMARY)
	body_col := tutorial_ass_color(TUTORIAL_TEXT_BODY)
	dim_col := tutorial_ass_color(TUTORIAL_TEXT_DIM)
	transparent := tutorial_ass_color({0, 0, 0}, 0xFF)

	fmt.sbprintf(&builder, "[V4+ Styles]\n")
	fmt.sbprintf(&builder, "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n")
	fmt.sbprintf(&builder, "Style: CardKicker,%s,22,%s,%s,%s,%s,0,0,0,0,100,100,1.5,0,1,0,0,7,0,0,0,1\n", TUTORIAL_FONT_BOLD, primary_col, primary_col, transparent, transparent)
	fmt.sbprintf(&builder, "Style: CardTitle,%s,50,%s,%s,%s,%s,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1\n", TUTORIAL_FONT_BOLD, primary_col, primary_col, transparent, transparent)
	fmt.sbprintf(&builder, "Style: CardBody,%s,28,%s,%s,%s,%s,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1\n", TUTORIAL_FONT_REGULAR, body_col, body_col, transparent, transparent)
	fmt.sbprintf(&builder, "Style: CardFooter,%s,22,%s,%s,%s,%s,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1\n", TUTORIAL_FONT_MONO, dim_col, dim_col, transparent, transparent)
	fmt.sbprintf(&builder, "Style: CapBox,%s,20,%s,%s,%s,%s,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1\n", TUTORIAL_FONT_REGULAR, primary_col, primary_col, transparent, transparent)
	fmt.sbprintf(&builder, "Style: CapKicker,%s,19,%s,%s,%s,%s,0,0,0,0,100,100,1.2,0,1,0,0,7,0,0,0,1\n", TUTORIAL_FONT_BOLD, primary_col, primary_col, transparent, transparent)
	fmt.sbprintf(&builder, "Style: CapHeading,%s,28,%s,%s,%s,%s,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1\n", TUTORIAL_FONT_BOLD, primary_col, primary_col, transparent, transparent)
	fmt.sbprintf(&builder, "Style: CapBody,%s,23,%s,%s,%s,%s,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1\n\n", TUTORIAL_FONT_REGULAR, body_col, body_col, transparent, transparent)

	fmt.sbprintf(&builder, "[Events]\n")
	fmt.sbprintf(&builder, "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n")

	// Chapter title cards (drawn onto their dedicated dark .ppm card frames).
	card_text_x := TUTORIAL_CARD_LEFT + 64
	for span in timeline.card_spans {
		card := cards[span.card_index]
		start_ts := tutorial_ass_timestamp(span.start_ms)
		end_ts := tutorial_ass_timestamp(span.end_ms)
		accent_ass := tutorial_ass_color(tutorial_accent_rgb[card.accent])

		kicker_y := len(card.lines) > 1 ? TUTORIAL_CARD_TOP + 64 : TUTORIAL_CARD_TOP + 150
		title_y := kicker_y + 44
		body_y := title_y + 84

		fmt.sbprintf(&builder, "Dialogue: 2,%s,%s,CardKicker,,0,0,0,,{{\\an7\\pos(%d,%d)\\1c%s}}%s\n",
			start_ts, end_ts, card_text_x, kicker_y, accent_ass, tutorial_ass_escape(card.kicker))
		fmt.sbprintf(&builder, "Dialogue: 2,%s,%s,CardTitle,,0,0,0,,{{\\an7\\pos(%d,%d)}}%s\n",
			start_ts, end_ts, card_text_x, title_y, tutorial_ass_escape(card.title))

		for line, line_idx in card.lines {
			prefix := len(card.lines) > 1 ? "-  " : ""
			fmt.sbprintf(&builder, "Dialogue: 2,%s,%s,CardBody,,0,0,0,,{{\\an7\\pos(%d,%d)}}%s%s\n",
				start_ts, end_ts, card_text_x, body_y + line_idx * 54, prefix, tutorial_ass_escape(line))
		}
		if card.footer != "" {
			footer_y := TUTORIAL_CARD_BOTTOM - 72
			fmt.sbprintf(&builder, "Dialogue: 2,%s,%s,CardFooter,,0,0,0,,{{\\an7\\pos(%d,%d)}}%s\n",
				start_ts, end_ts, card_text_x, footer_y, tutorial_ass_escape(card.footer))
		}
	}

	// Lower-third explanatory captions (strictly within TUTORIAL_CAPTION_*).
	cap_bg := tutorial_ass_color(TUTORIAL_BG_CARD, 0x10)
	cap_border := tutorial_ass_color(TUTORIAL_BORDER_CARD, 0x00)
	cap_w := TUTORIAL_CAPTION_RIGHT - TUTORIAL_CAPTION_LEFT
	cap_h := TUTORIAL_CAPTION_BOTTOM - TUTORIAL_CAPTION_TOP
	bar_w := 6

	for span in timeline.caption_spans {
		if span.end_ms <= span.start_ms {
			continue
		}
		cap := captions[span.caption_index]
		start_ts := tutorial_ass_timestamp(span.start_ms)
		end_ts := tutorial_ass_timestamp(span.end_ms)
		accent_ass := tutorial_ass_color(tutorial_accent_rgb[cap.accent])

		// Layer 0: rectangular backing box with crisp 1 px border.
		fmt.sbprintf(&builder, "Dialogue: 0,%s,%s,CapBox,,0,0,0,,{{\\an7\\pos(%d,%d)\\bord1\\shad0\\1c%s\\3c%s\\p1}}m 0 0 l %d 0 l %d %d l 0 %d{{\\p0}}\n",
			start_ts, end_ts, TUTORIAL_CAPTION_LEFT, TUTORIAL_CAPTION_TOP, cap_bg, cap_border, cap_w, cap_w, cap_h, cap_h)
		// Layer 1: rectangular semantic left accent bar.
		fmt.sbprintf(&builder, "Dialogue: 1,%s,%s,CapBox,,0,0,0,,{{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c%s\\p1}}m 0 0 l %d 0 l %d %d l 0 %d{{\\p0}}\n",
			start_ts, end_ts, TUTORIAL_CAPTION_LEFT, TUTORIAL_CAPTION_TOP, accent_ass, bar_w, bar_w, cap_h, cap_h)
		// Layer 2: kicker, bold heading, and concise explanation.
		text_x := TUTORIAL_CAPTION_LEFT + 32
		fmt.sbprintf(&builder, "Dialogue: 2,%s,%s,CapKicker,,0,0,0,,{{\\an7\\pos(%d,%d)\\1c%s}}%s\n",
			start_ts, end_ts, text_x, TUTORIAL_CAPTION_TOP + 22, accent_ass, tutorial_ass_escape(cap.kicker))
		fmt.sbprintf(&builder, "Dialogue: 2,%s,%s,CapHeading,,0,0,0,,{{\\an7\\pos(%d,%d)}}%s\n",
			start_ts, end_ts, text_x, TUTORIAL_CAPTION_TOP + 54, tutorial_ass_escape(cap.heading))
		fmt.sbprintf(&builder, "Dialogue: 2,%s,%s,CapBody,,0,0,0,,{{\\an7\\pos(%d,%d)}}%s\n",
			start_ts, end_ts, text_x, TUTORIAL_CAPTION_TOP + 100, tutorial_ass_escape(cap.body))
	}

	return strings.to_string(builder)
}

@(private = "file")
tutorial_encode_command :: proc(list_path, ass_path, fonts_dir: string, total_ms: i64, output: string, encoder: []string) -> []string {
	clamped_ms := max(total_ms, 0)
	filter := fmt.tprintf(
		"fps=%d,scale=%d:%d:flags=neighbor,ass=filename=%s:fontsdir=%s,scale=out_color_matrix=bt709:out_range=tv",
		FILM_RATE,
		TUTORIAL_VIDEO_WIDTH,
		TUTORIAL_VIDEO_HEIGHT,
		tutorial_ffmpeg_filter_escape(ass_path),
		tutorial_ffmpeg_filter_escape(fonts_dir),
	)
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", list_path)
	append(&command, "-vf", filter)
	append(&command, ..encoder)
	append(&command, "-pix_fmt", "yuv420p")
	append(&command, "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv")
	append(&command, "-t", fmt.tprintf("%d.%03d", clamped_ms / 1000, clamped_ms % 1000))
	append(&command, output)
	return command[:]
}

// tutorial_mp4_encode_command builds the 1920x1080 30 fps H.264 command for tutorial.mp4.
tutorial_mp4_encode_command :: proc(list_path, ass_path, fonts_dir: string, total_ms: i64, output: string) -> []string {
	encoder := FILM_MP4_ENCODER
	return tutorial_encode_command(list_path, ass_path, fonts_dir, total_ms, output, encoder[:])
}

// tutorial_webm_encode_command builds the 1920x1080 30 fps AV1 command for tutorial.webm.
tutorial_webm_encode_command :: proc(list_path, ass_path, fonts_dir, crf: string, total_ms: i64, output: string) -> []string {
	encoder := [7]string{"-c:v", "libsvtav1", "-preset", "6", "-crf", crf, "-an"}
	return tutorial_encode_command(list_path, ass_path, fonts_dir, total_ms, output, encoder[:])
}

// tutorial_film_write composes the chaptered 1920x1080 tutorial.mp4 and
// tutorial.webm (strictly <= FILM_DOCUMENT_SIZE_LIMIT, 4 MiB) from captured
// pictures and build/films/tutorial.cues, copies the MP4 and stills to the
// development log, removes the raw picture folder, and copies tutorial.webm
// to docs/films/tutorial.webm when a news entry names it.
tutorial_film_write :: proc(name: string) -> bool {
	folder := foundation.join(FILM_FOLDER, "/", name)
	paths, listed := foundation.files_with_suffix(folder, FILM_PICTURE_SUFFIX)
	if !listed || len(paths) == 0 {
		fmt.eprintfln("modustool: the film %s has no picture in %s: its scenario has no step Film_Start, or QEMU wrote none", name, folder)
		return false
	}
	names := make([]string, len(paths), context.temp_allocator)
	times := make([]time.Duration, len(paths), context.temp_allocator)
	for path, place in paths {
		names[place] = path[strings.last_index_byte(path, '/') + 1:]
		since_start, timed := film_picture_time(path)
		if !timed {
			fmt.eprintfln("modustool: %s is not a picture of a film: its name is not a time", path)
			return false
		}
		times[place] = since_start
	}
	runs := film_runs(times)

	cue_path := foundation.join(FILM_FOLDER, "/", name, FILM_CUES_SUFFIX)
	cue_bytes, cue_err := os.read_entire_file(cue_path, context.temp_allocator)
	if cue_err != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", cue_path, cue_err)
		return false
	}
	cues, cues_ok := tutorial_cues_parse(string(cue_bytes))
	if !cues_ok {
		fmt.eprintfln("modustool: %s has a malformed cue file", cue_path)
		return false
	}
	defer tutorial_cues_free(cues)

	timeline, timeline_ok := tutorial_timeline_build(names, runs, cues, tutorial_chapter_cards[:], tutorial_captions[:])
	if !timeline_ok {
		fmt.eprintfln("modustool: tutorial timeline composition failed: cue file %s does not match chapter cards and captions", cue_path)
		return false
	}
	defer tutorial_timeline_free(&timeline)

	// Write chapter title card .ppm frames into the picture folder.
	for card in tutorial_chapter_cards {
		ppm, ppm_ok := tutorial_card_ppm_encode(TUTORIAL_VIDEO_WIDTH, TUTORIAL_VIDEO_HEIGHT, card.accent)
		if !ppm_ok {
			fmt.eprintfln("modustool: cannot render tutorial card %s", card.id)
			return false
		}
		card_path := foundation.join(folder, "/", card.id, FILM_PICTURE_SUFFIX)
		write_err := os.write_entire_file(card_path, ppm)
		delete(ppm)
		if write_err != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", card_path, write_err)
			return false
		}
	}

	list_path := foundation.join(folder, "/", FILM_LIST_NAME)
	if write_err := os.write_entire_file(list_path, tutorial_ffconcat_text(timeline.entries)); write_err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", list_path, write_err)
		return false
	}

	ass_path := foundation.join(folder, "/", TUTORIAL_ASS_NAME)
	ass_text := tutorial_ass_generate(timeline, tutorial_chapter_cards[:], tutorial_captions[:])
	defer delete(ass_text)
	if write_err := os.write_entire_file(ass_path, ass_text); write_err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", ass_path, write_err)
		return false
	}

	// Encode 1920x1080 30 fps H.264 MP4.
	output := foundation.join(FILM_FOLDER, "/", name, FILM_MP4_SUFFIX)
	foundation.run(tutorial_mp4_encode_command(list_path, ass_path, TUTORIAL_FONTS_FOLDER, timeline.total_ms, output)) or_return

	// Encode 1920x1080 30 fps AV1 WebM, stepping up CRF if needed to guarantee
	// strict compliance with checks.FILM_DOCUMENT_SIZE_LIMIT (4 MiB).
	webm_output := foundation.join(FILM_FOLDER, "/", name, FILM_WEBM_SUFFIX)
	webm_ok := false
	webm_bytes := 0
	for crf in TUTORIAL_WEBM_CRF_LADDER {
		foundation.run(tutorial_webm_encode_command(list_path, ass_path, TUTORIAL_FONTS_FOLDER, crf, timeline.total_ms, webm_output)) or_return
		data := foundation.read_file(webm_output) or_return
		if problem := checks.film_document_problem(data); problem == "" {
			webm_ok = true
			webm_bytes = len(data)
			break
		}
	}
	if !webm_ok {
		fmt.eprintfln("modustool: the film %s: %s exceeds %d bytes even at highest AV1 CRF", name, webm_output, checks.FILM_DOCUMENT_SIZE_LIMIT)
		return false
	}

	// Copy MP4 and three representative rendered stills to the development log.
	year, month, day := time.date(time.now())
	hour, minute, second := time.clock(time.now())
	log_folder := fmt.tprintf("%s/%04d-%02d-%02d_%02d%02d%02d_film_%s", foundation.development_log_folder(), year, int(month), day, hour, minute, second, name)
	foundation.make_folder(log_folder) or_return
	target := foundation.join(log_folder, "/", name, FILM_MP4_SUFFIX)
	if copy_err := os.copy_file(target, output); copy_err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", target, copy_err)
		return false
	}
	for part in ([3]int{1, 2, 3}) {
		at_seconds := int(timeline.total_ms / 1000) * part / 4
		still := fmt.tprintf("%s/%s_at_%03d_seconds.png", log_folder, name, at_seconds)
		foundation.run({"ffmpeg", "-loglevel", "error", "-y", "-ss", fmt.tprintf("%d", at_seconds), "-i", output, "-frames:v", "1", still}) or_return
	}

	if remove_err := os.remove_all(folder); remove_err != nil {
		fmt.eprintfln("modustool: cannot remove %s: %v", folder, remove_err)
		return false
	}
	fmt.printfln("modustool: wrote %s and %s (%d bytes, %.1f s, 1920x1080), and %s", output, webm_output, webm_bytes, f64(timeline.total_ms) / 1000.0, target)
	if film_is_named_by_a_news_entry(name) {
		film_document_write(name, webm_output) or_return
	}
	return true
}
