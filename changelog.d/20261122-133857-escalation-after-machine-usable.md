type: Changed

**The escalation of a needed holder after the machine is usable.** A start policy that stops after `Machine_Usable`, as the default one does when a needed row is past its restart bound, now gives way to the rescue start policy: the root service stops each process that it asked for and starts the rescue, which gives a principal the console. A stop of the rescue after its own `Machine_Usable` leaves the machine with no start policy, with its line.
