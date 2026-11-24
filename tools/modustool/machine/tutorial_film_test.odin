// Host tests for the tutorial film scenario, placeholder expansion, project
// tree hashing + recipe evaluation, peer cache UDP forwarder, and signed QUIC
// cache seeding.
package machine

import "base:runtime"
import "core:crypto"
import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "internal:recipes/recipes_core"
import "modus:contract/blake3"
import module "modus:contract/module"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/release"
import "modus:cryptography/ed25519"
import "modus:random"
import "modustool:build"
import "modustool:cache_server"

@(private = "file")
sample_tutorial_bindings :: proc() -> Tutorial_Film_Bindings {
	return {
		cache_server_key  = strings.repeat("1", 64, context.temp_allocator),
		cache_signer_key  = strings.repeat("2", 64, context.temp_allocator),
		db_browser_here   = strings.repeat("4", 64, context.temp_allocator),
		db_browser_recipe = strings.repeat("5", 64, context.temp_allocator),
		db_browser_output = strings.repeat("6", 64, context.temp_allocator),
		db_browser_hash   = strings.repeat("7", 64, context.temp_allocator),
	}
}

// Placeholder expansion refuses missing required bindings, expands every
// tutorial placeholder cleanly, ensures zero raw 64-hex placeholders are typed
// on camera (Film_Type), and produces only keystrokes supported by
// key_names_of_a_text.
@(test)
tutorial_film_expands_placeholders_and_refuses_missing_bindings :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Missing required binding is refused.
	incomplete := sample_tutorial_bindings()
	incomplete.cache_server_key = ""
	_, ok := tutorial_film_expand_steps(scenario_tutorial_film[:], incomplete)
	testing.expect(t, !ok, "empty cache_server_key binding is refused")

	incomplete2 := sample_tutorial_bindings()
	incomplete2.db_browser_output = ""
	_, ok = tutorial_film_expand_steps(scenario_tutorial_film[:], incomplete2)
	testing.expect(t, !ok, "empty db_browser_output binding is refused")

	// No on-camera Film_Type step may type a raw hash placeholder or mention collatz,
	// and no console variable assignment may be followed immediately by a [console]
	// value wait without first evaluating a non-assignment expression (assignments
	// draw nothing in src/modules/system/console/language.odin).
	last_typed_was_assignment := false
	for step, index in scenario_tutorial_film {
		testing.expectf(t, !strings.contains(step.text, "collatz"), "step %d must not reference collatz: %s", index + 1, step.text)
		if step.kind == .Film_Type {
			testing.expectf(t, !strings.contains_rune(step.text, '{'), "on-camera Film_Type step %d must use Lex variables, not raw hash placeholders: %s", index + 1, step.text)
			last_typed_was_assignment = strings.contains(step.text, " = ")
		} else if step.kind == .Wait && strings.has_prefix(step.text, "[console] ") && !strings.has_prefix(step.text, "[console] > ") {
			testing.expectf(t, !last_typed_was_assignment, "step %d waits for drawn console output %q directly after a variable assignment", index + 1, step.text)
		}
	}

	// Complete bindings expand cleanly with zero leftover placeholders.
	bindings := sample_tutorial_bindings()
	expanded, expanded_ok := tutorial_film_expand_steps(scenario_tutorial_film[:], bindings)
	if !testing.expect(t, expanded_ok, "complete bindings expand cleanly") {
		return
	}
	defer tutorial_film_steps_free(expanded)
	testing.expect_value(t, len(expanded), len(scenario_tutorial_film))

	for step, index in expanded {
		testing.expectf(t, !strings.contains_rune(step.text, '{'), "step %d text still has placeholder: %s", index + 1, step.text)
		testing.expectf(t, !strings.contains_rune(step.expected, '{'), "step %d expected still has placeholder: %s", index + 1, step.expected)
		if step.kind == .Type || step.kind == .Film_Type {
			_, unknown := key_names_of_a_text(step.text)
			testing.expectf(t, unknown < 0, "step %d (%v) contains untypeable character at %d: %q", index + 1, step.kind, unknown, step.text)
		}
	}
}

// The real db_browser project folder hashes deterministically under MODTREE2
// and its Lex v3 project.lex (with let, here(), typed units, with, recipe, and
// store) evaluates cleanly against a generated catalog.lex.
@(test)
tutorial_project_trees_hash_and_evaluate_recipes_deterministically :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	db_objs, db_trees, db_here, db_ok := tutorial_read_project_tree(TUTORIAL_DB_BROWSER_DIR)
	if !testing.expect(t, db_ok, "db_browser project tree reads and hashes") {
		return
	}
	defer tutorial_free_project_tree(db_objs, db_trees)
	testing.expect(t, len(db_trees) >= 1, "db_browser includes nested core/ subtree")

	// Build a deterministic catalog.lex with the four required builder modules.
	catalog_modules := [?]build.Module_Hash{
		{name = "assemble", hash = blake3.hash(transmute([]u8)string("asm"))},
		{name = "c_builder", hash = blake3.hash(transmute([]u8)string("cb"))},
		{name = "c_compiler", hash = blake3.hash(transmute([]u8)string("cc"))},
		{name = "host", hash = blake3.hash(transmute([]u8)string("host"))},
	}
	catalog_lex, cat_problem := build.system_catalog_of_modules(catalog_modules[:], release.RELEASE_NUMBER, .Boot_Image)
	testing.expect_value(t, cat_problem, "")

	db_lex, db_lex_err := os.read_entire_file(TUTORIAL_DB_BROWSER_DIR + "/project.lex", context.temp_allocator)
	testing.expect(t, db_lex_err == nil)
	db_lex_text := string(db_lex)
	for token in ([]string{"project {", "here()", "with {", "MiB", "recipe(", "store(\"db_browser\""}) {
		testing.expectf(t, strings.contains(db_lex_text, token), "db_browser/project.lex demonstrates `%s`", token)
	}

	db_recipe_1, r1_ok := tutorial_evaluate_project_recipe(db_lex_text, db_here, catalog_lex)
	db_recipe_2, r2_ok := tutorial_evaluate_project_recipe(db_lex_text, db_here, catalog_lex)
	testing.expect(t, r1_ok && r2_ok, "db_browser outputs.default evaluates to a recipe")
	testing.expect_value(t, db_recipe_1, db_recipe_2)

	// Malformed project.lex is refused cleanly.
	_, bad_ok := tutorial_evaluate_project_recipe("project { outputs = { default = 42 } }", db_here, catalog_lex)
	testing.expect(t, !bad_ok, "non-recipe outputs.default is refused")
}

// Chapter cards and lower-third captions align with scenario_tutorial_film
// cues, splice into pictures.ffconcat without overlap, generate valid 1080p
// ASS subtitles and PPM cards, and refuse malformed cue files or missing cues.
@(test)
tutorial_film_compose_splices_cards_and_captions_without_overlap :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// 1. Cue parser refusals and valid parsing.
	for bad in ([]string{
		"not_a_time foo\n",
		"1.2 foo\n",
		"-1.000 foo\n",
		"1.000 BadName\n",
		"2.000 a\n1.500 b\n",
		"1.000 dup\n2.000 dup\n",
	}) {
		_, parsed := tutorial_cues_parse(bad)
		testing.expectf(t, !parsed, "malformed cues %q are refused", bad)
	}

	// 2. Collect every cue declared in scenario_tutorial_film in scenario order
	//    and assign synthetic monotonically increasing timestamps.
	scenario_cues := make([dynamic]Film_Cue, context.temp_allocator)
	cue_time := time.Duration(0)
	for step in scenario_tutorial_film {
		if step.kind == .Film_Hold && step.text != "" {
			append(&scenario_cues, Film_Cue{since_start = cue_time, name = step.text})
			cue_time += 4 * time.Second
		}
	}
	cue_text := film_cue_text(scenario_cues[:])
	parsed_cues, parsed_ok := tutorial_cues_parse(cue_text)
	if !testing.expect(t, parsed_ok, "scenario cues round-trip cleanly") {
		return
	}
	defer tutorial_cues_free(parsed_cues)
	testing.expect_value(t, len(parsed_cues), len(scenario_cues))

	// 3. Build synthetic runs spanning past the last cue (with multi-slot runs
	//    so chapter card splices exercise mid-run splitting).
	raw_total_s := int(cue_time / time.Second) + 4
	pic_names := make([]string, raw_total_s, context.temp_allocator)
	pic_times := make([]time.Duration, raw_total_s, context.temp_allocator)
	for i in 0 ..< raw_total_s {
		pic_times[i] = time.Duration(i) * time.Second
		pic_names[i] = fmt.tprintf("%010d.ppm", i * 1_000_000)
	}
	runs := film_runs(pic_times)
	raw_total_us := film_slot_microseconds(film_slot_count(runs))

	// Refusals: empty runs, missing cue in cues slice.
	_, bad_runs := tutorial_timeline_build(nil, nil, parsed_cues, tutorial_chapter_cards[:], tutorial_captions[:])
	testing.expect(t, !bad_runs, "empty runs are refused")
	_, missing_cue := tutorial_timeline_build(pic_names, runs, parsed_cues[:1], tutorial_chapter_cards[:], tutorial_captions[:])
	testing.expect(t, !missing_cue, "missing required cue is refused")

	// 4. Compose full 7-chapter timeline and verify exact duration conservation
	//    and strict non-overlap between every card and every caption.
	timeline, ok := tutorial_timeline_build(pic_names, runs, parsed_cues, tutorial_chapter_cards[:], tutorial_captions[:])
	if !testing.expect(t, ok, "full 7-chapter tutorial timeline builds cleanly") {
		return
	}
	defer tutorial_timeline_free(&timeline)
	testing.expect_value(t, len(timeline.card_spans), len(tutorial_chapter_cards))
	testing.expect_value(t, len(timeline.caption_spans), len(tutorial_captions))

	expected_cards_us: i64 = 0
	for card in tutorial_chapter_cards {
		expected_cards_us += card.duration_ms * 1000
	}
	actual_total_us: i64 = 0
	for entry in timeline.entries {
		testing.expect(t, entry.duration_us > 0, "every spliced ffconcat entry has positive duration")
		actual_total_us += entry.duration_us
	}
	testing.expect_value(t, actual_total_us, raw_total_us + expected_cards_us)

	// No two cards overlap, no two captions overlap, and no caption overlaps any card.
	for i in 0 ..< len(timeline.card_spans) {
		a := timeline.card_spans[i]
		testing.expect(t, a.end_ms > a.start_ms, "card span has positive duration")
		if i > 0 {
			testing.expect(t, a.start_ms >= timeline.card_spans[i - 1].end_ms, "cards are ordered without overlap")
		}
		for cap in timeline.caption_spans {
			overlaps := cap.start_ms < a.end_ms && cap.end_ms > a.start_ms
			testing.expectf(t, !overlaps, "caption %d [%d..%d] must not overlap card %d [%d..%d]", cap.caption_index, cap.start_ms, cap.end_ms, a.card_index, a.start_ms, a.end_ms)
		}
	}
	for i in 1 ..< len(timeline.caption_spans) {
		testing.expect(t, timeline.caption_spans[i].start_ms >= timeline.caption_spans[i - 1].end_ms, "captions are ordered without overlap")
	}

	// Every chapter card spliced before a cue starts a caption at that exact cue
	// (no uncaptioned gap right after a chapter card).
	for card in tutorial_chapter_cards {
		if card.anchor != .Before_Cue {
			continue
		}
		has_caption := false
		for cap in tutorial_captions {
			if cap.cue_name == card.cue_name {
				has_caption = true
				break
			}
		}
		testing.expectf(t, has_caption, "chapter card %s cue `%s` has an immediate caption", card.id, card.cue_name)
	}

	// ffconcat output repeats the final file line without a duration so FFmpeg's
	// concat demuxer honors the final Chapter 7 card's 4.0 s duration.
	ffconcat := tutorial_ffconcat_text(timeline.entries)
	testing.expect(t, strings.has_suffix(ffconcat, "file 'card_ch7.ppm'\nduration 4.000000\nfile 'card_ch7.ppm'\n"), "ffconcat repeats final card file line after its 4.0 s duration")

	// 5. ASS formatting helpers, ASCII-only glyph coverage for B612 ASCII, and generated script.
	testing.expect_value(t, tutorial_ass_color({0x12, 0x34, 0x56}, 0x10), "&H10563412")
	testing.expect_value(t, tutorial_ass_timestamp(0), "0:00:00.00")
	testing.expect_value(t, tutorial_ass_timestamp(65_439), "0:01:05.43")
	testing.expect_value(t, tutorial_ass_escape("a {b}\nc"), "a \\{b\\}\\Nc")

	is_printable_ascii :: proc(s: string) -> bool {
		for b in transmute([]u8)s {
			if b < 0x20 || b > 0x7E {
				return false
			}
		}
		return true
	}
	for card in tutorial_chapter_cards {
		testing.expectf(t, is_printable_ascii(card.kicker) && is_printable_ascii(card.title) && is_printable_ascii(card.footer), "card %s uses printable ASCII for B612 ASCII font coverage", card.id)
		for line in card.lines {
			testing.expectf(t, is_printable_ascii(line), "card %s line uses printable ASCII: %s", card.id, line)
		}
	}
	for cap in tutorial_captions {
		testing.expectf(t, is_printable_ascii(cap.kicker) && is_printable_ascii(cap.heading) && is_printable_ascii(cap.body), "caption %s uses printable ASCII for B612 ASCII font coverage", cap.cue_name)
	}

	ass := tutorial_ass_generate(timeline, tutorial_chapter_cards[:], tutorial_captions[:])
	defer delete(ass)
	testing.expect(t, !strings.contains(ass, "%!("), "generated ASS contains zero fmt formatting errors")
	for snippet in ([]string{
		"PlayResX: 1920",
		"PlayResY: 1080",
		TUTORIAL_FONT_BOLD,
		TUTORIAL_FONT_REGULAR,
		TUTORIAL_FONT_MONO,
		"Building a sandboxed SQLite GUI app on modus",
		"modus.systems",
		"Dialogue: 0,",
		"Dialogue: 2,",
		"{\\an7\\pos(",
		"\\p1}m 0 0 l ",
		"{\\p0}",
	}) {
		testing.expectf(t, strings.contains(ass, snippet), "generated ASS contains `%s`", snippet)
	}

	// 6. Card PPM encoder refusals and valid P6 output.
	_, bad_ppm := tutorial_card_ppm_encode(32, 32, .System)
	testing.expect(t, !bad_ppm, "undersized card PPM is refused")
	ppm, ppm_ok := tutorial_card_ppm_encode(192, 108, .Grant)
	if testing.expect(t, ppm_ok, "card PPM encodes cleanly") {
		defer delete(ppm)
		testing.expect(t, strings.has_prefix(string(ppm), "P6\n192 108\n255\n"), "card PPM starts with P6 header")
		testing.expect_value(t, len(ppm), len("P6\n192 108\n255\n") + 192 * 108 * 3)
	}

	// 7. Encoder command shapes: native 1920x1080 30 fps with libass + resources/fonts,
	//    both CPU and NVENC backends, and exact `-t` duration clamping the trailing ffconcat repeat.
	mp4_cmd := tutorial_mp4_encode_command("build/films/tutorial/pictures.ffconcat", "build/films/tutorial/tutorial.ass", TUTORIAL_FONTS_FOLDER, 65_432, "build/films/tutorial.mp4")
	mp4_joined := strings.join(mp4_cmd, " ", context.temp_allocator)
	for part in ([]string{"fps=30,scale=1920:1080:flags=neighbor,ass=filename=", "fontsdir=resources/fonts", "-c:v libx264", "-movflags +faststart", "-t 65.432 build/films/tutorial.mp4"}) {
		testing.expectf(t, strings.contains(mp4_joined, part), "tutorial CPU MP4 command contains `%s`: %s", part, mp4_joined)
	}
	mp4_nvenc_cmd := tutorial_mp4_encode_command("build/films/tutorial/pictures.ffconcat", "build/films/tutorial/tutorial.ass", TUTORIAL_FONTS_FOLDER, 65_432, "build/films/tutorial.mp4", .Nvenc)
	mp4_nvenc_joined := strings.join(mp4_nvenc_cmd, " ", context.temp_allocator)
	for part in ([]string{"-c:v h264_nvenc", "-preset p4", "-cq 19", "-movflags +faststart", "-t 65.432 build/films/tutorial.mp4"}) {
		testing.expectf(t, strings.contains(mp4_nvenc_joined, part), "tutorial NVENC MP4 command contains `%s`: %s", part, mp4_nvenc_joined)
	}
	webm_cmd := tutorial_webm_encode_command("build/films/tutorial/pictures.ffconcat", "build/films/tutorial/tutorial.ass", TUTORIAL_FONTS_FOLDER, 42, 65_432, "build/films/tutorial.webm")
	webm_joined := strings.join(webm_cmd, " ", context.temp_allocator)
	for part in ([]string{"fps=30,scale=1920:1080:flags=neighbor,ass=filename=", "fontsdir=resources/fonts", "-c:v libsvtav1", "-crf 42", "-an", "-t 65.432 build/films/tutorial.webm"}) {
		testing.expectf(t, strings.contains(webm_joined, part), "tutorial CPU WebM command contains `%s`: %s", part, webm_joined)
	}
	webm_nvenc_cmd := tutorial_webm_encode_command("build/films/tutorial/pictures.ffconcat", "build/films/tutorial/tutorial.ass", TUTORIAL_FONTS_FOLDER, 46, 65_432, "build/films/tutorial.webm", .Nvenc)
	webm_nvenc_joined := strings.join(webm_nvenc_cmd, " ", context.temp_allocator)
	for part in ([]string{"-c:v av1_nvenc", "-preset p4", "-cq 46", "-an", "-t 65.432 build/films/tutorial.webm"}) {
		testing.expectf(t, strings.contains(webm_nvenc_joined, part), "tutorial NVENC WebM command contains `%s`: %s", part, webm_nvenc_joined)
	}
}

// peer_cache answers ARP for 10.0.2.100, builds checksum-valid UDP frames from
// 10.0.2.100:5010, forwards UDP datagrams bidirectionally to a loopback socket,
// and drops oversized datagrams without sending.
@(test)
peer_cache_answers_arp_and_forwards_udp_bidirectionally :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// 1. ARP reply claims 10.0.2.100 at PEER_CACHE_HARDWARE.
	req_frame: [60]u8
	req_frame[0], req_frame[1], req_frame[2], req_frame[3], req_frame[4], req_frame[5] = 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	machine_mac := [6]u8{0x52, 0x54, 0x00, 0x12, 0x34, 0x56}
	copy(req_frame[6:12], machine_mac[:])
	put16(req_frame[:], 12, 0x0806)
	put16(req_frame[:], 14, 1)
	put16(req_frame[:], 16, 0x0800)
	req_frame[18], req_frame[19] = 6, 4
	put16(req_frame[:], 20, 1)
	copy(req_frame[22:28], machine_mac[:])
	copy(req_frame[28:32], MACHINE_ADDRESS[:])
	copy(req_frame[38:42], PEER_CACHE_ADDRESS[:])

	arp_reply := peer_cache_arp_reply(req_frame[:], req_frame[14:])
	testing.expect_value(t, be16(arp_reply[:], 12), 0x0806)
	testing.expect_value(t, be16(arp_reply[:], 20), 2)
	testing.expect(t, slice.equal(arp_reply[22:28], PEER_CACHE_HARDWARE[:]))
	testing.expect(t, slice.equal(arp_reply[28:32], PEER_CACHE_ADDRESS[:]))
	testing.expect(t, slice.equal(arp_reply[32:38], machine_mac[:]))

	// 2. Generated IPv4 + UDP frame has valid checksums and ports.
	payload := transmute([]u8)string("hello-cache")
	udp_frame := peer_cache_udp_frame(machine_mac, 54321, payload)
	testing.expect_value(t, internet_sum(0, udp_frame[14:34]), 0)
	udp_len := 8 + len(payload)
	testing.expect_value(t, be16(udp_frame, 34), int(PEER_CACHE_PORT))
	testing.expect_value(t, be16(udp_frame, 36), 54321)
	testing.expect_value(t, internet_sum(pseudo_sum(PEER_CACHE_ADDRESS[:], MACHINE_ADDRESS[:], udp_len), udp_frame[34:34 + udp_len]), 0)

	// 3. Bidirectional forwarding through Peer_Cache against a loopback UDP socket.
	echo_sock, echo_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if !testing.expect(t, echo_err == nil) {
		return
	}
	defer net.close(echo_sock)
	echo_ep, ep_err := net.bound_endpoint(echo_sock)
	testing.expect(t, ep_err == nil)
	_ = net.set_option(echo_sock, .Receive_Timeout, 200 * time.Millisecond)

	recv_sock, recv_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if !testing.expect(t, recv_err == nil) {
		return
	}
	defer net.close(recv_sock)
	recv_ep, recv_ep_err := net.bound_endpoint(recv_sock)
	testing.expect(t, recv_ep_err == nil)
	_ = net.set_option(recv_sock, .Receive_Timeout, 200 * time.Millisecond)

	peer_sock, peer_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if !testing.expect(t, peer_err == nil) {
		return
	}
	defer net.close(peer_sock)

	peer := Peer{
		socket   = peer_sock,
		machine  = recv_ep,
		hardware = machine_mac,
	}
	testing.expect(t, peer_cache_start(&peer.cache, echo_ep))
	defer peer_cache_stop(&peer.cache)

	// Oversized datagram is refused and counted.
	oversized := make([]u8, PEER_CACHE_DATA_LIMIT + 1, context.temp_allocator)
	peer_cache_datagram(&peer, 44444, oversized)
	testing.expect_value(t, peer.cache.too_long, 1)
	testing.expect_value(t, peer.cache.to_cache, 0)

	// Valid datagram forwards to echo_sock and reply relays back as an Ethernet frame.
	peer_cache_datagram(&peer, 44444, payload)
	testing.expect_value(t, peer.cache.to_cache, 1)

	got: [128]u8
	n, from, r_err := net.recv_udp(echo_sock, got[:])
	testing.expect(t, r_err == nil && n == len(payload))
	testing.expect(t, slice.equal(got[:n], payload))

	// Stray loopback datagram from another sender is dropped, never injected.
	stray_sock, stray_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if testing.expect(t, stray_err == nil) {
		defer net.close(stray_sock)
		cache_ep, cache_ep_err := net.bound_endpoint(peer.cache.socket)
		testing.expect(t, cache_ep_err == nil)
		_, _ = net.send_udp(stray_sock, transmute([]u8)string("spoofed"), cache_ep)
	}

	reply_msg := transmute([]u8)string("cache-reply")
	_, s_err := net.send_udp(echo_sock, reply_msg, from)
	testing.expect(t, s_err == nil)

	// Wait bounded for peer_cache_tick to relay the Ethernet frame back to recv_sock.
	relayed := false
	frame_buf: [2048]u8
	for started := time.tick_now(); time.tick_since(started) < 2 * time.Second; {
		peer_cache_tick(&peer)
		fn, _, f_err := net.recv_udp(recv_sock, frame_buf[:])
		if f_err == nil && fn >= 42 + len(reply_msg) {
			testing.expect_value(t, be16(frame_buf[:fn], 34), int(PEER_CACHE_PORT))
			testing.expect_value(t, be16(frame_buf[:fn], 36), 44444)
			testing.expect(t, slice.equal(frame_buf[42:42 + len(reply_msg)], reply_msg))
			relayed = true
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, relayed, "peer_cache relayed UDP reply back to machine")
	testing.expect_value(t, peer.cache.to_machine, 1)
	testing.expect_value(t, peer.cache.wrong_sender, 1)
}

@(private = "file")
Tutorial_Test_Udp :: struct {
	socket:     net.UDP_Socket,
	remote:     net.Endpoint,
	start_tick: time.Tick,
}

@(private = "file")
tutorial_test_udp_send :: proc "contextless" (bytes: []u8, user_data: rawptr) -> bool {
	context = runtime.default_context()
	u := (^Tutorial_Test_Udp)(user_data)
	sent, err := net.send_udp(u.socket, bytes, u.remote)
	return err == nil && sent == len(bytes)
}

@(private = "file")
tutorial_test_udp_recv :: proc "contextless" (buffer: []u8, deadline_us: u64, user_data: rawptr) -> (length: int, ok: bool) {
	context = runtime.default_context()
	u := (^Tutorial_Test_Udp)(user_data)
	now := tutorial_test_udp_now_us(user_data)
	wait_us := deadline_us > now ? deadline_us - now : 1000
	_ = net.set_option(u.socket, .Receive_Timeout, min(max(time.Duration(wait_us) * time.Microsecond, time.Millisecond), 50 * time.Millisecond))
	n, _, err := net.recv_udp(u.socket, buffer)
	if err != nil || n <= 0 {
		return 0, false
	}
	return n, true
}

@(private = "file")
tutorial_test_udp_now_us :: proc "contextless" (user_data: rawptr) -> u64 {
	context = runtime.default_context()
	u := (^Tutorial_Test_Udp)(user_data)
	return u64(time.tick_since(u.start_tick) / time.Microsecond) + 1
}

// cache_server_seed_object + cache_server_seed_realisation refuse bad inputs
// and serve verified signed objects/realisations over QUIC to recipes_core.
@(test)
tutorial_cache_seed_serves_signed_realisation_over_quic :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	temp_base, _ := os.temp_dir(context.temp_allocator)
	if temp_base == "" {
		temp_base = "/tmp"
	}
	dir := fmt.aprintf("%s/modus_tutorial_cache_test_%d", strings.trim_right(temp_base, "/"), os.get_pid())
	_ = os.remove_all(dir)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}

	signer_seed := [32]u8{}
	quic_seed := [32]u8{}
	untrusted_seed := [32]u8{}
	for i in 0 ..< 32 {
		signer_seed[i] = 0x31 + u8(i * 7)
		quic_seed[i] = 0x51 + u8(i * 9)
		untrusted_seed[i] = 0x91 + u8(i * 5)
	}
	signer_priv: ed25519.Private_Key
	defer ed25519.private_key_clear(&signer_priv)
	testing.expect(t, ed25519.private_key_set_bytes(&signer_priv, signer_seed[:]))
	signer_pub: [32]u8
	ed25519.private_key_public_bytes(&signer_priv, signer_pub[:])

	server, opened := cache_server.cache_server_open(dir, [][32]u8{signer_pub})
	if !testing.expect(t, opened) {
		return
	}
	defer cache_server.cache_server_destroy(&server)

	// Refusal cases: empty blob, invalid kind, untrusted signer.
	_, ok := cache_server.cache_server_seed_object(&server, .Blob, nil, signer_seed)
	testing.expect(t, !ok, "empty blob seed is refused")
	_, ok = cache_server.cache_server_seed_object(&server, object_cache.Cache_Object_Kind(0), transmute([]u8)string("x"), signer_seed)
	testing.expect(t, !ok, "invalid kind seed is refused")
	_, ok = cache_server.cache_server_seed_object(&server, .Blob, transmute([]u8)string("x"), untrusted_seed)
	testing.expect(t, !ok, "untrusted signer seed is refused")

	// Seed a blob, its canonical single-entry "module" tree, and a signed Tree
	// realisation, then fetch the tree closure over live QUIC.
	blob := transmute([]u8)string("tutorial-db-browser-module-bytes-v1")
	blob_hash, obj_ok := cache_server.cache_server_seed_object(&server, .Blob, blob, signer_seed)
	testing.expect(t, obj_ok)
	testing.expect_value(t, blob_hash, blake3.hash(blob))

	tree_bytes, tree_ok := tutorial_module_output_tree(blob_hash, context.temp_allocator)
	testing.expect(t, tree_ok)
	out_hash, tree_seed_ok := cache_server.cache_server_seed_object(&server, .Tree, tree_bytes, signer_seed)
	testing.expect(t, tree_seed_ok)

	recipe_hash := blake3.hash(transmute([]u8)string("tutorial-db-browser-recipe"))
	_, real_ok := cache_server.cache_server_seed_realisation(&server, recipe_hash, out_hash, .Tree, signer_seed)
	testing.expect(t, real_ok)

	running, q_err := cache_server.cache_quic_start(&server, net.Endpoint{address = net.IP4_Loopback, port = 0}, quic_seed)
	if !testing.expect(t, q_err == "" && running != nil) {
		return
	}
	defer cache_server.cache_quic_stop(running)

	sock, s_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if !testing.expect(t, s_err == nil) {
		return
	}
	defer net.close(sock)

	udp := Tutorial_Test_Udp{socket = sock, remote = running.bound_endpoint, start_tick = time.tick_now()}
	crypto_table := cache_server.cache_quic_cryptography()
	generator: random.Generator
	seed: [random.SEED_SIZE]u8
	crypto.rand_bytes(seed[:])
	random.generator_seed(&generator, &seed, .Processor)

	client := new(recipes_core.Cache_Quic_Client)
	defer free(client)
	transport := recipes_core.Cache_Datagram_Transport{
		send      = tutorial_test_udp_send,
		recv      = tutorial_test_udp_recv,
		now_us    = tutorial_test_udp_now_us,
		user_data = &udp,
	}
	testing.expect(t, recipes_core.cache_quic_client_init(client, running.public_key, &crypto_table, &generator, transport))
	testing.expect_value(t, recipes_core.cache_quic_client_connect(client), recipes_core.Cache_Client_Error.None)
	defer recipes_core.cache_quic_client_close(client)

	get_real_req := object_cache.Cache_Request{kind = .Get_Realisation, recipe_hash = recipe_hash}
	real_resp, rec_err := recipes_core.cache_quic_client_exchange(client, &get_real_req)
	testing.expect_value(t, rec_err, recipes_core.Cache_Client_Error.None)
	testing.expect_value(t, real_resp.status, object_cache.Cache_Response_Status.Ok)
	testing.expect_value(t, real_resp.realisation.output_hash, out_hash)
	testing.expect_value(t, real_resp.realisation.output_kind, object_cache.Cache_Object_Kind.Tree)

	mem_store := new(pr.Memory_Private_Store)
	defer free(mem_store)
	recipes_state := new(recipes_core.Recipes_State)
	defer free(recipes_state)
	recipes_core.state_init(recipes_state, pr.memory_private_store_port(mem_store))

	fetched_size, fetch_ref := recipes_core.cache_quic_fetch_closure_to_store(client, recipes_state, out_hash, .Tree)
	testing.expect_value(t, fetch_ref, pr.Recipe_Refusal.None)
	testing.expect_value(t, fetched_size, u64(len(tree_bytes)))
	blob_name := pr.blob_object_name(blob_hash)
	blob_size, blob_sz_st := pr.private_store_size(&recipes_state.store, pr.private_object_name_text(&blob_name))
	testing.expect_value(t, blob_sz_st, pr.Private_Store_Status.Ok)
	testing.expect_value(t, blob_size, u64(len(blob)))
}

// When SQLITE_SOURCE is provided by the development shell, tutorial_build_sqlite_module
// compiles a valid freestanding sqlite.module and tutorial_build_initial_main_db
// executes it in memory to produce a valid 4 KiB-page SQLite 3 database file.
@(test)
tutorial_sqlite_build_and_initial_main_db_seed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if os.get_env("SQLITE_SOURCE", context.temp_allocator) == "" {
		return
	}
	temp_base, _ := os.temp_dir(context.temp_allocator)
	if temp_base == "" {
		temp_base = "/tmp"
	}
	work := fmt.aprintf("%s/modus_tutorial_sqlite_test_%d", strings.trim_right(temp_base, "/"), os.get_pid())
	_ = os.remove_all(work)
	defer {
		_ = os.remove_all(work)
		delete(work)
	}
	testing.expect(t, os.make_directory_all(work) == nil)

	sqlite_bytes, built := tutorial_build_sqlite_module(work)
	if !testing.expect(t, built, "tutorial_build_sqlite_module produces a valid sqlite.module") {
		return
	}
	defer delete(sqlite_bytes)
	testing.expect_value(t, module.validate(sqlite_bytes), module.Error.None)

	// Invalid module bytes are refused cleanly by tutorial_build_initial_main_db.
	_, bad_db := tutorial_build_initial_main_db(transmute([]u8)string("not-a-module"))
	testing.expect(t, !bad_db, "corrupt module bytes are refused")

	main_db, seeded := tutorial_build_initial_main_db(sqlite_bytes)
	if !testing.expect(t, seeded, "tutorial_build_initial_main_db seeds main.db via sqlite.module") {
		return
	}
	defer delete(main_db)
	testing.expect(t, len(main_db) >= 8192 && len(main_db) % 4096 == 0, "seeded main.db is aligned to 4 KiB pages")
	testing.expect_value(t, string(main_db[:16]), "SQLite format 3\x00")
}
