import QtQuick
import qs.Commons
import qs.Ui

// Shown where your account is needed but you're signed out (or the session
// expired). Sign-in runs `bin/ytm auth` in a floating terminal.
Column {
  id: root

  property var service: null
  property QtObject bar: null
  property bool expired: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  spacing: Style.space(10)

  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: root.expired ? "Your YouTube Music sign-in expired" : "Sign in to YouTube Music"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.subtitle
    font.bold: true
    wrapMode: Text.Wrap
  }

  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: "Your playlists, likes, history and recommendations need your account. "
      + "Sign-in copies your YouTube session from your Chromium profile — "
      + "nothing goes through the clipboard."
    color: Qt.darker(root.foreground, 1.3)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
  }

  Button {
    iconText: "󰍂"
    text: root.expired ? "Sign in again" : "Sign in"
    foreground: root.foreground
    onClicked: if (root.service) root.service.signIn()
  }

  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: "Search and playback work without an account."
    color: Qt.darker(root.foreground, 1.6)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.Wrap
  }
}
