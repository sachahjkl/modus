type: Changed

**The devices service classifies the bus.** The root service starts `devices` before any device service, asks it once for the class of each device of the bus, and arms a device only at a place that `devices` classified with the class of its service. Each start and each stop of a device service is a binding of `devices`. A `devices` that does not answer within three starts leaves the machine with no device service, with one line.
