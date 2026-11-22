// The page of a browser machine: the thread of the document. It starts the
// worker of the processor, draws each frame of the framebuffer that the
// worker sends on the canvas, shows the serial port, and sends the keys
// and the pointer of the canvas to the worker
// (src/md/features/browser_machine.md, "The display and the scale").

const screen = document.getElementById("screen");
const status = document.getElementById("machine-status");
const serial = document.getElementById("serial-output");
const startButton = document.getElementById("start");
const context = screen.getContext("2d", { alpha: false });
const image = context.createImageData(screen.width, screen.height);

let worker = null;
let frameAsked = false;

// The framebuffer is blue first; ImageData is red first, with alpha.
function present(buffer) {
  const source = new Uint8Array(buffer);
  const target = image.data;
  for (let index = 0; index < target.length; index += 4) {
    target[index] = source[index + 2];
    target[index + 1] = source[index + 1];
    target[index + 2] = source[index];
    target[index + 3] = 255;
  }
  context.putImageData(image, 0, 0);
}

// One frame is asked at a time, at each animation frame: a slow worker
// gets no queue of requests.
function animationFrame() {
  if (worker && !frameAsked) {
    frameAsked = true;
    worker.postMessage({ kind: "frame" });
  }
  requestAnimationFrame(animationFrame);
}

function onWorkerMessage(event) {
  const message = event.data;
  switch (message.kind) {
    case "serial":
      serial.textContent += message.lines.join("\n") + "\n";
      serial.scrollTop = serial.scrollHeight;
      return;
    case "frame":
      frameAsked = false;
      present(message.pixels);
      return;
    case "state":
      status.textContent = message.state + (message.stopCode !== null && message.stopCode !== undefined ? " (code " + message.stopCode + ")" : "") + (message.trap ? ": " + message.trap : "");
      return;
  }
}

startButton.addEventListener("click", () => {
  if (worker) return;
  startButton.disabled = true;
  worker = new Worker("browser_machine_worker.js", { type: "module" });
  worker.onmessage = onWorkerMessage;
  worker.postMessage({
    kind: "start",
    kernelUrl: "modulus_kernel.wasm",
    bootImageUrl: "boot.image",
    memoryMebibytes: 512,
    width: screen.width,
    height: screen.height,
  });
  screen.focus();
  requestAnimationFrame(animationFrame);
});

for (const kind of ["keydown", "keyup"]) {
  screen.addEventListener(kind, (event) => {
    if (!worker) return;
    event.preventDefault();
    worker.postMessage({ kind: "key", code: event.code, pressed: kind === "keydown" });
  });
}

screen.addEventListener("pointermove", (event) => {
  if (worker) worker.postMessage({ kind: "pointer", deltaX: event.movementX, deltaY: event.movementY, buttons: event.buttons });
});
for (const kind of ["pointerdown", "pointerup"]) {
  screen.addEventListener(kind, (event) => {
    if (worker) worker.postMessage({ kind: "pointer", deltaX: 0, deltaY: 0, buttons: event.buttons });
  });
}

status.textContent = self.crossOriginIsolated ? "ready: shared memory" : "ready: one processor, no shared memory";
