// The tests of the stage tracker of the host (browser_machine.md, "The boot
// stages of the page"). `modustool browser-machine boot` runs them in Node
// before the machine; the path of the host is the first argument. Each
// failure names its case, and the exit code is 1.
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
const host = await import(pathToFileURL(resolve(process.argv[1])).href);
const failures = [];
const expect = (condition, text) => { if (!condition) failures.push(text); };
const tag = (name) => host.BOOT_STAGE_FACT_TAGS[name];
const hex = (text) => Array.from(new TextEncoder().encode(text), (byte) => byte.toString(16).padStart(2, "0")).join("");
const tracker = (desktop) => {
  const seen = [];
  const value = new host.BootStageTracker({ desktop, onStage: (stage) => seen.push(stage) });
  value.enter(host.BootStage.Kernel);
  return { value, seen };
};

// Lines that are not the line of a fact: no stage.
{
  const { value, seen } = tracker(true);
  for (const line of [
    "[root] #3d2ffd19:" + tag("root::Boot_Image_Agrees") + "x", // A key tag of 7 characters: no space before the values.
    "[root] #3d2ffd1:" + tag("root::Boot_Image_Agrees"), // A module tag of 7 digits.
    "[root] #3d2ffd19:" + tag("root::Boot_Image_Agrees").slice(0, 5), // A key tag of 5 digits.
    "root #3d2ffd19:" + tag("root::Boot_Image_Agrees"), // No process in brackets.
    " [root] #3d2ffd19:" + tag("root::Boot_Image_Agrees"), // A space before.
    "[Root] #3d2ffd19:" + tag("root::Boot_Image_Agrees"), // A process name that is not lower case.
    "[root] #3D2FFD19:" + tag("root::Boot_Image_Agrees"), // Upper case digits.
    "[root] root: the boot image agrees", // The rendered sentence, which the serial line never holds.
  ]) value.serialLine(line);
  expect(seen.length === 1, "a line that is not a fact line changed the stage: " + seen.join(","));
}

// The tag of a fact of another process: no stage.
{
  const { value, seen } = tracker(true);
  value.serialLine("[compositor] #3d2ffd19:" + tag("root::Boot_Image_Agrees"));
  value.serialLine("[root] #3d2ffd19:" + tag("compositor::First_Frame"));
  expect(seen.length === 1, "the tag of a fact of another process changed the stage: " + seen.join(","));
}

// The start of another process than the compositor, a name that begins
// with "compositor", and the console on the desktop: no stage.
{
  const { value, seen } = tracker(true);
  value.serialLine(host.ROOT_SERVICE_STAGE_LINE + "1 us");
  value.serialLine("[root] #3d2ffd19:" + tag("root::Boot_Image_Agrees") + " 10");
  value.serialLine("[root] #3d2ffd19:" + tag("root::Process_Started") + " " + hex("console"));
  value.serialLine("[root] #3d2ffd19:" + tag("root::Process_Started") + " " + hex("compositor2"));
  value.serialLine("[root] #3d2ffd19:" + tag("root::Process_Started_With_Terminal") + " " + hex("console"));
  expect(seen.join(",") === "kernel,image_check,services", "a start that is not the compositor changed the stage: " + seen.join(","));
}

// A stage comes once, in order: a line of an earlier stage, a second line
// of the same stage, and a start again (the rescue start policy) change
// nothing.
{
  const { value, seen } = tracker(true);
  value.serialLine(host.ROOT_SERVICE_STAGE_LINE + "1 us");
  value.serialLine(host.ROOT_SERVICE_STAGE_LINE + "1 us");
  value.serialLine("[root] #3d2ffd19:" + tag("root::Boot_Image_Agrees") + " 10");
  value.serialLine("[root] #3d2ffd19:" + tag("root::Process_Started") + " " + hex("compositor"));
  value.serialLine(host.ROOT_SERVICE_STAGE_LINE + "1 us");
  value.serialLine("[root] #3d2ffd19:" + tag("root::Process_Started") + " " + hex("compositor"));
  value.serialLine("[compositor] #22af003a:" + tag("compositor::First_Frame"));
  value.serialLine("[compositor] #22af003a:" + tag("compositor::First_Frame"));
  expect(seen.join(",") === "kernel,image_check,services,desktop,ready", "the stages of a desktop: " + seen.join(","));
}

// The console: its start, then the first line of its prompt on COM2.
{
  const { value, seen } = tracker(false);
  value.serialLine(host.ROOT_SERVICE_STAGE_LINE + "1 us");
  value.serialLine("[root] #3d2ffd19:" + tag("root::Boot_Image_Agrees") + " 10");
  value.serialLine("[compositor] #22af003a:" + tag("compositor::First_Frame"));
  value.serialLine("[root] #3d2ffd19:" + tag("root::Process_Started") + " " + hex("console"));
  value.consoleLine('{"t":"clr"}');
  expect(seen.join(",") === "kernel,image_check,services", "the console before its start: " + seen.join(","));
  value.serialLine("[root] #3d2ffd19:" + tag("root::Process_Started_With_Terminal") + " " + hex("console"));
  value.consoleLine('{"t":"edit","text":"> "}');
  value.consoleLine('{"t":"edit","text":"> "}');
  expect(seen.join(",") === "kernel,image_check,services,console,ready", "the stages of a console: " + seen.join(","));
}

// Each form of the check of the root service ends the stage of the check.
for (const name of ["root::Image_Checked_At_Start", "root::Image_Checked_At_Load"]) {
  const { value, seen } = tracker(false);
  value.serialLine(host.ROOT_SERVICE_STAGE_LINE + "1 us");
  value.serialLine("[root] #3d2ffd19:" + tag(name) + " 10");
  expect(seen.join(",") === "kernel,image_check,services", "the end of the check by " + name + ": " + seen.join(","));
}

// A line of a later stage moves past the stages before it, once.
{
  const { value, seen } = tracker(true);
  value.serialLine("[compositor] #22af003a:" + tag("compositor::First_Frame"));
  value.serialLine("[root] #3d2ffd19:" + tag("root::Boot_Image_Agrees") + " 10");
  expect(seen.join(",") === "kernel,ready", "a later stage first: " + seen.join(","));
}

if (failures.length) {
  for (const failure of failures) console.log("failed: " + failure);
  process.exit(1);
}
console.log("passed: 8 cases of the stage tracker");
