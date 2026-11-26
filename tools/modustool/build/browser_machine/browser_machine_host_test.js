// The tests of the stage tracker of the host (browser_machine.md, "The boot
// stages of the page"). `modustool browser-machine boot` runs them in Node
// before the machine; the path of the host is the first argument. Each
// failure names its case, and the exit code is 1.
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
const host = await import(pathToFileURL(resolve(process.argv[1])).href);
const failures = [];
const expect = (condition, text) => { if (!condition) failures.push(text); };
const tag = (name) => host.BOOT_STAGE_FACT_TAGS[name];
const hex = (text) => Array.from(new TextEncoder().encode(text), (byte) => byte.toString(16).padStart(2, "0")).join("");
const tracker = (desktop) => {
  const seen = [];
  const value = new host.BootStageTracker({ desktop, onStage: (stage) => seen.push(stage) });
  value.enter(host.BootStage.Kernel);
  return { value, seen };
};

// Lines that are not the line of a fact: no stage.
{
  const { value, seen } = tracker(true);
  for (const line of [
    "[root] #3d2ffd19:" + tag("root::Boot_Image_Agrees") + "x", // A key tag of 7 characters: no space before the values.
    "[root] #3d2ffd1:" + tag("root::Boot_Image_Agrees"), // A module tag of 7 digits.
    "[root] #3d2ffd19:" + tag("root::Boot_Image_Agrees").slice(0, 5), // A key tag of 5 digits.
    "root #3d2ffd19:" + tag("root::Boot_Image_Agrees"), // No process in brackets.
    " [root] #3d2ffd19:" + tag("root::Boot_Image_Agrees"), // A space before.
    "[Root] #3d2ffd19:" + tag("root::Boot_Image_Agrees"), // A process name that is not lower case.
    "[root] #3D2FFD19:" + tag("root::Boot_Image_Agrees"), // Upper case digits.
    "[root] root: the boot image agrees", // The rendered sentence, which the serial line never holds.
  ]) value.serialLine(line);
  expect(seen.length === 1, "a line that is not a fact line changed the stage: " + seen.join(","));
}

// The tag of a fact of another process: no stage.
{
  const { value, seen } = tracker(true);
  value.serialLine("[compositor] #3d2ffd19:" + tag("root::Boot_Image_Agrees"));
  value.serialLine("[root] #3d2ffd19:" + tag("compositor::First_Frame"));
  expect(seen.length === 1, "the tag of a fact of another process changed the stage: " + seen.join(","));
}

// The start of another process than the compositor, a name that begins
// with "compositor", and the console on the desktop: no stage.
{
  const { value, seen } = tracker(true);
  value.serialLine(host.ROOT_SERVICE_STAGE_LINE + "1 us");
  value.serialLine("[root] #3d2ffd19:" + tag("root::Boot_Image_Agrees") + " 10");
  value.serialLine("[root] #3d2ffd19:" + tag("root::Process_Started") + " " + hex("console"));
  value.serialLine("[root] #3d2ffd19:" + tag("root::Process_Started") + " " + hex("compositor2"));
  value.serialLine("[root] #3d2ffd19:" + tag("root::Process_Started_With_Terminal") + " " + hex("console"));
  expect(seen.join(",") === "kernel,image_check,services", "a start that is not the compositor changed the stage: " + seen.join(","));
}

// A stage comes once, in order: a line of an earlier stage, a second line
// of the same stage, and a start again (the rescue start policy) change
// nothing.
{
  const { value, seen } = tracker(true);
  value.serialLine(host.ROOT_SERVICE_STAGE_LINE + "1 us");
  value.serialLine(host.ROOT_SERVICE_STAGE_LINE + "1 us");
  value.serialLine("[root] #3d2ffd19:" + tag("root::Boot_Image_Agrees") + " 10");
  value.serialLine("[root] #3d2ffd19:" + tag("root::Process_Started") + " " + hex("compositor"));
  value.serialLine(host.ROOT_SERVICE_STAGE_LINE + "1 us");
  value.serialLine("[root] #3d2ffd19:" + tag("root::Process_Started") + " " + hex("compositor"));
  value.serialLine("[compositor] #22af003a:" + tag("compositor::First_Frame"));
  value.serialLine("[compositor] #22af003a:" + tag("compositor::First_Frame"));
  expect(seen.join(",") === "kernel,image_check,services,desktop,ready", "the stages of a desktop: " + seen.join(","));
}

// The console: its start, then the first line of its prompt on COM2.
{
  const { value, seen } = tracker(false);
  value.serialLine(host.ROOT_SERVICE_STAGE_LINE + "1 us");
  value.serialLine("[root] #3d2ffd19:" + tag("root::Boot_Image_Agrees") + " 10");
  value.serialLine("[compositor] #22af003a:" + tag("compositor::First_Frame"));
  value.serialLine("[root] #3d2ffd19:" + tag("root::Process_Started") + " " + hex("console"));
  value.consoleLine('{"t":"clr"}');
  expect(seen.join(",") === "kernel,image_check,services", "the console before its start: " + seen.join(","));
  value.serialLine("[root] #3d2ffd19:" + tag("root::Process_Started_With_Terminal") + " " + hex("console"));
  value.consoleLine('{"t":"edit","text":"> "}');
  value.consoleLine('{"t":"edit","text":"> "}');
  expect(seen.join(",") === "kernel,image_check,services,console,ready", "the stages of a console: " + seen.join(","));
}

// Each form of the check of the root service ends the stage of the check.
for (const name of ["root::Boot_Image_Agrees", "root::Image_Checked_At_Load"]) {
  const { value, seen } = tracker(false);
  value.serialLine(host.ROOT_SERVICE_STAGE_LINE + "1 us");
  value.serialLine("[root] #3d2ffd19:" + tag(name) + " 10");
  expect(seen.join(",") === "kernel,image_check,services", "the end of the check by " + name + ": " + seen.join(","));
}

// A line of a later stage moves past the stages before it, once.
{
  const { value, seen } = tracker(true);
  value.serialLine("[compositor] #22af003a:" + tag("compositor::First_Frame"));
  value.serialLine("[root] #3d2ffd19:" + tag("root::Boot_Image_Agrees") + " 10");
  expect(seen.join(",") === "kernel,ready", "a later stage first: " + seen.join(","));
}

// DomTerminalAccumulator: multi-span output assembly, clr reset, edit readiness,
// and refusal of malformed lines.
{
  const acc = new host.DomTerminalAccumulator();
  expect(!acc.ready && !acc.hasLineContaining("1536 KiB"), "accumulator starts empty");
  expect(!acc.feed("not-json"), "malformed JSON ignored");
  expect(!acc.feed('{"t":"unknown"}'), "unknown record ignored");
  expect(acc.feed('{"t":"edit","text":"> ","cur":2}'), "edit record accepted");
  expect(acc.ready, "edit marks accumulator ready");
  expect(acc.feed('{"t":"out","s":"1536","code":"number"}'), "first span accepted");
  expect(acc.feed('{"t":"out","s":" KiB","code":"unit","nl":true}'), "second span with nl accepted");
  expect(acc.hasLineContaining("1536 KiB"), "multi-span line assembled across runs");
  expect(acc.lastMatchingLine("1536 KiB") === "1536 KiB", "exact assembled line returned");
  expect(acc.feed('{"t":"clr"}'), "clr accepted");
  expect(!acc.hasLineContaining("1536 KiB"), "clr drops prior output");
}

// Official BLAKE3 test vectors (byte i = i % 251) verifying JS BLAKE3 bit-for-bit.
{
  const vectors = [
    [0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"],
    [1, "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213"],
    [63, "e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b"],
    [64, "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98"],
    [65, "de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee"],
    [1023, "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11"],
    [1024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"],
    [1025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444"],
    [2048, "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a"],
    [2049, "5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030"],
    [3072, "b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2"],
    [4096, "015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969"],
    [8193, "bab6c09cb8ce8cf459261398d2e7aef35700bf488116ceb94a36d0f5f1b7bc3b"],
    [16384, "f875d6646de28985646f34ee13be9a576fd515f76b5b0a26bb324735041ddde4"],
  ];
  const input = new Uint8Array(16384);
  for (let i = 0; i < input.length; i += 1) input[i] = i % 251;
  for (const [size, expectedHex] of vectors) {
    const actual = host.blake3HashHex(host.blake3Hash(input.subarray(0, size)));
    expect(actual === expectedHex, "blake3 vector size " + size + ": got " + actual + ", want " + expectedHex);
  }
}

// Chunked, Bao-verified streaming of a virtual 20 MiB + 13 B blob (21 frames of
// 1 MiB, strictly past BROWSER_CACHE_OBJECT_LIMIT = 16 MiB) + adversarial refusals.
{
  const FRAME_SIZE = host.OBJECT_FRAME_PAYLOAD_BYTES;
  const LARGE_SIZE = 20 * FRAME_SIZE + 13; // 20,971,533 bytes (> 16 MiB), 21 frames.
  const makeVirtualFrame = (frameIndex, length) => {
    const buf = new Uint8Array(length);
    const seed = (frameIndex * 37 + 11) & 0xff;
    for (let i = 0; i < length; i += 1) buf[i] = (seed + (i & 0xff) + ((i >>> 8) & 0xff)) & 0xff;
    return buf;
  };
  const tree = host.objectFrameTreeBuild({ objectSize: LARGE_SIZE, readFrame: makeVirtualFrame, frameBytes: FRAME_SIZE });
  expect(tree.frameCount === 21, "20 MiB + 13 B blob has 21 frames, got " + tree.frameCount);
  expect(tree.outboard.byteLength === 20 * host.OBJECT_OUTBOARD_ENTRY_SIZE, "outboard size matches (n - 1) * 64");

  const makeStreamBody = (bytes, chunkSize = 262144) => new ReadableStream({
    start(controller) {
      for (let at = 0; at < bytes.byteLength; at += chunkSize) {
        controller.enqueue(bytes.subarray(at, Math.min(at + chunkSize, bytes.byteLength)));
      }
      controller.close();
    },
  });

  const makeMockServer = ({ mutateFrame = null, mutateOutboard = null, overrideResponse = null } = {}) => {
    return async (url, init = {}) => {
      if (overrideResponse) {
        const overridden = overrideResponse(url, init);
        if (overridden) return overridden;
      }
      const method = init.method || "GET";
      const rangeHeader = init.headers?.Range || init.headers?.range || "";
      if (url === "https://cache.example/blobs/" + tree.rootHex) {
        if (method === "HEAD") {
          return new Response(null, { status: 200, headers: { "content-length": String(LARGE_SIZE) } });
        }
        const match = /^bytes=(\d+)-(\d+)$/.exec(rangeHeader);
        if (!match) return new Response(null, { status: 416 });
        const start = Number(match[1]);
        const end = Number(match[2]);
        if (start % FRAME_SIZE !== 0 || end < start || end >= LARGE_SIZE) return new Response(null, { status: 416 });
        const frameIndex = start / FRAME_SIZE;
        const expectedLength = host.objectFrameLength(LARGE_SIZE, frameIndex, FRAME_SIZE);
        if (end - start + 1 !== expectedLength) return new Response(null, { status: 416 });
        const frame = makeVirtualFrame(frameIndex, expectedLength);
        if (mutateFrame) mutateFrame(frameIndex, frame);
        return new Response(makeStreamBody(frame), {
          status: 206,
          headers: {
            "content-length": String(frame.byteLength),
            "content-range": "bytes " + start + "-" + end + "/" + LARGE_SIZE,
          },
        });
      }
      if (url === "https://cache.example/outboards/" + tree.rootHex) {
        const match = /^bytes=(\d+)-(\d+)$/.exec(rangeHeader);
        if (!match) return new Response(null, { status: 416 });
        const start = Number(match[1]);
        const end = Number(match[2]);
        if (end >= tree.outboard.byteLength || start > end) return new Response(null, { status: 416 });
        const slice = Uint8Array.from(tree.outboard.subarray(start, end + 1));
        if (mutateOutboard) mutateOutboard(start, slice);
        return new Response(makeStreamBody(slice, 64), {
          status: 206,
          headers: {
            "content-length": String(slice.byteLength),
            "content-range": "bytes " + start + "-" + end + "/" + tree.outboard.byteLength,
          },
        });
      }
      return new Response(null, { status: 404 });
    };
  };

  // 1. Valid >16 MiB multi-frame streaming via HEAD + Range + /outboards/ Range proofs.
  {
    const bridge = new host.ObjectCacheBridge({ baseUrl: "https://cache.example", fetchProcedure: makeMockServer() });
    let peakFrameBytes = 0;
    let seenFrames = 0;
    const streamed = await bridge.streamBlob(tree.rootHex, {
      onFrame: (bytes, info) => {
        if (bytes.byteLength > peakFrameBytes) peakFrameBytes = bytes.byteLength;
        expect(info.frameIndex === seenFrames, "frames arrive in order");
        expect(info.offset === seenFrames * FRAME_SIZE, "frame offset matches index");
        seenFrames += 1;
      },
    });
    expect(streamed.status === host.BrowserCacheStatus.Ok, "20 MiB+13B streamBlob succeeded: status=" + streamed.status);
    expect(streamed.totalBytes === LARGE_SIZE, "streamed exact 20 MiB + 13 B");
    expect(seenFrames === 21, "delivered all 21 verified frames");
    expect(peakFrameBytes === FRAME_SIZE && peakFrameBytes <= host.BROWSER_CACHE_STREAM_BUFFER_LIMIT, "peak buffered payload stays at 1 MiB");
  }

  // 2. Tampered byte in frame 0, frame 17 (past 16 MiB), and last frame 20 -> Hash_Mismatch.
  for (const badFrame of [0, 17, 20]) {
    const bridge = new host.ObjectCacheBridge({
      baseUrl: "https://cache.example",
      fetchProcedure: makeMockServer({
        mutateFrame: (idx, frame) => { if (idx === badFrame) frame[frame.byteLength - 1] ^= 0x01; },
      }),
    });
    const res = await bridge.fetchBlobFrame(tree.rootHex, { objectSize: LARGE_SIZE, frameIndex: badFrame });
    expect(res.status === host.BrowserCacheStatus.Hash_Mismatch && res.bytes === null, "tampered frame " + badFrame + " refused with Hash_Mismatch");
  }

  // 3. Tampered Bao sibling proof entry -> Hash_Mismatch.
  {
    const bridge = new host.ObjectCacheBridge({
      baseUrl: "https://cache.example",
      fetchProcedure: makeMockServer({ mutateOutboard: (_start, slice) => { slice[0] ^= 0x80; } }),
    });
    const res = await bridge.fetchBlobFrame(tree.rootHex, { objectSize: LARGE_SIZE, frameIndex: 17 });
    expect(res.status === host.BrowserCacheStatus.Hash_Mismatch && res.bytes === null, "tampered Bao proof refused with Hash_Mismatch");
  }

  // 4. Truncated and oversized explicit proof -> Invalid_Request.
  {
    const bridge = new host.ObjectCacheBridge({ baseUrl: "https://cache.example", fetchProcedure: makeMockServer() });
    const goodProof = host.objectProofFromOutboard(tree.outboard, LARGE_SIZE, 17, FRAME_SIZE);
    const shortRes = await bridge.fetchBlobFrame(tree.rootHex, { objectSize: LARGE_SIZE, frameIndex: 17, proof: goodProof.subarray(0, goodProof.byteLength - 1) });
    expect(shortRes.status === host.BrowserCacheStatus.Invalid_Request, "truncated proof refused");
    const longProof = new Uint8Array(goodProof.byteLength + 32);
    longProof.set(goodProof, 0);
    const longRes = await bridge.fetchBlobFrame(tree.rootHex, { objectSize: LARGE_SIZE, frameIndex: 17, proof: longProof });
    expect(longRes.status === host.BrowserCacheStatus.Invalid_Request, "oversized proof refused");
  }

  // 5. Bad Content-Range header (wrong start, wrong end, wrong total, missing) -> Invalid_Request.
  for (const badHeader of [null, "bytes 0-1048575/1048576", "bytes 1-1048575/" + LARGE_SIZE, "bytes 0-1048574/" + LARGE_SIZE, "bytes 0-1048575/*"]) {
    const bridge = new host.ObjectCacheBridge({
      baseUrl: "https://cache.example",
      fetchProcedure: makeMockServer({
        overrideResponse: (url) => {
          if (!url.includes("/blobs/")) return null;
          const headers = { "content-length": String(FRAME_SIZE) };
          if (badHeader !== null) headers["content-range"] = badHeader;
          return new Response(makeStreamBody(makeVirtualFrame(0, FRAME_SIZE)), { status: 206, headers });
        },
      }),
    });
    const res = await bridge.fetchBlobFrame(tree.rootHex, { objectSize: LARGE_SIZE, frameIndex: 0 });
    expect(res.status === host.BrowserCacheStatus.Invalid_Request, "bad Content-Range " + String(badHeader) + " refused");
  }

  // 6. Server ignores Range and sends 200 OK on multi-frame blob -> Too_Large (never buffered).
  {
    const bridge = new host.ObjectCacheBridge({
      baseUrl: "https://cache.example",
      fetchProcedure: makeMockServer({
        overrideResponse: (url) => url.includes("/blobs/")
          ? new Response(makeStreamBody(makeVirtualFrame(0, FRAME_SIZE)), { status: 200, headers: { "content-length": String(LARGE_SIZE) } })
          : null,
      }),
    });
    const res = await bridge.fetchBlobFrame(tree.rootHex, { objectSize: LARGE_SIZE, frameIndex: 0 });
    expect(res.status === host.BrowserCacheStatus.Too_Large && res.bytes === null, "200 OK on multi-frame blob refused with Too_Large");
  }

  // 7. Server streams 1 byte past frame length despite no Content-Length -> Too_Large.
  {
    const overFrame = new Uint8Array(14);
    const bridge = new host.ObjectCacheBridge({
      baseUrl: "https://cache.example",
      fetchProcedure: makeMockServer({
        overrideResponse: (url) => url.includes("/blobs/")
          ? new Response(makeStreamBody(overFrame, 14), {
              status: 206,
              headers: { "content-range": "bytes " + (20 * FRAME_SIZE) + "-" + (LARGE_SIZE - 1) + "/" + LARGE_SIZE },
            })
          : null,
      }),
    });
    const res = await bridge.fetchBlobFrame(tree.rootHex, { objectSize: LARGE_SIZE, frameIndex: 20 });
    expect(res.status === host.BrowserCacheStatus.Too_Large, "oversized frame stream refused with Too_Large");
  }

  // 8. Out-of-range index, HTTP 416, HTTP 404, zero hash, unconfigured bridge.
  {
    const unconfigured = new host.ObjectCacheBridge({});
    const unconfRes = await unconfigured.fetchBlobFrame(tree.rootHex, { objectSize: LARGE_SIZE, frameIndex: 0 });
    expect(unconfRes.status === host.BrowserCacheStatus.Not_Configured, "unconfigured bridge refused");

    const bridge = new host.ObjectCacheBridge({ baseUrl: "https://cache.example", fetchProcedure: makeMockServer() });
    const negRes = await bridge.fetchBlobFrame(tree.rootHex, { objectSize: LARGE_SIZE, frameIndex: -1 });
    expect(negRes.status === host.BrowserCacheStatus.Invalid_Request, "negative frame index refused");
    const pastRes = await bridge.fetchBlobFrame(tree.rootHex, { objectSize: LARGE_SIZE, frameIndex: 21 });
    expect(pastRes.status === host.BrowserCacheStatus.Invalid_Request, "past-end frame index refused");
    const zeroRes = await bridge.fetchBlobFrame("0".repeat(64), { objectSize: LARGE_SIZE, frameIndex: 0 });
    expect(zeroRes.status === host.BrowserCacheStatus.Invalid_Request, "zero hash refused");
    const absentRes = await bridge.fetchBlobFrame("a".repeat(64), { objectSize: LARGE_SIZE, frameIndex: 0 });
    expect(absentRes.status === host.BrowserCacheStatus.Absent, "404 blob gives Absent");
  }

  // 9. Single-frame 0-byte blob verifies cleanly via streamBlob.
  {
    const emptyHash = host.blake3HashHex(host.blake3Hash(new Uint8Array(0)));
    const bridge = new host.ObjectCacheBridge({
      baseUrl: "https://cache.example",
      fetchProcedure: async () => new Response(new Uint8Array(0), { status: 200, headers: { "content-length": "0" } }),
    });
    const emptyRes = await bridge.streamBlob(emptyHash, { objectSize: 0, onFrame: () => {} });
    expect(emptyRes.status === host.BrowserCacheStatus.Ok && emptyRes.totalBytes === 0 && emptyRes.frameCount === 1, "0-byte blob streams cleanly");
  }

  // 10. Regression checks: 32-bit wraparound frameBytes and oversized X-Modus-Frame-Proof header.
  {
    const wrapFrameBytes = 3 * (2 ** 32) * 1024;
    expect(host.objectFrameCount(LARGE_SIZE, wrapFrameBytes) === 0, "32-bit wraparound frameBytes refused by objectFrameCount");
    expect(host.objectFrameCount(LARGE_SIZE, host.OBJECT_FRAME_PAYLOAD_BYTES * 2) === 0, "frameBytes > 1 MiB refused by objectFrameCount");

    const hugeHexProof = "aa".repeat(host.OBJECT_MAX_PROOF_DEPTH * host.OBJECT_PROOF_ENTRY_SIZE + 1);
    const bridge = new host.ObjectCacheBridge({
      baseUrl: "https://cache.example",
      fetchProcedure: makeMockServer({
        overrideResponse: (url) => url.includes("/blobs/")
          ? new Response(makeStreamBody(makeVirtualFrame(0, FRAME_SIZE)), {
              status: 206,
              headers: {
                "content-length": String(FRAME_SIZE),
                "content-range": "bytes 0-" + (FRAME_SIZE - 1) + "/" + LARGE_SIZE,
                "x-modus-frame-proof": hugeHexProof,
              },
            })
          : null,
      }),
    });
    const res = await bridge.fetchBlobFrame(tree.rootHex, { objectSize: LARGE_SIZE, frameIndex: 0 });
    expect(res.status === host.BrowserCacheStatus.Invalid_Request && res.bytes === null, "oversized X-Modus-Frame-Proof header refused before hex parse");
  }
}

// Live viewport resize control page layout, clamping, wake packet, and ack sync.
{
  const smallLayout = host.physicalLayout({ kernelBytes: 65536, bootImageSize: 4096, framebufferWidth: 800, framebufferHeight: 600, memoryBytes: 16 * 1024 * 1024 });
  expect(smallLayout.framebufferResizeControl === 0, "small-memory layout skips live resize control page");

  const consoleLayout = host.physicalLayout({ kernelBytes: 65536, bootImageSize: 4096, framebufferWidth: 0, framebufferHeight: 0, memoryBytes: 128 * 1024 * 1024 });
  expect(consoleLayout.framebufferResizeControl === 0, "console layout with no framebuffer skips live resize control page");

  const layout = host.physicalLayout({ kernelBytes: 65536, bootImageSize: 4096, framebufferWidth: 1000, framebufferHeight: 640, memoryBytes: 64 * 1024 * 1024 });
  expect(layout.framebufferResizeControl === layout.framebuffer + host.BROWSER_RESIZE_MAX_BYTES, "live resize control page sits at framebuffer + BROWSER_RESIZE_MAX_BYTES");
  expect(layout.framebufferBytes === host.BROWSER_RESIZE_MAX_BYTES + host.PAGE_SIZE, "framebuffer backing holds max viewport plus 1 control page");

  const memory = { buffer: new ArrayBuffer(layout.total) };
  host.writeBootRecord(memory, layout, { bootImageSize: 4096, framebufferWidth: 1000, framebufferHeight: 640, startNanoseconds: 0n });
  const view = new DataView(memory.buffer);
  const base = layout.framebufferResizeControl;
  expect(view.getBigUint64(base + host.BROWSER_RESIZE_OFFSETS.magic, true) === host.BROWSER_RESIZE_MAGIC, "MODVRES1 magic written");
  expect(view.getUint32(base + host.BROWSER_RESIZE_OFFSETS.max_width, true) === host.BROWSER_RESIZE_MAX_WIDTH, "max_width written");
  expect(view.getUint32(base + host.BROWSER_RESIZE_OFFSETS.max_height, true) === host.BROWSER_RESIZE_MAX_HEIGHT, "max_height written");
  expect(view.getUint32(base + host.BROWSER_RESIZE_OFFSETS.ack_width, true) === 1000, "initial ack_width matches boot width");
  expect(view.getUint32(base + host.BROWSER_RESIZE_OFFSETS.ack_height, true) === 640, "initial ack_height matches boot height");

  const machine = new host.BrowserMachine({
    kernelModule: null,
    framebufferWidth: 1000,
    framebufferHeight: 640,
    clockNanoseconds: () => 0n,
    idleWait: () => {},
  });
  machine.memory = memory;
  machine.layout = layout;
  expect(!machine.requestResize(1000, 640), "no-op resize returns false");
  expect(machine.requestResize(9999, 100), "out-of-range resize clamps and publishes");
  expect(view.getUint32(base + host.BROWSER_RESIZE_OFFSETS.req_width, true) === host.BROWSER_RESIZE_MAX_WIDTH, "req_width clamped to max");
  expect(view.getUint32(base + host.BROWSER_RESIZE_OFFSETS.req_height, true) === host.BROWSER_RESIZE_MIN_HEIGHT, "req_height clamped to min");
  expect(view.getUint32(base + host.BROWSER_RESIZE_OFFSETS.req_seq, true) === 1, "req_seq incremented to 1");
  expect(machine.keyboard.queue.length >= 3, "zero-delta PS/2 pointer wake packet queued");
  expect(!machine.syncFramebufferSize(), "syncFramebufferSize stays false before compositor ack");

  view.setUint32(base + host.BROWSER_RESIZE_OFFSETS.ack_width, 1440, true);
  view.setUint32(base + host.BROWSER_RESIZE_OFFSETS.ack_height, 900, true);
  view.setUint32(base + host.BROWSER_RESIZE_OFFSETS.ack_seq, 1, true);
  expect(machine.syncFramebufferSize(), "syncFramebufferSize returns true when ack_seq advances");
  expect(machine.framebufferWidth === 1440 && machine.framebufferHeight === 900, "framebuffer dimensions updated from ack");
  expect(machine.framebufferPixels().byteLength === 1440 * 900 * 4, "framebufferPixels view reflects resized dimensions");
  expect(!machine.syncFramebufferSize(), "repeated syncFramebufferSize is false until next ack");

  // Dirty-rect + frame_seq O(1) unchanged check + worker-side BGRA -> RGBA conversion.
  const fb32 = new Uint32Array(memory.buffer, layout.framebuffer, 1440 * 900);
  fb32[10 * 1440 + 20] = 0x00112233; // BGRA: B=0x33, G=0x22, R=0x11 -> RGBA little-endian 0xff332211.
  view.setUint32(base + host.BROWSER_RESIZE_OFFSETS.dirty_x, 20, true);
  view.setUint32(base + host.BROWSER_RESIZE_OFFSETS.dirty_y, 10, true);
  view.setUint32(base + host.BROWSER_RESIZE_OFFSETS.dirty_w, 4, true);
  view.setUint32(base + host.BROWSER_RESIZE_OFFSETS.dirty_h, 2, true);
  view.setUint32(base + host.BROWSER_RESIZE_OFFSETS.frame_seq, 1, true);
  const firstPatch = machine.readFramePatch();
  expect(!firstPatch.unchanged && firstPatch.w === 1440 && firstPatch.h === 900, "first frame after boot/resize sends full frame");
  const unchangedPatch = machine.readFramePatch();
  expect(unchangedPatch.unchanged === true, "same frame_seq skips framebuffer scan in O(1)");

  view.setUint32(base + host.BROWSER_RESIZE_OFFSETS.frame_seq, 2, true);
  const dirtyPatch = machine.readFramePatch();
  expect(!dirtyPatch.unchanged && dirtyPatch.x === 20 && dirtyPatch.y === 10 && dirtyPatch.w === 4 && dirtyPatch.h === 2, "single-step frame_seq sends tight dirty rect");
  const dirty32 = new Uint32Array(dirtyPatch.rgba);
  expect(dirty32[0] === 0xff332211, "worker-side BGRA -> RGBA swap matches expected pixel");

  view.setUint32(base + host.BROWSER_RESIZE_OFFSETS.frame_seq, 5, true);
  const multiPatch = machine.readFramePatch();
  expect(!multiPatch.unchanged && multiPatch.x === 0 && multiPatch.y === 0 && multiPatch.w === 1440 && multiPatch.h === 900, "skipped frames fall back cleanly to full frame");

  // PS/2 mouse queue never truncates a 3-byte packet when full.
  const ps2 = new host.Ps2Controller();
  for (let i = 0; i < 120; i += 1) ps2.pointer(5, 5, 0);
  expect(ps2.queue.length % 3 === 0 && ps2.queue.length <= 256, "PS/2 mouse queue stays 3-byte aligned under flood");
}

if (failures.length) {
  for (const failure of failures) console.log("failed: " + failure);
  process.exit(1);
}
console.log("passed: stage tracker, dom_terminal accumulator, BLAKE3 vectors, >16 MiB Bao frame streaming, and live viewport resize");
