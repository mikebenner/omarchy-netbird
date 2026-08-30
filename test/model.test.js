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

// `netbird status --json` marshals an empty peer slice as null rather than [],
// which is the shape a freshly-started daemon reports.
test("a null peers.details parses to zero peers without throwing", () => {
  for (const raw of ['{"peers":{"details":null}}', '{"peers":{"total":0,"connected":0,"details":null}}']) {
    const status = Model.parseStatus(raw, NOW)
    assert.equal(status.ok, true)
    assert.equal(status.unavailable, false)
    assert.deepEqual(status.peers, [])
    assert.equal(status.peersTotal, 0)
    assert.equal(status.peersConnected, 0)
    assert.equal(Model.peerCountText(status), "0/0")
  }

  // The same must hold for the other shapes the field can arrive in.
  for (const raw of ['{"peers":{"details":{}}}', '{"peers":{"details":"nope"}}']) {
    const status = Model.parseStatus(raw, NOW)
    assert.equal(status.ok, true)
    assert.deepEqual(status.peers, [])
  }
})

test("a connected daemon with no session clock leaves the hero line sane", () => {
  const doc = JSON.parse(fixture("connected"))
  delete doc.sessionExpiresAt
  const status = Model.parseStatus(JSON.stringify(doc), NOW)

  assert.equal(status.running, true)
  assert.equal(status.sessionExpiresAt, "")
  assert.equal(status.sessionText, "")
  // Everything the hero line falls back on is still there.
  assert.equal(status.statusText, "Connected")
  assert.equal(status.managementHost, "netbird.example")
  assert.equal(status.selfName, "laptop")
  assert.equal(Model.peerCountText(status), "1/4")
  // And the summary drops the session clause rather than trailing a separator.
  assert.equal(Model.summaryLine(status), "Connected · laptop · 100.64.0.9 · 1/4 peers")

  // A zero session clock is the same case, not a date in year one.
  const zeroed = Model.parseStatus(JSON.stringify({ ...doc, sessionExpiresAt: "0001-01-01T00:00:00Z" }), NOW)
  assert.equal(zeroed.sessionText, "")
})

// Fix 1's hero line leads with this text, so the exact string is the contract.
test("degraded text is what the panel puts in front of the session clock", () => {
  const managementDown = Model.parseStatus(fixture("degraded"), NOW)
  assert.equal(managementDown.degraded, true)
  assert.equal(managementDown.degradedText, "Management server unreachable")
  assert.equal(managementDown.sessionText, "session expires in 1d 6h")

  const doc = JSON.parse(fixture("degraded"))
  doc.management.connected = true
  doc.signal.connected = false
  const signalDown = Model.parseStatus(JSON.stringify(doc), NOW)
  assert.equal(signalDown.degraded, true)
  assert.equal(signalDown.degradedText, "Signal server unreachable")

  doc.management.connected = false
  const bothDown = Model.parseStatus(JSON.stringify(doc), NOW)
  assert.equal(bothDown.degradedText, "Management and signal servers unreachable")

  // A healthy control plane says nothing, so the hero line stays as it was.
  const healthy = Model.parseStatus(fixture("connected"), NOW)
  assert.equal(healthy.degraded, false)
  assert.equal(healthy.degradedText, "")
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

// NB-03. SplitParser delivers `netbird up --no-browser` output one line at a
// time, and no single line of the real prompt carries both the invitation and
// the URL — the whole point of accumulating.
test("loginProgress yields the SSO URL exactly once, on the line that completes it", () => {
  const lines = [
    "Please do the SSO login in your browser.",
    "If your browser didn't open automatically, use this URL to log in:",
    "",
    "https://idp.example/activate"
  ]
  const management = "https://netbird.example:443"

  // Keep reading past the URL line: the URL stays in the buffer forever, so
  // every later line would re-report it unless loginProgress only answers on
  // the line that first completed the prompt.
  const after = ["Waiting for the browser…", "Connected", ""]
  const fed = lines.concat(after)

  let buffer = ""
  const urls = []
  for (const line of fed) {
    const progress = Model.loginProgress(buffer, line, management)
    buffer = progress.buffer
    urls.push(progress.url)
  }

  // Nothing to open until the URL itself arrives.
  assert.deepEqual(urls.slice(0, 3), ["", "", ""])
  assert.equal(urls[3], "https://idp.example/activate")
  // And nothing after it, however long the process keeps talking.
  assert.deepEqual(urls.slice(4), ["", "", ""])
  assert.equal(urls.filter((u) => u !== "").length, 1)
  // Each line alone yields nothing — the accumulation is what does the work.
  for (const line of fed) assert.equal(Model.extractAuthUrl(line, management), "")
  assert.equal(buffer, fed.join("\n"))
  // The buffer still holds a URL; it is loginProgress that stops offering it.
  assert.equal(Model.extractAuthUrl(buffer, management), "https://idp.example/activate")
})

// NB-03 residual. A second URL later in the same login is not a second
// invitation either — one login opens at most one browser.
test("loginProgress never re-reports once a URL has been seen", () => {
  let buffer = ""
  const feed = (line) => {
    const progress = Model.loginProgress(buffer, line, "")
    buffer = progress.buffer
    return progress.url
  }

  assert.equal(feed("Please do the SSO login in your browser."), "")
  assert.equal(feed("https://idp.example/activate"), "https://idp.example/activate")
  assert.equal(feed("https://idp.example/second"), "")
  assert.equal(feed("Use this URL to log in:"), "")
  assert.equal(feed(""), "")
})

test("loginProgress handles the short --no-browser prompt and an empty start", () => {
  let progress = Model.loginProgress("", "Use this URL to log in:", "")
  assert.equal(progress.url, "")
  assert.equal(progress.buffer, "Use this URL to log in:")

  progress = Model.loginProgress(progress.buffer, "https://idp.example/device?user_code=AB-CD", "")
  assert.equal(progress.url, "https://idp.example/device?user_code=AB-CD")

  // Null and undefined lines are survivable, and the buffer is bounded.
  assert.equal(Model.loginProgress(null, null, "").buffer, "")
  assert.equal(Model.loginProgress(undefined, "x", "").buffer, "x")
  const huge = Model.loginProgress("y".repeat(40000), "tail", "")
  assert.ok(huge.buffer.length <= 16384)
  assert.ok(huge.buffer.endsWith("tail"))
})

// NB-04. An auth-flavoured word in a failure line is not an invitation to
// click; only the phrasing NetBird actually prints counts.
test("extractAuthUrl refuses auth-flavoured error lines", () => {
  assert.equal(Model.extractAuthUrl("failed to authenticate TLS peer at https://status.example/error", ""), "")
  assert.equal(Model.extractAuthUrl("failed to authenticate TLS peer at https://status.example/error", "https://netbird.example:443"), "")
  assert.equal(Model.extractAuthUrl("WARN could not log in via https://status.example/x", ""), "")
  assert.equal(Model.extractAuthUrl("error: SSO login unavailable, see https://status.example/x", ""), "")
  assert.equal(Model.extractAuthUrl("please authorize this device at https://idp.example/activate", ""), "")

  // The real phrasing still extracts, including when a failure line sits in
  // the same buffer as a genuine prompt.
  const mixed = [
    "WARN relay probe failed for https://relay.example/health",
    "Please do the SSO login in your browser.",
    "https://idp.example/activate?user_code=ABCD-EFGH"
  ].join("\n")
  assert.equal(Model.extractAuthUrl(mixed, ""), "https://idp.example/activate?user_code=ABCD-EFGH")

  // A URL sharing the management host is the daemon talking about itself.
  const sameHost = "Please do the SSO login in your browser.\nhttps://netbird.example/peers"
  assert.equal(Model.extractAuthUrl(sameHost, "https://netbird.example:443"), "")
})

// NB-05. A CLI that prepends a warning line still handed us a status document.
test("a warning line before the JSON does not lose the document", () => {
  const status = Model.parseStatus('WARNING: cache stale\n{"daemonStatus":"Idle"}', NOW)
  assert.equal(status.ok, true)
  assert.equal(status.unavailable, false)
  assert.equal(status.daemonStatus, "Idle")
  assert.equal(status.statusText, "Disconnected")

  const trailing = Model.parseStatus('warn: x\n{"daemonStatus":"Connected"}\nbye', NOW)
  assert.equal(trailing.ok, true)
  assert.equal(trailing.daemonStatus, "Connected")

  const full = Model.parseStatus("WARNING: cache stale\n" + fixture("connected"), NOW)
  assert.equal(full.ok, true)
  assert.equal(full.selfIp, "100.64.0.9")
  assert.equal(full.peers.length, 4)

  // Salvage must not turn genuine garbage into a false success.
  for (const raw of ["netbird: command not found", "{", "<html>{oops}</html>"]) {
    assert.equal(Model.parseStatus(raw, NOW).ok, false, `expected ok=false for ${JSON.stringify(raw)}`)
  }
})

// NB-04 residual. The daemon reaches its own host on more than one port, and a
// failure word inside a URL path says nothing about the sentence around it.
test("extractAuthUrl compares hosts, not URL strings", () => {
  const management = "https://netbird.example:443"
  const prompt = "Please do the SSO login in your browser."

  // A port variant of the management host is still the management host.
  assert.equal(Model.extractAuthUrl(prompt + "\nhttps://netbird.example:8443/device", management), "")
  // As are case and credential variants.
  assert.equal(Model.extractAuthUrl(prompt + "\nhttps://NetBird.Example/device", management), "")
  assert.equal(Model.extractAuthUrl(prompt + "\nhttps://user:pw@netbird.example:8443/device", management), "")
  // The daemon's own chatter must not win a race against the real IdP line.
  assert.equal(
    Model.extractAuthUrl([prompt, "dialing https://netbird.example:8443/device", "https://idp.example/activate"].join("\n"), management),
    "https://idp.example/activate"
  )

  assert.equal(Model.hostKey("https://netbird.example:443"), "netbird.example")
  assert.equal(Model.hostKey("https://NetBird.Example:8443/x?y=1"), "netbird.example")
  assert.equal(Model.hostKey("https://user:pw@netbird.example./x"), "netbird.example")
  assert.equal(Model.hostKey("https://[2001:db8::1]:8443/x"), "2001:db8::1")
  assert.equal(Model.hostKey(""), "")
})

test("extractAuthUrl judges the sentence, not the link inside it", () => {
  // A URL path containing "error" is not a failure report.
  assert.equal(
    Model.extractAuthUrl("Use this URL to log in: https://idp.example/error-recovery", ""),
    "https://idp.example/error-recovery"
  )
  assert.equal(
    Model.extractAuthUrl("Use this URL to log in: https://idp.example/oauth?on_failure=retry", ""),
    "https://idp.example/oauth?on_failure=retry"
  )
  // The original false positive is still refused.
  assert.equal(Model.extractAuthUrl("failed to authenticate TLS peer at https://status.example/error", ""), "")
  // And a failure word in the prose still wins over a clean URL.
  assert.equal(Model.extractAuthUrl("Use this URL to log in:\nWARN could not reach https://idp.example/activate", ""), "")
})

// NB-05 residual. gRPC warnings carry braces of their own, so the old
// first-brace-to-last-brace span swallowed the warning and the document.
test("a brace-bearing warning line does not hide the status document", () => {
  const braced = 'WARNING grpc target {Addr:"/var/run/netbird.sock"}\n{"daemonStatus":"Idle"}'
  const status = Model.parseStatus(braced, NOW)
  assert.equal(status.ok, true)
  assert.equal(status.daemonStatus, "Idle")
  assert.equal(status.statusText, "Disconnected")

  // Same, with the document pretty-printed across several lines.
  const multiline = 'WARN grpc {Addr:"x"} retrying\n' + fixture("connected")
  const full = Model.parseStatus(multiline, NOW)
  assert.equal(full.ok, true)
  assert.equal(full.selfIp, "100.64.0.9")
  assert.equal(full.peers.length, 4)

  // Braces that never form a document are still an error.
  assert.equal(Model.parseStatus('WARNING grpc {Addr:"x"} and {more:1}', NOW).ok, false)
})

// NB-06 residual. Not every JSON object on stdout is a status document.
test("only a status-shaped document is accepted as status", () => {
  const denied = Model.parseStatus('{"error":"permission denied"}', NOW)
  assert.equal(denied.ok, false)
  assert.equal(denied.unavailable, true)
  assert.equal(denied.daemonStatus, "Unknown")
  // A distinct error, so the caller can tell this from "stdout was not JSON".
  assert.equal(denied.error, "netbird status output is not a status document")
  assert.equal(Model.parseStatus("netbird: command not found", NOW).error, "Failed to parse netbird status")

  // A real document exits non-zero and is still a document.
  const needsLogin = Model.parseStatus('{"daemonStatus":"NeedsLogin","peers":{"details":[]}}', NOW)
  assert.equal(needsLogin.ok, true)
  assert.equal(needsLogin.needsLogin, true)
  assert.equal(needsLogin.statusText, "Needs login")

  assert.equal(Model.isStatusDocument({ daemonStatus: "Idle" }), true)
  assert.equal(Model.isStatusDocument({ peers: { total: 0 } }), true)
  assert.equal(Model.isStatusDocument({ management: { connected: true } }), true)
  // A null top-level sub-object is not evidence of a status document; the
  // nullable Go slice lives at peers.details, one level down.
  assert.equal(Model.isStatusDocument({ peers: null }), false)
  assert.equal(Model.isStatusDocument({ management: null }), false)
  assert.equal(Model.isStatusDocument({ peers: { details: null } }), true)
  assert.equal(Model.isStatusDocument({ error: "permission denied" }), false)
  assert.equal(Model.isStatusDocument({ daemonStatus: 7 }), false)
  assert.equal(Model.isStatusDocument({ peers: "none" }), false)
  assert.equal(Model.isStatusDocument([{ daemonStatus: "Idle" }]), false)
  assert.equal(Model.isStatusDocument(null), false)
})

// NB-06 residual. The daemon always fills in its top-level sub-objects; the
// nullable Go slice is one level down at peers.details.
test("a null top-level sub-object is not a status document", () => {
  const nulled = Model.parseStatus('{"peers":null}', NOW)
  assert.equal(nulled.ok, false)
  assert.equal(nulled.unavailable, true)
  assert.equal(nulled.error, "netbird status output is not a status document")
  assert.equal(Model.parseStatus('{"management":null}', NOW).ok, false)
  assert.equal(Model.parseStatus('{"peers":null,"management":null}', NOW).ok, false)

  // The nested null the daemon really does emit is still fine.
  const nested = Model.parseStatus('{"peers":{"details":null}}', NOW)
  assert.equal(nested.ok, true)
  assert.deepEqual(nested.peers, [])
  // And a null sub-object alongside a real daemonStatus is still a document.
  assert.equal(Model.parseStatus('{"daemonStatus":"Idle","peers":null}', NOW).ok, true)
})

// NB-04 residual. The `]` closing an IPv6 literal is part of the URL, not the
// sentence's punctuation.
test("a bracketed IPv6 URL keeps its closing bracket", () => {
  const management = "https://[2001:db8::1]:443"
  const prompt = "Use this URL to log in: "

  // Both forms name the management host and must be suppressed.
  assert.equal(Model.extractAuthUrl(prompt + "https://[2001:db8::1]", management), "")
  assert.equal(Model.extractAuthUrl(prompt + "https://[2001:db8::1]/device", management), "")
  assert.equal(Model.extractAuthUrl(prompt + "https://[2001:db8::1]:8443/device", management), "")
  // A different host still extracts, bracket intact.
  assert.equal(Model.extractAuthUrl(prompt + "https://[2001:db8::2]/device", management), "https://[2001:db8::2]/device")
  assert.equal(Model.extractAuthUrl(prompt + "https://idp.example/", management), "https://idp.example/")

  assert.equal(Model.trimUrlPunctuation("https://[2001:db8::1]"), "https://[2001:db8::1]")
  assert.equal(Model.trimUrlPunctuation("https://[2001:db8::1]."), "https://[2001:db8::1]")
  // An unmatched bracket really is punctuation.
  assert.equal(Model.trimUrlPunctuation("https://idp.example/x]"), "https://idp.example/x")
  assert.equal(Model.trimUrlPunctuation("https://idp.example/x)"), "https://idp.example/x")
  assert.equal(Model.trimUrlPunctuation("https://idp.example/x(y)"), "https://idp.example/x(y)")
  assert.equal(Model.trimUrlPunctuation("https://idp.example/x,;:"), "https://idp.example/x")

  // Ordinary sentence punctuation is still peeled.
  assert.equal(Model.extractAuthUrl(prompt + "see https://idp.example/activate.", ""), "https://idp.example/activate")
  assert.equal(Model.extractAuthUrl(prompt + "(https://idp.example/activate)", ""), "https://idp.example/activate")
})

// NB-05 residual. The sweep is bounded at both ends now; a long braced prefix
// used to cost time quadratic in its line count.
test("a long braced prefix is resolved or refused quickly", () => {
  const prefix = Array.from({ length: 3200 }, (_, i) => `WARNING grpc target {Addr:"/run/n${i}.sock"}`).join("\n")
  const input = prefix + "\n" + '{"daemonStatus":"Idle"}'

  // Best of three: this asserts an algorithmic bound, and a single sample on a
  // loaded machine measures the scheduler as much as the parser. The minimum
  // still rises with the line count if the sweep ever goes quadratic again,
  // which is the regression worth catching — it used to cost ~500 ms here.
  const fastest = (raw) => {
    let best = Infinity
    let result = null
    for (let i = 0; i < 3; i++) {
      const started = Date.now()
      result = Model.parseStatus(raw, NOW)
      best = Math.min(best, Date.now() - started)
    }
    return { best, result }
  }

  const withDoc = fastest(input)
  assert.ok(withDoc.best < 100, `sweep took ${withDoc.best} ms`)
  assert.equal(withDoc.result.ok, true)
  assert.equal(withDoc.result.daemonStatus, "Idle")

  // The same length with no document at all must also stay cheap and refuse.
  const withoutDoc = fastest(prefix)
  assert.ok(withoutDoc.best < 100, `refusal took ${withoutDoc.best} ms`)
  assert.equal(withoutDoc.result.ok, false)
})

test("brace-bearing prose no longer spends the sweep's start budget", () => {
  const pretty = '{\n  "daemonStatus": "Idle"\n}'

  // 40 `{x}` fragments used to push the real document's opening brace past
  // MAX_JSON_STARTS, and being pretty-printed it is invisible to the per-line
  // pass too. `{x0}` cannot open a JSON object, so it is skipped for one
  // character now and the document is recovered.
  const prose = Array.from({ length: 40 }, (_, i) => `WARN {x${i}}`).join("\n")
  assert.equal(Model.parseStatus(prose + "\n" + pretty, NOW).daemonStatus, "Idle")

  // What still exceeds the cap is 40 genuine JSON objects ahead of the
  // document — each one is a plausible start. That fails safely: a parse
  // error, never an invented status.
  const objects = Array.from({ length: 40 }, (_, i) => `WARN ${JSON.stringify({ x: i })}`).join("\n")
  let status
  assert.doesNotThrow(() => {
    status = Model.parseStatus(objects + "\n" + pretty, NOW)
  })
  assert.equal(status.ok, false)
  assert.equal(status.unavailable, true)
  assert.equal(status.daemonStatus, "Unknown")
  assert.equal(status.statusText, "Status error")
  assert.equal(status.error, "Failed to parse netbird status")

  // Fewer than the cap and the same document is recovered.
  const few = Array.from({ length: 5 }, (_, i) => `WARN ${JSON.stringify({ x: i })}`).join("\n")
  assert.equal(Model.parseStatus(few + "\n" + pretty, NOW).daemonStatus, "Idle")
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
    Model.extractAuthUrl("Use this URL to log in: https://netbird.example:443 then https://idp.netbird.example/device", "https://netbird.example:443"),
    "https://idp.netbird.example/device"
  )
  // The same sentence without NetBird's actual phrasing is not a prompt at all.
  assert.equal(Model.extractAuthUrl("log in at https://idp.netbird.example/device", ""), "")
  assert.equal(Model.extractAuthUrl("", ""), "")
})

// --- daemon reachability ----------------------------------------------------

// Verified against the real CLI: with the daemon socket gone, `netbird status`
// never returns — it retries forever — so `timeout` firing is the signal.
test("daemonProbe treats a timeout as the daemon being gone", () => {
  assert.deepEqual(Model.daemonProbe(124, ""), { daemonDown: true, reason: "timeout" })
  // 128+9: the KILL after `timeout -k` was what ended it.
  assert.deepEqual(Model.daemonProbe(137, ""), { daemonDown: true, reason: "timeout" })
  assert.equal(Model.daemonProbe("124", "").daemonDown, true)
})

test("daemonProbe recognises a failed dial to the daemon address", () => {
  const unix = 'rpc error: dial unix /var/run/netbird.sock: connect: no such file or directory'
  const refused = 'transport: Error while dialing: dial tcp 127.0.0.1:59999: connect: connection refused'
  const denied = 'dial unix /var/run/netbird.sock: connect: permission denied'
  for (const err of [unix, refused, denied]) {
    assert.deepEqual(Model.daemonProbe(1, err), { daemonDown: true, reason: "unreachable" })
  }
  assert.equal(Model.daemonProbe(1, "is the daemon running?").daemonDown, true)
  assert.equal(Model.daemonProbe(1, "failed to connect to daemon").daemonDown, true)
  // The same phrases on stdout are the CLI's output, not a diagnosis of it.
  assert.equal(Model.daemonProbe(1, "", "is the daemon running?").daemonDown, false)
})

// The trap a competing plugin fell into: matching the words "connection error"
// anywhere. A healthy daemon prints them during ordinary peer handshakes, and
// calling that "daemon down" backs the poll off and tells the user to restart a
// service that is running fine.
test("daemonProbe does not call a healthy daemon down", () => {
  assert.deepEqual(Model.daemonProbe(0, ""), { daemonDown: false, reason: "" })
  assert.equal(Model.daemonProbe(1, "peer reported a connection error during handshake").daemonDown, false)
  assert.equal(Model.daemonProbe(1, "connection error: desc = transport is closing").daemonDown, false)
  assert.equal(Model.daemonProbe(1, "context deadline exceeded").daemonDown, false)
  assert.equal(Model.daemonProbe(2, "some other failure").daemonDown, false)
})

// A healthy daemon quotes dial failures inside its own JSON — an unreachable
// relay lands in relays.details[].error. Reading those as evidence about the
// daemon itself declared a working tunnel dead.
test("daemonProbe never calls a daemon down that answered", () => {
  const healthy = JSON.stringify({
    daemonStatus: "Connected",
    peers: { total: 1, connected: 1, details: [] },
    management: { url: "https://netbird.example", connected: true, error: "" },
    relays: { total: 1, available: 0, details: [{ uri: "rels://r", available: false, error: "dial tcp 1.2.3.4:443: connect: connection refused" }] }
  })

  assert.deepEqual(Model.daemonProbe(0, "", healthy), { daemonDown: false, reason: "" })
  // Noise on stderr does not outvote a document on stdout either.
  assert.deepEqual(Model.daemonProbe(0, "connection error: desc = transport is closing", healthy), { daemonDown: false, reason: "" })
  assert.deepEqual(Model.daemonProbe(0, "dial unix /var/run/netbird.sock: connect: no such file or directory", healthy), { daemonDown: false, reason: "" })
  // Management error quoted in the document is the daemon reporting, not the
  // daemon missing.
  const mgmtErr = JSON.stringify({ daemonStatus: "Connected", management: { connected: false, error: "dial tcp 10.0.0.1:443: connect: connection refused" } })
  assert.equal(Model.daemonProbe(0, "", mgmtErr).daemonDown, false)
})

test("daemonProbe reads dial failures from stderr, not from stdout", () => {
  const dial = "dial unix /var/run/netbird.sock: connect: no such file or directory"
  // On stderr, with no document to contradict it: the daemon is missing.
  assert.deepEqual(Model.daemonProbe(1, dial), { daemonDown: true, reason: "unreachable" })
  // The same text arriving on stdout is output, not diagnosis.
  assert.deepEqual(Model.daemonProbe(1, "", dial), { daemonDown: false, reason: "" })
  // A timeout still wins when nothing parsed.
  assert.deepEqual(Model.daemonProbe(124, "", ""), { daemonDown: true, reason: "timeout" })
  // …but not over a document that did parse, which can only mean it answered.
  assert.equal(Model.daemonProbe(124, "", '{"daemonStatus":"Connected"}').daemonDown, false)
  // Non-status JSON is not an answer.
  assert.equal(Model.daemonProbe(1, dial, '{"error":"permission denied"}').daemonDown, true)
})

// The literal stderr the CLI produced when pointed at a missing socket, kept
// verbatim as a regression guard: this is the shape the matcher has to survive,
// and it is dense with the words a looser matcher would trip on.
const REAL_TIMEOUT_STDERR = "2026-08-30T11:17:10.390-07:00 INFO ./caller_not_available:0: 2026/08/30 11:17:10 WARNING: [core] [Channel #1 SubChannel #2] grpc: addrConn.createTransport failed to connect to {Addr: \"/tmp/nonexistent.sock\", ServerName: \"localhost\", Attributes: {\"<%!p(networktype.keyType=grpc.internal.transport.networktype)>\": \"unix\" }, }. Err: connection error: desc = \"transport: Error while dialing: dial unix /tmp/nonexistent.sock: connect: no such file or directory\"\n2026-08-30T11:17:11.391-07:00 INFO ./caller_not_available:0: 2026/08/30 11:17:11 WARNING: [core] [Channel #1 SubChannel #2] grpc: addrConn.createTransport failed to connect to {Addr: \"/tmp/nonexistent.sock\", ServerName: \"localhost\", Attributes"

test("the stderr a real missing-socket run produced maps to daemon down", () => {
  // As it actually happened: timeout fired, so the exit code alone settles it.
  assert.deepEqual(Model.daemonProbe(124, REAL_TIMEOUT_STDERR, ""), { daemonDown: true, reason: "timeout" })
  // And on its own merits, without the timeout exit, the dial failure is there.
  assert.deepEqual(Model.daemonProbe(1, REAL_TIMEOUT_STDERR, ""), { daemonDown: true, reason: "unreachable" })
  // It contains "connection error", which must not be what decided it.
  assert.ok(/connection error/i.test(REAL_TIMEOUT_STDERR))
  assert.equal(Model.daemonProbe(1, "connection error: desc = whatever").daemonDown, false)
  // Even this, behind a document, is a daemon that answered.
  assert.equal(Model.daemonProbe(1, REAL_TIMEOUT_STDERR, '{"daemonStatus":"Connected"}').daemonDown, false)
})

test("the poll cadence widens while down and snaps back on recovery", () => {
  const interval = 30
  // Five failing polls in a row at the default cadence.
  const whileDown = [1, 2, 3, 4, 5].map((n) => Model.pollDelaySec(true, interval, n))
  assert.deepEqual(whileDown, [30, 30, 30, 40, 60])
  // Never below the healthy cadence, and never above the cap.
  for (const d of whileDown) {
    assert.ok(d >= interval)
    assert.ok(d <= 60)
  }
  // Monotonic: a longer outage never polls more eagerly than a shorter one.
  for (let i = 1; i < whileDown.length; i++) assert.ok(whileDown[i] >= whileDown[i - 1])
  // The first good poll clears the counter, and the cadence is the plain
  // interval again — not a lingering 60.
  assert.equal(Model.pollDelaySec(false, interval, 0), interval)
  assert.equal(Model.pollDelaySec(false, interval, 5), interval)
})

// Backing off must never mean polling a dead daemon more often than a live one.
test("pollDelaySec never dips below the configured cadence", () => {
  assert.deepEqual([1, 2, 3, 4, 5, 6].map((n) => Model.pollDelaySec(true, 30, n)), [30, 30, 30, 40, 60, 60])
  // At the 5 s floor the backoff is free to start at its own first step.
  assert.deepEqual([1, 2, 3, 4, 5].map((n) => Model.pollDelaySec(true, 5, n)), [5, 10, 20, 40, 60])
  // A slower cadence than the cap stays put throughout.
  assert.deepEqual([1, 5, 99].map((n) => Model.pollDelaySec(true, 300, n)), [300, 300, 300])
  // Healthy: always the configured interval, whatever the failure count says.
  for (const n of [0, 1, 99]) assert.equal(Model.pollDelaySec(false, 30, n), 30)
  // Nonsense intervals fall back to the default rather than to zero.
  for (const bad of [0, -1, undefined, null, "x"]) {
    assert.equal(Model.pollDelaySec(false, bad, 1), 30)
    assert.ok(Model.pollDelaySec(true, bad, 1) >= 30)
  }
})

test("backoffDelaySec doubles to a cap and never runs backwards", () => {
  assert.deepEqual([1, 2, 3, 4, 5, 6].map(Model.backoffDelaySec), [5, 10, 20, 40, 60, 60])
  // Out-of-range and nonsense inputs land on the first step, not on zero.
  for (const bad of [0, -3, undefined, null, "x", NaN]) {
    assert.equal(Model.backoffDelaySec(bad), 5)
  }
  // A long outage must not overflow the shift into something small or negative.
  for (const n of [40, 200, 100000]) {
    assert.equal(Model.backoffDelaySec(n), 60)
  }
})

// --- verification code ------------------------------------------------------

test("extractVerificationCode reads the sentence the CLI actually prints", () => {
  assert.equal(Model.extractVerificationCode("and enter the code ABCD-EFGH to authenticate."), "ABCD-EFGH")
  assert.equal(Model.extractVerificationCode("Enter the code WXYZ1234 to authenticate"), "WXYZ1234")
  assert.equal(Model.extractVerificationCode("...and enter the code   K7P-2QM   to authenticate."), "K7P-2QM")
  assert.equal(Model.extractVerificationCode(""), "")
  assert.equal(Model.extractVerificationCode(null), "")
})

test("extractVerificationCode ignores addresses and URLs", () => {
  // No sentence at all — nothing to take.
  assert.equal(Model.extractVerificationCode("https://idp.example/activate?user_code=ABCD-EFGH"), "")
  assert.equal(Model.extractVerificationCode("connected to 100.64.0.9"), "")
  // The sentence, but with something that is not a code where the code goes.
  assert.equal(Model.extractVerificationCode("enter the code https://idp.example/x to authenticate"), "")
  assert.equal(Model.extractVerificationCode("enter the code 10.0.0.1 to authenticate"), "")
  assert.equal(Model.extractVerificationCode("enter the code ab to authenticate"), "")
})

test("loginProgress surfaces the code line by line and keeps showing it", () => {
  const lines = [
    "Please do the SSO login in your browser.",
    "If your browser didn't open automatically, use this URL to log in:",
    "",
    "https://idp.example/activate",
    "",
    "and enter the code ABCD-EFGH to authenticate.",
    "Waiting for authentication…"
  ]
  let buffer = ""
  const seen = []
  for (const line of lines) {
    const progress = Model.loginProgress(buffer, line, "https://netbird.example:443")
    buffer = progress.buffer
    seen.push({ url: progress.url, code: progress.code })
  }

  // The URL is reported once, on the line that completed the prompt.
  assert.equal(seen.filter((s) => s.url !== "").length, 1)
  assert.equal(seen[3].url, "https://idp.example/activate")
  // The code appears when its line arrives and keeps being reported after,
  // because it is displayed for the life of the login rather than acted on.
  assert.deepEqual(seen.slice(0, 5).map((s) => s.code), ["", "", "", "", ""])
  assert.equal(seen[5].code, "ABCD-EFGH")
  assert.equal(seen[6].code, "ABCD-EFGH")
})

// --- peer filtering ---------------------------------------------------------

const FILTER_PEERS = [
  { name: "atlas", fqdn: "atlas.netbird.example", ip: "100.64.12.5", connectionType: "P2P", status: "Connected" },
  { name: "builder", fqdn: "builder.netbird.example", ip: "100.70.4.16", connectionType: "Relayed", status: "Connecting" },
  { name: "desktop-oslo", fqdn: "desktop-oslo.netbird.example", ip: "100.64.31.88", connectionType: "", status: "Idle" },
  { name: "phone-ada", fqdn: "phone-ada.netbird.example", ip: "100.99.7.201", connectionType: "", status: "Disconnected" }
]
const names = (list) => list.map((p) => p.name)

test("filterPeers returns everything for an empty query", () => {
  for (const q of ["", "   ", undefined, null]) {
    assert.deepEqual(names(Model.filterPeers(FILTER_PEERS, q)), ["atlas", "builder", "desktop-oslo", "phone-ada"])
  }
  // A copy, not the caller's array.
  const out = Model.filterPeers(FILTER_PEERS, "")
  out.pop()
  assert.equal(FILTER_PEERS.length, 4)
  assert.deepEqual(Model.filterPeers(null, "x"), [])
})

test("filterPeers matches name, fqdn, address, transport and state", () => {
  assert.deepEqual(names(Model.filterPeers(FILTER_PEERS, "atlas")), ["atlas"])
  assert.deepEqual(names(Model.filterPeers(FILTER_PEERS, "netbird.example")).length, 4)
  assert.deepEqual(names(Model.filterPeers(FILTER_PEERS, "relayed")), ["builder"])
  assert.deepEqual(names(Model.filterPeers(FILTER_PEERS, "idle")), ["desktop-oslo"])
  // An address prefix is the way you actually hunt for a peer.
  assert.deepEqual(names(Model.filterPeers(FILTER_PEERS, "100.64.")), ["atlas", "desktop-oslo"])
  assert.deepEqual(names(Model.filterPeers(FILTER_PEERS, "100.99.7.201")), ["phone-ada"])
})

test("filterPeers is case-insensitive and ANDs its tokens", () => {
  assert.deepEqual(names(Model.filterPeers(FILTER_PEERS, "ATLAS")), ["atlas"])
  assert.deepEqual(names(Model.filterPeers(FILTER_PEERS, "P2p")), ["atlas"])
  // Both tokens must hit the same peer.
  assert.deepEqual(names(Model.filterPeers(FILTER_PEERS, "builder relayed")), ["builder"])
  assert.deepEqual(names(Model.filterPeers(FILTER_PEERS, "atlas relayed")), [])
  assert.deepEqual(names(Model.filterPeers(FILTER_PEERS, "  100.64.   connected  ")), ["atlas"])
  assert.deepEqual(names(Model.filterPeers(FILTER_PEERS, "nothingmatches")), [])
})

test("filterPeers survives malformed peers", () => {
  const messy = [null, undefined, {}, { name: "ok" }]
  assert.doesNotThrow(() => Model.filterPeers(messy, "ok"))
  assert.deepEqual(Model.filterPeers(messy, "ok").length, 1)
  assert.equal(Model.peerHaystack(null), "")
  // Absent fields collapse to empty, so the haystack has runs of spaces. That
  // is harmless: tokens are split on whitespace and so never contain one.
  const hay = Model.peerHaystack({ name: "A", ip: "1.2.3.4" })
  assert.equal(hay.includes("a"), true)
  assert.equal(hay.includes("1.2.3.4"), true)
  assert.equal(hay, hay.toLowerCase())
  assert.deepEqual(Model.filterPeers([{ name: "A", ip: "1.2.3.4" }], "a 1.2.3.4").length, 1)
})

// --- networks ---------------------------------------------------------------

function textFixture(name) {
  return fs.readFileSync(path.join(FIXTURES, name + ".txt"), "utf8")
}

// The fixtures reproduce the 0.77.1 printer in client/cmd/networks.go:
//   "\n  - ID: %s\n    Network: %s\n    Status: %s\n"        (network route)
//   "\n  - ID: %s\n    Domains: %s\n    Status: %s\n"        (domain route)
test("parseNetworksList reads network routes and their selection", () => {
  const networks = Model.parseNetworksList(textFixture("networks-mixed"))

  assert.equal(networks.length, 3)
  assert.deepEqual(networks.map((n) => n.id), ["office-lan", "datacentre", "full-tunnel"])
  assert.deepEqual(networks.map((n) => n.selected), [true, false, false])
  assert.equal(networks[0].network, "10.10.0.0/16")
  // A default route is just a network whose range is 0.0.0.0/0 — NetBird has
  // no separate exit-node concept.
  assert.equal(networks[2].network, "0.0.0.0/0")
  assert.deepEqual(networks[0].domains, [])
  assert.equal(Model.selectedNetworkCount(networks), 1)
  assert.equal(Model.networkDetail(networks[0]), "10.10.0.0/16")
})

test("parseNetworksList reads domain routes and their resolved addresses", () => {
  const networks = Model.parseNetworksList(textFixture("networks-domains"))

  assert.equal(networks.length, 2)
  assert.deepEqual(networks[0].domains, ["app.example", "api.example"])
  assert.equal(networks[0].selected, true)
  assert.equal(networks[0].network, "")
  assert.deepEqual(networks[0].resolvedIps, [
    { domain: "app.example", ips: ["203.0.113.10", "203.0.113.11"] },
    { domain: "api.example", ips: ["203.0.113.20"] }
  ])
  // "Resolved IPs: -" means none, not a resolution to the string "-".
  assert.deepEqual(networks[1].resolvedIps, [])
  assert.equal(Model.networkDetail(networks[0]), "app.example, api.example")
})

test("parseNetworksList yields nothing rather than phantom rows", () => {
  assert.deepEqual(Model.parseNetworksList(textFixture("networks-empty")), [])
  for (const raw of ["", "   ", null, undefined, "WARNING failed to open log file\nrandom\n"]) {
    assert.deepEqual(Model.parseNetworksList(raw), [])
  }
  // Header and stray lines before any "- ID:" can never become a row — the
  // failure mode of the other implementation of this feature.
  const noisy = "WARNING grpc chatter\nAvailable Networks:\nNetwork: 10.0.0.0/8\nStatus: Selected\n"
  assert.deepEqual(Model.parseNetworksList(noisy), [])
  // A field arriving before its ID belongs to nothing.
  const ordered = "Available Networks:\n\n  - ID: real\n    Network: 10.0.0.0/8\n    Status: Selected\n"
  assert.deepEqual(Model.parseNetworksList(ordered).map((n) => n.id), ["real"])
  assert.equal(Model.selectedNetworkCount(null), 0)
  assert.equal(Model.networkDetail(null), "")
})

// `-a` is the whole point: upstream's select replaces by default, so a
// single-row toggle without it silently deselects everything else.
test("network commands carry the append flag exactly where they must", () => {
  assert.deepEqual(Model.networksListCommand(), ["timeout", "-k", "2", "8", "netbird", "networks", "list"])
  assert.deepEqual(Model.networksSelectCommand("x"), ["timeout", "-k", "2", "8", "netbird", "networks", "select", "-a", "x"])
  assert.deepEqual(Model.networksDeselectCommand("x"), ["timeout", "-k", "2", "8", "netbird", "networks", "deselect", "x"])
  // "all" is special-cased upstream ahead of the flag, so -a would be noise.
  assert.deepEqual(Model.networksSelectAllCommand(), ["timeout", "-k", "2", "8", "netbird", "networks", "select", "all"])
  assert.deepEqual(Model.networksDeselectAllCommand(), ["timeout", "-k", "2", "8", "netbird", "networks", "deselect", "all"])
  assert.equal(Model.networksSelectCommand("x").indexOf("-a") !== -1, true)
  assert.equal(Model.networksSelectAllCommand().indexOf("-a"), -1)
  assert.equal(Model.networksDeselectCommand("x").indexOf("-a"), -1)
  // Ids are stringified, never interpolated into a shell string.
  assert.deepEqual(Model.networksSelectCommand(42).slice(-2), ["-a", "42"])
})

// --- peer detail ------------------------------------------------------------

test("formatBytes uses binary steps and stays readable", () => {
  assert.equal(Model.formatBytes(0), "0 B")
  assert.equal(Model.formatBytes(512), "512 B")
  assert.equal(Model.formatBytes(1024), "1.0 KiB")
  assert.equal(Model.formatBytes(1536), "1.5 KiB")
  assert.equal(Model.formatBytes(1048576), "1.0 MiB")
  // Past three digits the decimal is noise.
  assert.equal(Model.formatBytes(187000000), "178 MiB")
  assert.equal(Model.formatBytes(5e12), "4.5 TiB")
  for (const bad of [-1, "x", undefined, null, NaN]) assert.equal(Model.formatBytes(bad), "")
})

test("connectionSummary names the relay a relayed peer is using", () => {
  assert.equal(Model.connectionSummary({ connectionType: "P2P" }), "P2P")
  assert.equal(
    Model.connectionSummary({ connectionType: "Relayed", relayAddress: "rels://relay.netbird.example:443" }),
    "Relayed via relay.netbird.example"
  )
  // Relayed with no address still says relayed rather than inventing a host.
  assert.equal(Model.connectionSummary({ connectionType: "Relayed", relayAddress: "" }), "Relayed")
  assert.equal(Model.connectionSummary({ connectionType: "" }), "")
  assert.equal(Model.connectionSummary(null), "")
})

test("iceSummary shows the negotiated pair, local first", () => {
  assert.equal(Model.iceSummary({ iceLocal: "host", iceRemote: "srflx" }), "host → srflx")
  assert.equal(
    Model.iceSummary({ iceLocal: "host", iceRemote: "srflx", iceLocalEndpoint: "10.0.0.2:51820", iceRemoteEndpoint: "203.0.113.5:51820" }),
    "host (10.0.0.2:51820) → srflx (203.0.113.5:51820)"
  )
  // A half-known pair is still worth showing.
  assert.equal(Model.iceSummary({ iceLocal: "host", iceRemote: "" }), "host → ?")
  assert.equal(Model.iceSummary({ iceLocal: "", iceRemote: "" }), "")
  assert.equal(Model.iceSummary(null), "")
})

test("relativeSince turns a timestamp into how long ago it was", () => {
  const at = "2026-08-30T00:00:00Z"
  const t = Date.parse(at)
  assert.equal(Model.relativeSince(at, t + 3 * 60 * 1000), "3m ago")
  assert.equal(Model.relativeSince(at, t + (2 * 3600 + 5 * 60) * 1000), "2h 5m ago")
  assert.equal(Model.relativeSince(at, t + 30 * 3600 * 1000), "1d 6h ago")
  // Sub-minute and clock skew both read as now rather than as nonsense.
  assert.equal(Model.relativeSince(at, t + 5000), "just now")
  assert.equal(Model.relativeSince(at, t - 60000), "just now")
  assert.equal(Model.relativeSince("", t), "")
  assert.equal(Model.relativeSince("0001-01-01T00:00:00Z", t), "")
  assert.equal(Model.relativeSince("not a date", t), "")
})

test("versionNotice fires only on a genuine mismatch", () => {
  assert.equal(Model.versionNotice("0.77.1", "0.76.0"), "CLI 0.77.1 · daemon 0.76.0 — restart the daemon")
  assert.equal(Model.versionNotice("0.77.1", "0.77.1"), "")
  // A missing half is not a mismatch worth shouting about.
  assert.equal(Model.versionNotice("0.77.1", ""), "")
  assert.equal(Model.versionNotice("", "0.77.1"), "")
  assert.equal(Model.versionNotice(null, undefined), "")
  assert.equal(Model.versionNotice(" 0.77.1 ", "0.77.1"), "")
})

test("peers carry the detail fields the expander shows", () => {
  const status = Model.parseStatus(fixture("connected"), NOW)
  const atlas = status.peers.find((p) => p.name === "atlas")

  assert.equal(atlas.publicKey, "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789ABCDEF2=")
  assert.equal(atlas.transferReceived, 91234)
  assert.equal(atlas.transferSent, 47810)
  assert.deepEqual(atlas.routes, [])
  assert.equal(atlas.iceLocal, "")
  assert.equal(Model.connectionSummary(atlas), "P2P")
  // Absent sub-objects must not throw on the way to empty strings.
  const bare = Model.peerFromStatus({ fqdn: "x.netbird.example", status: "Idle" })
  assert.equal(bare.iceLocal, "")
  assert.equal(bare.transferReceived, 0)
  assert.deepEqual(bare.routes, [])
})

test("relay details are parsed for the expandable relay list", () => {
  const status = Model.parseStatus(fixture("connected"), NOW)

  assert.equal(status.relays.length, 2)
  assert.equal(status.relays[0].uri, "stun:netbird.example:3478")
  assert.equal(status.relays[0].available, true)
  assert.equal(status.relays[0].error, "")
  // A document with no relay details yields an empty list, not undefined.
  assert.deepEqual(Model.parseStatus('{"daemonStatus":"Connected","relays":{"total":0,"available":0}}', NOW).relays, [])
  assert.deepEqual(Model.parseStatus('{"daemonStatus":"Connected","relays":{"details":"nope"}}', NOW).relays, [])
})

test("commands are the exact argv vectors the service runs", () => {
  // Every daemon call is timeout-wrapped: with the socket gone the CLI retries
  // forever rather than exiting, so without this a poll simply never returns.
  assert.deepEqual(Model.statusCommand(), ["timeout", "-k", "2", "8", "netbird", "status", "--json"])
  assert.deepEqual(Model.downCommand(), ["timeout", "-k", "2", "8", "netbird", "down"])
  // `up` gets a much longer deadline on purpose: it blocks for the whole SSO
  // round trip, and an eight-second cap would kill the login it is there for.
  // --no-browser keeps the SSO URL on stdout so the shell opens it itself.
  assert.deepEqual(Model.upCommand(), ["timeout", "-k", "5", "130", "netbird", "up", "--no-browser"])
  assert.ok(Number(Model.upCommand()[3]) > Number(Model.statusCommand()[3]))
  assert.deepEqual(Model.timeoutPrefix(8, 2), ["timeout", "-k", "2", "8"])
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
// Route fixtures describe LANs and domain routes, so their addresses are
// deliberately RFC 5737 / RFC 1918 / 0.0.0.0/0 rather than CGNAT. They get
// their own rule; the status documents keep the stricter one.
test("text fixtures use only documentation ranges and example domains", () => {
  const names = fs.readdirSync(FIXTURES).filter((n) => n.endsWith(".txt"))
  assert.ok(names.length >= 3)

  for (const name of names) {
    const body = fs.readFileSync(path.join(FIXTURES, name), "utf8")

    for (const match of body.match(/\b\d{1,3}(\.\d{1,3}){3}\b/g) || []) {
      const o = match.split(".").map(Number)
      const documentation = o[0] === 203 && o[1] === 0 && o[2] === 113
      const privateNet = o[0] === 10 || (o[0] === 192 && o[1] === 168) || (o[0] === 172 && o[1] >= 16 && o[1] <= 31)
      const unspecified = match === "0.0.0.0"
      assert.ok(documentation || privateNet || unspecified, `${name}: ${match} is not a documentation or private address`)
    }

    for (const match of body.match(/\b[a-z0-9-]+(\.[a-z0-9-]+)+\b/gi) || []) {
      // Skip anything that is actually a dotted address or a CIDR fragment.
      if (/^\d/.test(match)) continue
      assert.ok(/\.example$/.test(match), `${name}: host ${match} is not under .example`)
    }
  }
})

test("fixtures use only synthetic hosts and CGNAT addresses", () => {
  const names = fs.readdirSync(FIXTURES).filter((n) => n.endsWith(".json"))
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
