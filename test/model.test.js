const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

const Model = require("../Model.js")

const FIXTURES = path.join(__dirname, "fixtures")

function fixture(name) {
  return fs.readFileSync(path.join(FIXTURES, name + ".json"), "utf8")
}

// Every fixture that carries a session clock expires at this instant, so the
// relative formatting below is pinned rather than wall-clock dependent.
const NOW = Date.parse("2026-08-30T00:41:06Z")

test("connected: daemon state, self identity and control plane", () => {
  const status = Model.parseStatus(fixture("connected"), NOW)

  assert.equal(status.ok, true)
  assert.equal(status.unavailable, false)
  assert.equal(status.daemonStatus, "Connected")
  assert.equal(status.running, true)
  assert.equal(status.needsLogin, false)
  assert.equal(status.degraded, false)
  assert.equal(status.statusText, "Connected")
  assert.equal(status.selfFqdn, "laptop.netbird.example")
  assert.equal(status.selfName, "laptop")
  assert.equal(status.managementHost, "netbird.example")
  assert.equal(status.signalHost, "netbird.example")
  assert.equal(status.relaysAvailable, 2)
  assert.equal(status.relaysTotal, 2)
  assert.equal(status.cliVersion, "0.77.1")
})

test("connected: the CIDR suffix is stripped from this device's address", () => {
  const status = Model.parseStatus(fixture("connected"), NOW)

  assert.equal(status.selfIp, "100.64.0.9")
  assert.equal(Model.stripCidr("100.64.0.9/16"), "100.64.0.9")
  // Peers report a bare address already; stripping must leave it alone.
  assert.equal(Model.stripCidr("100.64.12.5"), "100.64.12.5")
  assert.equal(Model.stripCidr(""), "")
  assert.equal(Model.stripCidr(undefined), "")
})

test("connected: peer counts come straight from the daemon", () => {
  const status = Model.parseStatus(fixture("connected"), NOW)

  assert.equal(status.peersTotal, 4)
  assert.equal(status.peersConnected, 1)
  assert.equal(Model.peerCountText(status), "1/4")
  // Lazy connections leave healthy peers Idle, so every peer is listed, not
  // just the connected one.
  assert.equal(status.peers.length, 4)
})

test("connected: peers sort by name regardless of daemon order", () => {
  const status = Model.parseStatus(fixture("connected"), NOW)

  assert.deepEqual(status.peers.map((p) => p.name), ["atlas", "builder", "desktop-oslo", "phone-ada"])
})

test("connected: mixed peer statuses each get their own glyph and tint", () => {
  const status = Model.parseStatus(fixture("connected"), NOW)
  const byName = {}
  for (const peer of status.peers) byName[peer.name] = peer

  assert.deepEqual(
    { status: byName.atlas.status, online: byName.atlas.online, dimmed: byName.atlas.dimmed, offline: byName.atlas.offline, glyph: byName.atlas.glyph },
    { status: "Connected", online: true, dimmed: false, offline: false, glyph: "●" }
  )
  assert.deepEqual(
    { status: byName.builder.status, online: byName.builder.online, dimmed: byName.builder.dimmed, offline: byName.builder.offline },
    { status: "Connecting", online: false, dimmed: true, offline: false }
  )
  assert.deepEqual(
    { status: byName["desktop-oslo"].status, online: false, dimmed: byName["desktop-oslo"].dimmed, offline: byName["desktop-oslo"].offline },
    { status: "Idle", online: false, dimmed: true, offline: false }
  )
  // Disconnected is the only state that earns the crossed marker.
  assert.deepEqual(
    { status: byName["phone-ada"].status, dimmed: byName["phone-ada"].dimmed, offline: byName["phone-ada"].offline, glyph: byName["phone-ada"].glyph },
    { status: "Disconnected", dimmed: true, offline: true, glyph: "⊘" }
  )
  assert.notEqual(byName.atlas.glyph, byName.builder.glyph)
  assert.notEqual(byName.builder.glyph, byName["desktop-oslo"].glyph)
})

test("connected: peer transport and latency are normalized for display", () => {
  const status = Model.parseStatus(fixture("connected"), NOW)
  const byName = {}
  for (const peer of status.peers) byName[peer.name] = peer

  assert.equal(byName.atlas.connectionType, "P2P")
  assert.equal(byName.atlas.latency, "18.4 ms")
  assert.equal(byName.atlas.lastHandshake, "2026-08-30T00:40:52Z")
  // "-" means the peer never negotiated a transport; it is not a label.
  assert.equal(byName["desktop-oslo"].connectionType, "")
  assert.equal(byName["desktop-oslo"].latency, "")
  // Go's zero time means "no handshake ever", not a date in year one.
  assert.equal(byName["desktop-oslo"].lastHandshake, "")
})

test("connected: sessionExpiresAt renders as a relative span", () => {
  const status = Model.parseStatus(fixture("connected"), NOW)

  assert.equal(status.sessionExpiresAt, "2026-08-31T06:41:06Z")
  assert.equal(status.sessionText, "session expires in 1d 6h")
})

test("sessionExpiryText covers every span it can be asked for", () => {
  const at = "2026-08-31T06:41:06Z"
  const expiry = Date.parse(at)

  assert.equal(Model.sessionExpiryText(at, expiry - 30 * 3600 * 1000), "session expires in 1d 6h")
  assert.equal(Model.sessionExpiryText(at, expiry - 48 * 3600 * 1000), "session expires in 2d")
  assert.equal(Model.sessionExpiryText(at, expiry - (5 * 3600 + 12 * 60) * 1000), "session expires in 5h 12m")
  assert.equal(Model.sessionExpiryText(at, expiry - 3600 * 1000), "session expires in 1h")
  assert.equal(Model.sessionExpiryText(at, expiry - 45 * 1000), "session expires in under a minute")
  assert.equal(Model.sessionExpiryText(at, expiry + 1000), "session expired")
  // Nothing to say when the daemon has no session at all.
  assert.equal(Model.sessionExpiryText("", NOW), "")
  assert.equal(Model.sessionExpiryText("0001-01-01T00:00:00Z", NOW), "")
  assert.equal(Model.sessionExpiryText("not a date", NOW), "")
})

test("disconnected: an idle daemon reports no identity and no peers", () => {
  const status = Model.parseStatus(fixture("disconnected"), NOW)

  assert.equal(status.ok, true)
  assert.equal(status.unavailable, false)
  assert.equal(status.daemonStatus, "Idle")
  assert.equal(status.running, false)
  assert.equal(status.needsLogin, false)
  assert.equal(status.statusText, "Disconnected")
  assert.equal(status.selfIp, "")
  assert.equal(status.selfFqdn, "")
  assert.equal(status.selfName, "")
  assert.equal(status.peersTotal, 0)
  assert.deepEqual(status.peers, [])
  assert.equal(status.sessionText, "")
  // Management and signal are down because the daemon is down, which is not
  // the degraded case — that one is a *connected* daemon with a dead control
  // plane, and it must not fire here.
  assert.equal(status.degraded, false)
  assert.equal(status.degradedText, "")
})

test("needs-login: every re-auth state collapses into one", () => {
  const status = Model.parseStatus(fixture("needs-login"), NOW)

  assert.equal(status.ok, true)
  assert.equal(status.daemonStatus, "NeedsLogin")
  assert.equal(status.needsLogin, true)
  assert.equal(status.running, false)
  assert.equal(status.statusText, "Needs login")
  assert.equal(status.managementError, "peer is not registered")
  assert.equal(status.sessionExpiresAt, "")

  assert.equal(Model.isLoginState("NeedsLogin"), true)
  assert.equal(Model.isLoginState("SessionExpired"), true)
  assert.equal(Model.isLoginState("LoginFailed"), true)
  assert.equal(Model.isLoginState("Connected"), false)
  assert.equal(Model.isLoginState(""), false)
})

test("degraded: a connected daemon with a dead control plane warns", () => {
  const status = Model.parseStatus(fixture("degraded"), NOW)

  assert.equal(status.running, true)
  assert.equal(status.degraded, true)
  assert.equal(status.degradedText, "Management server unreachable")
  assert.equal(status.statusText, "Management server unreachable")
  assert.equal(Model.degradedTextFor(true, true), "Management and signal servers unreachable")
  assert.equal(Model.degradedTextFor(false, true), "Signal server unreachable")
  assert.equal(Model.degradedTextFor(false, false), "")
})

test("empty stdout parses to a fully-formed unknown state", () => {
  for (const raw of ["", "   \n\t ", null, undefined]) {
    const status = Model.parseStatus(raw, NOW)
    assert.equal(status.ok, true)
    assert.equal(status.unavailable, true)
    assert.equal(status.daemonStatus, "Unknown")
    assert.equal(status.statusText, "Unknown")
    assert.equal(status.running, false)
    assert.equal(status.needsLogin, false)
    assert.deepEqual(status.peers, [])
    assert.equal(status.selfIp, "")
    assert.equal(status.peersTotal, 0)
  }
})

test("garbage stdout never throws and never claims a state it does not have", () => {
  const garbage = [
    "netbird: command not found",
    "{",
    '{"daemonStatus": ',
    "<html><body>502</body></html>",
    "null",
    "42",
    '"Connected"',
    "[1, 2, 3]"
  ]

  for (const raw of garbage) {
    const status = Model.parseStatus(raw, NOW)
    assert.equal(status.ok, false, `expected ok=false for ${JSON.stringify(raw)}`)
    assert.equal(status.unavailable, true)
    assert.equal(status.daemonStatus, "Unknown")
    assert.equal(status.running, false)
    assert.equal(status.needsLogin, false)
    assert.equal(status.statusText, "Status error")
    assert.deepEqual(status.peers, [])
  }
})

test("a status document with no peers block still parses", () => {
  const status = Model.parseStatus('{"daemonStatus":"Connected"}', NOW)

  assert.equal(status.ok, true)
  assert.equal(status.running, true)
  assert.equal(status.peersTotal, 0)
  assert.deepEqual(status.peers, [])
  // No management block at all reads as "not connected", which is the
  // degraded case, and that is the honest answer.
  assert.equal(status.degraded, true)
})

test("hostFromUrl trims the scheme and the default port", () => {
  assert.equal(Model.hostFromUrl("https://netbird.example:443"), "netbird.example")
  assert.equal(Model.hostFromUrl("https://netbird.example:8443"), "netbird.example:8443")
  assert.equal(Model.hostFromUrl("http://netbird.example:80"), "netbird.example")
  assert.equal(Model.hostFromUrl("rels://relay.netbird.example:443"), "relay.netbird.example")
  assert.equal(Model.hostFromUrl("netbird.example:443/path"), "netbird.example")
  assert.equal(Model.hostFromUrl(""), "")
})

test("formatLatency scales with the size of the number", () => {
  assert.equal(Model.formatLatency(0), "")
  assert.equal(Model.formatLatency(-1), "")
  assert.equal(Model.formatLatency("nope"), "")
  assert.equal(Model.formatLatency(1200000), "1.20 ms")
  assert.equal(Model.formatLatency(18400000), "18.4 ms")
  assert.equal(Model.formatLatency(143000000), "143 ms")
})

test("extractAuthUrl only opens a browser for an actual login prompt", () => {
  const prompt = [
    "Please do the SSO login in your browser.",
    "If your browser didn't open automatically, use this URL to log in:",
    "",
    "https://idp.netbird.example/activate?user_code=ABCD-EFGH",
    ""
  ].join("\n")

  assert.equal(Model.extractAuthUrl(prompt, "https://netbird.example:443"), "https://idp.netbird.example/activate?user_code=ABCD-EFGH")
  // A plain connection error carries a URL too; it is not something to open.
  assert.equal(Model.extractAuthUrl("failed to connect to https://netbird.example:443: timeout", ""), "")
  // The endpoint the caller already knows is skipped even inside a prompt.
  assert.equal(
    Model.extractAuthUrl("log in at https://netbird.example:443 then https://idp.netbird.example/device", "https://netbird.example:443"),
    "https://idp.netbird.example/device"
  )
  assert.equal(Model.extractAuthUrl("", ""), "")
})

test("commands are the exact argv vectors the service runs", () => {
  assert.deepEqual(Model.statusCommand(), ["netbird", "status", "--json"])
  assert.deepEqual(Model.downCommand(), ["netbird", "down"])
  // --no-browser keeps the SSO URL on stdout so the shell opens it itself.
  assert.deepEqual(Model.upCommand(), ["netbird", "up", "--no-browser"])
})

test("summaryLine is what the status IPC call answers with", () => {
  const status = Model.parseStatus(fixture("connected"), NOW)

  assert.equal(
    Model.summaryLine(status),
    "Connected · laptop · 100.64.0.9 · 1/4 peers · session expires in 1d 6h"
  )
  assert.equal(Model.summaryLine(Model.parseStatus("", NOW)), "Unknown")
  assert.equal(Model.summaryLine(null), "Unknown")
})

// The fixtures must never carry a real mesh's names or addresses, so rather
// than blocklisting this machine's identifiers, every host and address in
// them is required to be in the documentation domain and the CGNAT range
// NetBird itself hands out (100.64.0.0/10).
test("fixtures use only synthetic hosts and CGNAT addresses", () => {
  const names = fs.readdirSync(FIXTURES)
  assert.ok(names.length > 0)

  for (const name of names) {
    const body = fs.readFileSync(path.join(FIXTURES, name), "utf8")
    const doc = JSON.parse(body)

    for (const match of body.match(/"[a-z0-9.-]+\.[a-z]{2,}(:\d+)?"/gi) || []) {
      const host = match.replace(/"/g, "").split(":")[0]
      assert.ok(
        host === "netbird.example" || host.endsWith(".netbird.example"),
        `${name}: host ${host} is not under netbird.example`
      )
    }

    for (const match of body.match(/\b\d{1,3}(\.\d{1,3}){3}\b/g) || []) {
      const octets = match.split(".").map(Number)
      assert.equal(octets[0], 100, `${name}: ${match} is outside 100.64.0.0/10`)
      assert.ok(octets[1] >= 64 && octets[1] <= 127, `${name}: ${match} is outside 100.64.0.0/10`)
    }

    // The daemon's own key and every peer key must be placeholders, not the
    // 44-character WireGuard keys a live status document carries.
    const keys = [doc.publicKey || ""].concat(((doc.peers || {}).details || []).map((p) => p.publicKey || ""))
    for (const key of keys.filter((k) => k !== "")) {
      assert.ok(/^AbCdEfGhIjKlMnOpQrStUvWxYz0123456789ABCDEF\d=$/.test(key), `${name}: ${key} is not a placeholder key`)
    }
  }
})
