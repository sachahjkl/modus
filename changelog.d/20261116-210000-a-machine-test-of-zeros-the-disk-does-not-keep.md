type: Added

**A machine test of zeros that the disk does not keep**: in `modustool test principals`, the disk of the change of the passphrase answers Ok to the write of zeros over the old file of the principal and keeps its bytes. The test checks the line of the storage service that reports the block, checks that the row of the erase counts only the zeros that the disk kept, and finds no part of the old file outside that block of the image.
