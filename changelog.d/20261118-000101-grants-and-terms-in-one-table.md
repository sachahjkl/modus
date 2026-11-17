type: Changed

**The grants and the terms of a role in one table.** The role of each program of the boot image is one row of `program_roles` in `src/programs/root/roles.odin`: its start grants, the services that it connects to, its store, its terminal and the reason of each. The build stops when a program of the boot image has no row, a row names no program, a program has two rows, or the grant System_Part is on a row that is no part of the system or missing from a part of the system, and the page of the grants on the site shows each row with its grants and its other terms.
