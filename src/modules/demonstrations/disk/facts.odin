package disk

// The log facts of the demonstration disk (src/md/features/log_facts.md,
// "The facts of the demonstrations"): its runs, its measures and its
// cases, as records of fields. Each fact template is the sentence that the
// line wrote before it was a fact, so a wait of a machine test on that
// sentence, and the measure record that reads the blocks in one second,
// read it as before. A Text field comes last, and holds its longest text
// and a zero byte.
//
// A run names its direction ("read" or "write") and the word of its blocks
// ("block" for one, "blocks" for more) as Text fields: a size in blocks
// writes "1 blocks", which the line never wrote.

// A run of a measure run: the blocks in one second.
@(log_fact = "disk: {direction}, {request_blocks} {block_word} in each request, {depth} in flight: {blocks_in_second} blocks in one second, kernel entries for 100 requests: {own_entries} of this process, {service_entries} of the block service, {request_errors} errors")
Run_Measured :: struct {
	request_blocks:   u64,
	depth:            u64,
	blocks_in_second: u64,
	own_entries:      u64,
	service_entries:  u64,
	request_errors:   u64,
	direction:        [8]u8,
	block_word:       [8]u8,
}

// A run of a check, outside a measure run.
@(log_fact = "disk: {direction}, {request_blocks} {block_word} in each request, {depth} in flight: {requests} requests, kernel entries for 100 requests: {own_entries} of this process, {service_entries} of the block service, {request_errors} errors")
Run_Checked :: struct {
	request_blocks:  u64,
	depth:           u64,
	requests:        u64,
	own_entries:     u64,
	service_entries: u64,
	request_errors:  u64,
	direction:       [8]u8,
	block_word:      [8]u8,
}

// The block service refused a command word that names no command, and
// served the next Info.
@(log_fact = "disk: the command word {command_word} of the block ring: refused with Bad_Command and the record Unsupported of the word, and the next Info is served: as it must")
Command_Word_Refused :: struct {
	command_word: u64,
}

// The block service answered a command word that names no command with
// another status or another error record.
@(log_fact = "disk: the command word {command_word} of the block ring: WRONG: the status {status_word}, the error kind {error_kind}, the operation {operation_word}; the next Info: the status {next_status_word}")
Command_Word_Not_Refused :: struct {
	command_word:     u64,
	status_word:      u64,
	error_kind:       u64,
	operation_word:   u64,
	next_status_word: u64,
}

// The compositor read the command words of the window that name no
// command.
@(log_fact = "disk: the window sent the command words {first_word}, {second_word} and {third_word}: the compositor read the three: as it must")
Window_Words_Read :: struct {
	first_word:  u64,
	second_word: u64,
	third_word:  u64,
}

// The compositor did not read the command words of the window in the hang
// bound.
@(log_fact = "disk: the window sent the command words {first_word}, {second_word} and {third_word}: WRONG: the compositor did not read them in {bound} ms")
Window_Words_Not_Read :: struct {
	first_word:  u64,
	second_word: u64,
	third_word:  u64,
	bound:       u64,
}

// The disk answered Info: its size, and the most blocks of one request.
@(log_fact = "disk: ok, the disk has {disk_blocks} blocks, {request_blocks_most} blocks in one request at most")
Disk_Ready :: struct {
	disk_blocks:         u64,
	request_blocks_most: u64,
}

// Each run had no error, and the check read back what it wrote.
@(log_fact = "disk: ok, {runs} runs, 0 errors, write then read back: 0 wrong")
Disk_Held :: struct {
	runs: u64,
}

// A run had errors, or the check read back other bytes.
@(log_fact = "disk: wrong: {request_errors} errors, {wrong_bytes} wrong bytes")
Disk_Wrong :: struct {
	request_errors: u64,
	wrong_bytes:    u64,
}
