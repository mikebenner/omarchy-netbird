import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property bool crossed: false
  property bool warning: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  // The NetBird mark is two straight-edged wings that meet in a checkmark, so
  // it survives being drawn as flat polygons at bar size where a traced SVG or
  // a curved silhouette would turn to mush. Same reasoning as the Tailscale
  // widget's dot grid: native shapes beat a tiny scaled image.
  Canvas {
    id: mark
    anchors.fill: parent
    antialiasing: true

    readonly property color markColor: root.color

    onMarkColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var s = Math.min(width, height)
      if (s <= 0) return
      var ox = (width - s) / 2
      var oy = (height - s) / 2
      ctx.fillStyle = mark.markColor

      function poly(points) {
        ctx.beginPath()
        ctx.moveTo(ox + points[0][0] * s, oy + points[0][1] * s)
        for (var i = 1; i < points.length; i++) ctx.lineTo(ox + points[i][0] * s, oy + points[i][1] * s)
        ctx.closePath()
        ctx.fill()
      }

      // Left wing: a broad quad sheared down and to the right.
      poly([[0.03, 0.17], [0.31, 0.17], [0.63, 0.85], [0.29, 0.85]])
      // Right wing: a taller triangle falling back to the same landing point.
      poly([[0.57, 0.17], [0.97, 0.17], [0.45, 0.85]])
    }
  }

  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: parent.width * 1.22
    height: Math.max(2, parent.height * 0.14)
    radius: height / 2
    color: root.color
    rotation: -45
  }

  BorderSurface {
    visible: root.warning
    width: Math.max(7, parent.width * 0.42)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}
