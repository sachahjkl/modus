package machine

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "modustool:foundation"
import "modustool:build"
import "modustool:checks"

// The films of the machine (docs/TOOLS.md, "The film").
//
// A film is a scenario of a machine with pictures of the screen taken at a
// steady rate while the scenario goes on. A worker thread takes the
// pictures through a connection to QEMU of its own, and names each picture
// by the time when it asked for it. The encoder then gets, for each slot of
// the film, the newest picture of that time: a picture that came late
// shifts nothing, and the film has the speed of the machine.
//
// A film shows time, and a test waits for conditions. So the steps of a
// film, and only they, have fixed times: the period between two typed keys
// (Film_Type) and the time that a viewer needs to read a state
// (Film_Hold). Each scene still waits for its line of the log before it
// goes on, so a film never shows a state that the machine did not reach.
// No scenario of a test has a step Film_Type or Film_Hold.

FILM_FOLDER :: foundation.BUILD_FOLDER + "/films"
// The slots of a film in one second, and the pictures that the worker asks
// for in one second: a rate, not a wait.
FILM_RATE :: 30
// The suffix of a picture of a film: the format that QEMU writes.
FILM_PICTURE_SUFFIX :: ".ppm"
// The list of the pictures for the encoder, in the folder of the pictures.
FILM_LIST_NAME :: "pictures.ffconcat"
// Each pixel of the screen is a square of this many pixels of the film,
// with no filter: an edge of one pixel of the screen stays sharp after the
// color planes of the encoder, which have half the size of the picture.
FILM_SCALE :: 2
// The end of the name of the socket of the film worker, after the name of
// the log of the machine.
FILM_QMP_SOCKET_SUFFIX :: ".film.qmp"

// The typing of a film: the middle period between two keys, and the most
// that one period differs from it. A seeded generator draws each period, so
// the typing does not look mechanical and two runs type at the same times.
FILM_KEY_PERIOD_MILLISECONDS :: 70
FILM_KEY_VARIATION_MILLISECONDS :: 25
FILM_TYPING_SEED :: 0x6D6F647573

// The holds of a film, in milliseconds: how long a state stays on the
// screen before the next act. They are times for a viewer, never waits for
// the machine.
FILM_HOLD_BEAT :: 400 // Between two acts of one scene.
FILM_HOLD_GLANCE :: 700 // A list that changed, a candidate that was taken.
FILM_HOLD_LOOK :: 1200 // A new state of the desktop: a window, the open panel.
FILM_HOLD_READ :: 2000 // A result or a question that a viewer reads.

// The film cues (docs/TOOLS.md, "The film cues"). A step Film_Hold with a
// text names a cue: the tool keeps the time since the start of the film
// when the hold starts, which is the moment the scene reached its state.
// An editor of the film places its captions by these times, not by times
// that it guesses: a film has the speed of the machine.
FILM_CUES_SUFFIX :: ".cues"
// The longest name of a cue, in bytes: a name is a key of the table of
// captions of an editor, not a sentence.
FILM_CUE_NAME_LIMIT :: 48

// One cue of a film: its name, and the time since the start of the film
// when the hold that names it started.
Film_Cue :: struct {
	since_start: time.Duration,
	name:        string,
}

// film_cue_name_problem gives "" for a valid name of a cue, else why it is
// refused. A name has 1 to FILM_CUE_NAME_LIMIT bytes of the lowercase
// letters, the digits, '_' and '.', and starts with a letter: the editor
// reads one name for each line, after one space.
film_cue_name_problem :: proc(name: string) -> string {
	if len(name) == 0 {
		return "the name of a cue is empty"
	}
	if len(name) > FILM_CUE_NAME_LIMIT {
		return "the name of a cue is longer than its limit"
	}
	if name[0] < 'a' || name[0] > 'z' {
		return "the name of a cue starts with a character that is not a lowercase letter"
	}
	for index in 0 ..< len(name) {
		character := name[index]
		if (character < 'a' || character > 'z') && (character < '0' || character > '9') && character != '_' && character != '.' {
			return "the name of a cue has a character that is not a lowercase letter, a digit, '_' or '.'"
		}
	}
	return ""
}

// film_cue_text gives the cue file of a film: one line for each cue, in
// the order of the film, with its time in seconds to the millisecond, one
// space and its name. A film with no cue gives an empty file, so a file of
// an earlier run never stays beside the new film.
film_cue_text :: proc(cues: []Film_Cue) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for cue in cues {
		milliseconds := i64(cue.since_start) / i64(time.Millisecond)
		fmt.sbprintf(&builder, "%d.%03d %s\n", milliseconds / 1000, milliseconds % 1000, cue.name)
	}
	return strings.to_string(builder)
}

// film_cue_note keeps the time of a cue of the film that runs. It refuses
// a cue with no film, a name that film_cue_name_problem refuses, and a
// name that the film already has: the editor finds each caption by its
// name, once.
film_cue_note :: proc(machine: ^Machine, name: string) -> bool {
	worker := machine.film
	if worker == nil {
		fmt.eprintfln("modustool: the film: the cue %s comes with no film that runs", name)
		return false
	}
	if problem := film_cue_name_problem(name); problem != "" {
		fmt.eprintfln("modustool: the film: the cue \"%s\": %s", name, problem)
		return false
	}
	for cue in worker.cues {
		if cue.name == name {
			fmt.eprintfln("modustool: the film: the cue %s comes two times", name)
			return false
		}
	}
	// The name is a text of a scenario, which lives as long as the tool.
	append(&worker.cues, Film_Cue{since_start = time.tick_since(worker.started), name = name})
	return true
}

// film_qmp_socket_of gives the path of the socket of the film worker of
// the machine with this log.
film_qmp_socket_of :: proc(output: string) -> string {
	return machine_file(output, FILM_QMP_SOCKET_SUFFIX)
}

// The display of the machine of a film: a VNC server on this socket, and no
// window. QEMU draws the text console of the firmware and of the boot
// program there, and a machine with no display draws nothing before the
// first picture of the system.
FILM_VNC_SOCKET_SUFFIX :: ".vnc.sock"

film_vnc_socket_of :: proc(output: string) -> string {
	return machine_file(output, FILM_VNC_SOCKET_SUFFIX)
}

// film_slot_of gives the slot of a film that holds a time since its start.
film_slot_of :: proc(since_start: time.Duration) -> int {
	return int(i64(since_start) * FILM_RATE / i64(time.Second))
}

// film_slot_start gives the first time of a slot, rounded up to the unit
// of the clock: the slot of that time is the slot.
film_slot_start :: proc(slot: int) -> time.Duration {
	return time.Duration((i64(slot) * i64(time.Second) + FILM_RATE - 1) / FILM_RATE)
}

// film_picture_name gives the name of the file of a picture from the time,
// since the start of the film, when the tool asked QEMU for it: the
// microseconds in ten digits, so the order of the names is the order of
// the times. The time is rounded up: the name never puts a picture in the
// slot before its own.
film_picture_name :: proc(since_start: time.Duration) -> string {
	microseconds := (i64(since_start) + i64(time.Microsecond) - 1) / i64(time.Microsecond)
	return fmt.tprintf("%010d%s", microseconds, FILM_PICTURE_SUFFIX)
}

// film_picture_time reads the time of a picture in its name, or in a path
// that ends with its name. ok is false for a file that is not a picture of
// a film.
film_picture_time :: proc(path: string) -> (since_start: time.Duration, ok: bool) {
	name := path[strings.last_index_byte(path, '/') + 1:]
	if !strings.has_suffix(name, FILM_PICTURE_SUFFIX) {
		return 0, false
	}
	digits := name[:len(name) - len(FILM_PICTURE_SUFFIX)]
	if len(digits) == 0 {
		return 0, false
	}
	for index in 0 ..< len(digits) {
		if digits[index] < '0' || digits[index] > '9' {
			return 0, false
		}
	}
	microseconds := strconv.parse_i64(digits) or_return
	return time.Duration(microseconds) * time.Microsecond, true
}

// One picture of a film and the slots that show it, one after the other.
Film_Run :: struct {
	picture:    int, // The place of the picture in the list of the pictures.
	first_slot: int,
	slot_count: int,
}

// film_runs gives what the encoder shows in each slot of a film, from the
// times of its pictures in their order: a slot shows the newest picture
// that was asked for before its end. A slot with no picture of its own (a
// picture that came late, or that is missing) shows the picture before,
// and the pictures after it keep their own slots. The film starts with its
// first picture, and the last picture has one slot. When two pictures have
// one slot, the newer one is shown.
film_runs :: proc(picture_times: []time.Duration) -> []Film_Run {
	runs := make([dynamic]Film_Run, 0, len(picture_times), context.temp_allocator)
	newest_slot := 0
	for picture_time, picture in picture_times {
		slot := film_slot_of(picture_time)
		if len(runs) == 0 {
			append(&runs, Film_Run{picture = picture, first_slot = 0, slot_count = 1})
			newest_slot = slot
			continue
		}
		last := &runs[len(runs) - 1]
		if slot <= newest_slot {
			last.picture = picture
			continue
		}
		last.slot_count = slot - last.first_slot
		append(&runs, Film_Run{picture = picture, first_slot = slot, slot_count = 1})
		newest_slot = slot
	}
	return runs[:]
}

// film_slot_microseconds gives the time of the start of a slot in
// microseconds, the unit of the list of the encoder, rounded to the nearest.
@(private = "file")
film_slot_microseconds :: proc(slot: int) -> i64 {
	return (i64(slot) * 1_000_000 + FILM_RATE / 2) / FILM_RATE
}

// film_list_text gives the list that the encoder reads: each picture of a
// run with the time that it stays on the screen. The time of a run is the
// difference of the rounded times of its two ends, so the rounding of one
// run never adds to the next one.
film_list_text :: proc(names: []string, runs: []Film_Run) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "ffconcat version 1.0\n")
	for film_run in runs {
		duration := film_slot_microseconds(film_run.first_slot + film_run.slot_count) - film_slot_microseconds(film_run.first_slot)
		fmt.sbprintf(&builder, "file '%s'\nduration %d.%06d\n", names[film_run.picture], duration / 1_000_000, duration % 1_000_000)
	}
	return strings.to_string(builder)
}

// film_slot_count gives the count of the slots of the runs of a film.
film_slot_count :: proc(runs: []Film_Run) -> int {
	if len(runs) == 0 {
		return 0
	}
	last := runs[len(runs) - 1]
	return last.first_slot + last.slot_count
}

// The two files of a film, by the suffix of their name.
FILM_MP4_SUFFIX :: ".mp4"
FILM_WEBM_SUFFIX :: checks.FILM_DOCUMENT_SUFFIX

// Film_Encoder_Backend selects the ffmpeg video encoder backend.
Film_Encoder_Backend :: enum u8 {
	Cpu,
	Nvenc,
}

FILM_ENCODER_BACKEND_NAMES :: [Film_Encoder_Backend]string{
	.Cpu   = "cpu",
	.Nvenc = "nvenc",
}

// Default WebM AV1 quality parameter (CRF for libsvtav1, CQ for av1_nvenc).
FILM_WEBM_DEFAULT_CRF :: 45

// Minimum frame size for the one-shot NVENC probe: NVIDIA NVENC rejects
// dimensions below 256x256 with invalid param (8).
FILM_NVENC_PROBE_SOURCE :: "color=c=black:s=256x256:d=0.05:r=30"

// The encoder of the MP4 file: H.264, which each site that takes a film
// plays. The index of the file is at its start, so a player starts before
// it has the whole file.
FILM_MP4_ENCODER :: [8]string{"-c:v", "libx264", "-preset", "slow", "-crf", "18", "-movflags", "+faststart"}
FILM_MP4_ENCODER_NVENC :: [12]string{"-c:v", "h264_nvenc", "-preset", "p4", "-rc", "vbr", "-cq", "19", "-b:v", "0", "-movflags", "+faststart"}
// The encoder of the WebM file: AV1, about half of the bytes of the MP4
// file for the same pictures, so this is the file that the repository
// holds and that the site shows. A film has no sound.
FILM_WEBM_ENCODER :: [7]string{"-c:v", "libsvtav1", "-preset", "6", "-crf", "45", "-an"}

// film_mp4_encoder_args returns the ffmpeg video encoder arguments for MP4
// output on the chosen backend.
film_mp4_encoder_args :: proc(backend: Film_Encoder_Backend, allocator := context.temp_allocator) -> []string {
	switch backend {
	case .Cpu:
		args := FILM_MP4_ENCODER
		return slice.clone(args[:], allocator)
	case .Nvenc:
		args := FILM_MP4_ENCODER_NVENC
		return slice.clone(args[:], allocator)
	}
	return nil
}

// film_webm_encoder_args returns the ffmpeg video encoder arguments for WebM
// AV1 output on the chosen backend at quality crf (CRF for libsvtav1, CQ for
// av1_nvenc).
film_webm_encoder_args :: proc(backend: Film_Encoder_Backend, crf := FILM_WEBM_DEFAULT_CRF, allocator := context.temp_allocator) -> []string {
	crf_text := fmt.aprintf("%d", crf, allocator = allocator)
	switch backend {
	case .Cpu:
		args := [7]string{"-c:v", "libsvtav1", "-preset", "6", "-crf", crf_text, "-an"}
		return slice.clone(args[:], allocator)
	case .Nvenc:
		args := [11]string{"-c:v", "av1_nvenc", "-preset", "p4", "-rc", "vbr", "-cq", crf_text, "-b:v", "0", "-an"}
		return slice.clone(args[:], allocator)
	}
	return nil
}

// film_nvenc_probe_command builds the 1-frame null-muxed ffmpeg command that
// tests whether codec works on the current host GPU.
film_nvenc_probe_command :: proc(codec: string, allocator := context.temp_allocator) -> []string {
	command := make([dynamic]string, 0, 15, allocator)
	append(&command, "ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", FILM_NVENC_PROBE_SOURCE, "-frames:v", "1", "-c:v", codec, "-f", "null", "-")
	return command[:]
}

@(private = "file")
film_nvenc_probe :: proc(codec: string) -> Film_Encoder_Backend {
	state, _, _, err := os.process_exec({command = film_nvenc_probe_command(codec)}, context.temp_allocator)
	if err == nil && state.success {
		return .Nvenc
	}
	return .Cpu
}

@(private = "file")
film_probe_lock: sync.Mutex
@(private = "file")
film_mp4_probed: bool
@(private = "file")
film_mp4_cached_backend: Film_Encoder_Backend
@(private = "file")
film_webm_probed: bool
@(private = "file")
film_webm_cached_backend: Film_Encoder_Backend

// film_detect_mp4_backend probes h264_nvenc once per tool run and falls back
// to Cpu when no NVENC-capable GPU is available.
film_detect_mp4_backend :: proc() -> Film_Encoder_Backend {
	sync.mutex_lock(&film_probe_lock)
	defer sync.mutex_unlock(&film_probe_lock)
	if !film_mp4_probed {
		film_mp4_cached_backend = film_nvenc_probe("h264_nvenc")
		film_mp4_probed = true
	}
	return film_mp4_cached_backend
}

// film_detect_webm_backend probes av1_nvenc once per tool run and falls back
// to Cpu when no AV1 NVENC-capable GPU is available.
film_detect_webm_backend :: proc() -> Film_Encoder_Backend {
	sync.mutex_lock(&film_probe_lock)
	defer sync.mutex_unlock(&film_probe_lock)
	if !film_webm_probed {
		film_webm_cached_backend = film_nvenc_probe("av1_nvenc")
		film_webm_probed = true
	}
	return film_webm_cached_backend
}

// film_encode_command gives the command of an encoder of a film, from the
// list of the timed pictures: the constant rate of the film, each pixel
// doubled with no filter, and the colors converted and named as those of
// a film in high definition, so that a player shows the colors of the
// screen. The two files of a film differ by the arguments of their
// encoder only.
@(private = "file")
film_encode_command :: proc(list_path, output: string, encoder: []string) -> []string {
	filter := fmt.tprintf("fps=%d,scale=iw*%d:ih*%d:flags=neighbor:out_color_matrix=bt709:out_range=tv", FILM_RATE, FILM_SCALE, FILM_SCALE)
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", list_path)
	append(&command, "-vf", filter)
	append(&command, ..encoder)
	append(&command, "-pix_fmt", "yuv420p")
	append(&command, "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv")
	append(&command, output)
	return command[:]
}

// film_mp4_encode_command gives the command that writes the MP4 file of a
// film for the given backend.
film_mp4_encode_command :: proc(list_path, output: string, backend: Film_Encoder_Backend = .Cpu) -> []string {
	return film_encode_command(list_path, output, film_mp4_encoder_args(backend))
}

// film_webm_encode_command gives the command that writes the WebM file of
// a film for the given backend and quality parameter.
film_webm_encode_command :: proc(list_path, output: string, backend: Film_Encoder_Backend = .Cpu, crf := FILM_WEBM_DEFAULT_CRF) -> []string {
	return film_encode_command(list_path, output, film_webm_encoder_args(backend, crf))
}

// film_key_periods gives the time after each key of a typed text of a
// film: FILM_KEY_PERIOD_MILLISECONDS, more or less a variation that a
// generator draws from the seed. The same seed gives the same times.
film_key_periods :: proc(count: int, seed: u64) -> []time.Duration {
	periods := make([]time.Duration, count, context.temp_allocator)
	state := rand.create_u64(seed)
	generator := rand.default_random_generator(&state)
	for &period in periods {
		variation := rand.int_max(2 * FILM_KEY_VARIATION_MILLISECONDS + 1, generator) - FILM_KEY_VARIATION_MILLISECONDS
		period = time.Duration(FILM_KEY_PERIOD_MILLISECONDS + variation) * time.Millisecond
	}
	return periods
}

// The worker of a film: the thread that takes the pictures between the
// steps Film_Start and Film_Stop, with its own connection to QEMU. The
// scenario thread sends its keys on the other connection, so a batch of
// keys and a picture never share a reply; QEMU does one command at a time,
// so each waits at most for the other one.
Film_Worker :: struct {
	worker:                ^thread.Thread,
	qmp:                   Qmp,
	folder:                string, // The folder of the pictures.
	started:               time.Tick,
	stop:                  bool, // The scenario thread sets it; the worker reads it before each picture.
	picture_count:         int,
	slots_without_picture: int, // The slots that passed while a picture before them was not written yet.
	newest_asked:          time.Duration, // When the worker asked for its newest picture.
	longest_gap:           time.Duration, // The longest time between two pictures.
	dump_times:            [dynamic]time.Duration, // From each command to its reply: QEMU wrote the whole file.
	failure:               string, // Why the worker ended before its stop, or "".
	cues:                  [dynamic]Film_Cue, // The scenario thread writes them; the worker thread never reads them.
}

@(private = "file")
film_worker_run :: proc(worker: ^Film_Worker) {
	next_slot := 0
	for !sync.atomic_load(&worker.stop) {
		now := time.tick_since(worker.started)
		if due := film_slot_start(next_slot); now < due {
			// The period of the rate of the film, never a wait for the machine.
			time.sleep(due - now)
			continue
		}
		// A picture has the slot of its real time: when the picture before
		// took longer than one period, the slots that passed get no picture.
		slot := max(film_slot_of(now), next_slot)
		path := strings.concatenate({worker.folder, "/", film_picture_name(now)}, context.temp_allocator)
		_, dumped := qmp_command(&worker.qmp, qmp_screendump_command(path))
		if !dumped {
			// A part of a picture is no picture of the film.
			_ = os.remove(path)
			if !worker.qmp.ended {
				worker.failure = "QEMU did not save a picture of the film"
			}
			break
		}
		append(&worker.dump_times, time.tick_since(worker.started) - now)
		if worker.picture_count > 0 {
			worker.longest_gap = max(worker.longest_gap, now - worker.newest_asked)
		}
		worker.newest_asked = now
		worker.picture_count += 1
		worker.slots_without_picture += slot - next_slot
		next_slot = slot + 1
		free_all(context.temp_allocator)
	}
}

// film_start starts the worker of the film with a name: its pictures go in
// a new, empty folder of that name.
film_start :: proc(machine: ^Machine, name: string) -> bool {
	if machine.film != nil {
		fmt.eprintln("modustool: the film: a step Film_Start while a film runs")
		return false
	}
	// Not in the temporary allocator: the scenario frees it after each step.
	folder := fmt.aprintf("%s/%s", FILM_FOLDER, name)
	worker := new(Film_Worker)
	worker.folder = folder
	if !foundation.reset_folder(folder) || !qmp_open(&worker.qmp, film_qmp_socket_of(machine.output)) {
		qmp_close(&worker.qmp)
		delete(folder)
		free(worker)
		return false
	}
	worker.started = time.tick_now()
	worker.worker = thread.create_and_start_with_poly_data(worker, film_worker_run)
	machine.film = worker
	return true
}

// film_stop ends the worker of the film of a machine, if one runs, and
// prints its measures: the rate that the pictures reached, the slots with
// no picture of their own, the longest time between two pictures, and the
// time of one picture of QEMU. No number of these makes the film fail.
film_stop :: proc(machine: ^Machine) -> bool {
	worker := machine.film
	if worker == nil {
		return true
	}
	machine.film = nil
	sync.atomic_store(&worker.stop, true)
	thread.join(worker.worker)
	thread.destroy(worker.worker)
	duration := time.tick_since(worker.started)
	qmp_close(&worker.qmp)
	passed := worker.failure == ""
	if !passed {
		fmt.eprintfln("modustool: the film: %s", worker.failure)
	}
	middle, longest: time.Duration
	if len(worker.dump_times) > 0 {
		slice.sort(worker.dump_times[:])
		middle = worker.dump_times[len(worker.dump_times) / 2]
		longest = worker.dump_times[len(worker.dump_times) - 1]
	}
	seconds := time.duration_seconds(duration)
	fmt.printfln(
		"modustool: measure: the film: %d pictures in %.1f s, %.1f in one second (the rate of the film is %d); %d slots have no picture of their own and show the picture before; the longest time between two pictures %.1f ms; one picture of QEMU %.1f ms in the middle, %.1f ms at most",
		worker.picture_count,
		seconds,
		seconds > 0 ? f64(worker.picture_count) / seconds : 0,
		FILM_RATE,
		worker.slots_without_picture,
		time.duration_milliseconds(worker.longest_gap),
		time.duration_milliseconds(middle),
		time.duration_milliseconds(longest),
	)
	// The cue file is beside the two files of the film, with the same name:
	// build/films/<name>.cues.
	cue_path := strings.concatenate({worker.folder, FILM_CUES_SUFFIX}, context.temp_allocator)
	if write_error := os.write_entire_file(cue_path, film_cue_text(worker.cues[:])); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", cue_path, write_error)
		passed = false
	} else {
		fmt.printfln("modustool: the film has %d cues in %s", len(worker.cues), cue_path)
	}
	delete(worker.cues)
	delete(worker.dump_times)
	delete(worker.folder)
	free(worker)
	return passed
}

// film_type types a text as a hand types it: one key, then the period of
// film_key_periods, and so on. After each key the tool waits, as for each
// key of a test, until the system read it; the periods count from the
// start of the text, so that wait does not add to them.
film_type :: proc(machine: ^Machine, text: string, seed: u64) -> bool {
	names, unknown := key_names_of_a_text(text)
	if unknown >= 0 {
		fmt.eprintfln("modustool: the film: no key for '%c'", text[unknown])
		return false
	}
	periods := film_key_periods(len(names), seed)
	what := fmt.tprintf("\"%s\"", text)
	started := time.tick_now()
	due: time.Duration
	for _, place in names {
		if wait := due - time.tick_since(started); wait > 0 {
			time.sleep(wait)
		}
		keys_send(machine, names[place:][:1], what) or_return
		due += periods[place]
	}
	if wait := due - time.tick_since(started); wait > 0 {
		time.sleep(wait)
	}
	return true
}

// A film that the command `film` makes.
Film :: struct {
	name:             string, // The argument of the command, the folder of the pictures and the name of the file.
	steps:            []Step,
	output:           string, // The log of its machine.
	needs_data_disk:  bool, // Prepares the tutorial STORAGE7 multi-store data disk.
	needs_cache_peer: bool, // Starts a local signed QUIC cache-serve forwarded at 10.0.2.100:5010.
}

FILM_NAMES :: "terminal | palette | heron | boot | desktop | console | program | monitor | tutorial"
TEST_OUTPUT_FILM_TERMINAL :: foundation.BUILD_FOLDER + "/test_output_film_terminal.txt"
TEST_OUTPUT_FILM_PALETTE :: foundation.BUILD_FOLDER + "/test_output_film_palette.txt"
TEST_OUTPUT_FILM_HERON :: foundation.BUILD_FOLDER + "/test_output_film_heron.txt"
TEST_OUTPUT_FILM_BOOT :: foundation.BUILD_FOLDER + "/test_output_film_boot.txt"
TEST_OUTPUT_FILM_DESKTOP :: foundation.BUILD_FOLDER + "/test_output_film_desktop.txt"
TEST_OUTPUT_FILM_CONSOLE :: foundation.BUILD_FOLDER + "/test_output_film_console.txt"
TEST_OUTPUT_FILM_PROGRAM :: foundation.BUILD_FOLDER + "/test_output_film_program.txt"
TEST_OUTPUT_FILM_MONITOR :: foundation.BUILD_FOLDER + "/test_output_film_monitor.txt"
TEST_OUTPUT_FILM_TUTORIAL :: foundation.BUILD_FOLDER + "/test_output_film_tutorial.txt"

// film_of_name gives the film with a name. The name of a film is the text
// of the step Film_Start of its scenario.
film_of_name :: proc(name: string) -> (film: Film, found: bool) {
	switch name {
	case "terminal":
		return Film{name = "terminal", steps = scenario_film[:], output = TEST_OUTPUT_FILM_TERMINAL}, true
	case "palette":
		return Film{name = "palette", steps = scenario_palette_film[:], output = TEST_OUTPUT_FILM_PALETTE}, true
	case "heron":
		return Film{name = "heron", steps = scenario_heron_film[:], output = TEST_OUTPUT_FILM_HERON}, true
	case "boot":
		return Film{name = "boot", steps = scenario_boot_film[:], output = TEST_OUTPUT_FILM_BOOT}, true
	case "desktop":
		return Film{name = "desktop", steps = scenario_desktop_film[:], output = TEST_OUTPUT_FILM_DESKTOP}, true
	case "console":
		return Film{name = "console", steps = scenario_console_film[:], output = TEST_OUTPUT_FILM_CONSOLE}, true
	case "program":
		return Film{name = "program", steps = scenario_program_film[:], output = TEST_OUTPUT_FILM_PROGRAM}, true
	case "monitor":
		return Film{name = "monitor", steps = scenario_monitor_film[:], output = TEST_OUTPUT_FILM_MONITOR}, true
	case "tutorial":
		return Film{
			name             = "tutorial",
			steps            = scenario_tutorial_film[:],
			output           = TEST_OUTPUT_FILM_TUTORIAL,
			needs_data_disk  = true,
			needs_cache_peer = true,
		}, true
	}
	return {}, false
}

// The parsed arguments of `modustool film`.
Film_Command_Options :: struct {
	name:         string,
	optimization: build.Optimization_Mode,
}

FILM_COMMAND_USAGE :: "film [--fast] [" + FILM_NAMES + "]"

// film_arguments_parse parses `film [--fast] [<name>]` (accepting `--fast`
// before or after the optional film name).
film_arguments_parse :: proc(args: []string) -> (options: Film_Command_Options, problem: string) {
	options.name = "terminal"
	options.optimization = .Speed
	seen_fast := false
	seen_name := false
	for arg in args {
		if arg == build.BUILD_FAST_FLAG {
			if seen_fast {
				return {}, "film: `--fast` is written two times; the form: `" + FILM_COMMAND_USAGE + "`"
			}
			seen_fast = true
			options.optimization = .None
			continue
		}
		if strings.has_prefix(arg, "-") {
			return {}, fmt.tprintf("film: unknown option `%s`; the form: `%s`", arg, FILM_COMMAND_USAGE)
		}
		if seen_name {
			return {}, "film: too many arguments; the form: `" + FILM_COMMAND_USAGE + "`"
		}
		if _, found := film_of_name(arg); !found {
			return {}, fmt.tprintf("film: unknown film `%s`; the form: `%s`", arg, FILM_COMMAND_USAGE)
		}
		seen_name = true
		options.name = arg
	}
	return options, ""
}

// run_film makes one film: `film` and `film terminal` the film of the
// terminal, `film palette` the film of the palette, `film heron` the film
// of the process heron, `film boot` the film of the boot of the machine,
// `film desktop`, `film console` and `film program` the films of the
// chapters of the tutorial, and `film monitor` the film of the graphs of
// monitor under a load (docs/TOOLS.md, "The film").
// The films differ by their scenario only: the worker, the list of the
// encoder and the encoder are the same. A film is for the development log, and for the
// news entry that names it: it is not a test, and no check runs it.
run_film :: proc(args: []string) -> int {
	command_options, problem := film_arguments_parse(args)
	if problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return foundation.EXIT_USAGE
	}
	film, _ := film_of_name(command_options.name)
	build.build_optimization_mode = command_options.optimization
	build.build_cache_folder_set(build.build_whole ? "" : build.build_cache_resolve(""))
	filter_modules := command_options.optimization == .None && !build.build_whole
	if code := build.build_system(build.boot_volumes_of_command("film"), filter_modules = filter_modules); code != 0 {
		return code
	}
	if !foundation.make_folder(FILM_FOLDER) || !foundation.make_folder(SCREENSHOT_FOLDER) {
		return foundation.EXIT_FAILURE
	}
	// The machine starts paused only for a scenario that lets it run with a
	// step Monitor "cont": a paused machine with no such step never starts.
	paused := false
	for step in film.steps {
		if step.kind == .Monitor && step.text == "cont" {
			paused = true
		}
	}
	part := test_part_run_make("film")
	defer test_part_run_free(&part)
	options := Machine_Options{
		volume      = build.BOOT_VOLUME,
		output      = film.output,
		exit_status = 0,
		vnc         = true,
		paused      = paused,
	}
	steps := film.steps
	tutorial_fixture: ^Tutorial_Film_Fixture
	expanded_steps: []Step
	defer tutorial_film_teardown(tutorial_fixture)
	defer if len(expanded_steps) > 0 {
		tutorial_film_steps_free(expanded_steps)
	}
	if film.needs_data_disk || film.needs_cache_peer {
		prepared, ok := tutorial_film_prepare()
		if !ok {
			return foundation.EXIT_FAILURE
		}
		tutorial_fixture = prepared
		expanded, expanded_ok := tutorial_film_expand_steps(film.steps, tutorial_fixture.bindings)
		if !expanded_ok {
			fmt.eprintln("modustool: the tutorial film: failed to expand scenario placeholders")
			return foundation.EXIT_FAILURE
		}
		expanded_steps = expanded
		steps = expanded_steps
		if film.needs_data_disk {
			options.data_disk = tutorial_fixture.data_disk_path
		}
		if film.needs_cache_peer {
			options.cache_endpoint = tutorial_fixture.cache_endpoint
		}
		options.fact_outside_modules = tutorial_fixture.fact_outside_modules[:]
	}
	// The tool ends QEMU: status 0.
	if !test_part_run_start(&part) || !machine_test(&part, steps, options) {
		return foundation.EXIT_FAILURE
	}
	return film_write(film.name) ? 0 : foundation.EXIT_FAILURE
}

// The moments of a film whose picture goes to the development log beside
// the film, as parts of its length.
@(private = "file", rodata)
film_still_parts := [?]int{1, 2, 3}
FILM_STILL_DIVISOR :: 4

// film_write makes the two files of a film from its pictures, copies the
// MP4 file and three of its pictures to a new folder of the development
// log, removes the pictures, and copies the WebM file to the repository
// when a news entry names the film.
film_write :: proc(name: string) -> bool {
	folder := foundation.join(FILM_FOLDER, "/", name)
	paths, listed := foundation.files_with_suffix(folder, FILM_PICTURE_SUFFIX)
	if !listed || len(paths) == 0 {
		fmt.eprintfln("modustool: the film %s has no picture in %s: its scenario has no step Film_Start, or QEMU wrote none", name, folder)
		return false
	}
	// The names are times in ten digits: their order is the order of the times.
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
	slot_count := film_slot_count(runs)
	list_path := foundation.join(folder, "/", FILM_LIST_NAME)
	if write_error := os.write_entire_file(list_path, film_list_text(names, runs)); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", list_path, write_error)
		return false
	}
	// Two files from the same timed pictures: the MP4 file for a post on
	// another site, and the WebM file, which the repository holds when a
	// news entry names the film.
	mp4_backend := film_detect_mp4_backend()
	output := foundation.join(FILM_FOLDER, "/", name, FILM_MP4_SUFFIX)
	foundation.run(film_mp4_encode_command(list_path, output, mp4_backend)) or_return
	webm_backend := film_detect_webm_backend()
	webm_output := foundation.join(FILM_FOLDER, "/", name, FILM_WEBM_SUFFIX)
	foundation.run(film_webm_encode_command(list_path, webm_output, webm_backend)) or_return
	// The name of the folder is the time of the run, in UTC.
	year, month, day := time.date(time.now())
	hour, minute, second := time.clock(time.now())
	log_folder := fmt.tprintf("%s/%04d-%02d-%02d_%02d%02d%02d_film_%s", foundation.development_log_folder(), year, int(month), day, hour, minute, second, name)
	foundation.make_folder(log_folder) or_return
	target := foundation.join(log_folder, "/", name, FILM_MP4_SUFFIX)
	if copy_error := os.copy_file(target, output); copy_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", target, copy_error)
		return false
	}
	for part in film_still_parts {
		slot := slot_count * part / FILM_STILL_DIVISOR
		for film_run in runs {
			if slot >= film_run.first_slot && slot < film_run.first_slot + film_run.slot_count {
				still := fmt.tprintf("%s/%s_at_%03d_seconds.png", log_folder, name, slot / FILM_RATE)
				foundation.run({"ffmpeg", "-loglevel", "error", "-y", "-i", paths[film_run.picture], still}) or_return
				break
			}
		}
	}
	if remove_error := os.remove_all(folder); remove_error != nil {
		fmt.eprintfln("modustool: cannot remove %s: %v", folder, remove_error)
		return false
	}
	backend_names := FILM_ENCODER_BACKEND_NAMES
	fmt.printfln("modustool: wrote %s (%s) and %s (%s) (%d pictures in %d slots of the film, %.1f s), and %s", output, backend_names[mp4_backend], webm_output, backend_names[webm_backend], len(paths), slot_count, f64(slot_count) / FILM_RATE, target)
	if film_is_named_by_a_news_entry(name) {
		film_document_write(name, webm_output) or_return
	}
	return true
}
