// Embedded interactive browser-machine console widgets for site guide pages
// (src/md/features/agent_code_mode.md and src/md/features/browser_machine.md).
//
// Detects runnable Lex console snippets in guide pages, wraps their static
// highlighted <pre><code> block with progressive-enhancement controls (an
// "Open Web Console" fallback link and a script-revealed "Run in browser
// console" toggle), and serves a zero-dependency script (`guide_console.js`)
// that boots the site's existing `browser_machine_worker.js` + `console.image`
// + `modulus_kernel.wasm` lazily on demand and renders COM2 dom_terminal JSON
// updates inline with full keyboard access.
package site

import "core:strings"
import "modustool:build"
import "modustool:foundation"

// Format property: external script file written beside style.css at site root.
SITE_GUIDE_CONSOLE_SCRIPT :: "guide_console.js"

// Plan value: maximum runnable console lines embedded in one guide widget,
// matching AGENT_STEP_LINE_CAPACITY so snippets stay bounded.
SITE_GUIDE_CONSOLE_LINE_LIMIT :: 16

// Plan value: maximum total bytes of embedded command text per guide widget.
SITE_GUIDE_CONSOLE_BYTE_LIMIT :: 4096

// site_guide_console_strip_comment strips a trailing "// ..." Lex line comment
// outside double-quoted string literals.
@(private = "file")
site_guide_console_strip_comment :: proc(line: string) -> string {
	in_string := false
	escaped := false
	for i := 0; i < len(line); i += 1 {
		c := line[i]
		if in_string {
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				in_string = false
			}
			continue
		}
		if c == '"' {
			in_string = true
			continue
		}
		if c == '/' && i + 1 < len(line) && line[i + 1] == '/' {
			return strings.trim_space(line[:i])
		}
	}
	return strings.trim_space(line)
}

// site_guide_console_line_has_placeholder reports whether a Lex command line
// contains illustrative placeholder syntax (`...` or `<placeholder>`) outside
// double-quoted string literals, or unbalanced brackets/quotes indicating a
// multi-line declarative block rather than a single console line.
@(private = "file")
site_guide_console_line_is_single_command :: proc(line: string) -> bool {
	trimmed := strings.trim_space(line)
	if trimmed == "" {
		return false
	}
	// Multi-line declarative blocks and bare `let` headers are file forms, not
	// single console lines.
	if trimmed == "let" || trimmed == "{" || trimmed == "}" ||
	   strings.has_prefix(trimmed, "plan {") || strings.has_prefix(trimmed, "project {") || strings.has_prefix(trimmed, "recipe {") {
		return false
	}
	in_string := false
	escaped := false
	parens, brackets, braces := 0, 0, 0
	for i := 0; i < len(trimmed); i += 1 {
		c := trimmed[i]
		if in_string {
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				in_string = false
			}
			continue
		}
		switch c {
		case '"':
			in_string = true
		case '(':
			parens += 1
		case ')':
			parens -= 1
			if parens < 0 {
				return false
			}
		case '[':
			brackets += 1
		case ']':
			brackets -= 1
			if brackets < 0 {
				return false
			}
		case '{':
			braces += 1
		case '}':
			braces -= 1
			if braces < 0 {
				return false
			}
		case '.':
			if i + 2 < len(trimmed) && trimmed[i + 1] == '.' && trimmed[i + 2] == '.' {
				return false
			}
		case '<':
			// Placeholder syntax `<name>` or `<64-hex-seed>` (letter or digit directly after `<` followed by `>`).
			if i + 2 < len(trimmed) && ((trimmed[i + 1] >= 'a' && trimmed[i + 1] <= 'z') || (trimmed[i + 1] >= 'A' && trimmed[i + 1] <= 'Z') || (trimmed[i + 1] >= '0' && trimmed[i + 1] <= '9')) {
				for j := i + 2; j < len(trimmed); j += 1 {
					if trimmed[j] == '>' {
						return false
					}
					if trimmed[j] == ' ' || trimmed[j] == '\t' || trimmed[j] == '(' || trimmed[j] == ')' {
						break
					}
				}
			}
		}
	}
	return !in_string && parens == 0 && brackets == 0 && braces == 0
}

// site_guide_console_lines extracts runnable Lex console command lines from a
// fenced `lex` block in a guide. Supports both direct command lists and console
// transcripts whose prompt lines begin with `> `. Returns nil for declarative
// multi-line file snippets, grammar illustrations, or empty blocks.
site_guide_console_lines :: proc(source: string) -> []string {
	if strings.trim_space(source) == "" {
		return nil
	}
	raw_lines := foundation.lines_of_text(source)
	out := make([dynamic]string, context.temp_allocator)
	total_bytes := 0

	if site_code_lex_is_transcript(source) {
		for raw in raw_lines {
			if !strings.has_prefix(raw, "> ") {
				continue
			}
			cmd := site_guide_console_strip_comment(raw[2:])
			if !site_guide_console_line_is_single_command(cmd) {
				continue
			}
			if len(out) >= SITE_GUIDE_CONSOLE_LINE_LIMIT || total_bytes + len(cmd) + 1 > SITE_GUIDE_CONSOLE_BYTE_LIMIT {
				break
			}
			append(&out, cmd)
			total_bytes += len(cmd) + 1
		}
		return out[:]
	}

	for raw in raw_lines {
		cmd := site_guide_console_strip_comment(raw)
		if cmd == "" {
			continue
		}
		// Any non-command line (such as a multi-line `project { ... }` block or
		// grammar illustration) disqualifies the entire block so partial broken
		// fragments are never sent to the console.
		if !site_guide_console_line_is_single_command(cmd) {
			return nil
		}
		if len(out) >= SITE_GUIDE_CONSOLE_LINE_LIMIT || total_bytes + len(cmd) + 1 > SITE_GUIDE_CONSOLE_BYTE_LIMIT {
			return nil
		}
		append(&out, cmd)
		total_bytes += len(cmd) + 1
	}
	return out[:]
}

// site_guide_console_escape_attr writes text safely inside a double-quoted HTML
// attribute, encoding HTML metacharacters and line breaks (`&#10;`, `&#13;`,
// `&#9;`) so the attribute stays single-line and decodes losslessly in DOM
// dataset reads.
site_guide_console_escape_attr :: proc(b: ^strings.Builder, text: string) {
	for i in 0 ..< len(text) {
		switch text[i] {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '"':
			strings.write_string(b, "&quot;")
		case '\'':
			strings.write_string(b, "&#39;")
		case '\n':
			strings.write_string(b, "&#10;")
		case '\r':
			strings.write_string(b, "&#13;")
		case '\t':
			strings.write_string(b, "&#9;")
		case:
			strings.write_byte(b, text[i])
		}
	}
}

// site_guide_console_widget_write emits the progressive-enhancement inline
// console widget wrapping a highlighted Lex `<pre><code>` block. With scripts
// disabled, the highlighted code and the "Open Web Console" link work cleanly;
// `guide_console.js` reveals the "Run in browser console" button and mounts the
// live browser-machine panel on demand.
site_guide_console_widget_write :: proc(renderer: ^Site_Renderer, b: ^strings.Builder, code_html: string, lines: []string) {
	if renderer == nil || b == nil || len(lines) == 0 {
		return
	}
	renderer.has_guide_console = true
	joined := strings.join(lines, "\n", context.temp_allocator)
	root := site_relative(renderer.page, "")
	console_href := site_page_link(renderer.site, renderer.page, build.BROWSER_MACHINE_CONSOLE_PAGE_FILE)

	strings.write_string(b, "<div class=\"guide-console\" data-console-lines=\"")
	site_guide_console_escape_attr(b, joined)
	strings.write_string(b, "\" data-console-root=\"")
	site_guide_console_escape_attr(b, root)
	strings.write_string(b, "\">\n<pre><code>")
	strings.write_string(b, code_html)
	strings.write_string(b, "</code></pre>\n<div class=\"guide-console-bar\">\n")
	strings.write_string(b, "<button type=\"button\" class=\"guide-console-run\" aria-expanded=\"false\" hidden>Run in browser console</button>\n")
	strings.write_string(b, "<a class=\"guide-console-open\" href=\"")
	foundation.html_escape(b, console_href)
	strings.write_string(b, "\">Open Web Console</a>\n</div>\n")
	strings.write_string(b, "<div class=\"guide-console-panel\" role=\"region\" aria-label=\"Interactive modus console\" hidden></div>\n</div>\n")
}

// site_guide_console_rules gives the style rules of the embedded guide console
// widgets using the site's design tokens, sharp square borders, and zero
// transitions or animations.
site_guide_console_rules :: proc() -> string {
	return `
/* Embedded interactive console widgets in guide pages. */
.guide-console { margin: 16px 0; border: 1px solid var(--track); background: var(--card-top); }
.guide-console > pre { margin: 0; border-bottom: 1px solid var(--track); }
.guide-console-bar { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; padding: 6px 12px; background: var(--card-bottom); }
.guide-console-bar button { display: inline-block; padding: 2px 10px; border: 1px solid var(--track); background: var(--track); color: var(--text); font-family: var(--reading); font-size: 13px; line-height: 22px; cursor: pointer; }
.guide-console-bar button[hidden] { display: none; }
.guide-console-bar button[aria-expanded="true"] { background: var(--control-active); color: var(--control-active-text); border-color: var(--line); }
.guide-console-bar a { display: inline-block; padding: 2px 10px; border: 1px solid var(--track); background: var(--track); color: var(--text); text-decoration: none; font-size: 13px; line-height: 22px; }
.guide-console-panel { border-top: 1px solid var(--track); background: var(--background); }
.guide-console-panel[hidden] { display: none; }
.guide-console-head { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px; padding: 6px 12px; background: var(--card-bottom); border-bottom: 1px solid var(--track); font-size: 13px; }
.guide-console-status { font-family: var(--mono); font-size: 12px; color: var(--dim); }
.guide-console-status.is-ready { color: var(--text); }
.guide-console-status.is-error { color: var(--text); border-left: 3px solid var(--match); padding-left: 6px; }
.guide-console-actions { display: flex; flex-wrap: wrap; gap: 6px; }
.guide-console-actions button { padding: 1px 8px; border: 1px solid var(--track); background: var(--track); color: var(--text); font-family: var(--reading); font-size: 12px; line-height: 20px; cursor: pointer; }
.guide-console-output { max-height: 260px; overflow: auto; padding: 8px 12px; font-family: var(--mono); font-size: 13px; line-height: 19px; color: var(--text); background: var(--background); }
.guide-console-line { white-space: pre-wrap; overflow-wrap: anywhere; min-height: 19px; }
.guide-console-line .t-dim { color: var(--dim); }
.guide-console-line .t-strong { font-weight: 700; }
.guide-console-line .t-bad { color: var(--match); }
.guide-console-form { display: flex; align-items: center; gap: 6px; padding: 6px 12px; border-top: 1px solid var(--track); background: var(--card-bottom); }
.guide-console-prompt { font-family: var(--mono); font-size: 13px; color: var(--dim); user-select: none; }
.guide-console-input { flex: 1 1 auto; min-width: 0; padding: 3px 8px; border: 1px solid var(--track); background: var(--background); color: var(--text); font-family: var(--mono); font-size: 13px; line-height: 20px; }
.guide-console-input::placeholder { color: var(--placeholder); }
.guide-console-form button { padding: 2px 10px; border: 1px solid var(--track); background: var(--track); color: var(--text); font-family: var(--reading); font-size: 13px; line-height: 20px; cursor: pointer; }
`
}

// site_guide_console_script gives the external browser script (`guide_console.js`)
// that upgrades `.guide-console` blocks on guide pages. It reuses the site's
// existing `browser_machine_worker.js`, `modulus_kernel.wasm`, and `console.image`
// with zero external dependencies, strict DOM textContent rendering (never
// innerHTML), lazy boot on demand, shared page-level console session, and full
// keyboard navigation (Enter to run, Up/Down history, Ctrl+L clear, Escape close).
site_guide_console_script :: proc() -> string {
	return `// Interactive inline consoles for modus guide pages.
// Reuses the site's browser_machine_worker.js, modulus_kernel.wasm, and
// console.image lazily on first click; zero external dependencies.
(function () {
  "use strict";
  var widgets = document.querySelectorAll(".guide-console[data-console-lines]");
  if (!widgets.length) {
    return;
  }

  var OUTPUT_LINE_LIMIT = 400;
  var LINE_SPAN_LIMIT = 128;
  var HISTORY_LIMIT = 64;
  var HEX_COLOR = /^#[0-9a-f]{6}$/;
  var TONES = { default: 1, dim: 1, strong: 1, good: 1, warning: 1, bad: 1, accent: 1, number: 1 };
  var CODE_KINDS = {
    function: 1, module: 1, type: 1, parameter: 1, variable: 1,
    number: 1, text: 1, text_unfinished: 1, operator: 1, arrow: 1, words: 1, unknown: 1
  };

  var sharedWorker = null;
  var workerRoot = "";
  var workerReady = false;
  var activeWidget = null;
  var pendingCommands = [];
  var statusText = "Idle";
  var statusKind = "";
  var allInstances = [];

  function setStatus(text, kind) {
    statusText = text;
    statusKind = kind || "";
    for (var i = 0; i < allInstances.length; i += 1) {
      allInstances[i].syncStatus(statusText, statusKind);
    }
  }

  function flushPending() {
    if (!sharedWorker || !workerReady || !pendingCommands.length) {
      return;
    }
    while (pendingCommands.length) {
      var line = pendingCommands.shift();
      sharedWorker.postMessage({ kind: "console_type", text: line + "\r" });
    }
  }

  function queueLines(instance, lines) {
    activeWidget = instance;
    for (var i = 0; i < lines.length; i += 1) {
      if (lines[i]) {
        pendingCommands.push(lines[i]);
      }
    }
    ensureWorker(instance.root);
    flushPending();
  }

  function stopWorker() {
    if (sharedWorker) {
      sharedWorker.terminate();
      sharedWorker = null;
    }
    workerReady = false;
    pendingCommands = [];
    setStatus("Stopped", "");
  }

  function ensureWorker(root) {
    if (sharedWorker) {
      return;
    }
    if (typeof Worker === "undefined" || typeof WebAssembly === "undefined") {
      setStatus("Web Worker or WebAssembly is unavailable in this browser. Open Web Console directly.", "is-error");
      return;
    }
    workerRoot = root || "";
    workerReady = false;
    setStatus("Starting browser console...", "");
    try {
      sharedWorker = new Worker(workerRoot + "browser_machine_worker.js", { type: "module" });
    } catch (err) {
      setStatus("Cannot start the console worker from this origin. Open Web Console on a served site.", "is-error");
      return;
    }
    sharedWorker.onmessage = function (event) {
      var msg = event.data;
      if (!msg || typeof msg !== "object") {
        return;
      }
      if (msg.kind === "stage") {
        if (msg.stage === "ready") {
          workerReady = true;
          setStatus("Console ready (console.image)", "is-ready");
          flushPending();
        } else if (typeof msg.sentence === "string" && msg.sentence) {
          var loaded = Number(msg.loaded) || 0;
          var total = Number(msg.total) || 0;
          var detail = msg.stage === "download" && loaded
            ? ": " + (loaded / 1048576).toFixed(1) + (total ? " of " + (total / 1048576).toFixed(1) : "") + " MiB"
            : "";
          setStatus(msg.sentence + detail, "");
        }
        return;
      }
      if (msg.kind === "console" && Array.isArray(msg.lines) && activeWidget) {
        activeWidget.receiveLines(msg.lines);
        return;
      }
      if (msg.kind === "state" && msg.state !== "running") {
        workerReady = false;
        var trap = typeof msg.trap === "string" && msg.trap ? msg.trap : "Console stopped";
        setStatus(trap, "is-error");
        if (activeWidget) {
          activeWidget.appendPlainLine(trap, "bad");
        }
      }
    };
    sharedWorker.onerror = function (event) {
      workerReady = false;
      var detail = event && event.message ? String(event.message) : "Console worker stopped.";
      setStatus(detail, "is-error");
      if (activeWidget) {
        activeWidget.appendPlainLine(detail, "bad");
      }
    };
    sharedWorker.postMessage({
      kind: "start",
      kernelUrl: "./modulus_kernel.wasm",
      bootImageUrl: "./console.image",
      memoryMebibytes: 512,
      width: 0,
      height: 0,
      cacheBaseUrl: ""
    });
  }

  function makeSpan(text, className, fg) {
    var node = document.createElement("span");
    node.textContent = text;
    if (className) {
      node.className = className;
    }
    if (fg && HEX_COLOR.test(fg)) {
      node.setAttribute("data-fg", fg);
    }
    return node;
  }

  function mountWidget(container) {
    var rawLines = container.getAttribute("data-console-lines") || "";
    var lines = rawLines.split("\n").filter(function (s) { return s.length > 0; });
    if (!lines.length) {
      return;
    }
    var root = container.getAttribute("data-console-root") || "";
    var runBtn = container.querySelector(".guide-console-run");
    var panel = container.querySelector(".guide-console-panel");
    if (!runBtn || !panel) {
      return;
    }
    runBtn.hidden = false;

    var built = false;
    var output = null;
    var statusEl = null;
    var inputEl = null;
    var openLine = null;
    var history = [];
    var historyPos = 0;

    function clearOutput() {
      if (output) {
        output.replaceChildren();
      }
      openLine = null;
    }

    function appendPlainLine(text, tone) {
      if (!output) {
        return;
      }
      var row = document.createElement("div");
      row.className = "guide-console-line";
      row.appendChild(makeSpan(text, tone ? "t-" + tone : "", ""));
      output.appendChild(row);
      while (output.childElementCount > OUTPUT_LINE_LIMIT) {
        output.firstElementChild.remove();
      }
      output.scrollTop = output.scrollHeight;
      openLine = null;
    }

    function renderRecord(record) {
      if (!output || !record || typeof record !== "object") {
        return;
      }
      if (record.t === "clr") {
        clearOutput();
        return;
      }
      if (record.t !== "out" || typeof record.s !== "string") {
        return;
      }
      if (!openLine || openLine.childElementCount >= LINE_SPAN_LIMIT) {
        openLine = document.createElement("div");
        openLine.className = "guide-console-line";
        output.appendChild(openLine);
        while (output.childElementCount > OUTPUT_LINE_LIMIT) {
          output.firstElementChild.remove();
        }
      }
      var classes = [];
      if (TONES[record.tone]) {
        classes.push("t-" + record.tone);
      }
      if (CODE_KINDS[record.code]) {
        classes.push("c-" + record.code);
      }
      openLine.appendChild(makeSpan(record.s, classes.join(" "), typeof record.fg === "string" ? record.fg : ""));
      if (record.nl === true) {
        openLine = null;
      }
    }

    function receiveLines(jsonLines) {
      if (!output) {
        return;
      }
      var atEnd = output.scrollHeight - output.scrollTop - output.clientHeight < 40;
      for (var i = 0; i < jsonLines.length; i += 1) {
        var raw = jsonLines[i];
        if (typeof raw !== "string") {
          continue;
        }
        try {
          renderRecord(JSON.parse(raw));
        } catch (err) {
          // Ignore malformed COM2 frames.
        }
      }
      if (atEnd) {
        output.scrollTop = output.scrollHeight;
      }
    }

    function syncStatus(text, kind) {
      if (!statusEl) {
        return;
      }
      statusEl.textContent = text;
      statusEl.className = "guide-console-status" + (kind ? " " + kind : "");
    }

    function closePanel() {
      panel.hidden = true;
      runBtn.setAttribute("aria-expanded", "false");
      runBtn.focus();
    }

    function buildPanel() {
      if (built) {
        return;
      }
      built = true;
      var head = document.createElement("div");
      head.className = "guide-console-head";
      statusEl = document.createElement("span");
      statusEl.className = "guide-console-status";
      statusEl.setAttribute("role", "status");
      statusEl.textContent = statusText;
      var actions = document.createElement("div");
      actions.className = "guide-console-actions";

      var rerunBtn = document.createElement("button");
      rerunBtn.type = "button";
      rerunBtn.textContent = "Run again";
      rerunBtn.addEventListener("click", function () {
        queueLines(instance, lines);
        if (inputEl) {
          inputEl.focus();
        }
      });

      var clearBtn = document.createElement("button");
      clearBtn.type = "button";
      clearBtn.textContent = "Clear";
      clearBtn.addEventListener("click", function () {
        clearOutput();
        if (inputEl) {
          inputEl.focus();
        }
      });

      var restartBtn = document.createElement("button");
      restartBtn.type = "button";
      restartBtn.textContent = "Restart";
      restartBtn.addEventListener("click", function () {
        stopWorker();
        clearOutput();
        queueLines(instance, lines);
        if (inputEl) {
          inputEl.focus();
        }
      });

      var hideBtn = document.createElement("button");
      hideBtn.type = "button";
      hideBtn.textContent = "Hide";
      hideBtn.addEventListener("click", closePanel);

      actions.appendChild(rerunBtn);
      actions.appendChild(clearBtn);
      actions.appendChild(restartBtn);
      actions.appendChild(hideBtn);
      head.appendChild(statusEl);
      head.appendChild(actions);

      output = document.createElement("div");
      output.className = "guide-console-output";
      output.setAttribute("role", "log");
      output.setAttribute("aria-live", "polite");
      output.setAttribute("tabindex", "0");

      var form = document.createElement("form");
      form.className = "guide-console-form";
      var promptMark = document.createElement("span");
      promptMark.className = "guide-console-prompt";
      promptMark.setAttribute("aria-hidden", "true");
      promptMark.textContent = ">";

      inputEl = document.createElement("input");
      inputEl.type = "text";
      inputEl.className = "guide-console-input";
      inputEl.setAttribute("aria-label", "Console command");
      inputEl.setAttribute("placeholder", "Type a Lex command and press Enter");
      inputEl.setAttribute("autocomplete", "off");
      inputEl.setAttribute("spellcheck", "false");

      inputEl.addEventListener("keydown", function (event) {
        if (event.key === "Escape") {
          event.preventDefault();
          closePanel();
          return;
        }
        if (event.ctrlKey && (event.key === "l" || event.key === "L")) {
          event.preventDefault();
          clearOutput();
          return;
        }
        if (event.key === "ArrowUp" && history.length) {
          event.preventDefault();
          historyPos = Math.max(0, historyPos - 1);
          inputEl.value = history[historyPos] || "";
          return;
        }
        if (event.key === "ArrowDown" && history.length) {
          event.preventDefault();
          historyPos = Math.min(history.length, historyPos + 1);
          inputEl.value = historyPos < history.length ? history[historyPos] : "";
        }
      });

      var sendBtn = document.createElement("button");
      sendBtn.type = "submit";
      sendBtn.textContent = "Run";

      form.addEventListener("submit", function (event) {
        event.preventDefault();
        var cmd = inputEl.value.trim();
        if (!cmd) {
          return;
        }
        if (!history.length || history[history.length - 1] !== cmd) {
          history.push(cmd);
          if (history.length > HISTORY_LIMIT) {
            history.shift();
          }
        }
        historyPos = history.length;
        inputEl.value = "";
        queueLines(instance, [cmd]);
      });

      form.appendChild(promptMark);
      form.appendChild(inputEl);
      form.appendChild(sendBtn);

      panel.appendChild(head);
      panel.appendChild(output);
      panel.appendChild(form);
      syncStatus(statusText, statusKind);
    }

    var instance = {
      root: root,
      receiveLines: receiveLines,
      appendPlainLine: appendPlainLine,
      syncStatus: syncStatus
    };
    allInstances.push(instance);

    runBtn.addEventListener("click", function () {
      var isOpen = !panel.hidden;
      if (isOpen) {
        closePanel();
        return;
      }
      buildPanel();
      panel.hidden = false;
      runBtn.setAttribute("aria-expanded", "true");
      queueLines(instance, lines);
      if (inputEl) {
        inputEl.focus();
      }
    });
  }

  for (var i = 0; i < widgets.length; i += 1) {
    mountWidget(widgets[i]);
  }
})();
`
}
