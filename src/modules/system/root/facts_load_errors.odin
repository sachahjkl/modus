package root

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:system"

// The log facts of a load that the loader refused
// (src/md/features/log_facts.md, "The load error as facts"). A line of the
// root service says which start failed; the fact of the load error after it
// holds the fields of its stage, one fact type for each stage, with the
// shapes of the contract module. The sentence is the form of the fields:
// a name is empty and a hash is zero where the stage names no import.

// The compositor did not load: the fact of the load error follows.
@(log_fact = "root: cannot load the compositor: the loader refused it")
Compositor_Load_Refused :: struct {}

// The terminal did not load: the fact of the load error follows.
@(log_fact = "root: cannot load the terminal: the loader refused it")
Terminal_Load_Refused :: struct {}

// A process did not start: the fact of the load error follows.
@(log_fact = "root: cannot start {refused_process}: the loader refused it")
Start_Refused_By_Loader :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

// A disk process did not start: the fact of the load error follows.
@(log_fact = "root: refused {refused_process} from the disk: the loader refused its file")
Disk_Load_Refused_By_Loader :: struct {
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: the load source has no file of the import {imported_name} ({imported_hash}) of {module_name} ({module_hash})")
Load_Find_Failed :: distinct module.Load_Find_Fields

@(log_fact = "root: the file of {subject_name} ({subject_hash}) is not a valid module, or not the file of its hash: {file_error}")
Load_Read_Failed :: distinct module.Load_Read_Fields

@(log_fact = "root: {module_name} imports itself through {imported_name}, by the replacement {replacement_name}")
Load_Cycle_Failed :: distinct module.Load_Cycle_Fields

@(log_fact = "root: the replacement of the import {imported_name} of {module_name} differs in its export {export}: {difference}, parameter {parameter}")
Load_Check_Failed :: distinct module.Load_Check_Fields

@(log_fact = "root: the import slot {import_slot} of {module_name} names no import or no export, or is not in writable data: the import {imported_name}, the export {export}")
Load_Bind_Failed :: distinct module.Load_Bind_Fields

@(log_fact = "root: the map of the memory of {module_name} ({module_hash}) failed: status {status}")
Load_Map_Failed :: distinct module.Load_Memory_Fields

@(log_fact = "root: the removal of {module_name} ({module_hash}) failed: status {status}")
Load_Unmap_Failed :: distinct module.Load_Memory_Fields

@(log_fact = "root: no room for {module_name} ({module_hash}): the module space, the imports of one module or the table of the loader is full")
Load_Room_Failed :: distinct module.Load_Room_Fields

// load_error_log writes the fact of a load error by its stage. A stage None
// is no error: it writes nothing.
load_error_log :: proc "contextless" (level: op.Log_Level, error: ^module.Load_Error) {
	stage, stage_ok := module.load_stage_of_word(error.stage)
	if !stage_ok {
		return
	}
	switch stage {
	case .None:
	case .Find:
		system.log_fact(level, Load_Find_Failed(module.load_find_fact_fields(error)))
	case .Read:
		system.log_fact(level, Load_Read_Failed(module.load_read_fact_fields(error)))
	case .Cycle:
		system.log_fact(level, Load_Cycle_Failed(module.load_cycle_fact_fields(error)))
	case .Check:
		system.log_fact(level, Load_Check_Failed(module.load_check_fact_fields(error)))
	case .Bind:
		system.log_fact(level, Load_Bind_Failed(module.load_bind_fact_fields(error)))
	case .Map:
		system.log_fact(level, Load_Map_Failed(module.load_memory_fact_fields(error)))
	case .Unmap:
		system.log_fact(level, Load_Unmap_Failed(module.load_memory_fact_fields(error)))
	case .Room:
		system.log_fact(level, Load_Room_Failed(module.load_room_fact_fields(error)))
	}
}
