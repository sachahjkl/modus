package modustool

// The randomness of the system: three machines (docs/RANDOMNESS.md).
//
// Two machines with each feature of the processor: the root service makes
// the seed of the system from rdseed; two programs `randomness` show two
// streams. The first of them has the entropy device of virtio: the root
// service starts the entropy service, mixes its two reads of 32 bytes into
// its generator, and the window shows the bytes; the second has none, and
// starts with the sources of the processor
// (src/md/features/entropy_device.md). The third machine has no rdrand and
// no rdseed (`-cpu max,-rdrand,-rdseed`): the seed comes from the cycle
// counter only, the root service and the window say "weak", and each
// program still starts. The first bytes of the stream of each program, in
// the three machines, all differ: two programs, and a restart, give
// different streams. On the first machine the root service reads the
// device again 30 seconds after the start, writes 32 bytes of its stream in
// the fresh bytes page of each program, and each program `randomness`
// mixes them into its generator (src/md/features/fresh_bytes.md).

TEST_OUTPUT_RANDOM :: BUILD_FOLDER + "/test_output_random.txt"

scenario_random_with_the_processor := [?]Step {
	{kind = .Wait, text = "root: the random seed of the system, strength entropy (rdseed): rdseed present, 8 good values, 0 refused; rdrand present, 8 good, 0 refused"},
	// The entropy service answers while the desktop starts: its lines come
	// in no fixed order with those of the compositor.
	{kind = .Wait, text = "root: started entropy for the device at the place 19 of the bus", any_order = true},
	{kind = .Wait, text = "entropy: ok, a queue of ", any_order = true},
	{kind = .Wait, text = "root: the entropy device gave 64 bytes in 2 reads: 64 bytes mixed into the random generator of the system; refused reads: 0", any_order = true},
	// The first refresh of the fresh bytes comes 30 seconds after the reads
	// of the start (src/md/features/fresh_bytes.md): its line comes in no
	// fixed order with those of the desktop.
	{kind = .Wait, text = "root: the first fresh bytes: 32 bytes of the entropy device mixed into the random generator of the system, then 32 bytes of its stream in the fresh bytes page of each of ", any_order = true},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"randomness\")"},
	{kind = .Remember, text = "randomness: the seed of the system: strength entropy (rdseed); the first bytes of the stream of this program: "},
	{kind = .Wait, text = "randomness: the entropy device: 64 bytes mixed after the gathering; refused reads: 0"},
	{kind = .Wait, text = "randomness: 1 MiB by the high 4 bits of each byte: from "},
	{kind = .Wait, text = "randomness: the generator: 4 MiB in "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"randomness\")"},
	{kind = .Remember, text = "randomness: the seed of the system: strength entropy (rdseed); the first bytes of the stream of this program: "},
	// The first program can mix its page before the second one ends its
	// measure: the next two lines search from the measure of the first.
	{kind = .Wait, text = "randomness: the generator: 4 MiB in ", any_order = true},
	// Each of the two programs mixes the next change of its page at a refill
	// of its live draw, then writes the line once. After both lines, the
	// window in front shows a mix.
	{kind = .Wait, text = "randomness: the fresh bytes of the root service are mixed into the generator of this program, at the change "},
	{kind = .Wait, text = "randomness: the fresh bytes of the root service are mixed into the generator of this program, at the change "},
	{kind = .Front, text = "randomness"},
	{kind = .Shot, text = "randomness"},
	{kind = .Distinct, text = "two programs of one machine"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_random_restart := [?]Step {
	{kind = .Wait, text = "root: the random seed of the system, strength entropy (rdseed)"},
	// No entropy device: the machine starts with the sources of the processor.
	{kind = .Wait, text = "root: no entropy device at the place 19 of the bus: the random seed of the system has the sources of the processor only"},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"randomness\")"},
	{kind = .Remember, text = "randomness: the seed of the system: strength entropy (rdseed); the first bytes of the stream of this program: "},
	{kind = .Wait, text = "randomness: the entropy device: absent"},
	{kind = .Distinct, text = "two programs, then a restart of the machine"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_random_without_the_processor := [?]Step {
	{kind = .Wait, text = "root: the random seed of the system, strength weak (the cycle counter only): rdseed absent, 0 good values, 0 refused; rdrand absent, 0 good, 0 refused; the cycle counter, 2048 samples, "},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"randomness\")"},
	{kind = .Remember, text = "randomness: the seed of the system: strength weak (the cycle counter only); the first bytes of the stream of this program: "},
	{kind = .Wait, text = "randomness: the generator: 4 MiB in "},
	{kind = .Front, text = "randomness"},
	{kind = .Shot, text = "randomness_weak"},
	{kind = .Distinct, text = "three machines, one of them with no rdrand and no rdseed"},
	// A QUIC server asks for the strength "processor" at least: with a weak
	// seed it makes no key, says why on the log and in its window, and
	// listens on nothing (docs/QUIC.md, section 6).
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"quic_echo\")"},
	{kind = .Wait, text = "quic_echo: the random seed of this program is weak: it makes no key of a server, and listens on nothing"},
	{kind = .Front, text = "quic_echo"},
	{kind = .Shot, text = "quic_echo_weak"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

random_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_random_with_the_processor[:], {volume = BOOT_VOLUME, output = TEST_OUTPUT_RANDOM, exit_status = MACHINE_STOP_OK, entropy_device = true}) && machine_test(part, scenario_random_restart[:], {volume = BOOT_VOLUME, output = TEST_OUTPUT_RANDOM, exit_status = MACHINE_STOP_OK}) && machine_test(part, scenario_random_without_the_processor[:], {volume = BOOT_VOLUME, output = TEST_OUTPUT_RANDOM, exit_status = MACHINE_STOP_OK, processor = .Without_Random})
}
