// The worker of the processor of a browser machine
// (src/md/features/browser_machine.md, "The constraints": the thread of the
// document never runs a processor). It runs the kernel with the host of
// browser_machine_host.js, sends the stages of the start, the lines of the
// serial ports and the pixels of the framebuffer to the page, and gives
// the keys and the
// pointer of the page to the PS/2 controller, and the text of the console
// page to COM2.
import { BootStage, BootStageTracker, BrowserMachine, LoopResult, MachineState, trustDescriptionHashParse } from "./browser_machine_host.js";

// The time of one slice of the loop before the worker reads its messages.
const SLICE_NANOSECONDS = 8000000;

const clockNanoseconds = () => BigInt(Math.round((performance.timeOrigin + performance.now()) * 1e6));

// With shared memory, the idle wait sleeps in Atomics.wait until the
// deadline of the timer. With none (a page with no cross-origin isolation),
// it returns at once: the kernel then waits for the deadline in its idle
// loop, and the messages of the page wait for the next run of a thread.
const idleWord = typeof SharedArrayBuffer === "function" && self.crossOriginIsolated ? new Int32Array(new SharedArrayBuffer(4)) : null;
const idleWait = (boundNanoseconds) => {
  if (idleWord) Atomics.wait(idleWord, 0, 0, Number(boundNanoseconds) / 1e6);
};

let machine = null;
let pendingLines = [];
let pendingConsoleLines = [];

// A slice ends with a yield to the event loop of the worker, through a
// message: a timer of 0 ms is clamped to 4 ms after a few calls.
const yieldChannel = new MessageChannel();
yieldChannel.port1.onmessage = () => loop();

// The lines of a slice go in one message for each port: a message for
// each line would cost the page more than the line.
function postState() {
  if (pendingLines.length) {
    self.postMessage({ kind: "serial", lines: pendingLines });
    pendingLines = [];
  }
  if (pendingConsoleLines.length) {
    self.postMessage({ kind: "console", lines: pendingConsoleLines });
    pendingConsoleLines = [];
  }
  self.postMessage({
    kind: "state",
    state: machine.state,
    stopCode: machine.stopCode,
    trap: machine.trap ? String(machine.trap.stack || machine.trap) : null,
  });
}

function loop() {
  if (machine.state !== MachineState.Running) {
    postState();
    return;
  }
  const result = machine.runSlice(SLICE_NANOSECONDS);
  postState();
  if (result === LoopResult.Idle) setTimeout(loop, 1);
  else yieldChannel.port2.postMessage(null);
}

// trustOf reads <image>.trust, the hash of the system description of a
// signed boot image of the page. No file: no trust, and a line says so. A
// file that is not one hash stops the start: a damaged trust is not an
// absent one.
async function trustOf(bootImageUrl) {
  const trustUrl = bootImageUrl + ".trust";
  const response = await fetch(trustUrl);
  if (!response.ok) {
    pendingLines.push("page: no trust at " + trustUrl + ": the machine starts with no trust of its description");
    return null;
  }
  const hash = trustDescriptionHashParse(await response.text());
  if (!hash) throw new Error("the trust at " + trustUrl + " is not the hash of one description");
  return hash;
}

// The stage of the start, for the page: a message at each new stage, and
// the bytes of the download as they come.
const postStage = (stage, loaded = 0, total = 0) => self.postMessage({ kind: "stage", stage, loaded, total });

// bytesOf reads the body of a response and posts the bytes that came, at
// most one message for each 64 KiB.
async function bytesOf(response) {
  const total = Number(response.headers.get("content-length")) || 0;
  const reader = response.body.getReader();
  const chunks = [];
  let loaded = 0, posted = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    loaded += value.byteLength;
    if (loaded - posted >= 65536) {
      posted = loaded;
      postStage(BootStage.Download, loaded, total);
    }
  }
  const bytes = new Uint8Array(loaded);
  let at = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, at);
    at += chunk.byteLength;
  }
  postStage(BootStage.Download, loaded, total);
  return bytes;
}

async function start({ kernelUrl, bootImageUrl, memoryMebibytes, width = 0, height = 0, cacheBaseUrl = "" }) {
  const tracker = new BootStageTracker({ desktop: width > 0 && height > 0, onStage: (stage) => postStage(stage) });
  postStage(BootStage.Download);
  const kernelModule = await WebAssembly.compileStreaming(fetch(kernelUrl));
  const response = await fetch(bootImageUrl);
  const bootImage = response.ok ? await bytesOf(response) : undefined;
  if (!response.ok) pendingLines.push("page: no boot image at " + bootImageUrl + ": the kernel starts with none");
  const trustDescriptionHash = bootImage ? await trustOf(bootImageUrl) : null;
  tracker.enter(BootStage.Kernel);
  machine = new BrowserMachine({
    kernelModule,
    bootImage,
    trustDescriptionHash,
    memoryMebibytes,
    framebufferWidth: width,
    framebufferHeight: height,
    cacheBaseUrl,
    clockNanoseconds,
    idleWait,
    onSerialLine: (line) => {
      pendingLines.push(line);
      tracker.serialLine(line);
    },
    onConsoleLine: (line) => {
      pendingConsoleLines.push(line);
      tracker.consoleLine(line);
    },
  });
  if (cacheBaseUrl && !machine.objectCache.configured) pendingLines.push("page: the object cache address is refused: the machine has no object cache");
  await machine.start();
  loop();
}

self.onmessage = (event) => {
  const message = event.data;
  if (!message || typeof message !== "object") return;
  switch (message.kind) {
    case "start":
      start(message).catch((error) => self.postMessage({ kind: "state", state: MachineState.Trapped, trap: String(error.stack || error) }));
      return;
    case "key":
      if (machine) machine.keyboard.key(message.code, message.pressed);
      return;
    case "pointer":
      if (machine) machine.keyboard.pointer(message.deltaX, message.deltaY, message.buttons);
      return;
    case "console_type":
      if (machine && typeof message.text === "string") machine.consolePort.type(message.text);
      return;
    case "frame": {
      // A copy, not a view: the memory of the machine is not transferable.
      const pixels = machine && machine.framebufferPixels();
      if (!pixels) return;
      const copy = pixels.slice();
      self.postMessage({ kind: "frame", pixels: copy.buffer }, [copy.buffer]);
      return;
    }
  }
};
