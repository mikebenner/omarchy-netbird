import Quickshell
import QtQuick
import QtQuick.Shapes
import qs.Commons

// The NetBird mark, in one of two styles:
//
//   "theme" (default) — drawn as vector paths in the colours the current
//                       Omarchy theme is using, so the widget matches the rest
//                       of the bar and follows a theme switch live.
//   "color"           — the official coloured tray PNGs, exactly what
//                       netbird-ui shows.
//
// The vector is upstream's own logo geometry: two wing paths whose union is the
// silhouette (upstream fills a third path over the overlap, which changes
// nothing once every path shares one colour). State is carried by the tint plus
// a small badge that mirrors the official artwork — a check when connected,
// three dots while connecting, a cross on error. Each badge is stroked twice,
// once fat in the surrounding background colour and once thin in its own, so it
// stays legible where it crosses the mark.
//
// Drawing rather than tinting a bitmap is deliberate: it is resolution-free at
// any bar size, and it needs no render effect, which is what the "color" style
// would otherwise require to follow a theme.
//
// `state` is Item's own string property rather than a redeclared one: QML will
// not let a subclass shadow it, and with no `states:` defined the state machine
// stays inert, so it behaves as the plain string the API asks for.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color dimColor: Qt.darker(color, 1.55)
  property color urgentColor: Color.urgent
  // What the badges are cut out of. Bind to whatever sits behind the icon.
  property color outlineColor: Color.background
  property string style: "theme"

  state: "disconnected"

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property bool notInstalled: root.state === "notInstalled"
  readonly property bool useColorIcons: root.style === "color"
  readonly property bool needsAttention: root.state === "error" || root.state === "needsLogin"
  readonly property bool subdued: notInstalled || root.state === "connecting" || root.state === "disconnected"

  readonly property color markColor: needsAttention
    ? urgentColor
    : (subdued ? dimColor : color)

  readonly property string assetState: {
    var value = String(root.state || "")
    if (value === "connected" || value === "connecting" || value === "error") return value
    if (value === "needsLogin") return "needs-login"
    return "disconnected"
  }

  // One unit of the upstream 32x32 view box, in pixels.
  readonly property real unit: iconSize / 32
  // Badge strokes: a floor in device pixels keeps them from vanishing in a bar
  // slot, and they grow with the icon everywhere else.
  readonly property real haloWidth: Math.max(1.6, unit * 3.0)
  readonly property real penWidth: Math.max(1.0, unit * 1.7)

  // --- "color": the official artwork, untinted -------------------------------

  Image {
    visible: root.useColorIcons
    anchors.fill: parent
    source: "assets/netbird-systemtray-" + root.assetState + ".png"
    sourceSize.width: Math.round(root.iconSize * Screen.devicePixelRatio)
    sourceSize.height: Math.round(root.iconSize * Screen.devicePixelRatio)
    fillMode: Image.PreserveAspectFit
    smooth: true
    mipmap: true
    // An absent CLI is not merely off, so fade the mark rather than tint it.
    opacity: root.notInstalled ? 0.45 : 1.0
  }

  // --- "theme": the same mark, drawn in the theme's colours ------------------

  Shape {
    visible: !root.useColorIcons
    // Upstream wraps the geometry in translate(0.5 4.5) within its 32x32 box.
    x: root.unit * 0.5
    y: root.unit * 4.5
    width: root.iconSize
    height: root.iconSize
    preferredRendererType: Shape.CurveRenderer
    opacity: root.notInstalled ? 0.55 : 1.0
    transform: Scale { xScale: root.unit; yScale: root.unit }

    ShapePath {
      fillColor: root.markColor
      strokeWidth: -1
      fillRule: ShapePath.WindingFill
      PathSvg { path: "M21.4631 0.523438C17.8173 0.857913 16.0028 2.95675 15.3171 4.01871L4.66406 22.4734H17.5163L30.1929 0.523438H21.4631Z" }
    }
    ShapePath {
      fillColor: root.markColor
      strokeWidth: -1
      fillRule: ShapePath.WindingFill
      PathSvg { path: "M17.5265 22.4737L0 3.88525C0 3.88525 19.8177 -1.44128 21.7493 15.1738L17.5265 22.4737Z" }
    }
  }

  Shape {
    visible: !root.useColorIcons && root.state === "connected"
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    transform: Scale { xScale: root.unit; yScale: root.unit }

    ShapePath {
      strokeColor: root.outlineColor
      strokeWidth: root.haloWidth / root.unit
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: "M17.5 24 L21.5 28 L30 19" }
    }
    ShapePath {
      strokeColor: root.color
      strokeWidth: root.penWidth / root.unit
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: "M17.5 24 L21.5 28 L30 19" }
    }
  }

  Shape {
    visible: !root.useColorIcons && root.needsAttention
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    transform: Scale { xScale: root.unit; yScale: root.unit }

    ShapePath {
      strokeColor: root.outlineColor
      strokeWidth: root.haloWidth / root.unit
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathSvg { path: "M21 20 L30 29" }
      PathSvg { path: "M30 20 L21 29" }
    }
    ShapePath {
      strokeColor: root.urgentColor
      strokeWidth: root.penWidth / root.unit
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathSvg { path: "M21 20 L30 29" }
      PathSvg { path: "M30 20 L21 29" }
    }
  }

  Row {
    visible: !root.useColorIcons && root.state === "connecting"
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    spacing: Math.max(1, Math.round(root.unit * 2.0))

    Repeater {
      model: 3
      Rectangle {
        width: Math.max(2, Math.round(root.unit * 5))
        height: width
        radius: width / 2
        color: root.color
        border.color: root.outlineColor
        border.width: Math.max(1, Math.round(root.unit * 1.2))
      }
    }
  }
}
