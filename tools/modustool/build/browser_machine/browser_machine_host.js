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
  debug_image: 408,
  debug_image_size: 416,
  start_request: 424,
  start_request_source: 432,
};
export const BOOT_INFO_SIZE = 440;
// The offsets of the trust record (Boot_Trust) that the page writes, and the
// word of File_Check that it writes there. A host test of the tool compares
// each one with the contract.
export const BOOT_TRUST_OFFSETS = { description_hash: 48, file_check: 216 };
export const FileCheck = { None: 0, Boot_Program: 1, Root_Service_At_Load: 2 };
Object.freeze(FileCheck);
export const FRAMEBUFFER_OFFSETS = { address: 0, width: 8, height: 12, pixels_per_line: 16, format: 20 };
export const MEMORY_RANGE_OFFSETS = { start: 0, page_count: 8, kind: 16, reserved: 20 };
export const MEMORY_RANGE_SIZE = 24;
export const BOOT_INFO_MAGIC = 0x4F464E49544F4F42n; // The bytes "BOOTINFO".

// Live viewport resize control page (src/library/modus/contract/boot_info/browser_resize.odin).
// A host test of the tool compares each constant and offset with the contract.
export const BROWSER_RESIZE_MAX_WIDTH = 1920;
export const BROWSER_RESIZE_MAX_HEIGHT = 1200;
export const BROWSER_RESIZE_MIN_WIDTH = 640;
export const BROWSER_RESIZE_MIN_HEIGHT = 400;
export const BROWSER_RESIZE_MAX_BYTES = BROWSER_RESIZE_MAX_WIDTH * BROWSER_RESIZE_MAX_HEIGHT * 4;
export const BROWSER_RESIZE_TOTAL_PAGES = BROWSER_RESIZE_MAX_BYTES / 4096 + 1;
export const BROWSER_RESIZE_MAGIC = 0x3153455256444f4dn; // The bytes "MODVRES1".
export const BROWSER_RESIZE_OFFSETS = {
  magic: 0,
  max_width: 8,
  max_height: 12,
  req_width: 16,
  req_height: 20,
  req_seq: 24,
  ack_width: 28,
  ack_height: 32,
  ack_seq: 36,
  frame_seq: 40,
  dirty_x: 44,
  dirty_y: 48,
  dirty_w: 52,
  dirty_h: 56,
  desktop_width: 60,
  desktop_height: 64,
};
export const BROWSER_RESIZE_PAGE_SIZE = 72;
const BROWSER_RESIZE_MIN_MEMORY_BYTES = 64 * 1024 * 1024;

// The words of Memory_Kind and of Pixel_Format.
export const MemoryKind = Object.freeze({ Reserved: 0, Free: 1, Boot: 2 });
export const PixelFormat = Object.freeze({ None: 0, Blue_Green_Red_X: 1, Red_Green_Blue_X: 2 });

// The words of Processor_Loop_Result (src/modulus/processor_loop_wasm64p32.odin).
export const LoopResult = Object.freeze({ Idle: 0, Kernel_Returned: 1, Budget_Refused: 2, Slice_Ended: 3 });

// The instructions of one call of the loop: STEP_BUDGET_LIMIT of the kernel
// is 1 000 000. 100 000 instructions reduces JS/WASM boundary overhead while
// staying within the 8 ms worker slice so input and frame reads stay snappy.
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
// Plan value: 1024 bytes holds up to 8 full-viewport 4-byte IntelliMouse resync
// bursts (ceil(1920 / 127) * 4 * 2 = 128 bytes each) without dropping packets.
const PS2_QUEUE_LIMIT = 1024;

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
    this.mouseWheel = false;
    this.mouseLastCommand = 0;
    this.mouseRateHistory = [];
    this.mouseButtons = 0;
    this.mouseReporting = true;
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
      case Ps2DataTarget.MouseArgument:
        this.push(PS2_ACKNOWLEDGE, true);
        if (this.mouseLastCommand === 0xf3) {
          this.mouseRateHistory.push(value & 0xff);
          if (this.mouseRateHistory.length > 3) this.mouseRateHistory.shift();
          if (
            this.mouseRateHistory.length === 3 &&
            this.mouseRateHistory[0] === 200 &&
            this.mouseRateHistory[1] === 100 &&
            this.mouseRateHistory[2] === 80
          ) {
            this.mouseWheel = true;
          }
        }
        this.mouseLastCommand = 0;
        return;
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
      case 0xd4:
        // On real 8042 hardware, every mouse byte (including an argument to
        // 0xF3/0xE8) is prefixed by controller command 0xD4.
        this.dataTarget = this.mouseLastCommand !== 0 ? Ps2DataTarget.MouseArgument : Ps2DataTarget.Mouse;
        return;
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
      case 0xff:
        this.mouseWheel = false;
        this.mouseLastCommand = 0;
        this.mouseRateHistory = [];
        this.mouseReporting = false;
        this.push(PS2_ACKNOWLEDGE, true);
        this.push(PS2_SELF_TEST_PASSED, true);
        this.push(0x00, true);
        return;
      case 0xf6:
        this.mouseWheel = false;
        this.mouseLastCommand = 0;
        this.mouseRateHistory = [];
        this.mouseReporting = false;
        this.push(PS2_ACKNOWLEDGE, true);
        return;
      case 0xf5:
        this.mouseLastCommand = 0;
        this.mouseReporting = false;
        this.push(PS2_ACKNOWLEDGE, true);
        return;
      case 0xf4:
        this.mouseLastCommand = 0;
        this.mouseReporting = true;
        this.push(PS2_ACKNOWLEDGE, true);
        return;
      case 0xf2:
        this.mouseLastCommand = 0;
        this.push(PS2_ACKNOWLEDGE, true);
        this.push(this.mouseWheel ? 0x03 : 0x00, true);
        return;
      case 0xf3: case 0xe8:
        this.mouseLastCommand = value;
        this.push(PS2_ACKNOWLEDGE, true);
        return;
      default:
        this.mouseLastCommand = 0;
        this.push(PS2_ACKNOWLEDGE, true);
        return;
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
  // Moves larger than one 8-bit signed step are split into bounded packets so
  // absolute-to-relative synchronization reaches any pixel of the screen.
  pointer(deltaX, deltaY, buttons, wheel = 0) {
    this.mouseButtons = buttons;
    if (!this.mouseReporting) return;
    let remX = Math.max(-4096, Math.min(4096, Math.round(deltaX)));
    let remY = Math.max(-4096, Math.min(4096, Math.round(-deltaY)));
    let remZ = this.mouseWheel ? Math.max(-64, Math.min(64, Math.round(wheel))) : 0;
    const left = buttons & 1, right = (buttons >> 1) & 1, middle = (buttons >> 2) & 1;
    const packetSize = this.mouseWheel ? 4 : 3;
    do {
      // Never split a PS/2 mouse packet when the queue is full.
      if (this.queue.length + packetSize > PS2_QUEUE_LIMIT) break;
      const x = Math.max(-127, Math.min(127, remX));
      const y = Math.max(-127, Math.min(127, remY));
      const z = Math.max(-7, Math.min(7, remZ));
      remX -= x;
      remY -= y;
      remZ -= z;
      const head = left | (right << 1) | (middle << 2) | 0x08 | (x < 0 ? 0x10 : 0) | (y < 0 ? 0x20 : 0);
      this.push(head, true);
      this.push(x & 0xff, true);
      this.push(y & 0xff, true);
      if (this.mouseWheel) this.push(z & 0xff, true);
    } while (remX !== 0 || remY !== 0 || remZ !== 0);
  }
  wheel(notches) {
    if (!this.mouseWheel || !this.mouseReporting) return;
    const count = Math.round(notches);
    if (count !== 0) this.pointer(0, 0, this.mouseButtons, count);
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

// The throws of the control-flow imports that do not return. They intentionally
// do NOT extend Error so V8 skips capturing a stack trace on every syscall and
// idle yield (tens of thousands of times per second). Any other thrown value is
// treated as a WebAssembly trap (browser_machine.md, "The subtle points").
export class ProcessorLoopUnwind {}
export class ProcessorStop {}
export class ProcessorIdle {
  constructor(boundNanoseconds) {
    this.boundNanoseconds = boundNanoseconds;
  }
}
const UNWIND_SIGNAL = new ProcessorLoopUnwind();
const STOP_SIGNAL = new ProcessorStop();

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
  const liveResize = framebufferWidth > 0 && framebufferHeight > 0 && memoryBytes >= BROWSER_RESIZE_MIN_MEMORY_BYTES;
  const framebufferBytes = liveResize
    ? Math.max(alignUp(framebufferWidth * framebufferHeight * 4, PAGE_SIZE), BROWSER_RESIZE_MAX_BYTES) + PAGE_SIZE
    : alignUp(framebufferWidth * framebufferHeight * 4, PAGE_SIZE);
  const framebufferResizeControl = liveResize ? framebuffer + BROWSER_RESIZE_MAX_BYTES : 0;
  const free = framebuffer + framebufferBytes;
  const total = alignUp(memoryBytes, WEBASSEMBLY_PAGE_SIZE);
  if (free + 16 * PAGE_SIZE > total) throw new Error("a memory of " + total + " bytes holds no free range after " + free + " bytes");
  return { kernelEnd, record, memoryMap, bootImage, bootEnd, framebuffer, framebufferBytes, framebufferResizeControl, free, total };
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
    if (layout.framebufferResizeControl) {
      const control = layout.framebufferResizeControl;
      new Uint8Array(memory.buffer, control, PAGE_SIZE).fill(0);
      u64(control + BROWSER_RESIZE_OFFSETS.magic, BROWSER_RESIZE_MAGIC);
      u32(control + BROWSER_RESIZE_OFFSETS.max_width, BROWSER_RESIZE_MAX_WIDTH);
      u32(control + BROWSER_RESIZE_OFFSETS.max_height, BROWSER_RESIZE_MAX_HEIGHT);
      u32(control + BROWSER_RESIZE_OFFSETS.req_width, framebufferWidth);
      u32(control + BROWSER_RESIZE_OFFSETS.req_height, framebufferHeight);
      u32(control + BROWSER_RESIZE_OFFSETS.req_seq, 0);
      u32(control + BROWSER_RESIZE_OFFSETS.ack_width, framebufferWidth);
      u32(control + BROWSER_RESIZE_OFFSETS.ack_height, framebufferHeight);
      u32(control + BROWSER_RESIZE_OFFSETS.ack_seq, 0);
    }
  }
  u64(field("cycles_start"), startNanoseconds);
  u64(field("cycles_loaded"), startNanoseconds);
  const vendor = new TextEncoder().encode("modus browser machine");
  new Uint8Array(memory.buffer, field("firmware_vendor"), vendor.length).set(vendor);
  // The page verifies nothing: the verifier and the key kind stay None, and
  // the record says that the root service checks each file at its first
  // use, against the description whose hash the page gives
  // (browser_machine.md, "The boot").
  if (trustDescriptionHash && trustDescriptionHash.length === 32) {
    const trust = field("trust");
    new Uint8Array(memory.buffer, trust + BOOT_TRUST_OFFSETS.description_hash, 32).set(trustDescriptionHash);
    u64(trust + BOOT_TRUST_OFFSETS.file_check, FileCheck.Root_Service_At_Load);
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
// The format bounds of verified 1 MiB Bao frame streaming (object_frames.odin
// of modus:contract/object_cache). A host test of the tool compares each one.
export const OBJECT_FRAME_PAYLOAD_BYTES = 1048576;
export const OBJECT_CHUNKS_PER_FRAME = 1024;
export const OBJECT_MAX_PROOF_DEPTH = 32;
export const OBJECT_PROOF_ENTRY_SIZE = 32;
export const OBJECT_OUTBOARD_ENTRY_SIZE = 64;
export const BROWSER_CACHE_OUTBOARD_PREFIX = "/outboards/";
// Peak payload buffer kept in memory while streaming a blob past 16 MiB:
// strictly one verified 1 MiB frame (OBJECT_FRAME_PAYLOAD_BYTES).
export const BROWSER_CACHE_STREAM_BUFFER_LIMIT = OBJECT_FRAME_PAYLOAD_BYTES;
const BROWSER_CACHE_HASH = /^[0-9a-f]{64}$/;
const BROWSER_CACHE_ZERO_HASH = "0".repeat(64);
const OBJECT_MAX_FRAME_COUNT = 2 ** OBJECT_MAX_PROOF_DEPTH;

// Pure BLAKE3 primitives matching src/library/modus/contract/blake3/blake3.odin
// for verified streaming of 1 MiB Bao frames in JavaScript without holding
// blobs past 16 MiB whole in memory.
const BLAKE3_CHUNK_SIZE = 1024;
const BLAKE3_BLOCK_SIZE = 64;
const BLAKE3_HASH_SIZE = 32;
const BLAKE3_FLAG_CHUNK_START = 1;
const BLAKE3_FLAG_CHUNK_END = 2;
const BLAKE3_FLAG_PARENT = 4;
const BLAKE3_FLAG_ROOT = 8;
const BLAKE3_IV = Uint32Array.of(
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
);
const BLAKE3_MSG_PERM = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8];

const rotr32 = (value, count) => ((value >>> count) | (value << (32 - count))) >>> 0;

function blake3Mix(state, a, b, c, d, x, y) {
  state[a] = (state[a] + state[b] + x) >>> 0;
  state[d] = rotr32(state[d] ^ state[a], 16);
  state[c] = (state[c] + state[d]) >>> 0;
  state[b] = rotr32(state[b] ^ state[c], 12);
  state[a] = (state[a] + state[b] + y) >>> 0;
  state[d] = rotr32(state[d] ^ state[a], 8);
  state[c] = (state[c] + state[d]) >>> 0;
  state[b] = rotr32(state[b] ^ state[c], 7);
}

function blake3Compress(cv, block, counter, blockLength, flags) {
  const state = new Uint32Array(16);
  for (let i = 0; i < 8; i += 1) state[i] = cv[i];
  state[8] = BLAKE3_IV[0];
  state[9] = BLAKE3_IV[1];
  state[10] = BLAKE3_IV[2];
  state[11] = BLAKE3_IV[3];
  state[12] = Number(counter & 0xffffffffn) >>> 0;
  state[13] = Number((counter >> 32n) & 0xffffffffn) >>> 0;
  state[14] = blockLength >>> 0;
  state[15] = flags >>> 0;
  let message = Uint32Array.from(block);
  for (let round = 0; round < 7; round += 1) {
    blake3Mix(state, 0, 4, 8, 12, message[0], message[1]);
    blake3Mix(state, 1, 5, 9, 13, message[2], message[3]);
    blake3Mix(state, 2, 6, 10, 14, message[4], message[5]);
    blake3Mix(state, 3, 7, 11, 15, message[6], message[7]);
    blake3Mix(state, 0, 5, 10, 15, message[8], message[9]);
    blake3Mix(state, 1, 6, 11, 12, message[10], message[11]);
    blake3Mix(state, 2, 7, 8, 13, message[12], message[13]);
    blake3Mix(state, 3, 4, 9, 14, message[14], message[15]);
    if (round < 6) {
      const next = new Uint32Array(16);
      for (let i = 0; i < 16; i += 1) next[i] = message[BLAKE3_MSG_PERM[i]];
      message = next;
    }
  }
  const half = new Uint32Array(8);
  for (let i = 0; i < 8; i += 1) half[i] = (state[i] ^ state[i + 8]) >>> 0;
  return half;
}

function blake3ReadBlockWords(bytes, offset, size) {
  const padded = new Uint8Array(BLAKE3_BLOCK_SIZE);
  if (size > 0) padded.set(bytes.subarray(offset, offset + size), 0);
  const words = new Uint32Array(16);
  for (let i = 0; i < 16; i += 1) {
    const at = i * 4;
    words[i] = (padded[at] | (padded[at + 1] << 8) | (padded[at + 2] << 16) | (padded[at + 3] << 24)) >>> 0;
  }
  return words;
}

function blake3ParentBlock(left, right) {
  const block = new Uint32Array(16);
  for (let i = 0; i < 8; i += 1) {
    block[i] = left[i];
    block[i + 8] = right[i];
  }
  return block;
}

function blake3ChunkValue(chunk, chunkCounter, lastFlags) {
  let value = Uint32Array.from(BLAKE3_IV);
  let offset = 0;
  let flags = BLAKE3_FLAG_CHUNK_START;
  for (;;) {
    const size = Math.min(chunk.byteLength - offset, BLAKE3_BLOCK_SIZE);
    const block = blake3ReadBlockWords(chunk, offset, size);
    offset += size;
    if (offset >= chunk.byteLength) flags |= BLAKE3_FLAG_CHUNK_END | lastFlags;
    value = blake3Compress(value, block, chunkCounter, size, flags);
    if (offset >= chunk.byteLength) return value;
    flags = 0;
  }
}

function blake3LeftSize(size) {
  const chunks = Math.floor((size - 1) / BLAKE3_CHUNK_SIZE);
  let power = 1;
  while (power * 2 <= chunks) power *= 2;
  return power * BLAKE3_CHUNK_SIZE;
}

export function blake3ChainingValueToBytes(cv) {
  const out = new Uint8Array(BLAKE3_HASH_SIZE);
  for (let i = 0; i < 8; i += 1) {
    const word = cv[i] >>> 0;
    out[i * 4] = word & 0xff;
    out[i * 4 + 1] = (word >>> 8) & 0xff;
    out[i * 4 + 2] = (word >>> 16) & 0xff;
    out[i * 4 + 3] = (word >>> 24) & 0xff;
  }
  return out;
}

export function blake3ChainingValueFromBytes(bytes) {
  const cv = new Uint32Array(8);
  for (let i = 0; i < 8; i += 1) {
    const at = i * 4;
    cv[i] = (bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16) | (bytes[at + 3] << 24)) >>> 0;
  }
  return cv;
}

export function blake3ParentChainingValue(left, right) {
  return blake3Compress(BLAKE3_IV, blake3ParentBlock(left, right), 0n, BLAKE3_BLOCK_SIZE, BLAKE3_FLAG_PARENT);
}

export function blake3RootOfChildren(left, right) {
  return blake3ChainingValueToBytes(
    blake3Compress(BLAKE3_IV, blake3ParentBlock(left, right), 0n, BLAKE3_BLOCK_SIZE, BLAKE3_FLAG_PARENT | BLAKE3_FLAG_ROOT),
  );
}

export function blake3SubtreeChainingValue(input, chunkCounter = 0n) {
  const counter = BigInt(chunkCounter);
  if (input.byteLength <= BLAKE3_CHUNK_SIZE) return blake3ChunkValue(input, counter, 0);
  const left = blake3LeftSize(input.byteLength);
  const leftCv = blake3SubtreeChainingValue(input.subarray(0, left), counter);
  const rightCv = blake3SubtreeChainingValue(input.subarray(left), counter + BigInt(left / BLAKE3_CHUNK_SIZE));
  return blake3ParentChainingValue(leftCv, rightCv);
}

export function blake3Hash(input) {
  if (input.byteLength <= BLAKE3_CHUNK_SIZE) return blake3ChainingValueToBytes(blake3ChunkValue(input, 0n, BLAKE3_FLAG_ROOT));
  const left = blake3LeftSize(input.byteLength);
  return blake3RootOfChildren(
    blake3SubtreeChainingValue(input.subarray(0, left), 0n),
    blake3SubtreeChainingValue(input.subarray(left), BigInt(left / BLAKE3_CHUNK_SIZE)),
  );
}

export function blake3HashHex(hash) {
  let text = "";
  for (let i = 0; i < hash.byteLength; i += 1) text += hash[i].toString(16).padStart(2, "0");
  return text;
}

export function blake3HashFromHex(hex) {
  if (typeof hex !== "string" || !BROWSER_CACHE_HASH.test(hex)) return null;
  return Uint8Array.from(hex.match(/../g), (pair) => parseInt(pair, 16));
}

export function blake3HashesEqual(a, b) {
  if (!a || !b || a.byteLength !== BLAKE3_HASH_SIZE || b.byteLength !== BLAKE3_HASH_SIZE) return false;
  let diff = 0;
  for (let i = 0; i < BLAKE3_HASH_SIZE; i += 1) diff |= a[i] ^ b[i];
  return diff === 0;
}

function validFrameBytes(frameBytes) {
  if (!Number.isSafeInteger(frameBytes) || frameBytes < BLAKE3_CHUNK_SIZE || frameBytes > OBJECT_FRAME_PAYLOAD_BYTES || frameBytes % BLAKE3_CHUNK_SIZE !== 0) return false;
  const chunks = frameBytes / BLAKE3_CHUNK_SIZE;
  return chunks > 0 && (chunks & (chunks - 1)) === 0;
}

// Bao frame tree math matching src/library/modus/contract/object_cache/object_frames.odin.
export function objectFrameCount(objectSize, frameBytes = OBJECT_FRAME_PAYLOAD_BYTES) {
  if (!Number.isSafeInteger(objectSize) || objectSize < 0 || !validFrameBytes(frameBytes)) return 0;
  const count = objectSize === 0 ? 1 : Math.ceil(objectSize / frameBytes);
  return count <= OBJECT_MAX_FRAME_COUNT ? count : 0;
}

export function objectFrameLength(objectSize, frameIndex, frameBytes = OBJECT_FRAME_PAYLOAD_BYTES) {
  const count = objectFrameCount(objectSize, frameBytes);
  if (count === 0 || !Number.isSafeInteger(frameIndex) || frameIndex < 0 || frameIndex >= count) return -1;
  if (frameIndex < count - 1) return frameBytes;
  return objectSize - frameIndex * frameBytes;
}

export function objectLeftFrames(frames) {
  let power = 1;
  while (power * 2 < frames) power *= 2;
  return power;
}

export function objectFramePath(frameCount, frameIndex) {
  if (!Number.isSafeInteger(frameCount) || frameCount <= 0 || frameCount > OBJECT_MAX_FRAME_COUNT) return null;
  if (!Number.isSafeInteger(frameIndex) || frameIndex < 0 || frameIndex >= frameCount) return null;
  const parentIndex = [];
  const inLeft = [];
  let first = 0;
  let size = frameCount;
  let index = 0;
  while (size > 1) {
    const left = objectLeftFrames(size);
    parentIndex.push(index);
    if (frameIndex < first + left) {
      inLeft.push(true);
      index += 1;
      size = left;
    } else {
      inLeft.push(false);
      index += left;
      first += left;
      size -= left;
    }
  }
  return { depth: parentIndex.length, parentIndex, inLeft };
}

export function objectFrameParentIndex(frameCount, firstFrame, frames) {
  let low = 0;
  let size = frameCount;
  let index = 0;
  while (size > 1) {
    if (low === firstFrame && size === frames) return index;
    const left = objectLeftFrames(size);
    if (firstFrame < low + left) {
      index += 1;
      size = left;
    } else {
      index += left;
      low += left;
      size -= left;
    }
  }
  return -1;
}

// Streaming Bao frame-tree builder matching Frame_Tree_Builder in object_frames.odin.
// Calls readFrame(frameIndex, length) one frame at a time so multi-MiB blobs
// never allocate more than one frame in memory.
export function objectFrameTreeBuild({ objectSize, readFrame, frameBytes = OBJECT_FRAME_PAYLOAD_BYTES }) {
  const frameCount = objectFrameCount(objectSize, frameBytes);
  if (frameCount === 0 || typeof readFrame !== "function") throw new Error("invalid objectSize or frameBytes for frame tree");
  const outboard = new Uint8Array((frameCount - 1) * OBJECT_OUTBOARD_ENTRY_SIZE);
  if (frameCount === 1) {
    const frame = readFrame(0, objectSize);
    if (!(frame instanceof Uint8Array) || frame.byteLength !== objectSize) throw new Error("frame 0 length mismatch");
    const root = blake3Hash(frame);
    return { root, rootHex: blake3HashHex(root), outboard, frameCount };
  }
  const chunksPerFrame = BigInt(frameBytes / BLAKE3_CHUNK_SIZE);
  const stack = [];
  let root = null;
  const joinTop = () => {
    const right = stack.pop();
    const left = stack.pop();
    const first = left.first;
    const frames = left.frames + right.frames;
    const parentIdx = objectFrameParentIndex(frameCount, first, frames);
    if (parentIdx < 0) throw new Error("invalid frame parent index");
    const entryOffset = parentIdx * OBJECT_OUTBOARD_ENTRY_SIZE;
    outboard.set(blake3ChainingValueToBytes(left.cv), entryOffset);
    outboard.set(blake3ChainingValueToBytes(right.cv), entryOffset + BLAKE3_HASH_SIZE);
    if (first === 0 && frames === frameCount) {
      root = blake3RootOfChildren(left.cv, right.cv);
      return;
    }
    stack.push({ cv: blake3ParentChainingValue(left.cv, right.cv), first, frames });
  };
  for (let frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
    const length = objectFrameLength(objectSize, frameIndex, frameBytes);
    const frame = readFrame(frameIndex, length);
    if (!(frame instanceof Uint8Array) || frame.byteLength !== length) throw new Error("frame length mismatch at " + frameIndex);
    const cv = blake3SubtreeChainingValue(frame, BigInt(frameIndex) * chunksPerFrame);
    stack.push({ cv, first: frameIndex, frames: 1 });
    while (stack.length >= 2 && stack[stack.length - 1].frames === stack[stack.length - 2].frames) joinTop();
  }
  while (stack.length >= 2) joinTop();
  if (!root || stack.length !== 0) throw new Error("incomplete frame tree");
  return { root, rootHex: blake3HashHex(root), outboard, frameCount };
}

export function objectProofFromOutboard(outboard, objectSize, frameIndex, frameBytes = OBJECT_FRAME_PAYLOAD_BYTES) {
  const frameCount = objectFrameCount(objectSize, frameBytes);
  const path = objectFramePath(frameCount, frameIndex);
  if (!path || !(outboard instanceof Uint8Array)) return null;
  if (outboard.byteLength !== (frameCount - 1) * OBJECT_OUTBOARD_ENTRY_SIZE) return null;
  const proof = new Uint8Array(path.depth * OBJECT_PROOF_ENTRY_SIZE);
  for (let level = 0; level < path.depth; level += 1) {
    const entryOffset = path.parentIndex[level] * OBJECT_OUTBOARD_ENTRY_SIZE;
    const siblingOffset = path.inLeft[level] ? entryOffset + BLAKE3_HASH_SIZE : entryOffset;
    proof.set(outboard.subarray(siblingOffset, siblingOffset + BLAKE3_HASH_SIZE), level * OBJECT_PROOF_ENTRY_SIZE);
  }
  return proof;
}

// Verifies one frame against the whole-blob BLAKE3 hash using its Bao sibling
// proof, matching object_frame_verify in object_frames.odin.
export function objectFrameVerify({ expectedHash, objectSize, frameIndex, proof, frame, frameBytes = OBJECT_FRAME_PAYLOAD_BYTES }) {
  const hashBytes = typeof expectedHash === "string" ? blake3HashFromHex(expectedHash) : expectedHash;
  if (!(hashBytes instanceof Uint8Array) || hashBytes.byteLength !== BLAKE3_HASH_SIZE) return BrowserCacheStatus.Invalid_Request;
  let allZero = true;
  for (let i = 0; i < BLAKE3_HASH_SIZE; i += 1) if (hashBytes[i] !== 0) { allZero = false; break; }
  if (allZero) return BrowserCacheStatus.Invalid_Request;
  const frameCount = objectFrameCount(objectSize, frameBytes);
  const expectedLength = objectFrameLength(objectSize, frameIndex, frameBytes);
  if (frameCount === 0 || expectedLength < 0 || !(frame instanceof Uint8Array) || frame.byteLength !== expectedLength) {
    return BrowserCacheStatus.Invalid_Request;
  }
  const path = objectFramePath(frameCount, frameIndex);
  if (!path || !(proof instanceof Uint8Array) || proof.byteLength !== path.depth * OBJECT_PROOF_ENTRY_SIZE) {
    return BrowserCacheStatus.Invalid_Request;
  }
  if (frameCount === 1) {
    return blake3HashesEqual(blake3Hash(frame), hashBytes) ? BrowserCacheStatus.Ok : BrowserCacheStatus.Hash_Mismatch;
  }
  const chunksPerFrame = BigInt(frameBytes / BLAKE3_CHUNK_SIZE);
  let value = blake3SubtreeChainingValue(frame, BigInt(frameIndex) * chunksPerFrame);
  for (let level = path.depth - 1; level >= 1; level -= 1) {
    const sibling = blake3ChainingValueFromBytes(proof.subarray(level * OBJECT_PROOF_ENTRY_SIZE, (level + 1) * OBJECT_PROOF_ENTRY_SIZE));
    value = path.inLeft[level] ? blake3ParentChainingValue(value, sibling) : blake3ParentChainingValue(sibling, value);
  }
  const topSibling = blake3ChainingValueFromBytes(proof.subarray(0, OBJECT_PROOF_ENTRY_SIZE));
  const root = path.inLeft[0] ? blake3RootOfChildren(value, topSibling) : blake3RootOfChildren(topSibling, value);
  return blake3HashesEqual(root, hashBytes) ? BrowserCacheStatus.Ok : BrowserCacheStatus.Hash_Mismatch;
}

// Strict parser for HTTP Content-Range: bytes <start>-<end>/<total>.
export function parseContentRange(header) {
  if (typeof header !== "string") return null;
  const match = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(header.trim());
  if (!match) return null;
  const start = Number(match[1]);
  const end = Number(match[2]);
  const total = Number(match[3]);
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || !Number.isSafeInteger(total)) return null;
  if (start < 0 || end < start || total <= end) return null;
  return { start, end, total };
}

function parseHexBytes(text) {
  if (typeof text !== "string" || text.length % 2 !== 0 || (text.length > 0 && !/^[0-9a-f]+$/.test(text))) return null;
  if (text.length === 0) return new Uint8Array(0);
  return Uint8Array.from(text.match(/../g), (pair) => parseInt(pair, 16));
}

async function readResponseExact(response, expectedBytes) {
  const rawLength = response.headers?.get?.("content-length");
  if (typeof rawLength === "string" && rawLength.trim() !== "") {
    if (!/^\d+$/.test(rawLength.trim())) {
      response.body?.cancel?.().catch?.(() => {});
      return { status: BrowserCacheStatus.Transport_Error, bytes: null };
    }
    const declared = Number(rawLength.trim());
    if (!Number.isSafeInteger(declared) || declared > expectedBytes) {
      response.body?.cancel?.().catch?.(() => {});
      return { status: BrowserCacheStatus.Too_Large, bytes: null };
    }
    if (declared < expectedBytes) {
      response.body?.cancel?.().catch?.(() => {});
      return { status: BrowserCacheStatus.Transport_Error, bytes: null };
    }
  }
  const out = new Uint8Array(expectedBytes);
  let offset = 0;
  try {
    if (response.body && typeof response.body.getReader === "function") {
      const reader = response.body.getReader();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        if (offset + value.byteLength > expectedBytes) {
          reader.cancel().catch(() => {});
          return { status: BrowserCacheStatus.Too_Large, bytes: null };
        }
        out.set(value, offset);
        offset += value.byteLength;
      }
    } else {
      const raw = new Uint8Array(await response.arrayBuffer());
      if (raw.byteLength > expectedBytes) return { status: BrowserCacheStatus.Too_Large, bytes: null };
      out.set(raw, 0);
      offset = raw.byteLength;
    }
  } catch {
    return { status: BrowserCacheStatus.Transport_Error, bytes: null };
  }
  if (offset !== expectedBytes) return { status: BrowserCacheStatus.Transport_Error, bytes: null };
  return { status: BrowserCacheStatus.Ok, bytes: out };
}

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
  // outboardUrlOf gives the address of the Bao outboard of a multi-frame blob,
  // or "" for a request that names no blob.
  outboardUrlOf(hash) {
    if (!this.configured || typeof hash !== "string" || !BROWSER_CACHE_HASH.test(hash) || hash === BROWSER_CACHE_ZERO_HASH) return "";
    return this.baseUrl + BROWSER_CACHE_OUTBOARD_PREFIX + hash;
  }
  // fetchOutboardParent fetches one 64-byte parent entry at parentIndex from
  // /outboards/<hash> using HTTP Range so even large outboards never buffer
  // whole in memory.
  async fetchOutboardParent(hash, parentIndex, outboardBytes) {
    const url = this.outboardUrlOf(hash);
    if (!url || !Number.isSafeInteger(parentIndex) || parentIndex < 0 || !Number.isSafeInteger(outboardBytes) || outboardBytes < OBJECT_OUTBOARD_ENTRY_SIZE) {
      return { status: BrowserCacheStatus.Invalid_Request, entry: null };
    }
    const start = parentIndex * OBJECT_OUTBOARD_ENTRY_SIZE;
    const end = start + OBJECT_OUTBOARD_ENTRY_SIZE - 1;
    if (end >= outboardBytes) return { status: BrowserCacheStatus.Invalid_Request, entry: null };
    let response;
    try {
      response = await this.fetchProcedure(url, {
        method: "GET",
        mode: "cors",
        credentials: "omit",
        redirect: "error",
        referrerPolicy: "no-referrer",
        headers: { Range: "bytes=" + start + "-" + end },
      });
    } catch {
      return { status: BrowserCacheStatus.Transport_Error, entry: null };
    }
    if (response.status === 404) return { status: BrowserCacheStatus.Absent, entry: null };
    if (response.status === 416) return { status: BrowserCacheStatus.Invalid_Request, entry: null };
    if (response.status === 206) {
      const range = parseContentRange(response.headers?.get?.("content-range"));
      if (!range || range.start !== start || range.end !== end || range.total !== outboardBytes) {
        response.body?.cancel?.().catch?.(() => {});
        return { status: BrowserCacheStatus.Invalid_Request, entry: null };
      }
    } else if (!(response.status === 200 && outboardBytes === OBJECT_OUTBOARD_ENTRY_SIZE && start === 0)) {
      response.body?.cancel?.().catch?.(() => {});
      return { status: response.status === 200 ? BrowserCacheStatus.Too_Large : BrowserCacheStatus.Transport_Error, entry: null };
    }
    const body = await readResponseExact(response, OBJECT_OUTBOARD_ENTRY_SIZE);
    if (body.status !== BrowserCacheStatus.Ok) return { status: body.status, entry: null };
    return { status: BrowserCacheStatus.Ok, entry: body.bytes };
  }
  // fetchFrameProof gathers the <= 32 sibling chaining values along the Bao
  // path of frameIndex from /outboards/<hash>.
  async fetchFrameProof(hash, objectSize, frameIndex, frameBytes = OBJECT_FRAME_PAYLOAD_BYTES) {
    const frameCount = objectFrameCount(objectSize, frameBytes);
    const path = objectFramePath(frameCount, frameIndex);
    if (!path) return { status: BrowserCacheStatus.Invalid_Request, proof: null };
    if (path.depth === 0) return { status: BrowserCacheStatus.Ok, proof: new Uint8Array(0) };
    const outboardBytes = (frameCount - 1) * OBJECT_OUTBOARD_ENTRY_SIZE;
    const proof = new Uint8Array(path.depth * OBJECT_PROOF_ENTRY_SIZE);
    for (let level = 0; level < path.depth; level += 1) {
      const result = await this.fetchOutboardParent(hash, path.parentIndex[level], outboardBytes);
      if (result.status !== BrowserCacheStatus.Ok) return { status: result.status, proof: null };
      const sibling = path.inLeft[level]
        ? result.entry.subarray(BLAKE3_HASH_SIZE, OBJECT_OUTBOARD_ENTRY_SIZE)
        : result.entry.subarray(0, BLAKE3_HASH_SIZE);
      proof.set(sibling, level * OBJECT_PROOF_ENTRY_SIZE);
    }
    return { status: BrowserCacheStatus.Ok, proof };
  }
  // fetchBlobFrame fetches one aligned 1 MiB frame of a blob of any size
  // (including past BROWSER_CACHE_OBJECT_LIMIT = 16 MiB) using HTTP Range and
  // verifies it against hash with its Bao proof before returning the bytes.
  // Never buffers more than one frame (<= frameBytes) in memory.
  async fetchBlobFrame(hash, { objectSize, frameIndex, proof = null, frameBytes = OBJECT_FRAME_PAYLOAD_BYTES } = {}) {
    if (!this.configured) return { status: BrowserCacheStatus.Not_Configured, bytes: null };
    const url = this.urlOf(BrowserCacheObjectKind.Blob, hash);
    if (!url || !validFrameBytes(frameBytes) || frameBytes > OBJECT_FRAME_PAYLOAD_BYTES) {
      return { status: BrowserCacheStatus.Invalid_Request, bytes: null };
    }
    const frameCount = objectFrameCount(objectSize, frameBytes);
    const length = objectFrameLength(objectSize, frameIndex, frameBytes);
    if (frameCount === 0 || length < 0) return { status: BrowserCacheStatus.Invalid_Request, bytes: null };
    const start = frameIndex * frameBytes;
    const headers = length > 0 ? { Range: "bytes=" + start + "-" + (start + length - 1) } : {};
    let response;
    try {
      response = await this.fetchProcedure(url, {
        method: "GET",
        mode: "cors",
        credentials: "omit",
        redirect: "error",
        referrerPolicy: "no-referrer",
        headers,
      });
    } catch {
      return { status: BrowserCacheStatus.Transport_Error, bytes: null };
    }
    if (response.status === 404) return { status: BrowserCacheStatus.Absent, bytes: null };
    if (response.status === 416) return { status: BrowserCacheStatus.Invalid_Request, bytes: null };
    if (length === 0) {
      if (response.status !== 200) {
        response.body?.cancel?.().catch?.(() => {});
        return { status: BrowserCacheStatus.Transport_Error, bytes: null };
      }
    } else if (response.status === 206) {
      const range = parseContentRange(response.headers?.get?.("content-range"));
      if (!range || range.start !== start || range.end !== start + length - 1 || range.total !== objectSize) {
        response.body?.cancel?.().catch?.(() => {});
        return { status: BrowserCacheStatus.Invalid_Request, bytes: null };
      }
    } else if (response.status === 200) {
      // Refuse 200 OK on multi-frame blobs so a server ignoring Range cannot
      // force buffering a blob past one frame / past 16 MiB.
      if (frameCount > 1) {
        response.body?.cancel?.().catch?.(() => {});
        return { status: BrowserCacheStatus.Too_Large, bytes: null };
      }
    } else {
      response.body?.cancel?.().catch?.(() => {});
      return { status: BrowserCacheStatus.Transport_Error, bytes: null };
    }
    const body = await readResponseExact(response, length);
    if (body.status !== BrowserCacheStatus.Ok) return { status: body.status, bytes: null };

    let frameProof = proof;
    if (frameCount === 1) {
      if (frameProof === null) frameProof = new Uint8Array(0);
    } else if (frameProof === null) {
      const headerProof = response.headers?.get?.("x-modus-frame-proof");
      if (typeof headerProof === "string") {
        const trimmedProof = headerProof.trim();
        if (trimmedProof.length > OBJECT_MAX_PROOF_DEPTH * OBJECT_PROOF_ENTRY_SIZE * 2) {
          return { status: BrowserCacheStatus.Invalid_Request, bytes: null };
        }
        frameProof = parseHexBytes(trimmedProof);
        if (!frameProof) return { status: BrowserCacheStatus.Invalid_Request, bytes: null };
      } else {
        const fetched = await this.fetchFrameProof(hash, objectSize, frameIndex, frameBytes);
        if (fetched.status !== BrowserCacheStatus.Ok) return { status: fetched.status, bytes: null };
        frameProof = fetched.proof;
      }
    }
    const verified = objectFrameVerify({ expectedHash: hash, objectSize, frameIndex, proof: frameProof, frame: body.bytes, frameBytes });
    if (verified !== BrowserCacheStatus.Ok) return { status: verified, bytes: null };
    return { status: BrowserCacheStatus.Ok, bytes: body.bytes, frameIndex, frameCount, objectSize, offset: start };
  }
  // streamBlob streams a blob of any size one verified 1 MiB frame at a time
  // into onFrame(bytes, info). Never holds more than one frame in JS memory.
  async streamBlob(hash, { objectSize = null, frameBytes = OBJECT_FRAME_PAYLOAD_BYTES, onFrame, proofForFrame = null } = {}) {
    if (!this.configured) return { status: BrowserCacheStatus.Not_Configured, totalBytes: 0, frameCount: 0 };
    if (typeof onFrame !== "function" || !validFrameBytes(frameBytes) || frameBytes > OBJECT_FRAME_PAYLOAD_BYTES) {
      return { status: BrowserCacheStatus.Invalid_Request, totalBytes: 0, frameCount: 0 };
    }
    const url = this.urlOf(BrowserCacheObjectKind.Blob, hash);
    if (!url) return { status: BrowserCacheStatus.Invalid_Request, totalBytes: 0, frameCount: 0 };
    let size = objectSize;
    if (size === null) {
      let head;
      try {
        head = await this.fetchProcedure(url, { method: "HEAD", mode: "cors", credentials: "omit", redirect: "error", referrerPolicy: "no-referrer" });
      } catch {
        return { status: BrowserCacheStatus.Transport_Error, totalBytes: 0, frameCount: 0 };
      }
      if (head.status === 404) return { status: BrowserCacheStatus.Absent, totalBytes: 0, frameCount: 0 };
      if (!head.ok) return { status: BrowserCacheStatus.Transport_Error, totalBytes: 0, frameCount: 0 };
      const rawHeadLength = head.headers?.get?.("content-length");
      if (typeof rawHeadLength !== "string" || !/^\d+$/.test(rawHeadLength.trim())) {
        return { status: BrowserCacheStatus.Invalid_Request, totalBytes: 0, frameCount: 0 };
      }
      const parsed = Number(rawHeadLength.trim());
      if (!Number.isSafeInteger(parsed) || parsed < 0) return { status: BrowserCacheStatus.Invalid_Request, totalBytes: 0, frameCount: 0 };
      size = parsed;
    }
    const frameCount = objectFrameCount(size, frameBytes);
    if (frameCount === 0) return { status: BrowserCacheStatus.Invalid_Request, totalBytes: 0, frameCount: 0 };
    let totalBytes = 0;
    for (let frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
      const explicitProof = typeof proofForFrame === "function" ? await proofForFrame(frameIndex) : null;
      const frame = await this.fetchBlobFrame(hash, { objectSize: size, frameIndex, proof: explicitProof, frameBytes });
      if (frame.status !== BrowserCacheStatus.Ok) {
        return { status: frame.status, failedFrame: frameIndex, totalBytes, frameCount, objectSize: size };
      }
      await onFrame(frame.bytes, { frameIndex, frameCount, offset: frame.offset, objectSize: size });
      totalBytes += frame.bytes.byteLength;
    }
    return { status: BrowserCacheStatus.Ok, totalBytes, frameCount, objectSize: size };
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
  image_check: "the root service checks the boot image",
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
  "root::Image_Checked_At_Load": "671a58",
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
    // The end of the check of the root service at its start, in each form
    // of the check (boot_info.File_Check).
    if (named("root::Boot_Image_Agrees") || named("root::Image_Checked_At_Load")) this.enter(BootStage.Services);
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

// DomTerminalAccumulator assembles logical output lines from the JSON records
// written by dom_terminal on COM2 (src/md/features/console_renderers.md,
// "Variant C: dom_terminal"): styled runs of one line arrive as separate
// {"t":"out","s":"..."} records until {"nl":true} terminates the line.
export class DomTerminalAccumulator {
  constructor() {
    this.lines = [];
    this.current = "";
    this.ready = false;
  }
  clear() {
    this.lines = [];
    this.current = "";
  }
  feed(line) {
    if (typeof line !== "string") return false;
    let record;
    try { record = JSON.parse(line); } catch { return false; }
    if (!record || typeof record !== "object" || typeof record.t !== "string") return false;
    switch (record.t) {
      case "clr":
        this.clear();
        return true;
      case "edit":
        this.ready = true;
        return true;
      case "out":
        if (typeof record.s === "string") this.current += record.s;
        if (record.nl === true) {
          this.lines.push(this.current);
          this.current = "";
        }
        return true;
      default:
        return false;
    }
  }
  hasLineContaining(needle) {
    return this.lastMatchingLine(needle) !== "";
  }
  lastMatchingLine(needle) {
    if (typeof needle !== "string" || needle.length === 0) return "";
    if (this.current.includes(needle)) return this.current;
    for (let i = this.lines.length - 1; i >= 0; i -= 1) {
      if (this.lines[i].includes(needle)) return this.lines[i];
    }
    return "";
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
    this.desktopWidth = 0;
    this.desktopHeight = 0;
    this.requestedWidth = framebufferWidth;
    this.requestedHeight = framebufferHeight;
    this.resizeSeq = 0;
    this.resizeAckSeq = 0;
    this.lastFrameSeq = 0;
    this.lastIdleBound = 0n;
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
        page_processor_loop_unwind: () => { throw UNWIND_SIGNAL; },
        page_processor_stop: () => { throw STOP_SIGNAL; },
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
    else if (port === Port.DebugExit) { this.stopCode = value; throw STOP_SIGNAL; }
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
      if (error instanceof ProcessorIdle) {
        this.instance.exports.__stack_pointer.value = this.stackTop;
        this.lastIdleBound = error.boundNanoseconds;
        return LoopResult.Idle;
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

  // requestResize publishes new viewport dimensions into the trailing MODVRES1
  // control page and nudges PS/2 input so the compositor wakes immediately.
  requestResize(width, height) {
    if (!this.memory || !this.layout || !this.layout.framebufferResizeControl) return false;
    const clampedW = Math.max(BROWSER_RESIZE_MIN_WIDTH, Math.min(BROWSER_RESIZE_MAX_WIDTH, Math.floor(Number(width) || 0) & ~1));
    const clampedH = Math.max(BROWSER_RESIZE_MIN_HEIGHT, Math.min(BROWSER_RESIZE_MAX_HEIGHT, Math.floor(Number(height) || 0) & ~1));
    if (clampedW === this.requestedWidth && clampedH === this.requestedHeight) return false;
    this.requestedWidth = clampedW;
    this.requestedHeight = clampedH;
    const view = new DataView(this.memory.buffer);
    const base = this.layout.framebufferResizeControl;
    this.resizeSeq = (this.resizeSeq + 1) >>> 0;
    if (this.resizeSeq === 0) this.resizeSeq = 1;
    view.setUint32(base + BROWSER_RESIZE_OFFSETS.req_width, clampedW, true);
    view.setUint32(base + BROWSER_RESIZE_OFFSETS.req_height, clampedH, true);
    view.setUint32(base + BROWSER_RESIZE_OFFSETS.req_seq, this.resizeSeq, true);
    // Wake input -> compositor immediately while preserving any held buttons.
    this.keyboard.pointer(0, 0, this.keyboard.mouseButtons);
    return true;
  }

  // syncFramebufferSize updates active dimensions once the compositor has
  // repainted screen.pixels and published ack_seq with .Release.
  syncFramebufferSize() {
    if (!this.memory || !this.layout || !this.layout.framebufferResizeControl) return false;
    const view = new DataView(this.memory.buffer);
    const base = this.layout.framebufferResizeControl;
    const ackSeq = view.getUint32(base + BROWSER_RESIZE_OFFSETS.ack_seq, true);
    if (ackSeq === this.resizeAckSeq) return false;
    const ackW = view.getUint32(base + BROWSER_RESIZE_OFFSETS.ack_width, true);
    const ackH = view.getUint32(base + BROWSER_RESIZE_OFFSETS.ack_height, true);
    this.resizeAckSeq = ackSeq;
    if (
      ackW >= BROWSER_RESIZE_MIN_WIDTH &&
      ackW <= BROWSER_RESIZE_MAX_WIDTH &&
      ackH >= BROWSER_RESIZE_MIN_HEIGHT &&
      ackH <= BROWSER_RESIZE_MAX_HEIGHT &&
      (ackW !== this.framebufferWidth || ackH !== this.framebufferHeight)
    ) {
      this.framebufferWidth = ackW;
      this.framebufferHeight = ackH;
      return true;
    }
    return false;
  }

  // readFramePatch returns { unchanged: true } in O(1) when frame_seq has not
  // advanced, or converts only the damaged rectangle (BGRA -> RGBA) into a
  // transferable ArrayBuffer so the browser UI thread never loops over pixels.
  readFramePatch() {
    if (!this.memory || !this.framebufferWidth || !this.framebufferHeight) return null;
    const resized = this.syncFramebufferSize();
    const width = this.framebufferWidth;
    const height = this.framebufferHeight;
    let x = 0;
    let y = 0;
    let w = width;
    let h = height;
    if (this.layout && this.layout.framebufferResizeControl) {
      const view = new DataView(this.memory.buffer);
      const base = this.layout.framebufferResizeControl;
      const frameSeq = view.getUint32(base + BROWSER_RESIZE_OFFSETS.frame_seq, true);
      if (!resized && frameSeq !== 0 && frameSeq === this.lastFrameSeq) {
        return { unchanged: true };
      }
      const dwLogical = view.getUint32(base + BROWSER_RESIZE_OFFSETS.desktop_width, true);
      const dhLogical = view.getUint32(base + BROWSER_RESIZE_OFFSETS.desktop_height, true);
      if (dwLogical > 0 && dwLogical <= width && dhLogical > 0 && dhLogical <= height) {
        this.desktopWidth = dwLogical;
        this.desktopHeight = dhLogical;
      }
      const nextExpected = ((this.lastFrameSeq + 1) >>> 0) || 1;
      if (!resized && this.lastFrameSeq !== 0 && frameSeq === nextExpected) {
        const dx = view.getUint32(base + BROWSER_RESIZE_OFFSETS.dirty_x, true);
        const dy = view.getUint32(base + BROWSER_RESIZE_OFFSETS.dirty_y, true);
        const dw = view.getUint32(base + BROWSER_RESIZE_OFFSETS.dirty_w, true);
        const dh = view.getUint32(base + BROWSER_RESIZE_OFFSETS.dirty_h, true);
        if (dw > 0 && dh > 0 && dx + dw <= width && dy + dh <= height) {
          x = dx;
          y = dy;
          w = dw;
          h = dh;
        }
      }
      this.lastFrameSeq = frameSeq;
    }
    const rgba32 = new Uint32Array(w * h);
    const src32 = new Uint32Array(this.memory.buffer, this.layout.framebuffer, width * height);
    let dst = 0;
    for (let row = 0; row < h; row += 1) {
      let src = (y + row) * width + x;
      const end = src + w;
      for (; src < end; src += 1) {
        const pixel = src32[src];
        rgba32[dst++] = 0xff000000 | ((pixel & 0xff) << 16) | (pixel & 0x00ff00) | ((pixel >> 16) & 0xff);
      }
    }
    const desktopWidth = this.desktopWidth > 0 ? this.desktopWidth : width;
    const desktopHeight = this.desktopHeight > 0 ? this.desktopHeight : height;
    return { unchanged: false, rgba: rgba32.buffer, x, y, w, h, width, height, desktopWidth, desktopHeight };
  }

  // The pixels of the framebuffer, blue first: a view of the memory.
  framebufferPixels() {
    if (!this.memory || !this.framebufferWidth) return null;
    return new Uint8Array(this.memory.buffer, this.layout.framebuffer, this.framebufferWidth * this.framebufferHeight * 4);
  }
}
