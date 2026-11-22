package machine

import "modustool:foundation"
import "modustool:build"

// QUIC against a stack that this project did not write (docs/QUIC.md,
// section 6): the step Openssl_Quic runs the QUIC client of OpenSSL against
// quic_echo (openssl_quic.odin).

TEST_OUTPUT_QUIC_REAL :: foundation.BUILD_FOLDER + "/test_output_quic_real.txt"

scenario_quic_real := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "quic_echo"},
	{kind = .Wait, text = "network: an endpoint for quic_echo: UDP, the listen port 4433, the remotes that send 1200 bytes to it", any_order = true},
	{kind = .Quic_Key, text = "quic_echo: the public key of this server: "},
	{kind = .Wait, text = "quic_echo: listening on the UDP port 4433, a table of 16 connections of "},
	{kind = .Openssl_Quic, text = "an echo through QUIC, from the OpenSSL of the host"},
	{kind = .Wait, text = "quic_echo: a connection from 10.0.2.2 port "},
	{kind = .Front, text = "quic_echo"},
	{kind = .Shot, text = "quic_echo_openssl"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// quic_real_tests_run runs the machine of `modustool test quic-real`.
quic_real_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_quic_real[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_QUIC_REAL, exit_status = build.MACHINE_STOP_OK})
}

// A binary of the tool runs the test part quic-real only when it holds this file
// (test_parts.odin, test_part_scenario_register).
@(init)
quic_real_test_part_register :: proc "contextless" () {
	test_part_scenario_register("quic-real", quic_real_tests_run)
}
