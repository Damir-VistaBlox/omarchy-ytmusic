import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "YtmModel.js" as Model

// Bar entry for damir.ytmusic: a music icon, or the icon plus scrolling
// now-playing text (setting "display": "icon" | "player"). Left click opens
// the panel, middle click plays/pauses, right click switches icon/player, the
// wheel skips tracks. One instance per monitor; all state lives in the service.
BarWidget {
  id: root
  moduleName: Model.PLUGIN_ID

  // serviceFor() is a plain call, so resolve again until the service exists.
  property var service: null

  readonly property string displayMode: Model.normalizeDisplay(setting("display", "icon"))
  readonly property bool playerMode: !vertical && displayMode === "player"
  readonly property var track: service ? service.currentTrack : null
  readonly property bool hasMedia: service ? service.hasMedia : false
  readonly property bool playing: service ? service.playing : false
  readonly property string tooltip: track ? Model.mediaTitle(track) : "YouTube Music"
  readonly property Item anchorButton: playerMode ? playerButton : iconButton

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  // The panel is created on first open and destroyed a while after closing,
  // so its rows and cover images don't sit in the shell's memory.
  property bool panelWanted: false
  property bool openWhenLoaded: false
  property bool reportedOpen: false
  property real wheelRemainder: 0
  property real lastWheelAt: 0

  function resolveService() {
    var found = bar && bar.shell && typeof bar.shell.serviceFor === "function"
      ? bar.shell.serviceFor(Model.PLUGIN_ID) : null
    if (found !== service) service = found
  }

  function open() {
    panelWanted = true
    if (panelLoader.item) panelLoader.item.open()
    else openWhenLoaded = true
  }

  function close() {
    openWhenLoaded = false
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (opened) close()
    else open()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = root.anchorButton
    target.hostWidget = root
    target.service = root.service
  }

  function handlePress(button) {
    var action = Model.clickAction(button)
    if (action === "playPause") {
      if (!service || !service.playPause()) togglePanel()
    } else if (action === "toggleDisplay") {
      toggleDisplay()
    } else {
      togglePanel()
    }
  }

  function toggleDisplay() {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.display = Model.nextDisplay(displayMode)
    // Applied locally first so the bar changes on the click itself; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // One notch, one track; touchpads accumulate, and a short cooldown keeps a
  // fast flick from skipping half the queue.
  function wheel(delta) {
    var result = Util.wheelSteps(wheelRemainder, delta)
    wheelRemainder = result.remainder
    if (result.steps === 0 || !service) return
    var now = Date.now()
    if (now - lastWheelAt < 250) return
    lastWheelAt = now
    if (result.steps > 0) service.previous()
    else service.next()
  }

  function syncOpenReport() {
    if (!service || opened === reportedOpen) return
    reportedOpen = opened
    service.panelOpenChanged(opened)
  }

  implicitWidth: playerMode ? playerButton.implicitWidth : iconButton.implicitWidth
  implicitHeight: playerMode ? playerButton.implicitHeight : iconButton.implicitHeight

  onBarChanged: {
    resolveService()
    injectPanel()
  }
  onSettingsChanged: injectPanel()
  onServiceChanged: {
    injectPanel()
    syncOpenReport()
  }
  onAnchorButtonChanged: injectPanel()
  onOpenedChanged: {
    if (opened) unloadTimer.stop()
    else unloadTimer.restart()
    syncOpenReport()
  }
  Component.onDestruction: if (reportedOpen && service) service.panelOpenChanged(false)

  Timer {
    interval: 250
    repeat: true
    running: root.service === null && root.bar !== null
    onTriggered: root.resolveService()
  }

  Timer {
    id: unloadTimer
    interval: 45000
    onTriggered: {
      if (root.opened) return
      root.panelWanted = false
      // Reclaim the destroyed panel's JS objects now rather than whenever the
      // engine next feels like collecting.
      Qt.callLater(gc)
    }
  }

  Loader {
    id: panelLoader
    active: root.panelWanted
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      if (root.openWhenLoaded) {
        root.openWhenLoaded = false
        item.open()
      }
    }
  }

  BarIconButton {
    id: iconButton
    anchors.fill: parent
    visible: !root.playerMode
    bar: root.bar
    text: "󰝚"
    dimmed: root.hasMedia && !root.playing
    tooltipText: root.tooltip

    onPressed: function(b) { root.handlePress(b) }
    onWheelMoved: function(delta) { root.wheel(delta) }
  }

  WidgetButton {
    id: playerButton
    anchors.fill: parent
    visible: root.playerMode
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: contentRow.implicitWidth + Style.space(14)
    tooltipText: root.tooltip

    onPressed: function(b) { root.handlePress(b) }
    onWheelMoved: function(delta) { root.wheel(delta) }

    Row {
      id: contentRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.playing ? "󰏤" : (root.hasMedia ? "󰐊" : "󰝚")
        color: root.hasMedia && !root.playing ? Qt.darker(playerButton.foreground, 1.5) : playerButton.foreground
        font.family: playerButton.fontFamily
        font.pixelSize: Style.font.body
      }

      Item {
        id: clipItem
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(Style.space(180), label.implicitWidth)
        height: label.implicitHeight
        clip: true

        Text {
          id: label
          textFormat: Text.PlainText
          text: root.track ? Model.nowPlayingLabel(root.track) : "YouTube Music"
          color: playerButton.foreground
          opacity: root.track ? 1 : 0.58
          font.family: playerButton.fontFamily
          font.pixelSize: Style.font.body

          readonly property real overflow: Math.max(0, implicitWidth - clipItem.width)

          // Pause, scroll to the end, pause, return — and always rest at 0
          // when not scrolling (the built-in media widget leaves text stuck).
          SequentialAnimation on x {
            id: scroll
            running: label.overflow > 0 && root.playerMode && !root.opened
            loops: Animation.Infinite
            PauseAnimation { duration: 1800 }
            NumberAnimation { from: 0; to: -label.overflow; duration: Math.max(2500, label.overflow * 28); easing.type: Easing.InOutSine }
            PauseAnimation { duration: 1200 }
            NumberAnimation { to: 0; duration: 350; easing.type: Easing.OutCubic }
          }

          onTextChanged: x = 0
        }
      }
    }
  }

  Connections {
    target: scroll
    function onRunningChanged() {
      if (!scroll.running) label.x = 0
    }
  }
}
