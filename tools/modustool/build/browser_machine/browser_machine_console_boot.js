// Node boot test for the console image on COM2 (src/md/features/console_renderers.md,
// "The console image"): boots console.image on modulus_kernel.wasm with no
// framebuffer, waits for dom_terminal readiness on COM2 under the hang bound,
// types a Lex command on COM2, verifies the exact answer in the COM2 JSON
// updates, and exits 0 on success or 1 on timeout, trap, or missing answer.
//
// Arguments:
//   hostPath kernelPath imagePath boundMilliseconds command expectedAnswer [trustHashHex]
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const [hostPath, kernelPath, imagePath, boundText, command, expectedAnswer, trustHashHex = ""] = process.argv.slice(1);
if (!hostPath || !kernelPath || !imagePath || !boundText || !command || !expectedAnswer) {
  console.error("console-boot requires hostPath, kernelPath, imagePath, boundMilliseconds, command, and expectedAnswer");
  process.exit(1);
}
const boundMilliseconds = Number(boundText);
if (!Number.isFinite(boundMilliseconds) || boundMilliseconds <= 0) {
  console.error("console-boot refused invalid hang bound: " + boundText);
  process.exit(1);
}

const host = await import(pathToFileURL(resolve(hostPath)).href);
const kernelModule = await WebAssembly.compile(readFileSync(kernelPath));
const bootImage = new Uint8Array(readFileSync(imagePath));
const trustDescriptionHash = host.trustDescriptionHashParse(trustHashHex);
const idleWord = new Int32Array(new SharedArrayBuffer(4));

const started = Date.now();
const end = started + boundMilliseconds;
const collector = new host.DomTerminalAccumulator();
let typed = false;
let answered = false;
let matchedLine = "";

const tracker = new host.BootStageTracker({
  desktop: false,
  onStage: (stage) => console.log("stage: " + stage + " at " + ((Date.now() - started) / 1000).toFixed(1) + " s"),
});
tracker.enter(host.BootStage.Kernel);

const machine = new host.BrowserMachine({
  kernelModule,
  bootImage,
  trustDescriptionHash,
  memoryMebibytes: 512,
  framebufferWidth: 0,
  framebufferHeight: 0,
  clockNanoseconds: () => process.hrtime.bigint(),
  idleWait: (bound) => {
    const remaining = end - Date.now();
    if (remaining <= 0) throw new host.ProcessorStop();
    Atomics.wait(idleWord, 0, 0, Math.min(Number(bound) / 1e6, remaining, 5));
  },
  onSerialLine: (line) => {
    console.log("serial: " + line);
    tracker.serialLine(line);
  },
  onConsoleLine: (line) => {
    console.log("console: " + line);
    tracker.consoleLine(line);
    collector.feed(line);
    if (typed && !answered && collector.hasLineContaining(expectedAnswer)) {
      answered = true;
      matchedLine = collector.lastMatchingLine(expectedAnswer);
    }
  },
});

await machine.start();
while (machine.state === host.MachineState.Running && Date.now() < end && !answered) {
  if (tracker.stage === host.BootStage.Ready && !typed) {
    typed = true;
    // Reset any banner text collected before the prompt so the match comes from
    // the typed command's output.
    collector.clear();
    machine.consolePort.type(command + "\r");
    console.log("typed: " + command + " at " + ((Date.now() - started) / 1000).toFixed(1) + " s");
  }
  if (machine.runSlice(10000000) === host.LoopResult.Idle) {
    Atomics.wait(idleWord, 0, 0, 1);
  }
}

if (answered) {
  console.log("answered: at " + ((Date.now() - started) / 1000).toFixed(1) + " s");
  console.log("answer: " + matchedLine);
}
const trap = machine.trap ? String(machine.trap).replace(/\s+/g, " ") : "";
console.log("machine: " + machine.state + " " + machine.stopCode + " " + trap);

if (machine.state === host.MachineState.Trapped) {
  console.error("console-boot ended with a WebAssembly trap: " + trap);
  process.exit(1);
}
if (!typed) {
  console.error("console-boot reached the hang bound before dom_terminal became ready on COM2");
  process.exit(1);
}
if (!answered) {
  console.error("console-boot did not observe expected COM2 answer " + JSON.stringify(expectedAnswer) + " for " + JSON.stringify(command));
  process.exit(1);
}
process.exit(0);
