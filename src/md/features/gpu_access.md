# The access to a GPU for acceleration

Processes of the system draw in 2D through the draw table, and WebGPU is the later interface of the GPU: [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "18. One 2D interface: the draw table". When a GPU exists, the drawing module draws the draw table through WebGPU ([../api/draw_table.md](../api/draw_table.md), "The execution"). This file records how WebGPU reaches a real GPU, and which forms were refused. The access to a GPU for acceleration is the aim of the work on guests; compatibility with another system is not ([foreign_systems.md](foreign_systems.md)). Among the forms, the most performant and the most modular one is chosen. Nothing of it is built.

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
