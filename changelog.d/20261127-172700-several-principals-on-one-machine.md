type: Added

**Several principals on one machine.** A machine now hosts up to 7 named principals beside principal 0 (`PRINCIPAL_CAPACITY = 8`), each with its own session, encrypted stores, keys, and slot-stable identity across reboots, alongside update-surviving TPM seals (`PolicyAuthorize` + `PolicyNV` + `Owner_Protect`), machine grants (`Principals` and `System`), the `root.machine_acts` audit space, grant-authorized principal removal (`Principal_Remove_By_Grant`), and local cross-principal signed grants.
