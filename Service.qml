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
  // Three poll cadences wide, never under fifteen seconds: long enough that a
  // slow-but-healthy `netbird status` is never mistaken for a hung one.
  readonly property int pollTimeoutSec: Math.max(15, refreshIntervalSec * 3)
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
  // Every line `netbird up` has printed so far, stdout and stderr interleaved
  // in arrival order — the SSO prompt and its URL can land on either stream.
  property string _loginBuffer: ""
  property bool _loginCancelled: false
  property bool _watchdogReaped: false

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
    // Armed here and stopped in onExited, so the deadline always measures the
    // process it would reap. Leaving it armed across a successful poll let an
    // old deadline expire onto a later, healthy one and kill it early.
    pollWatchdog.restart()
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
    // A stopped daemon still reports the peer block it last knew about. Holding
    // on to it would leave the copy keys handing out addresses for a mesh this
    // machine is no longer on, so the list empties with the tunnel.
    peers = parsed.running ? parsed.peers : []
    statusText = parsed.statusText

    if (running) {
      _loginInProgress = false
      loginTimeoutTimer.stop()
    }
    // `_loginUrlOpened` is deliberately NOT cleared here. It is owned by the
    // login attempt — set when the browser opens, reset only by `up()` and
    // `cancelLogin()`. Clearing it on a successful poll let a refresh that
    // landed between the browser opening and `loginProcess` exiting re-arm the
    // guard, and the exit handler then opened the same SSO URL a second time.
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

  // THE TOGGLE RULE. `up()` and `down()` are the only ways to move the tunnel,
  // and every caller goes through them — the hero switch, the `t` key, the bar
  // right-click, and each IPC method. Neither starts while the other's process
  // is still running: a request that arrives on a busy service is refused and
  // returns false, leaving `_desired` alone, because a rejected request must
  // not repaint a switch it did not move. The single exception is `down()`
  // during a pending login, which cancels the login and proceeds — a user
  // saying "off" outranks an SSO flow that otherwise blocks for minutes.
  function toggleNetbird() {
    if (!installed) return false
    return active ? down() : up()
  }

  function down() {
    if (!installed) return false
    // "Off" wins over a login still waiting on a browser.
    if (loginProcess.running) cancelLogin()
    if (actionProcess.running) return false
    // No progress status here — the greyed icon and hero line already convey
    // the optimistic off; only surface a message if the command fails.
    _desired = 0
    desiredTimeout.restart()
    runAction(Model.downCommand())
    return true
  }

  function up() {
    if (!installed || actionProcess.running || loginProcess.running) return false
    _loginOutput = ""
    _loginError = ""
    _loginBuffer = ""
    _loginUrlOpened = false
    // `_loginCancelled` is deliberately not cleared here: it belongs to the
    // process that was cancelled, and only that process's exit handler may
    // consume it. Clearing it would make a cancelled login report a failure
    // the user asked for.
    //
    // In progress whatever the last poll said: the session can expire between
    // polls, so an `up` that turns out to need SSO must still be watched for
    // the prompt. Same reason the timers below are armed unconditionally.
    _loginInProgress = true
    _desired = needsLogin ? -1 : 1
    desiredTimeout.restart()
    if (needsLogin) actionStatus = "Starting NetBird login…"
    loginProcess.command = Model.upCommand()
    loginProcess.running = true
    loginTimeoutTimer.restart()
    loginHardTimeout.restart()
    return true
  }

  // Tear down a login in flight without letting its exit handler report a
  // failure the user caused. Used by `down()` and by the hard timeout.
  function cancelLogin() {
    if (!loginProcess.running) return
    _loginCancelled = true
    loginProcess.running = false
    _loginInProgress = false
    _loginUrlOpened = false
    _loginBuffer = ""
    loginTimeoutTimer.stop()
    loginHardTimeout.stop()
  }

  function runAction(command, label) {
    if (actionProcess.running) return
    _actionOutput = ""
    _actionError = ""
    actionStatus = label || ""
    actionProcess.command = command
    actionProcess.running = true
  }

  function openAuthUrl(url) {
    if (_loginUrlOpened || String(url || "") === "") return false
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

  function openAuthUrlFrom(text) {
    return openAuthUrl(Model.extractAuthUrl(text, managementUrl))
  }

  // One line at a time is not enough to decide anything: the prompt sentence
  // and the URL it points at land on different lines. Keep the running buffer
  // in the model and re-read it after every line.
  function handleLoginOutput(data, isError) {
    // A cancelled login can still flush a line before the process dies. None
    // of it may reopen a flow the user just called off.
    if (_loginCancelled) return
    var text = String(data === undefined || data === null ? "" : data)
    if (isError) _loginError += text + "\n"
    else _loginOutput += text + "\n"
    var progress = Model.loginProgress(_loginBuffer, text, managementUrl)
    _loginBuffer = progress.buffer
    if (!_loginUrlOpened) openAuthUrl(progress.url)
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
    // anything still running so the next tick starts clean.
    //
    // The deadline has to clear the poll cadence, not just be "big": at the
    // five-second floor a flat 15s watchdog is only three ticks wide and will
    // eventually axe a healthy `netbird status` that simply took its time.
    id: pollWatchdog
    interval: root.pollTimeoutSec * 1000
    repeat: false
    onTriggered: {
      if (!statusProcess.running) return
      // Killing our own poll says nothing about the daemon, so flag the exit
      // as ours and let onExited leave the last known state standing.
      root._watchdogReaped = true
      statusProcess.running = false
    }
  }

  Timer {
    // The optimistic switch is only ever cleared by reality agreeing or by the
    // command failing. A `netbird up`/`down` that exits 0 without moving the
    // daemon satisfies neither, and would pin the knob in the wrong position
    // for the rest of the session. Give the pretence a hard deadline; once it
    // lapses the switch follows the daemon again, wherever the daemon is.
    id: desiredTimeout
    interval: 20000
    repeat: false
    onTriggered: root._desired = -1
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    // Armed on every `up`. If the CLI has printed a prompt we somehow did not
    // act on line by line, this is the second look at the whole buffer.
    id: loginTimeoutTimer
    interval: 10000
    repeat: false
    onTriggered: {
      if (!root._loginInProgress || root._loginUrlOpened) return
      if (!root.openAuthUrlFrom(root._loginBuffer)) {
        root._loginInProgress = false
        // Not an error: an `up` on a still-valid session simply connects and
        // never prints a link. Only say something once the user was told a
        // login was starting.
        if (root.needsLogin) {
          root.actionStatus = "NetBird login link not available yet"
          actionStatusTimer.restart()
        }
      }
    }
  }

  Timer {
    // `netbird up --no-browser` blocks until the SSO round trip finishes, and
    // a user who closes the browser without authenticating never finishes it.
    // The process would then sit there holding the toggle gate shut for as
    // long as the CLI's own patience lasts, swallowing every retry. Give it a
    // deadline of our own.
    id: loginHardTimeout
    interval: 120000
    repeat: false
    onTriggered: {
      if (!loginProcess.running) return
      root.cancelLogin()
      root._desired = -1
      root.actionStatus = "NetBird login timed out"
      actionStatusTimer.restart()
      delayedRefresh.restart()
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
      // First, before anything can return: this deadline belongs to the poll
      // that just ended and must not outlive it.
      pollWatchdog.stop()
      root.refreshing = false
      if (root._watchdogReaped) {
        // Our own watchdog ended this poll. The daemon has not told us
        // anything, so every field keeps the value the last good poll gave it.
        root._watchdogReaped = false
        console.warn("netbird status refresh timed out after", root.pollTimeoutSec, "seconds")
        return
      }
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0) {
        root.parseStatus(stdout)
        return
      }
      // A non-zero exit that still printed a whole status document knows more
      // than "Disconnected" does — a NeedsLogin or degraded daemon can exit
      // non-zero and say so in stdout. `Model.parseStatus` now refuses JSON
      // that is not a status document, so `{"error":"permission denied"}`
      // falls through to the error path instead of being read as an
      // all-defaults "Unknown".
      var salvaged = Model.parseStatus(stdout, Date.now())
      if (salvaged.ok && !salvaged.unavailable) {
        root.parseStatus(stdout)
        root.lastError = root.elideStatus(stderr)
        return
      }
      root.resetUnavailable("Disconnected")
      // Whatever the CLI did say is the only explanation the user gets, and it
      // is as likely to be on stdout as on stderr.
      root.lastError = root.elideStatus(stderr || stdout)
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
      loginHardTimeout.stop()
      if (root._loginCancelled) {
        // We ended this one — `down()` or the hard timeout. Its exit code says
        // nothing about the user's request, so report nothing.
        root._loginCancelled = false
        delayedRefresh.restart()
        return
      }
      // Last look at the buffer, and only if nothing was opened yet — the
      // whole point of the guard is that one login opens at most one browser.
      var combined = String(root._loginBuffer || "")
      var opened = root._loginUrlOpened || root.openAuthUrlFrom(combined)
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
