type: Fixed

**The GPU device service replaces a scanout only once the new one is on the screen**: a refused attach leaves the old picture and its memory as they were, the memory of a client is closed on each refusal, the old memory is closed only after the device released it, and a device that does not answer a control request stops the service in place of reusing its descriptors.
