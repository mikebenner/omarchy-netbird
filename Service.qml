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
  // The CLI is present but the daemon behind it is not answering. Distinct
  // from `disconnected`, which means a daemon that answered and said it is off.
  property bool daemonDown: false
  property string daemonDownReason: ""
  // The device code from an SSO login in flight, shown until the login ends.
  property string loginCode: ""
  property var relays: []
  property string versionNotice: ""

  // Networks are listed only while the panel is open — the list costs a process
  // and nobody is looking at it otherwise.
  property var networks: []
  property bool networksLoaded: false
  property bool panelOpen: false
  // Rows the user has just flipped, before the daemon has confirmed. Keyed by
  // network id, same optimistic contract as the tunnel toggle, same deadline.
  property var networkDesired: ({})
  // A list read that started before the most recent mutation is stale by the
  // time it lands: the daemon answered about a selection we have already
  // changed. Bump on every write, capture on every read, discard on mismatch.
  // Reads are ordered against writes that have COMPLETED, and never started
  // while one is in flight. Counting writes *started* let a read that began
  // mid-write match on the way out and apply a pre-write snapshot.
  property int _networkWritesCompleted: 0
  property int _networkReadSeq: 0
  // Set whenever a list result is thrown away for ordering, or a scheduled
  // re-read is refused because something was already running. Every list and
  // action exit checks it, so no interleaving can end with stale rows on
  // screen and nothing queued to correct them.
  property bool _networksDirty: false
  property bool _profilesDirty: false

  property var profiles: []
  property bool profilesLoaded: false
  // True for the whole life of `netbird up`. `_loginInProgress` is cleared the
  // moment the browser opens, so it cannot be what a Cancel affordance is
  // gated on: a URL-only login would leave the process running with no way to
  // stop it. Quickshell terminating this Process signals `timeout`, which
  // forwards to its direct child — verified: TERM to `timeout` takes `netbird`
  // with it, since we exec it directly rather than through a shell.
  readonly property bool loginActive: loginProcess.running
  property var peers: []
  property string actionStatus: ""
  property string lastError: ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  // Three poll cadences wide, never under fifteen seconds: long enough that a
  // slow-but-healthy `netbird status` is never mistaken for a hung one.
  readonly property int pollTimeoutSec: Math.max(15, refreshIntervalSec * 3)
  // Everything that changes the daemon's state, so no two such commands can
  // overlap. Profile selection recycles the engine, which is at least as
  // disruptive as a toggle, so it belongs here too.
  readonly property bool busy: whichProcess.running || statusProcess.running || actionProcess.running
    || loginProcess.running || profileActionProcess.running
  readonly property bool networksBusy: networksProcess.running || networkActionProcess.running
  // Any command that mutates the daemon or its selection. Used to serialise
  // profile switching against tunnel and network work in both directions.
  readonly property bool mutating: actionProcess.running || loginProcess.running
    || networkActionProcess.running || profileActionProcess.running
  readonly property bool profilesBusy: profilesProcess.running || profileActionProcess.running
  readonly property string adminUrl: Model.adminConsoleUrl(managementUrl, setting("adminConsoleUrl", ""))
  // While the daemon is missing there is nothing to poll for; back off instead
  // of starting a process every few seconds inside the shared shell process.
  readonly property int pollIntervalSec: Model.pollDelaySec(daemonDown, refreshIntervalSec, _consecutiveDaemonFailures)
  readonly property string peerCountText: peersTotal > 0 || running ? String(peersConnected) + "/" + String(peersTotal) : ""

  property int _consecutiveDaemonFailures: 0
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
    refreshing = true
    statusStdout.reset()
    statusStderr.reset()
    statusProcess.command = Model.statusCommand()
    statusProcess.running = true
    // Armed here and stopped in onExited, so the deadline always measures the
    // process it would reap. Leaving it armed across a successful poll let an
    // old deadline expire onto a later, healthy one and kill it early.
    pollWatchdog.restart()
  }

  // --- networks -------------------------------------------------------------

  function refreshNetworks() {
    if (!installed || daemonDown || !running || !panelOpen) return false
    // Never read across a write. Refusing here is safe only because the refusal
    // is recorded: the next exit that finds nothing running starts the read.
    if (!Model.canStartNetworksRead(networkActionProcess.running, networksProcess.running)) {
      _networksDirty = true
      return false
    }
    _networksDirty = false
    _networkReadSeq = _networkWritesCompleted
    networksStdout.reset()
    networksStderr.reset()
    networksProcess.command = Model.networksListCommand()
    networksProcess.running = true
    return true
  }

  // Start the read a refusal or a discard owed us, the moment nothing is in
  // the way. Called from every list and action exit.
  function _drainNetworksDirty() {
    if (!_networksDirty) return
    if (!Model.canStartNetworksRead(networkActionProcess.running, networksProcess.running)) return
    refreshNetworks()
  }

  function _drainProfilesDirty() {
    if (!_profilesDirty) return
    if (profilesProcess.running || profileActionProcess.running) return
    refreshProfiles()
  }

  function networkSelected(id) {
    var key = String(id || "")
    var pending = networkDesired[key]
    if (pending !== undefined) return pending === true
    var list = networks || []
    for (var i = 0; i < list.length; i++) {
      if (list[i] && String(list[i].id) === key) return list[i].selected === true
    }
    return false
  }

  function _setNetworkDesired(id, value) {
    // Reassign rather than mutate: QML only sees a var property change when the
    // reference changes, so an in-place write would not repaint the row.
    var next = {}
    for (var key in networkDesired) next[key] = networkDesired[key]
    if (value === null) delete next[String(id)]
    else next[String(id)] = value
    networkDesired = next
  }

  function _runNetworkAction(command) {
    if (!installed || daemonDown || networkActionProcess.running || profileActionProcess.running) return false
    networkActionStdout.reset()
    networkActionStderr.reset()
    networkActionProcess.command = command
    networkActionProcess.running = true
    networkDesiredTimeout.restart()
    return true
  }

  function toggleNetwork(id) {
    var key = String(id || "")
    if (key === "") return false
    var want = !networkSelected(key)
    if (!_runNetworkAction(want ? Model.networksSelectCommand(key) : Model.networksDeselectCommand(key))) return false
    _setNetworkDesired(key, want)
    return true
  }

  function selectAllNetworks() {
    if (!_runNetworkAction(Model.networksSelectAllCommand())) return false
    networkDesired = {}
    return true
  }

  function deselectAllNetworks() {
    if (!_runNetworkAction(Model.networksDeselectAllCommand())) return false
    networkDesired = {}
    return true
  }

  // --- profiles -------------------------------------------------------------

  function refreshProfiles() {
    if (!installed || daemonDown || !panelOpen) return false
    if (profilesProcess.running || profileActionProcess.running) {
      _profilesDirty = true
      return false
    }
    _profilesDirty = false
    profilesStdout.reset()
    profilesStderr.reset()
    profilesProcess.command = Model.profileListCommand()
    profilesProcess.running = true
    return true
  }

  function activeProfile() {
    var list = profiles || []
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].active === true) return String(list[i].name)
    return ""
  }

  function selectProfile(name) {
    var target = String(name || "")
    if (target === "" || target === activeProfile()) return false
    // Serialised against every other command: switching recycles the engine,
    // so it must not overlap a toggle, a login, or a network change — and a
    // stale list must not be the thing being selected from.
    if (!installed || daemonDown || mutating || profilesProcess.running) return false
    actionStatus = "Switching to profile " + target + "…"
    profileActionStdout.reset()
    profileActionStderr.reset()
    profileActionProcess.command = Model.profileSelectCommand(target)
    profileActionProcess.running = true
    return true
  }

  // Both are argv vectors, never a shell string: the address comes from the
  // daemon and must never be handed to something that parses it.
  function sshToPeer(peer) {
    if (!peer || String(peer.ip || "") === "") return false
    Quickshell.execDetached(Model.sshCommand(peer.ip))
    return true
  }

  function pingPeer(peer) {
    if (!peer || String(peer.ip || "") === "") return false
    Quickshell.execDetached(Model.pingCommand(peer.ip))
    return true
  }

  function openAdminConsole() {
    var url = adminUrl
    if (url === "") return false
    Quickshell.execDetached(["omarchy-launch-browser", url])
    return true
  }

  function elideStatus(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 140 ? value.substring(0, 137) + "…" : value
  }

  // The daemon did not answer. Keep saying so, clear everything that came from
  // it, and let the caller's backoff widen — showing the last good peer list
  // next to "daemon is not running" would be worse than showing nothing.
  function enterDaemonDown(reason) {
    _consecutiveDaemonFailures += 1
    daemonDown = true
    daemonDownReason = String(reason || "")
    resetUnavailable("Daemon not running")
    lastError = ""
  }

  function clearDaemonDown() {
    if (!daemonDown && _consecutiveDaemonFailures === 0) return
    daemonDown = false
    daemonDownReason = ""
    _consecutiveDaemonFailures = 0
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
    relays = []
    versionNotice = ""
    networks = []
    networksLoaded = false
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

    // A panel held open across a recovery kept the empty list resetUnavailable
    // installed, because opening was the only trigger. Notice the transition.
    var cameBack = (!running && parsed.running) || (daemonDown && parsed.running)

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
    relays = parsed.relays
    versionNotice = parsed.versionNotice
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
      loginCode = ""
      loginTimeoutTimer.stop()
    }
    if (cameBack && panelOpen) {
      networksRefreshDelay.restart()
      refreshProfiles()
    }
    // `_loginUrlOpened` is deliberately NOT cleared here. It is owned by the
    // login attempt — set when the browser opens, reset only by `up()` and
    // `cancelLogin()`. Clearing it on a successful poll let a refresh that
    // landed between the browser opening and `loginProcess` exiting re-arm the
    // guard, and the exit handler then opened the same SSO URL a second time.
    lastError = ""
  }

  function summary() {
    if (daemonDown) return "Daemon not running"
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
    if (!installed || daemonDown) return false
    return active ? down() : up()
  }

  function down() {
    if (!installed || daemonDown || profileActionProcess.running) return false
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
    if (!installed || daemonDown || profileActionProcess.running || actionProcess.running || loginProcess.running) return false
    _loginBuffer = ""
    _loginUrlOpened = false
    loginCode = ""
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
    loginCode = ""
    loginTimeoutTimer.stop()
    loginHardTimeout.stop()
  }

  function runAction(command, label) {
    if (actionProcess.running) return
    actionStdout.reset()
    actionStderr.reset()
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
    var progress = Model.loginProgress(_loginBuffer, text, managementUrl)
    _loginBuffer = progress.buffer
    if (progress.code !== "") loginCode = progress.code
    if (!_loginUrlOpened) openAuthUrl(progress.url)
  }

  Timer {
    id: refreshTimer
    interval: root.pollIntervalSec * 1000
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
      // Stop the moment the tunnel is up, the budget runs out, or the daemon
      // turns out to be missing — the backoff owns the cadence from there.
      if (root.running || root.daemonDown || ticks >= 15) startupRamp.running = false
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
    stdout: BoundedCollector { id: statusStdout; limit: 262144 }
    stderr: BoundedCollector { id: statusStderr; limit: 262144 }
    onExited: function(exitCode) {
      // First, before anything can return: this deadline belongs to the poll
      // that just ended and must not outlive it.
      pollWatchdog.stop()
      root.refreshing = false
      var stdout = String(statusStdout.tail || "")
      var stderr = String(statusStderr.tail || "")

      if (root._watchdogReaped) {
        // Our own watchdog ended this poll — now only a backstop, since the
        // argv carries its own `timeout`. Treat it the same as that timeout:
        // the daemon told us nothing, and saying nothing is what went wrong
        // before, leaving a stale "Connected" on screen for as long as the
        // daemon stayed down.
        root._watchdogReaped = false
        console.warn("netbird status refresh timed out after", root.pollTimeoutSec, "seconds")
        root.enterDaemonDown("timeout")
        return
      }

      // A clean exit carrying a real status document needs no adjudication:
      // the daemon answered. Asking the probe first was a bug — a healthy
      // daemon quotes dial failures inside its own JSON (an unreachable relay
      // in `relays.details[].error`), and reading those as evidence about the
      // daemon itself declared a working tunnel dead.
      var parsed = exitCode === 0 ? Model.parseStatus(stdout, Date.now()) : null
      if (parsed && parsed.ok && !parsed.unavailable) {
        root.clearDaemonDown()
        root.parseStatus(stdout)
        return
      }

      // No usable answer. Now it is worth asking whether anything was there.
      var probe = Model.daemonProbe(exitCode, stderr, stdout)
      if (probe.daemonDown) {
        root.enterDaemonDown(probe.reason)
        return
      }

      // Deliberately NOT clearing the outage here: only a poll whose stdout
      // parses as a status document counts as recovery. Exit 0 carrying
      // unusable output is not the daemon saying it is back, and treating it
      // as such reset the backoff on every garbage reply.
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
    id: networksProcess
    running: false
    command: []
    stdout: BoundedCollector { id: networksStdout; limit: 65536 }
    stderr: BoundedCollector { id: networksStderr; limit: 16384 }
    onExited: function(exitCode) {
      // Discard a read that started before the most recent write: it describes
      // a selection the user has already changed, and applying it would flip
      // the row back under them.
      // Ordered against completed writes, and rejected outright if a write
      // started while this read was in flight.
      if (!Model.shouldApplyNetworksRead(root._networkReadSeq, root._networkWritesCompleted, networkActionProcess.running)) {
        // Discarded — so the rows on screen are stale and something must go
        // back for the truth.
        root._networksDirty = true
        root._drainNetworksDirty()
        return
      }
      if (exitCode !== 0) {
        root._drainNetworksDirty()
        return
      }
      root.networks = Model.parseNetworksList(String(networksStdout.tail || ""))
      root.networksLoaded = true
      root.networkDesired = {}
      root._drainNetworksDirty()
    }
  }

  Process {
    id: profilesProcess
    running: false
    command: []
    stdout: BoundedCollector { id: profilesStdout; limit: 16384 }
    stderr: BoundedCollector { id: profilesStderr; limit: 16384 }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root._drainProfilesDirty()
        return
      }
      root.profiles = Model.parseProfileList(String(profilesStdout.tail || ""))
      root.profilesLoaded = true
      root._drainProfilesDirty()
    }
  }

  Process {
    id: profileActionProcess
    running: false
    command: []
    stdout: BoundedCollector { id: profileActionStdout; limit: 16384 }
    stderr: BoundedCollector { id: profileActionStderr; limit: 16384 }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = root.elideStatus(
          String(profileActionStderr.tail || "") || String(profileActionStdout.tail || "") || "netbird profile select failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.actionStatus = ""
      }
      // Switching profiles re-cycles the engine: the daemon may come back
      // needing a login on the target profile. Let the ordinary states carry
      // whatever it reports.
      root.profilesLoaded = false
      root._profilesDirty = true
      root._networksDirty = true
      delayedRefresh.restart()
      networksRefreshDelay.restart()
      root._drainProfilesDirty()
    }
  }

  Process {
    id: networkActionProcess
    running: false
    command: []
    stdout: BoundedCollector { id: networkActionStdout; limit: 16384 }
    stderr: BoundedCollector { id: networkActionStderr; limit: 16384 }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.networkDesired = {}
        root.lastError = root.elideStatus(
          String(networkActionStderr.tail || "") || String(networkActionStdout.tail || "") || "netbird networks command failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      }
      // The write is done: from here a read can be trusted again.
      root._networkWritesCompleted += 1
      // Re-read either way: on success to see it, on failure to see the truth.
      root._networksDirty = true
      networksRefreshDelay.restart()
    }
  }

  Timer {
    id: networksRefreshDelay
    interval: 400
    repeat: false
    onTriggered: root.refreshNetworks()
  }

  Timer {
    // Same contract as the tunnel toggle: an optimistic row cannot outlive the
    // daemon's silence, or a command that exits 0 without changing anything
    // would pin the switch.
    id: networkDesiredTimeout
    interval: 20000
    repeat: false
    onTriggered: root.networkDesired = {}
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: BoundedCollector { id: actionStdout; limit: 16384 }
    stderr: BoundedCollector { id: actionStderr; limit: 16384 }
    onExited: function(exitCode) {
      var stdout = String(actionStdout.tail || "")
      var stderr = String(actionStderr.tail || "")
      if (exitCode !== 0) {
        root._desired = -1
        root.lastError = root.elideStatus(stderr || stdout || "netbird command failed")
        if (actionStderr.truncated || actionStdout.truncated) root.lastError += " (output truncated)"
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
      root.loginCode = ""
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
