type: Changed

**The tables of the services sized from the process slots of the machine.** The root service takes its places, its wait set and its other tables for each process slot from its budget at its start, one for each process slot of the machine: 255 on a machine of 1 GiB, in place of 1023. The disk process page and the region of the devices service hold the rows of these places only, and `inspect` and `monitor` take their tables of the processes the same way.
