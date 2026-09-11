import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "components"

// The YouTube Music dropdown. BarWidget.qml loads this and injects the bar,
// the anchor button, the widget itself (bar identity) and the service.
//
// Tabs: Now (playing + queue), Search, Library and Home, with a page stack on
// top for albums, playlists, Liked Music, History and artists, and the
// playlist picker.
// Keys: 1–4 tabs · / search · j/k or ↑/↓ move · Enter play/open · n play next ·
// a add to queue · L like · p add to playlist · J/K move in queue ·
// x remove (queue, playlist page, Liked Music) · Space play/pause ·
// ←/→ seek 10 s (Now) · Esc leave field → close picker → back → close.
Panel {
  id: root
  moduleName: "damir.ytmusic"
  ipcTarget: "damir.ytmusic"
  manageIpc: false

  property var anchorItem: null
  property var service: null

  // The bar tracks the widget mounted in its slot, not this nested panel, so
  // the popout coordinator must compare against that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var store: service ? service.store : null
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool sessionProblem: !!service && (service.authState === "expired" || service.authState === "invalid")

  property string tab: "now"
  // Opened albums/playlists/artists, innermost last.
  property var stack: []
  readonly property var page: stack.length > 0 ? stack[stack.length - 1] : null
  property bool returnPressed: false

  readonly property var tabs: [
    { key: "now", title: "Now" },
    { key: "search", title: "Search" },
    { key: "library", title: "Library" },
    { key: "home", title: "Home" }
  ]

  function setTab(key) {
    picker.close()
    tab = key
    stack = []
    if (key === "search") Qt.callLater(focusSearch)
    else Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function focusSearch() {
    searchView.field.forceActiveFocus()
    searchView.field.selectAll()
  }

  function push(item) {
    picker.close()
    stack = stack.concat([item])
    keyCatcher.forceActiveFocus()
  }

  function back() {
    if (stack.length === 0) return false
    stack = stack.slice(0, -1)
    keyCatcher.forceActiveFocus()
    return true
  }

  // (Not "escape": QML rejects methods named after JS globals.)
  function handleEscape() {
    if (picker.open) picker.close()
    else if (!back()) close()
  }

  // The view whose list the keyboard cursor currently drives.
  function activeListOwner() {
    if (picker.open) return picker
    if (page) return collectionLoader.item
    if (tab === "search") return searchView
    if (tab === "library") return libraryView
    if (tab === "home") return homeView
    return null
  }

  function activeList() {
    var owner = activeListOwner()
    return owner ? owner.results : null
  }

  function moveCursor(delta) {
    var list = activeList()
    if (list) list.moveCursor(delta)
    else if (tab === "now") queueView.moveCursor(delta)
  }

  function activateCursor() {
    var owner = activeListOwner()
    var list = activeList()
    if (owner && list) owner.activate(list.cursorIndex)
    else if (tab === "now") queueView.activateCursor()
  }

  function listAction(action) {
    var owner = activeListOwner()
    var list = activeList()
    if (!owner || !list || list.cursorIndex < 0) return
    if (action === "next") owner.playNext(list.cursorIndex)
    else if (action === "queue") owner.addToQueue(list.cursorIndex)
  }

  // The track the keyboard is pointing at: a selected row, else what plays.
  function cursorTrack() {
    var list = activeList()
    var row = list ? list.rowAt(list.cursorIndex) : null
    if (row && row.item.type === "track") return row.item
    if (!list && tab === "now" && queueView.cursorIndex >= 0 && service) {
      var entry = service.queue[queueView.cursorIndex]
      if (entry) return entry.track
    }
    return service ? service.currentTrack : null
  }

  // The artist / album page of a track (from Now Playing, or `A` / `o` on
  // the selected row or the current track).
  function openArtist(artist) {
    if (artist && artist.id) push({ type: "artist", channelId: artist.id, name: artist.name, thumb: null })
  }

  function openArtistOf(track) {
    var artists = track && track.artists ? track.artists : []
    for (var i = 0; i < artists.length; i++) {
      if (artists[i].id) return openArtist(artists[i])
    }
  }

  function openAlbumOf(track) {
    if (!track || !track.album || !track.album.id) return
    push({ type: "album", browseId: track.album.id, title: track.album.name,
           thumb: track.thumb, thumbLarge: track.thumbLarge })
  }

  function removeCursor() {
    if (page && collectionLoader.item) {
      collectionLoader.item.remove(collectionLoader.item.results.cursorIndex)
    } else if (tab === "now" && !page) {
      queueView.removeCursor()
    } else if (tab === "search" && !page) {
      searchView.remove(searchView.results.cursorIndex)
    }
  }

  function openPicker(tracks) {
    var list = (tracks || []).filter(function(t) { return t && t.videoId })
    if (list.length === 0 || !service || !service.signedIn) return
    picker.tracks = list
    keyCatcher.forceActiveFocus()
  }

  // Tab requests (IPC "search") can arrive before this panel exists, so they
  // are also picked up when it opens.
  property int handledTabRequest: 0

  function applyTabRequest() {
    if (!store || store.tabRequestSeq === handledTabRequest) return
    handledTabRequest = store.tabRequestSeq
    // Show the requested query in the field, not whatever was typed last.
    if (store.requestedTab === "search") searchView.setText(store.query)
    setTab(store.requestedTab)
  }

  onOpenedChanged: {
    if (!opened) {
      picker.close()
      return
    }
    queueView.cursorIndex = -1
    applyTabRequest()
    Qt.callLater(function() { queueView.ensureVisible(root.service ? root.service.playlistPos : -1) })
  }

  Connections {
    target: root.store
    function onTabRequestSeqChanged() { if (root.opened) root.applyTabRequest() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: root.tab === "search" && !root.page ? searchView.field : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchView.field.activeFocus || libraryView.inputFocused || picker.inputFocused

      onCloseRequested: root.handleEscape()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0 && root.tab === "now" && !root.page && root.service) root.service.seekRelative(dx * 10)
      }
      onReturnRequested: {
        root.returnPressed = true
        root.activateCursor()
      }
      onActivateRequested: {
        // Enter also emits activate; only Space means play/pause.
        if (root.returnPressed) {
          root.returnPressed = false
          return
        }
        if (root.service) root.service.playPause()
      }
      onDeleteRequested: root.removeCursor()
      onTextKey: function(text) {
        if (text === "1") root.setTab("now")
        else if (text === "2" || text === "/") root.setTab("search")
        else if (text === "3") root.setTab("library")
        else if (text === "4") root.setTab("home")
        else if (text === "n") root.listAction("next")
        else if (text === "a") root.listAction("queue")
        else if (text === "L" && root.service) root.service.toggleLike(root.cursorTrack())
        else if (text === "p") root.openPicker([root.cursorTrack()])
        else if (text === "A") root.openArtistOf(root.cursorTrack())
        else if (text === "o") root.openAlbumOf(root.cursorTrack())
        else if (text === "s" && root.service) root.service.toggleShuffle()
        else if (text === "r" && root.service) root.service.cycleRepeat()
        else if (text === "J" && root.tab === "now") queueView.moveSelected(1)
        else if (text === "K" && root.tab === "now") queueView.moveSelected(-1)
      }

      Item {
        id: header
        width: parent.width
        height: tabRow.implicitHeight

        Row {
          id: tabRow
          spacing: Style.space(4)

          Button {
            visible: !!root.page
            iconText: "󰁍"
            tooltipText: "Back (Esc)"
            foreground: root.foreground
            onClicked: root.back()
          }

          Repeater {
            model: root.tabs

            Button {
              required property var modelData
              required property int index
              text: modelData.title
              tooltipText: modelData.title + " (" + (index + 1) + ")"
              selected: root.tab === modelData.key && !root.page
              foreground: root.foreground
              onClicked: root.setTab(modelData.key)
            }
          }
        }
      }

      // uv / deno / mpv-mpris missing (a fresh Omarchy lacks uv and deno).
      Rectangle {
        id: toolsBanner
        anchors.top: header.bottom
        anchors.topMargin: visible ? Style.space(8) : 0
        width: parent.width
        height: visible ? toolsRow.implicitHeight + Style.space(12) : 0
        visible: !!root.service && root.service.missingTools.length > 0
        radius: Style.spacing.labelGap
        color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.15)

        Row {
          id: toolsRow
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(6)
          spacing: Style.space(8)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - toolsButton.width - parent.spacing
            textFormat: Text.PlainText
            text: root.service ? "YouTube Music needs " + root.service.missingTools.join(", ")
              + " (" + root.service.installCommand + ")." : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          Button {
            id: toolsButton
            anchors.verticalCenter: parent.verticalCenter
            text: "Install"
            tooltipText: "Opens a terminal running " + (root.service ? root.service.installCommand : "")
            foreground: root.foreground
            fontSize: Style.font.caption
            onClicked: root.service.installTools()
          }
        }
      }

      Rectangle {
        id: banner
        anchors.top: toolsBanner.bottom
        anchors.topMargin: visible ? Style.space(8) : 0
        width: parent.width
        height: visible ? bannerRow.implicitHeight + Style.space(12) : 0
        visible: root.sessionProblem
        radius: Style.spacing.labelGap
        color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.15)

        Row {
          id: bannerRow
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(6)
          spacing: Style.space(8)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - bannerButton.width - parent.spacing
            textFormat: Text.PlainText
            text: "Your YouTube Music sign-in expired. Search and playback still work."
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          Button {
            id: bannerButton
            anchors.verticalCenter: parent.verticalCenter
            text: "Sign in"
            foreground: root.foreground
            fontSize: Style.font.caption
            onClicked: root.service.signIn()
          }
        }
      }

      Item {
        id: content
        anchors.top: banner.bottom
        anchors.topMargin: Style.space(12)
        anchors.bottom: parent.bottom
        width: parent.width

        Column {
          id: nowTab
          anchors.fill: parent
          visible: root.tab === "now" && !root.page
          spacing: Style.space(14)

          NowPlayingView {
            id: nowPlaying
            width: parent.width
            service: root.service
            bar: root.bar
            onAddToPlaylistRequested: root.openPicker([root.service.currentTrack])
            onArtistRequested: function(artist) { root.openArtist(artist) }
            onAlbumRequested: function(track) { root.openAlbumOf(track) }
          }

          PanelSeparator {
            id: separator
            width: parent.width
            foreground: root.foreground
          }

          QueueView {
            id: queueView
            width: parent.width
            height: nowTab.height - nowPlaying.height - separator.height - nowTab.spacing * 2
            service: root.service
            bar: root.bar
          }
        }

        SearchView {
          id: searchView
          anchors.fill: parent
          visible: root.tab === "search" && !root.page
          service: root.service
          bar: root.bar
          onOpenRequested: function(item) { root.push(item) }
          onLeftField: keyCatcher.forceActiveFocus()
        }

        LibraryView {
          id: libraryView
          anchors.fill: parent
          visible: root.tab === "library" && !root.page
          service: root.service
          bar: root.bar
          onOpenRequested: function(item) { root.push(item) }
          onLeftField: keyCatcher.forceActiveFocus()
        }

        HomeView {
          id: homeView
          anchors.fill: parent
          visible: root.tab === "home" && !root.page
          service: root.service
          bar: root.bar
          onOpenRequested: function(item) { root.push(item) }
        }

        Loader {
          id: collectionLoader
          anchors.fill: parent
          active: !!root.page
          sourceComponent: CollectionView {
            service: root.service
            bar: root.bar
            target: root.page
            onOpenRequested: function(item) { root.push(item) }
            onCloseRequested: root.back()
          }
        }

        PlaylistPicker {
          id: picker
          anchors.fill: parent
          service: root.service
          bar: root.bar
          onClosed: keyCatcher.forceActiveFocus()
        }
      }
    }
  }
}
