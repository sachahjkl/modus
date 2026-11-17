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
		// Up to 300 operations and a walk after each commit in one
		// execution: a long run explores; the check keeps its part short.
		check_executions = 2_000,
	},
	{
		name = "storage_mount",
		kind = .Generated,
		about = "support/storage_mount: the open of a disk gives back each object of its writer, then never a wrong object of a damaged disk",
		packages = {"support/storage_mount", "support/storage_object", "support/storage_tree"},
		input_limit = 4 << 10,
		execute = fuzz_storage_mount_execute,
		start = fuzz_storage_mount_start,
		// Measured: about 120 executions in one second (a whole disk is
		// written and opened two times), so 1000 cost about 8 seconds.
		check_executions = 1_000,
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
		// Measured: about 120 executions in one second (a whole handshake
		// each), so 1000 cost about 8 seconds.
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
	{
		name = "remote_request",
		kind = .Raw,
		about = "contract/remote: a call request that request_check accepts keeps each place in the call region and writes again to its bytes",
		packages = {"contract/remote"},
		input_limit = 4 << 10,
		execute = fuzz_remote_request_execute,
		seeds = fuzz_remote_request_seeds,
	},
	{
		name = "remote_answer",
		kind = .Raw,
		about = "contract/remote: a call answer that answer_check accepts names a status, shows no more details than it holds, and writes again to its bytes",
		packages = {"contract/remote"},
		input_limit = 4 << 10,
		execute = fuzz_remote_answer_execute,
		seeds = fuzz_remote_answer_seeds,
	},
	{
		name = "remote_client_table",
		kind = .Raw,
		about = "contract/remote: the client table reads as it is written, and each decision on a key names the right row",
		packages = {"contract/remote"},
		input_limit = 1 << 10,
		execute = fuzz_remote_client_table_execute,
		seeds = fuzz_remote_client_table_seeds,
	},
	{
		name = "isolated_call",
		kind = .Raw,
		about = "contract/isolated: decode of a description and a call region gives only slices inside the call region",
		packages = {"contract/isolated"},
		input_limit = FUZZ_CALL_DESCRIPTION_SIZE + FUZZ_CALL_REGION_LIMIT,
		execute = fuzz_isolated_call_execute,
		seeds = fuzz_isolated_call_seeds,
		start = fuzz_isolated_call_start,
	},
	{
		name = "ring_records",
		kind = .Raw,
		about = "the records of a ring: each event, input, service command and root command is a member that its word names, or a refusal",
		packages = {"support/display", "support/terminal", "support/system", "contract/root_ring", "contract/errors"},
		input_limit = FUZZ_RING_RECORDS_INPUT_LIMIT,
		execute = fuzz_ring_records_execute,
		seeds = fuzz_ring_records_seeds,
		regions = fuzz_ring_records_regions,
	},
	{
		name = "disk_grant_table",
		kind = .Raw,
		about = "support/disk_program: a table behind its tag holds rows by its rules, and encodes and decodes to its part that persists",
		packages = {"support/disk_program"},
		input_limit = 2 << 10,
		execute = fuzz_disk_grant_table_execute,
		seeds = fuzz_disk_grant_table_seeds,
	},
	{
		name = "system_description",
		kind = .Raw,
		about = "contract/system_description: a description that entries accepts is the one that its writer gives for its entries",
		packages = {"contract/system_description", "contract/boot_info"},
		input_limit = 16 << 10,
		execute = fuzz_system_description_execute,
		seeds = fuzz_system_description_seeds,
	},
	{
		name = "boot_image_generated",
		kind = .Generated,
		about = "contract/system_description: a boot image as built passes the checks; a changed byte of a file or of the description fails them",
		packages = {"contract/system_description", "contract/boot_info"},
		input_limit = 4 << 10,
		execute = fuzz_boot_image_generated_execute,
		// Each execution writes a whole boot image of up to seven pages and
		// hashes each file.
		check_executions = 5_000,
	},
	{
		name = "vector_font",
		kind = .Raw,
		about = "support/vector_font: a font that font_open accepts gives each glyph, outline, pair and substitution, and draws a glyph",
		packages = {"support/vector_font"},
		input_limit = 64 << 10,
		execute = fuzz_vector_font_execute,
		seeds = fuzz_vector_font_seeds,
		start = fuzz_vector_font_start,
		// Each execution of a whole font reads the outlines of 94
		// characters and draws one.
		check_executions = 5_000,
	},
	{
		name = "glyph_cache",
		kind = .Raw,
		about = "contract/glyph_cache: a cache that validate accepts gives each glyph with its rows in its line and its words in the file",
		packages = {"contract/glyph_cache"},
		input_limit = 64 << 10,
		execute = fuzz_glyph_cache_execute,
		seeds = fuzz_glyph_cache_seeds,
		regions = fuzz_glyph_cache_regions,
	},
	{
		name = "font_outlines",
		kind = .Raw,
		about = "contract/font_outlines: a resource that validate accepts gives its font files, and its fonts write again to a resource with the same fonts",
		packages = {"contract/font_outlines"},
		input_limit = 4 << 10,
		execute = fuzz_font_outlines_execute,
		seeds = fuzz_font_outlines_seeds,
		regions = fuzz_font_outlines_regions,
	},
	{
		name = "pointer_pictures",
		kind = .Raw,
		about = "contract/pointer_pictures: a theme that validate accepts gives a picture of each shape, size and time with its pixels in the file",
		packages = {"contract/pointer_pictures"},
		input_limit = 8 << 10,
		execute = fuzz_pointer_pictures_execute,
		seeds = fuzz_pointer_pictures_seeds,
		regions = fuzz_pointer_pictures_regions,
	},
	{
		name = "firmware_tables",
		kind = .Raw,
		about = "contract/iommu: the tables DMAR, IVRS and MCFG that the readers accept keep their counts, ranges and units in their bounds",
		packages = {"contract/iommu"},
		input_limit = 4 << 10,
		execute = fuzz_firmware_tables_execute,
		seeds = fuzz_firmware_tables_seeds,
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
