type: Fixed

**The error records of the root ring say the cause.** `machine_seal()` and `machine_passphrase()` on a machine whose firmware did not verify the boot program now give the record Refused of the principals, and no longer a missing grant; a refused `Machine_Key` from `unlock` now has an error record; and an error record that names no command of the root ring now reads "an unknown command".
