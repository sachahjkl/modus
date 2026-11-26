type: Fixed

**Fix settings window launch raising when started on a fresh process slot.** The root service now matches both kernel process slot and serial when identifying a running settings pass, so opening `settings` a second time raises the running window instead of waiting forever for the finished boot pass.
