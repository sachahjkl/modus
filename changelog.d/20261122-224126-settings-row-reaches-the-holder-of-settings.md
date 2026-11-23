type: Fixed

**The row `settings` of a start list reaches the holder of the role Settings.** The boot pass started the module `settings` of the boot image by its name, so a plan of principal 0 that gave the role to another module did not reach it; it now starts the holder in force and gives it the value of the boot pass. That holder still gets the grants of its own module name, not those of `settings`.
