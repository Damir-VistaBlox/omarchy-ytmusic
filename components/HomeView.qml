import QtQuick
import qs.Commons
import qs.Ui
import "../YtmModel.js" as Model

// YouTube Music's home shelves (personal when signed in). Songs play their
// shelf from that song; albums, playlists and artists open as pages.
Item {
  id: root

  property var service: null
  property QtObject bar: null

  readonly property var store: service ? service.store : null
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var rows: store ? Model.homeRows(store.shelves) : []
  readonly property alias results: resultList

  signal openRequested(var item)

  function refresh(force) {
    if (store) store.loadHome(force)
  }

  function activate(index) {
    var row = resultList.rowAt(index)
    if (!row || !service) return
    if (row.item.type === "track") service.playCollection(Model.shelfTracks(store.shelves, row.shelfIndex), row.trackIndex, false)
    else root.openRequested(row.item)
  }

  function playNext(index) {
    var row = resultList.rowAt(index)
    if (row && row.item.type === "track" && service) service.playNext(row.item)
  }

  function addToQueue(index) {
    var row = resultList.rowAt(index)
    if (row && row.item.type === "track" && service) service.addToQueue(row.item)
  }

  onVisibleChanged: if (visible) refresh(false)

  Item {
    id: header
    width: parent.width
    height: Math.max(statusText.implicitHeight, refreshButton.implicitHeight)

    Text {
      id: statusText
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - refreshButton.width - Style.space(8)
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: !root.store ? ""
        : root.store.homeLoading && root.rows.length === 0 ? "Loading your recommendations…"
        : root.store.homeError !== "" ? root.store.homeError
        : root.service && !root.service.signedIn ? "General picks — sign in for yours."
        : "Picked for you"
      color: root.store && root.store.homeError !== "" ? Color.urgent : Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Button {
      id: refreshButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰑐"
      tooltipText: "Refresh"
      foreground: root.foreground
      fontSize: Style.font.caption
      onClicked: root.refresh(true)
    }
  }

  ResultList {
    id: resultList
    anchors.top: header.bottom
    anchors.topMargin: Style.space(8)
    anchors.bottom: parent.bottom
    width: parent.width
    bar: root.bar
    store: root.store
    rows: root.rows

    onActivated: function(index) { root.activate(index) }
    onPlayNextRequested: function(index) { root.playNext(index) }
    onAddToQueueRequested: function(index) { root.addToQueue(index) }
  }
}
