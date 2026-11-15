type: Changed

**The machines of the TPM run in the full check.** `modustool test trusted_boot` now runs the two machines of the measure, and `modustool test principals` runs the six machines of the machine key sealed by the TPM; the forms `test trusted_boot tpm` and `test principals tpm` are gone. The lost answer of the software TPM was a fault of QEMU 10.2 with its io_uring main loop, and the development shell now builds QEMU without io_uring: in two runs of each part, each of the 16 machines of the TPM had one `Startup` and no abandoned command.
