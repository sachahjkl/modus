package root

// A disk process: a process whose module file is an object of the store
// `module_files` of the storage service, and not a file of the boot image
// (docs/MODULE_CONTRACT.md, "A module from a disk").
//
// The command Start_From_Disk names the process and the hash of its file.
// The delegated service disk_processes reads the object, and the imports
// that the boot image does not hold, into memory that this service lends;
// this service checks the hash of the bytes after the end of each loan,
// and starts them with the grants of the row of the nickname. Neither
// service is trusted to choose what runs, and neither is waited for: the
// load is a state of the loop of this service, so each other ring is
// served while the bytes come (disk_processes_delegation.odin).
//
// The disk grant table of each principal binds a nickname, the name of the
// entry, to the hash of one file, with the grants of that file
// (docs/MODULE_CONTRACT.md, "The grants of a disk process"). Its rules are
// in modus:disk_process; this file applies them at each start and
// serves the commands Disk_Grant and Nickname_Move. The store is the one
// grant that a command gives: the store of the nickname, so it follows the
// nickname to its next file.

import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import process_page "modus:contract/disk_process_page"
import "modus:contract/errors"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/start_grant"
import "modus:disk_process"
import "modus:display"
import "modus:principals"
import "modus:random"
import "modus:storage"
import "modus:contract/root_ring"
import "modus:system"
import "modus:contract/value_kinds"

// The disk grant table of each principal. With no machine passphrase, no
// key signs the table of principal 0: it lasts until the machine stops.
// With one, it is read from the disk and written after each change. The
// table of a named principal is read after its first unlock, under the key
// that `unlock` gives with it, and written after each change
// (persisted_grant_table.odin). A caller that acts for a named principal
// is a process of its session, such as a console that the desktop starts
// while the session runs.
disk_grant_tables: [principals.PRINCIPAL_CAPACITY]disk_process.Grant_Table

// disk_grant_table_of gives the table of a principal, or nil for a number
// with no record.
disk_grant_table_of :: proc "contextless" (principal: u64) -> ^disk_process.Grant_Table {
	if principal >= principals.PRINCIPAL_CAPACITY {
		return nil
	}
	return &disk_grant_tables[principal]
}

// How long the disk grant table of a principal lasts: the end of the
// sentence of a change of the table. A fact template has no condition, so
// each line of a change has one fact type for each member.
Table_Lasting :: enum u8 {
	Until_Stop, // Principal 0 has no passphrase: the table lasts until the machine stops.
	Kept_By_Machine_Passphrase, // The machine passphrase keeps the table of principal 0 on the disk.
	Kept_By_Passphrase, // The passphrase of a named principal keeps its table on the disk.
}

// disk_grant_table_lasting gives how long the table of a principal lasts.
disk_grant_table_lasting :: proc "contextless" (principal: u64) -> Table_Lasting {
	if principal == principals.MACHINE {
		if persisted_tables[principals.MACHINE].state == .No_Passphrase {
			return .Until_Stop
		}
		return .Kept_By_Machine_Passphrase
	}
	// A change of the table of a named principal is taken only when the
	// table is kept on the disk (persisted_table_refusal).
	return .Kept_By_Passphrase
}

// grant_lost_log writes the line of a grant that a nickname lost.
grant_lost_log :: proc "contextless" (principal: u64, hash: [disk_process.HASH_SIZE]u8, nickname, grant: string) {
	fact_hash, fact_nickname, fact_grant := value_kinds.Hash_Field(hash), module_name_field(nickname), text_field(grant, 24)
	switch disk_grant_table_lasting(principal) {
	case .Until_Stop:
		system.log_fact(.Info, Grant_Lost_Until_Stop{hash = fact_hash, principal = principal, nickname = fact_nickname, grant = fact_grant})
	case .Kept_By_Machine_Passphrase:
		system.log_fact(.Info, Grant_Lost_Kept_By_Machine_Passphrase{hash = fact_hash, principal = principal, nickname = fact_nickname, grant = fact_grant})
	case .Kept_By_Passphrase:
		system.log_fact(.Info, Grant_Lost_Kept_By_Passphrase{hash = fact_hash, principal = principal, nickname = fact_nickname, grant = fact_grant})
	}
}

// grant_given_log writes the line of a grant that a nickname has from its
// next start.
grant_given_log :: proc "contextless" (principal: u64, hash: [disk_process.HASH_SIZE]u8, nickname, grant: string) {
	fact_hash, fact_nickname, fact_grant := value_kinds.Hash_Field(hash), module_name_field(nickname), text_field(grant, 24)
	switch disk_grant_table_lasting(principal) {
	case .Until_Stop:
		system.log_fact(.Info, Grant_Given_Until_Stop{hash = fact_hash, principal = principal, nickname = fact_nickname, grant = fact_grant})
	case .Kept_By_Machine_Passphrase:
		system.log_fact(.Info, Grant_Given_Kept_By_Machine_Passphrase{hash = fact_hash, principal = principal, nickname = fact_nickname, grant = fact_grant})
	case .Kept_By_Passphrase:
		system.log_fact(.Info, Grant_Given_Kept_By_Passphrase{hash = fact_hash, principal = principal, nickname = fact_nickname, grant = fact_grant})
	}
}

// nickname_moved_log writes the line of a nickname that names another
// file, with its grants and its store.
nickname_moved_log :: proc "contextless" (principal: u64, hash: [disk_process.HASH_SIZE]u8, nickname: string) {
	fact_hash, fact_nickname := value_kinds.Hash_Field(hash), module_name_field(nickname)
	switch disk_grant_table_lasting(principal) {
	case .Until_Stop:
		system.log_fact(.Info, Nickname_Moved_Until_Stop{hash = fact_hash, nickname = fact_nickname})
	case .Kept_By_Machine_Passphrase:
		system.log_fact(.Info, Nickname_Moved_Kept_By_Machine_Passphrase{hash = fact_hash, nickname = fact_nickname})
	case .Kept_By_Passphrase:
		system.log_fact(.Info, Nickname_Moved_Kept_By_Passphrase{hash = fact_hash, nickname = fact_nickname})
	}
}

// table_persistence_log writes the line of the global setting of
// persistence of a table.
table_persistence_log :: proc "contextless" (principal: u64, persistence: string) {
	words := text_field(persistence, 32)
	switch disk_grant_table_lasting(principal) {
	case .Until_Stop:
		system.log_fact(.Info, Table_Persistence_Set_Until_Stop{principal = principal, persistence = words})
	case .Kept_By_Machine_Passphrase:
		system.log_fact(.Info, Table_Persistence_Set_Kept_By_Machine_Passphrase{principal = principal, persistence = words})
	case .Kept_By_Passphrase:
		system.log_fact(.Info, Table_Persistence_Set_Kept_By_Passphrase{principal = principal, persistence = words})
	}
}

// row_persistence_log writes the line of the setting of persistence of the
// row of a nickname.
row_persistence_log :: proc "contextless" (principal: u64, nickname, persistence: string) {
	fact_nickname, words := module_name_field(nickname), text_field(persistence, 32)
	switch disk_grant_table_lasting(principal) {
	case .Until_Stop:
		system.log_fact(.Info, Row_Persistence_Set_Until_Stop{principal = principal, nickname = fact_nickname, persistence = words})
	case .Kept_By_Machine_Passphrase:
		system.log_fact(.Info, Row_Persistence_Set_Kept_By_Machine_Passphrase{principal = principal, nickname = fact_nickname, persistence = words})
	case .Kept_By_Passphrase:
		system.log_fact(.Info, Row_Persistence_Set_Kept_By_Passphrase{principal = principal, nickname = fact_nickname, persistence = words})
	}
}

// disk_store_limit gives the blocks of the store of a disk process in a
// service: the store of its nickname when its start gave it the grant
// store, and the grant was not revoked; else none.
disk_store_limit :: proc "contextless" (caller: ^Started, service: ^Started) -> u64 {
	if .Store not_in caller.start_grant_set.grants || .Store in caller.revoked || !is_role_holder(system.name_of(service.name[:]), .Storage) {
		return 0
	}
	// The budget that a module asks for has no part for a store yet: the
	// store of a nickname uses disk_process.PRIVATE_STORE_BLOCKS_LIMIT, which
	// no name of the tables of this service changes for a disk process.
	return disk_process.PRIVATE_STORE_BLOCKS_LIMIT
}

// disk_process_running gives the disk process of a nickname that runs in
// the session of a principal, or nil.
disk_process_running :: proc "contextless" (nickname: string, principal: u64) -> ^Started {
	for &item in started {
		if item.process != 0 && item.from_disk && item.principal == principal && system.name_of(item.name[:]) == nickname {
			return &item
		}
	}
	return nil
}

// disk_loader_refusal_log writes the line of a disk process whose file the
// loader refused, then the fact of the load error.
disk_loader_refusal_log :: proc "contextless" (name: string, error: ^module.Load_Error) {
	system.log_fact(.Warning, Disk_Load_Refused_By_Loader{refused_process = module_name_field(name)})
	load_error_log(.Warning, error)
}

// disk_name_refusal gives the outcome of a name that cannot be the name of
// a disk process, with its record in values, or Succeeded,
// with the values of the completion. A process of the boot image has its
// grants, its budget and the name of its store by its name, in the tables
// of this service: a file of a disk with such a name would take them. So
// the name of a disk process is the name of no module of the boot image, of
// no row of those tables and of no process of the system.
disk_name_refusal :: proc "contextless" (name: string, values: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Start_From_Disk)
	problem, offset := disk_process.name_problem(name)
	switch problem {
	case .None:
	case .Empty:
		system.log_fact(.Warning, Disk_Load_Refused_Name_Empty{refused_process = module_name_field(name)})
		return root_ring.refuse(values, .Argument_Refused, kind, .Empty, .Bytes, 1, 0, disk_process.NAME_LIMIT)
	case .Too_Long:
		system.log_fact(.Warning, Disk_Load_Refused_Name_Too_Long{name_limit = u64(disk_process.NAME_LIMIT), refused_process = module_name_field(name)})
		return root_ring.refuse(values, .Argument_Refused, kind, .Too_Long, .Bytes, 1, i64(len(name)), disk_process.NAME_LIMIT)
	case .Bad_Byte:
		system.log_fact(.Warning, Disk_Load_Refused_Name_Not_A_Process_Name{refused_process = module_name_field(name)})
		return root_ring.refuse(values, .Argument_Refused, kind, .Bad_Byte, .None, 1, i64(offset), 0, i64(name[offset]))
	case .Store_Name:
		system.log_fact(.Warning, Disk_Load_Refused_Name_Of_Module_Store{refused_process = module_name_field(name)})
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .Reserved, .None, 1)
	case .Table_Name:
		system.log_fact(.Warning, Disk_Load_Refused_Name_Of_Grant_Table{refused_process = module_name_field(name)})
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .Reserved, .None, 1)
	}
	if name_is_a_system_part(name) || start_grant_set_names_the_process(name) || name_is_a_role_name(name) {
		system.log_fact(.Warning, Disk_Load_Refused_Name_In_Grant_Table{refused_process = module_name_field(name)})
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .Reserved, .None, 1)
	}
	if len(system.image_find(image, name)) != 0 {
		system.log_fact(.Warning, Disk_Load_Refused_Name_In_Boot_Image{refused_process = module_name_field(name)})
		return root_ring.refuse(values, .Name_Already_Taken, kind, .Exists, .Modules, 1)
	}
	return .Succeeded
}

// disk_start_begin runs the command Start_From_Disk of a process with the
// grant Root_Ring. It refuses at once what needs no read, with the values
// of the completion; else it starts the load through the service
// disk_processes, and holds the completion until the load ends (held): the
// loop of this service goes on.
disk_start_begin :: proc "contextless" (asker: ^Started, record: ring.Record, values: ^[7]u64) -> (outcome: call_outcome.Call_Outcome, held: bool) {
	kind := u32(root_ring.Root_Command.Start_From_Disk)
	hash := transmute([disk_process.HASH_SIZE]u8)[4]u64{record.values[0], record.values[1], record.values[2], record.values[3]}
	name_bytes, name_length := disk_process.name_unpack({record.values[4], record.values[5], record.values[6]})
	name := string(name_bytes[:name_length])
	if name_outcome := disk_name_refusal(name, values); name_outcome != .Succeeded {
		return name_outcome, false
	}
	// The nickname rule: two hashes never share a nickname. No hash asked
	// takes the hash of the row of the nickname.
	table := disk_grant_table_of(asker.principal)
	if table == nil {
		system.log_fact(.Warning, Disk_Load_Refused_Asker_Without_Principal{refused_process = module_name_field(name)})
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Principals, 0), false
	}
	file, _, problem_of_the_nickname := disk_process.start_file(table, name, hash)
	switch problem_of_the_nickname {
	case .None, .Absent, .Full, .Not_Held, .Same_File, .Zero_Hash, .Zero_Key, .Bad_Uses, .Start_Policy_Row, .Holds_Store, .Zero_Identifier, .Bad_Machine_Scopes, .Last_System_Grant:
		// start_file gives only None, No_File and Other_File: the start goes on.
	case .No_File:
		system.log_fact(.Warning, Disk_Load_Refused_Nickname_Without_Row{principal = asker.principal, refused_process = module_name_field(name)})
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Grants, 2), false
	case .Other_File:
		head := transmute([4]u64)file
		system.log_fact(.Warning, Disk_Load_Refused_Nickname_Other_File{named_hash = value_kinds.Hash_Field(file), hash = value_kinds.Hash_Field(hash), refused_process = module_name_field(name)})
		return root_ring.refuse(values, .Name_Already_Taken, kind, .Exists, .Grants, 2, i64(head[0])), false
	}
	hash = file
	if disk_load_running() {
		system.log_fact(.Warning, Disk_Load_Refused_Load_Busy{refused_process = module_name_field(name)})
		return root_ring.refuse(values, .Callee_Busy, kind, .Busy, .Requests, 0, 1, 1), false
	}
	// The service disk_processes reads the file, through a connection that
	// reads only to the store `module_files` of the principal of the asker
	// (disk_processes_delegation.odin).
	failure, begun := disk_load_begin(asker, record.tag, name, hash, asker.principal, false, values)
	switch failure {
	case .None:
	case .No_Service:
		system.log_fact(.Warning, Disk_Load_Refused_No_Service{refused_process = module_name_field(name)})
		return begun, false
	case .No_Connection:
		system.log_fact(.Warning, Disk_Load_Refused_No_Connection{outcome = begun, refused_process = module_name_field(name)})
		return begun, false
	case .Not_Given:
		system.log_fact(.Warning, Disk_Load_Refused_Not_Mapped{refused_process = module_name_field(name)})
		return begun, false
	}
	system.log_fact(.Info, Disk_Load_Started{principal = asker.principal, loaded_process = module_name_field(name)})
	return .Succeeded, true
}

// disk_load_start starts the file whose bytes this service checked, with
// the files of the store that the import scan kept beside the boot image.
disk_load_start :: proc "contextless" () {
	load := &disk_load
	kind := u32(root_ring.Root_Command.Start_From_Disk)
	name := string(load.name[:load.name_length])
	found := load.hash
	principal := load.principal
	// The chosen start policy starts with the grant Start_Policy only, and
	// never with the grants of a disk process.
	if load.for_start_policy {
		chosen_error: module.Load_Error
		chosen_status := start_policy_chosen_run(name, disk_load_module(), found, disk_load_files(), &chosen_error)
		if chosen_status != .Succeeded && chosen_error.stage != u32(module.Load_Stage.None) {
			disk_loader_refusal_log(name, &chosen_error)
		} else if chosen_status != .Succeeded {
			system.log_fact(.Warning, Disk_Load_Refused_Not_Started{outcome = system.own_operation_outcome(chosen_status), refused_process = module_name_field(name)})
		}
		disk_load_end(system.own_operation_outcome(chosen_status), {})
		return
	}
	// The grants are read now, not at the command: a change of the table
	// during the load is the table of this start.
	table := disk_grant_table_of(principal)
	if table == nil {
		system.log_fact(.Warning, Disk_Load_Refused_Principal_Without_Record{refused_process = module_name_field(name)})
		disk_load_end(.Nothing_Has_That_Name, errors.ring_fail(kind, .Absent, .Principals, 0))
		return
	}
	file, granted, problem_of_the_nickname := disk_process.start_file(table, name, found)
	if problem_of_the_nickname != .None {
		system.log_fact(.Warning, Disk_Load_Refused_Nickname_Moved{named_hash = value_kinds.Hash_Field(file), found_hash = value_kinds.Hash_Field(found), refused_process = module_name_field(name)})
		disk_load_end(.Another_Change_Came_First, errors.ring_fail(kind, .State, .Grants, 2))
		return
	}
	load_error: module.Load_Error
	run_refusal: [7]u64
	run := disk_process_run(name, disk_load_module(), found, principal, granted, disk_load_files(), &load_error, &run_refusal)
	if run != .Succeeded {
		if load_error.stage != u32(module.Load_Stage.None) {
			// The loader refused the module: its file breaks the format.
			disk_loader_refusal_log(name, &load_error)
			disk_load_end(.Argument_Refused, errors.ring_fail(kind, .Malformed, .None, 1, i64(load_error.file_error)))
		} else {
			system.log_fact(.Warning, Disk_Load_Refused_Not_Started{outcome = run, refused_process = module_name_field(name)})
			disk_load_end(run, run_refusal)
		}
		return
	}
	process_buffer, store_buffer: [32]u8
	with_store := .Store in granted && principals.store_name_write(&store_buffer, disk_process.store_process_name(&process_buffer, name), principal, false)
	started_process := module_name_field(name)
	hash := value_kinds.Hash_Field(found)
	machine_principal := principal == principals.MACHINE
	switch {
	case machine_principal && !with_store:
		system.log_fact(.Info, Disk_Process_Started{started_process = started_process, hash = hash})
	case machine_principal && with_store:
		system.log_fact(.Info, Disk_Process_Started_With_Store{started_process = started_process, hash = hash, store = store_buffer})
	case !with_store:
		system.log_fact(.Info, Disk_Process_Started_In_Session{started_process = started_process, hash = hash, principal = principal, principal_name = text_field(principal_name(principal), 24)})
	case:
		system.log_fact(.Info, Disk_Process_Started_With_Store_In_Session{started_process = started_process, hash = hash, store = store_buffer, principal = principal, principal_name = text_field(principal_name(principal), 24)})
	}
	disk_load_end(.Succeeded, {})
}

// disk_module_imports_fonts reports whether a validated disk module imports
// the boot image's drawing, text_rendering, or interface_module library.
// Bare disk processes such as visitor and core_probe do not import font
// libraries and keep empty storage handle slots in their context.
@(private = "file")
disk_module_imports_fonts :: proc "contextless" (file: []u8) -> bool {
	if module.count(file, .Imports) <= 1 {
		return false
	}
	for index in 1 ..< module.count(file, .Imports) {
		imp, ok := module.record(file, .Imports, index, module.Import)
		if !ok {
			continue
		}
		for &entry in system.image_entries(image) {
			if entry.hash != imp.hash {
				continue
			}
			entry_name := system.name_of(entry.name[:])
			if entry_name == "drawing" || entry_name == "text_rendering" || entry_name == "interface_module" {
				return true
			}
		}
	}
	return false
}

// disk_process_run starts a disk process from the bytes of its file, which
// this service checked. The process receives what each process receives
// and nothing of a start grant set: the log with the right Write, a window, the date
// page, the settings page and the font outlines, read-only. It has no row
// in the tables by name of this service, and the budget of a process that
// no table names. Its grants are the grants of its nickname in the disk
// grant table of its principal: with the grant store, a connection to the
// store of its nickname, in its context as a process of the boot image
// receives its private store. Its modules are copies that its own budget
// pays: it maps no prepared module of this service. store_files are the
// files of the store that the import scan kept: its load source holds them
// beside the boot image.
disk_process_run :: proc "contextless" (name: string, file: []u8, hash: [disk_process.HASH_SIZE]u8, principal: u64, disk_grants: disk_process.Disk_Grants, store_files: []system.Source_File, load_error: ^module.Load_Error, refusal: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Start_From_Disk)
	// The storage service runs before a slot is chosen: a start of it
	// takes the first free slot.
	storage_service: ^Started
	for &item in started {
		if item.process != 0 && item.service.head != nil && is_role_holder(system.name_of(item.name[:]), .Storage) {
			storage_service = &item
		}
	}
	if .Store in disk_grants && storage_service == nil {
		return root_ring.refuse(refusal, .Callee_Unavailable, kind, .Refused, .Services)
	}
	slot: ^Started
	for &item in started {
		if place_is_free(&item) {
			slot = &item
			break
		}
	}
	if slot == nil {
		// The table of the processes frees a place when a process stops.
		return root_ring.refuse(refusal, .Callee_Busy, kind, .Full, .Processes, 0, 0, i64(len(started)))
	}
	slot^ = {}
	// The connection to the storage service names the nickname, its
	// principal, and the grants of its start.
	copy(slot.name[:len(slot.name) - 1], name)
	slot.principal = principal
	slot.from_disk = true
	// Its start grant set is the grants of its row, and never a row of the tables of
	// this service: it has no root ring, so it sends no root command
	// (root_ring.ROOT_RING_GRANTS).
	if .Store in disk_grants {
		slot.start_grant_set = {grants = {.Store}}
	}
	context_grants: system.Context_Grants
	values: system.Context_Values
	system.grant_put(&context_grants, op.CONTEXT_LOG, {system.context_record().handles[op.CONTEXT_LOG], {.Write}})
	status: call_outcome.Call_Outcome
	// This service does not keep the memory of the ring to the compositor.
	display_memory: system.Handle
	defer if display_memory != 0 {
		system.close(display_memory)
	}
	// With no screen, or in a console image with no window server, the
	// process gets no window, as a process of the boot image
	// (start_view_give).
	if !desktop_absent() && console_renderer == .Desktop_Terminal {
		if display_memory, status = system.memory_create(ring.PAGE_COUNT); status != .Succeeded {
			return kernel_refused(refusal, kind, status)
		}
		client: system.Handle
		if client, status = system.give(display_holder, display_memory, {.Read, .Write}); status != .Succeeded {
			return kernel_refused(refusal, kind, status)
		}
		slot.client = client
		// The compositor names the window by the nickname, beside the hash
		// prefix of the file that this service checked: the process does not
		// choose the name that the menu of the windows shows.
		nickname := disk_process.name_pack(name)
		system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Add), values = {0 = u64(client), 1 = nickname[0], 2 = nickname[1], 3 = nickname[2], 4 = process_page.hash_head(hash)}})
		system.grant_put(&context_grants, system.GRANT_DISPLAY, {display_memory, {.Read, .Write}})
	}
	// The date page, the fresh bytes page, the settings page, five glyph
	// caches, the font outlines, the file of the storage service.
	mappings: [11]system.Mapping
	mapping_count := 0
	date_page_give(mappings[:], &mapping_count, &values)
	fresh_bytes_page_give(slot, mappings[:], &mapping_count, &values)
	measure_run_value_give(&values)
	text_settings_give(mappings[:], &mapping_count, &values, .Presentation, slot)
	// The store of the nickname, as start() gives a private store: the call
	// ring, the call region, the storage service with the right Read, and
	// its file. This service closes its handles of the connection after the
	// start.
	store_ring, store_region: system.Handle
	defer if store_ring != 0 {
		system.close(store_ring)
		system.close(store_region)
	}
	wants_disk_store := .Store in disk_grants
	fonts_only := !wants_disk_store && storage_service != nil && slot.client != 0 && disk_module_imports_fonts(file)
	if wants_disk_store || fonts_only {
		store_outcome: call_outcome.Call_Outcome
		open_refusal: [7]u64
		_, _, store_ring, store_region, store_outcome = connection_open(slot, role_holder_name(.Storage), fonts_only ? &open_refusal : refusal, kind, fonts_only = fonts_only)
		if store_outcome != .Succeeded {
			if !fonts_only {
				release(slot) // The compositor forgets the ring.
				return store_outcome
			}
		} else {
			system.grant_put(&context_grants, system.GRANT_STORAGE_RING, {store_ring, {.Read, .Write}})
			system.grant_put(&context_grants, system.GRANT_STORAGE_REGION, {store_region, {.Read, .Write}})
			system.grant_put(&context_grants, system.GRANT_STORAGE_SERVICE, {storage_service.process, {.Read}})
			if fonts_only {
				system.value_put(&values, system.GRANT_VALUE_STORAGE_FONTS_ONLY, 1)
			}
			for &item in system.image_entries(image) {
				if is_role_holder(system.name_of(item.name[:]), .Storage) && item.offset % system.PAGE_SIZE == 0 && item.offset <= u64(len(image)) && item.size <= u64(len(image)) - item.offset {
					mapping, given := image_entry_mapping(&item, storage.FILE_ADDRESS)
					if !given {
						// The file of the storage service does not have the hash
						// of its entry (image_entry_mapping names it on the log):
						// the disk process would read a file that nothing
						// checked, so it does not start, and its slot and its
						// ring are freed as for any abandoned start.
						release(slot)
						return root_ring.refuse(refusal, .Data_Damaged, kind, .Damaged, .Modules)
					}
					system.value_put(&values, system.GRANT_VALUE_STORAGE_FILE_SIZE, item.size)
					mappings[mapping_count] = mapping
					mapping_count += 1
				}
			}
		}
	}
	process: system.Handle
	process_budget: Start_Budget
	// Its request, up to the largest budget of a disk process, paid by the
	// one budget of the disk processes: a file of a disk cannot take what
	// the processes of the boot image need. Its name selects no exception.
	disk_processes: system.Handle
	disk_processes, status = disk_processes_budget_get(name)
	if status == .Succeeded && context_refused(name, &context_grants, &values) {
		// Two grants in one slot, or one value written twice: the table of
		// the grants is damaged.
		release(slot)
		return root_ring.refuse(refusal, .Data_Damaged, kind, .Damaged, .Records)
	}
	if status == .Succeeded {
		budget_ok: bool
		if process_budget, budget_ok = disk_budget_of(file, name, disk_processes); !budget_ok {
			status = .Budget_Or_Capacity_Exhausted
		} else {
			source := load_source()
			source.files = store_files
			process, status = system.process_start(file, name, context_grants.grants, random.values_with_seed(&process_generator, values.values), process_budget.amounts, mappings[:mapping_count], nil, source, load_error, disk_processes, ready = &slot.ready)
			if status == .Budget_Or_Capacity_Exhausted {
				budget_refusal_log(name, process_budget.amounts, disk_processes, "the disk processes")
			}
		}
	}
	if status != .Succeeded {
		release(slot) // The compositor forgets the ring, and the connection ends.
		return kernel_refused(refusal, kind, status)
	}
	slot.process = process
	slot.hash = hash
	slot.granted += {.Log}
	session_table_record_slot(slot)
	start_budget_note(slot, process_budget)
	disk_process_page_add(slot)
	return .Succeeded
}

// disk_grant_change runs the command Disk_Grant: the principal of the
// caller gives a grant to the file that a nickname names, or takes it. The
// caller acts for its principal, and changes the table of that principal
// only. values is the completion: an error record for a refusal.
disk_grant_change :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Disk_Grant)
	nickname_bytes, nickname_length := disk_process.name_unpack({record.values[0], record.values[1], record.values[2]})
	nickname := string(nickname_bytes[:nickname_length])
	action, action_outcome, action_refusal := root_ring.member_of_word(root_ring.Disk_Grant_Action, record.values[4], .Disk_Grant, 0)
	if action_outcome != .Succeeded {
		values^ = action_refusal
		return action_outcome
	}
	if grants_manage_only(caller) {
		// Grants_Manage only revokes remembered disk grants; it can never mint
		// new grants via Allow.
		if action != .Disallow {
			return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .No_Grant, .Grants, 1)
		}
	} else if .Acts_For_Principal not_in grants_held(caller) {
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .No_Grant, .Acts_For_Principal, 1)
	}
	number := record.values[5]
	asked, known := enum_word.member_of_word(start_grant.Grant, number)
	if !known {
		return root_ring.refuse(values, .Argument_Refused, kind, .Bad_Value, .None, 2, i64(min(number, 1 << 62)), i64(max(start_grant.Grant)))
	}
	asked_name := start_grant.GRANT_NAMES[asked]
	grant, answer := disk_process.grant_by_command(asked)
	switch answer {
	case .Given:
	case .Never:
		system.log_fact(.Warning, Disk_Grant_Refused_Never{nickname = module_name_field(nickname), grant = text_field(asked_name, 24)})
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .Reserved, .Grants, 2, i64(number))
	case .Not_Built:
		system.log_fact(.Warning, Disk_Grant_Refused_Not_Built{nickname = module_name_field(nickname), grant = text_field(asked_name, 24)})
		return root_ring.refuse(values, .Operation_Unsupported, kind, .Unsupported, .Grants, 2, i64(number))
	}
	problem_of_the_name, offset := disk_process.nickname_grant_problem(nickname)
	switch problem_of_the_name {
	case .None:
	case .Empty:
		return root_ring.refuse(values, .Argument_Refused, kind, .Empty, .Bytes, 1, 0, disk_process.NAME_LIMIT)
	case .Too_Long:
		return root_ring.refuse(values, .Argument_Refused, kind, .Too_Long, .Bytes, 1, i64(nickname_length), disk_process.NAME_LIMIT)
	case .Bad_Byte:
		system.log_fact(.Warning, Disk_Grant_Refused_Nickname_Characters{nickname = module_name_field(nickname), grant = text_field(asked_name, 24)})
		return root_ring.refuse(values, .Argument_Refused, kind, .Bad_Byte, .None, 1, i64(offset), 0, i64(offset < len(nickname) ? nickname[offset] : 0))
	case .Store_Name, .Table_Name:
		system.log_fact(.Warning, Disk_Grant_Refused_Reserved_Name{nickname = module_name_field(nickname), grant = text_field(asked_name, 24)})
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .Reserved, .None, 1)
	}
	table := disk_grant_table_of(caller.principal)
	if table == nil {
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Principals, 0)
	}
	if persisted_table_refusal(caller.principal) {
		return root_ring.refuse(values, .Wrong_State, kind, .State)
	}
	grant_name := disk_process.disk_grant_names[grant]
	if action == .Disallow {
		row := disk_process.table_find(table, nickname)
		problem := disk_process.table_disallow(table, nickname, grant)
		if problem != .None {
			return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Grants, problem == .Absent ? 1 : 2)
		}
		grant_lost_log(caller.principal, row.hash, nickname, grant_name)
		persisted_table_changed(caller.principal)
		return .Succeeded
	}
	// The hash that the nickname names now: its row, else the disk process
	// of the nickname that runs, whose bytes this service checked.
	hash: [disk_process.HASH_SIZE]u8
	if row := disk_process.table_find(table, nickname); row != nil {
		hash = row.hash
	} else if running := disk_process_running(nickname, caller.principal); running != nil {
		hash = running.hash
	} else {
		system.log_fact(.Warning, Disk_Grant_Refused_No_Row{principal = caller.principal, nickname = module_name_field(nickname), grant = text_field(grant_name, 24)})
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Processes, 1)
	}
	// The name of the store must fit: a cut name can be the name of
	// another store.
	process_buffer, store_buffer: [32]u8
	if grant == .Store && !principals.store_name_write(&store_buffer, disk_process.store_process_name(&process_buffer, nickname), caller.principal, false) {
		system.log_fact(.Warning, Disk_Grant_Refused_Store_Name{principal = caller.principal, nickname = module_name_field(nickname)})
		return root_ring.refuse(values, .Argument_Refused, kind, .Too_Long, .Bytes, 1, i64(nickname_length), i64(len(store_buffer) - 1))
	}
	switch disk_process.table_allow(table, nickname, hash, grant) {
	case .None:
	case .Full:
		return root_ring.refuse(values, .Budget_Or_Capacity_Exhausted, kind, .Full, .Grants, 0, 0, disk_process.ROW_CAPACITY)
	case .Start_Policy_Row:
		// The chosen start policy holds its one start grant and nothing
		// else (src/md/features/start_policy.md).
		system.log_fact(.Warning, Disk_Grant_Refused_Start_Policy{nickname = module_name_field(nickname), grant = text_field(grant_name, 24)})
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .Reserved, .Grants, 1)
	case .No_File, .Other_File, .Absent, .Not_Held, .Same_File, .Zero_Hash, .Zero_Key, .Bad_Uses, .Holds_Store, .Zero_Identifier, .Bad_Machine_Scopes, .Last_System_Grant:
		return root_ring.refuse(values, .Wrong_State, kind, .State)
	}
	grant_given_log(caller.principal, hash, nickname, grant_name)
	persisted_table_changed(caller.principal)
	return .Succeeded
}

// nickname_move runs the command Nickname_Move: a nickname of the table of
// the principal of the caller points to another file, and its grants and
// its store follow. The log says it before the change. A process of the
// nickname that runs keeps the grants of its start.
nickname_move :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Nickname_Move)
	hash := transmute([disk_process.HASH_SIZE]u8)[4]u64{record.values[0], record.values[1], record.values[2], record.values[3]}
	nickname_bytes, nickname_length := disk_process.name_unpack({record.values[4], record.values[5], record.values[6]})
	nickname := string(nickname_bytes[:nickname_length])
	if .Acts_For_Principal not_in grants_held(caller) {
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .No_Grant, .Acts_For_Principal, 1)
	}
	table := disk_grant_table_of(caller.principal)
	if table == nil {
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Principals, 0)
	}
	if persisted_table_refusal(caller.principal) {
		return root_ring.refuse(values, .Wrong_State, kind, .State)
	}
	row := disk_process.table_find(table, nickname)
	if row == nil {
		system.log_fact(.Warning, Nickname_Move_Refused_No_Row{principal = caller.principal, nickname = module_name_field(nickname)})
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Grants, 1)
	}
	if hash == {} || hash == row.hash {
		return root_ring.refuse(values, .Argument_Refused, kind, .Bad_Value, .None, 2)
	}
	// The chosen start policy names the file that principal 0 chose: only
	// a new choice changes it.
	if .Start_Policy in row.grants {
		system.log_fact(.Warning, Nickname_Move_Refused_Start_Policy{nickname = module_name_field(nickname)})
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .Reserved, .Grants, 1)
	}
	system.log_fact(.Info, Nickname_Move_Announced{hash = value_kinds.Hash_Field(hash), nickname = module_name_field(nickname)})
	if disk_process.table_move(table, nickname, hash) != .None {
		return root_ring.refuse(values, .Wrong_State, kind, .State)
	}
	nickname_moved_log(caller.principal, hash, nickname)
	persisted_table_changed(caller.principal)
	return .Succeeded
}

// The words of a setting of persistence, as the log writes them.
@(rodata)
persistence_words := [disk_process.Persistence]string {
	.Global  = "the global setting",
	.Persist = "persist across a restart",
	.Forget  = "last until the machine stops",
}

// disk_grant_persistence runs the command Disk_Grant_Persistence: how long
// a row of the table of the principal of the caller lasts, or with no
// nickname the global setting. The caller acts for its principal. The
// table is written after the change when the principal keeps it on the
// disk: a row that now lasts until the machine stops leaves the disk.
disk_grant_persistence :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Disk_Grant_Persistence)
	nickname_bytes, nickname_length := disk_process.name_unpack({record.values[0], record.values[1], record.values[2]})
	nickname := string(nickname_bytes[:nickname_length])
	if .Acts_For_Principal not_in grants_held(caller) {
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .No_Grant, .Acts_For_Principal, 1)
	}
	setting := record.values[4]
	persistence, persistence_ok := enum_word.member_of_word(disk_process.Persistence, setting)
	if !persistence_ok || nickname == "" && persistence == .Global {
		return root_ring.refuse(values, .Argument_Refused, kind, .Bad_Value, .None, 2, i64(min(setting, 1 << 62)), i64(max(disk_process.Persistence)))
	}
	table := disk_grant_table_of(caller.principal)
	if table == nil {
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Principals, 0)
	}
	if persisted_table_refusal(caller.principal) {
		return root_ring.refuse(values, .Wrong_State, kind, .State)
	}
	switch disk_process.table_persistence_set(table, nickname, persistence) {
	case .None:
	case .Start_Policy_Row:
		system.log_fact(.Warning, Persistence_Refused_Start_Policy{nickname = module_name_field(nickname)})
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .Reserved, .Grants, 1)
	case .Absent, .No_File, .Other_File, .Full, .Not_Held, .Same_File, .Zero_Hash, .Zero_Key, .Bad_Uses, .Holds_Store, .Zero_Identifier, .Bad_Machine_Scopes, .Last_System_Grant:
		system.log_fact(.Warning, Persistence_Refused_No_Row{principal = caller.principal, nickname = module_name_field(nickname)})
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Grants, 1)
	}
	if nickname == "" {
		table_persistence_log(caller.principal, persistence_words[persistence])
	} else {
		row_persistence_log(caller.principal, nickname, persistence_words[persistence])
	}
	persisted_table_changed(caller.principal)
	return .Succeeded
}
