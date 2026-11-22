type: Added

**Triangles of the WebGPU subset four pixels at a time**: on the processor, the back end of the WebGPU subset computes the edge functions, the coverage with the top-left rule, the depth and the colors corrected for perspective of four adjacent pixels in one SSE2 register, with the same color bytes and depth values as the scalar form. The host tests compare the two forms on a cube in perspective, translucent triangles, shared edges, scissor rectangles and degenerate triangles.
