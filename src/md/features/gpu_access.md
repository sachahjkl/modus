# The access to a GPU for acceleration

Processes of the system draw in 2D through the draw table, and WebGPU is the later interface of the GPU: [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "18. One 2D interface: the draw table". When a GPU exists, the drawing module draws the draw table through WebGPU ([../api/draw_table.md](../api/draw_table.md), "The execution"). This file records how WebGPU reaches a real GPU, and which forms were refused. The access to a GPU for acceleration is the aim of the work on guests; compatibility with another system is not ([foreign_systems.md](foreign_systems.md)). Among the forms, the most performant and the most modular one is chosen. The first layers (VirtIO-GPU 2D scanout, the Venus wire protocol of Mesa with the objects of a 2D frame, the Venus context of the `gpu_device` service, the WebGPU subset with its processor and Venus back ends, and the Venus stream of a draw table from the drawing module) are built; see "State".

The terms are in [`docs/glossary/access.md`](../../../docs/glossary/access.md), "Driver domain".

## The constraints

- No vendor code in the kernel. The code of a device is a process: a device service.
- A GPU writes memory by direct memory access from the command buffers that processes give. So a real GPU needs the IOMMU first.
- The project does not port an existing implementation of the graphics interface.
- No support for hardware that nobody on the project owns: one GPU, named, with an opt-in test.
- The compositor owns the display. A guest must not draw on a screen that the compositor does not own: it can draw a false system dialog there.

## The chosen form: a driver domain, with one serialization

A driver domain is a small Linux guest that owns the GPU through the IOMMU. It runs the Linux driver and the open user-space driver with no change, and serves the GPU to the system.

The library of the system emits Vulkan commands in one serialization, the one that the virtual GPU of QEMU carries (Venus). The same encoder then serves two transports:

- under QEMU, the virtio GPU device carries the commands;
- on real hardware, a ring between the system and the driver domain carries them.

Why this works in the reversed direction: the serialization is not a transport. The renderer that reads it also takes it over a socket with no guest at all, so it runs over any byte channel. In the usual use the renderer is in the host and the client in the guest. Here the processes of the system are the clients and the guest is the renderer. This direction is the safer one: the renderer sees only the memory that the system granted to the guest.

What the system writes: the graphics interface and its back end in the shape of Vulkan, the encoder, a ring service, and the process that runs the guest. The shaders go from WGSL to SPIR-V, the intermediate form of Vulkan, at build time ("The WebGPU of the system"). The encoder runs in each client and is not trusted: a wrong stream harms only its own context.

What the kernel must provide is already in the order of the work: the IOMMU with interrupt remapping, guest support, the assignment of a device to a guest, a reset of the device, and shared memory of hundreds of megabytes between the guest and a client.

## The WebGPU of the system

The graphics interface is WebGPU, in a subset that the system writes: only what the draw table, the compositor and 3D need. The subset grows with a need, as the kinds of the draw table do.

- **The shaders are compiled before the run.** The build compiles each shader of WGSL to SPIR-V with a compiler of the host, and the module carries the SPIR-V. The system holds no compiler of shaders, and no process compiles one at run time.
- **The subset has two back ends.** The GPU back end emits Vulkan through the serialization above. The processor back end runs the same objects (buffers, pipelines, command lists, draw calls) on the processor, with a small fixed set of shaders written in Odin with SIMD ([desktop_to_browser.md](desktop_to_browser.md), "F. 3D"). A process writes the same code for both, and only the back end changes.
- **A port of wgpu or Dawn stays open** for a module of a third party, as its own module over the WebGPU of the system ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "18. One 2D interface: the draw table"). The code of the system never uses one.

Why a subset of its own first: wgpu and Dawn each carry back ends for Vulkan, Metal and Direct3D and a compiler of shaders inside. The system needs one back end and a few pipelines, and the compilers of the host already turn WGSL into SPIR-V.

## The Venus wire

The serialization is Venus as Mesa and virglrenderer define it, not a format of the system: the renderer of the host reads only that. Its sources are the venus-protocol repository (`VK_EXT_command_serialization`, `VK_MESA_venus_protocol`, the generator `vn_protocol.py`), and the Linux header `include/uapi/linux/virtio_gpu.h` for the VirtIO-GPU commands.

- **The VirtIO-GPU words are those of the header.** `RESOURCE_CREATE_BLOB` is `0x010C` and `SET_SCANOUT_BLOB` `0x010D`, because `GET_EDID` and `RESOURCE_ASSIGN_UUID` come before them; `RESOURCE_MAP_BLOB` and `RESOURCE_UNMAP_BLOB` are `0x0208` and `0x0209`, after `SUBMIT_3D`. The `SUBMIT_3D` header is 32 bytes: the size and a padding word. A wrong word makes the host refuse every command; the host tests assert each word and each size.
- **No command carries its length.** A command is its type, its flags, then the parameters in the order of the Vulkan call. An integer is padded to 32 bits, an enum is an `int32`, a `size_t` a `uint64`, a handle the 64-bit object id that the driver side chooses, a pointer or an array a `uint64` count then its values, a string its size with the null byte then its bytes padded to 32 bits. A reader that does not know a command cannot skip it, so the decoder of `venus_vulkan` knows each command that the encoder writes, and nothing else.
- **An output struct travels partly.** For `vkGetPhysicalDeviceProperties`, the command carries only the sizes of the fixed arrays of the output (the name, the UUID, the six arrays of the limits); the reply carries the values. The limits are a table of 106 fields in the order of `vulkan_core.h`, read by one loop, not 106 lines of code.
- **The default union tags.** A clear color travels as its `uint32` member (tag 2) and a clear value as its color (tag 0): the bits of each float arrive unchanged.
- **What the renderer refuses.** `vkCreateInstance` with a layer or an extension; `vkGetDeviceQueue` (only `vkGetDeviceQueue2` binds the id of a queue, once); an instance below Vulkan 1.1. The encoders follow these rules, so a refusal of the host is a fault of the host, not of the system.
- **The ring.** The layout is Mesa's: the head, the tail and the status each in a 64-byte line, then a buffer whose size is a power of two, then the extra region. The head and the tail are free-running 32-bit counters, and the tail after a write is its sequence number. The driver refuses a write that does not fit whole, a head that is ahead of the tail, and a status with an unknown bit or the fatal bit. The idle bit asks for `vkNotifyRingMESA`.
- **The replies.** A command with the reply flag writes its reply in the reply stream (`docs/glossary/devices.md`, "Reply stream") that `vkSetReplyCommandStreamMESA` names. A reply decoder refuses an unknown `VkResult`, a device name that is not UTF-8, and checks that the renderer echoes each object id that the command bound.
- **A reply has no length, so the driver reserves it.** `venus_ring_submit_command` takes one whole command with the reply flag and the size of its reply, which the encoder of that reply measures. It writes `vkSeekReplyCommandStreamMESA` and the command in one ring write, so that no other command comes between them, with `vkSetReplyCommandStreamMESA` before the first one. `venus_ring_poll_reply` gives the reply once the head of the renderer passes the sequence number of that write, copied out of the shared memory, so that the decoder reads bytes that the renderer can no longer change. The renderer stores its head after it ran the commands, so the reply is complete when the head passes. The reply stream starts again at 0 only when no reply waits in it; before that, a submission is refused, as a write to a full ring is. A status with the fatal bit refuses each submission and each poll.

### The Venus context of the service

The GPU device service probes the features `VIRGL`, `RESOURCE_BLOB` and `CONTEXT_INIT` and the capsets at its start, beside the 2D scanout. When all four parts exist, it reads the Venus capset (`GET_CAPSET`), refuses a capset whose wire format is not 1, creates one context with `CTX_CREATE` and the Venus capset in `context_init`, then the blob of its ring: `RESOURCE_CREATE_BLOB` of host memory with the blob id 0, `CTX_ATTACH_RESOURCE`, `RESOURCE_MAP_BLOB`. A device with no 3D feature logs nothing more and keeps its 2D scanout as before; a device with a 3D feature and no Venus logs why.

A client sends a Venus stream with `Venus_Submit`: a memory object, an offset and a length. The service copies the stream out of the client memory, decodes it whole with the decoder of `venus_vulkan`, and sends the copy in one `SUBMIT_3D`. The device then receives the bytes that the service checked, and a client that changes its memory after the check changes nothing. The decoder protects the service and the host from a malformed stream; it is not the trust boundary of the content, which stays the renderer ("The chosen form").

The ring and the reply stream of the context belong to the service. A client stream holds rendering and resource commands only: `stream_validate_client` refuses the whole stream when it holds `vkCreateRingMESA`, `vkDestroyRingMESA`, `vkNotifyRingMESA`, `vkSetReplyCommandStreamMESA` or `vkSeekReplyCommandStreamMESA`, or a command with the reply flag. A client that sent them could point the renderer at the ring of the service, or make it write a reply over the replies of the service. So a client encodes its commands with no reply flag; the encoders that ask a reply by default take `{}` as their flags.

A control request that the device does not answer within the hang bound stops the service: its descriptors stay with the device, so a later request on them could read the answer of this one. A 2D scanout is replaced in the order that keeps the screen: the new resource is created, given its memory and set on the scanout, then the old resource gets `RESOURCE_UNREF`, and only after the device took it does the service close the old memory. A device that refuses the unref keeps the memory as its backing, and the service stops rather than close that memory under the device.

The service maps the blob in the host-visible region of the device, but no process maps that region yet. The kernel gives the mapping that it needs ("Write-combining device memory"); the service does not take the region of the device yet. Until then the service reports the cache type, the commands go through `SUBMIT_3D`, and no reply is read.

### Write-combining device memory

The host-visible region of a VirtIO-GPU is device memory that the processor fills and the device reads: the ring, the reply stream, the vertices of a frame. Mapped with no cache, as the registers of a device are, each write of 8 bytes is one bus transaction. Write-combining gathers the writes in a buffer of the processor and sends them in bursts of a cache line; a read is not cached, so the processor reads what the device wrote.

- **The page attribute table of the kernel.** At the setup of each processor, before any process, the kernel writes the register `IA32_PAT` (0x277) with write-combining at the entry 1 (the bit `PWT` alone) and at the entry 5. The table at reset has write-through there, and no page of the kernel or of the boot selects it, so no mapping changes its type and no cache needs a flush. The entry 3 (`PWT` and `PCD`) stays uncacheable, for the registers of a device. The word and its entries are in `modulus:page_attributes`, with host tests.
- **The flag `Write_Combining` of `Memory_Map`.** A device service maps device memory of `Device_Kind.Memory` with it: the entry gets `PWT` alone, not `PWT` and `PCD`. The service makes one memory object for the registers and one for the shared region, and chooses the type of each mapping. `Process_Mapping_Flag.Write_Combining` names such a mapping in the reports.
- **One cache type for each memory object of a device.** Two cache types over one frame break the coherence of the caches: a write that one mapping combines can pass a read through the other. So each memory object that `Device_Create` made, and the framebuffer of the firmware, counts its live mappings of each type (no cache, write-combining, the entry 0 of a screen), under the frame lock. `Memory_Map` refuses a mapping (`Bad_State`, error kind `Object_Shared`) when a live mapping of another type exists through this object or through another object whose physical pages meet its pages: `Device_Create` can give one range twice. The count is for each object, not for each page: a conflict over one page refuses the whole object, which is stricter than the rule and costs nothing on the machines of the tests. The check is the last check of a map, and reads each memory object; only a map of such an object pays it, which a device service and the compositor make once at their start. The time page, the log and the images of the boot are device memory for the kernel but normal memory for the processor: their maps do not count.
- **Refused on other memory.** `Memory_Map` refuses `Write_Combining` (`Bad_Operation`) on normal memory: the kernel reads and writes those frames through its direct map, write-back. It refuses it on the memory of a screen (`Display_Memory`), whose type is the one of the firmware, and with `Execute`: the processor would fetch code from memory that it does not cache. `Memory_Protect` does not take it: the cache type of a mapping is fixed at its creation, and a protection keeps it.
- **The direct map over device memory.** The boot program maps the physical addresses with the entry 0 of the table, the addresses of devices too, above 4 GiB as below. There, a frame of a device takes the type of the memory type ranges of the firmware, uncacheable for the ranges of devices on the machines of the tests. The kernel reads and writes no frame of device memory through the direct map, but the registers of the IOMMU, which `Device_Create` refuses to give. So the direct map is an alias that no access uses; the counts above do not include it.
- **No new kernel operation.** The cache type is a flag of `Memory_Map`, as `At_Address_Zero` is ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface").

### The Vulkan objects

The encoders create the objects that a 2D frame names, in the one shape that the draw table needs, so each encoder has few parameters and the decoder reads a fixed order:

- **An image is 2D**, with one sample, one mip level and one layer, exclusive to one queue, and created in the layout `UNDEFINED`. A barrier gives it its first layout; the decoder refuses another initial layout.
- **A render pass has one color attachment and one subpass**, and no subpass dependency: the barriers of the command buffer order the work around the pass. A final layout `UNDEFINED` is refused, as Vulkan refuses it.
- **A pipeline has a vertex and a fragment stage**, one vertex binding, no depth test and no logic operation, and takes the viewport and the scissor as dynamic state. One pipeline then serves each size of surface, and each clip is a `vkCmdSetScissor`, not a pipeline.
- **The SPIR-V of a shader module is checked** on both sides with the check of the WebGPU subset: the header and the length of each instruction.
- **A barrier transitions an image**, and a global memory barrier makes the writes of the transfers visible. A transition to `UNDEFINED` is refused. The layout of a present, `PRESENT_SRC_KHR`, is a member of the layouts, for the scanout that comes later.
- **The data of a buffer travels in the stream**, with `vkCmdUpdateBuffer`: at most 65536 bytes, a multiple of 4. No process maps the host-visible memory yet ("The Venus context of the service").

### The draw table on the virtual GPU

A draw table becomes a frame on the GPU in two steps, each of an existing contract: `webgpu_subset.draw_table_translate_to_webgpu` makes a stream of the WebGPU subset with its vertices and its indices, then `venus_vulkan.draw_table_to_venus` makes the Venus stream of one frame. The drawing module gives it as the export `draw_table_to_venus_20` ([`docs/INTERFACE.md`](../../../docs/INTERFACE.md), section 7).

- **The objects are created once.** `encode_draw_table_venus_objects` writes the image, its memory and its view, the render pass, the framebuffer, the two shader modules, the pipeline layout, the 2D pipeline, and the vertex, the index and the readback buffers. Each object has the id of its base plus its number in the WebGPU subset, as in the WebGPU back end: a frame names the objects with no table of ids.
- **One frame is one command buffer**: the upload of the vertices and the indices; the barrier of the image to `COLOR_ATTACHMENT_OPTIMAL`, from `UNDEFINED` when the frame clears, from `TRANSFER_SRC_OPTIMAL` when it keeps the last frame; the viewport and the push constants of the surface size; the render pass with its pipeline, its buffers, a scissor for each clip and the indexed draws; the barrier to `TRANSFER_SRC_OPTIMAL`; `vkCmdCopyImageToBuffer` into the readback buffer; a barrier to the host; then `vkQueueSubmit`.
- **The vertex shader takes pixels.** The vertices of the WebGPU subset are in pixels of the surface, as the processor back end reads them; the two push constants are the width and the height, and the shader turns a pixel into a place of the viewport.
- **A frame fits in one packet.** The stream, with its vertices, is at most the 65536 bytes of one `SUBMIT_3D`: a larger table is refused whole, and the caller draws it on the processor. A table of 300 rectangles fits, and one of 600 does not (the host test `oversized_draw_table_is_refused`).
- **Nothing is written on a refusal.** The stream is measured before it is written: a refused table, target or size writes no byte of the output.
- **The processor path does not change.** A caller with no virtual GPU calls `execute_draw_table_in_rectangles_20`. The new export draws no pixel.

What the GPU draws is not yet the pixels of the processor: a text and a grid are a quad of the color of the record, a picture is a white quad. The glyphs and the pictures need a sampled texture, which needs descriptor sets.

## The refused forms

| Form | Why refused, or when |
|---|---|
| A Windows driver loaded outside Windows | It needs an NT kernel around it. See [foreign_systems.md](foreign_systems.md) |
| The whole GPU given to one guest | The guest gets native speed, and native processes never use the GPU. It does not reach the aim. It stays as a test of the IOMMU, with the display of the guest inside a surface |
| A device service for the GPU, written for the system | It removes the guest, but it is one device service for each vendor. The open kernel modules of one vendor are about 2.2 million lines; the smallest known form is a multiplexer for one family of integrated GPUs. Only for a fixed machine that must run with no guest |
| The kernel interface of one vendor's driver carried to the client ("native context") | Faster: within a few percent of native. But each client then holds the user-space driver of that vendor, of 100 000 lines and more. Not the first form: it comes after the measure, for one vendor |
| The older protocol of the virtual GPU, which carries OpenGL state | The wrong shape for the one graphics interface |
| A stream of the graphics interface itself sent to an implementation in the guest | It removes the Vulkan back end from the system, but it puts in the guest an implementation that the project did not write, and the virtual GPU of QEMU does not carry it. One mechanism on both transports is preferred |
| An existing implementation of the graphics interface, ported into the code of the system | The property forbids it in the code of the system. For a module of a third party it stays open, over the WebGPU of the system |
| A wire format of the system, framed like Venus | The renderer of the host reads only the format of Mesa; a format of the system needs a renderer of the system on the host |
| A decoder driven by a table of field kinds for each command | One interpreter for all commands, but each command still needs its table, and the tables hide the order of the Vulkan parameters that the encoders show. The decoder is one case for each command, in the order of the encoder |
| A compiler of WGSL in the system, for the GPU or for the processor | The build compiles the shaders; a compiler for the processor is larger than the whole 2D drawing |
| A kind of `Device_Create` for write-combining memory | The cache type is a property of a mapping, not of the memory: one region of a device holds registers and a shared region. A kind of its own makes a second handle for one range |
| The cache type that `RESOURCE_MAP_BLOB` gives, applied by the kernel | The kernel would read a word of one device protocol. The service reads the cache type and asks for the mapping |
| Write-combining on normal memory | Its frames are write-back in the direct map of the kernel, which the kernel uses: two types over one frame break the coherence of the caches |
| The cache type fixed for the life of a memory object at its first mapping | Smaller than the counts, but a second `Device_Create` of the same range is a new object with no history, so the rule would not hold across objects |
| Two cache types over one frame left to the service | One mapping of each type is enough to lose a write, and a second service that holds the same range breaks the first one |

## The numbers behind the choice

- The whole GPU given to one guest: 98 to 100 % of native.
- The chosen serialization: 45 to 77 % of native on one discrete GPU in the published measures, and "close to native" in other reports. The limit is the synchronization between the two sides.
- The native context: within a few percent.

The chosen form is the most modular one: any GPU with a Linux Vulkan driver works with no change of the system. The measured cost is the price of that. The fraction of native speed that is enough is fixed before the measure: 80 %. The native context for one vendor is wanted too, as a second form after the measure, and not only when the measure is below that fraction.

## The order

1. The draw table on the processor. It fixes the 2D interface that each later step keeps. A software WebGPU is refused: it needs a compiler of WGSL for the processor, larger than the whole 2D drawing.
2. The service of the virtual GPU under QEMU, in three steps: the 2D scanout of the compositor, then Vulkan to the host through Venus, then the WebGPU subset on it. It needs one new thing of the kernel: a device mapping with the cache type that the device gives. It brings the encoder and the back end, which the next steps reuse with no change.
3. The IOMMU, then guest support.
4. The driver domain over a ring, on one GPU, as an opt-in test. The machine is a laptop with an integrated GPU of Intel.
5. The measure against the same GPU under Linux with the same program.
6. The native context, then a native driver later.

The test of the serialization under QEMU on the development host is an opt-in test.

## The subtle points

- **The compositor keeps the display.** The first form renders only: the compositor keeps the framebuffer of the firmware or the scanout of the virtual GPU, and receives rendered surfaces. The display of the guest comes later.
- **Compute needs no second interface.** The one graphics interface has compute pipelines. The vendor compute stacks exist only with the full driver of the vendor: inside a guest that owns the GPU, not for native processes.
- **A buffer with no copy.** The memory of the guest is made of memory objects of the system. A buffer that the guest allocates can be mapped into a client with no copy, when the guest reports its pages. That needs a small helper in the guest that does not exist. The first version can copy.
- **The driver domain is trusted for the content of the GPU.** It can read and change what each client renders. The rest of the system does not trust it.
- **The image of the driver domain is a resource by hash**, not a disk that changes.

## Not verified

- Whether a software Vulkan driver on the test host is enough for the serialization. If not, the test of the virtual GPU is opt-in.
- The size of an encoder for only the commands that the back end uses.
- Which machine and which GPU: the system must boot on it directly, the GPU must be alone in its IOMMU group, and it must reset.

## State

Built:

- `src/library/modus/contract/virtio_gpu`: the VirtIO-GPU 1.2 control queue header, closed enumerations (`Command_Type`, `Pixel_Format`, `Capset_Id`, `Blob_Memory`, `Map_Cache`, `Header_Flags`, `Blob_Flags`, `Venus_Support`), 2D scanout lifecycle encoders and decoders (`Get_Display_Info`, `Resource_Create_2D`, `Resource_Attach_Backing`, `Set_Scanout`, `Transfer_To_Host_2D`, `Resource_Flush`, `Resource_Unref`), and the 3D, capset and blob commands (`Get_Capset_Info`, `Get_Capset`, `Ctx_Create`, `Ctx_Destroy`, `Ctx_Attach_Resource`, `Ctx_Detach_Resource`, `Resource_Create_Blob`, `Resource_Map_Blob`, `Resource_Unmap_Blob`, `Submit_3D`) with border validation and host tests.
- `src/library/modus/contract/venus_vulkan`: the Venus wire of Mesa ("The Venus wire"): the encoders of `vkCreateInstance`, `vkEnumeratePhysicalDevices`, `vkGetPhysicalDeviceProperties`, `vkCreateDevice`, `vkGetDeviceQueue2`, `vkCreateBuffer`, `vkAllocateMemory`, `vkBindBufferMemory`, `vkCreateCommandPool`, `vkAllocateCommandBuffers`, `vkBeginCommandBuffer`, `vkCmdCopyBuffer`, `vkCmdClearColorImage`, `vkCmdCopyBufferToImage`, the commands of a render pass and its draws, `vkEndCommandBuffer`, `vkQueueSubmit`, `vkQueueWaitIdle` and the ring and reply commands of `VK_MESA_venus_protocol`; the objects of a frame ("The Vulkan objects"): `vkCreateImage`, `vkBindImageMemory`, `vkCreateImageView`, `vkCreateShaderModule`, `vkCreatePipelineLayout`, `vkCreateRenderPass`, `vkCreateFramebuffer`, `vkCreateGraphicsPipelines`, and the recording commands `vkCmdPipelineBarrier`, `vkCmdCopyImageToBuffer`, `vkCmdUpdateBuffer`, `vkCmdPushConstants` and `vkCmdSetViewport`; the decoder of each; the reply decoders and encoders; the Venus capset; the ring; the exchange of a command and its reply through the ring and the reply stream (`venus_ring_submit_command`, `venus_ring_poll_reply`); the back end of the WebGPU subset (`webgpu_stream_to_venus`, `webgpu_stream_to_submit_3d`, `encode_webgpu_buffers`); and the frame of a draw table (`encode_draw_table_venus_objects`, `draw_table_to_venus`: "The draw table on the virtual GPU"), with adversarial host tests.
- `src/modules/libraries/drawing`: the export `draw_table_to_venus_20`, which writes the Venus stream of a draw table into the bytes of its caller, beside the draw into pixels, which does not change.
- `src/library/modus/contract/webgpu_subset`: the minimal WebGPU subset contract with closed enumerations, precompiled SPIR-V binary validation (`spirv_header_validate`, `spirv_bytes_validate`) with no runtime WGSL compiler, binary command stream encoding and border validation (`Gpu_Command_Stream`, `stream_validate`), the Draw Table v20 to WebGPU subset translator (`draw_table_translate_to_webgpu`), and the processor 3D and 2D rasterizer back end (`software_3d_execute` with `Solid_Color_2D` and `Vertex_Color_3D`, 4x4 MVP transforms, 24-bit depth testing, scissor clipping, and linear-light alpha blending; its triangles have an SSE2 vector form of four pixels that gives the bytes of the scalar form: `docs/SIMD.md`, "11. The triangles of the WebGPU subset"), with adversarial and end-to-end host tests.
- The screen of the compositor through the 2D scanout, on the machine of `modustool run` and in the part `gpu_scanout` ([../infrastructure/whole_frame.md](../infrastructure/whole_frame.md), "The screen through the scanout of the virtual GPU").
- `src/modules/system/gpu_device`: the freestanding VirtIO-GPU PCI device service (`0x1AF4:0x1050`) that initializes the control queue, queries display geometry, binds client 2D scanout framebuffers, presents each frame of its client as one batch of the transfer and the flush of each damage rectangle, and, on a device that carries Venus, creates the Venus context and its ring blob and submits client Venus streams (`Venus_Info`, `Venus_Submit`).

Left:

- The mapping of the host-visible region by the service, with `Write_Combining` ("Write-combining device memory"), then the ring and the reply stream in it: until then the service reads no reply of the host. The kernel side is built: the page attribute table and the flag, with host tests. The exchange of `venus_vulkan` is ready for it and is checked by host tests only, against a renderer of the tests.
- The descriptor sets and the sampled textures that the glyphs and the pictures of a frame need: on the GPU they are quads of one color.
- The shaders of the 2D pipeline, compiled from WGSL to SPIR-V by the build, and a caller of `draw_table_to_venus_20`: the window layer and the compositor still draw on the processor.
- A frame larger than one `SUBMIT_3D` packet: it needs the ring, or the mapped memory of the device for the vertices.
- The opt-in machine test under QEMU with Venus: no test has run these commands on a host yet.
- The Linux driver domain transport over a shared-memory ring on real hardware.
