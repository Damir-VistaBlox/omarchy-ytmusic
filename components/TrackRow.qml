import QtQuick
import qs.Commons
import qs.Ui
import "../YtmModel.js" as Model

// One track: cover, title, artists and duration. Hovering (or the keyboard
// cursor) swaps the duration for row actions.
Item {
  id: root

  property var track: null
  property bool current: false
  property bool cursor: false
  property bool showMove: false
  property bool showRemove: false
  property bool showQueueActions: false
  property string removeTooltip: "Remove"
  property QtObject bar: null
  property var store: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool showActions: (hover.hovered || cursor) && (showMove || showRemove || showQueueActions)
  readonly property bool hovered: hover.hovered

  signal activated()
  signal removeRequested()
  signal moveRequested(int delta)
  signal playNextRequested()
  signal addToQueueRequested()

  implicitHeight: Style.space(46)

  Rectangle {
    anchors.fill: parent
    radius: Style.spacing.labelGap
    color: root.current ? Style.selectedFillFor(root.foreground, Color.accent)
      : (hover.hovered || root.cursor ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")
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
      size: Style.space(34)
      store: root.store
      source: root.track && root.track.thumb ? root.track.thumb : ""
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - cover.width - trailing.width - parent.spacing * 2
      spacing: Style.space(1)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.track ? root.track.title : ""
        color: root.foreground
        opacity: root.track && root.track.available === false ? 0.5 : 1
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: root.current
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: Model.itemSubtitle(root.track)
        visible: text !== ""
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Item {
      id: trailing
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(duration.implicitWidth, actions.implicitWidth)
      height: parent.height

      Text {
        id: duration
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.showActions
        textFormat: Text.PlainText
        text: root.track && root.track.durationSec ? Model.formatDuration(root.track.durationSec) : ""
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        id: actions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: root.showActions
        spacing: Style.space(2)

        PanelActionButton {
          visible: root.showQueueActions
          iconText: "󰒭"
          tooltipText: "Play next"
          foreground: root.foreground
          onClicked: root.playNextRequested()
        }

        PanelActionButton {
          visible: root.showQueueActions
          iconText: "󰐕"
          tooltipText: "Add to queue"
          foreground: root.foreground
          onClicked: root.addToQueueRequested()
        }

        PanelActionButton {
          visible: root.showMove
          iconText: "󰁝"
          tooltipText: "Move up"
          foreground: root.foreground
          onClicked: root.moveRequested(-1)
        }

        PanelActionButton {
          visible: root.showMove
          iconText: "󰁅"
          tooltipText: "Move down"
          foreground: root.foreground
          onClicked: root.moveRequested(1)
        }

        PanelActionButton {
          visible: root.showRemove
          iconText: "󰅖"
          tooltipText: root.removeTooltip
          foreground: root.foreground
          onClicked: root.removeRequested()
        }
      }
    }
  }
}
