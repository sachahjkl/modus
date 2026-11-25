// Two-machine build, publish, and cache-only pull scenario for
// `src/outside/projects/collatz` (src/md/features/application_projects.md).
//
// Starts one ephemeral host QUIC object cache on 127.0.0.1:0 authorizing a
// deterministic test-only Ed25519 publisher key, then runs two machines on
// separate fresh STORAGE7 data disks seeded only with `collatz` sources:
//
//   1. Builder machine: builds `collatz` with `recipes.build_project("build_only")`,
//      delivers and executes `collatz.steps(27)` (111) and `collatz.steps(0)` (-1),
//      and publishes the signed realisation and closure over QUIC via `recipes.publish`.
//   2. Consumer machine: starts on a separate empty data disk with no local
//      build store and no publisher key, trusts the signer key, pulls the output
//      via `recipes.build_project("cache_only")`, verifies `origin: remote_cache`
//      and `signer` provenance, delivers the module, and runs `collatz.steps(27)` (111).
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

COLLATZ_PROJECT_DIR :: "src/outside/projects/collatz"
// Plan value: data disk store block limit for the collatz source tree, matching
// the project store limit used by tutorial and course setups.
COLLATZ_PROJECT_STORE_BLOCKS :: 2048

TEST_OUTPUT_COLLATZ_BUILDER :: foundation.BUILD_FOLDER + "/test_output_collatz_builder.txt"
TEST_OUTPUT_COLLATZ_CONSUMER :: foundation.BUILD_FOLDER + "/test_output_collatz_consumer.txt"

// Deterministic test-only Ed25519 seeds for the ephemeral local QUIC cache
// (bound to 127.0.0.1:0 and destroyed on teardown).
@(private = "file")
collatz_cache_ed25519_seed :: proc(base: u8) -> (seed: [32]u8) {
	for i in 0 ..< 32 {
		seed[i] = base + u8(i * 19 + 5)
	}
	return seed
}

Collatz_Cache_Bindings :: struct {
	cache_server_key:     string,
	cache_signer_key:     string,
	cache_publisher_seed: string,
	collatz_here:         string,
	collatz_recipe:       string,
}

Collatz_Cache_Fixture :: struct {
	work_dir:           string,
	builder_disk_path:  string,
	consumer_disk_path: string,
	cache_server_state: cache_server.Cache_Server,
	cache_server_open:  bool,
	cache_quic:         ^cache_server.Cache_Quic_Running,
	cache_endpoint:     net.Endpoint,
	bindings:           Collatz_Cache_Bindings,
}

@(rodata)
scenario_collatz_builder := [?]Step {
	{kind = .Wait, text = "storage: ok, generation ", any_order = true},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "root: settings stopped: itself, done"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"recipes\")"},
	{kind = .Wait, text = "[console]   module     recipes"},
	{kind = .Type, text = "recipes.configure_cache(\"{cache_server_key}\", \"{cache_signer_key}\")"},
	{kind = .Wait, text = "[console] 1"},
	{kind = .Type, text = "recipes.configure_publisher(\"{cache_publisher_seed}\")"},
	{kind = .Wait, text = "[console] {cache_signer_key}"},
	{kind = .Type, text = "tree = \"collatz\" |> recipes.ingest_tree"},
	{kind = .Type, text = "tree"},
	{kind = .Wait, text = "[console] {collatz_here}"},
	{kind = .Type, text = "pkg = \"collatz\" |> recipes.build_project(\"build_only\")"},
	{kind = .Wait, text = "recipes: build completed with outcome "},
	{kind = .Type, text = "pkg"},
	{kind = .Wait, text = "[console]   outcome  built"},
	{kind = .Wait, text = "[console]   recipe   {collatz_recipe}"},
	{kind = .Type, text = "pkg.recipe |> recipes.provenance"},
	{kind = .Wait, text = "[console]   origin  local_build"},
	{kind = .Type, text = "mod = pkg.output |> recipes.deliver_module(\"module\", \"collatz\")"},
	{kind = .Wait, text = "module_files: put collatz: "},
	{kind = .Type, text = "f = buffer(16)"},
	{kind = .Type, text = "n = module_files.read(\"collatz\", f)"},
	{kind = .Type, text = "collatz = isolate_memory(\"collatz\", f, n)"},
	{kind = .Wait, text = "[collatz] host: ready, 1 exports", any_order = true},
	{kind = .Wait, text = "console: collatz is a module from memory: "},
	{kind = .Type, text = "collatz.steps(0)"},
	{kind = .Wait, text = "[console] -1"},
	{kind = .Type, text = "collatz.steps(27)"},
	{kind = .Wait, text = "[console] 111"},
	{kind = .Type, text = "unload(collatz)"},
	{kind = .Wait, text = "[console]   module    collatz"},
	{kind = .Type, text = "release(f)"},
	{kind = .Type, text = "pub = pkg.recipe |> recipes.publish"},
	{kind = .Wait, text = "recipes: published recipe {collatz_recipe}"},
	{kind = .Type, text = "pub"},
	{kind = .Wait, text = "[console]   bytes_uploaded"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

@(rodata)
scenario_collatz_consumer := [?]Step {
	{kind = .Wait, text = "storage: ok, generation ", any_order = true},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "root: settings stopped: itself, done"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"recipes\")"},
	{kind = .Wait, text = "[console]   module     recipes"},
	{kind = .Type, text = "recipes.configure_cache(\"{cache_server_key}\", \"{cache_signer_key}\")"},
	{kind = .Wait, text = "[console] 1"},
	{kind = .Type, text = "pkg = \"collatz\" |> recipes.build_project(\"cache_only\")"},
	{kind = .Wait, text = "recipes: build completed with outcome "},
	{kind = .Type, text = "pkg"},
	{kind = .Wait, text = "[console]   outcome  cached"},
	{kind = .Wait, text = "[console]   recipe   {collatz_recipe}"},
	{kind = .Type, text = "pkg.recipe |> recipes.provenance"},
	{kind = .Wait, text = "[console]   origin  remote_cache"},
	{kind = .Wait, text = "[console]   signer  {cache_signer_key}"},
	{kind = .Type, text = "mod = pkg.output |> recipes.deliver_module(\"module\", \"collatz\")"},
	{kind = .Wait, text = "module_files: put collatz: "},
	{kind = .Type, text = "f = buffer(16)"},
	{kind = .Type, text = "n = module_files.read(\"collatz\", f)"},
	{kind = .Type, text = "collatz = isolate_memory(\"collatz\", f, n)"},
	{kind = .Wait, text = "[collatz] host: ready, 1 exports", any_order = true},
	{kind = .Wait, text = "console: collatz is a module from memory: "},
	{kind = .Type, text = "collatz.steps(0)"},
	{kind = .Wait, text = "[console] -1"},
	{kind = .Type, text = "collatz.steps(27)"},
	{kind = .Wait, text = "[console] 111"},
	{kind = .Type, text = "unload(collatz)"},
	{kind = .Wait, text = "[console]   module    collatz"},
	{kind = .Type, text = "release(f)"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

@(private = "file")
collatz_cache_expand_text :: proc(text: string, bindings: Collatz_Cache_Bindings, allocator := context.allocator) -> (expanded: string, ok: bool) {
	if !strings.contains_rune(text, '{') {
		return strings.clone(text, allocator), true
	}
	pairs := [?][2]string{
		{"{cache_server_key}", bindings.cache_server_key},
		{"{cache_signer_key}", bindings.cache_signer_key},
		{"{cache_publisher_seed}", bindings.cache_publisher_seed},
		{"{collatz_here}", bindings.collatz_here},
		{"{collatz_recipe}", bindings.collatz_recipe},
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

// collatz_cache_expand_steps clones template and expands all collatz cache
// scenario placeholders. Refuses empty required bindings.
collatz_cache_expand_steps :: proc(template: []Step, bindings: Collatz_Cache_Bindings, allocator := context.allocator) -> (steps: []Step, ok: bool) {
	if len(template) == 0 {
		return nil, true
	}
	out := make([]Step, len(template), allocator)
	defer if !ok {
		collatz_cache_steps_free(out, allocator)
	}
	for step, index in template {
		copied := step
		copied.text = collatz_cache_expand_text(step.text, bindings, allocator) or_return
		copied.expected = collatz_cache_expand_text(step.expected, bindings, allocator) or_return
		copied.fails_on = collatz_cache_expand_text(step.fails_on, bindings, allocator) or_return
		out[index] = copied
	}
	return out, true
}

collatz_cache_steps_free :: proc(steps: []Step, allocator := context.allocator) {
	for step in steps {
		delete(step.text, allocator)
		delete(step.expected, allocator)
		delete(step.fails_on, allocator)
	}
	delete(steps, allocator)
}

// collatz_cache_prepare reads src/outside/projects/collatz, writes two fresh
// STORAGE7 data disks (builder and consumer) seeded only with the collatz
// source store, and starts one empty ephemeral QUIC object cache on 127.0.0.1:0
// authorizing a deterministic test-only Ed25519 publisher key.
collatz_cache_prepare :: proc() -> (fixture: ^Collatz_Cache_Fixture, ok: bool) {
	work_dir := fmt.aprintf("%s/collatz_cache_%d", foundation.BUILD_FOLDER, os.get_pid())
	if !foundation.reset_folder(work_dir) {
		delete(work_dir)
		return nil, false
	}
	fixture = new(Collatz_Cache_Fixture)
	fixture.work_dir = work_dir
	defer if !ok {
		collatz_cache_teardown(fixture)
		fixture = nil
	}

	catalog_bytes, catalog_ok := foundation.read_file(build.CATALOG_FILE)
	if !catalog_ok {
		fmt.eprintln("modustool: collatz_cache: cannot read catalog.lex")
		return nil, false
	}
	catalog_lex := string(catalog_bytes)

	collatz_objs, collatz_trees, collatz_here := tutorial_read_project_tree(COLLATZ_PROJECT_DIR) or_return
	defer tutorial_free_project_tree(collatz_objs, collatz_trees)

	project_lex_bytes, lex_err := os.read_entire_file(COLLATZ_PROJECT_DIR + "/project.lex", context.temp_allocator)
	if lex_err != nil {
		fmt.eprintfln("modustool: collatz_cache: cannot read %s/project.lex: %v", COLLATZ_PROJECT_DIR, lex_err)
		return nil, false
	}
	collatz_recipe := tutorial_evaluate_project_recipe(string(project_lex_bytes), collatz_here, catalog_lex) or_return

	stores := [?]build.Data_Disk_Store{
		{name = "collatz", limit = COLLATZ_PROJECT_STORE_BLOCKS, objects = collatz_objs, trees = collatz_trees},
	}
	fixture.builder_disk_path = fmt.aprintf("%s/collatz_builder_disk.img", work_dir)
	if !build.data_disk_write_stores(fixture.builder_disk_path, stores[:], build.DATA_DISK_SIZE) {
		fmt.eprintln("modustool: collatz_cache: cannot write builder STORAGE7 data disk")
		return nil, false
	}
	fixture.consumer_disk_path = fmt.aprintf("%s/collatz_consumer_disk.img", work_dir)
	if !build.data_disk_write_stores(fixture.consumer_disk_path, stores[:], build.DATA_DISK_SIZE) {
		fmt.eprintln("modustool: collatz_cache: cannot write consumer STORAGE7 data disk")
		return nil, false
	}

	publisher_seed := collatz_cache_ed25519_seed(0x61)
	quic_seed := collatz_cache_ed25519_seed(0x83)
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
		fmt.eprintln("modustool: collatz_cache: cannot open local cache server")
		return nil, false
	}
	fixture.cache_server_state = server
	fixture.cache_server_open = true

	running, quic_err := cache_server.cache_quic_start(&fixture.cache_server_state, net.Endpoint{address = net.IP4_Loopback, port = 0}, quic_seed)
	if quic_err != "" || running == nil {
		fmt.eprintfln("modustool: collatz_cache: cannot start local QUIC cache: %s", quic_err)
		return nil, false
	}
	fixture.cache_quic = running
	fixture.cache_endpoint = running.bound_endpoint

	fixture.bindings = {
		cache_server_key     = tutorial_hex_of(running.public_key),
		cache_signer_key     = tutorial_hex_of(publisher_pub),
		cache_publisher_seed = tutorial_hex_of(publisher_seed),
		collatz_here         = tutorial_hex_of(collatz_here),
		collatz_recipe       = tutorial_hex_of(collatz_recipe),
	}
	return fixture, true
}

collatz_cache_teardown :: proc(fixture: ^Collatz_Cache_Fixture) {
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
	delete(fixture.bindings.collatz_here)
	delete(fixture.bindings.collatz_recipe)
	delete(fixture.builder_disk_path)
	delete(fixture.consumer_disk_path)
	if fixture.work_dir != "" {
		_ = os.remove_all(fixture.work_dir)
		delete(fixture.work_dir)
	}
	free(fixture)
}

// collatz_cache_run runs the two-machine collatz build, QUIC publish, and
// cache-only pull verification against boot_volume.
collatz_cache_run :: proc(part: ^Test_Part_Run, boot_volume: string) -> bool {
	if part == nil || boot_volume == "" {
		fmt.eprintln("modustool: collatz_cache: part and boot volume are required")
		return false
	}
	fixture, prepared := collatz_cache_prepare()
	if !prepared {
		return false
	}
	defer collatz_cache_teardown(fixture)

	builder_steps, builder_ok := collatz_cache_expand_steps(scenario_collatz_builder[:], fixture.bindings)
	if !builder_ok {
		fmt.eprintln("modustool: collatz_cache: cannot expand builder scenario placeholders")
		return false
	}
	defer collatz_cache_steps_free(builder_steps)

	consumer_steps, consumer_ok := collatz_cache_expand_steps(scenario_collatz_consumer[:], fixture.bindings)
	if !consumer_ok {
		fmt.eprintln("modustool: collatz_cache: cannot expand consumer scenario placeholders")
		return false
	}
	defer collatz_cache_steps_free(consumer_steps)

	machine_test(part, builder_steps, {
		volume         = boot_volume,
		output         = TEST_OUTPUT_COLLATZ_BUILDER,
		exit_status    = build.MACHINE_STOP_OK,
		data_disk      = fixture.builder_disk_path,
		cache_endpoint = fixture.cache_endpoint,
	}) or_return

	return machine_test(part, consumer_steps, {
		volume         = boot_volume,
		output         = TEST_OUTPUT_COLLATZ_CONSUMER,
		exit_status    = build.MACHINE_STOP_OK,
		data_disk      = fixture.consumer_disk_path,
		cache_endpoint = fixture.cache_endpoint,
	})
}
