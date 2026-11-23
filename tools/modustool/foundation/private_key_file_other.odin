#+build !linux
package foundation

// file_owned_by_this_user: a host with no owner of a file that the tool reads
// refuses each private key, so no key goes unchecked.
file_owned_by_this_user :: proc(path: string) -> bool {
	return false
}
