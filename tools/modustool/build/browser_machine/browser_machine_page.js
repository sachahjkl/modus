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
const VIEWPORT_MIN_WIDTH = 640;
const VIEWPORT_MIN_HEIGHT = 400;
const VIEWPORT_MAX_WIDTH = 1920;
const VIEWPORT_MAX_HEIGHT = 1200;
const RESIZE_DEBOUNCE_MS = 120;

const stageFrame = document.getElementById("stage-frame");
const screen = document.getElementById("screen");
const screenMeta = document.getElementById("screen-meta");
const status = document.getElementById("machine-status");
const statusDot = document.getElementById("dot");
const serial = document.getElementById("serial-output");
const startButton = document.getElementById("start");
const fullscreenButton = document.getElementById("fullscreen");
const themeButton = document.getElementById("theme");
const context = screen.getContext("2d", { alpha: false });
let guestPointerX = Math.floor(screen.width / 2);
let guestPointerY = Math.floor(screen.height / 2);
let guestPointerButtons = 0;
let pointerSynced = false;
let pendingPointerEvent = null;
let lastRequestedWidth = screen.width;
let lastRequestedHeight = screen.height;
let lastSeenStageWidth = screen.width;
let lastSeenStageHeight = screen.height;
let resizeTimer = 0;

function updateScreenMeta(width, height) {
  if (screenMeta) screenMeta.textContent = "boot.image · " + width + " × " + height;
}

function applyCanvasSize(width, height) {
  if (screen.width === width && screen.height === height) return;
  screen.width = width;
  screen.height = height;
  updateScreenMeta(width, height);
  pointerSynced = false;
}

function measureStageSize() {
  if (!stageFrame) return { width: screen.width, height: screen.height };
  const rect = stageFrame.getBoundingClientRect();
  const rawW = Math.floor(rect.width) & ~1;
  const rawH = Math.floor(rect.height) & ~1;
  if (rawW <= 0 || rawH <= 0) return { width: screen.width, height: screen.height };
  return {
    width: Math.max(VIEWPORT_MIN_WIDTH, Math.min(VIEWPORT_MAX_WIDTH, rawW)),
    height: Math.max(VIEWPORT_MIN_HEIGHT, Math.min(VIEWPORT_MAX_HEIGHT, rawH)),
  };
}

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

// The worker performs BGRA -> RGBA conversion over only the damaged rectangle
// so the document thread uploads the patch directly with zero per-pixel loops.
function presentPatch(rgbaBuffer, x, y, w, h) {
  if (!rgbaBuffer || w <= 0 || h <= 0) return;
  const bytes = new Uint8ClampedArray(rgbaBuffer);
  if (bytes.byteLength !== w * h * 4) return;
  context.putImageData(new ImageData(bytes, w, h), x, y);
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
  else if (worker) {
    if (pendingPointerEvent) {
      const event = pendingPointerEvent;
      pendingPointerEvent = null;
      sendPointerAt(event, false);
    }
    const stageSize = measureStageSize();
    if (stageSize.width !== lastSeenStageWidth || stageSize.height !== lastSeenStageHeight) {
      lastSeenStageWidth = stageSize.width;
      lastSeenStageHeight = stageSize.height;
      requestStageResize(false);
    }
    if (!frameAsked) {
      frameAsked = true;
      worker.postMessage({ kind: "frame" });
    }
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
      if (stage === STAGE_READY) {
        screen.classList.add("ready");
        if (machineState === "running") {
          dotSet("running");
          status.textContent = "running";
        }
        requestStageResize(true);
      }
      return;
    case "frame":
      frameAsked = false;
      if (!message.unchanged && message.rgba) {
        if (message.width && message.height && (message.width !== screen.width || message.height !== screen.height)) {
          applyCanvasSize(message.width, message.height);
        }
        presentPatch(message.rgba, message.x, message.y, message.w, message.h);
      }
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

function sendResize(width, height) {
  if (!worker || stage !== STAGE_READY) return;
  if (width === lastRequestedWidth && height === lastRequestedHeight) return;
  lastRequestedWidth = width;
  lastRequestedHeight = height;
  worker.postMessage({ kind: "resize", width, height });
}

function requestStageResize(immediate = false) {
  const size = measureStageSize();
  lastSeenStageWidth = size.width;
  lastSeenStageHeight = size.height;
  if (!worker) {
    applyCanvasSize(size.width, size.height);
    lastRequestedWidth = screen.width;
    lastRequestedHeight = screen.height;
    drawIdle();
    return;
  }
  if (stage !== STAGE_READY) return;
  if (resizeTimer) {
    clearTimeout(resizeTimer);
    resizeTimer = 0;
  }
  if (immediate) {
    sendResize(size.width, size.height);
    return;
  }
  resizeTimer = setTimeout(() => {
    resizeTimer = 0;
    const settled = measureStageSize();
    sendResize(settled.width, settled.height);
  }, RESIZE_DEBOUNCE_MS);
}

startButton.addEventListener("click", () => {
  if (worker) return;
  const bootSize = measureStageSize();
  applyCanvasSize(bootSize.width, bootSize.height);
  lastRequestedWidth = screen.width;
  lastRequestedHeight = screen.height;
  startButton.disabled = true;
  dotSet("");
  worker = new Worker("../browser_machine_worker.js", { type: "module" });
  worker.onmessage = onWorkerMessage;
  worker.onerror = (event) => {
    dotSet("stopped");
    status.textContent = "stopped: " + event.message;
  };
  worker.postMessage({
    kind: "start",
    kernelUrl: "./modulus_kernel.wasm",
    bootImageUrl: "./boot.image",
    memoryMebibytes: 512,
    width: screen.width,
    height: screen.height,
  });
  screen.focus();
  requestAnimationFrame(animationFrame);
});

if (fullscreenButton && stageFrame) {
  const updateFullscreenLabel = () => {
    fullscreenButton.textContent = document.fullscreenElement === stageFrame ? "Exit fullscreen" : "Fullscreen";
  };
  fullscreenButton.addEventListener("click", () => {
    if (document.fullscreenElement === stageFrame) {
      document.exitFullscreen().catch(() => {});
    } else if (stageFrame.requestFullscreen) {
      stageFrame.requestFullscreen().then(() => screen.focus()).catch(() => {});
    }
  });
  document.addEventListener("fullscreenchange", () => {
    updateFullscreenLabel();
    requestStageResize(true);
    if (document.fullscreenElement === stageFrame) screen.focus();
  });
}

let stageResizeObserver = null;
if (stageFrame && typeof ResizeObserver === "function") {
  stageResizeObserver = new ResizeObserver(() => requestStageResize(false));
  stageResizeObserver.observe(stageFrame);
}
window.addEventListener("resize", () => requestStageResize(false));
const serialPanel = document.querySelector(".serial-panel");
if (serialPanel) {
  serialPanel.addEventListener("toggle", () => requestStageResize(true));
}

for (const kind of ["keydown", "keyup"]) {
  screen.addEventListener(kind, (event) => {
    if (!worker) return;
    event.preventDefault();
    worker.postMessage({ kind: "key", code: event.code, pressed: kind === "keydown" });
  });
}

// Map absolute canvas coordinates onto relative PS/2 packets so the guest
// desktop cursor stays aligned 1:1 with the browser pointer at every scale.
function canvasPointer(event) {
  const rect = screen.getBoundingClientRect();
  if (rect.width <= 0 || rect.height <= 0) return null;
  const x = Math.max(0, Math.min(screen.width - 1, Math.round(((event.clientX - rect.left) * screen.width) / rect.width)));
  const y = Math.max(0, Math.min(screen.height - 1, Math.round(((event.clientY - rect.top) * screen.height) / rect.height)));
  return { x, y };
}

function sendPointerAt(event, forceButtons) {
  if (!worker || stage !== STAGE_READY) return;
  const point = canvasPointer(event);
  if (!point) return;
  const buttons = event.buttons;
  if (!pointerSynced) {
    // Drive the compositor pointer to the top-left clamp (0, 0) once on entry,
    // then move directly to the exact canvas pixel.
    worker.postMessage({ kind: "pointer", deltaX: -screen.width, deltaY: -screen.height, buttons: 0 });
    guestPointerX = 0;
    guestPointerY = 0;
    guestPointerButtons = 0;
    pointerSynced = true;
  }
  const deltaX = point.x - guestPointerX;
  const deltaY = point.y - guestPointerY;
  if (deltaX !== 0 || deltaY !== 0 || buttons !== guestPointerButtons || forceButtons) {
    worker.postMessage({ kind: "pointer", deltaX, deltaY, buttons });
    guestPointerX = point.x;
    guestPointerY = point.y;
    guestPointerButtons = buttons;
  }
}

screen.addEventListener("pointerenter", (event) => {
  pendingPointerEvent = null;
  pointerSynced = false;
  sendPointerAt(event, false);
});
screen.addEventListener("pointerleave", () => {
  pendingPointerEvent = null;
  pointerSynced = false;
});
screen.addEventListener("pointermove", (event) => {
  // Coalesce high-frequency moves to one packet per animation frame so the PS/2
  // controller and software CPU never lag behind 120-240 Hz mouse reports.
  pendingPointerEvent = event;
});
for (const kind of ["pointerdown", "pointerup"]) {
  screen.addEventListener(kind, (event) => {
    pendingPointerEvent = null;
    if (kind === "pointerdown") screen.focus();
    sendPointerAt(event, true);
  });
}

const initialSize = measureStageSize();
applyCanvasSize(initialSize.width, initialSize.height);
lastRequestedWidth = screen.width;
lastRequestedHeight = screen.height;
lastSeenStageWidth = screen.width;
lastSeenStageHeight = screen.height;
updateScreenMeta(screen.width, screen.height);
drawIdle();
status.textContent = self.crossOriginIsolated ? "ready: shared memory" : "ready: one processor";
