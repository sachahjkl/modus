package host

import module "modus:contract/module"
import "modus:system"

// The log facts of the call host (src/md/features/log_facts.md): the module
// that it loaded, and the grants that it lacks, as records of fields. Each
// fact template is the sentence that the line wrote before it was a fact.
// No field has the name of a column of the head of facts(): number, time,
// process, level.

// The call host loaded its module, and serves its exports.
@(log_fact = "host: ready, {exports} exports")
Ready :: struct {
	exports: u64,
}

// The ring or the region of the calls does not open.
@(log_fact = "host: no call ring or no call region")
No_Call_Ring_Or_Region :: struct {}

// The call region has no size.
@(log_fact = "host: the call region has no size")
Call_Region_Without_Size :: struct {}

// The load of the module failed: one fact type for each stage, a distinct
// type of the shape of the stage in the contract module, whose fields are
// the names, the heads of the hashes and what failed
// (src/md/features/log_facts.md, "The load error as facts"). A name that
// the load error does not hold is an empty text; a hash that it does not
// hold is a head of zeros.

// The load source has no file of the module or of one of its imports.
@(log_fact = "host: cannot load the module: the load of {module_name} ({module_hash}) found no file of its import {imported_name} ({imported_hash})")
Load_Find_Failed :: distinct module.Load_Find_Fields

// A file does not have the hash that names it, or is not a valid module.
@(log_fact = "host: cannot load the module: the file of {subject_name} ({subject_hash}) is refused: {file_error}")
Load_Read_Failed :: distinct module.Load_Read_Fields

// A module imports itself through its imports, by a replacement.
@(log_fact = "host: cannot load the module: an import cycle: {module_name} imports {imported_name}, and {replacement_name} still loads its imports")
Load_Cycle_Failed :: distinct module.Load_Cycle_Fields

// An export of a replacement fails the check against the import.
@(log_fact = "host: cannot load the module: {module_name} imports {imported_name}, and the export {export} of its replacement fails the check: {difference}, parameter {parameter}")
Load_Check_Failed :: distinct module.Load_Check_Fields

// An import slot of a module cannot be bound.
@(log_fact = "host: cannot load the module: import slot {import_slot} of {module_name} cannot be bound: export {export} of {imported_name}")
Load_Bind_Failed :: distinct module.Load_Bind_Fields

// The kernel refused to map the memory of a module.
@(log_fact = "host: cannot load the module: the kernel refused to map {module_name} ({module_hash}): status {status}")
Load_Map_Failed :: distinct module.Load_Memory_Fields

// The kernel refused to remove a module.
@(log_fact = "host: cannot load the module: the kernel refused to remove {module_name} ({module_hash}): status {status}")
Load_Unmap_Failed :: distinct module.Load_Memory_Fields

// The loader has no room for one more module.
@(log_fact = "host: cannot load the module: no room for {module_name} ({module_hash}): a process has 16 modules at most, a module 8 imports, a table of prepared modules 64 parts, and its modules fit below the fixed ranges of the system")
Load_Room_Failed :: distinct module.Load_Room_Fields

// The load failed with no stage: the loader wrote no error.
@(log_fact = "host: cannot load the module: the load error names no stage")
Load_Failed_Without_Stage :: struct {}

// load_failure_log writes the fact of a load error, by its stage.
load_failure_log :: proc "contextless" (error: ^module.Load_Error) {
	stage, stage_ok := module.load_stage_of_word(error.stage)
	if !stage_ok {
		system.log_fact(.Info, Load_Failed_Without_Stage{})
		return
	}
	switch stage {
	case .None:
		system.log_fact(.Info, Load_Failed_Without_Stage{})
	case .Find:
		system.log_fact(.Info, Load_Find_Failed(module.load_find_fact_fields(error)))
	case .Read:
		system.log_fact(.Info, Load_Read_Failed(module.load_read_fact_fields(error)))
	case .Cycle:
		system.log_fact(.Info, Load_Cycle_Failed(module.load_cycle_fact_fields(error)))
	case .Check:
		system.log_fact(.Info, Load_Check_Failed(module.load_check_fact_fields(error)))
	case .Bind:
		system.log_fact(.Info, Load_Bind_Failed(module.load_bind_fact_fields(error)))
	case .Map:
		system.log_fact(.Info, Load_Map_Failed(module.load_memory_fact_fields(error)))
	case .Unmap:
		system.log_fact(.Info, Load_Unmap_Failed(module.load_memory_fact_fields(error)))
	case .Room:
		system.log_fact(.Info, Load_Room_Failed(module.load_room_fact_fields(error)))
	}
}
