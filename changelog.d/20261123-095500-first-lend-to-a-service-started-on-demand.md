type: Fixed

**The first call to a service that starts on demand can lend a handle**: the call failed with "an argument names no handle of the console" when the service had not mapped its call ring yet. A call host or a service now sends a ready completion once it can receive handles, and each caller waits for it before its first call.
