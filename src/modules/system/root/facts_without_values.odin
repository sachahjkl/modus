package root

// The log facts of the root service whose line holds no value
// (src/md/features/log_facts.md): a fact type with no field, whose
// sentence is its template. A reader still chooses them by fact type, and
// a machine test waits for them as before.

@(log_fact = "root: no debug image: a stop report names each frame by its module and its offset")
Debug_Image_Absent :: struct {}

@(log_fact = "root: the standard VGA does not hold the framebuffer of the firmware and its display registers: the compositor writes the screen page that the display shows")
Standard_Vga_Without_Framebuffer :: struct {}

@(log_fact = "root: the display registers of the standard VGA do not say the mode of the framebuffer of the firmware with two screen pages: the compositor writes the screen page that the display shows")
Standard_Vga_Mode_Unknown :: struct {}

@(log_fact = "root: the entropy service stopped: no more fresh bytes for the running processes")
Entropy_Service_Stopped :: struct {}

@(log_fact = "root: the boot display shows the failure")
Failure_Shown :: struct {}

@(log_fact = "root: no screen: no console, no window; the other services start")
No_Screen :: struct {}

@(log_fact = "root: the compositor stopped: no screen; a start of a window or a terminal is refused from now on")
Compositor_Stopped :: struct {}

@(log_fact = "root: no compositor in the boot image: the console writes to the second serial port through serial_terminal")
Console_Renderer_Serial :: struct {}

@(log_fact = "root: no compositor in the boot image: the console draws a text grid on the screen through grid_terminal")
Console_Renderer_Grid :: struct {}

@(log_fact = "root: no compositor in the boot image: the console writes lines for a page to the second serial port through dom_terminal")
Console_Renderer_Dom :: struct {}

@(log_fact = "root: no palette provider")
Palette_Provider_Absent :: struct {}

@(log_fact = "root: refused a machine passphrase: the record of the machine passphrase cannot be read, and a new one would replace a key that can be good")
Machine_Passphrase_Refused_Unreadable :: struct {}

@(log_fact = "root: refused a machine passphrase: the machine has one, and a change is not built")
Machine_Passphrase_Refused_Exists :: struct {}

@(log_fact = "root: refused a machine passphrase: unlock runs; it is set when unlock stopped")
Machine_Passphrase_Refused_Unlock_Runs :: struct {}

@(log_fact = "root: the machine passphrase is set in the window of unlock")
Machine_Passphrase_Setting_Started :: struct {}

@(log_fact = "root: refused a machine key sealed by the TPM: no TPM service runs, as the system is not measured into a TPM")
Machine_Key_Seal_Refused_No_Tpm :: struct {}

@(log_fact = "root: refused a machine key sealed by the TPM: the firmware did not verify the boot program (Secure Boot is off), so a seal would trust a boot program that nothing verified")
Machine_Key_Seal_Refused_Not_Verified :: struct {}

@(log_fact = "root: refused a machine key sealed by the TPM: the machine has a record of its machine key, and a change is not built")
Machine_Key_Seal_Refused_Exists :: struct {}

@(log_fact = "root: refused a machine key sealed by the TPM: unlock runs; it is made when unlock stopped")
Machine_Key_Seal_Refused_Unlock_Runs :: struct {}

@(log_fact = "root: the machine key is sealed by the TPM in the window of unlock")
Machine_Key_Seal_Started :: struct {}

@(log_fact = "root: the machine key is sealed by the TPM: the disk grants of principal 0 wait for the unseal, and the machine runs")
Machine_Key_Sealed_Grants_Wait :: struct {}

@(log_fact = "root: the machine has a passphrase: the disk grants of principal 0 wait for it, and the machine runs")
Machine_Passphrase_Grants_Wait :: struct {}

@(log_fact = "root: the record of the machine passphrase cannot be read: the disk grants of principal 0 stay absent, and no change and no new passphrase is taken")
Machine_Passphrase_Record_Unreadable :: struct {}

@(log_fact = "root: refused a change of the disk grant table of principal 0: the machine passphrase is not typed; type it in the window of unlock")
Machine_Table_Change_Refused_Not_Typed :: struct {}

@(log_fact = "root: refused a change of the disk grant table of principal 0: the record of the machine passphrase cannot be read, so nothing is written over the table on the disk")
Machine_Table_Change_Refused_Record_Unreadable :: struct {}

@(log_fact = "root: principal 0 is the machine: the system is not measured; its key, the attestation key of the TPM, is not built")
Machine_Principal_Unmeasured :: struct {}

@(log_fact = "root: refused a change of the passphrase: the caller runs in no session of a named principal")
Passphrase_Change_Refused_No_Session :: struct {}

@(log_fact = "root: refused a change of the passphrase: unlock runs; it is made when unlock stopped")
Passphrase_Change_Refused_Unlock_Runs :: struct {}

@(log_fact = "root: no choice of a start policy is read: no TPM service runs, so no machine key opens with no passphrase")
Start_Policy_Choice_Unread_No_Tpm :: struct {}

@(log_fact = "root: no choice of a start policy is read: the machine has no data disk")
Start_Policy_Choice_Unread_No_Disk :: struct {}

@(log_fact = "root: the plan of principal 0 is not read before the rescue start policy: the roles of the boot image hold")
Plan_At_Start_Unread_Rescue :: struct {}

@(log_fact = "root: the plan of principal 0 is not read before the start policy: the machine has no data disk")
Plan_At_Start_Unread_No_Disk :: struct {}

@(log_fact = "root: the plan of principal 0 is not read before the start policy: the boot image has no holder of the role Plans")
Plan_At_Start_Unread_No_Plans_Module :: struct {}

@(log_fact = "root: the plan of principal 0 is not read before the start policy: the boot image has no holder of the role Storage")
Plan_At_Start_Unread_No_Storage_Module :: struct {}

@(log_fact = "root: principal 0 has no plan stored: the roles of the boot image hold")
Plan_At_Start_No_Plan :: struct {}

@(log_fact = "root: the boot image cannot hold the roles of the stored plan of principal 0: the roles of the boot image hold")
Plan_At_Start_Plan_Refused :: struct {}

@(log_fact = "root: the plans service cannot read the plan of principal 0 from its store: the roles of the boot image hold")
Plan_At_Start_Store_Unread :: struct {}

@(log_fact = "root: the plans service did not read the roles in force: the roles of the boot image hold")
Plan_At_Start_Core_Unread :: struct {}

@(log_fact = "root: the plans service stopped before it read the plan of principal 0: the roles of the boot image hold")
Plan_At_Start_Holder_Stopped :: struct {}

@(log_fact = "root: unlock reads the machine key with no window, before the start policy: the choice of principal 0 is in its disk grant table")
Unlock_Reads_Machine_Key :: struct {}

@(log_fact = "root: the disk grant table of principal 0 is not read before the start policy: no choice of principal 0 is known")
Machine_Table_Unread_Before_Start_Policy :: struct {}

@(log_fact = "root: refused a choice of a start policy: a nickname of no byte ends the choice, and the command names a hash")
Start_Policy_Choice_Refused_Empty_Nickname :: struct {}

@(log_fact = "root: refused a choice of a start policy: the machine has no machine key, so the disk grant table of principal 0 lasts until the machine stops, and no choice reaches the next start; machine_seal() makes a machine key")
Start_Policy_Choice_Refused_No_Machine_Key :: struct {}

@(log_fact = "root: refused a choice of a start policy: the machine key opens with the machine passphrase, and the root service reads the choice before a passphrase can be typed")
Start_Policy_Choice_Refused_Passphrase :: struct {}

@(log_fact = "root: principal 0 has chosen no start policy: the default start policy runs at the next start")
Start_Policy_Choice_Absent :: struct {}

@(log_fact = "root: principal 0 ended its choice of a start policy: the default start policy runs at the next start of the machine")
Start_Policy_Choice_Ended :: struct {}

@(log_fact = "root: the start policy is absent from the boot image: the rescue start policy starts")
Start_Policy_Absent :: struct {}

@(log_fact = "root: the machine parts page holds no part")
Machine_Parts_None :: struct {}

@(log_fact = "root: the boot image has no valid font outlines: the text of the system is Spleen 8x16")
Font_Outlines_Absent :: struct {}

@(log_fact = "root: no TPM service: the system is not measured into a TPM, so no key is sealed to its measure")
Tpm_Service_Absent_Unmeasured :: struct {}

@(log_fact = "root: no TPM service: the table of the processes is full")
Tpm_Service_Absent_Table_Full :: struct {}

@(log_fact = "root: the TPM service stopped: no key is sealed or unsealed until the machine starts again")
Tpm_Service_Stopped :: struct {}

@(log_fact = "root: the system description is signed by the test signing key, whose private key is published: this system is not trusted")
Description_Signed_By_Test_Key :: struct {}

@(log_fact = "root: verified by the boot program, which the firmware did not verify")
Verified_By_Boot_Program :: struct {}

@(log_fact = "root: verified by the firmware (Secure Boot), then by the boot program")
Verified_By_Firmware :: struct {}

@(log_fact = "root: the system description is not measured into the TPM: the firmware has no TPM")
Description_Unmeasured_No_Tpm :: struct {}

@(log_fact = "root: the boot program did not try the measure")
Measure_Not_Tried :: struct {}

@(log_fact = "root: an index of a TPM floor was not a floor that the boot program could read: another system defined or planted it, or PCR 7 changed; the boot program took it as 0, and replaced it with Secure Boot on")
Tpm_Floor_Foreign :: struct {}
