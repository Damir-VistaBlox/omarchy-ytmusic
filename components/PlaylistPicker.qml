import QtQuick
import qs.Commons
import qs.Ui
import "../YtmModel.js" as Model

// "Add to playlist": your own playlists, or a new one created with the songs.
// Covers the panel content while `tracks` is non-empty.
Rectangle {
  id: root

  property var service: null
  property QtObject bar: null
  property var tracks: []

  readonly property bool open: tracks.length > 0
  readonly property var store: service ? service.store : null
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var rows: store ? Model.ownedPlaylists(store.playlists).map(function(p) { return { item: p } }) : []
  readonly property alias results: resultList
  readonly property bool inputFocused: nameField.activeFocus

  signal closed()

  function close() {
    if (!open) return
    tracks = []
    nameField.text = ""
    closed()
  }

  function activate(index) {
    var row = resultList.rowAt(index)
    if (!row || !service) return
    service.addToPlaylist(row.item, tracks)
    close()
  }

  function playNext(index) {}
  function addToQueue(index) {}

  function createWithTracks() {
    var name = nameField.text.trim()
    if (name === "" || !service) return
    service.createPlaylist(name, tracks)
    close()
  }

  visible: open
  color: Color.popups.background

  onOpenChanged: if (open && store) store.loadLibrary(false)

  // Keep clicks from reaching the views underneath.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
  }

  Item {
    id: header
    width: parent.width
    height: Math.max(titleColumn.implicitHeight, closeButton.implicitHeight)

    Column {
      id: titleColumn
      width: parent.width - closeButton.width
      spacing: Style.space(2)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "Add to playlist"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.tracks.length === 1 ? Model.mediaTitle(root.tracks[0]) : root.tracks.length + " songs"
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    PanelActionButton {
      id: closeButton
      anchors.right: parent.right
      iconText: "󰅖"
      tooltipText: "Cancel (Esc)"
      foreground: root.foreground
      onClicked: root.close()
    }
  }

  Row {
    id: createRow
    anchors.top: header.bottom
    anchors.topMargin: Style.space(12)
    width: parent.width
    spacing: Style.space(6)

    TextField {
      id: nameField
      width: parent.width - createButton.width - parent.spacing
      placeholderText: "New playlist with this song"
      foreground: root.foreground
      font.family: root.fontFamily

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.createWithTracks()
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        }
      }
    }

    Button {
      id: createButton
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰐕"
      text: "Create"
      enabled: nameField.text.trim() !== ""
      opacity: enabled ? 1 : 0.4
      foreground: root.foreground
      fontSize: Style.font.caption
      onClicked: root.createWithTracks()
    }
  }

  Text {
    id: statusText
    anchors.top: createRow.bottom
    anchors.topMargin: Style.space(8)
    width: parent.width
    visible: text !== ""
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    text: !root.store ? "" : root.store.libraryLoading && root.rows.length === 0 ? "Loading your playlists…"
      : root.store.libraryError !== "" ? root.store.libraryError
      : root.rows.length === 0 ? "You have no playlists yet — create one above." : ""
    color: root.store && root.store.libraryError !== "" ? Color.urgent : Qt.darker(root.foreground, 1.5)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  ResultList {
    id: resultList
    anchors.top: statusText.visible ? statusText.bottom : createRow.bottom
    anchors.topMargin: Style.space(8)
    anchors.bottom: parent.bottom
    width: parent.width
    bar: root.bar
    store: root.store
    rows: root.rows

    onActivated: function(index) { root.activate(index) }
  }
}
