import QtQuick
import qs.Commons
import qs.Ui
import "../YtmModel.js" as Model

// An album, playlist, Liked Music or artist page: header with Play, Shuffle
// and Queue all, then its tracks (and an artist's albums and singles).
Item {
  id: root

  property var service: null
  property QtObject bar: null
  // The item that was opened (album / playlist / artist / { type: "liked" }).
  property var target: null

  property var page: null
  property bool loading: false
  property string error: ""

  readonly property var store: service ? service.store : null
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var ref: Model.collectionTarget(target)
  readonly property bool isArtist: !!ref && ref.kind === "artist"
  readonly property bool isLiked: !!ref && ref.kind === "liked"
  readonly property bool isHistory: !!ref && ref.kind === "history"
  readonly property bool editable: !!page && page.editable === true
  property bool confirmDelete: false
  readonly property var tracks: !page ? [] : isArtist ? (page.songs || []) : (page.tracks || [])
  readonly property var rows: !page ? [] : isArtist ? Model.flattenArtist(page)
    : isHistory ? Model.historyRows(tracks) : Model.trackRows(tracks)
  readonly property alias results: resultList

  readonly property string title: page ? (page.title || page.name || "") : (target ? (target.title || target.name || "") : "")
  readonly property string subtitle: !page ? Model.itemSubtitle(target)
    : isArtist ? (page.subtitle || "Artist")
    : page.subtitle + (page.truncated ? " • showing " + tracks.length : "")

  signal openRequested(var item)
  // The page itself went away (playlist deleted).
  signal closeRequested()

  // Playlist pages remove from the playlist; Liked Music un-likes.
  function remove(index) {
    var row = resultList.rowAt(index)
    if (!row || row.item.type !== "track" || !service) return
    var track = row.item
    if (isLiked) {
      if (service.setLike(track, false)) page = Model.withoutTrack(page, track)
    } else if (editable) {
      service.removeFromPlaylist(page.id, [track], function(reply) {
        if (reply.ok) root.page = Model.withoutTrack(root.page, track)
      })
    }
  }

  function deletePlaylist() {
    if (!editable || !service) return
    if (!confirmDelete) {
      confirmDelete = true
      confirmReset.restart()
      return
    }
    confirmDelete = false
    service.deletePlaylist({ playlistId: page.id, title: page.title }, function(reply) {
      if (reply.ok) root.closeRequested()
    })
  }

  Timer {
    id: confirmReset
    interval: 4000
    onTriggered: root.confirmDelete = false
  }

  function load() {
    if (!store || !ref) return
    var requested = ref
    page = null
    loading = true
    error = ""
    store.loadCollection(requested.kind, requested.id, function(reply) {
      if (!root.ref || root.ref.kind !== requested.kind || root.ref.id !== requested.id) return
      root.loading = false
      if (reply.ok) root.page = reply.result
      else root.error = reply.error.message
    })
  }

  function activate(index) {
    var row = resultList.rowAt(index)
    if (!row || !service) return
    if (row.trackIndex !== undefined) service.playCollection(tracks, row.trackIndex, false)
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

  onRefChanged: load()
  Component.onCompleted: load()

  Row {
    id: header
    width: parent.width
    spacing: Style.space(14)

    CoverArt {
      id: cover
      size: Style.space(88)
      radius: root.isArtist ? size / 2 : Math.max(2, Math.round(size * 0.1))
      store: root.store
      source: root.page && root.page.thumbLarge ? root.page.thumbLarge
        : root.target ? (root.target.thumbLarge || root.target.thumb || "") : ""
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - cover.width - parent.spacing
      spacing: Style.space(4)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.subtitle
        visible: text !== ""
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Flow {
        width: parent.width
        spacing: Style.space(4)
        visible: root.tracks.length > 0

        Button {
          iconText: "󰐊"
          text: "Play"
          foreground: root.foreground
          fontSize: Style.font.caption
          onClicked: root.service.playCollection(root.tracks, 0, false)
        }

        Button {
          text: "Shuffle"
          tooltipText: "Turn shuffle on and play in random order"
          foreground: root.foreground
          fontSize: Style.font.caption
          onClicked: root.service.playCollection(root.tracks, 0, true)
        }

        Button {
          text: "Queue all"
          foreground: root.foreground
          fontSize: Style.font.caption
          onClicked: root.service.queueAll(root.tracks)
        }

        Button {
          visible: root.editable
          text: root.confirmDelete ? "Really delete?" : "Delete"
          tooltipText: "Delete this playlist from your account"
          foreground: root.confirmDelete ? Color.urgent : root.foreground
          fontSize: Style.font.caption
          onClicked: root.deletePlaylist()
        }
      }
    }
  }

  Text {
    id: statusText
    anchors.top: header.bottom
    anchors.topMargin: Style.space(10)
    width: parent.width
    visible: text !== ""
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    text: root.loading ? "Loading…" : root.error !== "" ? root.error
      : root.page && root.rows.length === 0 ? "Nothing here" : ""
    color: root.error !== "" ? Color.urgent : Qt.darker(root.foreground, 1.5)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  ResultList {
    id: resultList
    anchors.top: statusText.visible ? statusText.bottom : header.bottom
    anchors.topMargin: Style.space(10)
    anchors.bottom: parent.bottom
    width: parent.width
    bar: root.bar
    store: root.store
    rows: root.rows
    removable: root.editable || root.isLiked
    removeTooltip: root.isLiked ? "Remove from Liked Music" : "Remove from playlist"

    onActivated: function(index) { root.activate(index) }
    onPlayNextRequested: function(index) { root.playNext(index) }
    onAddToQueueRequested: function(index) { root.addToQueue(index) }
    onRemoveRequested: function(index) { root.remove(index) }
  }
}
