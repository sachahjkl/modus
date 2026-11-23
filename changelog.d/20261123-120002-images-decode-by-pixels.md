type: Changed

**An image decodes whatever its sides, within the memory of its caller**: `modus:contract/image_decode` takes an image of any width and height up to 268 435 456 pixels, the pixels of one memory object, so a photo of 6000 × 4000 and a panorama of 30000 × 2000 decode. The output buffer that the caller gives bounds each image; a PNG wider than 4096 pixels takes its rows from the scratch, which its header names in `minimum_scratch_bytes`.
