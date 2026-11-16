package modustool

// The fuzz targets (src/md/infrastructure/fuzzing.md, "The targets, in
// order of value"). A new target adds its row here and its folder of corpus
// under tools/modustool/fuzzing_corpus. The important formats have a raw
// target, which reaches the first checks of the reader, and a generated
// target, which reaches the code behind them.

@(private = "file")
fuzz_target_table := [?]Fuzz_Target {
	{
		name = "module_file",
		kind = .Raw,
		about = "contract/module: a file that validate accepts gives no read out of bounds through any reader",
		packages = {"contract/module"},
		input_limit = 64 << 10,
		execute = fuzz_module_file_execute,
		seeds = fuzz_module_seeds,
		regions = fuzz_module_regions,
	},
	{
		name = "module_generated",
		kind = .Generated,
		about = "contract/module: a module built by the rules is valid; one broken field, then each reader",
		packages = {"contract/module"},
		input_limit = 4 << 10,
		execute = fuzz_module_generated_execute,
	},
	{
		name = "debug_object",
		kind = .Raw,
		about = "contract/debug_object: an object that check accepts gives each reader with no fault, and encodes to the same bytes",
		packages = {"contract/debug_object"},
		input_limit = 64 << 10,
		execute = fuzz_debug_object_execute,
		seeds = fuzz_debug_object_seeds,
		regions = fuzz_debug_object_regions,
	},
	{
		name = "debug_object_generated",
		kind = .Generated,
		about = "contract/debug_object: an object built by the rules passes check; one broken field, then each reader",
		packages = {"contract/debug_object"},
		input_limit = 4 << 10,
		execute = fuzz_debug_object_generated_execute,
	},
	{
		name = "storage_tree",
		kind = .Generated,
		about = "support/storage_tree: the B-tree against a sorted model, its walk after each commit, then damaged nodes",
		packages = {"support/storage_tree"},
		input_limit = 8 << 10,
		execute = fuzz_storage_tree_execute,
		start = fuzz_storage_tree_start,
		check_executions = 5_000,
	},
	{
		name = "storage_mount",
		kind = .Generated,
		about = "support/storage_mount: the open of a disk gives back each object of its writer, then never a wrong object of a damaged disk",
		packages = {"support/storage_mount", "support/storage_object", "support/storage_tree"},
		input_limit = 4 << 10,
		execute = fuzz_storage_mount_execute,
		start = fuzz_storage_mount_start,
		check_executions = 2_000,
	},
	{
		name = "quic_datagram",
		kind = .Raw,
		about = "support/quic: one datagram to a server that waits for its client: the header reader, the receive, the answer",
		packages = {"support/quic"},
		input_limit = 2 << 10,
		execute = fuzz_quic_datagram_execute,
		seeds = fuzz_quic_datagram_seeds,
		start = fuzz_quic_start,
	},
	{
		name = "quic_connection",
		kind = .Generated,
		about = "support/quic: a client and a server in memory, datagrams changed or resealed with new frames; with no change the handshake completes",
		packages = {"support/quic"},
		input_limit = 4 << 10,
		execute = fuzz_quic_connection_execute,
		start = fuzz_quic_start,
		check_executions = 1_000,
	},
	{
		name = "tls_messages",
		kind = .Raw,
		about = "support/quic: the messages of TLS 1.3 to a client or to a server, level by level",
		packages = {"support/quic"},
		input_limit = 8 << 10,
		execute = fuzz_tls_messages_execute,
		seeds = fuzz_tls_messages_seeds,
		start = fuzz_quic_start,
		check_executions = 5_000,
	},
	{
		name = "quic_transport_parameters",
		kind = .Raw,
		about = "support/quic: the transport parameters that the reader accepts write and read again to the same record",
		packages = {"support/quic"},
		input_limit = 1 << 10,
		execute = fuzz_transport_parameters_execute,
		seeds = fuzz_transport_parameters_seeds,
	},
	{
		name = "tcp_segment",
		kind = .Raw,
		about = "support/tcp: the header reader and its writer agree, and a listening table takes the segment",
		packages = {"support/tcp"},
		input_limit = 1480,
		execute = fuzz_tcp_segment_execute,
		start = fuzz_tcp_start,
	},
	{
		name = "tcp_connection",
		kind = .Generated,
		about = "support/tcp: two tables in memory with injected segments; with no injection the bytes arrive whole and in order",
		packages = {"support/tcp"},
		input_limit = 4 << 10,
		execute = fuzz_tcp_connection_execute,
		start = fuzz_tcp_start,
		check_executions = 5_000,
	},
	{
		name = "http_request",
		kind = .Raw,
		about = "support/web: the reader of a request head: its fields stay in their limits, and the head reads the same from its own bytes",
		packages = {"support/web"},
		input_limit = 16 << 10,
		execute = fuzz_http_request_execute,
		seeds = fuzz_http_request_seeds,
	},
}

fuzz_targets :: proc() -> []Fuzz_Target {
	return fuzz_target_table[:]
}

fuzz_target_find :: proc(targets: []Fuzz_Target, name: string) -> (target: ^Fuzz_Target, found: bool) {
	for &item in targets {
		if item.name == name {
			return &item, true
		}
	}
	return nil, false
}
