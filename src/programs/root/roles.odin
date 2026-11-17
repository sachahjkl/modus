package root

import "modus:support/disk_program"
import terminal "modus:support/terminal"

// The role of a program of the boot image: what this service gives it at
// its start, by its name. role_of reads it one time, at the start; the
// program keeps it in Started.role, and each rule after the start reads it
// there and never by the name of the program. A disk program has a
// nickname that it chose: its role comes from the disk grant table of its
// principal, never from this table (disk_programs.odin).
//
// The grants are the switch `grants_of` (main.odin), which the site reads
// for its table "The grants of each program". The other parts of a role
// are the rows below; a name with no row has the zero terms.
Program_Role :: struct {
	grants:      bit_set[Grant],
	using terms: Program_Role_Terms,
}

// The services that a program with the grant Connect and not Root_Ring can
// connect to: the list of its row, an empty text after the last one.
CALLABLE_LIMIT :: 9

// The parts of a role that are not start grants. Zero is the role of each
// program that no row names.
Program_Role_Terms :: struct {
	callable:         [CALLABLE_LIMIT]string, // With the grant Connect: the services that it can connect to.
	store_blocks:     u64, // With the grant Store: the blocks of its private store. 0: STORE_BLOCKS_DEFAULT.
	log_gives:        bool, // The log with the right Give: it gives the log to the programs that it starts.
	terminal_columns: u64, // With the grant Terminal: the columns of its terminal. 0: TERMINAL_COLUMNS_DEFAULT.
	terminal_rows:    u64, // 0: TERMINAL_ROWS_DEFAULT.
	terminal_measure: bool, // Its terminal shows the rates of the program.
	on_demand:        bool, // A service that starts at the first connection to it.
}

STORE_BLOCKS_DEFAULT :: 64
TERMINAL_COLUMNS_DEFAULT :: 96
TERMINAL_ROWS_DEFAULT :: 26

// A row of the table: the terms of the role of one program, by its name.
Program_Role_Row :: struct {
	name:  string,
	terms: Program_Role_Terms,
}

// The terms of each program that has a term that is not zero, with the
// reason of each.
@(rodata)
program_role_rows := [?]Program_Role_Row {
	// A small limit: the test reaches it. It starts programs that write on
	// the log.
	{name = "console", terms = {store_blocks = 3, log_gives = true}},
	// One object is over the limit. It gives the log to its child, which
	// measures a refused Log.
	{name = "errors", terms = {store_blocks = 2, log_gives = true}},
	// The versions of a run of 1000 commits of the count (4 blocks each),
	// then thinning at the limit.
	{name = "notes", terms = {store_blocks = 4500}},
	// 100000 empty objects in 1110 trees: about 9500 nodes, and room for
	// the copies of a commit.
	{name = "hierarchy", terms = {store_blocks = 12000}},
	// A commit of 1000 blocks spread over an object of 8 GiB holds about
	// 2000 blocks, with its version; the loop of range commits about 4000.
	{name = "ranges", terms = {store_blocks = 12000}},
	// The store of the module files: the limit with which this service
	// reads it and the tool writes it, so no grant differs from the limit
	// on the disk. It starts when a principal connects to it.
	{name = "programs", terms = {store_blocks = disk_program.STORE_BLOCKS_LIMIT, on_demand = true}},
	// Its nodes write on the log.
	{name = "rings", terms = {log_gives = true}},
	// The child that repairs logs its own cases.
	{name = "fault_ring", terms = {log_gives = true}},
	// A child of debugged writes one line from a buffer that its debugger
	// watches.
	{name = "debugged", terms = {log_gives = true}},
	// The log service and no other (src/md/features/log_reader_scope.md);
	// each child writes the records that its starter reads back, one of
	// them more than the whole log keeps.
	{name = "log_reader", terms = {callable = {0 = "log"}, log_gives = true}},
	// The services that a call from another machine reaches, each for one
	// row of the client table (docs/PRINCIPALS.md, "The client keys of
	// remote").
	{name = "remote", terms = {callable = {"compositor", "date", "debugger", "inspect", "log", "manual", "monitor", "settings", "storage"}}},
	{name = "tables", terms = {callable = {0 = "sample"}}},
	// The window of the debugger connects to the service debugger only
	// (docs/TOOLS.md, "The window of the debugger").
	{name = "debugger_window", terms = {callable = {0 = "debugger"}}},
	// It shows the rates of the program in a terminal as large as a
	// terminal can be.
	{name = "flood", terms = {terminal_columns = terminal.COLUMNS_LIMIT, terminal_rows = terminal.ROWS_LIMIT, terminal_measure = true}},
	// The services that start at the first connection to them.
	{name = "storage", terms = {on_demand = true}},
	{name = "sample", terms = {on_demand = true}},
	{name = "debugger", terms = {on_demand = true}},
}

// role_of gives the role of a program of the boot image by its name: the
// grants of grants_of, and the terms of its row. Only a start reads it.
role_of :: proc "contextless" (name: string) -> (role: Program_Role) {
	role.grants = grants_of(name)
	for &row in program_role_rows {
		if row.name == name {
			role.terms = row.terms
			break
		}
	}
	return role
}

// role_names_the_program says if the tables of this service give the name
// a grant or a term: a disk program does not take such a nickname.
role_names_the_program :: proc "contextless" (name: string) -> bool {
	if grants_of(name) != {} {
		return true
	}
	for &row in program_role_rows {
		if row.name == name {
			return true
		}
	}
	return false
}

// role_store_blocks gives the blocks of the private store of a role.
role_store_blocks :: proc "contextless" (role: ^Program_Role) -> u64 {
	return role.store_blocks == 0 ? STORE_BLOCKS_DEFAULT : role.store_blocks
}

// role_may_connect says if a program with a role can ask this service for a
// connection to the service with a name. A program with the grant
// Root_Ring connects to each service.
role_may_connect :: proc "contextless" (role: ^Program_Role, service: string) -> bool {
	if .Root_Ring in role.grants {
		return true
	}
	if .Connect not_in role.grants {
		return false
	}
	for name in role.callable {
		if name == "" {
			return false
		}
		if name == service {
			return true
		}
	}
	return false
}

// role_terminal gives the size of the terminal of a role, and what it
// shows.
role_terminal :: proc "contextless" (role: ^Program_Role) -> (columns, rows: u64, measure: bool) {
	columns = role.terminal_columns == 0 ? TERMINAL_COLUMNS_DEFAULT : role.terminal_columns
	rows = role.terminal_rows == 0 ? TERMINAL_ROWS_DEFAULT : role.terminal_rows
	return columns, rows, role.terminal_measure
}

// on_demand says if the service with a name starts when a program asks for
// a connection to it.
on_demand :: proc "contextless" (name: string) -> bool {
	return role_of(name).on_demand
}
