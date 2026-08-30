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

// Is this the shape `netbird status --json` returns, or merely some JSON that
// happened to be on stdout? Without this, `{"error":"permission denied"}`
// parses "successfully" into an all-defaults document and the real error text
// is thrown away.
//
// At the top level `peers` and `management` are sub-objects the daemon always
// fills in, so a null one is not evidence of a status document — the nullable
// Go slice lives one level down at `peers.details`, and that stays welcome
// (see the Array.isArray guard in parseStatus).
function hasStatusObjectField(value, name) {
  var field = value[name]
  return !!field && typeof field === "object" && typeof field.length !== "number"
}

function isStatusDocument(value) {
  if (!value || typeof value !== "object") return false
  if (typeof value.length === "number") return false
  if (typeof value.daemonStatus === "string") return true
  return hasStatusObjectField(value, "peers") || hasStatusObjectField(value, "management")
}

function parseStatusJson(text) {
  try {
    var value = JSON.parse(text)
    return isStatusDocument(value) ? value : null
  } catch (e) {
    return null
  }
}

// The document is normally the whole of stdout, but a CLI that prepends a
// warning line still gave us a usable status. Widening to "first brace through
// last brace" is not enough — a gRPC warning carries braces of its own
// (`WARNING grpc target {Addr:"/var/run/netbird.sock"}`) and swallowing it
// makes the combined span unparseable. So: whole string, then each line alone,
// then a bounded sweep of brace positions against plausible ends.
//
// Both ends of the sweep are capped. Starts were always capped; ends used to
// grow with the line count and were de-duplicated with a linear scan, so a
// long braced prefix cost time quadratic in its length. The document we want
// is whatever the CLI printed last, so only the ends nearest the end of the
// output are worth trying.
var MAX_JSON_STARTS = 32
var MAX_JSON_ENDS = 32

// `{` followed by `"` or `}` (whitespace aside) is the only way a JSON object
// can begin. Anything else — `{Addr:`, `{x0}` — is prose.
function opensJsonObject(text, open) {
  for (var i = open + 1; i < text.length; i++) {
    var ch = text.charAt(i)
    if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") continue
    return ch === "\"" || ch === "}"
  }
  return false
}

function findStatusJson(text) {
  var whole = parseStatusJson(text)
  if (whole) return whole

  // Split on "\n" alone so a line's offset is exactly the sum of the lengths
  // before it — splitting on /\r?\n/ drops a character per CRLF line and
  // slides every later offset out of place. A trailing "\r" is trimmed off
  // before parsing, so it costs nothing.
  var lines = text.split("\n")
  var i
  for (i = 0; i < lines.length; i++) {
    var alone = parseStatusJson(lines[i].trim())
    if (alone) return alone
  }

  // Candidate ends: the last `}` overall, plus the last `}` on each of the
  // final MAX_JSON_ENDS lines that carry one — a document usually ends where
  // its line does.
  var lineCloses = []
  var offset = 0
  for (i = 0; i < lines.length; i++) {
    var close = lines[i].lastIndexOf("}")
    if (close !== -1) lineCloses.push(offset + close)
    offset += lines[i].length + 1
  }
  if (lineCloses.length > MAX_JSON_ENDS) lineCloses = lineCloses.slice(lineCloses.length - MAX_JSON_ENDS)

  var seen = {}
  var ends = []
  var last = text.lastIndexOf("}")
  if (last !== -1) {
    ends.push(last)
    seen[last] = true
  }
  for (i = 0; i < lineCloses.length; i++) {
    if (seen[lineCloses[i]]) continue
    seen[lineCloses[i]] = true
    ends.push(lineCloses[i])
  }

  var starts = 0
  for (var open = text.indexOf("{"); open !== -1 && starts < MAX_JSON_STARTS; open = text.indexOf("{", open + 1)) {
    // A brace that cannot open a JSON object is not worth a candidate, and
    // skipping it costs one character instead of copying tens of kilobytes.
    // Warning text is full of them (`{Addr:"/run/netbird.sock"}`), and letting
    // them consume the start budget was also what hid a real document sitting
    // behind a long braced prefix.
    if (!opensJsonObject(text, open)) continue
    starts++
    for (var e = 0; e < ends.length; e++) {
      if (ends[e] <= open) continue
      var candidate = parseStatusJson(text.substring(open, ends[e] + 1))
      if (candidate) return candidate
    }
  }
  return null
}

function parseStatus(raw, nowMs) {
  var text = String(raw || "").trim()
  if (text === "") return emptyStatus()

  var data = findStatusJson(text)
  if (!data) {
    // Say which kind of failure it was: well-formed JSON that simply is not a
    // status document is a different problem from output that is not JSON, and
    // the caller keeps its own stderr around only for the second case.
    var wasJson = true
    try {
      JSON.parse(text)
    } catch (e) {
      wasJson = false
    }
    var broken = emptyStatus()
    broken.ok = false
    broken.statusText = "Status error"
    broken.message = "Status error"
    broken.error = wasJson
      ? "netbird status output is not a status document"
      : "Failed to parse netbird status"
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

// A comparison key for "is this the same machine we already talk to", as
// opposed to hostFromUrl's display form: credentials and *any* port dropped,
// case folded. The daemon prints its own endpoint on more than one port, so
// `https://netbird.example:8443/device` must match a management URL of
// `https://netbird.example:443`.
function hostKey(url) {
  var text = String(url || "").trim()
  if (text === "") return ""
  text = text.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "")
  text = text.split("/")[0].split("?")[0].split("#")[0]
  var at = text.lastIndexOf("@")
  if (at !== -1) text = text.substring(at + 1)
  if (text.charAt(0) === "[") {
    var close = text.indexOf("]")
    if (close !== -1) text = text.substring(1, close)
  } else {
    var colon = text.indexOf(":")
    if (colon !== -1) text = text.substring(0, colon)
  }
  return text.toLowerCase().replace(/\.$/, "")
}

// A URL at the end of a sentence picks up the sentence's punctuation, but a
// bracket may equally be the URL's own: `https://[2001:db8::1]` ends in a `]`
// that closes its IPv6 literal, and stripping it leaves an address that no
// longer normalises to the host it names. Peel one character at a time, and
// only surrender a closing bracket that has no opener left to match.
function countChar(text, ch) {
  var total = 0
  for (var i = 0; i < text.length; i++) if (text.charAt(i) === ch) total++
  return total
}

function trimUrlPunctuation(url) {
  var text = String(url || "")
  while (text.length > 0) {
    var last = text.charAt(text.length - 1)
    if (".,;:!?".indexOf(last) !== -1) {
      text = text.substring(0, text.length - 1)
      continue
    }
    if (last === "]" && countChar(text, "]") > countChar(text, "[")) {
      text = text.substring(0, text.length - 1)
      continue
    }
    if (last === ")" && countChar(text, ")") > countChar(text, "(")) {
      text = text.substring(0, text.length - 1)
      continue
    }
    break
  }
  return text
}

function extractAuthUrl(text, excludeUrl) {
  var value = String(text || "")
  if (!SSO_PROMPT.test(value)) return ""

  var excluded = String(excludeUrl || "")
  var excludedHost = hostKey(excluded)
  var lines = value.split(/\r?\n/)

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var urls = line.match(/https?:\/\/\S+/g) || []
    // Judge the sentence, not the link inside it: a URL whose own path reads
    // `/error-recovery` says nothing about whether the line is a failure
    // report, and treating it as one loses a legitimate prompt.
    if (FAILURE_LINE.test(line.replace(/https?:\/\/\S+/g, " "))) continue
    for (var j = 0; j < urls.length; j++) {
      var url = trimUrlPunctuation(urls[j])
      if (excluded !== "" && url === excluded) continue
      // The management and admin endpoints are printed by the daemon's own
      // chatter; the identity provider is somewhere else.
      if (excludedHost !== "" && hostKey(url) === excludedHost) continue
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
  var previous = String(bufferSoFar === undefined || bufferSoFar === null ? "" : bufferSoFar)
  var line = String(newLine === undefined || newLine === null ? "" : newLine)
  var buffer = previous === "" ? line : previous + "\n" + line
  // The SSO prompt is a handful of lines; anything past the cap is a daemon
  // logging into our pipe, and the tail is the part that still matters.
  if (buffer.length > LOGIN_BUFFER_LIMIT) buffer = buffer.substring(buffer.length - LOGIN_BUFFER_LIMIT)

  // Report a URL only on the line that first completed the prompt. The URL
  // stays in the buffer forever after, so re-reporting it would make every
  // subsequent line another invitation to open a browser — the once-only
  // guarantee belongs here, not only in the caller's flag.
  var url = extractAuthUrl(buffer, excludeUrl)
  if (url !== "" && extractAuthUrl(previous, excludeUrl) !== "") url = ""
  return { buffer: buffer, url: url }
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
    isStatusDocument: isStatusDocument,
    hostKey: hostKey,
    trimUrlPunctuation: trimUrlPunctuation,
    parseStatus: parseStatus,
    extractAuthUrl: extractAuthUrl,
    loginProgress: loginProgress,
    upCommand: upCommand,
    downCommand: downCommand,
    statusCommand: statusCommand,
    summaryLine: summaryLine
  }
}
