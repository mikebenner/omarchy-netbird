import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// NetBird in the Omarchy bar, modeled on the first-party Tailscale widget:
// a bar icon that reflects the daemon, a keyboard-driven popup with a power
// switch in the hero, and a peer list with copy actions.
//
// What NetBird does not have, this does not show: no exit nodes, no Mullvad,
// no account switching, and no operator handshake — the daemon socket is
// world-writable, so status/up/down all run unprivileged.
Panel {
  id: root
  moduleName: "mikebenner.netbird"
  ipcTarget: "mikebenner.netbird"
  manageIpc: false

  property string focusSection: "header"
  property int peerIndex: 0
  property bool cursorActive: false
  property bool copyMenuOpen: false
  property bool searchOpen: false
  property string peerQuery: ""
  property int networkIndex: 0
  property int profileIndex: 0
  property bool relaysExpanded: false
  // Only one peer's detail is open at a time; "" means none.
  property string expandedPeerId: ""
  // "3m ago" has to keep meaning that, so the relative label depends on a
  // value that changes. Ticks only while a detail is actually on screen.
  property double detailNow: Date.now()

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool showSelf: netbird.installed && netbird.active && (netbird.selfIp !== "" || netbird.selfFqdn !== "")
  readonly property bool showPeers: netbird.active && visiblePeers.length > 0
  // Only claim the header cursor when the switch is actually on screen —
  // "header" stays navigable, but an absent CLI leaves nothing to highlight.
  readonly property bool headerHasCursor: cursorActive && focusSection === "header" && netbird.installed
  // "theme" unless the user asked for the official artwork; an unrecognised
  // value falls back to the themed mark rather than to nothing.
  readonly property string iconStyle: String(setting("iconStyle", "theme") || "") === "color" ? "color" : "theme"
  readonly property color barBackground: bar && bar.background ? bar.background : Color.background

  // A toggle the daemon has not caught up with yet. `active` is the optimistic
  // value and `running` the observed one, so they disagree exactly while a
  // requested up or down is still in flight.
  readonly property bool togglePending: netbird.active !== netbird.running

  // Every peer still negotiating and none up yet. Lazy connections make this a
  // real, and temporary, state of the mesh rather than a fault.
  readonly property bool peersConnectingOnly: {
    if (!netbird.active || netbird.peersConnected > 0) return false
    var list = netbird.peers || []
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].connecting === true) return true
    return false
  }

  // Which of the official tray icons this moment calls for. Order matters:
  // an absent CLI outranks everything, then re-authentication, then a control
  // plane that is down under a daemon claiming to be up, and only then the
  // ordinary on/off.
  //
  // Note `busy` is deliberately not consulted: it is true during every routine
  // status poll, and wiring it here would blink the bar to "connecting" twice a
  // minute. The daemon's own Connecting state, an in-flight toggle, and a mesh
  // whose peers are all still negotiating are the three things that really mean
  // it.
  readonly property string iconState: {
    if (!netbird.installed) return "notInstalled"
    // A daemon that cannot be reached is an error, not an "off" — the tunnel
    // state is unknown, and the fix is not the toggle.
    if (netbird.daemonDown) return "error"
    if (netbird.needsLogin) return "needsLogin"
    if (netbird.active && netbird.degraded) return "error"
    if (netbird.daemonStatus === "Connecting" || togglePending || peersConnectingOnly) return "connecting"
    return netbird.active ? "connected" : "disconnected"
  }
  readonly property string toggleHint: netbird.daemonDown
    ? "The NetBird daemon is not running"
    : (netbird.active ? "Turn NetBird off" : (netbird.needsLogin ? "Sign in to NetBird" : "Turn NetBird on"))
  readonly property string barTooltip: !netbird.installed
    ? "NetBird is not installed"
    : (netbird.daemonDown
      ? "NetBird daemon is not running"
      : netbird.statusText + (netbird.peerCountText !== "" ? " · " + netbird.peerCountText + " peers" : ""))

  readonly property string heroMeta: {
    if (!netbird.installed) return ""
    if (netbird.daemonDown) return "NetBird daemon is not running"
    if (netbird.needsLogin) return "Sign in to join the network"
    if (!netbird.active) return "NetBird is disconnected"
    // Session first: on a self-hosted management domain the two together
    // outrun the hero's width, and the clock that will drop you off the mesh
    // is the half worth keeping when one of them has to elide. A degraded
    // control plane outranks both — it is the reason the bar icon is wearing
    // a warning badge, and the panel is where that gets explained.
    var parts = []
    if (netbird.degraded && netbird.degradedText !== "") parts.push(netbird.degradedText)
    if (netbird.sessionText !== "") parts.push(netbird.sessionText)
    if (netbird.managementHost !== "") parts.push(netbird.managementHost)
    return parts.length > 0 ? parts.join(" · ") : "NetBird is connected"
  }

  readonly property string selfDetail: {
    var parts = []
    if (netbird.selfIp !== "") parts.push(netbird.selfIp)
    if (netbird.relaysTotal > 0) parts.push("relays " + netbird.relaysAvailable + "/" + netbird.relaysTotal)
    if (netbird.profileName !== "" && netbird.profileName !== "default") parts.push("profile " + netbird.profileName)
    return parts.join(" · ")
  }

  // Same staleness rule as PROFILES below, and for the same reason: a profile
  // switch drops both lists until their corrective re-reads land, so the
  // previous account's networks are never left on screen — clicking one would
  // send `networks select` an id belonging to an account this machine has
  // left.
  readonly property bool showNetworks: netbird.installed && netbird.active && !netbird.daemonDown
    && netbird.networksLoaded && netbird.networks.length > 0
  readonly property string networksHeading: "NETWORKS — " + Model.selectedNetworkCount(netbird.networks) + "/" + netbird.networks.length
  readonly property bool showRelays: netbird.installed && netbird.active && netbird.relays.length > 0
  // Only worth a section when there is a choice to make — and only rows from
  // a list that was actually loaded. A profile switch drops `profilesLoaded`
  // until the corrective re-read lands, so the section never shows the old
  // account's rows with the old active mark while the engine recycles.
  readonly property bool showProfiles: netbird.installed && !netbird.daemonDown
    && netbird.profilesLoaded && netbird.profiles.length > 1

  readonly property var visiblePeers: Model.filterPeers(netbird.peers, root.peerQuery)
  readonly property bool filtering: root.peerQuery !== ""
  readonly property string peersHeading: filtering
    ? "PEERS — " + visiblePeers.length + " OF " + netbird.peers.length
    : "PEERS"

  readonly property var selfCopyOptions: {
    var options = []
    if (netbird.selfName !== "") options.push({ kind: "name", label: netbird.selfName })
    if (netbird.selfFqdn !== "") options.push({ kind: "fqdn", label: netbird.selfFqdn })
    if (netbird.selfIp !== "") options.push({ kind: "ip", label: netbird.selfIp })
    return options
  }

  function selectedPeer() {
    var list = root.visiblePeers
    if (list.length === 0) return null
    return list[Math.max(0, Math.min(peerIndex, list.length - 1))]
  }

  // c / n / d act on whatever the cursor is sitting on, so the same three keys
  // copy this device's details from the self row and a peer's from the list.
  // c / n / d act on the focused row, and only on a row that actually has
  // these fields. With the header or a network focused they do nothing, rather
  // than silently copying from whichever peer the cursor last sat on.
  function copyIp() {
    if (focusSection === "self") netbird.copyToClipboard(netbird.selfIp)
    else if (focusSection === "peers") netbird.copyPeerIp(selectedPeer())
  }

  function copyName() {
    if (focusSection === "self") netbird.copyToClipboard(netbird.selfName)
    else if (focusSection === "peers") netbird.copyPeerName(selectedPeer())
  }

  function copyFqdn() {
    if (focusSection === "self") netbird.copyToClipboard(netbird.selfFqdn)
    else if (focusSection === "peers") netbird.copyPeerFqdn(selectedPeer())
  }

  // s / p act on the focused peer row only, for the same reason.
  function sshFocusedPeer() {
    if (focusSection !== "peers") return
    var peer = selectedPeer()
    if (peer && peer.online) netbird.sshToPeer(peer)
  }

  function pingFocusedPeer() {
    if (focusSection !== "peers") return
    var peer = selectedPeer()
    if (peer && peer.online) netbird.pingPeer(peer)
  }

  function ensureCursor() {
    if (peerIndex < 0) peerIndex = 0
    if (peerIndex >= visiblePeers.length) peerIndex = Math.max(0, visiblePeers.length - 1)
    if (networkIndex < 0) networkIndex = 0
    if (networkIndex >= netbird.networks.length) networkIndex = Math.max(0, netbird.networks.length - 1)
    if (profileIndex < 0) profileIndex = 0
    if (profileIndex >= netbird.profiles.length) profileIndex = Math.max(0, netbird.profiles.length - 1)
    if (focusSection === "self" && !showSelf) focusSection = showPeers ? "peers" : "header"
    if (focusSection === "profiles" && !showProfiles) focusSection = showNetworks ? "networks" : (showPeers ? "peers" : "header")
    if (focusSection === "networks" && !showNetworks) focusSection = showPeers ? "peers" : "header"
    if (focusSection === "peers" && !showPeers) focusSection = showSelf ? "self" : "header"
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy !== 0) {
      if (focusSection === "header") {
        if (dy > 0) {
          if (showSelf) focusSection = "self"
          else if (showPeers) focusSection = "peers"
        }
      } else if (focusSection === "self") {
        if (dy < 0) focusSection = "header"
        else if (showProfiles) focusSection = "profiles"
        else if (showNetworks) focusSection = "networks"
        else if (showPeers) focusSection = "peers"
      } else if (focusSection === "profiles") {
        if (dy < 0) {
          if (profileIndex <= 0) focusSection = showSelf ? "self" : "header"
          else profileIndex--
        } else if (profileIndex < netbird.profiles.length - 1) {
          profileIndex++
        } else if (showNetworks) {
          focusSection = "networks"
        } else if (showPeers) {
          focusSection = "peers"
        }
      } else if (focusSection === "networks") {
        if (dy < 0) {
          if (networkIndex <= 0) focusSection = showProfiles ? "profiles" : (showSelf ? "self" : "header")
          else networkIndex--
        } else if (networkIndex < netbird.networks.length - 1) {
          networkIndex++
        } else if (showPeers) {
          focusSection = "peers"
        }
      } else if (focusSection === "peers") {
        if (dy < 0) {
          if (peerIndex <= 0) focusSection = showNetworks ? "networks" : (showSelf ? "self" : "header")
          else peerIndex--
        } else if (peerIndex < visiblePeers.length - 1) {
          peerIndex++
        }
      }
    }
    ensureCursor()
    scrollCursorIntoView()
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") netbird.toggleNetbird()
    else if (focusSection === "self") selfRow.openCopyMenu()
    else if (focusSection === "profiles") {
      var list = netbird.profiles || []
      var entry = list[Math.max(0, Math.min(profileIndex, list.length - 1))]
      if (entry) netbird.selectProfile(entry.name)
    }
    else if (focusSection === "networks") toggleFocusedNetwork()
    // Enter opens the peer's detail rather than the copy menu: the chevron is
    // what the row now advertises, and c / n / d already copy without a menu.
    else if (focusSection === "peers") togglePeerDetail(selectedPeer())
  }

  function toggleFocusedNetwork() {
    var list = netbird.networks || []
    if (list.length === 0) return
    var entry = list[Math.max(0, Math.min(networkIndex, list.length - 1))]
    if (entry) netbird.toggleNetwork(entry.id)
  }

  function togglePeerDetail(peer) {
    if (!peer) return
    var id = String(peer.id || "")
    expandedPeerId = expandedPeerId === id ? "" : id
  }

  function focusNetworks() {
    if (!showNetworks) return
    cursorActive = true
    focusSection = "networks"
    networkIndex = Math.max(0, Math.min(networkIndex, netbird.networks.length - 1))
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (focusSection === "peers" && peerColumn && peerIndex >= 0 && peerIndex < peerColumn.children.length) scrollItemIntoView(peerColumn.children[peerIndex])
  }

  function openSelectedPeerCopyMenu() {
    if (!peerColumn || peerIndex < 0 || peerIndex >= peerColumn.children.length) return
    var item = peerColumn.children[peerIndex]
    if (item && item.openCopyMenu) item.openCopyMenu()
  }

  function setPeerCursor(index) {
    cursorActive = true
    focusSection = "peers"
    peerIndex = index
    scrollCursorIntoView()
  }

  function setSelfCursor() {
    cursorActive = true
    focusSection = "self"
  }

  function openSearch() {
    if (!showPeers && netbird.peers.length === 0) return
    searchOpen = true
    Qt.callLater(function() { if (peerSearch) peerSearch.forceActiveFocus() })
  }

  function closeSearch() {
    searchOpen = false
    if (peerSearch) peerSearch.text = ""
    peerQuery = ""
    peerIndex = 0
    if (root.opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    // The service lists networks only while someone is looking at them.
    netbird.panelOpen = opened
    if (!opened) {
      // Transient view state does not survive a close. Without this the filter
      // field reappears on the next open, showing over an unfiltered list, and
      // an expanded peer stays expanded for a mesh that has since changed.
      searchOpen = false
      if (peerSearch) peerSearch.text = ""
      peerQuery = ""
      peerIndex = 0
      networkIndex = 0
      profileIndex = 0
      // Focus too: a section that is gone on the next open must not still be
      // the remembered target, or the first arrow key highlights nothing.
      focusSection = "header"
      cursorActive = false
      expandedPeerId = ""
      relaysExpanded = false
      return
    }
    cursorActive = false
    if (panelFlick) panelFlick.contentY = 0
    // Only the status poll is kicked here. The two list reads used to be
    // called straight after it and were swallowed: they run synchronously,
    // before the poll's answer can clear a `daemonDown` left over from the
    // last time the panel was open, so both refused and — once the sections
    // were gated on their loaded flag — stayed gone for the session. Setting
    // `panelOpen` above already told the service both lists are owed; it
    // starts them when its own state says they can run, including on the
    // first poll that clears the outage.
    netbird.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onPeerIndexChanged: scrollCursorIntoView()
  onShowSelfChanged: ensureCursor()
  onShowPeersChanged: ensureCursor()
  // Both of these are volatile now — a profile switch hides each section
  // until its list is re-read — so a cursor parked in one has to be moved on
  // when it goes, or the arrow keys highlight nothing.
  onShowProfilesChanged: ensureCursor()
  onShowNetworksChanged: ensureCursor()

  Service {
    id: netbird
    settings: root.settings
  }

  Timer {
    running: root.opened && root.expandedPeerId !== ""
    interval: 15000
    repeat: true
    triggeredOnStart: true
    onTriggered: root.detailNow = Date.now()
  }

  Connections {
    target: netbird
    function onPeersChanged() { root.ensureCursor() }
    // A list that shrinks under the cursor leaves the index past its end,
    // which highlights nothing and activates the wrong row on the way back.
    function onNetworksChanged() { root.ensureCursor() }
    function onProfilesChanged() { root.ensureCursor() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { netbird.refresh(); return "ok" }
    // These three are the same gated entry points the switch, the `t` key and
    // the bar right-click use, so an IPC caller cannot race a command that is
    // already running. A refused request answers "busy" rather than "ok".
    function up(): string { return netbird.up() ? "ok" : "busy" }
    function down(): string { return netbird.down() ? "ok" : "busy" }
    function toggleNetbird(): string { return netbird.toggleNetbird() ? "ok" : "busy" }
    function status(): string { return netbird.summary() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.barTooltip
    iconComponent: Component {
      Item {
        NetbirdIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          state: root.iconState
          style: root.iconStyle
          color: root.barForeground
          dimColor: Qt.darker(root.barForeground, 1.55)
          urgentColor: root.urgent
          outlineColor: root.barBackground
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) netbird.toggleNetbird()
      else if (buttonCode === Qt.MiddleButton) netbird.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Blocked while a copy menu is up or the filter field has focus, so
      // typed characters land in the field rather than firing shortcuts.
      blocked: root.copyMenuOpen || (root.searchOpen && peerSearch.activeFocus)
      onMoveRequested: function(dx, dy) {
        // The first press only reveals the cursor — but it still has to land
        // somewhere visible, so settle the section before returning.
        if (!root.cursorActive) {
          root.cursorActive = true
          root.ensureCursor()
          return
        }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: {
        // Escape unwinds one layer at a time: the filter, then a login in
        // flight, then the panel.
        if (root.searchOpen) root.closeSearch()
        else if (netbird.loginActive) netbird.cancelLogin()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "/") root.openSearch()
        // Capital N, because lowercase n already copies the name.
        else if (t === "N") root.focusNetworks()
        else if (t === "e" || t === "E") root.relaysExpanded = !root.relaysExpanded
        else if (t === "s" || t === "S") root.sshFocusedPeer()
        else if (t === "p" || t === "P") root.pingFocusedPeer()
        else if (t === "a" || t === "A") netbird.openAdminConsole()
        else if (t === "t" || t === "T") netbird.toggleNetbird()
        else if (t === "r" || t === "R") netbird.refresh()
        else if (t === "c" || t === "C") root.copyIp()
        else if (t === "n" || t === "N") root.copyName()
        else if (t === "d" || t === "D") root.copyFqdn()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // Exposed for the hero's trailingControl, whose `root` resolves to
            // PanelHero (not this Panel) — reach panel state via `header`.
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.setHeaderCursor() }

            PanelHero {
              id: hero
              width: parent.width
              title: netbird.installed && netbird.selfName !== "" ? netbird.selfName : "NetBird"
              meta: root.heroMeta
              detail: netbird.installed && netbird.peerCountText !== "" ? netbird.peerCountText : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: netbird.active ? 1.0 : 0.5
              // Status only — the switch owns toggling, mouse and keyboard alike.
              iconComponent: Component {
                NetbirdIcon {
                  iconSize: Style.font.display
                  state: root.iconState
                  style: root.iconStyle
                  color: root.foreground
                  dimColor: root.dim
                  urgentColor: root.urgent
                  outlineColor: Color.popups.background
                }
              }

              // Compact on/off switch on the trailing edge of the hero, and the
              // header's only cursor target. The service already flips `active`
              // optimistically, so the knob throws the instant you click it.
              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: netbird.installed
                  checked: netbird.active
                  // Swallow clicks while the daemon is unreachable: there is
                  // nothing for up or down to talk to, and the service refuses
                  // them anyway.
                  busy: netbird.busy || netbird.daemonDown
                  opacity: netbird.daemonDown ? 0.5 : 1.0
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: netbird.toggleNetbird()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: root.toggleHint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            visible: netbird.actionStatus !== "" || netbird.lastError !== ""
            width: parent.width
            text: netbird.actionStatus !== "" ? netbird.actionStatus : netbird.lastError
            color: netbird.lastError !== "" && netbird.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // The daemon is not answering. Say so, and say what to check —
          // the toggle cannot help here, so it is disabled rather than left
          // looking like the fix.
          CursorSurface {
            visible: netbird.daemonDown
            width: parent.width
            implicitHeight: daemonDownText.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground

            Text {
              id: daemonDownText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              text: "The NetBird CLI is installed but the daemon is not answering. Check it with systemctl status netbird."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // The device code an SSO login is waiting on, with the two things
          // you want while looking at it: a way to copy it, and a way out.
          // Shown for as long as `netbird up` runs, not only when it printed a
          // code: a login that only ever emits a URL still needs a way out.
          CursorSurface {
            visible: netbird.loginActive
            width: parent.width
            implicitHeight: loginCodeRow.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground

            RowLayout {
              id: loginCodeRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(10)

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(2)

                Text {
                  Layout.fillWidth: true
                  text: netbird.loginCode !== ""
                    ? "Enter this code to finish signing in"
                    : "Finish signing in to NetBird in your browser"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  wrapMode: Text.WordWrap
                }

                Text {
                  visible: netbird.loginCode !== ""
                  Layout.fillWidth: true
                  text: netbird.loginCode
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  font.letterSpacing: 2
                  elide: Text.ElideRight
                }
              }

              PanelActionButton {
                visible: netbird.loginCode !== ""
                iconText: "󰆏"
                tooltipText: "Copy code"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: netbird.copyToClipboard(netbird.loginCode)
              }

              PanelActionButton {
                iconText: "󰅖"
                tooltipText: "Cancel sign-in (esc)"
                foreground: root.foreground
                hoverColor: root.urgent
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: netbird.cancelLogin()
              }
            }
          }

          CursorSurface {
            visible: !netbird.installed
            width: parent.width
            implicitHeight: missingText.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground

            Text {
              id: missingText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              text: "NetBird CLI is not installed or not on PATH."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }

          // Both numbers are in the status document already; a mismatch is a
          // real support-ticket source and costs one caption to surface.
          Text {
            visible: netbird.versionNotice !== ""
            width: parent.width
            text: netbird.versionNotice
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // This device: the address and FQDN NetBird gave us, relay health,
          // and the same copy menu the peer rows carry.
          SelfRow {
            id: selfRow
            visible: root.showSelf
            width: parent.width
          }

          // Which relay is failing, behind the count on the self row. `e`
          // toggles; collapsed by default because it is usually all fine.
          Column {
            visible: root.showRelays && root.relaysExpanded
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: netbird.relays
              Text {
                required property var modelData
                width: parent.width
                leftPadding: Style.space(34)
                text: (modelData.available ? "● " : "⊘ ") + modelData.uri
                  + (modelData.error !== "" ? " — " + modelData.error : "")
                color: modelData.available ? root.dim : root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }

          PanelSeparator {
            visible: root.showProfiles
            foreground: root.foreground
          }

          Column {
            visible: root.showProfiles
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "PROFILES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              id: profileColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: netbird.profiles
                ProfileRow {
                  required property var modelData
                  required property int index
                  width: profileColumn.width
                  profile: modelData
                  rowIndex: index
                }
              }
            }
          }

          PanelSeparator {
            visible: root.showNetworks
            foreground: root.foreground
          }

          Column {
            visible: root.showNetworks
            width: parent.width
            spacing: Style.space(10)

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                Layout.fillWidth: true
                text: root.networksHeading
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              PanelActionButton {
                iconText: "󰄬"
                tooltipText: "Select all networks"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !netbird.networksBusy
                Layout.alignment: Qt.AlignVCenter
                onClicked: netbird.selectAllNetworks()
              }

              PanelActionButton {
                iconText: "󰅖"
                tooltipText: "Deselect all networks"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !netbird.networksBusy
                Layout.alignment: Qt.AlignVCenter
                onClicked: netbird.deselectAllNetworks()
              }
            }

            Column {
              id: networkColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: netbird.networks
                NetworkRow {
                  required property var modelData
                  required property int index
                  width: networkColumn.width
                  network: modelData
                  rowIndex: index
                }
              }
            }
          }

          PanelSeparator {
            visible: netbird.installed && netbird.active
            foreground: root.foreground
          }

          Column {
            visible: netbird.installed && netbird.active
            width: parent.width
            spacing: Style.space(10)

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                Layout.fillWidth: true
                text: root.peersHeading
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              PanelActionButton {
                visible: netbird.adminUrl !== ""
                iconText: "󰖟"
                tooltipText: "Open the admin console (a)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: netbird.openAdminConsole()
              }
            }

            // Opened with `/`. While it has focus the panel's key catcher is
            // blocked, so typed characters reach the field instead of being
            // read as shortcuts.
            TextField {
              id: peerSearch
              visible: root.searchOpen
              width: parent.width
              foreground: root.foreground
              placeholderText: "Filter peers — name, address, transport, state"
              // One-way: the field is the source of truth and `peerQuery`
              // follows it. Binding `text` back to `peerQuery` meant clearing
              // the property on close did not necessarily clear the field, so
              // `/` reopened showing a stale query over an unfiltered list.
              onTextChanged: {
                root.peerQuery = text
                root.peerIndex = 0
              }
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.closeSearch()
                  event.accepted = true
                  return
                }
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Down) {
                  root.cursorActive = true
                  root.focusSection = "peers"
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }

            Text {
              visible: netbird.active && netbird.peers.length === 0
              width: parent.width
              text: "No peers on this network."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              visible: netbird.active && netbird.peers.length > 0 && root.visiblePeers.length === 0
              width: parent.width
              text: "No peer matches " + root.peerQuery
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
            }

            Column {
              id: peerColumn
              visible: root.showPeers
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.visiblePeers
                PeerRow {
                  required property var modelData
                  required property int index
                  width: peerColumn.width
                  peer: modelData
                  rowIndex: index
                }
              }
            }
          }
        }
      }
    }
  }

  // Shared drop-down behind every copy button: the same list-and-choose menu
  // the Tailscale widget uses, lifted out so the self row and the peer rows
  // cannot drift apart.
  component CopyMenu: Popup {
    id: menu
    property var options: []
    property Item anchorButton: null
    property int index: 0
    signal chosen(string kind)

    x: anchorButton ? anchorButton.x + anchorButton.width - width : 0
    y: anchorButton ? anchorButton.y + anchorButton.height + Style.space(4) : 0
    width: Style.space(280)
    padding: 0
    modal: false
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    function clampIndex() {
      index = Math.max(0, Math.min(index, options.length - 1))
    }

    function move(delta) {
      if (options.length === 0) return
      index = Math.max(0, Math.min(options.length - 1, index + delta))
    }

    function chooseCurrent() {
      clampIndex()
      if (options.length === 0) return
      menu.chosen(String(options[index].kind || ""))
      menu.close()
    }

    function handleKey(event) {
      if (event.key === Qt.Key_Escape) {
        menu.close()
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Down || event.text === "j") {
        menu.move(1)
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Up || event.text === "k") {
        menu.move(-1)
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        menu.chooseCurrent()
        event.accepted = true
      }
    }

    onOpenedChanged: {
      root.copyMenuOpen = opened
      if (opened) {
        menu.clampIndex()
        Qt.callLater(function() { menuContent.forceActiveFocus() })
      } else if (root.opened) {
        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      }
    }

    background: BorderSurface {
      color: Color.background
      borderSpec: Border.flat(root.dim, 1)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      id: menuContent
      width: parent.width
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { menu.handleKey(event) }

      Repeater {
        model: menu.options
        CopyChoice {
          required property var modelData
          required property int index
          width: parent.width
          label: String(modelData.label || "")
          selected: menu.index === index
          onHovered: menu.index = index
          onChosen: {
            menu.chosen(String(modelData.kind || ""))
            menu.close()
          }
        }
      }
    }
  }

  component CopyChoice: CursorSurface {
    id: copyChoice
    signal chosen()
    signal hovered()
    property string label: ""
    property bool selected: false

    visible: enabled
    foreground: root.foreground
    hasCursor: selected
    implicitHeight: Style.space(48)
    radius: 0

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: copyChoice.hovered()
      onClicked: copyChoice.chosen()
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(10)

      Text {
        Layout.fillWidth: true
        text: copyChoice.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        text: "󰆏"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  component SelfRow: CursorSurface {
    id: selfSurface

    function openCopyMenu() {
      if (root.selfCopyOptions.length === 0) return
      selfCopyMenu.open()
    }

    hasCursor: root.cursorActive && root.focusSection === "self"
    foreground: root.foreground

    implicitHeight: Math.max(selfContent.implicitHeight, selfCopyButton.implicitHeight) + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      hoverEnabled: true
      cursorShape: Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.setSelfCursor()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        text: "󰌘"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: selfContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: netbird.selfFqdn !== "" ? netbird.selfFqdn : netbird.selfName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: root.selfDetail
          visible: text !== ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        id: selfCopyButton
        iconText: "󰆏"
        tooltipText: "Copy this device"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: root.selfCopyOptions.length > 0
        Layout.alignment: Qt.AlignVCenter
        onClicked: selfSurface.openCopyMenu()
      }

      CopyMenu {
        id: selfCopyMenu
        options: root.selfCopyOptions
        anchorButton: selfCopyButton
        onChosen: function(kind) {
          if (kind === "name") netbird.copyToClipboard(netbird.selfName)
          else if (kind === "fqdn") netbird.copyToClipboard(netbird.selfFqdn)
          else if (kind === "ip") netbird.copyToClipboard(netbird.selfIp)
        }
      }
    }
  }

  component ProfileRow: CursorSurface {
    id: profileRow
    property var profile: null
    property int rowIndex: 0
    readonly property string profileName: profile ? String(profile.name || "") : ""
    readonly property bool isActive: profile ? profile.active === true : false

    hasCursor: root.cursorActive && root.focusSection === "profiles" && root.profileIndex === rowIndex
    current: isActive
    foreground: root.foreground
    fill: Style.hoverFillFor(root.foreground, Color.accent)
    currentFill: Style.selectedFillFor(root.foreground, Color.accent)

    implicitHeight: profileInner.implicitHeight + Style.spacing.xl

    Row {
      id: profileInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: profileRow.isActive ? "◉" : "○"
        color: profileRow.isActive ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: profileRow.profileName
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: profileRow.isActive
        elide: Text.ElideRight
        width: parent.width - Style.space(30)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: profileRow.isActive ? Qt.ArrowCursor : Qt.PointingHandCursor
      enabled: !netbird.profilesBusy
      onEntered: {
        root.cursorActive = true
        root.focusSection = "profiles"
        root.profileIndex = profileRow.rowIndex
      }
      onClicked: netbird.selectProfile(profileRow.profileName)
    }
  }

  component NetworkRow: CursorSurface {
    id: networkRow
    property var network: null
    property int rowIndex: 0
    readonly property string networkId: network ? String(network.id || "") : ""
    readonly property bool selected: netbird.networkSelected(networkId)
    readonly property string detail: Model.networkDetail(network)
    readonly property int resolvedCount: {
      if (!network || !network.resolvedIps) return 0
      return network.resolvedIps.length
    }

    hasCursor: root.cursorActive && root.focusSection === "networks" && root.networkIndex === rowIndex
    foreground: root.foreground

    implicitHeight: Math.max(networkContent.implicitHeight, networkSwitch.implicitHeight) + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      hoverEnabled: true
      cursorShape: Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "networks"
        root.networkIndex = networkRow.rowIndex
      }
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        text: "󰛳"
        color: networkRow.selected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: networkContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: networkRow.networkId
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: text !== ""
          text: {
            var parts = []
            if (networkRow.detail !== "") parts.push(networkRow.detail)
            if (networkRow.resolvedCount > 0) parts.push(networkRow.resolvedCount + " resolved")
            return parts.join(" · ")
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      ToggleSwitch {
        id: networkSwitch
        checked: networkRow.selected
        busy: netbird.networksBusy
        foreground: root.foreground
        Layout.alignment: Qt.AlignVCenter
        onToggled: netbird.toggleNetwork(networkRow.networkId)
      }
    }
  }

  component PeerRow: CursorSurface {
    id: peerRow
    property var peer: null
    property int rowIndex: 0
    readonly property string peerName: peer ? String(peer.name || "Unknown") : "Unknown"
    readonly property string peerIp: peer ? String(peer.ip || "") : ""
    readonly property string peerFqdn: peer ? String(peer.fqdn || "") : ""
    readonly property string peerKey: peer ? String(peer.publicKey || "") : ""
    readonly property bool peerDimmed: peer ? peer.dimmed === true : true
    readonly property string peerDetail: {
      if (!peer) return ""
      var parts = []
      if (peerIp !== "") parts.push(peerIp)
      // The glyph carries the state at a glance; the word spells it out, and
      // is the marker a Disconnected peer needs to read as genuinely gone.
      if (peer.online !== true) parts.push(String(peer.status || "unknown").toLowerCase())
      if (String(peer.connectionType || "") !== "") parts.push(String(peer.connectionType).toLowerCase())
      if (String(peer.latency || "") !== "") parts.push(String(peer.latency))
      return parts.join(" · ")
    }
    readonly property var copyOptions: {
      var options = []
      if (peerName !== "") options.push({ kind: "name", label: peerName })
      if (peerFqdn !== "") options.push({ kind: "fqdn", label: peerFqdn })
      if (peerIp !== "") options.push({ kind: "ip", label: peerIp })
      if (peerKey !== "") options.push({ kind: "key", label: peerKey })
      return options
    }

    function openCopyMenu() {
      if (copyOptions.length === 0) return
      peerCopyMenu.open()
    }

    readonly property bool expanded: root.expandedPeerId !== "" && peer && root.expandedPeerId === String(peer.id || "")
    readonly property var detailRows: {
      if (!peer || !expanded) return []
      var rows = []
      var connection = Model.connectionSummary(peer)
      if (connection !== "") rows.push({ label: "Connection", value: connection })
      var ice = Model.iceSummary(peer)
      if (ice !== "") rows.push({ label: "ICE pair", value: ice })
      var handshake = Model.relativeSince(peer.lastHandshake, root.detailNow)
      if (handshake !== "") rows.push({ label: "Last handshake", value: handshake })
      if (String(peer.latency || "") !== "") rows.push({ label: "Latency", value: String(peer.latency) })
      var received = Model.formatBytes(peer.transferReceived)
      var sent = Model.formatBytes(peer.transferSent)
      if (received !== "" || sent !== "") rows.push({ label: "Transfer", value: "↓ " + received + "   ↑ " + sent })
      var routes = peer.routes || []
      if (routes.length > 0) rows.push({ label: "Routes", value: routes.join(", ") })
      if (peer.quantumResistance === true) rows.push({ label: "Rosenpass", value: "enabled" })
      return rows
    }

    hasCursor: root.cursorActive && root.focusSection === "peers" && root.peerIndex === rowIndex
    foreground: root.foreground

    implicitHeight: Math.max(peerContent.implicitHeight, peerCopyButton.implicitHeight)
      + Style.spacing.rowPaddingX
      + (expanded ? peerDetail.implicitHeight + Style.space(8) : 0)

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      hoverEnabled: true
      cursorShape: Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.setPeerCursor(peerRow.rowIndex)
    }

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.spacing.rowPaddingX / 2
      spacing: Style.space(6)

    RowLayout {
      width: parent.width
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        text: peerRow.peer ? String(peerRow.peer.glyph || "○") : "○"
        color: peerRow.peerDimmed ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: peerContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: peerRow.peerName
          color: peerRow.peerDimmed ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: peerRow.peerDetail
          visible: text !== ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        visible: peerRow.peer && peerRow.peer.online === true && peerRow.peerIp !== ""
        iconText: "󰆍"
        tooltipText: "SSH to this peer (s)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: netbird.sshToPeer(peerRow.peer)
      }

      PanelActionButton {
        visible: peerRow.peer && peerRow.peer.online === true && peerRow.peerIp !== ""
        // A plain Unicode arrow pair, not a Nerd Font codepoint: the icon this
        // slot first used has no glyph in the bar font and fell back to a
        // letter box. Verified rendering in JetBrainsMono Nerd Font.
        iconText: "⇄"
        tooltipText: "Ping this peer (p)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: netbird.pingPeer(peerRow.peer)
      }

      PanelActionButton {
        iconText: peerRow.expanded ? "󰅃" : "󰅀"
        tooltipText: peerRow.expanded ? "Hide details" : "Show details"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.togglePeerDetail(peerRow.peer)
      }

      PanelActionButton {
        id: peerCopyButton
        iconText: "󰆏"
        tooltipText: "Copy peer details"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: peerRow.copyOptions.length > 0
        Layout.alignment: Qt.AlignVCenter
        onClicked: peerRow.openCopyMenu()
      }

      CopyMenu {
        id: peerCopyMenu
        options: peerRow.copyOptions
        anchorButton: peerCopyButton
        onChosen: function(kind) {
          if (kind === "name") netbird.copyPeerName(peerRow.peer)
          else if (kind === "fqdn") netbird.copyPeerFqdn(peerRow.peer)
          else if (kind === "ip") netbird.copyPeerIp(peerRow.peer)
          else if (kind === "key") netbird.copyToClipboard(peerRow.peerKey)
        }
      }
    }

    // The fields the status document already carries and we used to discard —
    // the answer to "why is this peer relayed?", which is what the panel is
    // for. Collapsed until asked for, one peer at a time.
    Column {
      id: peerDetail
      visible: peerRow.expanded
      width: parent.width
      spacing: Style.space(2)

      Repeater {
        model: peerRow.detailRows
        RowLayout {
          required property var modelData
          width: peerDetail.width
          spacing: Style.space(8)

          Text {
            Layout.preferredWidth: Style.space(96)
            leftPadding: Style.space(34)
            text: modelData.label
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            Layout.fillWidth: true
            text: modelData.value
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
    }
  }
}
