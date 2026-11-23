package root

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the root service whose line says the status of a kernel
// operation (src/md/features/log_facts.md, "Field kinds"). The line wrote
// the status as its number; the field of the kind Status writes the name
// of its member, so the sentence says "status No_Memory" where it said
// "status 7". A word that names no member stays its number. A status after
// a field of 8 bytes is the word type op.Status_Word, so the record has no
// padding.

@(log_fact = "root: cannot make the budget of the disk processes: status {status}")
Disk_Processes_Budget_Refused :: struct {
	status: op.Status,
}

@(log_fact = "root: cannot read the configuration of the bus for the entropy device: status {status}: the random seed of the system has the sources of the processor only")
Entropy_Configuration_Unread :: struct {
	status: op.Status,
}

@(log_fact = "root: cannot start the entropy service: status {status}: the random seed of the system has the sources of the processor only")
Entropy_Service_Start_Failed :: struct {
	status: op.Status,
}

@(log_fact = "root: cannot open the entropy ring: status {status}: the random seed of the system has the sources of the processor only")
Entropy_Ring_Open_Failed :: struct {
	status: op.Status,
}

@(log_fact = "root: cannot create the fresh bytes pages: status {status}: a running process mixes no new bytes into its generator")
Fresh_Bytes_Pages_Failed :: struct {
	status: op.Status,
}

@(log_fact = "root: cannot create the pages of the plan values: status {status}: each owner holds the defaults of its contract")
Plan_Values_Pages_Failed :: struct {
	status: op.Status,
}

@(log_fact = "root: cannot create the presentation pages: status {status}: each window draws with the defaults")
Presentation_Pages_Failed :: struct {
	status: op.Status,
}

@(log_fact = "root: cannot start shortage: status {status}")
Shortage_Start_Failed :: struct {
	status: op.Status,
}

@(log_fact = "root: cannot start operation_fuzzing: status {status}")
Operation_Fuzzing_Start_Failed :: struct {
	status: op.Status,
}

// The root service cannot go on: the boot display shows the failure, and
// the service serves nothing more. The failure is a sentence of a closed
// set of this service, or the sentence of a fault of the check of the boot
// image with the name of its entry: at most 112 bytes.
@(log_fact = "root: {failure}: status {status}")
Root_Failed :: struct {
	status:  op.Status,
	failure: [140]u8,
}

@(log_fact = "root: cannot start input: status {status}")
Input_Start_Failed :: struct {
	status: op.Status,
}

// The virtio tablet was classified but could not be armed: the input
// service starts with the PS/2 controller only.
@(log_fact = "root: cannot give the virtio tablet to input: status {status}: the pointer is the PS/2 mouse only")
Input_Tablet_Arm_Failed :: struct {
	status: op.Status,
}

@(log_fact = "root: cannot start the compositor: no control ring: status {status}")
Compositor_Control_Ring_Failed :: struct {
	status: op.Status,
}

@(log_fact = "root: cannot start the compositor: no service ring: status {status}")
Compositor_Service_Ring_Failed :: struct {
	status: op.Status,
}

@(log_fact = "root: the holder of the display gets no role store (status {status}): it draws with the defaults of its contract, and keeps no choice")
Display_Role_Store_Not_Given :: struct {
	status: op.Status,
}

@(log_fact = "root: cannot start the compositor: status {status}")
Compositor_Start_Failed :: struct {
	status: op.Status,
}

@(log_fact = "root: unlock did not start (status {status}): no named principal can be created or unlocked")
Unlock_Start_Failed :: struct {
	status: op.Status,
}

// A start refused by the kernel with a status, and no error of the loader.
@(log_fact = "root: cannot start {refused_process}: status {status}")
Start_Failed :: struct {
	status:          op.Status,
	refused_process: value_kinds.Module_Name_Field,
}

@(log_fact = "root: no choice of a start policy is read: unlock did not start, with the status {status}")
Start_Policy_Choice_Unread_Unlock_Failed :: struct {
	status: op.Status,
}

@(log_fact = "root: the chosen start policy \"{nickname}\" is not read: no connection to the storage service, status {status}: the rescue start policy starts")
Chosen_Start_Policy_No_Connection :: struct {
	status:   op.Status,
	nickname: value_kinds.Module_Name_Field,
}

@(log_fact = "root: the chosen start policy \"{nickname}\" is not started, with the status {status}: the rescue start policy starts")
Chosen_Start_Policy_Not_Started :: struct {
	status:   op.Status,
	nickname: value_kinds.Module_Name_Field,
}

@(log_fact = "root: cannot create the machine parts page: status {status}")
Machine_Parts_Page_Failed :: struct {
	status: op.Status,
}

@(log_fact = "root: the boot pass of settings did not start (status {status}): the settings are the defaults")
Settings_Boot_Pass_Failed :: struct {
	status: op.Status,
}

// The start of the window of settings that waited for a pass, after the
// pass stopped.
@(log_fact = "root: the start of settings that waited for its pass did not start (status {status})")
Settings_Due_Start_Failed :: struct {
	status: op.Status,
}

// The tile of the Control Center asked for the next appearance, and the
// pass of settings did not start.
@(log_fact = "root: the next appearance of the Control Center did not start settings (status {status})")
Appearance_Next_Not_Started :: struct {
	status: op.Status,
}

@(log_fact = "root: cannot start the TPM service: status {status}")
Tpm_Service_Start_Failed :: struct {
	status: op.Status,
}

// The registers of the TPM refused: the address in 16 digits with no
// "0x", as system.Hex wrote it.
@(log_fact = "root: no TPM service: the registers of the TPM at {registers} are refused: status {status}")
Tpm_Registers_Refused :: struct {
	registers: value_kinds.Hexadecimal_Sixteen_Digits,
	status:    op.Status_Word,
}
