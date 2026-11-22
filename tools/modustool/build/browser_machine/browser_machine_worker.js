// The worker of the processor of a browser machine
// (src/md/features/browser_machine.md, "The constraints": the thread of the
// document never runs a processor). It runs the kernel with the host of
// browser_machine_host.js, sends the lines of the serial port and the
// pixels of the framebuffer to the page, and gives the keys and the
// pointer of the page to the PS/2 controller.
import { BrowserMachine, LoopResult, MachineState } from "./browser_machine_host.js";

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

// A slice ends with a yield to the event loop of the worker, through a
// message: a timer of 0 ms is clamped to 4 ms after a few calls.
const yieldChannel = new MessageChannel();
yieldChannel.port1.onmessage = () => loop();

function postState() {
  if (pendingLines.length) {
    self.postMessage({ kind: "serial", lines: pendingLines });
    pendingLines = [];
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

async function start({ kernelUrl, bootImageUrl, memoryMebibytes, width, height }) {
  const kernelModule = await WebAssembly.compileStreaming(fetch(kernelUrl));
  const response = await fetch(bootImageUrl);
  const bootImage = response.ok ? new Uint8Array(await response.arrayBuffer()) : undefined;
  if (!response.ok) pendingLines.push("page: no boot image at " + bootImageUrl + ": the kernel starts with none");
  machine = new BrowserMachine({
    kernelModule,
    bootImage,
    memoryMebibytes,
    framebufferWidth: width,
    framebufferHeight: height,
    clockNanoseconds,
    idleWait,
    onSerialLine: (line) => pendingLines.push(line),
  });
  await machine.start();
  loop();
}

self.onmessage = (event) => {
  const message = event.data;
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
