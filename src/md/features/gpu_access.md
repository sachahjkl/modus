# The access to a GPU for acceleration

Processes of the system draw in 2D through the draw table, and WebGPU is the later interface of the GPU: [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "18. One 2D interface: the draw table". When a GPU exists, the drawing module draws the draw table through WebGPU ([../api/draw_table.md](../api/draw_table.md), "The execution"). This file records how WebGPU reaches a real GPU, and which forms were refused. The access to a GPU for acceleration is the aim of the work on guests; compatibility with another system is not ([foreign_systems.md](foreign_systems.md)). Among the forms, the most performant and the most modular one is chosen. The first layers (VirtIO-GPU 2D scanout, the Venus wire protocol of Mesa, the Venus context of the `gpu_device` service, and the WebGPU subset with its processor and Venus back ends) are built; see "State".

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
- **The replies.** A command with the reply flag writes its reply in the reply stream that `vkSetReplyCommandStreamMESA` names. A reply decoder refuses an unknown `VkResult` and checks that the renderer echoes each object id that the command bound.

### The Venus context of the service

The GPU device service probes the features `VIRGL`, `RESOURCE_BLOB` and `CONTEXT_INIT` and the capsets at its start, beside the 2D scanout. When all four parts exist, it reads the Venus capset (`GET_CAPSET`), refuses a capset whose wire format is not 1, creates one context with `CTX_CREATE` and the Venus capset in `context_init`, then the blob of its ring: `RESOURCE_CREATE_BLOB` of host memory with the blob id 0, `CTX_ATTACH_RESOURCE`, `RESOURCE_MAP_BLOB`. A device with no 3D feature logs nothing more and keeps its 2D scanout as before; a device with a 3D feature and no Venus logs why.

A client sends a Venus stream with `Venus_Submit`: a memory object, an offset and a length. The service copies the stream out of the client memory, decodes it whole with the decoder of `venus_vulkan`, and sends the copy in one `SUBMIT_3D`. The device then receives the bytes that the service checked, and a client that changes its memory after the check changes nothing. The decoder protects the service and the host from a malformed stream; it is not the trust boundary of the content, which stays the renderer ("The chosen form").

The service maps the blob in the host-visible region of the device, but no process maps that region yet: it needs the device mapping of the kernel with the cache type that `RESOURCE_MAP_BLOB` gives (step 2 of "The order"). Until then the service reports the cache type, the commands go through `SUBMIT_3D`, and no reply is read.

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
- `src/library/modus/contract/venus_vulkan`: the Venus wire of Mesa ("The Venus wire"): the encoders of `vkCreateInstance`, `vkEnumeratePhysicalDevices`, `vkGetPhysicalDeviceProperties`, `vkCreateDevice`, `vkGetDeviceQueue2`, `vkCreateBuffer`, `vkAllocateMemory`, `vkBindBufferMemory`, `vkCreateCommandPool`, `vkAllocateCommandBuffers`, `vkBeginCommandBuffer`, `vkCmdCopyBuffer`, `vkCmdClearColorImage`, `vkCmdCopyBufferToImage`, the commands of a render pass and its draws, `vkEndCommandBuffer`, `vkQueueSubmit`, `vkQueueWaitIdle` and the ring and reply commands of `VK_MESA_venus_protocol`; the decoder of each; the reply decoders and encoders; the Venus capset; the ring; and the back end of the WebGPU subset (`webgpu_stream_to_venus`, `webgpu_stream_to_submit_3d`, `encode_webgpu_buffers`), with adversarial host tests.
- `src/library/modus/contract/webgpu_subset`: the minimal WebGPU subset contract with closed enumerations, precompiled SPIR-V binary validation (`spirv_header_validate`, `spirv_bytes_validate`) with no runtime WGSL compiler, binary command stream encoding and border validation (`Gpu_Command_Stream`, `stream_validate`), the Draw Table v20 to WebGPU subset translator (`draw_table_translate_to_webgpu`), and the processor 3D and 2D rasterizer back end (`software_3d_execute` with `Solid_Color_2D` and `Vertex_Color_3D`, 4x4 MVP transforms, 24-bit depth testing, scissor clipping, and linear-light alpha blending; its triangles have an SSE2 vector form of four pixels that gives the bytes of the scalar form: `docs/SIMD.md`, "11. The triangles of the WebGPU subset"), with adversarial and end-to-end host tests.
- `src/modules/system/gpu_device`: the freestanding VirtIO-GPU PCI device service (`0x1AF4:0x1050`) that initializes the control queue, queries display geometry, binds client 2D scanout framebuffers, flushes damaged rectangles, and, on a device that carries Venus, creates the Venus context and its ring blob and submits client Venus streams (`Venus_Info`, `Venus_Submit`).

Left:

- Wiring `gpu_device` to the compositor as an alternative scanout back end beside standard VGA, and the QEMU virtio-gpu machine test.
- The device mapping of the kernel for the host-visible region, then the ring and the reply stream in it: until then the service reads no reply of the host.
- The Vulkan objects that a translated stream names (images, render passes, framebuffers, pipelines, descriptor sets) and the layout transitions of the images (`vkCmdPipelineBarrier`): the back end records commands on objects that it does not create yet.
- Wiring `draw_table_translate_to_webgpu` and `webgpu_stream_to_venus` into the drawing module.
- The opt-in machine test under QEMU with Venus: no test has run these commands on a host yet.
- The Linux driver domain transport over a shared-memory ring on real hardware.
