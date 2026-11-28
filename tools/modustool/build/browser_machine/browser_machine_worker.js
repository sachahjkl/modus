// The worker of the processor of a browser machine
// (src/md/features/browser_machine.md, "The constraints": the thread of the
// document never runs a processor). It runs the kernel with the host of
// browser_machine_host.js, sends the stages of the start, the lines of the
// serial ports and the pixels of the framebuffer to the page, and gives
// the keys and the
// pointer of the page to the PS/2 controller, and the text of the console
// page to COM2.
import { BOOT_STAGE_SENTENCES, BootStage, BootStageTracker, BrowserMachine, LoopResult, MachineState, ProcessorIdle, trustDescriptionHashParse } from "./browser_machine_host.js";

// The time of one slice of the loop before the worker reads its messages.
const SLICE_NANOSECONDS = 8000000;

const clockNanoseconds = () => BigInt(Math.round((performance.timeOrigin + performance.now()) * 1e6));

// Yield out of the kernel on idle instead of blocking the worker thread in
// Atomics.wait or spinning in WASM: input and frame messages wake the loop
// immediately with near-zero CPU when the guest is idle.
const idleSignal = new ProcessorIdle(0n);
const idleWait = (boundNanoseconds) => {
  idleSignal.boundNanoseconds = boundNanoseconds;
  throw idleSignal;
};

let machine = null;
let pendingLines = [];
let pendingConsoleLines = [];
let lastPostedState = null;
let lastPostedStopCode = null;
let lastPostedTrap = null;
let loopQueued = false;
let idleTimer = 0;

// A slice ends with a yield to the event loop of the worker, through a
// message: a timer of 0 ms is clamped to 4 ms after a few calls.
const yieldChannel = new MessageChannel();
yieldChannel.port1.onmessage = () => {
  loopQueued = false;
  loop();
};

function wakeLoop() {
  if (!machine || machine.state !== MachineState.Running) return;
  if (idleTimer) {
    clearTimeout(idleTimer);
    idleTimer = 0;
  }
  if (!loopQueued) {
    loopQueued = true;
    yieldChannel.port2.postMessage(null);
  }
}

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
  const trap = machine.trap ? String(machine.trap.stack || machine.trap) : null;
  if (machine.state !== lastPostedState || machine.stopCode !== lastPostedStopCode || trap !== lastPostedTrap) {
    lastPostedState = machine.state;
    lastPostedStopCode = machine.stopCode;
    lastPostedTrap = trap;
    self.postMessage({
      kind: "state",
      state: machine.state,
      stopCode: machine.stopCode,
      trap,
    });
  }
}

function loop() {
  if (!machine || machine.state !== MachineState.Running) {
    if (machine) postState();
    return;
  }
  const result = machine.runSlice(SLICE_NANOSECONDS);
  postState();
  if (machine.state !== MachineState.Running) return;
  if (result === LoopResult.Idle) {
    const delayMs = Math.max(1, Math.min(8, Math.ceil(Number(machine.lastIdleBound) / 1e6) || 4));
    if (!idleTimer && !loopQueued) {
      idleTimer = setTimeout(() => {
        idleTimer = 0;
        loop();
      }, delayMs);
    }
  } else if (!loopQueued) {
    loopQueued = true;
    yieldChannel.port2.postMessage(null);
  }
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

// The stage of the start, for the page: a message at each new stage, with
// its sentence, and the bytes of the download as they come. The document
// imports nothing of the host: the worker gives the words.
const postStage = (stage, loaded = 0, total = 0) => self.postMessage({ kind: "stage", stage, sentence: BOOT_STAGE_SENTENCES[stage], loaded, total });

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

async function start({ kernelUrl, bootImageUrl, memoryMebibytes, width = 0, height = 0, keyboardLayoutHint = 0, cacheBaseUrl = "" }) {
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
    keyboardLayoutHint,
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
      if (machine) {
        machine.keyboard.key(message.code, message.pressed);
        wakeLoop();
      }
      return;
    case "pointer":
      if (machine) {
        machine.keyboard.pointer(message.deltaX, message.deltaY, message.buttons);
        wakeLoop();
      }
      return;
    case "wheel":
      if (machine) {
        machine.keyboard.wheel(message.notches);
        wakeLoop();
      }
      return;
    case "resize":
      if (machine) {
        machine.requestResize(message.width, message.height);
        wakeLoop();
      }
      return;
    case "keyboard_layout":
      if (machine) {
        machine.setKeyboardLayoutHint(message.hint);
        wakeLoop();
      }
      return;
    case "console_type":
      if (machine && typeof message.text === "string") {
        machine.consolePort.type(message.text);
        wakeLoop();
      }
      return;
    case "frame": {
      if (!machine) return;
      const patch = machine.readFramePatch();
      if (!patch) return;
      if (patch.unchanged) {
        self.postMessage({ kind: "frame", unchanged: true });
        return;
      }
      self.postMessage(
        {
          kind: "frame",
          rgba: patch.rgba,
          x: patch.x,
          y: patch.y,
          w: patch.w,
          h: patch.h,
          width: patch.width,
          height: patch.height,
          desktopWidth: patch.desktopWidth,
          desktopHeight: patch.desktopHeight,
        },
        [patch.rgba],
      );
      return;
    }
  }
};
