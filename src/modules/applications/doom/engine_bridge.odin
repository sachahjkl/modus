#+build freestanding
package doom

foreign _ {
	modus_doom_init :: proc "c" (host: ^Doom_Host) -> i32 ---
	modus_doom_tick :: proc "c" () -> i32 ---
}
