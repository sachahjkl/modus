type: Added

**Freestanding PNG and baseline JPEG decoders with SSE2 vector forms.** Added zero-allocation `modus:contract/image_decode` supporting PNG (bit depth 8, color types 0, 2, 3, 4, and 6, CRC-32, PLTE/tRNS, concatenated IDAT zlib/DEFLATE stored, fixed, and dynamic Huffman, Adler-32, and SSE2 scanline filters) and baseline JPEG (DQT, DHT, SOF0 grayscale and YCbCr 4:4:4/4:2:2/4:2:0, DRI restart intervals, SOS byte stuffing, SSE2 integer 2D IDCT, and SSE2 YCbCr-to-RGBA conversion), with strict dimension/bomb bounds and zero pixel writes on refusal.
