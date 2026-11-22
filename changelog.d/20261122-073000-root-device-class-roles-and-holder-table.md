type: Changed

**The roles of the device classes.** `root` now resolves PCI vendor/device identities through `root_delegation.Device_Identity_Table` into closed `Device_Class_Role` values and maps system roles to holder module names through a central role-holder table instead of hardcoding VirtIO device IDs beside module names.
