type: Changed

**An audit space whose record size changed closes and keeps its records.** When a module changes the size of an audited record, its old audit space takes no more records, and its records stay readable and verifiable, across a restart. A new space takes the new records.
