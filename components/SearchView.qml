import QtQuick
import qs.Commons
import qs.Ui
import "../YtmModel.js" as Model

// Search field, filter chips and grouped results. Typing searches after a
// short pause; Enter searches right away and moves to the results.
Item {
  id: root

  property var service: null
  property QtObject bar: null

  readonly property var store: service ? service.store : null
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var resultRows: store ? Model.flattenSearch(store.result, store.filter) : []
  // Suggestions show above the results while you type; Tab / Shift+Tab put
  // them in the field. An empty field lists your recent searches.
  readonly property bool typing: searchField.activeFocus && searchField.text.trim() !== ""
  property int suggestionIndex: -1
  property bool _completing: false
  readonly property var rows: !store ? []
    : searchField.text.trim() === "" ? Model.recentRows(store.recent, 8)
    : (typing && (suggestionIndex >= 0 || store.suggestionsFor === searchField.text.trim())
        ? Model.suggestionRows(store.suggestions, suggestionIndex) : []).concat(resultRows)
  readonly property alias field: searchField
  readonly property alias results: resultList

  readonly property var filters: [
    { key: "", title: "All" },
    { key: "songs", title: "Songs" },
    { key: "albums", title: "Albums" },
    { key: "artists", title: "Artists" },
    { key: "playlists", title: "Playlists" },
    { key: "videos", title: "Videos" }
  ]

  // An album, playlist or artist was chosen: Panel.qml opens it.
  signal openRequested(var item)
  // The field gave up focus (Down, Enter, Esc): the panel takes keys again.
  signal leftField()

  function runSearch() {
    if (store) store.search(searchField.text, store.filter)
  }

  function setFilter(key) {
    if (store) store.search(searchField.text, key)
  }

  // Set the field without asking for suggestions (IPC search, completions).
  function setText(text) {
    _completing = true
    searchField.text = text
    _completing = false
  }

  // A search that led somewhere (Enter, or something from its results was
  // played or opened) joins the recent searches; half-typed ones don't.
  function rememberSearch() {
    if (store) store.rememberQuery(store.query)
  }

  // A recent search or suggestion was picked: search it right away.
  function searchFor(text) {
    setText(text)
    debounce.stop()
    suggestionIndex = -1
    if (store) {
      store.search(text, store.filter)
      store.rememberQuery(text)
    }
    root.leftField()
  }

  function cycleSuggestion(delta) {
    var list = store ? store.suggestions : []
    if (list.length === 0) return
    var i = suggestionIndex + delta
    if (i < 0) i = list.length - 1
    else if (i >= list.length) i = 0
    suggestionIndex = i
    setText(list[i].text)
    searchField.cursorPosition = searchField.text.length
  }

  function activate(index) {
    var row = resultList.rowAt(index)
    if (!row || !service) return
    if (row.item.type === "query") {
      searchFor(row.item.text)
      return
    }
    rememberSearch()
    if (row.item.type === "track") service.playNow(row.item)
    else root.openRequested(row.item)
  }

  function playNext(index) {
    var row = resultList.rowAt(index)
    if (!row || row.item.type !== "track" || !service) return
    rememberSearch()
    service.playNext(row.item)
  }

  function addToQueue(index) {
    var row = resultList.rowAt(index)
    if (!row || row.item.type !== "track" || !service) return
    rememberSearch()
    service.addToQueue(row.item)
  }

  // x on a recent search forgets it.
  function remove(index) {
    var row = resultList.rowAt(index)
    if (row && row.item.type === "query" && row.item.removable && store) store.forgetQuery(row.item.text)
  }

  function leaveField(moveToResults) {
    root.leftField()
    if (moveToResults && resultList.cursorIndex < 0) resultList.moveCursor(1)
  }

  TextField {
    id: searchField
    width: parent.width
    placeholderText: "Search YouTube Music"
    foreground: root.foreground
    font.family: root.fontFamily

    Component.onCompleted: if (root.store) root.setText(root.store.query)
    onTextChanged: {
      debounce.restart()
      if (root._completing) return
      root.suggestionIndex = -1
      suggestTimer.restart()
    }
    onActiveFocusChanged: if (root.store) root.store.inputFocused = activeFocus

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        debounce.stop()
        root.runSearch()
        root.rememberSearch()
        root.leaveField(true)
        event.accepted = true
      } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
        root.cycleSuggestion(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1)
        event.accepted = true
      } else if (event.key === Qt.Key_Down) {
        root.leaveField(true)
        event.accepted = true
      } else if (event.key === Qt.Key_Escape) {
        root.leaveField(false)
        event.accepted = true
      }
    }
  }

  Timer {
    id: debounce
    interval: 350
    onTriggered: root.runSearch()
  }

  Timer {
    id: suggestTimer
    interval: 120
    onTriggered: if (root.store) root.store.suggest(searchField.text)
  }

  Flow {
    id: chips
    anchors.top: searchField.bottom
    anchors.topMargin: Style.space(8)
    width: parent.width
    spacing: Style.space(4)

    Repeater {
      model: root.filters

      Button {
        required property var modelData
        text: modelData.title
        selected: !!root.store && root.store.filter === modelData.key
        foreground: root.foreground
        fontSize: Style.font.caption
        onClicked: root.setFilter(modelData.key)
      }
    }
  }

  Text {
    id: statusText
    anchors.top: chips.bottom
    anchors.topMargin: Style.space(8)
    width: parent.width
    visible: text !== ""
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    text: !root.store ? ""
      : root.store.searching ? "Searching…"
      : root.store.searchError !== "" ? root.store.searchError
      : root.store.query === "" ? (root.store.recent.length > 0 ? "" : "Search songs, albums, artists and playlists.")
      : root.resultRows.length === 0 ? "No results for \"" + root.store.query + "\""
      : ""
    color: root.store && root.store.searchError !== "" ? Color.urgent : Qt.darker(root.foreground, 1.5)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  ResultList {
    id: resultList
    anchors.top: statusText.visible ? statusText.bottom : chips.bottom
    anchors.topMargin: Style.space(8)
    anchors.bottom: parent.bottom
    width: parent.width
    bar: root.bar
    store: root.store
    rows: root.rows
    opacity: root.store && root.store.searching ? 0.5 : 1

    onActivated: function(index) { root.activate(index) }
    onPlayNextRequested: function(index) { root.playNext(index) }
    onAddToQueueRequested: function(index) { root.addToQueue(index) }
    onRemoveRequested: function(index) { root.remove(index) }
  }
}
