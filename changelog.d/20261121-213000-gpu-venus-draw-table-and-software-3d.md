type: Added

**Venus Vulkan wire protocol, draw-table WebGPU translator, and processor 3D rasterizer.** Added the freestanding `venus_vulkan` wire encoder, ring header validator, and `webgpu_stream_to_venus` translator for `virtio_gpu.Submit_3D`, plus `draw_table_translate_to_webgpu` and the `software_3d_execute` processor rasterizer in `webgpu_subset` with 24-bit depth testing, scissor clipping, and linear-light alpha blending.
