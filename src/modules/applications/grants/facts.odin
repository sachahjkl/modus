package grants_window

// Log facts of the desktop Grants window (src/md/features/grants_window.md).
// Text fields come last so the serial line trims trailing zero bytes cleanly.

FACT_NAME_BYTES :: 32
FACT_CAUSE_BYTES :: 96

@(log_fact = "grants: ok")
Running :: struct {}

@(log_fact = "grants: no root ring grant; cannot read or revoke grants")
No_Root_Ring :: struct {}

@(log_fact = "grants: revoked {grant} from {process}")
Process_Grant_Revoked :: struct {
	process: [32]u8,
	grant:   [32]u8,
}

@(log_fact = "grants: ended the active wide grant")
Wide_Grant_Ended :: struct {}

@(log_fact = "grants: disallowed {grant} for {nickname}")
Disk_Grant_Disallowed :: struct {
	nickname: [32]u8,
	grant:    [32]u8,
}

@(log_fact = "grants: revocation refused: {cause}")
Revocation_Refused :: struct {
	cause: [96]u8,
}
