// A Node mirror of the checks `omarchy plugin validate` makes, so the same
// `node --test test/` run covers them locally and in CI — where the Omarchy
// validator is not installed. Kept deliberately close to the shell script's
// rules; where it and this disagree, the shell script is authoritative.

const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

const ROOT = path.join(__dirname, "..")
const manifestPath = path.join(ROOT, "manifest.json")

function manifest() {
  return JSON.parse(fs.readFileSync(manifestPath, "utf8"))
}

test("manifest.json is valid JSON with the required fields", () => {
  const m = manifest()
  // schemaVersion must be the number 1, not the string — the registry's check
  // is type-aware and would reject "1".
  assert.strictEqual(m.schemaVersion, 1)
  for (const field of ["id", "name", "version", "kinds", "entryPoints"]) {
    assert.ok(Object.prototype.hasOwnProperty.call(m, field), `missing required field '${field}'`)
  }
  assert.ok(Array.isArray(m.kinds) && m.kinds.length > 0, "kinds must be a non-empty array")
  assert.equal(typeof m.entryPoints, "object")
  assert.ok(m.entryPoints !== null && !Array.isArray(m.entryPoints))
})

test("the plugin id is well formed and outside the reserved namespace", () => {
  const id = manifest().id
  assert.ok(/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id), `invalid plugin id '${id}'`)
  assert.ok(!id.includes(".."), "id may not contain '..'")
  assert.ok(!id.startsWith("omarchy."), "the omarchy.* namespace is reserved for first-party plugins")
})

test("every entry point is a safe relative path that exists", () => {
  const m = manifest()
  const entries = Object.entries(m.entryPoints)
  assert.ok(entries.length > 0)

  for (const [kind, target] of entries) {
    assert.equal(typeof target, "string", `${kind}: entry point must be a string`)
    assert.notEqual(target, "", `${kind}: entry point is empty`)
    assert.ok(!target.includes("\n"), `${kind}: entry point may not contain a newline`)
    assert.ok(!target.startsWith("/"), `${kind}: entry point must be relative`)
    assert.ok(!target.includes(".."), `${kind}: entry point may not contain '..'`)
    // The validator requires a regular file, not merely something that exists:
    // a directory at an entry point passes `-f`-less checks and then fails to
    // load. Mirror that, or this suite is weaker than the tool it stands in for.
    const full = path.join(ROOT, target)
    assert.ok(fs.existsSync(full), `${kind}: entry point file not found: ${target}`)
    assert.ok(fs.statSync(full).isFile(), `${kind}: entry point is not a regular file: ${target}`)
  }
})

test("every declared kind has the entry point that loads it", () => {
  // Claiming a kind without its entry point installs and enables a plugin that
  // then does nothing, explained only by a line on the shell's console.
  const KIND_ENTRY_POINT = {
    bar: "bar",
    "bar-widget": "barWidget",
    menu: "menu",
    overlay: "overlay",
    panel: "panel",
    service: "service"
  }
  const m = manifest()
  for (const kind of m.kinds) {
    const key = KIND_ENTRY_POINT[kind]
    if (!key) continue // a kind this table does not cover is left alone
    assert.ok(
      Object.prototype.hasOwnProperty.call(m.entryPoints, key),
      `kind '${kind}' requires entryPoints.${key}`
    )
  }
})

test("barWidget.defaultSection is one the bar accepts", () => {
  const bar = manifest().barWidget
  if (!bar || !Object.prototype.hasOwnProperty.call(bar, "defaultSection")) return
  assert.ok(["left", "center", "right"].includes(bar.defaultSection),
    `defaultSection must be left, center or right, got '${bar.defaultSection}'`)
})

test("every setting in the schema has a matching default", () => {
  // Not a validator rule, but a drift the widget would otherwise inherit
  // silently: a schema key with no default reads as undefined at runtime.
  const bar = manifest().barWidget
  if (!bar || !Array.isArray(bar.schema)) return
  for (const entry of bar.schema) {
    assert.ok(entry.key, "every schema entry needs a key")
    assert.ok(
      Object.prototype.hasOwnProperty.call(bar.defaults || {}, entry.key),
      `schema key '${entry.key}' has no entry in defaults`
    )
    if (entry.type === "enum") {
      assert.ok(Array.isArray(entry.options) && entry.options.length > 0, `${entry.key}: enum needs options`)
      assert.ok(entry.options.includes(entry.defaultValue), `${entry.key}: defaultValue is not one of its options`)
      assert.equal(bar.defaults[entry.key], entry.defaultValue, `${entry.key}: defaults and defaultValue disagree`)
    }
  }
})

test("the tree contains no symlinks", () => {
  // A symlink inside a plugin folder could point back at arbitrary files once
  // the folder is copied into the trusted plugins directory.
  // Only `.git` is skipped — the validator walks everything else, and a
  // symlink under `node_modules` would ship just the same.
  const skip = new Set([".git"])
  const found = []

  function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (skip.has(entry.name)) continue
      const full = path.join(dir, entry.name)
      if (entry.isSymbolicLink()) found.push(path.relative(ROOT, full))
      else if (entry.isDirectory()) walk(full)
    }
  }

  walk(ROOT)
  assert.deepEqual(found, [], `symlinks are not allowed inside a plugin folder: ${found.join(", ")}`)
})

test("the CI workflow runs the same command that passes locally", () => {
  const workflow = path.join(ROOT, ".github", "workflows", "ci.yml")
  assert.ok(fs.existsSync(workflow), "ci.yml is missing")
  const body = fs.readFileSync(workflow, "utf8")

  assert.ok(body.includes("node --test test/"), "CI must run the local test command")
  // Pinned by major, and first-party only — no third-party actions.
  assert.ok(body.includes("actions/checkout@v4"))
  assert.ok(body.includes("actions/setup-node@v4"))
  for (const line of body.split("\n")) {
    const uses = line.match(/^\s*-?\s*uses:\s*(\S+)/)
    if (!uses) continue
    assert.ok(uses[1].startsWith("actions/"), `third-party action not allowed: ${uses[1]}`)
    assert.ok(uses[1].includes("@"), `action must be version-pinned: ${uses[1]}`)
  }
})
