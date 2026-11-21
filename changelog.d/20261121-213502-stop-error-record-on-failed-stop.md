type: Added

**Optional typed error record on failed or refused process stops.** `Process_Stop` accepts a readable `errors.Error_Record` address for a `Failed` or `Refused` self-stop, stores it in `Stop_Report.error`, and refuses any non-zero error address on `Done`, `Stopped_On_Request`, or holder stops; `system.stop` passes the optional record and the console prints it on call-host failure.
