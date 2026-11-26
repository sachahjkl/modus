// Preparation and teardown of the deterministic data disk and ephemeral local
// signed QUIC object cache for `modustool film course_building`
// (src/md/infrastructure/course_building_film.md; docs/COURSE_BUILDING.md).
//
// Writes a lightweight STORAGE7 data disk containing the `"calc"` project
// (`main.c` and `project.lex`), starts an empty ephemeral host QUIC cache
// server on 127.0.0.1:0 authorizing a deterministic test-only Ed25519
// publisher key (so Lesson 5 publishes live objects and a signed realisation
// directly from inside modus over QUIC), and expands scenario placeholders.
package machine

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "modus:contract/object_cache"
import "modus:cryptography/ed25519"
import "modustool:build"
import "modustool:cache_server"
import "modustool:foundation"

// Multi-line C source of the `"calc"` project opened live in `edit` during
// Lesson 3 and compiled natively inside modus in Lessons 4-6 (returns 84).
COURSE_BUILDING_CALC_MAIN_C :: `long double_sum(long a, long b) {
  return (a + b) * 2;
}

long main(void) {
  return double_sum(19, 23);
}
`

// Declarative Lex project file shown live in `edit("calc", "project.lex")`
// during Lesson 3 and evaluated in Lessons 4-6.
COURSE_BUILDING_CALC_PROJECT_LEX :: `let
  default_build = {
    source    = here(),
    path      = "main.c",
    compiler  = catalog.modules.c_compiler,
    assembler = catalog.modules.assemble,
    host      = catalog.modules.host,
    heap      = 2 MiB,
  },
  release_build = default_build with { heap = 4 MiB },
in
  project {
    source = here(),
    inputs = { modus = catalog },
    outputs = {
      default = recipe(catalog.modules.c_builder, release_build),
      source  = here(),
    },
    console = {
      modules = [catalog.modules.c_builder],
      stores  = [store("calc", .read, .write)],
    },
  }
`

// Deterministic test-only Ed25519 seeds for the ephemeral local cache server
// (bound to 127.0.0.1:0, destroyed on teardown).
@(private = "file")
course_building_ed25519_seed :: proc(base: u8) -> (seed: [32]u8) {
	for i in 0 ..< 32 {
		seed[i] = base + u8(i * 17 + 11)
	}
	return seed
}

Course_Building_Bindings :: struct {
	cache_server_key:     string,
	cache_signer_key:     string,
	cache_publisher_seed: string, // Used ONLY off-camera before clear() and Film_Start.
	calc_here:            string,
	calc_recipe:          string,
}

Course_Building_Fixture :: struct {
	work_dir:           string,
	data_disk_path:     string,
	cache_server_state: cache_server.Cache_Server,
	cache_server_open:  bool,
	cache_quic:         ^cache_server.Cache_Quic_Running,
	cache_endpoint:     net.Endpoint,
	bindings:           Course_Building_Bindings,
}

@(private = "file")
course_building_film_expand_text :: proc(text: string, bindings: Course_Building_Bindings, allocator := context.allocator) -> (expanded: string, ok: bool) {
	if !strings.contains_rune(text, '{') {
		return strings.clone(text, allocator), true
	}
	pairs := [?][2]string{
		{"{cache_server_key}", bindings.cache_server_key},
		{"{cache_signer_key}", bindings.cache_signer_key},
		{"{cache_publisher_seed}", bindings.cache_publisher_seed},
		{"{calc_here}", bindings.calc_here},
		{"{calc_recipe}", bindings.calc_recipe},
	}
	current := strings.clone(text, context.temp_allocator)
	for pair in pairs {
		if strings.contains(current, pair[0]) {
			if len(pair[1]) == 0 {
				return "", false
			}
			current, _ = strings.replace_all(current, pair[0], pair[1], context.temp_allocator)
		}
	}
	for pair in pairs {
		if strings.contains(current, pair[0]) {
			return "", false
		}
	}
	return strings.clone(current, allocator), true
}

// course_building_film_expand_steps clones template and expands all placeholders
// for `modustool film course_building`. Refuses empty required bindings.
course_building_film_expand_steps :: proc(template: []Step, bindings: Course_Building_Bindings, allocator := context.allocator) -> (steps: []Step, ok: bool) {
	out := make([]Step, len(template), allocator)
	defer if !ok {
		course_building_film_steps_free(out, allocator)
	}
	for step, index in template {
		copied := step
		copied.text = course_building_film_expand_text(step.text, bindings, allocator) or_return
		copied.expected = course_building_film_expand_text(step.expected, bindings, allocator) or_return
		copied.fails_on = course_building_film_expand_text(step.fails_on, bindings, allocator) or_return
		out[index] = copied
	}
	return out, true
}

course_building_film_steps_free :: proc(steps: []Step, allocator := context.allocator) {
	for step in steps {
		delete(step.text, allocator)
		delete(step.expected, allocator)
		delete(step.fails_on, allocator)
	}
	delete(steps, allocator)
}

// course_building_film_prepare writes the STORAGE7 data disk with the `"calc"`
// project and starts an empty ephemeral QUIC object cache on 127.0.0.1:0
// authorizing the deterministic test-only publisher key.
course_building_film_prepare :: proc() -> (fixture: ^Course_Building_Fixture, ok: bool) {
	work_dir := fmt.aprintf("%s/course_building_film_%d", foundation.BUILD_FOLDER, os.get_pid())
	if !foundation.reset_folder(work_dir) {
		delete(work_dir)
		return nil, false
	}
	fixture = new(Course_Building_Fixture)
	fixture.work_dir = work_dir
	defer if !ok {
		course_building_film_teardown(fixture)
		fixture = nil
	}

	catalog_bytes, catalog_ok := foundation.read_file(build.CATALOG_FILE)
	if !catalog_ok {
		fmt.eprintln("modustool: course_building: cannot read catalog.lex")
		return nil, false
	}
	catalog_lex := string(catalog_bytes)

	calc_objects := [?]build.Module_File{
		{name = "main.c", bytes = transmute([]u8)string(COURSE_BUILDING_CALC_MAIN_C)},
		{name = "project.lex", bytes = transmute([]u8)string(COURSE_BUILDING_CALC_PROJECT_LEX)},
	}
	calc_here := tutorial_tree_hash_of(calc_objects[:], nil) or_return
	calc_recipe := tutorial_evaluate_project_recipe(COURSE_BUILDING_CALC_PROJECT_LEX, calc_here, catalog_lex) or_return

	// Write the lightweight STORAGE7 data disk holding only the `"calc"` source store.
	fixture.data_disk_path = fmt.aprintf("%s/course_building_data_disk.img", work_dir)
	stores := [?]build.Data_Disk_Store{
		{name = "calc", limit = 2048, objects = calc_objects[:]},
	}
	if !build.data_disk_write_stores(fixture.data_disk_path, stores[:], build.DATA_DISK_SIZE) {
		fmt.eprintln("modustool: course_building: cannot write STORAGE7 data disk")
		return nil, false
	}

	// Start an empty ephemeral QUIC cache authorizing the deterministic test-only publisher key.
	publisher_seed := course_building_ed25519_seed(0x52)
	quic_seed := course_building_ed25519_seed(0x79)
	publisher_priv: ed25519.Private_Key
	defer ed25519.private_key_clear(&publisher_priv)
	if !ed25519.private_key_set_bytes(&publisher_priv, publisher_seed[:]) {
		return nil, false
	}
	publisher_pub: [object_cache.PUBLIC_KEY_SIZE]u8
	ed25519.private_key_public_bytes(&publisher_priv, publisher_pub[:])

	cache_dir := foundation.join(work_dir, "/cache")
	server, opened := cache_server.cache_server_open(cache_dir, [][32]u8{publisher_pub})
	if !opened {
		fmt.eprintln("modustool: course_building: cannot open local cache server")
		return nil, false
	}
	fixture.cache_server_state = server
	fixture.cache_server_open = true

	running, quic_err := cache_server.cache_quic_start(&fixture.cache_server_state, net.Endpoint{address = net.IP4_Loopback, port = 0}, quic_seed)
	if quic_err != "" || running == nil {
		fmt.eprintfln("modustool: course_building: cannot start local QUIC cache: %s", quic_err)
		return nil, false
	}
	fixture.cache_quic = running
	fixture.cache_endpoint = running.bound_endpoint

	fixture.bindings = {
		cache_server_key     = tutorial_hex_of(running.public_key),
		cache_signer_key     = tutorial_hex_of(publisher_pub),
		cache_publisher_seed = tutorial_hex_of(publisher_seed),
		calc_here            = tutorial_hex_of(calc_here),
		calc_recipe          = tutorial_hex_of(calc_recipe),
	}
	return fixture, true
}

course_building_film_teardown :: proc(fixture: ^Course_Building_Fixture) {
	if fixture == nil {
		return
	}
	if fixture.cache_quic != nil {
		cache_server.cache_quic_stop(fixture.cache_quic)
		fixture.cache_quic = nil
	}
	if fixture.cache_server_open {
		cache_server.cache_server_destroy(&fixture.cache_server_state)
		fixture.cache_server_open = false
	}
	delete(fixture.bindings.cache_server_key)
	delete(fixture.bindings.cache_signer_key)
	delete(fixture.bindings.cache_publisher_seed)
	delete(fixture.bindings.calc_here)
	delete(fixture.bindings.calc_recipe)
	delete(fixture.data_disk_path)
	if fixture.work_dir != "" {
		_ = os.remove_all(fixture.work_dir)
		delete(fixture.work_dir)
	}
	free(fixture)
}
