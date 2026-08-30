// Pure parsing and formatting for the NetBird widget. QML loads this with
// `import "Model.js" as Model`; `node --test` loads the same file through the
// CommonJS export at the bottom. Nothing here may touch a QML API, and the
// dialect stays ES5-plain so both engines read it the same way.

var DAEMON_CONNECTED = "Connected"

// netbird reports the daemon's own state as one of a small closed set. Three of
// them mean "the daemon is fine, the identity is not" and all three are fixed by
// the same SSO round trip, so they collapse into one needs-login state here.
var LOGIN_STATES = ["NeedsLogin", "SessionExpired", "LoginFailed"]

function intOr(value, fallback) {
  var n = parseInt(String(value), 10)
  return isFinite(n) ? n : fallback
}

// The daemon reports its own address with a mask (100.64.0.1/16) and peers
// without one. Display and clipboard always want the bare address.
function stripCidr(value) {
  var text = String(value || "")
  var slash = text.indexOf("/")
  return slash === -1 ? text : text.substring(0, slash)
}

function trimDot(name) {
  var value = String(name || "")
  return value.charAt(value.length - 1) === "." ? value.slice(0, -1) : value
}

function shortName(fqdn) {
  var clean = trimDot(fqdn)
  if (clean === "") return ""
  return clean.split(".")[0] || clean
}

// Management and signal are configured as full URLs; the hero only has room
// for the host, and the default port carries no information.
function hostFromUrl(url) {
  var text = String(url || "").trim()
  if (text === "") return ""
  var scheme = ""
  var schemeMatch = text.match(/^([a-z][a-z0-9+.-]*):\/\//i)
  if (schemeMatch) {
    scheme = schemeMatch[1].toLowerCase()
    text = text.substring(schemeMatch[0].length)
  }
  var host = text.split("/")[0].split("?")[0]
  if (scheme === "https" || scheme === "rels" || scheme === "") host = host.replace(/:443$/, "")
  if (scheme === "http" || scheme === "rel") host = host.replace(/:80$/, "")
  return host
}

// Go marshals its zero time as year one; netbird uses it for "this never
// happened" on handshakes and on the session clock of an unregistered peer.
function isZeroTime(iso) {
  var text = String(iso || "")
  return text === "" || text.indexOf("0001-01-01") === 0
}

// A peer's row tint and glyph. Lazy connections leave healthy peers sitting in
// Idle for hours, so an offline-looking peer is normal rather than a fault —
// only Disconnected earns the crossed marker.
function peerStatusInfo(status) {
  var value = String(status || "")
  if (value === "Connected") return { glyph: "●", dimmed: false, offline: false }
  if (value === "Connecting") return { glyph: "◍", dimmed: true, offline: false }
  if (value === "Idle") return { glyph: "○", dimmed: true, offline: false }
  if (value === "Disconnected") return { glyph: "⊘", dimmed: true, offline: true }
  return { glyph: "○", dimmed: true, offline: true }
}

// Latency arrives as a Go duration, i.e. an integer count of nanoseconds.
function formatLatency(ns) {
  var n = Number(ns)
  if (!isFinite(n) || n <= 0) return ""
  var ms = n / 1000000
  if (ms >= 100) return Math.round(ms) + " ms"
  if (ms >= 10) return ms.toFixed(1) + " ms"
  return ms.toFixed(2) + " ms"
}

// Coarse "1d 6h" spans: two units is all the hero line can carry, and the
// session clock is a day-scale number nobody reads to the second.
function formatDuration(ms) {
  var total = Math.floor(Number(ms) / 1000)
  if (!isFinite(total) || total <= 0) return ""
  var days = Math.floor(total / 86400)
  var hours = Math.floor((total % 86400) / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  if (days > 0) return hours > 0 ? days + "d " + hours + "h" : days + "d"
  if (hours > 0) return minutes > 0 ? hours + "h " + minutes + "m" : hours + "h"
  if (minutes > 0) return minutes + "m"
  return "under a minute"
}

function sessionExpiryText(iso, nowMs) {
  if (isZeroTime(iso)) return ""
  var at = Date.parse(String(iso))
  if (!isFinite(at)) return ""
  var now = isFinite(Number(nowMs)) ? Number(nowMs) : Date.now()
  var span = formatDuration(at - now)
  return span === "" ? "session expired" : "session expires in " + span
}

function isLoginState(daemonStatus) {
  var value = String(daemonStatus || "")
  for (var i = 0; i < LOGIN_STATES.length; i++) if (LOGIN_STATES[i] === value) return true
  return false
}

function peerFromStatus(peer) {
  var raw = peer || {}
  var fqdn = trimDot(raw.fqdn)
  var ip = stripCidr(raw.netbirdIp)
  var status = String(raw.status || "Unknown")
  var info = peerStatusInfo(status)
  var connectionType = String(raw.connectionType || "")
  return {
    id: String(raw.publicKey || fqdn || ip || status),
    fqdn: fqdn,
    name: shortName(fqdn) || ip || "Unknown",
    ip: ip,
    status: status,
    online: status === "Connected",
    connecting: status === "Connecting",
    offline: info.offline,
    dimmed: info.dimmed,
    glyph: info.glyph,
    // A peer that never came up reports "-" for its transport.
    connectionType: connectionType === "-" ? "" : connectionType,
    latency: formatLatency(raw.latency),
    lastHandshake: isZeroTime(raw.lastWireguardHandshake) ? "" : String(raw.lastWireguardHandshake),
    relayAddress: String(raw.relayAddress || "")
  }
}

// Every consumer reads the same field set whatever happened, so the unknown and
// error paths hand back a fully-populated document rather than a stub.
function emptyStatus() {
  return {
    ok: true,
    unavailable: true,
    daemonStatus: "Unknown",
    running: false,
    needsLogin: false,
    connecting: false,
    statusText: "Unknown",
    message: "Unknown",
    error: "",
    selfName: "",
    selfFqdn: "",
    selfIp: "",
    profileName: "",
    managementUrl: "",
    managementHost: "",
    managementConnected: false,
    managementError: "",
    signalUrl: "",
    signalHost: "",
    signalConnected: false,
    signalError: "",
    relaysTotal: 0,
    relaysAvailable: 0,
    peersTotal: 0,
    peersConnected: 0,
    peers: [],
    sessionExpiresAt: "",
    sessionText: "",
    cliVersion: "",
    daemonVersion: "",
    degraded: false,
    degradedText: ""
  }
}

function degradedTextFor(managementDown, signalDown) {
  if (managementDown && signalDown) return "Management and signal servers unreachable"
  if (managementDown) return "Management server unreachable"
  if (signalDown) return "Signal server unreachable"
  return ""
}

function statusTextFor(status) {
  if (status.needsLogin) return "Needs login"
  if (status.running) return status.degraded ? status.degradedText : "Connected"
  if (status.connecting) return "Connecting…"
  if (status.daemonStatus === "Idle" || status.daemonStatus === "Disconnected") return "Disconnected"
  return status.daemonStatus
}

function peerCountText(status) {
  if (!status) return ""
  return String(status.peersConnected) + "/" + String(status.peersTotal)
}

function parseStatus(raw, nowMs) {
  var text = String(raw || "").trim()
  if (text === "") return emptyStatus()

  // The document is normally the whole of stdout, but a CLI that prepends a
  // warning line still gave us a usable status — carve the outermost braces
  // out and try again before calling it an error.
  var data = null
  try {
    data = JSON.parse(text)
  } catch (e) {
    data = null
  }
  if (data === null) {
    var open = text.indexOf("{")
    var close = text.lastIndexOf("}")
    if (open !== -1 && close > open) {
      try {
        data = JSON.parse(text.substring(open, close + 1))
      } catch (e2) {
        data = null
      }
    }
  }
  if (!data || typeof data !== "object" || (typeof data.length === "number" && !data.daemonStatus)) {
    var broken = emptyStatus()
    broken.ok = false
    broken.statusText = "Status error"
    broken.message = "Status error"
    broken.error = "Failed to parse netbird status"
    return broken
  }

  var result = emptyStatus()
  result.unavailable = false

  var daemonStatus = String(data.daemonStatus || "Unknown")
  result.daemonStatus = daemonStatus
  result.running = daemonStatus === DAEMON_CONNECTED
  result.needsLogin = isLoginState(daemonStatus)
  result.connecting = daemonStatus === "Connecting"

  var management = data.management || {}
  result.managementUrl = String(management.url || "")
  result.managementHost = hostFromUrl(result.managementUrl)
  result.managementConnected = management.connected === true
  result.managementError = String(management.error || "")

  var signal = data.signal || {}
  result.signalUrl = String(signal.url || "")
  result.signalHost = hostFromUrl(result.signalUrl)
  result.signalConnected = signal.connected === true
  result.signalError = String(signal.error || "")

  var relays = data.relays || {}
  result.relaysTotal = intOr(relays.total, 0)
  result.relaysAvailable = intOr(relays.available, 0)

  var peersBlock = data.peers || {}
  result.peersTotal = intOr(peersBlock.total, 0)
  result.peersConnected = intOr(peersBlock.connected, 0)

  // Every peer is listed, whatever its state: with lazy connections on, a
  // healthy network can show a single Connected peer and a dozen Idle ones,
  // and an online-only list would read as an empty network.
  // Go marshals an empty peer slice as null, and a duck-typed length check
  // would walk a string character by character into a list of phantom peers,
  // so nothing but a real array is iterated.
  var details = peersBlock.details
  var peers = []
  if (Array.isArray(details)) {
    for (var i = 0; i < details.length; i++) peers.push(peerFromStatus(details[i]))
  }
  peers.sort(function(a, b) {
    var byName = String(a.name).localeCompare(String(b.name))
    if (byName !== 0) return byName
    return String(a.fqdn).localeCompare(String(b.fqdn))
  })
  result.peers = peers

  result.selfFqdn = trimDot(data.fqdn)
  result.selfIp = stripCidr(data.netbirdIp)
  result.selfName = shortName(result.selfFqdn) || result.selfIp
  result.profileName = String(data.profileName || "")
  result.sessionExpiresAt = isZeroTime(data.sessionExpiresAt) ? "" : String(data.sessionExpiresAt || "")
  result.sessionText = sessionExpiryText(result.sessionExpiresAt, nowMs)
  result.cliVersion = String(data.cliVersion || "")
  result.daemonVersion = String(data.daemonVersion || "")

  // A daemon that says Connected while its control plane is not is the one
  // state worth shouting about: the tunnel looks up but nothing new can join.
  var managementDown = result.running && !result.managementConnected
  var signalDown = result.running && !result.signalConnected
  result.degraded = managementDown || signalDown
  result.degradedText = degradedTextFor(managementDown, signalDown)

  result.statusText = statusTextFor(result)
  result.message = result.statusText
  return result
}

// `netbird up` prints the SSO link on stdout when the peer needs to log in.
// The daemon also logs its own management and signal endpoints, so a URL only
// counts when the surrounding text is actually asking for a browser, and the
// endpoint URL the caller already knows is skipped.
// The two sentences `netbird up` prints when it wants a browser, verbatim from
// the 0.77.1 binary:
//
//   Please do the SSO login in your browser.
//   If your browser didn't open automatically, use this URL to log in:
//   Use this URL to log in:                      (the --no-browser short form)
//
// Nothing weaker counts. An earlier, looser test — any of "login", "browser",
// "authenticate" anywhere — turned `failed to authenticate TLS peer at
// https://status.example/error` into a browser launch.
var SSO_PROMPT = /sso login|use this url to log in/i

// A line that is reporting a failure is never an invitation to click, whatever
// else it contains.
var FAILURE_LINE = /\b(error|errors|failed|failure|fatal|warn|warning|cannot|could not|unable)\b/i

function extractAuthUrl(text, excludeUrl) {
  var value = String(text || "")
  if (!SSO_PROMPT.test(value)) return ""

  var excluded = String(excludeUrl || "")
  var excludedHost = excluded === "" ? "" : hostFromUrl(excluded)
  var lines = value.split(/\r?\n/)

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (FAILURE_LINE.test(line)) continue
    var urls = line.match(/https?:\/\/\S+/g) || []
    for (var j = 0; j < urls.length; j++) {
      var url = urls[j].replace(/[.,;:)\]]+$/, "")
      if (excluded !== "" && url === excluded) continue
      // The management and admin endpoints are printed by the daemon's own
      // chatter; the identity provider is somewhere else.
      if (excludedHost !== "" && hostFromUrl(url) === excludedHost) continue
      return url
    }
  }
  return ""
}

// SplitParser hands `netbird up` output over one line at a time, but the
// prompt and the URL it refers to arrive on different lines — so nothing can
// be decided from a single line. Accumulate, and re-read the whole buffer
// after every line. Pure so the line-by-line sequence is unit-testable.
var LOGIN_BUFFER_LIMIT = 16384

function loginProgress(bufferSoFar, newLine, excludeUrl) {
  var buffer = String(bufferSoFar === undefined || bufferSoFar === null ? "" : bufferSoFar)
  var line = String(newLine === undefined || newLine === null ? "" : newLine)
  buffer = buffer === "" ? line : buffer + "\n" + line
  // The SSO prompt is a handful of lines; anything past the cap is a daemon
  // logging into our pipe, and the tail is the part that still matters.
  if (buffer.length > LOGIN_BUFFER_LIMIT) buffer = buffer.substring(buffer.length - LOGIN_BUFFER_LIMIT)
  return { buffer: buffer, url: extractAuthUrl(buffer, excludeUrl) }
}

function upCommand() {
  // --no-browser keeps the URL on stdout instead of letting the CLI shell out
  // to a browser of its own, so the shell opens it with omarchy-launch-browser.
  return ["netbird", "up", "--no-browser"]
}

function downCommand() {
  return ["netbird", "down"]
}

function statusCommand() {
  return ["netbird", "status", "--json"]
}

// One line describing the whole mesh, for the `status` IPC call.
function summaryLine(status) {
  if (!status) return "Unknown"
  var parts = [status.statusText]
  if (status.selfName !== "") parts.push(status.selfName)
  if (status.selfIp !== "") parts.push(status.selfIp)
  if (!status.unavailable) parts.push(peerCountText(status) + " peers")
  if (status.sessionText !== "") parts.push(status.sessionText)
  return parts.join(" · ")
}

if (typeof module !== "undefined") {
  module.exports = {
    intOr: intOr,
    stripCidr: stripCidr,
    trimDot: trimDot,
    shortName: shortName,
    hostFromUrl: hostFromUrl,
    isZeroTime: isZeroTime,
    isLoginState: isLoginState,
    peerStatusInfo: peerStatusInfo,
    formatLatency: formatLatency,
    formatDuration: formatDuration,
    sessionExpiryText: sessionExpiryText,
    peerFromStatus: peerFromStatus,
    emptyStatus: emptyStatus,
    degradedTextFor: degradedTextFor,
    statusTextFor: statusTextFor,
    peerCountText: peerCountText,
    parseStatus: parseStatus,
    extractAuthUrl: extractAuthUrl,
    loginProgress: loginProgress,
    upCommand: upCommand,
    downCommand: downCommand,
    statusCommand: statusCommand,
    summaryLine: summaryLine
  }
}
