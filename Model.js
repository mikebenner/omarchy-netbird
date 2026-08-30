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
    lastStatusUpdate: isZeroTime(raw.lastStatusUpdate) ? "" : String(raw.lastStatusUpdate),
    relayAddress: String(raw.relayAddress || ""),
    publicKey: String(raw.publicKey || ""),
    transferReceived: intOr(raw.transferReceived, 0),
    transferSent: intOr(raw.transferSent, 0),
    quantumResistance: raw.quantumResistance === true,
    iceLocal: String((raw.iceCandidateType || {}).local || ""),
    iceRemote: String((raw.iceCandidateType || {}).remote || ""),
    iceLocalEndpoint: String((raw.iceCandidateEndpoint || {}).local || ""),
    iceRemoteEndpoint: String((raw.iceCandidateEndpoint || {}).remote || ""),
    routes: Array.isArray(raw.networks) ? raw.networks.map(String) : []
  }
}

// --- peer detail formatting -------------------------------------------------

// Bytes as the daemon counts them, in the units a person reads. Binary steps,
// because that is what a WireGuard counter is measuring.
var BYTE_UNITS = ["B", "KiB", "MiB", "GiB", "TiB"]

function formatBytes(bytes) {
  // Absent is not the same as zero: a missing counter hides its row, while a
  // real zero is worth showing as "0 B".
  if (bytes === undefined || bytes === null || bytes === "") return ""
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) return ""
  if (n < 1024) return Math.round(n) + " B"
  var unit = 0
  var value = n
  while (value >= 1024 && unit < BYTE_UNITS.length - 1) {
    value = value / 1024
    unit++
  }
  return (value >= 100 ? Math.round(value) : value.toFixed(1)) + " " + BYTE_UNITS[unit]
}

// "P2P", or "Relayed via <host>" — the answer to the question the panel exists
// to settle. The relay address is shown as its host, since the scheme and port
// are the same for every relay in a deployment.
function connectionSummary(peer) {
  if (!peer) return ""
  var kind = String(peer.connectionType || "")
  if (kind === "") return ""
  if (kind.toLowerCase() !== "relayed") return kind
  var relay = hostFromUrl(peer.relayAddress)
  return relay === "" ? kind : kind + " via " + relay
}

// The negotiated ICE pair, local first. Endpoints are appended when the daemon
// knows them, since "host → srflx" alone rarely settles an argument.
function iceSummary(peer) {
  if (!peer) return ""
  var local = String(peer.iceLocal || "")
  var remote = String(peer.iceRemote || "")
  if (local === "" && remote === "") return ""
  var left = local === "" ? "?" : local
  var right = remote === "" ? "?" : remote
  var localEnd = String(peer.iceLocalEndpoint || "")
  var remoteEnd = String(peer.iceRemoteEndpoint || "")
  if (localEnd !== "") left += " (" + localEnd + ")"
  if (remoteEnd !== "") right += " (" + remoteEnd + ")"
  return left + " → " + right
}

// "3m ago" for a timestamp in the past. Reuses the duration vocabulary so the
// panel does not grow a second way of saying the same thing.
function relativeSince(iso, nowMs) {
  if (isZeroTime(iso)) return ""
  var at = Date.parse(String(iso))
  if (!isFinite(at)) return ""
  var now = isFinite(Number(nowMs)) ? Number(nowMs) : Date.now()
  var delta = now - at
  if (delta < 0) return "just now"
  var span = formatDuration(delta)
  return span === "" || span === "under a minute" ? "just now" : span + " ago"
}

// --- version skew -----------------------------------------------------------

// A CLI and daemon that disagree is a real support-ticket source, and both
// numbers are already in the status document.
function versionNotice(cliVersion, daemonVersion) {
  var cli = String(cliVersion || "").trim()
  var daemon = String(daemonVersion || "").trim()
  if (cli === "" || daemon === "" || cli === daemon) return ""
  return "CLI " + cli + " · daemon " + daemon + " — restart the daemon"
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
    relays: [],
    peersTotal: 0,
    peersConnected: 0,
    peers: [],
    sessionExpiresAt: "",
    sessionText: "",
    cliVersion: "",
    daemonVersion: "",
    degraded: false,
    degradedText: "",
    versionNotice: ""
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
  // Which relay failed, and why — we showed only the count before, which said
  // something was wrong without saying what.
  var relayDetails = relays.details
  if (Array.isArray(relayDetails)) {
    for (var r = 0; r < relayDetails.length; r++) {
      var entry = relayDetails[r] || {}
      // The URI is shown as-is: relays are addressed as stun:/turns:/rels:,
      // and hostFromUrl is built for the http(s) endpoints, not these.
      result.relays.push({
        uri: String(entry.uri || ""),
        available: entry.available === true,
        error: String(entry.error || "")
      })
    }
  }

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
  result.versionNotice = versionNotice(result.cliVersion, result.daemonVersion)

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
  // The code, unlike the URL, is reported every time it is present: it is
  // displayed for as long as the login runs rather than acted on once.
  return { buffer: buffer, url: url, code: extractVerificationCode(buffer) }
}

// The device code `netbird up --no-browser` prints, from the sentence the
// 0.77.1 binary actually formats: "and enter the code %s to authenticate."
var VERIFICATION_SENTENCE = /enter the code\s+(\S+?)\s+to authenticate/i
// A device code is a short run of letters, digits and dashes.
var VERIFICATION_CODE_SHAPE = /^[A-Za-z0-9][A-Za-z0-9-]{2,}$/
// Long enough to be a hash rather than something a person retypes.
var VERIFICATION_CODE_MAX = 64
// A bare run of hex is a digest, not a device code — those carry a separator
// or at least a digit among letters outside a-f.
var VERIFICATION_LOOKS_LIKE_DIGEST = /^[0-9a-f]{24,}$/i

function extractVerificationCode(text) {
  // The sentence can arrive split across lines, since the buffer joins the
  // CLI's output with newlines. Collapse whitespace before matching so
  // "enter the\ncode ABCD-EFGH to authenticate" is still one sentence.
  var flat = String(text || "").replace(/\s+/g, " ")
  var match = flat.match(VERIFICATION_SENTENCE)
  if (!match) return ""
  var code = trimUrlPunctuation(String(match[1] || ""))
  if (!VERIFICATION_CODE_SHAPE.test(code)) return ""
  if (code.length > VERIFICATION_CODE_MAX) return ""
  // Never a URL, and never something that is only an address.
  if (code.indexOf("://") !== -1) return ""
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(code)) return ""
  // A digest is not a code a person is being asked to type.
  if (VERIFICATION_LOOKS_LIKE_DIGEST.test(code)) return ""
  // Real device codes carry a separator or a digit; an all-letter run of this
  // length is far more likely to be a word from a reworded sentence.
  if (!/[0-9-]/.test(code)) return ""
  return code
}

// --- peer filtering ---------------------------------------------------------

// Every token must match somewhere in the peer, so typing narrows rather than
// widens. Fields searched are the ones on screen plus the transport, which is
// the thing people actually hunt for ("which peers are relayed?").
function peerHaystack(peer) {
  if (!peer) return ""
  return [peer.name, peer.fqdn, peer.ip, peer.connectionType, peer.status]
    .map(function(value) { return String(value === undefined || value === null ? "" : value) })
    .join(" ")
    .toLowerCase()
}

function filterPeers(peers, query) {
  var list = Array.isArray(peers) ? peers : []
  var tokens = String(query === undefined || query === null ? "" : query)
    .toLowerCase()
    .split(/\s+/)
    .filter(function(token) { return token !== "" })
  if (tokens.length === 0) return list.slice()

  var result = []
  for (var i = 0; i < list.length; i++) {
    var hay = peerHaystack(list[i])
    var all = true
    for (var t = 0; t < tokens.length; t++) {
      if (hay.indexOf(tokens[t]) === -1) { all = false; break }
    }
    if (all) result.push(list[i])
  }
  return result
}

// Every call into the daemon is wrapped in `timeout`, because the CLI does not
// give up on its own: with the daemon stopped, `netbird status` retries the
// socket forever, printing gRPC warnings and never exiting. Measured on 0.77.1,
// both for a missing unix socket and a refused TCP address.
//
// `-k` sends KILL that many seconds after the first TERM, for a CLI that
// ignores TERM while inside a retry.
var DAEMON_TIMEOUT_SEC = 8
var DAEMON_KILL_GRACE_SEC = 2

// `up` is the exception. With a valid session it returns in about a second, but
// when SSO is needed it blocks for the whole browser round trip — an eight
// second cap would kill exactly the flow the verification code exists for. Its
// deadline sits just past the service's own 120 s login timer, so our timer
// reports the failure and this only ever acts as the backstop.
var LOGIN_TIMEOUT_SEC = 130
var LOGIN_KILL_GRACE_SEC = 5

function timeoutPrefix(seconds, graceSeconds) {
  return ["timeout", "-k", String(graceSeconds), String(seconds)]
}

function upCommand() {
  // --no-browser keeps the URL on stdout instead of letting the CLI shell out
  // to a browser of its own, so the shell opens it with omarchy-launch-browser.
  return timeoutPrefix(LOGIN_TIMEOUT_SEC, LOGIN_KILL_GRACE_SEC).concat(["netbird", "up", "--no-browser"])
}

function downCommand() {
  return timeoutPrefix(DAEMON_TIMEOUT_SEC, DAEMON_KILL_GRACE_SEC).concat(["netbird", "down"])
}

function statusCommand() {
  return timeoutPrefix(DAEMON_TIMEOUT_SEC, DAEMON_KILL_GRACE_SEC).concat(["netbird", "status", "--json"])
}

// --- networks ---------------------------------------------------------------

function networksListCommand() {
  return timeoutPrefix(DAEMON_TIMEOUT_SEC, DAEMON_KILL_GRACE_SEC).concat(["netbird", "networks", "list"])
}

// `-a` is not optional for a single row. Upstream: "Default mode is replace,
// use -a to append to already selected networks" — so selecting a second
// network without it silently deselects the first, which is precisely the bug
// a competing plugin shipped.
function networksSelectCommand(id) {
  return timeoutPrefix(DAEMON_TIMEOUT_SEC, DAEMON_KILL_GRACE_SEC)
    .concat(["netbird", "networks", "select", "-a", String(id)])
}

function networksDeselectCommand(id) {
  return timeoutPrefix(DAEMON_TIMEOUT_SEC, DAEMON_KILL_GRACE_SEC)
    .concat(["netbird", "networks", "deselect", String(id)])
}

// "all" is special-cased upstream ahead of the append flag, so passing -a here
// would be meaningless — select all deliberately replaces the whole selection.
function networksSelectAllCommand() {
  return timeoutPrefix(DAEMON_TIMEOUT_SEC, DAEMON_KILL_GRACE_SEC)
    .concat(["netbird", "networks", "select", "all"])
}

function networksDeselectAllCommand() {
  return timeoutPrefix(DAEMON_TIMEOUT_SEC, DAEMON_KILL_GRACE_SEC)
    .concat(["netbird", "networks", "deselect", "all"])
}

// `netbird networks list` has no --json, so this parses the text form pinned to
// the 0.77.1 printer (client/cmd/networks.go). Two block shapes, both opening
// on "  - ID:":
//
//     - ID: <id>
//       Network: <cidr>
//       Status: Selected | Not Selected
//
//     - ID: <id>
//       Domains: a.example, b.example
//       Status: Not Selected
//       Resolved IPs:
//         [a.example]: 1.2.3.4, 5.6.7.8
//
// A row is emitted only for a block that actually opened with an ID, so a
// warning line or a stray header can never become a phantom network the user
// could click — the failure mode of the other implementation of this feature.
var NETWORK_ID_LINE = /^\s*-\s*ID:\s*(\S.*?)\s*$/
var NETWORK_FIELD_LINE = /^\s*(Network|Domains|Status|Resolved IPs):\s*(.*?)\s*$/
var NETWORK_RESOLVED_LINE = /^\s*\[([^\]]+)\]:\s*(.*?)\s*$/

function splitList(value) {
  return String(value || "")
    .split(",")
    .map(function(part) { return part.trim() })
    .filter(function(part) { return part !== "" })
}

function parseNetworksList(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw)
  if (text.trim() === "") return []

  var lines = text.split(/\r?\n/)
  var networks = []
  var pending = []
  var current = null

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]

    var idMatch = line.match(NETWORK_ID_LINE)
    if (idMatch) {
      // Held back until the block proves itself complete — see below.
      current = {
        id: idMatch[1],
        network: "",
        domains: [],
        resolvedIps: [],
        selected: false,
        _hasRoute: false,
        _hasStatus: false
      }
      pending.push(current)
      continue
    }
    // Anything before the first "- ID:" is a header or chatter, never a row.
    if (!current) continue

    var resolved = line.match(NETWORK_RESOLVED_LINE)
    if (resolved) {
      current.resolvedIps.push({ domain: resolved[1], ips: splitList(resolved[2]) })
      continue
    }

    var field = line.match(NETWORK_FIELD_LINE)
    if (!field) continue
    var key = field[1]
    var value = field[2]
    if (key === "Network") {
      current.network = value
      current._hasRoute = value !== ""
    } else if (key === "Domains") {
      current.domains = splitList(value)
      current._hasRoute = current.domains.length > 0
    } else if (key === "Status") {
      // Only the two values upstream prints count. Anything else means we are
      // not looking at the table we think we are.
      if (value === "Selected" || value === "Not Selected") {
        current.selected = value === "Selected"
        current._hasStatus = true
      }
    }
  }

  // A row ships only when its block carried an id, a route or domain list, and
  // a Status the printer actually emits. A stray "- ID:" inside warning text
  // therefore yields nothing rather than a clickable phantom network — and a
  // future release that renames these fields degrades to an empty section
  // rather than to rows that lie.
  for (var n = 0; n < pending.length; n++) {
    var entry = pending[n]
    if (!entry._hasRoute || !entry._hasStatus) continue
    delete entry._hasRoute
    delete entry._hasStatus
    networks.push(entry)
  }

  return networks
}

// What the row shows under the name: the route for a network entry, the domain
// list for a domain entry.
function networkDetail(network) {
  if (!network) return ""
  if (network.network) return String(network.network)
  var domains = Array.isArray(network.domains) ? network.domains : []
  return domains.join(", ")
}

// --- bounded text retention -------------------------------------------------

// Keep at most `limit` UTF-16 code units of `text`, dropping from the front.
// Whole lines go first, so a code point cannot be cut — a code point never
// straddles a "\n". The exception is a single line longer than the whole
// budget, where there is no line boundary to land on; there the cut is nudged
// forward off a low surrogate so the result never begins with half a pair.
function trimToLimit(text, limit) {
  var value = String(text === undefined || text === null ? "" : text)
  var cap = parseInt(String(limit), 10)
  if (!isFinite(cap) || cap < 0) return value
  if (value.length <= cap) return value

  var cut = 0
  while (value.length - cut > cap) {
    var nl = value.indexOf("\n", cut)
    if (nl === -1) {
      cut = value.length - cap
      break
    }
    cut = nl + 1
  }

  // A low surrogate here means the cut landed inside a pair; step past it.
  // Costs one code unit and keeps the string well formed.
  if (cut < value.length) {
    var code = value.charCodeAt(cut)
    if (code >= 0xDC00 && code <= 0xDFFF) cut += 1
  }

  return value.substring(cut)
}

// --- networks read/write ordering -------------------------------------------
//
// A list read is only trustworthy if no write happened between its start and
// its finish. Counting writes *started* is not enough: a read that begins while
// an action is in flight captures the already-incremented number, snapshots the
// pre-write selection, and then matches on the way out — applying stale rows
// and clearing the optimistic state. So reads are ordered against writes that
// have *completed*, and a read is not even started while one is in flight.

function canStartNetworksRead(writeInFlight, readInFlight) {
  return writeInFlight !== true && readInFlight !== true
}

function shouldApplyNetworksRead(capturedCompletions, currentCompletions, writeInFlight) {
  // A write that began after this read started invalidates it, whether or not
  // it has finished: its result is not in these rows.
  if (writeInFlight === true) return false
  return Number(capturedCompletions) === Number(currentCompletions)
}

// --- profiles ---------------------------------------------------------------

// `netbird profile list` prints a two-column table:
//
//     NAME     ACTIVE
//     default  ✓
//
// The header is required. Without it we are looking at a warning, an error, or
// a future format — and turning arbitrary lines into profiles would put rows in
// the switcher that run `netbird profile select <that line>` when clicked.
var PROFILE_HEADER = /^(\s*)NAME(\s+)ACTIVE\s*$/

// Read by the header's column geometry, not by splitting on whitespace.
// Profile names are free-form — `Work Account` and `büro` are both legal — so
// taking the first whitespace-delimited token truncated one and dropped the
// other. The ACTIVE column starts at a fixed offset the header itself declares;
// everything left of it is the name.
function parseProfileList(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw)
  var lines = text.split(/\r?\n/)

  var headerAt = -1
  var activeAt = -1
  for (var i = 0; i < lines.length; i++) {
    var header = lines[i].match(PROFILE_HEADER)
    if (!header) continue
    headerAt = i
    activeAt = header[1].length + "NAME".length + header[2].length
    break
  }
  if (headerAt === -1) return []

  var profiles = []
  for (var j = headerAt + 1; j < lines.length; j++) {
    var line = lines[j]
    if (line.trim() === "") continue
    // A row has to reach the ACTIVE column to be a row at all. A trailing
    // "WARNING failed to read cache" is shorter than the table is wide, so it
    // is discarded rather than becoming a selectable profile.
    if (line.length < activeAt) continue
    var namePart = line.substring(0, activeAt)
    // The name column is padded, so a real row always has whitespace where the
    // ACTIVE column begins. That single check is what separates a row from a
    // trailing "WARNING failed to read cache", whose words run straight
    // through the column boundary.
    if (!/\s$/.test(namePart)) continue
    var name = namePart.replace(/\s+$/, "")
    if (name === "" || /^\s/.test(name)) continue
    var cell = line.substring(activeAt).trim()
    profiles.push({ name: name, active: cell !== "" })
  }
  return profiles
}

function profileListCommand() {
  return timeoutPrefix(DAEMON_TIMEOUT_SEC, DAEMON_KILL_GRACE_SEC).concat(["netbird", "profile", "list"])
}

function profileSelectCommand(name) {
  return timeoutPrefix(DAEMON_TIMEOUT_SEC, DAEMON_KILL_GRACE_SEC)
    .concat(["netbird", "profile", "select", String(name)])
}

// --- peer actions -----------------------------------------------------------
//
// Both are argv vectors handed to execDetached, never a shell string: a peer
// address comes from the daemon, and the moment it is interpolated into a
// command line it is one bad character away from being a command.
function sshCommand(address) {
  return ["omarchy-launch-terminal", "ssh", String(address)]
}

function pingCommand(address) {
  return ["omarchy-launch-terminal", "ping", String(address)]
}

// --- admin console ----------------------------------------------------------
//
// Self-hosted deployments serve the dashboard from the management host itself,
// so the management URL is the default. The explicit setting always wins.
// NetBird Cloud serves its management API from api.netbird.io and its dashboard
// from app.netbird.io, so the host cannot simply be reused there.
var HOSTED_MANAGEMENT_HOST = "api.netbird.io"
var HOSTED_CONSOLE_URL = "https://app.netbird.io"

function adminConsoleUrl(managementUrl, override) {
  var explicit = String(override || "").trim()
  if (explicit !== "") return explicit

  var url = String(managementUrl || "").trim()
  if (url === "") return ""

  // Hosted NetBird, on any port.
  if (hostKey(url) === HOSTED_MANAGEMENT_HOST) return HOSTED_CONSOLE_URL

  var schemeMatch = url.match(/^([a-z][a-z0-9+.-]*):\/\//i)
  var scheme = schemeMatch ? schemeMatch[1].toLowerCase() : "https"
  var rest = schemeMatch ? url.substring(schemeMatch[0].length) : url
  var authority = rest.split("/")[0].split("?")[0]
  if (authority === "") return ""

  // Only the default port is dropped; a deployment on 8443 is reachable there
  // and nowhere else. IPv6 literals keep their brackets.
  if (authority.charAt(0) === "[") {
    var close = authority.indexOf("]")
    if (close !== -1) {
      var host6 = authority.substring(0, close + 1)
      var tail6 = authority.substring(close + 1)
      authority = tail6 === ":443" ? host6 : host6 + tail6
    }
  } else {
    authority = authority.replace(/:443$/, "")
  }
  return scheme + "://" + authority
}

function selectedNetworkCount(networks) {
  var list = Array.isArray(networks) ? networks : []
  var total = 0
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].selected === true) total++
  return total
}

// --- daemon reachability ----------------------------------------------------

// `timeout` reports 124 when it fired, and 128+9 = 137 when the KILL after -k
// was what finally ended the process.
var TIMEOUT_EXIT = 124
var TIMEOUT_KILL_EXIT = 137

// A dial that failed against the daemon's own address. Deliberately anchored on
// "dial <transport> <addr>: connect: <reason>" rather than on the words
// "connection error", which a *healthy* daemon also prints — it appears in
// ordinary peer-handshake chatter, and matching it would report a working
// daemon as stopped whenever an unrelated call failed.
var DAEMON_DIAL_FAILURE = /dial\s+(?:unix|tcp)\s+\S+:\s*connect:\s*(?:no such file or directory|connection refused|permission denied)/i
var DAEMON_UNREACHABLE_PHRASE = /(?:failed to connect to (?:the )?daemon|daemon is not running|is the daemon running)/i

// Did this invocation fail because the daemon is not there, as opposed to
// failing for a reason the daemon itself reported?
//
// Two rules keep this from firing on a healthy daemon:
//
//   - A parseable status document on stdout settles it. The daemon answered,
//     so it is running, whatever it had to say about a relay or a management
//     endpoint it could not reach. Those errors are *quoted inside* the
//     document — `relays.details[].error` is routinely a dial failure — and
//     reading them as evidence about the daemon itself inverts their meaning.
//   - Dial failures are matched on stderr only, never on stdout, for the same
//     reason: on stdout that text is the daemon's report, not the CLI's.
function daemonProbe(exitCode, stderr, stdout) {
  var code = parseInt(String(exitCode), 10)

  // The daemon spoke. Nothing else in here can outvote that.
  if (findStatusJson(String(stdout || "").trim())) return { daemonDown: false, reason: "" }

  if (code === TIMEOUT_EXIT || code === TIMEOUT_KILL_EXIT) {
    return { daemonDown: true, reason: "timeout" }
  }
  var err = String(stderr || "")
  if (DAEMON_DIAL_FAILURE.test(err) || DAEMON_UNREACHABLE_PHRASE.test(err)) {
    return { daemonDown: true, reason: "unreachable" }
  }
  return { daemonDown: false, reason: "" }
}

// While the daemon is missing there is nothing to learn from polling at the
// normal rate, and the shell pays for every process it starts. Back off
// 5, 10, 20, 40, 60, 60 … and snap back to the configured interval on the
// first poll that succeeds.
var BACKOFF_BASE_SEC = 5
var BACKOFF_CAP_SEC = 60

// What the poll timer should be set to. While the daemon is missing the delay
// widens, but it never drops below the interval the user configured — with the
// default 30 s cadence a "backoff" of 5 s would poll a dead daemon six times
// more often than a live one.
function pollDelaySec(daemonDown, refreshIntervalSec, consecutiveFailures) {
  var base = parseInt(String(refreshIntervalSec), 10)
  if (!isFinite(base) || base < 1) base = 30
  if (!daemonDown) return base
  return Math.max(base, backoffDelaySec(consecutiveFailures))
}

function backoffDelaySec(consecutiveFailures) {
  var n = parseInt(String(consecutiveFailures), 10)
  if (!isFinite(n) || n < 1) n = 1
  // 2^30 seconds is already past the cap; stop there so the shift cannot
  // overflow into a negative delay on a long outage.
  var steps = Math.min(n - 1, 30)
  return Math.min(BACKOFF_CAP_SEC, BACKOFF_BASE_SEC * Math.pow(2, steps))
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
    trimToLimit: trimToLimit,
    parseStatus: parseStatus,
    extractAuthUrl: extractAuthUrl,
    loginProgress: loginProgress,
    extractVerificationCode: extractVerificationCode,
    filterPeers: filterPeers,
    peerHaystack: peerHaystack,
    daemonProbe: daemonProbe,
    backoffDelaySec: backoffDelaySec,
    pollDelaySec: pollDelaySec,
    timeoutPrefix: timeoutPrefix,
    formatBytes: formatBytes,
    connectionSummary: connectionSummary,
    iceSummary: iceSummary,
    relativeSince: relativeSince,
    versionNotice: versionNotice,
    parseNetworksList: parseNetworksList,
    networkDetail: networkDetail,
    selectedNetworkCount: selectedNetworkCount,
    networksListCommand: networksListCommand,
    networksSelectCommand: networksSelectCommand,
    networksDeselectCommand: networksDeselectCommand,
    networksSelectAllCommand: networksSelectAllCommand,
    networksDeselectAllCommand: networksDeselectAllCommand,
    canStartNetworksRead: canStartNetworksRead,
    shouldApplyNetworksRead: shouldApplyNetworksRead,
    parseProfileList: parseProfileList,
    profileListCommand: profileListCommand,
    profileSelectCommand: profileSelectCommand,
    sshCommand: sshCommand,
    pingCommand: pingCommand,
    adminConsoleUrl: adminConsoleUrl,
    upCommand: upCommand,
    downCommand: downCommand,
    statusCommand: statusCommand,
    summaryLine: summaryLine
  }
}
