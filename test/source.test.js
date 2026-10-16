// Source-level guards for the conventions Omarchy's shell tree enforces on its
// own panels, so the plugin cannot drift from them again without a test
// saying so. Each mirrors a rule in the Omarchy checkout (test/shell.d/).
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

const ROOT = path.join(__dirname, "..")
const read = (name) => fs.readFileSync(path.join(ROOT, name), "utf8")
const QML = ["Panel.qml", "Service.qml", "NetbirdIcon.qml", "BoundedCollector.qml"]

// Blank out comments and string literals, keeping line structure, so a rule
// never trips on prose or on text the panel shows.
function code(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "))
    .replace(/\/\/[^\n]*/g, "")
    .replace(/"(?:[^"\\\n]|\\.)*"/g, '""')
    .replace(/'(?:[^'\\\n]|\\.)*'/g, "''")
}

test("the palette singleton is qualified for Qt 6.12 (no bare Color.)", () => {
  // Omarchy b83d3df0: under Qt 6.12 a bare `Color` resolves to Qt's own type.
  for (const name of QML) {
    const src = code(read(name))
    const bare = src.match(/(^|[^.\w])Color\./g) || []
    assert.equal(bare.length, 0, `${name} uses bare Color. ${bare.length} time(s)`)
    if (/Commons\.Color\./.test(src)) assert.match(src, /import qs\.Commons as Commons/, `${name} must import qs.Commons as Commons`)
  }
})

test("the panel's IPC goes over the shell's own socket", () => {
  // Omarchy c231097d: ShellIpc answers on the shell socket; IpcHandler falls
  // back to the slow `qs ipc` path for every call.
  const src = code(read("Panel.qml"))
  assert.match(src, /\bShellIpc \{/)
  assert.doesNotMatch(src, /\bIpcHandler \{/)
})

test("the panel card is built on first open, not at startup", () => {
  // Omarchy 4c1b4cb3: KeyboardPanel takes its card as `content:`; a direct
  // child is built once per monitor at startup.
  const src = read("Panel.qml")
  const start = src.indexOf("\n  KeyboardPanel {")
  assert.ok(start > 0, "KeyboardPanel is declared at the root")
  const body = src.slice(start)
  assert.match(body, /\n    content: PanelKeyCatcher \{/)
  assert.doesNotMatch(body, /\n    PanelKeyCatcher \{/)
  assert.match(body, /focusTarget: panel\.loadedContent/)
  assert.match(body, /panel\.loadedContentHeight/)
})

test("every Text that renders a non-literal value declares textFormat", () => {
  // Omarchy 3af7675a: AutoText promotes a string starting with `<` to rich
  // text, and <img src> in a peer name would make the shell fetch a URL.
  const lines = read("Panel.qml").split("\n")
  const stripped = code(read("Panel.qml")).split("\n")
  const problems = []
  for (let i = 0; i < lines.length; i++) {
    if (!/^\s*Text \{\s*$/.test(lines[i])) continue
    let depth = 0
    let end = i
    for (let j = i; j < lines.length; j++) {
      depth += (stripped[j].match(/\{/g) || []).length - (stripped[j].match(/\}/g) || []).length
      if (depth <= 0) { end = j; break }
    }
    const block = lines.slice(i, end + 1)
    const textLine = block.find((l) => /^\s*text:\s*/.test(l))
    if (!textLine) continue
    const value = textLine.replace(/^\s*text:\s*/, "").trim()
    const literal = /^"(?:[^"\\]|\\.)*"$/.test(value)
    if (!literal && !block.some((l) => /^\s*textFormat:/.test(l))) problems.push(i + 1)
  }
  assert.deepEqual(problems, [], `Text without textFormat at lines ${problems.join(", ")}`)
})

test("the daemon state machine is the plugin's service, shared across monitors", () => {
  const manifest = JSON.parse(read("manifest.json"))
  assert.ok(manifest.kinds.includes("service"), "manifest declares the service kind")
  assert.equal(manifest.entryPoints.service, "Service.qml")
  assert.equal(manifest.keepLoaded, true, "the service survives plugin hot-reloads")
  const panel = code(read("Panel.qml"))
  assert.doesNotMatch(panel, /\n  Service \{/, "the widget no longer inlines a Service per monitor")
  assert.match(panel, /serviceFor\(moduleName\)/, "the widget looks its service up through the shell")
  assert.match(panel, /readonly property var netbird: sharedService \|\| idle/)
  const service = code(read("Service.qml"))
  assert.match(service, /function panelOpened\(\)/)
  assert.match(service, /function panelClosed\(\)/)
})

test("the idle stand-in mirrors every property and function the service exposes", () => {
  const service = read("Service.qml")
  const panel = read("Panel.qml")
  const idleStart = panel.indexOf("\n  QtObject {\n    id: idle")
  assert.ok(idleStart > 0, "idle stand-in is declared")
  const idle = panel.slice(idleStart, panel.indexOf("\n  }\n", idleStart) + 4)
  for (const m of service.matchAll(/^  (?:readonly )?property \w+ (\w+)/gm)) {
    if (["shell", "manifest"].includes(m[1])) continue
    assert.match(idle, new RegExp(`\\n    property \\w+ ${m[1]}:`), `idle is missing property ${m[1]}`)
  }
  for (const m of service.matchAll(/^  function (\w+)\(/gm)) {
    assert.match(idle, new RegExp(`\\n    function ${m[1]}\\(`), `idle is missing function ${m[1]}`)
  }
})

test("the documented IPC surface is present", () => {
  const src = read("Panel.qml")
  for (const fn of ["open", "close", "show", "hide", "toggle", "refresh", "up", "down", "toggleNetbird", "status"]) {
    assert.match(src, new RegExp(`\\n    function ${fn}\\(\\)`), `IPC function ${fn}`)
  }
})
