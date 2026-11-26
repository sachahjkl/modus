package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import debug_object "modus:contract/debug_object"
import module "modus:contract/module"
import "modustool:foundation"

@(private = "file")
odin_core_test_temp_dir :: proc(t: ^testing.T, label: string) -> string {
	temp_base, _ := os.temp_dir(context.temp_allocator)
	if temp_base == "" {
		temp_base = "/tmp"
	}
	dir := fmt.tprintf("%s/modus_odin_core_%s_%d", strings.trim_right(temp_base, "/"), label, os.get_pid())
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil, "create temporary test directory")
	return dir
}

@(private = "file")
run_odin_modus_check :: proc(dir: string) -> (ok: bool, output: string) {
	command := [?]string {
		"odin",
		"check",
		dir,
		"-no-entry-point",
		"-target:modus_amd64",
		"-collection:modus=" + foundation.SOURCE_FOLDER_PUBLIC,
		"-custom-attribute:log_fact,enum_getters,member_texts,parameter_ranges,parameter_choices,parameter_instances",
	}
	state, stdout, stderr, err := os.process_exec({command = command[:]}, context.temp_allocator)
	combined := fmt.tprintf("%s%s", string(stdout), string(stderr))
	return err == nil && state.exited && state.success, combined
}

// Verifies that core:sys/modus ABI constants, fixed addresses, enum values,
// struct sizes, and struct field offsets match modus:contract/*.
@(test)
core_sys_modus_abi_matches_modus_contracts :: proc(t: ^testing.T) {
	root := odin_core_test_temp_dir(t, "abi")
	defer _ = os.remove_all(root)

	// Refusal first: an intentional ABI mismatch must fail odin check.
	refusal_dir := foundation.join(root, "/refusal")
	testing.expect(t, os.make_directory_all(refusal_dir) == nil)
	testing.expect(t, os.write_entire_file(foundation.join(refusal_dir, "/check.odin"), `package abi_refusal

import "core:sys/modus"
import op "modus:contract/operation"

#assert(modus.PAGE_SIZE == op.PAGE_SIZE + 1)
`) == nil)
	refusal_ok, _ := run_odin_modus_check(refusal_dir)
	testing.expect(t, !refusal_ok, "intentional ABI mismatch must fail odin check")

	// Full parity check compiled under -target:modus_amd64 where both
	// core:sys/modus and modus:contract/* are visible.
	parity_dir := foundation.join(root, "/parity")
	testing.expect(t, os.make_directory_all(parity_dir) == nil)
	testing.expect(t, os.write_entire_file(foundation.join(parity_dir, "/check.odin"), `package abi_parity

import "core:sys/modus"
import "modus:contract/call_outcome"
import "modus:contract/date"
import "modus:contract/errors"
import "modus:contract/fixed_addresses"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:system"

// Fixed constants and addresses.
#assert(modus.PAGE_SIZE == op.PAGE_SIZE)
#assert(modus.WAIT_FOREVER == op.WAIT_FOREVER)
#assert(modus.THREAD_CAPACITY == op.THREAD_CAPACITY)
#assert(modus.THREAD_AREA_PAGES == op.THREAD_AREA_PAGES)
#assert(modus.THREAD_STACK_PAGES == op.THREAD_STACK_PAGES)
#assert(modus.MEMORY_PAGE_LIMIT == op.MEMORY_PAGE_LIMIT)
#assert(modus.RANGE_TABLE_CAPACITY == op.RANGE_TABLE_CAPACITY)
#assert(modus.RANGE_TABLE_PAGE_LIMIT == op.RANGE_TABLE_PAGE_LIMIT)
#assert(modus.LOG_TEXT_BYTES_MOST == op.LOG_TEXT_BYTES_MOST)
#assert(modus.PROCESS_BASE == op.PROCESS_BASE)
#assert(modus.CHOSEN_BASE == op.CHOSEN_BASE)
#assert(modus.MODULE_BASE == op.MODULE_BASE)
#assert(modus.BAND_START == fixed_addresses.BAND_START)
#assert(modus.SLOT == fixed_addresses.SLOT)
#assert(modus.DATE_PAGE_ADDRESS == fixed_addresses.DATE_PAGE_ADDRESS)
#assert(modus.STORAGE_FILE_ADDRESS == fixed_addresses.STORAGE_FILE_ADDRESS)
#assert(modus.TIME_ADDRESS == op.TIME_ADDRESS)
#assert(modus.USER_END == op.USER_END)
#assert(modus.THREAD_AREA_BASE == op.THREAD_AREA_BASE)
#assert(modus.CONTEXT_ADDRESS == op.CONTEXT_ADDRESS)
#assert(modus.STACK_TOP == op.STACK_TOP)

// Context slots and values.
#assert(modus.CONTEXT_HANDLES == op.CONTEXT_HANDLES)
#assert(modus.CONTEXT_VALUES == op.CONTEXT_VALUES)
#assert(modus.CONTEXT_LOG == op.CONTEXT_LOG)
#assert(modus.CONTEXT_BUDGET == op.CONTEXT_BUDGET)
#assert(modus.CONTEXT_WIRING_RING == op.CONTEXT_WIRING_RING)
#assert(modus.CONTEXT_LOG_OUTPUT == op.CONTEXT_LOG_OUTPUT)
#assert(modus.CONTEXT_LOG_OUTPUT_END == op.CONTEXT_LOG_OUTPUT_END)
#assert(modus.CONTEXT_READY_RING == op.CONTEXT_READY_RING)
#assert(modus.GRANT_STORAGE_RING == system.GRANT_STORAGE_RING)
#assert(modus.GRANT_STORAGE_REGION == system.GRANT_STORAGE_REGION)
#assert(modus.GRANT_STORAGE_SERVICE == system.GRANT_STORAGE_SERVICE)
#assert(modus.CONTEXT_VALUE_STORAGE_FILE_SIZE == system.GRANT_VALUE_STORAGE_FILE_SIZE)
#assert(modus.CONTEXT_VALUE_SEED == op.CONTEXT_VALUE_SEED)
#assert(modus.CONTEXT_VALUE_SEED_COUNT == op.CONTEXT_VALUE_SEED_COUNT)
#assert(modus.CONTEXT_VALUE_FIXED_RANGES_MAPPED == op.CONTEXT_VALUE_FIXED_RANGES_MAPPED)

// Ring, root, fault, and date constants.
#assert(modus.RING_CAPACITY == ring.CAPACITY)
#assert(modus.RING_PAGE_COUNT == ring.PAGE_COUNT)
#assert(modus.RING_CAPACITY_LIMIT == ring.CAPACITY_LIMIT)
#assert(modus.ROOT_COMMAND_READY == u32(root_ring.Root_Command.Ready))
#assert(modus.FAULT_RECORD_CAPACITY == op.FAULT_RECORD_CAPACITY)
#assert(modus.DATE_MILLISECONDS_LIMIT == date.DATE_MILLISECONDS_LIMIT)
#assert(modus.DATE_READ_TRIES == date.READ_TRIES)

// Operation enum: member count and every member value.
#assert(len(modus.Operation) == len(op.Operation))
#assert(u32(modus.Operation.None) == u32(op.Operation.None))
#assert(u32(modus.Operation.Log) == u32(op.Operation.Log))
#assert(u32(modus.Operation.Memory_Create) == u32(op.Operation.Memory_Create))
#assert(u32(modus.Operation.Memory_Map) == u32(op.Operation.Memory_Map))
#assert(u32(modus.Operation.Memory_Unmap) == u32(op.Operation.Memory_Unmap))
#assert(u32(modus.Operation.Memory_Size) == u32(op.Operation.Memory_Size))
#assert(u32(modus.Operation.Process_Create) == u32(op.Operation.Process_Create))
#assert(u32(modus.Operation.Process_Start) == u32(op.Operation.Process_Start))
#assert(u32(modus.Operation.Process_Stop) == u32(op.Operation.Process_Stop))
#assert(u32(modus.Operation.Process_State) == u32(op.Operation.Process_State))
#assert(u32(modus.Operation.Handle_Give) == u32(op.Operation.Handle_Give))
#assert(u32(modus.Operation.Handle_Close) == u32(op.Operation.Handle_Close))
#assert(u32(modus.Operation.Interrupt_Read) == u32(op.Operation.Interrupt_Read))
#assert(u32(modus.Operation.Device_Create) == u32(op.Operation.Device_Create))
#assert(u32(modus.Operation.Inspect) == u32(op.Operation.Inspect))
#assert(u32(modus.Operation.Machine_Stop) == u32(op.Operation.Machine_Stop))
#assert(u32(modus.Operation.Thread_Create) == u32(op.Operation.Thread_Create))
#assert(u32(modus.Operation.Thread_Stop) == u32(op.Operation.Thread_Stop))
#assert(u32(modus.Operation.Thread_State) == u32(op.Operation.Thread_State))
#assert(u32(modus.Operation.Word_Wait) == u32(op.Operation.Word_Wait))
#assert(u32(modus.Operation.Word_Wake) == u32(op.Operation.Word_Wake))
#assert(u32(modus.Operation.Budget_Create) == u32(op.Operation.Budget_Create))
#assert(u32(modus.Operation.Budget_Read) == u32(op.Operation.Budget_Read))
#assert(u32(modus.Operation.Handle_State) == u32(op.Operation.Handle_State))
#assert(u32(modus.Operation.Handle_Revoke) == u32(op.Operation.Handle_Revoke))
#assert(u32(modus.Operation.Memory_Physical) == u32(op.Operation.Memory_Physical))
#assert(u32(modus.Operation.Process_Module) == u32(op.Operation.Process_Module))
#assert(u32(modus.Operation.Strategy_Set) == u32(op.Operation.Strategy_Set))
#assert(u32(modus.Operation.Memory_Commit) == u32(op.Operation.Memory_Commit))
#assert(u32(modus.Operation.Memory_Protect) == u32(op.Operation.Memory_Protect))
#assert(u32(modus.Operation.Fault_Handler_Set) == u32(op.Operation.Fault_Handler_Set))
#assert(u32(modus.Operation.Fault_Answer) == u32(op.Operation.Fault_Answer))
#assert(u32(modus.Operation.Events_Set) == u32(op.Operation.Events_Set))
#assert(u32(modus.Operation.Thread_Control) == u32(op.Operation.Thread_Control))
#assert(u32(modus.Operation.Guest_Run) == u32(op.Operation.Guest_Run))
#assert(u32(modus.Operation.Log_Read) == u32(op.Operation.Log_Read))
#assert(u32(modus.Operation.Memory_Read) == u32(op.Operation.Memory_Read))

// Call_Outcome enum: member count and every member value.
#assert(len(modus.Call_Outcome) == len(call_outcome.Call_Outcome))
#assert(u64(modus.Call_Outcome.Succeeded) == u64(call_outcome.Call_Outcome.Succeeded))
#assert(u64(modus.Call_Outcome.Argument_Refused) == u64(call_outcome.Call_Outcome.Argument_Refused))
#assert(u64(modus.Call_Outcome.Nothing_Has_That_Name) == u64(call_outcome.Call_Outcome.Nothing_Has_That_Name))
#assert(u64(modus.Call_Outcome.Name_Already_Taken) == u64(call_outcome.Call_Outcome.Name_Already_Taken))
#assert(u64(modus.Call_Outcome.Grant_Or_Right_Missing) == u64(call_outcome.Call_Outcome.Grant_Or_Right_Missing))
#assert(u64(modus.Call_Outcome.Callee_Busy) == u64(call_outcome.Call_Outcome.Callee_Busy))
#assert(u64(modus.Call_Outcome.Budget_Or_Capacity_Exhausted) == u64(call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted))
#assert(u64(modus.Call_Outcome.Wrong_State) == u64(call_outcome.Call_Outcome.Wrong_State))
#assert(u64(modus.Call_Outcome.Another_Change_Came_First) == u64(call_outcome.Call_Outcome.Another_Change_Came_First))
#assert(u64(modus.Call_Outcome.Operation_Unsupported) == u64(call_outcome.Call_Outcome.Operation_Unsupported))
#assert(u64(modus.Call_Outcome.Data_Damaged) == u64(call_outcome.Call_Outcome.Data_Damaged))
#assert(u64(modus.Call_Outcome.Callee_Unavailable) == u64(call_outcome.Call_Outcome.Callee_Unavailable))
#assert(u64(modus.Call_Outcome.Stopped_After_A_Partial_Change) == u64(call_outcome.Call_Outcome.Stopped_After_A_Partial_Change))
#assert(u64(modus.Call_Outcome.Callee_Stopped_During_The_Call) == u64(call_outcome.Call_Outcome.Callee_Stopped_During_The_Call))
#assert(u64(modus.Call_Outcome.Connection_Ended_During_The_Call) == u64(call_outcome.Call_Outcome.Connection_Ended_During_The_Call))
#assert(u64(modus.Call_Outcome.Deadline_Passed_During_The_Call) == u64(call_outcome.Call_Outcome.Deadline_Passed_During_The_Call))
#assert(u64(modus.Call_Outcome.Answer_Unreadable) == u64(call_outcome.Call_Outcome.Answer_Unreadable))

// Rights, object kinds, states, flags, and fixed ranges.
#assert(len(modus.Right) == len(op.Right))
#assert(u32(modus.Right.Give) == u32(op.Right.Give))
#assert(u32(modus.Right.Read) == u32(op.Right.Read))
#assert(u32(modus.Right.Write) == u32(op.Right.Write))
#assert(u32(modus.Right.Execute) == u32(op.Right.Execute))
#assert(u32(modus.Right.Control) == u32(op.Right.Control))
#assert(u32(modus.Right.Inspect) == u32(op.Right.Inspect))
#assert(u32(modus.Right.Devices) == u32(op.Right.Devices))
#assert(u32(modus.Right.Stop) == u32(op.Right.Stop))
#assert(u32(modus.Right.Spend) == u32(op.Right.Spend))
#assert(u32(modus.Right.Physical) == u32(op.Right.Physical))
#assert(u32(modus.Right.Schedule) == u32(op.Right.Schedule))
#assert(u32(modus.Right.Commit) == u32(op.Right.Commit))
#assert(u32(modus.Right.Events) == u32(op.Right.Events))
#assert(u32(modus.Right.Debug) == u32(op.Right.Debug))
#assert(u32(modus.Right.Counters) == u32(op.Right.Counters))

#assert(len(modus.Object_Kind) == len(op.Object_Kind))
#assert(u8(modus.Object_Kind.None) == u8(op.Object_Kind.None))
#assert(u8(modus.Object_Kind.Memory) == u8(op.Object_Kind.Memory))
#assert(u8(modus.Object_Kind.Process) == u8(op.Object_Kind.Process))
#assert(u8(modus.Object_Kind.Interrupt) == u8(op.Object_Kind.Interrupt))
#assert(u8(modus.Object_Kind.Ports) == u8(op.Object_Kind.Ports))
#assert(u8(modus.Object_Kind.Machine) == u8(op.Object_Kind.Machine))
#assert(u8(modus.Object_Kind.Thread) == u8(op.Object_Kind.Thread))
#assert(u8(modus.Object_Kind.Budget) == u8(op.Object_Kind.Budget))
#assert(u8(modus.Object_Kind.Log) == u8(op.Object_Kind.Log))

#assert(len(modus.Stop_Outcome) == len(op.Stop_Outcome))
#assert(u32(modus.Stop_Outcome.None) == u32(op.Stop_Outcome.None))
#assert(u32(modus.Stop_Outcome.Done) == u32(op.Stop_Outcome.Done))
#assert(u32(modus.Stop_Outcome.Failed) == u32(op.Stop_Outcome.Failed))
#assert(u32(modus.Stop_Outcome.Refused) == u32(op.Stop_Outcome.Refused))
#assert(u32(modus.Stop_Outcome.Stopped_On_Request) == u32(op.Stop_Outcome.Stopped_On_Request))

#assert(len(modus.Process_State) == len(op.Process_State))
#assert(u32(modus.Process_State.None) == u32(op.Process_State.None))
#assert(u32(modus.Process_State.Created) == u32(op.Process_State.Created))
#assert(u32(modus.Process_State.Ready) == u32(op.Process_State.Ready))
#assert(u32(modus.Process_State.Waiting) == u32(op.Process_State.Waiting))
#assert(u32(modus.Process_State.Stopped) == u32(op.Process_State.Stopped))

#assert(len(modus.Log_Level) == len(op.Log_Level))
#assert(u8(modus.Log_Level.Info) == u8(op.Log_Level.Info))
#assert(u8(modus.Log_Level.Debug) == u8(op.Log_Level.Debug))
#assert(u8(modus.Log_Level.Warning) == u8(op.Log_Level.Warning))
#assert(u8(modus.Log_Level.Error) == u8(op.Log_Level.Error))

#assert(len(modus.Memory_Flag) == len(op.Memory_Flag))
#assert(u64(modus.Memory_Flag.Frames_Now) == u64(op.Memory_Flag.Frames_Now))
#assert(u64(modus.Memory_Flag.Contiguous) == u64(op.Memory_Flag.Contiguous))
#assert(u64(modus.Memory_Flag.Uncommitted) == u64(op.Memory_Flag.Uncommitted))
#assert(u64(modus.Memory_Flag.Large_Pages) == u64(op.Memory_Flag.Large_Pages))

#assert(len(modus.Commit_Flag) == len(op.Commit_Flag))
#assert(u64(modus.Commit_Flag.Decommit) == u64(op.Commit_Flag.Decommit))
#assert(u64(modus.Commit_Flag.Frames_Now) == u64(op.Commit_Flag.Frames_Now))

#assert(len(modus.Map_Flag) == len(op.Map_Flag))
#assert(u64(modus.Map_Flag.Write) == u64(op.Map_Flag.Write))
#assert(u64(modus.Map_Flag.Execute) == u64(op.Map_Flag.Execute))
#assert(u64(modus.Map_Flag.No_Access) == u64(op.Map_Flag.No_Access))
#assert(u64(modus.Map_Flag.Receive_Handles) == u64(op.Map_Flag.Receive_Handles))
#assert(u64(modus.Map_Flag.At_Address_Zero) == u64(op.Map_Flag.At_Address_Zero))
#assert(u64(modus.Map_Flag.Write_Combining) == u64(op.Map_Flag.Write_Combining))

#assert(len(modus.Fixed_Range) == len(fixed_addresses.Fixed_Range))
#assert(u8(modus.Fixed_Range.Module_Files) == u8(fixed_addresses.Fixed_Range.Module_Files))
#assert(u8(modus.Fixed_Range.Pointer_Themes) == u8(fixed_addresses.Fixed_Range.Pointer_Themes))
#assert(u8(modus.Fixed_Range.Settings_Page) == u8(fixed_addresses.Fixed_Range.Settings_Page))
#assert(u8(modus.Fixed_Range.Presentation_Page) == u8(fixed_addresses.Fixed_Range.Presentation_Page))
#assert(u8(modus.Fixed_Range.Plan_Values_Page) == u8(fixed_addresses.Fixed_Range.Plan_Values_Page))
#assert(u8(modus.Fixed_Range.Date_Page) == u8(fixed_addresses.Fixed_Range.Date_Page))
#assert(u8(modus.Fixed_Range.Storage_File) == u8(fixed_addresses.Fixed_Range.Storage_File))
#assert(u8(modus.Fixed_Range.Module_Tables) == u8(fixed_addresses.Fixed_Range.Module_Tables))
#assert(u8(modus.Fixed_Range.Debug_Image) == u8(fixed_addresses.Fixed_Range.Debug_Image))
#assert(u8(modus.Fixed_Range.Disk_Process_Page) == u8(fixed_addresses.Fixed_Range.Disk_Process_Page))
#assert(u8(modus.Fixed_Range.Font_Outlines) == u8(fixed_addresses.Fixed_Range.Font_Outlines))
#assert(u8(modus.Fixed_Range.Fresh_Bytes_Page) == u8(fixed_addresses.Fixed_Range.Fresh_Bytes_Page))
#assert(u8(modus.Fixed_Range.Start_Policy_Pages) == u8(fixed_addresses.Fixed_Range.Start_Policy_Pages))
#assert(u8(modus.Fixed_Range.Edit_Target_Page) == u8(fixed_addresses.Fixed_Range.Edit_Target_Page))
#assert(u8(modus.Fixed_Range.Script_Fonts) == u8(fixed_addresses.Fixed_Range.Script_Fonts))

// Struct sizes and field offsets.
#assert(size_of(modus.Handle) == size_of(op.Handle))

#assert(size_of(modus.Time_Record) == size_of(op.Time_Record))
#assert(offset_of(modus.Time_Record, milliseconds) == offset_of(op.Time_Record, milliseconds))
#assert(offset_of(modus.Time_Record, cycle_frequency) == offset_of(op.Time_Record, cycle_frequency))
#assert(offset_of(modus.Time_Record, cycle_start) == offset_of(op.Time_Record, cycle_start))

#assert(size_of(modus.Date_Page) == size_of(date.Page))
#assert(offset_of(modus.Date_Page, change_count) == offset_of(date.Page, change_count))
#assert(offset_of(modus.Date_Page, source) == offset_of(date.Page, source))
#assert(offset_of(modus.Date_Page, milliseconds_at_time_zero) == offset_of(date.Page, milliseconds_at_time_zero))
#assert(offset_of(modus.Date_Page, zone_offset_seconds) == offset_of(date.Page, zone_offset_seconds))

#assert(size_of(modus.Fault_Record) == size_of(op.Fault_Record))
#assert(offset_of(modus.Fault_Record, thread) == offset_of(op.Fault_Record, thread))
#assert(offset_of(modus.Fault_Record, serial) == offset_of(op.Fault_Record, serial))
#assert(offset_of(modus.Fault_Record, address) == offset_of(op.Fault_Record, address))
#assert(offset_of(modus.Fault_Record, access) == offset_of(op.Fault_Record, access))
#assert(offset_of(modus.Fault_Record, instruction) == offset_of(op.Fault_Record, instruction))
#assert(offset_of(modus.Fault_Record, kind) == offset_of(op.Fault_Record, kind))
#assert(offset_of(modus.Fault_Record, error_code) == offset_of(op.Fault_Record, error_code))
#assert(offset_of(modus.Fault_Record, reserved) == offset_of(op.Fault_Record, reserved))

#assert(size_of(modus.Thread_Record) == size_of(op.Thread_Record))
#assert(offset_of(modus.Thread_Record, self) == offset_of(op.Thread_Record, self))
#assert(offset_of(modus.Thread_Record, parameter) == offset_of(op.Thread_Record, parameter))
#assert(offset_of(modus.Thread_Record, number) == offset_of(op.Thread_Record, number))
#assert(offset_of(modus.Thread_Record, events) == offset_of(op.Thread_Record, events))
#assert(offset_of(modus.Thread_Record, processors) == offset_of(op.Thread_Record, processors))
#assert(offset_of(modus.Thread_Record, fault_written) == offset_of(op.Thread_Record, fault_written))
#assert(offset_of(modus.Thread_Record, fault_read) == offset_of(op.Thread_Record, fault_read))
#assert(offset_of(modus.Thread_Record, fault_full) == offset_of(op.Thread_Record, fault_full))
#assert(offset_of(modus.Thread_Record, wait_room_words) == offset_of(op.Thread_Record, wait_room_words))
#assert(offset_of(modus.Thread_Record, fault_records) == offset_of(op.Thread_Record, fault_records))

#assert(size_of(modus.Context) == size_of(op.Context))
#assert(offset_of(modus.Context, handles) == offset_of(op.Context, handles))
#assert(offset_of(modus.Context, values) == offset_of(op.Context, values))

#assert(size_of(modus.Word) == size_of(op.Word))
#assert(offset_of(modus.Word, address) == offset_of(op.Word, address))
#assert(offset_of(modus.Word, value) == offset_of(op.Word, value))

#assert(size_of(modus.Page_Range) == size_of(op.Page_Range))
#assert(offset_of(modus.Page_Range, first) == offset_of(op.Page_Range, first))
#assert(offset_of(modus.Page_Range, page_count) == offset_of(op.Page_Range, page_count))

#assert(size_of(modus.Address_Range) == size_of(op.Address_Range))
#assert(offset_of(modus.Address_Range, address) == offset_of(op.Address_Range, address))
#assert(offset_of(modus.Address_Range, page_count) == offset_of(op.Address_Range, page_count))

#assert(size_of(modus.Error_Record) == size_of(errors.Error_Record))
#assert(offset_of(modus.Error_Record, kind) == offset_of(errors.Error_Record, kind))
#assert(offset_of(modus.Error_Record, unit) == offset_of(errors.Error_Record, unit))
#assert(offset_of(modus.Error_Record, operation) == offset_of(errors.Error_Record, operation))
#assert(offset_of(modus.Error_Record, argument) == offset_of(errors.Error_Record, argument))
#assert(offset_of(modus.Error_Record, value) == offset_of(errors.Error_Record, value))
#assert(offset_of(modus.Error_Record, limit) == offset_of(errors.Error_Record, limit))
#assert(offset_of(modus.Error_Record, found) == offset_of(errors.Error_Record, found))

#assert(size_of(modus.Ring_Record) == size_of(ring.Record))
#assert(offset_of(modus.Ring_Record, kind) == offset_of(ring.Record, kind))
#assert(offset_of(modus.Ring_Record, tag) == offset_of(ring.Record, tag))
#assert(offset_of(modus.Ring_Record, values) == offset_of(ring.Record, values))

#assert(size_of(modus.Ring_Counters) == size_of(ring.Counters))
#assert(offset_of(modus.Ring_Counters, write) == offset_of(ring.Counters, write))
#assert(offset_of(modus.Ring_Counters, writer_waits) == offset_of(ring.Counters, writer_waits))
#assert(offset_of(modus.Ring_Counters, read) == offset_of(ring.Counters, read))
#assert(offset_of(modus.Ring_Counters, reader_waits) == offset_of(ring.Counters, reader_waits))

#assert(size_of(modus.Ring_Head) == size_of(ring.Head))
#assert(offset_of(modus.Ring_Head, commands) == offset_of(ring.Head, commands))
#assert(offset_of(modus.Ring_Head, completions) == offset_of(ring.Head, completions))
`) == nil)
	parity_ok, parity_output := run_odin_modus_check(parity_dir)
	testing.expectf(t, parity_ok, "core:sys/modus ABI parity check failed:\n%s", parity_output)
}

@(private = "file")
verify_built_probe_module :: proc(t: ^testing.T, name: string, module_path: string, debug_path: string, expected_threads: u64) {
	mod_bytes, mod_err := os.read_entire_file(module_path, context.temp_allocator)
	testing.expectf(t, mod_err == nil && len(mod_bytes) > 0, "read built module %s", module_path)
	if mod_err != nil || len(mod_bytes) == 0 {
		return
	}
	testing.expect_value(t, module.validate(mod_bytes), module.Error.None)

	saw_entry := false
	for idx in 1 ..< module.count(mod_bytes, .Exports) {
		if module_export_name(mod_bytes, idx) == ENTRY_NAME {
			saw_entry = true
		}
	}
	testing.expectf(t, saw_entry, "%s must export entry", name)

	floor, has_floor := module.floor_read(mod_bytes)
	testing.expectf(t, has_floor, "%s must declare a floor", name)
	if has_floor {
		testing.expect_value(t, floor.threads, expected_threads)
	}

	if debug_path == "" {
		return
	}
	dbg_bytes, dbg_err := os.read_entire_file(debug_path, context.temp_allocator)
	testing.expectf(t, dbg_err == nil && len(dbg_bytes) > 0, "read debug object %s", debug_path)
	if dbg_err != nil || len(dbg_bytes) == 0 {
		return
	}
	parts, fault := debug_object.tables(dbg_bytes)
	testing.expect_value(t, fault, debug_object.Fault.None)
	if fault != .None {
		return
	}
	saw_main := false
	expected_main := foundation.join(name, "/main.odin")
	for file in parts.files[min(1, len(parts.files)):] {
		path := debug_object.text_of(parts.strings, file.path_offset, file.path_count)
		testing.expectf(t, !strings.has_prefix(path, "/"), "debug object of %s must not record host path %s", name, path)
		if path == expected_main {
			saw_main = true
		}
	}
	testing.expectf(t, saw_main, "debug object of %s must record %s", name, expected_main)
}

// Verifies that core_probe and core_probe_panic build cleanly through both
// outside_module_build (checkout path) and sdk_build_outside_module (SDK path).
@(test)
core_probe_modules_build_through_checkout_and_sdk :: proc(t: ^testing.T) {
	root := odin_core_test_temp_dir(t, "probe_build")
	defer _ = os.remove_all(root)

	saved_build_folder := foundation.module_build_folder
	saved_import_folder := foundation.module_import_folder
	saved_outside_folder := outside_source_folder
	saved_debug_info := debug_information
	defer {
		foundation.module_build_folder = saved_build_folder
		foundation.module_import_folder = saved_import_folder
		outside_source_folder = saved_outside_folder
		debug_information = saved_debug_info
	}

	Probe :: struct {
		name:    string,
		source:  string,
		threads: u64,
	}
	probes := [?]Probe {
		{name = "core_probe", source = "src/outside/projects/core_probe", threads = 3},
		{name = "core_probe_panic", source = "src/outside/projects/core_probe_panic", threads = 1},
	}

	// 1. Build through the repository outside_module_build path.
	checkout_out := foundation.join(root, "/checkout_out")
	testing.expect(t, os.make_directory_all(checkout_out) == nil)
	for probe in probes {
		abs_src, abs_err := os.get_absolute_path(probe.source, context.temp_allocator)
		testing.expectf(t, abs_err == nil, "resolve absolute path for %s", probe.source)
		if abs_err != nil {
			continue
		}
		built := outside_module_build(abs_src, checkout_out)
		testing.expectf(t, built, "outside_module_build must build %s", probe.name)
		if built {
			verify_built_probe_module(
				t,
				probe.name,
				foundation.join(checkout_out, "/", probe.name, ".module"),
				foundation.join(checkout_out, "/", probe.name, ".debug"),
				probe.threads,
			)
		}
	}

	// Restore globals before packing and running the SDK build path.
	foundation.module_build_folder = saved_build_folder
	foundation.module_import_folder = saved_import_folder
	outside_source_folder = saved_outside_folder
	debug_information = saved_debug_info

	// 2. Build both probes purely against a freshly packed SDK.
	sdk_dir := foundation.join(root, "/sdk")
	_, sdk_prob := sdk_build(sdk_dir, {source_root = ".", compiler_version = "dev-test"})
	testing.expect_value(t, sdk_prob, "")
	if sdk_prob != "" {
		return
	}
	for probe in probes {
		out_file := foundation.join(root, "/sdk_out/", probe.name, ".module")
		prob := sdk_build_outside_module(sdk_dir, probe.source, out_file)
		testing.expectf(t, prob == "", "sdk_build_outside_module %s failed: %s", probe.name, prob)
		if prob == "" {
			verify_built_probe_module(t, probe.name, out_file, "", probe.threads)
		}
	}
}
