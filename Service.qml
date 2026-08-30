import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Everything the panel knows about NetBird, driven entirely by the `netbird`
// CLI. `/var/run/netbird.sock` is world-writable, so status, up and down all
// run as the logged-in user — there is no operator handshake to perform.
Item {
  id: root

  property var settings: ({})

  property bool installed: false
  property bool running: false
  property bool needsLogin: false

  // Optimistic off state so the UI reacts the instant you click, rather than
  // waiting for the next status refresh. _desired is -1 while we just follow
  // the real state, or 0/1 while a toggle is still catching up.
  property int _desired: -1
  readonly property bool active: _desired === -1 ? running : (_desired === 1)
  property bool refreshing: false
  property string daemonStatus: "Unknown"
  property string statusText: "Checking…"
  property string selfName: ""
  property string selfFqdn: ""
  property string selfIp: ""
  property string profileName: ""
  property string managementHost: ""
  property string managementUrl: ""
  property bool managementConnected: false
  property string signalHost: ""
  property bool signalConnected: false
  property int relaysTotal: 0
  property int relaysAvailable: 0
  property int peersTotal: 0
  property int peersConnected: 0
  property string sessionExpiresAt: ""
  property string sessionText: ""
  property string cliVersion: ""
  property string daemonVersion: ""
  property bool degraded: false
  property string degradedText: ""
  property var peers: []
  property string actionStatus: ""
  property string lastError: ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  readonly property bool busy: whichProcess.running || statusProcess.running || actionProcess.running || loginProcess.running
  readonly property string peerCountText: peersTotal > 0 || running ? String(peersConnected) + "/" + String(peersTotal) : ""

  property string _statusOutput: ""
  property string _statusError: ""
  property string _actionOutput: ""
  property string _actionError: ""
  property string _loginOutput: ""
  property string _loginError: ""
  property bool _loginInProgress: false
  property bool _loginUrlOpened: false

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function shortName(fqdn) {
    return Model.shortName(fqdn)
  }

  function copyToClipboard(value) {
    var text = String(value || "")
    if (text === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
  }

  function copyPeerIp(peer) {
    if (!peer) return
    copyToClipboard(peer.ip)
  }

  function copyPeerName(peer) {
    if (!peer) return
    copyToClipboard(peer.name)
  }

  function copyPeerFqdn(peer) {
    if (!peer) return
    copyToClipboard(peer.fqdn)
  }

  function refresh() {
    if (installed) {
      refreshStatus()
      return
    }
    if (!whichProcess.running) {
      refreshing = true
      whichProcess.command = ["which", "netbird"]
      whichProcess.running = true
    }
  }

  function refreshStatus() {
    if (!installed || statusProcess.running) return
    _statusOutput = ""
    _statusError = ""
    refreshing = true
    statusProcess.command = Model.statusCommand()
    statusProcess.running = true
    // Arm on the launch that needs watching and leave it alone after that.
    // Restarting it every refresh pushes the deadline out ahead of a hung
    // process forever once the refresh interval is shorter than the timeout,
    // and refreshIntervalSec goes down to five seconds.
    if (!pollWatchdog.running) pollWatchdog.start()
  }

  function elideStatus(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 140 ? value.substring(0, 137) + "…" : value
  }

  function resetUnavailable(message) {
    running = false
    needsLogin = false
    _desired = -1
    daemonStatus = "Unavailable"
    statusText = message
    selfName = ""
    selfFqdn = ""
    selfIp = ""
    profileName = ""
    managementHost = ""
    managementUrl = ""
    managementConnected = false
    signalHost = ""
    signalConnected = false
    relaysTotal = 0
    relaysAvailable = 0
    peersTotal = 0
    peersConnected = 0
    sessionExpiresAt = ""
    sessionText = ""
    degraded = false
    degradedText = ""
    peers = []
  }

  function parseStatus(raw) {
    var parsed = Model.parseStatus(raw, Date.now())
    if (!parsed.ok) {
      resetUnavailable(parsed.message || "Status error")
      lastError = parsed.error || "Failed to parse netbird status"
      console.warn("netbird", lastError)
      return
    }
    if (parsed.unavailable) {
      resetUnavailable(parsed.message || "Unknown")
      return
    }

    daemonStatus = parsed.daemonStatus
    running = parsed.running
    // Reality caught up to the pending toggle — stop overriding.
    if (_desired !== -1 && running === (_desired === 1)) _desired = -1
    needsLogin = parsed.needsLogin
    selfName = parsed.selfName
    selfFqdn = parsed.selfFqdn
    selfIp = parsed.selfIp
    profileName = parsed.profileName
    managementHost = parsed.managementHost
    managementUrl = parsed.managementUrl
    managementConnected = parsed.managementConnected
    signalHost = parsed.signalHost
    signalConnected = parsed.signalConnected
    relaysTotal = parsed.relaysTotal
    relaysAvailable = parsed.relaysAvailable
    peersTotal = parsed.peersTotal
    peersConnected = parsed.peersConnected
    sessionExpiresAt = parsed.sessionExpiresAt
    sessionText = parsed.sessionText
    cliVersion = parsed.cliVersion
    daemonVersion = parsed.daemonVersion
    degraded = parsed.degraded
    degradedText = parsed.degradedText
    peers = parsed.peers
    statusText = parsed.statusText

    if (running) {
      _loginInProgress = false
      _loginUrlOpened = false
      loginTimeoutTimer.stop()
    }
    lastError = ""
  }

  function summary() {
    return Model.summaryLine({
      unavailable: !installed || daemonStatus === "Unavailable",
      statusText: statusText,
      selfName: selfName,
      selfIp: selfIp,
      peersConnected: peersConnected,
      peersTotal: peersTotal,
      sessionText: sessionText
    })
  }

  function toggleNetbird() {
    if (!installed) return
    if (active) down()
    else up()
  }

  function down() {
    // No progress status here — the greyed icon and hero line already convey
    // the optimistic off; only surface a message if the command fails.
    _desired = 0
    runAction(Model.downCommand())
  }

  function up() {
    if (!installed || loginProcess.running) return
    _loginOutput = ""
    _loginError = ""
    _loginUrlOpened = false
    _loginInProgress = needsLogin
    _desired = needsLogin ? -1 : 1
    if (needsLogin) actionStatus = "Starting NetBird login…"
    loginProcess.command = Model.upCommand()
    loginProcess.running = true
    if (needsLogin) loginTimeoutTimer.restart()
  }

  function runAction(command, label) {
    if (actionProcess.running) return
    _actionOutput = ""
    _actionError = ""
    actionStatus = label || ""
    actionProcess.command = command
    actionProcess.running = true
  }

  function openAuthUrlFrom(text) {
    if (_loginUrlOpened) return true
    var url = Model.extractAuthUrl(text, managementUrl)
    if (url === "") return false
    // Turning on ended up needing browser auth — stop pretending we're up.
    _desired = -1
    _loginUrlOpened = true
    _loginInProgress = false
    loginTimeoutTimer.stop()
    actionStatus = "Finish NetBird login in your browser"
    actionStatusTimer.restart()
    Quickshell.execDetached(["omarchy-launch-browser", url])
    return true
  }

  function handleLoginOutput(data, isError) {
    var text = String(data || "")
    if (isError) _loginError += text + "\n"
    else _loginOutput += text + "\n"
    if (!_loginUrlOpened) openAuthUrlFrom(text)
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // After a fresh boot the startup poll usually lands before the netbird
    // daemon has connected, which left the icon stale until the next periodic
    // refresh. Poll quickly until it shows up, or give up after ~30 seconds.
    id: startupRamp
    property int ticks: 0
    interval: 2000
    repeat: true
    running: true
    onTriggered: {
      ticks += 1
      if (root.running || ticks >= 15) startupRamp.running = false
      else root.refresh()
    }
  }

  Timer {
    id: delayedRefresh
    interval: 600
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    // Every poll is skipped while its own process is still running, so one that
    // never exits — the CLI can hang on a daemon that is coming and going —
    // silently stops the panel refreshing at all, and it stays stopped. Reap
    // anything still running well inside the refresh interval so the next tick
    // starts clean.
    id: pollWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (statusProcess.running) statusProcess.running = false
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    id: loginTimeoutTimer
    interval: 10000
    repeat: false
    onTriggered: {
      if (!root._loginInProgress || root._loginUrlOpened) return
      if (!root.openAuthUrlFrom(String(root._loginOutput) + "\n" + String(root._loginError))) {
        root._loginInProgress = false
        root.actionStatus = "NetBird login link not available yet"
        actionStatusTimer.restart()
      }
    }
  }

  Process {
    id: whichProcess
    running: false
    command: []
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      if (root.installed) root.refreshStatus()
      else {
        root.refreshing = false
        root.resetUnavailable("Not installed")
      }
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function(exitCode) {
      root.refreshing = false
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0) root.parseStatus(stdout)
      else {
        root.resetUnavailable("Disconnected")
        root.lastError = root.elideStatus(stderr)
      }
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true; onStreamFinished: root._actionOutput = text }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true; onStreamFinished: root._actionError = text }
    onExited: function(exitCode) {
      var stdout = String(actionStdout.text || root._actionOutput || "")
      var stderr = String(actionStderr.text || root._actionError || "")
      if (exitCode !== 0) {
        root._desired = -1
        root.lastError = root.elideStatus(stderr || stdout || "netbird command failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.lastError = ""
        root.actionStatus = ""
      }
      delayedRefresh.restart()
    }
  }

  Process {
    id: loginProcess
    running: false
    command: []
    stdout: SplitParser { onRead: function(data) { root.handleLoginOutput(data, false) } }
    stderr: SplitParser { onRead: function(data) { root.handleLoginOutput(data, true) } }
    onExited: function(exitCode) {
      var combined = String(root._loginOutput || "") + "\n" + String(root._loginError || "")
      var opened = root.openAuthUrlFrom(combined)
      if (exitCode !== 0 && !opened) {
        root._desired = -1
        root._loginInProgress = false
        root.lastError = root.elideStatus(combined || "netbird up failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else if (!opened) {
        root.lastError = ""
        root.actionStatus = ""
      }
      delayedRefresh.restart()
    }
  }
}
