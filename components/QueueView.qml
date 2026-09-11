import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// The play queue (mpv's playlist): click to jump, hover to move or remove.
// Owns its keyboard cursor; Panel.qml forwards keys.
Item {
  id: root

  property var service: null
  property QtObject bar: null
  property int cursorIndex: -1

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var queue: service ? service.queue : []
  readonly property int currentIndex: service ? service.playlistPos : -1

  function ensureVisible(index) {
    if (index >= 0 && index < list.count) list.positionViewAtIndex(index, ListView.Contain)
  }

  function moveCursor(delta) {
    if (queue.length === 0) {
      cursorIndex = -1
      return
    }
    if (cursorIndex < 0) cursorIndex = Math.max(0, currentIndex)
    else cursorIndex = Math.max(0, Math.min(queue.length - 1, cursorIndex + delta))
    ensureVisible(cursorIndex)
  }

  function activateCursor() {
    if (cursorIndex < 0 || !service) return false
    service.jumpTo(cursorIndex)
    return true
  }

  function removeCursor() {
    if (cursorIndex < 0 || !service) return
    service.removeAt(cursorIndex)
    if (cursorIndex >= queue.length - 1) cursorIndex = queue.length - 2
  }

  function moveSelected(delta) {
    if (cursorIndex < 0 || !service) return
    var target = cursorIndex + delta
    if (service.move(cursorIndex, target)) {
      cursorIndex = target
      ensureVisible(cursorIndex)
    }
  }

  Item {
    id: header
    width: parent.width
    height: Math.max(heading.implicitHeight, autoplayButton.implicitHeight)

    Text {
      id: heading
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.queue.length === 0 ? "QUEUE"
        : "QUEUE  " + (root.currentIndex >= 0 ? (root.currentIndex + 1) + " / " : "") + root.queue.length
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }

    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Button {
        id: autoplayButton
        readonly property bool autoplayOn: !!root.service && root.service.autoplay
        text: "Autoplay"
        selected: autoplayOn
        tooltipText: autoplayOn ? "Similar songs follow when the queue ends (click to turn off)"
          : "Keep playing similar songs when the queue ends"
        foreground: root.foreground
        fontSize: Style.font.caption
        onClicked: root.service.toggleAutoplay()
      }

      Button {
        visible: root.queue.length > 1
        text: "Clear"
        tooltipText: "Remove everything except the current track"
        foreground: root.foreground
        fontSize: Style.font.caption
        onClicked: root.service.clearUpcoming()
      }
    }
  }

  ListView {
    id: list
    anchors.top: header.bottom
    anchors.topMargin: Style.space(6)
    anchors.bottom: parent.bottom
    width: parent.width
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    spacing: Style.space(2)
    model: root.queue
    reuseItems: true

    ScrollBar.vertical: ScrollBar {
      policy: ScrollBar.AsNeeded
    }

    delegate: TrackRow {
      required property var modelData
      required property int index

      width: list.width
      bar: root.bar
      store: root.service ? root.service.store : null
      track: modelData.track
      current: modelData.current
      cursor: index === root.cursorIndex
      showMove: true
      showRemove: true

      onActivated: root.service.jumpTo(index)
      onRemoveRequested: root.service.removeAt(index)
      onMoveRequested: function(delta) { root.service.move(index, index + delta) }
    }

    Text {
      anchors.centerIn: parent
      visible: list.count === 0
      textFormat: Text.PlainText
      text: "The queue is empty"
      color: Qt.darker(root.foreground, 1.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
