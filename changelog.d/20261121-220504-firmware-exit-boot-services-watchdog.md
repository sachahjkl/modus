type: Fixed

**A firmware that hangs in the end of its services.** The UEFI boot program arms the firmware watchdog for 30 seconds immediately before the final memory map read and `ExitBootServices`, so a firmware hang during boot exit restarts the machine instead of freezing it.
