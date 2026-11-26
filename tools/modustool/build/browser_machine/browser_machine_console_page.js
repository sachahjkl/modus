// The page draws the lines that dom_terminal writes on COM2, one JSON
// object for each line (src/md/features/console_renderers.md, "Variant C:
// dom_terminal"). Each place in a text is a place in Array.from(text).
// The machine runs in the worker of the browser machine, never on the
// thread of this document (src/md/features/browser_machine.md, "The page
// and its host"): the lines come in one message for each slice of the
// worker, and the text that the reader types goes back as one message.
const OUTPUT_LINE_LIMIT = 4000;
const LINE_SPAN_LIMIT = 256;
const LIST_ROW_LIMIT = 8;
const HEX_COLOR = /^#[0-9a-f]{6}$/;
const TONES = new Set(["default", "dim", "strong", "good", "warning", "bad", "accent", "number"]);
const CODE_KINDS = new Set(["function", "module", "type", "parameter", "variable", "number", "text", "text_unfinished", "operator", "arrow", "words", "unknown"]);
const ICONS = new Set(["command", "export", "record", "service", "module", "process", "variable", "history_line"]);
const STARTERS = ["help()", "processes()", "s = isolate(\"sample\")", "s.readings(4)"];
const THEME_KEY = "modus-console-theme";
const element = (id) => document.getElementById(id);
const output = element("output");
const promptBar = element("prompt-bar");
const hintBar = element("hint-bar");
const popup = element("completion-popup");
const chips = element("chips");

function clampIndex(value, limit) {
  return typeof value === "number" && Number.isFinite(value) ? Math.max(0, Math.min(Math.trunc(value), limit)) : 0;
}
function validColor(value) {
  return typeof value === "string" && HEX_COLOR.test(value) ? value : "";
}
function span(text, className) {
  const node = document.createElement("span");
  node.textContent = text;
  if (className) node.className = className;
  return node;
}
function sanitizeRuns(runs, limit) {
  if (!Array.isArray(runs)) return [];
  const clean = [];
  for (const entry of runs.slice(0, 64)) {
    if (!Array.isArray(entry) || entry.length < 3 || !CODE_KINDS.has(entry[2])) continue;
    const start = clampIndex(entry[0], limit), end = clampIndex(entry[1], limit);
    if (start < end) clean.push([start, end, entry[2]]);
  }
  return clean;
}
function kindAt(runs, place) {
  for (const [start, end, kind] of runs) if (place >= start && place < end) return "c-" + kind;
  return "";
}
// appendParts appends characters from..to of chars, one span for each run
// of characters with the same class.
function appendParts(parent, chars, from, to, classOf) {
  if (from >= to) return;
  let start = from;
  for (let place = from + 1; place <= to; place++) {
    if (place === to || classOf(place) !== classOf(start)) {
      parent.append(span(chars.slice(start, place).join(""), classOf(start)));
      start = place;
    }
  }
}

function themeSet(theme) {
  document.documentElement.dataset.theme = theme;
  element("theme").textContent = theme === "dark" ? "Light" : "Dark";
  try { localStorage.setItem(THEME_KEY, theme); } catch {}
}
let savedTheme = "dark";
try { savedTheme = localStorage.getItem(THEME_KEY) === "light" ? "light" : "dark"; } catch {}
themeSet(savedTheme);
element("theme").addEventListener("click", () => themeSet(document.documentElement.dataset.theme === "dark" ? "light" : "dark"));

let openLine = null;
function clearOutput() { output.replaceChildren(); openLine = null; }
element("clear").addEventListener("click", clearOutput);

let listChosen = -1;
const records = {
  out(record) {
    if (typeof record.s !== "string") return;
    if (!openLine || openLine.childElementCount >= LINE_SPAN_LIMIT) {
      openLine = document.createElement("div");
      openLine.className = "line";
      output.append(openLine);
      while (output.childElementCount > OUTPUT_LINE_LIMIT) output.firstElementChild.remove();
    }
    const classes = [];
    if (TONES.has(record.tone)) classes.push("t-" + record.tone);
    if (CODE_KINDS.has(record.code)) classes.push("c-" + record.code);
    const node = span(record.s, classes.join(" "));
    const color = validColor(record.fg);
    if (color) node.style.color = color;
    if (record.rev === true) { node.style.backgroundColor = color || "var(--text)"; node.style.color = "var(--recess)"; }
    openLine.append(node);
    if (record.nl === true) openLine = null;
  },
  clr: clearOutput,
  edit(record) {
    if (typeof record.text !== "string") return;
    const chars = Array.from(record.text), runs = sanitizeRuns(record.runs, chars.length);
    const classOf = (place) => kindAt(runs, place);
    promptBar.replaceChildren();
    if (typeof record.cur !== "number" || !Number.isFinite(record.cur)) appendParts(promptBar, chars, 0, chars.length, classOf);
    else {
      const cursor = clampIndex(record.cur, chars.length);
      appendParts(promptBar, chars, 0, cursor, classOf);
      promptBar.append(span("", "caret"));
      appendParts(promptBar, chars, cursor, chars.length, classOf);
    }
    chips.hidden = !/^>\s*$/.test(record.text);
  },
  hint(record) {
    if (typeof record.text !== "string") return;
    const chars = Array.from(record.text);
    const start = clampIndex(record.ms, chars.length);
    const end = clampIndex(start + clampIndex(record.ml, chars.length), chars.length);
    hintBar.replaceChildren();
    appendParts(hintBar, chars, 0, chars.length, (place) => (place >= start && place < end ? "mark" : ""));
  },
  status(record) {
    const total = typeof record.tot === "number" && Number.isFinite(record.tot) ? Math.max(0, Math.trunc(record.tot)) : 0;
    element("status-bar").hidden = !(total > 0);
    if (!(total > 0)) return;
    const value = typeof record.v === "number" && Number.isFinite(record.v) ? Math.max(0, Math.trunc(record.v)) : 0;
    element("status-text").textContent = typeof record.text === "string" ? record.text : "";
    element("status-fill").style.width = Math.min(100, (100 * value) / total) + "%";
    element("status-count").textContent = value + " / " + total;
  },
  list(record) {
    popup.replaceChildren();
    const rawItems = Array.isArray(record.items) ? record.items.slice(0, LIST_ROW_LIMIT) : [];
    const items = rawItems.filter((item) => item && typeof item === "object" && typeof item.name === "string" && typeof item.detail === "string");
    popup.hidden = items.length === 0;
    const chosen = typeof record.chosen === "number" && Number.isFinite(record.chosen) ? Math.trunc(record.chosen) : -1;
    listChosen = chosen >= 0 && chosen < items.length ? chosen : -1;
    if (popup.hidden) return;
    items.forEach((item, index) => {
      const row = document.createElement("div");
      row.className = "item" + (index === listChosen ? " chosen" : "");
      row.setAttribute("role", "option");
      if (ICONS.has(item.icon)) row.append(span(item.icon.replace("_", " "), "icon"));
      const chars = Array.from(item.name + item.detail), nameLength = Array.from(item.name).length;
      const runs = sanitizeRuns(item.runs, chars.length);
      const matched = new Set(Array.isArray(item.match) ? item.match.map((p) => clampIndex(p, nameLength)) : []);
      const name = span("", "name"), detail = span("", "detail");
      appendParts(name, chars, 0, nameLength, (place) => (matched.has(place) ? "matched" : kindAt(runs, place)));
      appendParts(detail, chars, nameLength, chars.length, (place) => kindAt(runs, place));
      row.append(name, detail);
      // The console moves its choice by the arrows and takes it by Tab: a
      // click sends the keys that choose its row.
      row.addEventListener("mousedown", (event) => {
        event.preventDefault();
        const step = index - listChosen;
        send((step > 0 ? "\x1b[B" : "\x1b[A").repeat(Math.abs(step)) + "\t");
        promptBar.focus();
      });
      popup.append(row);
    });
    const total = typeof record.total === "number" && Number.isFinite(record.total) ? Math.max(0, Math.trunc(record.total)) : items.length;
    const first = typeof record.first === "number" && Number.isFinite(record.first) ? Math.max(0, Math.trunc(record.first)) : 0;
    if (total > items.length) {
      const count = document.createElement("div");
      count.id = "list-count";
      count.textContent = first + 1 + "–" + (first + items.length) + " / " + total;
      popup.append(count);
    }
    // The list starts at the column of the name, inside the prompt area.
    const startColumn = clampIndex(record.start, 256);
    const probe = span("0".repeat(10));
    promptBar.append(probe);
    const columnWidth = probe.getBoundingClientRect().width / 10;
    probe.remove();
    const promptRect = promptBar.getBoundingClientRect();
    const left = 16 + startColumn * columnWidth - promptBar.scrollLeft;
    popup.style.left = Math.max(8, Math.min(left, promptRect.width - popup.offsetWidth - 8)) + "px";
  },
};

for (const command of STARTERS) {
  const chip = document.createElement("button");
  chip.type = "button";
  chip.className = "chip-button";
  chip.textContent = command;
  chip.addEventListener("click", () => { send(command + "\r"); promptBar.focus(); });
  chips.append(chip);
}

// The states of the machine that the worker names (MachineState of the
// host of the browser machine); any other word shows as stopped.
const STATES = new Set(["created", "running", "stopped", "trapped"]);
function stateSet(text) {
  element("state-text").textContent = text;
  const dot = element("dot");
  dot.className = "status-dot" + (text === "running" ? " running" : text === "starting" || text === "loading" ? "" : " stopped");
}

// consoleLine draws one line of COM2. The worker passes the lines of the
// system as they are, so each check of a line is here.
function consoleLine(line) {
  if (typeof line !== "string") return;
  let record;
  try { record = JSON.parse(line); } catch { return; }
  if (!record || typeof record !== "object" || typeof record.t !== "string") return;
  if (!Object.hasOwn(records, record.t)) return;
  try { records[record.t](record); } catch {}
}

const worker = new Worker("./browser_machine_worker.js", { type: "module" });
let running = false;
// The stage of the start, which the header shows until the prompt
// (src/md/features/browser_machine.md, "The boot stages of the page"); the
// worker names each one with its sentence.
let stage = "download";
let stageSentence = "";
let stageStarted = performance.now();
let stageDetail = "";
function stageShow() {
  if (stage === "ready" || !stageSentence) return;
  element("state-text").textContent = stageSentence + stageDetail + " (" + ((performance.now() - stageStarted) / 1000).toFixed(0) + " s)";
}
const stageTimer = setInterval(stageShow, 500);
worker.onmessage = (event) => {
  const message = event.data;
  if (!message || typeof message !== "object") return;
  switch (message.kind) {
    case "stage": {
      if (typeof message.stage !== "string") return;
      if (message.stage !== stage) { stage = message.stage; stageStarted = performance.now(); }
      if (typeof message.sentence === "string") stageSentence = message.sentence;
      const loaded = Number(message.loaded) || 0, total = Number(message.total) || 0;
      stageDetail = stage === "download" && loaded ? ": " + (loaded / 1048576).toFixed(1) + (total ? " of " + (total / 1048576).toFixed(1) : "") + " MiB" : "";
      if (stage === "ready") { clearInterval(stageTimer); if (running) stateSet("running"); }
      else stageShow();
      return;
    }
    case "console": {
      if (!Array.isArray(message.lines)) return;
      // Output follows the end only when the reader is at the end.
      const atEnd = output.scrollHeight - output.scrollTop - output.clientHeight < 40;
      for (const line of message.lines) consoleLine(line);
      if (atEnd) output.scrollTop = output.scrollHeight;
      return;
    }
    // COM1 is the log of the kernel: the console of the developer shows it.
    case "serial":
      if (Array.isArray(message.lines)) for (const line of message.lines) console.log(String(line));
      return;
    case "state": {
      const state = STATES.has(message.state) ? message.state : "stopped";
      if (state === "running" && !running) { running = true; promptBar.focus(); }
      if (state !== "running" && typeof message.trap === "string" && message.trap) {
        console.error(message.trap);
        records.out({ s: message.trap, tone: "bad", nl: true });
        output.scrollTop = output.scrollHeight;
      }
      // While the machine starts, the header keeps the stage.
      if (state === "running" && stage !== "ready") return;
      if (state !== "running") clearInterval(stageTimer);
      stateSet(state);
      return;
    }
  }
};
worker.onerror = (event) => {
  const detail = event && event.message ? String(event.message) : "the worker stopped";
  console.error(detail);
  records.out({ s: detail, tone: "bad", nl: true });
  output.scrollTop = output.scrollHeight;
  stateSet("stopped");
};
// send gives text to COM2 as a terminal sends it: UTF-8 and VT100 keys,
// which dom_terminal decodes.
function send(text) { worker.postMessage({ kind: "console_type", text }); }

const NAMED_KEYS = { ArrowUp: "\x1b[A", ArrowDown: "\x1b[B", ArrowRight: "\x1b[C", ArrowLeft: "\x1b[D", Home: "\x1b[H", End: "\x1b[F", Delete: "\x1b[3~", PageUp: "\x1b[5~", PageDown: "\x1b[6~", Enter: "\r", Backspace: "\x7f", Escape: "\x1b" };
document.addEventListener("keydown", (event) => {
  if ((event.target instanceof HTMLButtonElement || event.target instanceof HTMLAnchorElement) && (event.key === "Enter" || event.key === " ")) return;
  // Cmd and Alt stay with the browser; Ctrl+C with a selection copies it,
  // and Ctrl+V comes as a paste.
  if (event.metaKey || event.altKey) return;
  const letter = event.key.length === 1 ? event.key.toLowerCase() : "";
  if (event.ctrlKey && ((letter === "c" && String(getSelection())) || letter === "v")) return;
  let sequence = event.key === "Tab" ? (event.shiftKey ? "\x1b[Z" : "\t") : NAMED_KEYS[event.key];
  if (!sequence && event.ctrlKey && letter >= "a" && letter <= "z") sequence = String.fromCharCode(letter.charCodeAt(0) - 96);
  else if (!sequence && !event.ctrlKey && event.key.length >= 1 && Array.from(event.key).length === 1) sequence = event.key;
  if (!sequence) return;
  event.preventDefault();
  send(sequence);
});
document.addEventListener("paste", (event) => {
  const text = event.clipboardData?.getData("text/plain");
  if (!text) return;
  event.preventDefault();
  send(text.replace(/\r\n?|\n/g, "\r"));
});
promptBar.addEventListener("mousedown", () => promptBar.focus());

stateSet("starting");
// ?cache=<address> names an object cache; the host refuses any address
// that is not one it may fetch.
worker.postMessage({
  kind: "start", kernelUrl: "./modulus_kernel.wasm", bootImageUrl: "./console.image", memoryMebibytes: 512, width: 0, height: 0,
  cacheBaseUrl: new URLSearchParams(location.search).get("cache") ?? "",
});
