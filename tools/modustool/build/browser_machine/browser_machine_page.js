// The page of a browser machine: the thread of the document. It starts the
// worker of the processor, shows the stages of the start until the first
// frame of the desktop, then draws each frame of the framebuffer that the
// worker sends on the canvas, shows the serial port, and sends the keys and
// the pointer of the canvas to the worker
// (src/md/features/browser_machine.md, "The display and the scale", and
// "The boot stages of the page").
// The stage that ends the start: the first frame of the compositor.
const STAGE_READY = "ready";
const THEME_KEY = "modus-console-theme";

const screen = document.getElementById("screen");
const status = document.getElementById("machine-status");
const statusDot = document.getElementById("dot");
const serial = document.getElementById("serial-output");
const startButton = document.getElementById("start");
const themeButton = document.getElementById("theme");
const context = screen.getContext("2d", { alpha: false });
const image = context.createImageData(screen.width, screen.height);

function themeSet(theme) {
  document.documentElement.dataset.theme = theme;
  if (themeButton) themeButton.textContent = theme === "dark" ? "Light" : "Dark";
  try { localStorage.setItem(THEME_KEY, theme); } catch {}
}
let savedTheme = "dark";
try { savedTheme = localStorage.getItem(THEME_KEY) === "light" ? "light" : "dark"; } catch {}
themeSet(savedTheme);
if (themeButton) {
  themeButton.addEventListener("click", () => themeSet(document.documentElement.dataset.theme === "dark" ? "light" : "dark"));
}

function dotSet(kind) {
  if (statusDot) statusDot.className = "status-dot" + (kind ? " " + kind : "");
}

function drawBackdrop() {
  context.fillStyle = "#0b1018";
  context.fillRect(0, 0, screen.width, screen.height);
  context.fillStyle = "#18212d";
  for (let y = 12; y < screen.height; y += 24) {
    for (let x = 12; x < screen.width; x += 24) {
      context.fillRect(x, y, 2, 2);
    }
  }
}

function drawIdle() {
  drawBackdrop();
  context.fillStyle = "#4a9cf0";
  context.fillRect(64, 68, 4, 24);
  context.fillStyle = "#dce4ec";
  context.font = "700 22px ui-monospace, Menlo, Consolas, monospace";
  context.textBaseline = "top";
  context.fillText("modus web desktop", 80, 68);
  context.fillStyle = "#7c8a99";
  context.font = "16px ui-monospace, Menlo, Consolas, monospace";
  context.fillText("Press Start to boot the WebAssembly machine in this tab.", 64, 112);
}

let worker = null;
let frameAsked = false;
// The stages that ended, with their time in seconds, and the stage that
// runs. The canvas shows them until the first frame of the compositor.
const stagesDone = [];
let stage = null;
let stageSentence = "";
let stageStarted = 0;
let downloaded = { loaded: 0, total: 0 };
let machineState = "";

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

// The panel of the stages: one line for each stage, at a fixed step, so no
// line meets another. The font is fixed: each line is shorter than the
// canvas at 18 px.
const STAGE_LINE_STEP = 32;
function stagesDraw() {
  drawBackdrop();
  context.font = "18px ui-monospace, Menlo, Consolas, monospace";
  context.textBaseline = "top";
  let y = 64;
  const line = (text, color) => {
    context.fillStyle = color;
    context.fillText(text, 64, y);
    y += STAGE_LINE_STEP;
  };
  line("modus: the machine starts", "#dce4ec");
  y += STAGE_LINE_STEP / 2;
  for (const done of stagesDone) line("done  " + done.sentence + " (" + done.seconds.toFixed(1) + " s)", "#7c8a99");
  if (stage) {
    let text = "now   " + stageSentence + " (" + ((performance.now() - stageStarted) / 1000).toFixed(0) + " s)";
    if (stage === "download" && downloaded.loaded) {
      text += ": " + (downloaded.loaded / 1048576).toFixed(1) + (downloaded.total ? " of " + (downloaded.total / 1048576).toFixed(1) : "") + " MiB";
    }
    line(text, "#4a9cf0");
  }
  if (machineState && machineState !== "running" && machineState !== "created") line("the machine is " + machineState, "#f06060");
}

// One frame is asked at a time, at each animation frame: a slow worker
// gets no queue of requests. Before the first frame of the compositor, the
// canvas shows the stages.
function animationFrame() {
  if (stage !== STAGE_READY) stagesDraw();
  else if (worker && !frameAsked) {
    frameAsked = true;
    worker.postMessage({ kind: "frame" });
  }
  requestAnimationFrame(animationFrame);
}

function stageTake(message) {
  if (message.stage === stage) {
    downloaded = { loaded: message.loaded, total: message.total };
    return;
  }
  const now = performance.now();
  if (stage) stagesDone.push({ sentence: stageSentence, seconds: (now - stageStarted) / 1000 });
  stage = message.stage;
  stageSentence = typeof message.sentence === "string" ? message.sentence : String(message.stage);
  stageStarted = now;
  status.textContent = stageSentence;
}

function onWorkerMessage(event) {
  const message = event.data;
  switch (message.kind) {
    case "serial":
      serial.textContent += message.lines.join("\n") + "\n";
      serial.scrollTop = serial.scrollHeight;
      return;
    case "stage":
      stageTake(message);
      return;
    case "frame":
      frameAsked = false;
      present(message.pixels);
      return;
    case "state":
      machineState = message.state;
      if (message.state === "running" && stage === STAGE_READY) dotSet("running");
      else if (message.state !== "running" && message.state !== "created") dotSet("stopped");
      if (stage === STAGE_READY || message.state !== "running") {
        status.textContent = message.state + (message.stopCode !== null && message.stopCode !== undefined ? " (code " + message.stopCode + ")" : "") + (message.trap ? ": " + message.trap : "");
      }
      return;
  }
}

startButton.addEventListener("click", () => {
  if (worker) return;
  startButton.disabled = true;
  dotSet("");
  worker = new Worker("browser_machine_worker.js", { type: "module" });
  worker.onmessage = onWorkerMessage;
  worker.onerror = (event) => {
    dotSet("stopped");
    status.textContent = "stopped: " + event.message;
  };
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

drawIdle();
status.textContent = self.crossOriginIsolated ? "ready: shared memory" : "ready: one processor";
