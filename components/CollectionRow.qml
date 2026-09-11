import QtQuick
import qs.Commons
import "../YtmModel.js" as Model

// An album, playlist or artist in a list; clicking opens it.
Item {
  id: root

  property var item: null
  property bool cursor: false
  property QtObject bar: null
  property var store: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool isArtist: item && item.type === "artist"

  signal activated()

  implicitHeight: Style.space(50)

  Rectangle {
    anchors.fill: parent
    radius: Style.spacing.labelGap
    color: hover.hovered || root.cursor ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
  }

  HoverHandler {
    id: hover
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }

  Row {
    anchors.fill: parent
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(8)
    spacing: Style.space(10)

    CoverArt {
      id: cover
      anchors.verticalCenter: parent.verticalCenter
      size: Style.space(38)
      radius: root.isArtist ? size / 2 : Math.max(2, Math.round(size * 0.1))
      store: root.store
      source: root.item && root.item.thumb ? root.item.thumb : ""
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - cover.width - chevron.width - parent.spacing * 2
      spacing: Style.space(1)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.item ? (root.item.title || root.item.name || "") : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: Model.itemSubtitle(root.item)
        visible: text !== ""
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Text {
      id: chevron
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: "󰅂"
      color: Qt.darker(root.foreground, 1.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
