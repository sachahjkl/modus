type: Changed

**The plan dialog reaches any holder of Display.** `plans` connects to the role `display`, not to the module `compositor`, and reads the exports of the holder from the boot image by the hash that the connection gives, so a plan that gives Display to another module keeps the trusted dialog of each apply and rollback.
