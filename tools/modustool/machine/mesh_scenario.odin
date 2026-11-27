// Live two-machine QEMU mesh test over QUIC and NAT relay
// (src/md/features/several_machines.md).
//
// Boots two concurrent modus QEMU instances (Machine A = switch node 0 at
// 10.0.2.2:42100, Machine B = switch node 1 at 10.0.2.2:42101) connected
// through Peer_Mesh_Switch alongside a live Host_Mesh_Relay QUIC server
// (node 2 at 10.0.2.2:42102). Exercises every live mesh flow end to end:
//
// 1. CPace pairing over QUIC (wrong-code refusal first, then real pairing);
// 2. Multi-chunk (>16 KiB) object-by-hash exchange with BLAKE3 verification;
// 3. Remote role call dispatch (`Role.Recipes`) hitting Machine A's local
//    service through root Connect, plus handle-bearing role refusal;
// 4. Multi-page store exchange with three-way fast-forward merge, concurrent
//    conflict creation, and single resolution converging both machines;
// 5. NAT isolation blocking direct A <-> B packets and end-to-end
//    ChaCha20-Poly1305 sealed Relay_Deposit / Relay_Collect over QUIC.
package machine

import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "modus:contract/machine_mesh"
import "modus:contract/machine_wire"
import module "modus:contract/module"
import "modus:contract/remote"
import "modus:contract/role_contract"
import "modustool:build"
import "modustool:foundation"

TEST_OUTPUT_MESH_A :: foundation.BUILD_FOLDER + "/test_output_mesh_a.txt"
TEST_OUTPUT_MESH_B :: foundation.BUILD_FOLDER + "/test_output_mesh_b.txt"
TEST_DISK_MESH_A :: foundation.BUILD_FOLDER + "/test_data_disk_mesh_a.img"
TEST_DISK_MESH_B :: foundation.BUILD_FOLDER + "/test_data_disk_mesh_b.img"

// Plan value: bounded polling turns for an asynchronous QUIC handshake or
// mesh request inside console, capped by foundation.HANG_BOUND.
MESH_POLL_STEP_SLEEP :: 25 * time.Millisecond

@(private = "file")
Mesh_Live_Machine :: struct {
	peer:          Peer,
	machine:       Machine,
	monitor_read:  ^os.File,
	monitor_write: ^os.File,
	output:        string,
	data_disk:     string,
	started:       bool,
}

@(private = "file")
mesh_live_machine_start :: proc(
	live: ^Mesh_Live_Machine,
	part: ^Test_Part_Run,
	volume: string,
	output: string,
	data_disk: string,
	sw: ^Peer_Mesh_Switch,
	node_id: int,
) -> bool {
	live^ = {output = output, data_disk = data_disk}
	if !disk_prepare(data_disk, build.DATA_DISK_SIZE, true) {
		return false
	}
	if !peer_start(&live.peer, relay_machine_port = remote.LISTEN_PORT, mesh_switch = sw, mesh_node_id = node_id) {
		return false
	}
	clock := machine_clock_of(time.time_to_unix(time.now()))
	command, ok := machine_command(
		volume, output, data_disk, &live.peer, {}, {}, .Usual,
		false, false, .None, false, false, clock.argument, "", "",
		false, false, false, false, false, false, "", "", .None, false,
		"", false, "", "", false, 0,
	)
	if !ok {
		peer_stop(&live.peer)
		return false
	}
	_ = os.remove(output)
	_ = os.remove(qmp_socket_of(output))
	pipe_err: os.Error
	live.monitor_read, live.monitor_write, pipe_err = os.pipe()
	if pipe_err != nil {
		fmt.eprintfln("modustool: mesh test: cannot create pipe: %v", pipe_err)
		peer_stop(&live.peer)
		return false
	}
	host_process, start_err := os.process_start({command = command, stdin = live.monitor_read, stderr = os.stderr})
	peer_machine_socket_lent_close(&live.peer)
	if start_err != nil {
		fmt.eprintfln("modustool: mesh test: cannot start QEMU for %s: %v", output, start_err)
		os.close(live.monitor_write)
		os.close(live.monitor_read)
		peer_stop(&live.peer)
		return false
	}
	socket_made, _ := qmp_socket_wait(host_process, qmp_socket_of(output))
	qmp: Qmp
	if !socket_made || !qmp_open(&qmp, qmp_socket_of(output)) {
		fmt.eprintfln("modustool: mesh test: QMP did not open for %s", output)
		_ = os.process_kill(host_process)
		_, _ = os.process_wait(host_process)
		os.close(live.monitor_write)
		os.close(live.monitor_read)
		peer_stop(&live.peer)
		return false
	}
	live.machine = Machine {
		qmp                  = qmp,
		part                 = part,
		started_at           = time.tick_now(),
		started_unix         = time.time_to_unix(time.now()),
		clock_offset_seconds = clock.offset_seconds,
		host_process         = host_process,
		monitor              = live.monitor_write,
		output               = output,
		call_socket          = live.peer.call_socket,
		peer                 = &live.peer,
	}
	live.started = true
	return true
}

@(private = "file")
mesh_live_machine_stop :: proc(live: ^Mesh_Live_Machine, passed: bool) -> bool {
	if !live.started {
		return passed
	}
	ok := passed
	if ok {
		if line, found := floor_passed_line(log_read(&live.machine)); found {
			fmt.eprintfln("modustool: test failed: floor passed on %s: %s", live.output, line)
			ok = false
		}
	}
	state: os.Process_State
	if ok {
		wait_err: os.Error
		state, wait_err = os.process_wait(live.machine.host_process, foundation.HANG_BOUND)
		if wait_err != nil || !state.exited || state.exit_code != build.MACHINE_STOP_OK {
			fmt.eprintfln("modustool: test failed: %s did not exit cleanly (code %d)", live.output, state.exit_code)
			ok = false
		}
	}
	if !state.exited {
		_ = os.process_kill(live.machine.host_process)
		_, _ = os.process_wait(live.machine.host_process)
	}
	if line := common_failure_line(log_read(&live.machine), 0); line != "" {
		fmt.eprintfln("modustool: test failed: %s printed %q", live.output, line)
		ok = false
	}
	os.close(live.monitor_write)
	os.close(live.monitor_read)
	qmp_close(&live.machine.qmp)
	log_watch_close(&live.machine.log_watch)
	peer_stop(&live.peer)
	if ok {
		ok = peer_check(&live.peer)
	}
	_ = os.remove(machine_file(live.output, SCRATCH_DISK_SUFFIX))
	_ = os.remove(machine_file(live.output, SCREEN_DUMP_SUFFIX))
	for suffix in ([]string{FIRMWARE_VARIABLES_SUFFIX, FIRMWARE_TPM_VARIABLES_SUFFIX, FIRMWARE_FULL_VARIABLES_SUFFIX}) {
		_ = os.remove(machine_file(live.output, suffix))
	}
	live.started = false
	return ok
}

// mesh_extract_after scans the machine log after offset for prefix and returns
// the next exact_len characters (trimmed of quotes if quoted), heap-allocated
// so later scenario_run temp_allocator resets cannot clobber it.
@(private = "file")
mesh_extract_after :: proc(machine: ^Machine, offset: int, prefix: string, exact_len: int) -> (value: string, ok: bool) {
	deadline := time.tick_now()
	for time.tick_since(deadline) < foundation.HANG_BOUND {
		log := log_read(machine)
		if len(log) > offset {
			hay := log[offset:]
			if idx := strings.last_index(hay, prefix); idx >= 0 {
				rest := hay[idx + len(prefix):]
				rest = strings.trim_left(rest, "\" ")
				if len(rest) >= exact_len {
					return strings.clone(rest[:exact_len]), true
				}
			}
		}
		time.sleep(MESH_POLL_STEP_SLEEP)
	}
	return "", false
}

// mesh_wait_console_line waits until a complete non-echo "[console] ...\n"
// result line appears AFTER a "[console] > " command echo in log[offset:],
// and returns the trimmed payload on the heap. Requiring the echo first
// prevents trailing lines of a multi-line record from an earlier command from
// being mistaken for this command's result.
@(private = "file")
mesh_wait_console_line :: proc(machine: ^Machine, offset: int) -> (line_out: string, ok: bool) {
	deadline := time.tick_now()
	for time.tick_since(deadline) < foundation.HANG_BOUND {
		log := log_read(machine)
		if len(log) > offset {
			tail := log[offset:]
			saw_echo := false
			last_result := ""
			pos := 0
			for pos < len(tail) {
				nl := strings.index_byte(tail[pos:], '\n')
				if nl < 0 {
					break
				}
				line := strings.trim_right(tail[pos:pos + nl], "\r")
				pos += nl + 1
				if strings.has_prefix(line, "[console] > ") {
					saw_echo = true
					last_result = ""
				} else if saw_echo && strings.has_prefix(line, "[console] ") {
					trimmed := strings.trim_space(line[len("[console] "):])
					if len(trimmed) > 0 {
						last_result = trimmed
					}
				}
			}
			if len(last_result) > 0 {
				return strings.clone(last_result), true
			}
		}
		time.sleep(MESH_POLL_STEP_SLEEP)
	}
	return "", false
}

// mesh_console_command types one console expression and waits for its output
// prefix to appear in the log past the pre-command log offset. When expected
// is "[console] ", waits for a complete non-echo result line instead of
// matching the "[console] > ..." command echo.
@(private = "file")
mesh_console_command :: proc(machine: ^Machine, expr: string, expected: string) -> bool {
	expr_copy := strings.clone(expr)
	defer delete(expr_copy)
	if expected == "[console] " {
		before := len(log_read(machine))
		if !scenario_run(machine, {{kind = .Type, text = expr_copy}}) {
			return false
		}
		line, ok := mesh_wait_console_line(machine, before)
		if !ok {
			fmt.eprintfln("modustool: test failed: console produced no result line for %q", expr_copy)
			return false
		}
		delete(line)
		return true
	}
	expected_copy := strings.clone(expected)
	defer delete(expected_copy)
	steps := [?]Step {
		{kind = .Type, text = expr_copy},
		{kind = .Wait, text = expected_copy},
	}
	return scenario_run(machine, steps[:])
}

// mesh_wait_link_up polls remote.mesh_link_state until the outbound QUIC
// handshake reaches Mesh_Link_State.Up (2), bounded by foundation.HANG_BOUND.
@(private = "file")
mesh_wait_link_up :: proc(machine: ^Machine, peer_key_hex: string) -> bool {
	started := time.tick_now()
	expr := fmt.aprintf("remote.mesh_link_state(\"%s\")", peer_key_hex)
	defer delete(expr)
	for time.tick_since(started) < foundation.HANG_BOUND {
		before := len(log_read(machine))
		if !scenario_run(machine, {{kind = .Type, text = expr}}) {
			return false
		}
		line, line_ok := mesh_wait_console_line(machine, before)
		if line_ok {
			defer delete(line)
			if line == "2" {
				return true
			}
		}
		time.sleep(MESH_POLL_STEP_SLEEP)
	}
	fmt.eprintfln("modustool: test failed: outbound QUIC link to %s did not reach Up", peer_key_hex)
	return false
}

// mesh_wait_request_ok polls remote.mesh_request_poll until the request ends
// and checks that the returned line contains expected_result.
@(private = "file")
mesh_wait_request_ok :: proc(machine: ^Machine, peer_key_hex: string, req_id: string, expected_result: string) -> bool {
	started := time.tick_now()
	expr := fmt.aprintf("remote.mesh_request_poll(\"%s\", %s)", peer_key_hex, req_id)
	defer delete(expr)
	for time.tick_since(started) < foundation.HANG_BOUND {
		before := len(log_read(machine))
		if !scenario_run(machine, {{kind = .Type, text = expr}}) {
			return false
		}
		line, line_ok := mesh_wait_console_line(machine, before)
		if line_ok {
			defer delete(line)
			if strings.contains(line, expected_result) {
				return true
			}
			if strings.contains(line, "error:") {
				fmt.eprintfln("modustool: test failed: mesh request %s failed: %s", req_id, line)
				return false
			}
		}
		time.sleep(MESH_POLL_STEP_SLEEP)
	}
	fmt.eprintfln("modustool: test failed: mesh request %s timed out waiting for %q", req_id, expected_result)
	return false
}

// mesh_extract_int_line reads the integer result printed by the last console
// command after offset.
@(private = "file")
mesh_extract_int_line :: proc(machine: ^Machine, offset: int) -> (num_text: string, ok: bool) {
	return mesh_wait_console_line(machine, offset)
}

@(private = "file")
mesh_hex_to_key :: proc(hex_text: string) -> (key: [32]u8, ok: bool) {
	bytes, decoded := hex.decode(transmute([]u8)hex_text, context.temp_allocator)
	if !decoded || len(bytes) != 32 {
		return {}, false
	}
	copy(key[:], bytes)
	return key, true
}

@(private = "file")
mesh_hex_to_token :: proc(hex_text: string) -> (token: machine_wire.Routing_Token, ok: bool) {
	bytes, decoded := hex.decode(transmute([]u8)hex_text, context.temp_allocator)
	if !decoded || len(bytes) != machine_wire.ROUTING_TOKEN_SIZE {
		return {}, false
	}
	copy(token[:], bytes)
	return token, true
}

// mesh_tests_run boots two live modus QEMU machines on Peer_Mesh_Switch with
// Host_Mesh_Relay and runs live CPace pairing, object exchange, remote role
// call dispatch, three-way store sync + conflict resolution, and NAT relay
// forwarding over QUIC.
mesh_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	sw: Peer_Mesh_Switch
	mesh_switch_init(&sw)

	relay, relay_ok := host_mesh_relay_make(&sw, 2)
	if !relay_ok {
		fmt.eprintln("modustool: test failed: cannot initialize Host_Mesh_Relay")
		return false
	}
	host_mesh_relay_start_thread(relay)
	defer host_mesh_relay_stop(relay)
	relay_key_hex := strings.clone(host_mesh_relay_public_key_hex(relay))
	defer delete(relay_key_hex)

	live_a, live_b: Mesh_Live_Machine
	if !mesh_live_machine_start(&live_a, part, build.BOOT_VOLUME, TEST_OUTPUT_MESH_A, TEST_DISK_MESH_A, &sw, 0) {
		return false
	}
	defer _ = mesh_live_machine_stop(&live_a, false)
	if !mesh_live_machine_start(&live_b, part, build.BOOT_VOLUME, TEST_OUTPUT_MESH_B, TEST_DISK_MESH_B, &sw, 1) {
		return false
	}
	defer _ = mesh_live_machine_stop(&live_b, false)

	boot_steps := [?]Step {
		{kind = .Wait, text = "compositor: surface console"},
		{kind = .Launch, text = "remote"},
		{kind = .Wait, text = "root: started remote", any_order = true},
		{kind = .Wait, text = "remote: listening on the UDP port 7100, for the host 10.0.2.2 only", any_order = true},
		{kind = .Front, text = "console"},
		{kind = .Type, text = "connect(\"remote\")"},
		{kind = .Wait, text = "[console]   binding    remote"},
	}
	if !scenario_run(&live_a.machine, boot_steps[:]) || !scenario_run(&live_b.machine, boot_steps[:]) {
		return false
	}

	key_a_hex, key_a_ok := mesh_extract_after(&live_a.machine, 0, "remote: the public key of this service: ", 64)
	defer delete(key_a_hex)
	key_b_hex, key_b_ok := mesh_extract_after(&live_b.machine, 0, "remote: the public key of this service: ", 64)
	defer delete(key_b_hex)
	key_a, ka_ok := mesh_hex_to_key(key_a_hex)
	key_b, kb_ok := mesh_hex_to_key(key_b_hex)
	if !key_a_ok || !key_b_ok || !ka_ok || !kb_ok {
		fmt.eprintln("modustool: test failed: could not read machine identity keys from logs")
		return false
	}

	port_a, _ := mesh_switch_node_port(0)
	port_r, _ := mesh_switch_node_port(2)

	// 1. Live CPace pairing over QUIC: wrong code refused first, then real pairing.
	off_a := len(log_read(&live_a.machine))
	if !mesh_console_command(&live_a.machine, "remote.mesh_pair_offer(1)", "[console] ") {
		return false
	}
	if !mesh_console_command(&live_b.machine, "remote.mesh_pair_join(\"AAAAAAAAAB\", 1)", "[console] 0") {
		return false
	}
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_link_open(\"%s\", \"10.0.2.2\", %d, 2)", key_a_hex, port_a), "[console] ") {
		return false
	}
	if !mesh_wait_link_up(&live_b.machine, key_a_hex) {
		return false
	}
	off_b := len(log_read(&live_b.machine))
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_pair_send(\"%s\")", key_a_hex), "[console] ") {
		return false
	}
	wrong_req_id, wrong_id_ok := mesh_extract_int_line(&live_b.machine, off_b)
	if !wrong_id_ok {
		return false
	}
	// Poll wrong-code pairing until it fails with an error record.
	wrong_started := time.tick_now()
	wrong_refused := false
	for time.tick_since(wrong_started) < foundation.HANG_BOUND {
		b_off := len(log_read(&live_b.machine))
		if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_request_poll(\"%s\", %s)", key_a_hex, wrong_req_id), "[console] ") {
			return false
		}
		if strings.contains(log_read(&live_b.machine)[b_off:], "error:") {
			wrong_refused = true
			break
		}
		time.sleep(MESH_POLL_STEP_SLEEP)
	}
	if !wrong_refused {
		fmt.eprintln("modustool: test failed: wrong CPace pairing code was not refused")
		return false
	}
	if !mesh_console_command(&live_a.machine, fmt.tprintf("remote.mesh_paired_has(\"%s\")", key_b_hex), "[console] 0") {
		return false
	}
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_paired_has(\"%s\")", key_a_hex), "[console] 0") {
		return false
	}

	// Real CPace pairing with the valid one-time code.
	off_a = len(log_read(&live_a.machine))
	if !mesh_console_command(&live_a.machine, "remote.mesh_pair_offer(1)", "[console] ") {
		return false
	}
	pair_code, code_ok := mesh_wait_console_line(&live_a.machine, off_a)
	if !code_ok || len(pair_code) != machine_mesh.PAIRING_CODE_TEXT_SIZE {
		fmt.eprintln("modustool: test failed: could not read pairing code from Machine A")
		return false
	}
	defer delete(pair_code)
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_pair_join(\"%s\", 1)", pair_code), "[console] 0") {
		return false
	}
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_link_open(\"%s\", \"10.0.2.2\", %d, 2)", key_a_hex, port_a), "[console] ") {
		return false
	}
	if !mesh_wait_link_up(&live_b.machine, key_a_hex) {
		return false
	}
	off_b = len(log_read(&live_b.machine))
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_pair_send(\"%s\")", key_a_hex), "[console] ") {
		return false
	}
	pair_req_id, pair_id_ok := mesh_extract_int_line(&live_b.machine, off_b)
	if !pair_id_ok || !mesh_wait_request_ok(&live_b.machine, key_a_hex, pair_req_id, "ok:0") {
		return false
	}
	if !mesh_console_command(&live_a.machine, fmt.tprintf("remote.mesh_paired_has(\"%s\")", key_b_hex), "[console] 1") {
		return false
	}
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_paired_has(\"%s\")", key_a_hex), "[console] 1") {
		return false
	}

	// 2. Grant uses/roles, allow Machine B in Machine A's client table, and open Paired QUIC link.
	recipes_bit := u64(1) << u64(role_contract.Role.Recipes)
	settings_bit := u64(1) << u64(role_contract.Role.Settings)
	roles_mask := recipes_bit | settings_bit
	uses_all := u64(transmute(u32)(machine_wire.Machine_Uses{.Objects, .Stores, .Roles, .Relay}))
	uses_no_roles := u64(transmute(u32)(machine_wire.Machine_Uses{.Objects, .Stores, .Relay}))
	if !mesh_console_command(&live_a.machine, fmt.tprintf("remote_allow(\"%s\")", key_b_hex), "root: principal 0 allowed the client key ") {
		return false
	}
	if !mesh_console_command(&live_a.machine, fmt.tprintf("remote.mesh_grant(\"%s\", %d, %d)", key_b_hex, uses_all, roles_mask), "[console] 0") {
		return false
	}
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_grant(\"%s\", %d, 0)", key_a_hex, uses_no_roles), "[console] 0") {
		return false
	}
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_link_open(\"%s\", \"10.0.2.2\", %d, 1)", key_a_hex, port_a), "[console] ") {
		return false
	}
	if !mesh_wait_link_up(&live_b.machine, key_a_hex) {
		return false
	}

	// 3. Multi-chunk (>16 KiB) object-by-hash exchange over QUIC.
	off_a = len(log_read(&live_a.machine))
	if !mesh_console_command(&live_a.machine, "remote.mesh_object_put(1, \"modus-mesh-payload-block-0123456\", 768)", "[console] ") {
		return false
	}
	obj_hash_hex, hash_ok := mesh_wait_console_line(&live_a.machine, off_a)
	if !hash_ok || len(obj_hash_hex) != 64 {
		return false
	}
	defer delete(obj_hash_hex)
	off_b = len(log_read(&live_b.machine))
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_object_fetch(\"%s\", 1, \"%s\")", key_a_hex, obj_hash_hex), "[console] ") {
		return false
	}
	fetch_req_id, fetch_id_ok := mesh_extract_int_line(&live_b.machine, off_b)
	if !fetch_id_ok || !mesh_wait_request_ok(&live_b.machine, key_a_hex, fetch_req_id, "ok:0") {
		return false
	}
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_object_has(\"%s\")", obj_hash_hex), "[console] 24576") {
		return false
	}

	// 4. Live remote role call dispatch over QUIC (Role.Recipes build_count).
	recipes_bytes, recipes_read_err := os.read_entire_file(foundation.module_path("recipes"), context.temp_allocator)
	if recipes_read_err != nil || module.validate(recipes_bytes) != .None {
		fmt.eprintln("modustool: test failed: cannot read recipes.module for build_count export index")
		return false
	}
	build_count_export := module.export_find(recipes_bytes, "build_count")
	if build_count_export == 0 {
		fmt.eprintln("modustool: test failed: recipes.module has no build_count export")
		return false
	}
	off_b = len(log_read(&live_b.machine))
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_role_call(\"%s\", %d, %d, 1)", key_a_hex, u64(role_contract.Role.Recipes), build_count_export), "[console] ") {
		return false
	}
	role_req_id, role_id_ok := mesh_extract_int_line(&live_b.machine, off_b)
	if !role_id_ok || !mesh_wait_request_ok(&live_b.machine, key_a_hex, role_req_id, "ok:0") {
		return false
	}
	// Handle-bearing role (Role.Display) must be refused over the mesh.
	off_b = len(log_read(&live_b.machine))
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_role_call(\"%s\", %d, 1, 1)", key_a_hex, u64(role_contract.Role.Display)), "[console] ") {
		return false
	}
	bad_role_id, bad_role_id_ok := mesh_extract_int_line(&live_b.machine, off_b)
	if !bad_role_id_ok {
		return false
	}
	bad_role_started := time.tick_now()
	bad_role_refused := false
	for time.tick_since(bad_role_started) < foundation.HANG_BOUND {
		b_off := len(log_read(&live_b.machine))
		if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_request_poll(\"%s\", %s)", key_a_hex, bad_role_id), "[console] ") {
			return false
		}
		if strings.contains(log_read(&live_b.machine)[b_off:], "error:") {
			bad_role_refused = true
			break
		}
		time.sleep(MESH_POLL_STEP_SLEEP)
	}
	if !bad_role_refused {
		fmt.eprintln("modustool: test failed: handle-bearing Role.Display call was not refused over the mesh")
		return false
	}

	// 5. Multi-page store exchange with fast-forward merge, conflict creation, and resolution.
	if !mesh_console_command(&live_a.machine, fmt.tprintf("remote.mesh_store_add(\"notes\", \"%s\")", key_b_hex), "[console] 0") {
		return false
	}
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_store_add(\"notes\", \"%s\")", key_a_hex), "[console] 0") {
		return false
	}
	if !mesh_console_command(&live_a.machine, "remote.mesh_store_put(\"notes\", \"doc1\", \"v1\")", "[console] 0") {
		return false
	}
	off_b = len(log_read(&live_b.machine))
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_store_sync(\"%s\", \"notes\")", key_a_hex), "[console] ") {
		return false
	}
	sync1_id, sync1_ok := mesh_extract_int_line(&live_b.machine, off_b)
	if !sync1_ok || !mesh_wait_request_ok(&live_b.machine, key_a_hex, sync1_id, "ok:0") {
		return false
	}
	if !mesh_console_command(&live_b.machine, "remote.mesh_store_info(\"notes\")", "[console]   entry_count       1") {
		return false
	}
	// Concurrent conflicting edits -> sync -> conflict_count = 1 -> resolve -> re-sync -> conflict_count = 0.
	if !mesh_console_command(&live_a.machine, "remote.mesh_store_put(\"notes\", \"doc1\", \"from-A\")", "[console] 0") {
		return false
	}
	if !mesh_console_command(&live_b.machine, "remote.mesh_store_put(\"notes\", \"doc1\", \"from-B\")", "[console] 0") {
		return false
	}
	off_b = len(log_read(&live_b.machine))
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_store_sync(\"%s\", \"notes\")", key_a_hex), "[console] ") {
		return false
	}
	sync2_id, sync2_ok := mesh_extract_int_line(&live_b.machine, off_b)
	if !sync2_ok || !mesh_wait_request_ok(&live_b.machine, key_a_hex, sync2_id, "ok:0") {
		return false
	}
	if !mesh_console_command(&live_b.machine, "remote.mesh_store_info(\"notes\")", "[console]   conflict_count    1") {
		return false
	}
	if !mesh_console_command(&live_b.machine, "remote.mesh_store_resolve(\"notes\", \"doc1\", \"merged-AB\")", "[console] 0") {
		return false
	}
	off_b = len(log_read(&live_b.machine))
	if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_store_sync(\"%s\", \"notes\")", key_a_hex), "[console] ") {
		return false
	}
	sync3_id, sync3_ok := mesh_extract_int_line(&live_b.machine, off_b)
	if !sync3_ok || !mesh_wait_request_ok(&live_b.machine, key_a_hex, sync3_id, "ok:0") {
		return false
	}
	if !mesh_console_command(&live_a.machine, "remote.mesh_store_info(\"notes\")", "[console]   conflict_count    0") {
		return false
	}

	// 6. NAT isolation + end-to-end ChaCha20-Poly1305 sealed relay deposit & collect over QUIC.
	_ = mesh_switch_set_nat_blocked(&sw, 0, 1, true)
	off_a = len(log_read(&live_a.machine))
	if !mesh_console_command(&live_a.machine, fmt.tprintf("remote.mesh_relay_token(\"%s\", 1)", key_b_hex), "[console] ") {
		return false
	}
	token_hex, tok_ok := mesh_wait_console_line(&live_a.machine, off_a)
	defer delete(token_hex)
	token, tok_dec_ok := mesh_hex_to_token(token_hex)
	if !tok_ok || len(token_hex) != 32 || !tok_dec_ok {
		fmt.eprintfln("modustool: test failed: bad relay token %q (ok=%v)", token_hex, tok_ok)
		return false
	}
	if status := host_mesh_relay_route_add(relay, token, key_a, key_b); status != .Ok {
		fmt.eprintfln("modustool: test failed: host_mesh_relay_route_add failed: %v", status)
		return false
	}
	// Pair Machine A with Host_Mesh_Relay over QUIC, then grant Relay use.
	{
		rand_bytes: [8]u8 = {1, 2, 3, 4, 5, 6, 7, 8}
		relay_code, r_status := host_mesh_relay_offer_pairing(relay, rand_bytes, {.Calls}, host_mesh_relay_now_ms(relay))
		if r_status != .Ok {
			fmt.eprintfln("modustool: test failed: relay offer A failed: %v", r_status)
			return false
		}
		if !mesh_console_command(&live_a.machine, fmt.tprintf("remote.mesh_pair_join(\"%s\", 1)", string(relay_code[:])), "[console] 0") {
			return false
		}
		if !mesh_console_command(&live_a.machine, fmt.tprintf("remote.mesh_link_open(\"%s\", \"10.0.2.2\", %d, 2)", relay_key_hex, port_r), "[console] ") {
			return false
		}
		if !mesh_wait_link_up(&live_a.machine, relay_key_hex) {
			return false
		}
		off_a = len(log_read(&live_a.machine))
		if !mesh_console_command(&live_a.machine, fmt.tprintf("remote.mesh_pair_send(\"%s\")", relay_key_hex), "[console] ") {
			return false
		}
		req_a, ok_a := mesh_extract_int_line(&live_a.machine, off_a)
		if !ok_a || !mesh_wait_request_ok(&live_a.machine, relay_key_hex, req_a, "ok:0") {
			return false
		}
		if !host_mesh_relay_grant_peer(relay, key_a, {.Relay}) {
			fmt.eprintln("modustool: test failed: relay grant A failed")
			return false
		}
		// Open Paired link from Machine A to Host_Mesh_Relay and deposit sealed envelope.
		if !mesh_console_command(&live_a.machine, fmt.tprintf("remote.mesh_link_open(\"%s\", \"10.0.2.2\", %d, 1)", relay_key_hex, port_r), "[console] ") {
			return false
		}
		if !mesh_wait_link_up(&live_a.machine, relay_key_hex) {
			return false
		}
		off_a = len(log_read(&live_a.machine))
		if !mesh_console_command(&live_a.machine, fmt.tprintf("remote.mesh_relay_send(\"%s\", \"%s\", 1, \"secret-via-nat-relay\")", relay_key_hex, key_b_hex), "[console] ") {
			return false
		}
		dep_id, dep_ok := mesh_extract_int_line(&live_a.machine, off_a)
		if !dep_ok || !mesh_wait_request_ok(&live_a.machine, relay_key_hex, dep_id, "ok:0") {
			return false
		}
	}
	// Pair Machine B with Host_Mesh_Relay over QUIC, grant Relay use, and collect + decrypt.
	{
		rand_bytes: [8]u8 = {9, 10, 11, 12, 13, 14, 15, 16}
		relay_code, r_status := host_mesh_relay_offer_pairing(relay, rand_bytes, {.Calls}, host_mesh_relay_now_ms(relay))
		if r_status != .Ok {
			return false
		}
		if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_pair_join(\"%s\", 1)", string(relay_code[:])), "[console] 0") {
			return false
		}
		if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_link_open(\"%s\", \"10.0.2.2\", %d, 2)", relay_key_hex, port_r), "[console] ") {
			return false
		}
		if !mesh_wait_link_up(&live_b.machine, relay_key_hex) {
			return false
		}
		off_b = len(log_read(&live_b.machine))
		if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_pair_send(\"%s\")", relay_key_hex), "[console] ") {
			return false
		}
		req_b, ok_b := mesh_extract_int_line(&live_b.machine, off_b)
		if !ok_b || !mesh_wait_request_ok(&live_b.machine, relay_key_hex, req_b, "ok:0") {
			return false
		}
		if !host_mesh_relay_grant_peer(relay, key_b, {.Relay}) {
			return false
		}
		if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_link_open(\"%s\", \"10.0.2.2\", %d, 1)", relay_key_hex, port_r), "[console] ") {
			return false
		}
		if !mesh_wait_link_up(&live_b.machine, relay_key_hex) {
			return false
		}
		off_b = len(log_read(&live_b.machine))
		if !mesh_console_command(&live_b.machine, fmt.tprintf("remote.mesh_relay_receive(\"%s\", \"%s\", 1)", relay_key_hex, key_a_hex), "[console] ") {
			return false
		}
		col_id, col_ok := mesh_extract_int_line(&live_b.machine, off_b)
		if !col_ok || !mesh_wait_request_ok(&live_b.machine, relay_key_hex, col_id, "ok:secret-via-nat-relay") {
			return false
		}
	}

	shutdown_steps := [?]Step {
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "kernel: the machine stops with code 0"},
	}
	ok_a := scenario_run(&live_a.machine, shutdown_steps[:])
	ok_b := scenario_run(&live_b.machine, shutdown_steps[:])
	clean_a := mesh_live_machine_stop(&live_a, ok_a)
	clean_b := mesh_live_machine_stop(&live_b, ok_b)
	return clean_a && clean_b
}

// A binary of the tool runs the test part mesh only when it holds this file
// (test_parts.odin, test_part_scenario_register).
@(init)
mesh_test_part_register :: proc "contextless" () {
	test_part_scenario_register("mesh", mesh_tests_run)
}
