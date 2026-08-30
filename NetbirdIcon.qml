import Quickshell
import QtQuick
import qs.Commons

// The official NetBird system-tray icons, one per connection state — the same
// artwork netbird-ui puts in the tray, replacing a hand-drawn Canvas mark. The
// icons carry the state themselves, so there is no `crossed` or `warning`
// overlay to compose: pick a state and the artwork says the rest.
//
// Colour only, deliberately. A themed monochrome variant was built and then
// withdrawn: tinting the upstream white silhouette draws nothing inside
// quickshell's layer-shell bar, with no error logged, while the identical code
// tints correctly under plain `qml6`. See `assets/NOTICE` for the unused mono
// files and .herd/results/t03.md for what was tried.
//
// `state` is Item's own string property rather than a redeclared one: QML will
// not let a subclass shadow it, and with no `states:` defined the state machine
// stays inert, so it behaves as the plain string the API asks for.
Item {
  id: root

  property real iconSize: Style.font.icon

  state: "disconnected"

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  // An absent CLI has no NetBird state to report, so it borrows the
  // disconnected mark and fades it: the daemon is not merely off, it is not
  // there. Opacity rather than a tint, so this needs no render effect.
  readonly property bool notInstalled: root.state === "notInstalled"

  readonly property string assetState: {
    var value = String(root.state || "")
    if (value === "connected" || value === "connecting" || value === "error") return value
    if (value === "needsLogin") return "needs-login"
    return "disconnected"
  }

  Image {
    anchors.fill: parent
    source: "assets/netbird-systemtray-" + root.assetState + ".png"
    sourceSize.width: Math.round(root.iconSize * Screen.devicePixelRatio)
    sourceSize.height: Math.round(root.iconSize * Screen.devicePixelRatio)
    fillMode: Image.PreserveAspectFit
    smooth: true
    mipmap: true
    opacity: root.notInstalled ? 0.45 : 1.0
  }
}
