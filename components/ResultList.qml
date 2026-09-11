import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../YtmModel.js" as Model

// A flat list of result rows ({ header, title } or { item, trackIndex }):
// section headers, tracks and collections. Owns its keyboard cursor.
ListView {
  id: root

  property var rows: []
  property QtObject bar: null
  property var store: null
  property int cursorIndex: -1
  // Track rows get a remove action (playlist pages, Liked Music).
  property bool removable: false
  property string removeTooltip: "Remove"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // index = row index in `rows`
  signal activated(int index)
  signal playNextRequested(int index)
  signal addToQueueRequested(int index)
  signal removeRequested(int index)

  function moveCursor(delta) {
    cursorIndex = Model.nextSelectable(rows, cursorIndex, delta)
    if (cursorIndex >= 0) positionViewAtIndex(cursorIndex, ListView.Contain)
  }

  function rowAt(index) {
    return index >= 0 && index < rows.length && !rows[index].header ? rows[index] : null
  }

  onRowsChanged: cursorIndex = -1

  // The row under the keyboard cursor or the pointer, once it rests there a
  // moment, is a likely pick: its stream gets looked up in advance.
  property int _hintIndex: -1

  function hintRow(index) {
    _hintIndex = index
    hintTimer.restart()
  }

  onCursorIndexChanged: if (cursorIndex >= 0) hintRow(cursorIndex)

  Timer {
    id: hintTimer
    interval: 350
    onTriggered: {
      var row = root.rowAt(root._hintIndex)
      if (row && root.store) root.store.hint(row.item)
    }
  }

  clip: true
  boundsBehavior: Flickable.StopAtBounds
  spacing: Style.space(2)
  model: rows

  ScrollBar.vertical: ScrollBar {
    policy: ScrollBar.AsNeeded
  }

  delegate: Loader {
    id: row

    required property var modelData
    required property int index

    width: root.width
    sourceComponent: modelData.header ? headerComponent
      : modelData.item.type === "track" ? trackComponent
      : modelData.item.type === "query" ? queryComponent : collectionComponent

    Component {
      id: headerComponent

      Text {
        topPadding: row.index === 0 ? 0 : Style.space(10)
        bottomPadding: Style.space(4)
        textFormat: Text.PlainText
        text: String(row.modelData.title).toUpperCase()
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
    }

    Component {
      id: trackComponent

      TrackRow {
        bar: root.bar
        store: root.store
        track: row.modelData.item
        cursor: row.index === root.cursorIndex
        showQueueActions: true
        showRemove: root.removable
        removeTooltip: root.removeTooltip
        onActivated: root.activated(row.index)
        onPlayNextRequested: root.playNextRequested(row.index)
        onAddToQueueRequested: root.addToQueueRequested(row.index)
        onRemoveRequested: root.removeRequested(row.index)
        onHoveredChanged: if (hovered) root.hintRow(row.index)
      }
    }

    // A recent search or suggestion: history or search icon, text, and a
    // remove action on recent searches.
    Component {
      id: queryComponent

      Item {
        id: queryRow
        readonly property var query: row.modelData.item
        readonly property bool highlighted: row.index === root.cursorIndex || query.selected === true

        implicitHeight: Style.space(32)

        Rectangle {
          anchors.fill: parent
          radius: Style.spacing.labelGap
          color: queryHover.hovered || queryRow.highlighted ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
        }

        HoverHandler {
          id: queryHover
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.activated(row.index)
        }

        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(8)
          spacing: Style.space(10)

          Text {
            id: queryIcon
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: queryRow.query.recent ? "󰋚" : "󰍉"
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.icon
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - queryIcon.width - removeQuery.width - parent.spacing * 2
            textFormat: Text.PlainText
            text: queryRow.query.text
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          PanelActionButton {
            id: removeQuery
            anchors.verticalCenter: parent.verticalCenter
            opacity: queryRow.query.removable && (queryHover.hovered || row.index === root.cursorIndex) ? 1 : 0
            enabled: opacity > 0
            iconText: "󰅖"
            tooltipText: "Forget this search (x)"
            foreground: root.foreground
            onClicked: root.removeRequested(row.index)
          }
        }
      }
    }

    Component {
      id: collectionComponent

      CollectionRow {
        bar: root.bar
        store: root.store
        item: row.modelData.item
        cursor: row.index === root.cursorIndex
        onActivated: root.activated(row.index)
      }
    }
  }
}
