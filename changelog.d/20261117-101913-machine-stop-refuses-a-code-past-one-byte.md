type: Fixed

**`Machine_Stop` refuses a code that the host cannot receive**: a code above `MACHINE_STOP_CODE_MOST` (255) gives `Bad_Operation` with the error record `Bad_Value` of the code, and the machine runs on. Before, the kernel wrote the whole code on the log and gave the host its low byte, so the code 256 ended the machine with 0, the code of a normal end.
