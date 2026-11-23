type: Changed

**The call outcome of the device rings and of the TPM ring.** The block, frame, network, entropy and TPM services now answer each request with a call outcome and an error record in place of a status set of their own, so one reader serves each of these rings and a caller tells a refusal from a failure of the device. A failed write or flush of a disk is a partial change, as some blocks can be on the disk; the iommu fact and the log facts of the network, the root service and `unlock` name the outcome.
