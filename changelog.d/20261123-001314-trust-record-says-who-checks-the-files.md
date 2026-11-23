type: Fixed

**The trust record says who checks the files**: a new field `file_check` names the boot program, the root service at its start, or the root service at the first use of each file. A browser machine writes the root service at the first use and no verifier, and the root service writes on the log that no boot program verified the description, in place of the false lines "verified by the boot program" and "checked the signature and every hash in 0 us".
