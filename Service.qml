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
  //
  // "Write" here is any change to what a networks read would return, which
  // includes a profile switch: it moves the whole account under the list, so
  // a read spanning one describes networks that are no longer selectable.
  // Counting only `networks select/deselect` let such a read pass, apply the
  // previous account's rows, and clear the very obligation the switch queued.
  property int _networkGeneration: 0
  property int _networkReadGeneration: 0
  // Set whenever a list result is thrown away for ordering, a scheduled
  // re-read is refused because something was already running, or a corrective
  // read fails. Cleared ONLY when a read successfully applies — clearing it
  // when the read merely *started* let a non-zero exit strand stale rows with
  // nothing queued. Drained through the single-shot timers below, so no
  // interleaving can end dirty with nothing scheduled to correct it.
  property bool _networksDirty: false
  property bool _profilesDirty: false
  // Consecutive corrective reads that failed to apply. At
  // Model.MAX_CORRECTIVE_ATTEMPTS the obligation stops rescheduling itself
  // and waits for a natural trigger — a panel open, an action, a daemon
  // recovery — each of which resets the budget.
  property int _networksAttempts: 0
  property int _profilesAttempts: 0
  // Refusals because another process held the gate, counted separately: they
  // are not the daemon failing, so they get their own generous budget
  // (Model.MAX_BUSY_REFUSALS) rather than sharing — or, as before, sharing
  // nothing and knocking forever.
  property int _networksBusyRefusals: 0
  property int _profilesBusyRefusals: 0
  // The generation counter above orders reads against *writes*. This one
  // orders them against *requests*: every state hook that invalidates a list
  // — a daemon recovery, the tunnel coming up, the panel opening — bumps the
  // epoch, and a read that started before the bump may not clear the
  // obligation the bump created. Without it, a read that began while the
  // daemon was healthy, survived an outage in flight, and exited cleanly
  // after the recovery counted as "applied" (no write had happened, so the
  // generation still matched) and cancelled the post-recovery re-read. Its
  // rows are still displayed — a snapshot is not wrong to show — but the
  // obligation stands and the drain goes back for a current one.
  property int _networksRequestEpoch: 0
  property int _profilesRequestEpoch: 0
  property int _networksReadEpoch: 0
  property int _profilesReadEpoch: 0
  // `profile list --show-id` carries the identity this widget selects by. A
  // CLI too old to know the flag rejects the whole command, so the first such
  // refusal drops the flag for the rest of the session and the retry parses
  // the two-column table instead.
  property bool _profileListShowId: true

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

  // --- corrective list reads ------------------------------------------------
  //
  // Networks and profiles have the same lifecycle: a write makes the displayed
  // list stale, the obligation to re-read it survives everything except a read
  // that actually applies, and the retries are bounded. They used to be
  // written out twice and had already drifted apart — the networks path
  // charged ordering discards against the failure budget, the profiles path
  // charged an empty parse — so both now go through the one set of functions
  // below and the one decision table in `Model.correctiveStep`.
  //
  // `kind` is "networks" or "profiles". The two branches inside each function
  // are property access, nothing more; every rule lives in the model.

  function _correctiveState(kind) {
    return kind === "profiles"
      ? { attempts: _profilesAttempts, busy: _profilesBusyRefusals }
      : { attempts: _networksAttempts, busy: _networksBusyRefusals }
  }

  // Record what an attempt came to, store the next state, and schedule the
  // retry the model asked for — a retry of 0 means "arm nothing": either
  // nothing is owed, or the obligation is waiting on the state hooks below.
  // Returns true only for a read that applied, so the refusal paths can
  // `return _noteCorrective(...)` and still answer false to their caller.
  function _noteCorrective(kind, outcome) {
    var next = Model.correctiveStep(outcome, _correctiveState(kind))
    if (kind === "profiles") {
      _profilesAttempts = next.attempts
      _profilesBusyRefusals = next.busy
      _profilesDirty = next.dirty
      if (next.retryMs > 0) {
        profilesDirtyDrain.interval = next.retryMs
        profilesDirtyDrain.restart()
      }
    } else {
      _networksAttempts = next.attempts
      _networksBusyRefusals = next.busy
      _networksDirty = next.dirty
      if (next.retryMs > 0) {
        networksDirtyDrain.interval = next.retryMs
        networksDirtyDrain.restart()
      }
    }
    return outcome === Model.CORRECTIVE_APPLIED
  }

  // A natural trigger — the panel opening, an action completing, the daemon
  // coming back. Both lists owe a fresh read and both budgets start over.
  function requestLists() {
    requestList("networks")
    requestList("profiles")
  }

  function requestList(kind) {
    if (kind === "profiles") {
      _profilesDirty = true
      _profilesAttempts = 0
      _profilesBusyRefusals = 0
      // Nothing already in flight can satisfy this request.
      _profilesRequestEpoch += 1
      profilesDirtyDrain.interval = Model.CORRECTIVE_PROMPT_MS
      profilesDirtyDrain.restart()
    } else {
      _networksDirty = true
      _networksAttempts = 0
      _networksBusyRefusals = 0
      _networksRequestEpoch += 1
      networksDirtyDrain.interval = Model.CORRECTIVE_PROMPT_MS
      networksDirtyDrain.restart()
    }
  }

  // Start the read a refusal, a discard or a failed corrective read owes us.
  // Reached only through the drain timers — never straight from an exit
  // handler — so a failing daemon is retried on a cadence, not in a tight
  // exit-restart loop.
  function _drainList(kind) {
    if (kind === "profiles") {
      if (!_profilesDirty) return
      refreshProfiles()
    } else {
      if (!_networksDirty) return
      refreshNetworks()
    }
  }

  // The state hooks. A refusal for a state reason arms no timer — re-asking a
  // state that only an event can change is a loop with nothing to gain — so
  // the transition that unblocks it is what re-arms the drain. Without these
  // the obligation stayed set with nothing scheduled, and the section it owned
  // (PROFILES, after the loaded-gate went in) never came back that session.
  onPanelOpenChanged: if (panelOpen) requestLists()
  onDaemonDownChanged: if (!daemonDown && panelOpen) requestLists()
  onRunningChanged: if (running && panelOpen) requestLists()
  onInstalledChanged: if (installed && panelOpen) requestLists()

  // --- networks -------------------------------------------------------------

  // A profile switch recycles the engine onto another account, so it
  // invalidates a networks read exactly as a networks write does: the rows in
  // flight describe the account we just left. Both kinds of write are
  // therefore counted in the same generation, and neither lets a read start.
  readonly property bool _networkWriteInFlight: networkActionProcess.running || profileActionProcess.running

  function refreshNetworks() {
    // State reasons: nothing to retry against, and nothing charged. The hooks
    // above re-arm the drain when the state that blocked it changes.
    if (!installed || daemonDown || !running || !panelOpen) return _noteCorrective("networks", Model.CORRECTIVE_BLOCKED)
    // Never read across a write. Refusing here is safe only because the
    // refusal is recorded and rescheduled — and bounded, so a process that
    // never exits cannot leave the drain knocking forever.
    if (!Model.canStartNetworksRead(_networkWriteInFlight, networksProcess.running)) {
      return _noteCorrective("networks", Model.CORRECTIVE_BUSY)
    }
    // The dirty bit is NOT cleared here. Starting a read fulfils nothing;
    // only its successful apply in onExited does — and only if it started
    // late enough to answer the newest request.
    _networkReadGeneration = _networkGeneration
    _networksReadEpoch = _networksRequestEpoch
    networksStdout.reset()
    networksStderr.reset()
    networksProcess.command = Model.networksListCommand()
    networksProcess.running = true
    return true
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
    // `profile list` reads the on-disk profiles, so it does not need the
    // tunnel up — only a daemon to answer and someone looking.
    if (!installed || daemonDown || !panelOpen) return _noteCorrective("profiles", Model.CORRECTIVE_BLOCKED)
    if (profilesProcess.running || profileActionProcess.running) {
      return _noteCorrective("profiles", Model.CORRECTIVE_BUSY)
    }
    // Not cleared here — only a successful apply in onExited clears it.
    _profilesReadEpoch = _profilesRequestEpoch
    profilesStdout.reset()
    profilesStderr.reset()
    profilesProcess.command = Model.profileListCommand(_profileListShowId)
    profilesProcess.running = true
    return true
  }

  // The display name of the active profile, for the panel. Identity is the id
  // below; this is only ever text on screen.
  function activeProfile() {
    var list = profiles || []
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].active === true) return String(list[i].name)
    return ""
  }

  function profileDisplayName(handle) {
    var target = Model.normalizeProfileHandle(handle)
    var list = profiles || []
    for (var i = 0; i < list.length; i++) {
      if (list[i] && String(list[i].id) === target) return String(list[i].name || target)
    }
    return target
  }

  // `handle` is a row's id — the ID column when the CLI gave us one, the
  // display name on an older CLI that cannot. Every refusal is decided in
  // `Model.resolveProfileSelection`, including normalising the handle before
  // it is compared with the active row: comparing the raw value first let
  // `selectProfile("default ")` past the check and then normalised it back to
  // the profile already in use, re-cycling the engine for nothing.
  function selectProfile(handle) {
    var decision = Model.resolveProfileSelection(profiles, handle)
    if (!decision.ok) {
      // The one refusal a person can act on: two rows that cannot be told
      // apart, which only an id-less table can produce.
      if (decision.reason === "ambiguous") {
        actionStatus = "Two profiles share that name — run `netbird profile list --show-id`"
        actionStatusTimer.restart()
      }
      return false
    }
    // Serialised against every other command: switching recycles the engine,
    // so it must not overlap a toggle, a login, or a network change — and a
    // stale list must not be the thing being selected from.
    if (!installed || daemonDown || mutating || profilesProcess.running) return false
    actionStatus = "Switching to profile " + profileDisplayName(decision.id) + "…"
    profileActionStdout.reset()
    profileActionStderr.reset()
    profileActionProcess.command = Model.profileSelectCommand(decision.id)
    profileActionProcess.running = true
    // Both sections belong to the old account from the moment the switch
    // starts, not from the moment it ends: the README says they disappear
    // while switching, and leaving them up for the seconds an engine recycle
    // takes showed the previous account's rows as if they were current.
    // Cleared only after the process is running, so a refused switch never
    // blanks the panel.
    _dropAccountLists()
    return true
  }

  // Everything that describes the account being left. Called when a switch
  // starts and again when it exits, since the exit also owes fresh reads.
  function _dropAccountLists() {
    profilesLoaded = false
    networksLoaded = false
    networks = []
    networkDesired = {}
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

  // `truncated` is the collector's own flag for the output this document came
  // from. A status that exits 0 with an unparseable document is a failure
  // like any other, and it is exactly the case the cap can cause — so it
  // reports through the same formatter, and says `(output truncated)` when
  // lines were dropped. Reporting the parse error bare was the one path that
  // did not, contradicting the README.
  function parseStatus(raw, truncated) {
    var parsed = Model.parseStatus(raw, Date.now())
    if (!parsed.ok) {
      resetUnavailable(parsed.message || "Status error")
      lastError = Model.failureText(parsed.error, "", "Failed to parse netbird status", truncated === true)
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
    // A panel held open across a recovery used to keep the empty list
    // `resetUnavailable` installed, because opening was the only trigger.
    // The transition itself is now the trigger: assigning `running` and
    // `daemonDown` above fires the state hooks, which re-arm both drains.
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
      var truncated = statusStdout.truncated || statusStderr.truncated
      var parsed = exitCode === 0 ? Model.parseStatus(stdout, Date.now()) : null
      if (parsed && parsed.ok && !parsed.unavailable) {
        root.clearDaemonDown()
        root.parseStatus(stdout, truncated)
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
        root.parseStatus(stdout, truncated)
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
        root.parseStatus(stdout, truncated)
        root.lastError = Model.failureText(stderr, "", "", statusStderr.truncated)
        return
      }
      root.resetUnavailable("Disconnected")
      // Whatever the CLI did say is the only explanation the user gets, and it
      // is as likely to be on stdout as on stderr — noting, as every failure
      // path here does, when the collector had to drop lines to stay bounded.
      root.lastError = Model.failureText(stderr, stdout, "", statusStderr.truncated || statusStdout.truncated)
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
      // the row back under them. Ordered against completed writes — network
      // writes and profile switches alike — and rejected outright if either
      // kind started while this read was in flight.
      if (!Model.shouldApplyNetworksRead(root._networkReadGeneration, root._networkGeneration, root._networkWriteInFlight)) {
        // A discard is not a fault: it is the race this ordering exists to
        // catch, self-correcting one prompt re-read later. Charging it
        // against the failure budget let an active user spend three clicks
        // and lose the corrective read entirely.
        root._noteCorrective("networks", Model.CORRECTIVE_DISCARDED)
        return
      }
      if (exitCode !== 0) {
        // The rows on screen are stale and the daemon would not say
        // otherwise. Count the attempt; while under the cap the drain timer
        // goes back for the truth, and past it the obligation waits for the
        // next natural trigger instead of looping.
        root._noteCorrective("networks", Model.CORRECTIVE_FAILED)
        return
      }
      root.networks = Model.parseNetworksList(String(networksStdout.tail || ""))
      root.networksLoaded = true
      root.networkDesired = {}
      // The rows are shown either way — a snapshot is not wrong to display —
      // but a read that started before the newest request cannot discharge
      // it: the obligation stands and the drain fetches a current list.
      root._noteCorrective("networks", Model.readSatisfiesRequest(root._networksReadEpoch, root._networksRequestEpoch)
        ? Model.CORRECTIVE_APPLIED : Model.CORRECTIVE_SUPERSEDED)
    }
  }

  Process {
    id: profilesProcess
    running: false
    command: []
    stdout: BoundedCollector { id: profilesStdout; limit: 16384 }
    stderr: BoundedCollector { id: profilesStderr; limit: 16384 }
    onExited: function(exitCode) {
      // "Applied" means the CLI exited 0 and what it printed was the table we
      // asked for. It does NOT mean the table had rows: an empty parse used
      // to be treated as a failure, on the theory that there is always a
      // default profile — which turned any format drift into the section
      // disappearing plus three spawns per trigger. A parsed table with no
      // rows is an answer, so it is applied.
      // A CLI that does not know `--show-id` rejects the command outright.
      // Drop the flag for the rest of the session; the ordinary failure
      // budget carries the retry, which parses the two-column table.
      if (root._profileListShowId
          && Model.rejectsShowId(exitCode, String(profilesStderr.tail || ""), String(profilesStdout.tail || ""))) {
        root._profileListShowId = false
        root._noteCorrective("profiles", Model.CORRECTIVE_FAILED)
        return
      }
      var parsed = exitCode === 0
        ? Model.parseProfileTable(String(profilesStdout.tail || ""))
        : { ok: false, hasIds: false, profiles: [] }
      if (!parsed.ok) {
        root._noteCorrective("profiles", Model.CORRECTIVE_FAILED)
        return
      }
      root.profiles = parsed.profiles
      root.profilesLoaded = true
      root._noteCorrective("profiles", Model.readSatisfiesRequest(root._profilesReadEpoch, root._profilesRequestEpoch)
        ? Model.CORRECTIVE_APPLIED : Model.CORRECTIVE_SUPERSEDED)
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
        root.lastError = Model.failureText(profileActionStderr.tail, profileActionStdout.tail,
          "netbird profile select failed", profileActionStderr.truncated || profileActionStdout.truncated)
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.actionStatus = ""
      }
      // The switch has landed, so a networks read may be trusted again — and
      // any read still in flight belongs to the account we just left. Same
      // generation as a networks write, for exactly that reason.
      root._networkGeneration += 1
      // Switching profiles re-cycles the engine: the daemon may come back
      // needing a login on the target profile. Let the ordinary states carry
      // whatever it reports. Both lists belong to the old account until they
      // are re-read, so both are dropped rather than left on screen: the
      // networks of an account this machine is no longer on are not
      // selectable, and clicking one would send an id from it.
      root._dropAccountLists()
      // An action is a natural trigger: fresh budgets, both lists owed.
      root.requestLists()
      delayedRefresh.restart()
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
        root.lastError = Model.failureText(networkActionStderr.tail, networkActionStdout.tail,
          "netbird networks command failed", networkActionStderr.truncated || networkActionStdout.truncated)
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      }
      // The write is done: from here a read can be trusted again.
      root._networkGeneration += 1
      // Re-read either way: on success to see it, on failure to see the
      // truth. A completed action is a natural trigger — fresh retry budget.
      root.requestList("networks")
    }
  }

  // The dirty drains. Deliberately timers, not calls from exit handlers: a
  // daemon refusing every list would otherwise be retried the instant each
  // failure landed, in a tight exit-restart loop. The interval is whatever
  // `Model.correctiveStep` asked for — the slow cadence after a fault, the
  // prompt one after a discard or a natural trigger — so it is set on every
  // arm rather than declared once.
  Timer {
    id: networksDirtyDrain
    interval: Model.CORRECTIVE_RETRY_MS
    repeat: false
    onTriggered: root._drainList("networks")
  }

  Timer {
    id: profilesDirtyDrain
    interval: Model.CORRECTIVE_RETRY_MS
    repeat: false
    onTriggered: root._drainList("profiles")
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
        root.lastError = Model.failureText(stderr, stdout, "netbird command failed",
          actionStderr.truncated || actionStdout.truncated)
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
        root.lastError = Model.failureText(combined, "", "netbird up failed", false)
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
