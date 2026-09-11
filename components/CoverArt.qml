import QtQuick
import Quickshell.Widgets
import qs.Commons

// Rounded cover image with a music glyph until (or unless) it loads. Images
// are decoded at twice the drawn size, never at their full source size, and
// kept out of Qt's pixmap cache so they go away with the panel instead of
// staying in the shell's memory.
Item {
  id: root

  property string source: ""
  // The service's Store: covers already on disk load from there instead of
  // the network.
  property var store: null
  readonly property string effectiveSource: store && source !== "" ? store.thumbSource(source) : source
  property real size: Style.space(40)
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real radius: Math.max(2, Math.round(size * 0.1))

  implicitWidth: size
  implicitHeight: size

  ClippingRectangle {
    anchors.fill: parent
    radius: root.radius
    color: Style.normalFillFor(root.foreground, Color.accent)

    Image {
      id: image
      anchors.fill: parent
      source: root.effectiveSource
      sourceSize.width: Math.round(root.size * 2)
      sourceSize.height: Math.round(root.size * 2)
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      visible: status === Image.Ready
    }

    Text {
      anchors.centerIn: parent
      visible: image.status !== Image.Ready
      text: "󰝚"
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Math.round(root.size * 0.42)
    }
  }
}
