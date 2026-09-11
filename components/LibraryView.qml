import QtQuick
import qs.Commons
import qs.Ui
import "../YtmModel.js" as Model

// Your account, Liked Music and playlists, with "new playlist".
Item {
  id: root

  property var service: null
  property QtObject bar: null

  readonly property var store: service ? service.store : null
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool signedIn: !!service && service.signedIn
  readonly property var account: service ? service.account : null
  readonly property var rows: store ? Model.libraryRows(store.playlists) : []
  readonly property alias results: resultList
  readonly property bool inputFocused: nameField.activeFocus

  signal openRequested(var item)
  signal leftField()

  function refresh(force) {
    if (signedIn && store) store.loadLibrary(force)
  }

  function activate(index) {
    var row = resultList.rowAt(index)
    if (row) root.openRequested(row.item)
  }

  function playNext(index) {}
  function addToQueue(index) {}

  function createPlaylist() {
    var name = nameField.text.trim()
    if (name === "" || !service) return
    service.createPlaylist(name, [], function(reply) {
      if (reply.ok) nameField.text = ""
    })
  }

  onVisibleChanged: if (visible) refresh(false)
  onSignedInChanged: if (visible) refresh(false)

  SignInCard {
    width: parent.width
    visible: !root.signedIn
    service: root.service
    bar: root.bar
    expired: !!root.service && (root.service.authState === "expired" || root.service.authState === "invalid")
  }

  Item {
    id: content
    anchors.fill: parent
    visible: root.signedIn

    Row {
      id: accountRow
      width: parent.width
      spacing: Style.space(10)

      CoverArt {
        id: photo
        anchors.verticalCenter: parent.verticalCenter
        size: Style.space(34)
        radius: size / 2
        store: root.store
        source: root.account && root.account.photo ? root.account.photo : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - photo.width - signOut.width - parent.spacing * 2
        spacing: Style.space(1)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.account && root.account.name ? root.account.name : "Signed in"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.account && root.account.handle ? root.account.handle : ""
          visible: text !== ""
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Button {
        id: signOut
        anchors.verticalCenter: parent.verticalCenter
        text: "Sign out"
        tooltipText: "Delete the saved session from this computer"
        foreground: root.foreground
        fontSize: Style.font.caption
        onClicked: root.service.signOut()
      }
    }

    Row {
      id: createRow
      anchors.top: accountRow.bottom
      anchors.topMargin: Style.space(12)
      width: parent.width
      spacing: Style.space(6)

      TextField {
        id: nameField
        width: parent.width - createButton.width - parent.spacing
        placeholderText: "New playlist name"
        foreground: root.foreground
        font.family: root.fontFamily

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.createPlaylist()
            event.accepted = true
          } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Down) {
            root.leftField()
            if (event.key === Qt.Key_Down) resultList.moveCursor(1)
            event.accepted = true
          }
        }
      }

      Button {
        id: createButton
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰐕"
        text: "Create"
        tooltipText: "Create a private playlist"
        enabled: nameField.text.trim() !== ""
        opacity: enabled ? 1 : 0.4
        foreground: root.foreground
        fontSize: Style.font.caption
        onClicked: root.createPlaylist()
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
      text: !root.store ? "" : root.store.libraryLoading && root.store.playlists.length === 0 ? "Loading your library…"
        : root.store.libraryError
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
}
