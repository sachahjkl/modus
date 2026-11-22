// The host of a browser machine: the device models and the processor loop
// that the page gives to the kernel of modus built for WebAssembly
// (src/md/features/browser_machine.md, "The devices of the page" and "The
// processor loop"). The same module runs in the worker of the page and in
// Node, where "modustool browser-machine boot" starts the kernel with it.
// It touches no document: the page draws the framebuffer and sends the
// events of the keys and of the pointer.

// The imports of the kernel, in the module modus_page, and its exports.
// "modustool browser-machine" checks the same lists in the file that it
// builds.
export const PAGE_IMPORT_MODULE = "modus_page";
export const PAGE_IMPORT_NAMES = [
  "page_clock_nanoseconds",
  "page_port_write_8",
  "page_port_read_8",
  "page_processor_loop_unwind",
  "page_processor_stop",
  "page_idle_wait",
  "page_interrupt_lines_take",
];
// __stack_pointer is the global of the shadow stack: the loop sets it back
// to the top of the stack after each throw (browser_machine.md, "The
// processor loop").
export const KERNEL_EXPORT_NAMES = ["memory", "entry", "modus_processor_loop_run", "__stack_pointer"];

// The byte offsets of the boot record (Boot_Info in
// src/library/modus/contract/boot_info/boot_info.odin). A host test of the
// tool compares each one with offset_of of the record.
export const BOOT_INFO_OFFSETS = {
  magic: 0,
  memory_ranges: 8,
  memory_range_count: 16,
  direct_map_size: 24,
  page_table: 32,
  kernel_address: 40,
  kernel_size: 48,
  kernel_file: 56,
  kernel_file_size: 64,
  boot_image: 72,
  boot_image_size: 80,
  framebuffer: 88,
  acpi_root: 112,
  cycles_start: 120,
  cycles_loaded: 128,
  firmware_vendor: 136,
  firmware_revision: 168,
  self_test: 176,
  trust: 184,
  debug_image: 400,
  debug_image_size: 408,
  start_request: 416,
  start_request_source: 424,
};
export const BOOT_INFO_SIZE = 432;
export const FRAMEBUFFER_OFFSETS = { address: 0, width: 8, height: 12, pixels_per_line: 16, format: 20 };
export const MEMORY_RANGE_OFFSETS = { start: 0, page_count: 8, kind: 16, reserved: 20 };
export const MEMORY_RANGE_SIZE = 24;
export const BOOT_INFO_MAGIC = 0x4F464E49544F4F42n; // The bytes "BOOTINFO".

// The words of Memory_Kind and of Pixel_Format.
export const MemoryKind = Object.freeze({ Reserved: 0, Free: 1, Boot: 2 });
export const PixelFormat = Object.freeze({ None: 0, Blue_Green_Red_X: 1, Red_Green_Blue_X: 2 });

// The words of Processor_Loop_Result (src/modulus/processor_loop_wasm64p32.odin).
export const LoopResult = Object.freeze({ Idle: 0, Kernel_Returned: 1, Budget_Refused: 2, Slice_Ended: 3 });

// The instructions of one call of the loop: STEP_BUDGET_LIMIT of the kernel
// is 1 000 000. A smaller slice gives the page its events sooner.
export const STEP_BUDGET = 100000n;

export const PAGE_SIZE = 4096;
const WEBASSEMBLY_PAGE_SIZE = 65536;

// The ports of the devices of the test machine that the page plays.
// COM1 (0x3f8) is the log of the kernel. COM2 (0x2f8) is the terminal of a
// console image: dom_terminal writes one JSON line for each change of the
// terminal there, and reads the keys of the page there.
export const Port = Object.freeze({
  SerialData: 0x3f8,
  SerialLineControl: 0x3fb,
  SerialLineStatus: 0x3fd,
  ConsoleData: 0x2f8,
  Ps2Data: 0x60,
  Ps2Command: 0x64,
  ClockIndex: 0x70,
  ClockData: 0x71,
  DebugExit: 0xf4,
});

// The device lines of the 8259 of the test machine that the page raises.
// The kernel delivers line n as the vector 32 + n. A host test of the tool
// reads the numbers.
export const InterruptLine = { Keyboard: 1, Mouse: 12 };

// The state of the machine, as the page shows it.
export const MachineState = Object.freeze({
  Created: "created",
  Running: "running",
  Stopped: "stopped",
  Trapped: "trapped",
});

const SERIAL_TRANSMIT_EMPTY = 0x60;
const SERIAL_DATA_READY = 0x01;
const SERIAL_DIVISOR_LATCH = 0x80;

// The registers of a 16550 UART, from its data port.
const SerialRegister = Object.freeze({ Data: 0, LineControl: 3, LineStatus: 5 });
// The ports of one UART.
export const SERIAL_PORT_COUNT = 8;

// A serial port at its data port: COM1 at Port.SerialData, COM2 at
// Port.ConsoleData. Each byte that the kernel writes goes to onBytes as it
// comes, and to a line; each line goes to onLine. A line holds the bytes
// as they came, escape sequences included.
export class SerialPort {
  constructor(onLine, base = Port.SerialData, onBytes = () => {}) {
    this.base = base;
    this.onLine = onLine;
    this.onBytes = onBytes;
    this.line = [];
    this.lines = [];
    this.input = [];
    this.lineControl = 0;
    this.decoder = new TextDecoder();
  }
  holds(port) {
    return port >= this.base && port < this.base + SERIAL_PORT_COUNT;
  }
  write(port, value) {
    const register = port - this.base;
    if (register === SerialRegister.LineControl) {
      this.lineControl = value;
      return;
    }
    // With the divisor latch on, the data port is the low byte of the divisor.
    if (register !== SerialRegister.Data || this.lineControl & SERIAL_DIVISOR_LATCH) return;
    this.onBytes(value);
    if (value === 0x0a) {
      const text = this.decoder.decode(new Uint8Array(this.line));
      this.line = [];
      this.lines.push(text);
      this.onLine(text);
    } else if (value !== 0x0d) {
      this.line.push(value);
    }
  }
  read(port) {
    const register = port - this.base;
    if (register === SerialRegister.LineStatus) return SERIAL_TRANSMIT_EMPTY | (this.input.length ? SERIAL_DATA_READY : 0);
    if (register === SerialRegister.Data && !(this.lineControl & SERIAL_DIVISOR_LATCH)) return this.input.shift() ?? 0;
    if (register === SerialRegister.LineControl) return this.lineControl;
    return 0;
  }
  // type queues the bytes of a text as the input of the port: UTF-8, as a
  // terminal sends it.
  type(text) {
    for (const byte of new TextEncoder().encode(text)) this.input.push(byte);
  }
}

const PS2_STATUS_OUTPUT_FULL = 0x01;
const PS2_STATUS_MOUSE = 0x20;
const PS2_ACKNOWLEDGE = 0xfa;
const PS2_SELF_TEST_PASSED = 0xaa;
// The configuration byte after a reset: the interrupts of both ports on,
// the translation to scan code set 1 on.
const PS2_DEFAULT_CONFIGURATION = 0x47;
// A queue of the page that grows past this bound drops its oldest byte:
// the system reads the controller slower than the reader types.
const PS2_QUEUE_LIMIT = 256;

// What the next byte written to the data port means.
const Ps2DataTarget = Object.freeze({ Keyboard: 0, KeyboardArgument: 1, Configuration: 2, Mouse: 3, MouseArgument: 4 });

// The bits of the configuration byte that turn on the line of each port.
const PS2_CONFIGURATION_KEYBOARD_INTERRUPT = 0x01;
const PS2_CONFIGURATION_MOUSE_INTERRUPT = 0x02;

// The PS/2 controller with its keyboard and its mouse. A key reaches the
// system as its bytes of scan code set 1, which the controller gives when
// its translation is on. Each byte that comes to the head of the queue
// raises the line of its port, when the configuration turns that line on,
// as the output buffer of the controller does.
export class Ps2Controller {
  constructor(raiseLine = () => {}) {
    this.raiseLine = raiseLine;
    this.queue = []; // Of {byte, mouse}.
    this.configuration = PS2_DEFAULT_CONFIGURATION;
    this.dataTarget = Ps2DataTarget.Keyboard;
  }
  push(byte, mouse) {
    if (this.queue.length >= PS2_QUEUE_LIMIT) this.queue.shift();
    this.queue.push({ byte, mouse });
    if (this.queue.length === 1) this.signalHead();
  }
  // signalHead raises the line of the byte at the head of the queue.
  signalHead() {
    if (!this.queue.length) return;
    if (this.queue[0].mouse) {
      if (this.configuration & PS2_CONFIGURATION_MOUSE_INTERRUPT) this.raiseLine(InterruptLine.Mouse);
    } else if (this.configuration & PS2_CONFIGURATION_KEYBOARD_INTERRUPT) {
      this.raiseLine(InterruptLine.Keyboard);
    }
  }
  read(port) {
    if (port === Port.Ps2Command) {
      if (!this.queue.length) return 0;
      return PS2_STATUS_OUTPUT_FULL | (this.queue[0].mouse ? PS2_STATUS_MOUSE : 0);
    }
    const next = this.queue.shift();
    this.signalHead();
    return next ? next.byte : 0;
  }
  write(port, value) {
    if (port === Port.Ps2Command) {
      this.command(value);
      return;
    }
    const target = this.dataTarget;
    this.dataTarget = Ps2DataTarget.Keyboard;
    switch (target) {
      case Ps2DataTarget.Configuration: this.configuration = value; this.signalHead(); return;
      case Ps2DataTarget.KeyboardArgument: this.push(PS2_ACKNOWLEDGE, false); return;
      case Ps2DataTarget.MouseArgument: this.push(PS2_ACKNOWLEDGE, true); return;
      case Ps2DataTarget.Mouse: this.mouseCommand(value); return;
      case Ps2DataTarget.Keyboard: this.keyboardCommand(value); return;
    }
  }
  command(value) {
    switch (value) {
      case 0x20: this.push(this.configuration, false); return; // Read the configuration.
      case 0x60: this.dataTarget = Ps2DataTarget.Configuration; return;
      case 0xaa: this.push(0x55, false); return; // The self test of the controller.
      case 0xa9: case 0xab: this.push(0x00, false); return; // The test of a port.
      case 0xd4: this.dataTarget = Ps2DataTarget.Mouse; return;
      default: return; // Enable and disable change nothing that the page plays.
    }
  }
  keyboardCommand(value) {
    switch (value) {
      case 0xff: this.push(PS2_ACKNOWLEDGE, false); this.push(PS2_SELF_TEST_PASSED, false); return;
      case 0xf2: this.push(PS2_ACKNOWLEDGE, false); this.push(0xab, false); this.push(0x83, false); return;
      case 0xed: case 0xf0: case 0xf3:
        this.push(PS2_ACKNOWLEDGE, false);
        this.dataTarget = Ps2DataTarget.KeyboardArgument;
        return;
      default: this.push(PS2_ACKNOWLEDGE, false); return;
    }
  }
  mouseCommand(value) {
    switch (value) {
      case 0xff: this.push(PS2_ACKNOWLEDGE, true); this.push(PS2_SELF_TEST_PASSED, true); this.push(0x00, true); return;
      case 0xf2: this.push(PS2_ACKNOWLEDGE, true); this.push(0x00, true); return;
      case 0xf3: case 0xe8:
        this.push(PS2_ACKNOWLEDGE, true);
        this.dataTarget = Ps2DataTarget.MouseArgument;
        return;
      default: this.push(PS2_ACKNOWLEDGE, true); return;
    }
  }
  // A key of the document, by KeyboardEvent.code. A code with no byte of
  // set 1 is dropped: false.
  key(code, pressed) {
    const scan = SCAN_CODE_SET_1[code];
    if (scan === undefined) return false;
    if (scan > 0xff) this.push(0xe0, false);
    this.push((scan & 0x7f) | (pressed ? 0 : 0x80), false);
    return true;
  }
  // typeText presses and releases the keys of a text on a keyboard of the
  // layout United States, with Shift around each character that needs it.
  // A character that the layout has no key for stops the text: false.
  typeText(text) {
    for (const character of text) {
      const key = US_LAYOUT_KEYS[character];
      if (key === undefined) return false;
      if (key.shift) this.key("ShiftLeft", true);
      this.key(key.code, true);
      this.key(key.code, false);
      if (key.shift) this.key("ShiftLeft", false);
    }
    return true;
  }
  // A move of the pointer in pixels, y down as in the document, and the
  // buttons as MouseEvent.buttons gives them (bit 0 left, 1 right, 2 middle).
  pointer(deltaX, deltaY, buttons) {
    const x = Math.max(-255, Math.min(255, Math.round(deltaX)));
    const y = Math.max(-255, Math.min(255, Math.round(-deltaY)));
    const left = buttons & 1, right = (buttons >> 1) & 1, middle = (buttons >> 2) & 1;
    const head = left | (right << 1) | (middle << 2) | 0x08 | (x < 0 ? 0x10 : 0) | (y < 0 ? 0x20 : 0);
    this.push(head, true);
    this.push(x & 0xff, true);
    this.push(y & 0xff, true);
  }
}

// KeyboardEvent.code to scan code set 1; a value past 0xFF has the prefix
// 0xE0.
export const SCAN_CODE_SET_1 = Object.freeze({
  Escape: 0x01, Digit1: 0x02, Digit2: 0x03, Digit3: 0x04, Digit4: 0x05, Digit5: 0x06, Digit6: 0x07,
  Digit7: 0x08, Digit8: 0x09, Digit9: 0x0a, Digit0: 0x0b, Minus: 0x0c, Equal: 0x0d, Backspace: 0x0e,
  Tab: 0x0f, KeyQ: 0x10, KeyW: 0x11, KeyE: 0x12, KeyR: 0x13, KeyT: 0x14, KeyY: 0x15, KeyU: 0x16,
  KeyI: 0x17, KeyO: 0x18, KeyP: 0x19, BracketLeft: 0x1a, BracketRight: 0x1b, Enter: 0x1c,
  ControlLeft: 0x1d, KeyA: 0x1e, KeyS: 0x1f, KeyD: 0x20, KeyF: 0x21, KeyG: 0x22, KeyH: 0x23,
  KeyJ: 0x24, KeyK: 0x25, KeyL: 0x26, Semicolon: 0x27, Quote: 0x28, Backquote: 0x29, ShiftLeft: 0x2a,
  Backslash: 0x2b, KeyZ: 0x2c, KeyX: 0x2d, KeyC: 0x2e, KeyV: 0x2f, KeyB: 0x30, KeyN: 0x31, KeyM: 0x32,
  Comma: 0x33, Period: 0x34, Slash: 0x35, ShiftRight: 0x36, NumpadMultiply: 0x37, AltLeft: 0x38,
  Space: 0x39, CapsLock: 0x3a, F1: 0x3b, F2: 0x3c, F3: 0x3d, F4: 0x3e, F5: 0x3f, F6: 0x40, F7: 0x41,
  F8: 0x42, F9: 0x43, F10: 0x44, NumLock: 0x45, ScrollLock: 0x46, Numpad7: 0x47, Numpad8: 0x48,
  Numpad9: 0x49, NumpadSubtract: 0x4a, Numpad4: 0x4b, Numpad5: 0x4c, Numpad6: 0x4d, NumpadAdd: 0x4e,
  Numpad1: 0x4f, Numpad2: 0x50, Numpad3: 0x51, Numpad0: 0x52, NumpadDecimal: 0x53, IntlBackslash: 0x56,
  F11: 0x57, F12: 0x58,
  NumpadEnter: 0xe01c, ControlRight: 0xe01d, NumpadDivide: 0xe035, AltRight: 0xe038, Home: 0xe047,
  ArrowUp: 0xe048, PageUp: 0xe049, ArrowLeft: 0xe04b, ArrowRight: 0xe04d, End: 0xe04f, ArrowDown: 0xe050,
  PageDown: 0xe051, Insert: 0xe052, Delete: 0xe053, MetaLeft: 0xe05b, MetaRight: 0xe05c, ContextMenu: 0xe05d,
});

// The character of each key of the layout United States, with and
// without Shift: the key that typeText presses for a character.
export const US_LAYOUT_KEYS = (() => {
  const keys = { " ": { code: "Space", shift: false }, "\n": { code: "Enter", shift: false } };
  for (const letter of "abcdefghijklmnopqrstuvwxyz") {
    const code = "Key" + letter.toUpperCase();
    keys[letter] = { code, shift: false };
    keys[letter.toUpperCase()] = { code, shift: true };
  }
  const pairs = [
    ["Digit1", "1", "!"], ["Digit2", "2", "@"], ["Digit3", "3", "#"], ["Digit4", "4", "$"], ["Digit5", "5", "%"],
    ["Digit6", "6", "^"], ["Digit7", "7", "&"], ["Digit8", "8", "*"], ["Digit9", "9", "("], ["Digit0", "0", ")"],
    ["Minus", "-", "_"], ["Equal", "=", "+"], ["BracketLeft", "[", "{"], ["BracketRight", "]", "}"],
    ["Semicolon", ";", ":"], ["Quote", "'", "\""], ["Backquote", "`", "~"], ["Backslash", "\\", "|"],
    ["Comma", ",", "<"], ["Period", ".", ">"], ["Slash", "/", "?"],
  ];
  for (const [code, plain, shifted] of pairs) {
    keys[plain] = { code, shift: false };
    keys[shifted] = { code, shift: true };
  }
  return Object.freeze(keys);
})();

// The clock of the machine (the CMOS clock at ports 0x70 and 0x71): the
// date of the page in UTC, in binary-coded decimal, as the firmware of the
// test machine sets it.
export class MachineClock {
  constructor(now) {
    this.now = now;
    this.index = 0;
  }
  write(port, value) {
    if (port === Port.ClockIndex) this.index = value & 0x7f;
  }
  read(port) {
    if (port !== Port.ClockData) return 0;
    const date = new Date(this.now());
    const decimal = (value) => ((Math.floor(value / 10) << 4) | (value % 10)) & 0xff;
    switch (this.index) {
      case 0x00: return decimal(date.getUTCSeconds());
      case 0x02: return decimal(date.getUTCMinutes());
      case 0x04: return decimal(date.getUTCHours());
      case 0x06: return decimal(date.getUTCDay() + 1);
      case 0x07: return decimal(date.getUTCDate());
      case 0x08: return decimal(date.getUTCMonth() + 1);
      case 0x09: return decimal(date.getUTCFullYear() % 100);
      case 0x32: return decimal(Math.floor(date.getUTCFullYear() / 100));
      case 0x0a: return 0x26; // No update in progress.
      case 0x0b: return 0x02; // 24 hours, binary-coded decimal.
      default: return 0;
    }
  }
}

// The throws of the two imports that do not return. The loop driver
// catches them; any other error is a trap of WebAssembly, which ends the
// machine (browser_machine.md, "The subtle points").
export class ProcessorLoopUnwind extends Error {}
export class ProcessorStop extends Error {}

const alignUp = (value, alignment) => Math.ceil(value / alignment) * alignment;

// The layout of the physical memory of a machine: the memory of the kernel
// at 0, then the boot range (the record, the memory map, the boot image),
// the framebuffer, then the free memory up to the end.
export function physicalLayout({ kernelBytes, bootImageSize, framebufferWidth, framebufferHeight, memoryBytes }) {
  const kernelEnd = alignUp(kernelBytes, PAGE_SIZE);
  const record = kernelEnd;
  const memoryMap = record + PAGE_SIZE;
  const bootImage = memoryMap + PAGE_SIZE;
  const bootEnd = bootImage + alignUp(bootImageSize, PAGE_SIZE);
  const framebuffer = bootEnd;
  const framebufferBytes = alignUp(framebufferWidth * framebufferHeight * 4, PAGE_SIZE);
  const free = framebuffer + framebufferBytes;
  const total = alignUp(memoryBytes, WEBASSEMBLY_PAGE_SIZE);
  if (free + 16 * PAGE_SIZE > total) throw new Error("a memory of " + total + " bytes holds no free range after " + free + " bytes");
  return { kernelEnd, record, memoryMap, bootImage, bootEnd, framebuffer, framebufferBytes, free, total };
}

// writeBootRecord writes the boot record and its memory map: what the
// boot program writes on a machine of x86-64. The memory of the kernel and
// the framebuffer are in no range, as the firmware lists no device memory.
export function writeBootRecord(memory, layout, { bootImageSize, framebufferWidth, framebufferHeight, startNanoseconds, trustDescriptionHash = null }) {
  const view = new DataView(memory.buffer);
  const u64 = (address, value) => view.setBigUint64(address, BigInt(value), true);
  const u32 = (address, value) => view.setUint32(address, value, true);
  new Uint8Array(memory.buffer, layout.record, 2 * PAGE_SIZE).fill(0);
  const ranges = [
    { start: layout.record, pages: (layout.bootEnd - layout.record) / PAGE_SIZE, kind: MemoryKind.Boot },
    { start: layout.free, pages: (layout.total - layout.free) / PAGE_SIZE, kind: MemoryKind.Free },
  ];
  ranges.forEach((range, index) => {
    const at = layout.memoryMap + index * MEMORY_RANGE_SIZE;
    u64(at + MEMORY_RANGE_OFFSETS.start, range.start);
    u64(at + MEMORY_RANGE_OFFSETS.page_count, range.pages);
    u32(at + MEMORY_RANGE_OFFSETS.kind, range.kind);
  });
  const field = (name) => layout.record + BOOT_INFO_OFFSETS[name];
  u64(field("magic"), BOOT_INFO_MAGIC);
  u64(field("memory_ranges"), layout.memoryMap);
  u64(field("memory_range_count"), ranges.length);
  u64(field("direct_map_size"), layout.total);
  u64(field("boot_image"), bootImageSize ? layout.bootImage : 0);
  u64(field("boot_image_size"), bootImageSize);
  const framebuffer = field("framebuffer");
  if (framebufferWidth && framebufferHeight) {
    u64(framebuffer + FRAMEBUFFER_OFFSETS.address, layout.framebuffer);
    u32(framebuffer + FRAMEBUFFER_OFFSETS.width, framebufferWidth);
    u32(framebuffer + FRAMEBUFFER_OFFSETS.height, framebufferHeight);
    u32(framebuffer + FRAMEBUFFER_OFFSETS.pixels_per_line, framebufferWidth);
    u32(framebuffer + FRAMEBUFFER_OFFSETS.format, PixelFormat.Blue_Green_Red_X);
  }
  u64(field("cycles_start"), startNanoseconds);
  u64(field("cycles_loaded"), startNanoseconds);
  const vendor = new TextEncoder().encode("modus browser machine");
  new Uint8Array(memory.buffer, field("firmware_vendor"), vendor.length).set(vendor);
  if (trustDescriptionHash && trustDescriptionHash.length === 32) {
    const trust = field("trust");
    u64(trust + 0, 1); // Verifier.Boot_Program
    u64(trust + 8, 1); // Signing_Key_Kind.Test
    new Uint8Array(memory.buffer, trust + 48, 32).set(trustDescriptionHash);
  }
  return layout.record;
}

// The object cache of the page (browser_machine.md, "The object cache of
// the page"): a read-only fetch of objects by hash from a server that the
// page names. The bridge trusts no byte: the system checks the hash of each
// blob and the signer of each realisation (browser_cache.odin of
// modus:contract/object_cache). It only keeps the request to one path of
// one kind and one hash, and the body under the bound of its kind.

// The words of Browser_Cache_Object_Kind and of Browser_Cache_Status. A
// host test of the tool compares them with the enums.
export const BrowserCacheObjectKind = { Blob: 1, Realisation: 2 };
Object.freeze(BrowserCacheObjectKind);
export const BrowserCacheStatus = { Ok: 0, Absent: 1, Hash_Mismatch: 2, Too_Large: 3, Not_Configured: 4, Invalid_Request: 5, Transport_Error: 6, Malformed_Record: 7, Untrusted_Signer: 8, Bad_Signature: 9 };
Object.freeze(BrowserCacheStatus);
// BROWSER_CACHE_OBJECT_LIMIT and REALISATION_WIRE_SIZE of the contract.
export const BROWSER_CACHE_OBJECT_LIMIT = 16777216;
export const REALISATION_WIRE_SIZE = 164;
const BROWSER_CACHE_HASH = /^[0-9a-f]{64}$/;
const BROWSER_CACHE_ZERO_HASH = "0".repeat(64);

// cacheBaseUrlCheck gives the base address of an object cache, or "" when
// text names none that the page may fetch: only http: and https:, with no
// user, no password, no query and no fragment. A final "/" is dropped, so
// each path of the bridge starts with its own "/".
export function cacheBaseUrlCheck(text) {
  if (typeof text !== "string" || text === "" || /[\s\\]/.test(text) || text.includes("#") || text.includes("?")) return "";
  let url;
  try { url = new URL(text); } catch { return ""; }
  if (url.protocol !== "https:" && url.protocol !== "http:") return "";
  if (url.username || url.password || url.search || url.hash) return "";
  const path = url.pathname.replace(/\/+$/, "");
  if (path.split("/").some((part) => part === "." || part === ".." || /%2e|%2f|%5c/i.test(part))) return "";
  return url.origin + path;
}

// browserCacheBodyLimit gives the largest body of a kind; 0 for a word
// that names no kind.
export function browserCacheBodyLimit(kind) {
  if (kind === BrowserCacheObjectKind.Blob) return BROWSER_CACHE_OBJECT_LIMIT;
  if (kind === BrowserCacheObjectKind.Realisation) return REALISATION_WIRE_SIZE;
  return 0;
}

export class ObjectCacheBridge {
  // baseUrl is checked here; fetchProcedure is fetch of the runtime, and a
  // test gives its own.
  constructor({ baseUrl = "", fetchProcedure = globalThis.fetch } = {}) {
    this.baseUrl = cacheBaseUrlCheck(baseUrl);
    this.fetchProcedure = fetchProcedure;
  }
  get configured() {
    return this.baseUrl !== "";
  }
  // urlOf gives the address of the object of kind and hash, or "" for a
  // request that names no object.
  urlOf(kind, hash) {
    if (!this.configured || typeof hash !== "string" || !BROWSER_CACHE_HASH.test(hash) || hash === BROWSER_CACHE_ZERO_HASH) return "";
    if (kind === BrowserCacheObjectKind.Blob) return this.baseUrl + "/blobs/" + hash;
    if (kind === BrowserCacheObjectKind.Realisation) return this.baseUrl + "/realisations/" + hash;
    return "";
  }
  // fetchObject gives { status, bytes }: bytes only with Ok, and never
  // more than the bound of the kind. Ok says only that the server answered:
  // the system checks the bytes.
  async fetchObject(kind, hash) {
    if (!this.configured) return { status: BrowserCacheStatus.Not_Configured, bytes: null };
    const url = this.urlOf(kind, hash);
    if (!url) return { status: BrowserCacheStatus.Invalid_Request, bytes: null };
    const limit = browserCacheBodyLimit(kind);
    let response;
    try {
      response = await this.fetchProcedure(url, { method: "GET", mode: "cors", credentials: "omit", redirect: "error", referrerPolicy: "no-referrer" });
    } catch {
      return { status: BrowserCacheStatus.Transport_Error, bytes: null };
    }
    if (response.status === 404) return { status: BrowserCacheStatus.Absent, bytes: null };
    if (!response.ok) return { status: BrowserCacheStatus.Transport_Error, bytes: null };
    const declared = Number(response.headers?.get?.("content-length") ?? NaN);
    if (Number.isFinite(declared) && declared > limit) {
      response.body?.cancel?.().catch?.(() => {});
      return { status: BrowserCacheStatus.Too_Large, bytes: null };
    }
    // The body is read in its chunks and stopped past the bound: a server
    // that lies about its length never fills the memory of the page.
    const chunks = [];
    let size = 0;
    try {
      const reader = response.body.getReader();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > limit) {
          reader.cancel().catch(() => {});
          return { status: BrowserCacheStatus.Too_Large, bytes: null };
        }
        chunks.push(value);
      }
    } catch {
      return { status: BrowserCacheStatus.Transport_Error, bytes: null };
    }
    const bytes = new Uint8Array(size);
    let at = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, at);
      at += chunk.byteLength;
    }
    return { status: BrowserCacheStatus.Ok, bytes };
  }
}

// trustDescriptionHashParse reads the file <image>.trust that the tool
// writes beside a signed boot image of the page: 64 hexadecimal digits and
// an optional line feed. It gives the 32 bytes, or null for any other text.
export function trustDescriptionHashParse(text) {
  if (typeof text !== "string") return null;
  const digits = text.endsWith("\n") ? text.slice(0, -1) : text;
  if (!/^[0-9a-f]{64}$/.test(digits) || digits === BROWSER_CACHE_ZERO_HASH) return null;
  return Uint8Array.from(digits.match(/../g), (pair) => parseInt(pair, 16));
}

// The stages of the start of a machine, which a page shows while it waits
// (browser_machine.md, "The boot stages of the page"). The worker names the
// download; the lines of the serial ports name the others.
export const BootStage = Object.freeze({
  Download: "download",
  Kernel: "kernel",
  Image_Check: "image_check",
  Services: "services",
  Desktop: "desktop",
  Console: "console",
  Ready: "ready",
});
export const BOOT_STAGE_SENTENCES = Object.freeze({
  download: "downloading the kernel and the boot image",
  kernel: "starting the kernel and the root service",
  image_check: "the root service checks each file of the boot image",
  services: "starting the services",
  desktop: "starting the desktop",
  console: "starting the console",
  ready: "ready",
});
// The line of the kernel when it starts the root service.
export const ROOT_SERVICE_STAGE_LINE = "kernel: boot: kernel: root service: ";
// The key tags of the log facts that end a stage: the first 3 bytes of the
// fact key, which the serial line of a fact writes after the module tag
// (log_facts.md, "The serial port"). A host test of the tool computes each
// one from its fact type.
export const BOOT_STAGE_FACT_TAGS = {
  "root::Boot_Image_Agrees": "9bf297",
  "root::Process_Started": "526e32",
  "root::Process_Started_With_Terminal": "a29438",
  "compositor::First_Frame": "cd3633",
};
Object.freeze(BOOT_STAGE_FACT_TAGS);
// The serial line of a fact: the process, the module tag, the key tag, and
// the value bytes.
const FACT_LINE = /^\[([a-z0-9_]+)\] #[0-9a-f]{8}:([0-9a-f]{6})(?: ([0-9a-z]*))?$/;
const hexadecimalOf = (text) => Array.from(new TextEncoder().encode(text), (byte) => byte.toString(16).padStart(2, "0")).join("");

// BootStageTracker follows the stages of one start from the lines of the
// serial ports. A start with a framebuffer ends at the first frame of the
// compositor; a console image ends at the first line of the console prompt
// on COM2. Each stage comes once and in order: a line of an earlier stage
// changes nothing.
export class BootStageTracker {
  constructor({ desktop, onStage = () => {} }) {
    this.desktop = desktop;
    this.onStage = onStage;
    this.stage = BootStage.Download;
    this.order = [BootStage.Download, BootStage.Kernel, BootStage.Image_Check, BootStage.Services, desktop ? BootStage.Desktop : BootStage.Console, BootStage.Ready];
  }
  enter(stage) {
    if (this.order.indexOf(stage) <= this.order.indexOf(this.stage)) return;
    this.stage = stage;
    this.onStage(stage);
  }
  serialLine(line) {
    if (line.startsWith(ROOT_SERVICE_STAGE_LINE)) {
      this.enter(BootStage.Image_Check);
      return;
    }
    const fact = FACT_LINE.exec(line);
    if (!fact) return;
    const [, process, tag, values = ""] = fact;
    const named = (name) => BOOT_STAGE_FACT_TAGS[name] === tag && name.startsWith(process + "::");
    if (named("root::Boot_Image_Agrees")) this.enter(BootStage.Services);
    else if (this.desktop && named("root::Process_Started") && values === hexadecimalOf("compositor")) this.enter(BootStage.Desktop);
    else if (!this.desktop && named("root::Process_Started_With_Terminal") && values === hexadecimalOf("console")) this.enter(BootStage.Console);
    else if (this.desktop && named("compositor::First_Frame")) this.enter(BootStage.Ready);
  }
  // consoleLine reads a line of COM2: the first line of the prompt ends
  // the start of a console image.
  consoleLine(line) {
    if (!this.desktop && line.startsWith('{"t":"edit"')) this.enter(BootStage.Ready);
  }
}

// The machine: one instance of the kernel, its memory and its devices, on
// one processor. The caller gives the clock and the idle wait of its
// runtime: Atomics.wait in Node and in a worker with shared memory; with
// neither, a wait that returns at once, and the deadline of the timer ends
// the idle loop of the kernel. The clock of the machine counts from the
// creation of the machine, as the cycle counter of a processor counts from
// its reset: the boot record then names the time of the page before the
// kernel as its firmware time.
export class BrowserMachine {
  constructor({ kernelModule, bootImage, trustDescriptionHash = null, memoryMebibytes = 256, framebufferWidth = 0, framebufferHeight = 0, cacheBaseUrl = "", clockNanoseconds, idleWait, onSerialLine = () => {}, onConsoleLine = () => {}, onConsoleBytes = () => {}, onStop = () => {} }) {
    this.kernelModule = kernelModule;
    this.bootImage = bootImage ?? new Uint8Array(0);
    this.trustDescriptionHash = trustDescriptionHash;
    this.memoryMebibytes = memoryMebibytes;
    this.framebufferWidth = framebufferWidth;
    this.framebufferHeight = framebufferHeight;
    const clockBase = clockNanoseconds();
    this.clockNanoseconds = () => clockNanoseconds() - clockBase;
    this.idleWait = idleWait;
    this.onStop = onStop;
    this.serial = new SerialPort(onSerialLine, Port.SerialData);
    this.consolePort = new SerialPort(onConsoleLine, Port.ConsoleData, onConsoleBytes);
    this.interruptLines = 0;
    this.keyboard = new Ps2Controller((line) => { this.interruptLines |= 1 << line; });
    this.clock = new MachineClock(() => Date.now());
    this.objectCache = new ObjectCacheBridge({ baseUrl: cacheBaseUrl });
    this.state = MachineState.Created;
    this.stopCode = null;
    this.trap = null;
    this.calls = 0;
    this.unknownPorts = new Map();
  }

  imports() {
    const machine = this;
    return {
      [PAGE_IMPORT_MODULE]: {
        page_clock_nanoseconds: () => machine.clockNanoseconds(),
        page_port_write_8: (port, value) => machine.portWrite(port, value),
        page_port_read_8: (port) => machine.portRead(port),
        page_processor_loop_unwind: () => { throw new ProcessorLoopUnwind(); },
        page_processor_stop: () => { throw new ProcessorStop(); },
        page_idle_wait: (boundNanoseconds) => machine.idleWait(boundNanoseconds),
        page_interrupt_lines_take: () => machine.interruptLinesTake(),
      },
    };
  }

  // interruptLinesTake gives the kernel the lines raised since its last
  // call, and clears them.
  interruptLinesTake() {
    const lines = this.interruptLines;
    this.interruptLines = 0;
    return lines;
  }

  portWrite(port, value) {
    if (this.serial.holds(port)) this.serial.write(port, value);
    else if (this.consolePort.holds(port)) this.consolePort.write(port, value);
    else if (port === Port.Ps2Data || port === Port.Ps2Command) this.keyboard.write(port, value);
    else if (port === Port.ClockIndex) this.clock.write(port, value);
    else if (port === Port.DebugExit) { this.stopCode = value; throw new ProcessorStop(); }
    else this.unknownPorts.set(port, (this.unknownPorts.get(port) ?? 0) + 1);
  }

  portRead(port) {
    if (this.serial.holds(port)) return this.serial.read(port);
    if (this.consolePort.holds(port)) return this.consolePort.read(port);
    if (port === Port.Ps2Data || port === Port.Ps2Command) return this.keyboard.read(port);
    if (port === Port.ClockData) return this.clock.read(port);
    // A port with no device reads all ones.
    return 0xff;
  }

  // start instantiates the kernel, places the memory, the boot image and
  // the boot record, and calls entry. entry never returns: it ends in the
  // throw of its stack switch, and the loop takes the first run.
  async start() {
    const instance = await WebAssembly.instantiate(this.kernelModule, this.imports());
    for (const name of KERNEL_EXPORT_NAMES) {
      if (!(name in instance.exports)) throw new Error("the kernel exports no " + name);
    }
    this.instance = instance;
    this.memory = instance.exports.memory;
    // The top of the shadow stack, before the first call.
    this.stackTop = instance.exports.__stack_pointer.value;
    this.layout = physicalLayout({
      kernelBytes: this.memory.buffer.byteLength,
      bootImageSize: this.bootImage.length,
      framebufferWidth: this.framebufferWidth,
      framebufferHeight: this.framebufferHeight,
      memoryBytes: this.memoryMebibytes * 1048576,
    });
    this.memory.grow((this.layout.total - this.memory.buffer.byteLength) / WEBASSEMBLY_PAGE_SIZE);
    new Uint8Array(this.memory.buffer, this.layout.bootImage, this.bootImage.length).set(this.bootImage);
    const record = writeBootRecord(this.memory, this.layout, {
      bootImageSize: this.bootImage.length,
      framebufferWidth: this.framebufferWidth,
      framebufferHeight: this.framebufferHeight,
      startNanoseconds: this.clockNanoseconds(),
      trustDescriptionHash: this.trustDescriptionHash,
    });
    this.state = MachineState.Running;
    this.call(() => this.instance.exports.entry(record));
  }

  // call runs one call into the kernel and reads how it ended. The throw of
  // the loop is a path of the kernel that ran to its end.
  call(body) {
    this.calls += 1;
    try {
      return body();
    } catch (error) {
      if (error instanceof ProcessorLoopUnwind) {
        // The throw skipped the end of each frame, so the shadow stack
        // pointer stays where the deepest frame left it: without this, each
        // throw leaks those frames, and the stack runs past its bottom.
        this.instance.exports.__stack_pointer.value = this.stackTop;
        return LoopResult.Kernel_Returned;
      }
      if (error instanceof ProcessorStop) {
        this.state = MachineState.Stopped;
      } else {
        this.state = MachineState.Trapped;
        this.trap = error;
      }
      this.onStop(this);
      return null;
    }
  }

  // runSlice calls the processor loop until the clock passes the bound or
  // the loop has nothing to run. Kernel_Returned and Slice_Ended both mean
  // "call again": the thread goes on at the next call. The driver of the
  // runtime yields to its event loop between two slices.
  runSlice(boundNanoseconds) {
    const end = this.clockNanoseconds() + BigInt(boundNanoseconds);
    let result = LoopResult.Kernel_Returned;
    while (this.state === MachineState.Running && this.clockNanoseconds() < end) {
      result = this.call(() => this.instance.exports.modus_processor_loop_run(STEP_BUDGET));
      if (result === LoopResult.Budget_Refused) {
        this.state = MachineState.Trapped;
        this.trap = new Error("the kernel refused the step budget " + STEP_BUDGET);
        this.onStop(this);
        break;
      }
      if (result === LoopResult.Idle) break;
    }
    return result;
  }

  // The pixels of the framebuffer, blue first: a view of the memory.
  framebufferPixels() {
    if (!this.memory || !this.framebufferWidth) return null;
    return new Uint8Array(this.memory.buffer, this.layout.framebuffer, this.framebufferWidth * this.framebufferHeight * 4);
  }
}
