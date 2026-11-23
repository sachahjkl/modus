package foundation

import "core:fmt"
import "core:os"

// private_key_mode_problem gives the sentence that refuses a private key file
// with this mode, or "". A group or other bit lets another user of the
// computer read the key, change it or run it; each is a fault, and the
// sentence names the one that the mode holds.
private_key_mode_problem :: proc(path: string, mode: os.Permissions) -> string {
	read_bits := os.Permissions{.Read_Group, .Read_Other}
	write_bits := os.Permissions{.Write_Group, .Write_Other}
	run_bits := os.Permissions{.Execute_Group, .Execute_Other}
	if mode & read_bits != {} {
		return fmt.tprintf("the private key %s can be read by other users of this computer: run `chmod 600 %s`, then make a new key if another user can have copied it", path, path)
	}
	if mode & write_bits != {} {
		return fmt.tprintf("the private key %s can be written by other users of this computer: run `chmod 600 %s`, then make a new key if another user can have replaced it", path, path)
	}
	if mode & run_bits != {} {
		return fmt.tprintf("the private key %s can be run by other users of this computer: run `chmod 600 %s`", path, path)
	}
	return ""
}

// private_key_file_check refuses a private key file that another user owns,
// or that the group or the others can read, write or run: such a key can be
// copied or replaced by someone who is not its owner. It prints the refusal.
private_key_file_check :: proc(path: string) -> bool {
	information, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil {
		fmt.eprintfln("modustool: the mode of the private key %s was not read: %v", path, stat_error)
		return false
	}
	if problem := private_key_mode_problem(path, information.mode); problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return false
	}
	if !file_owned_by_this_user(path) {
		fmt.eprintfln("modustool: the private key %s belongs to another user", path)
		return false
	}
	return true
}
