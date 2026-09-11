import QtQuick
import Quickshell
import Quickshell.Io
import "YtmModel.js" as Model

// JSON IPC client for the detached mpv player (bin/ytm-mpv). Commands get an
// optional reply callback; observed properties arrive via propertyUpdated.
// Commands sent while mpv is down start it and are flushed once connected.
// After every (re)connect the observers are registered again, because mpv
// drops them with the connection.
Item {
  id: root

  property string socketPath: ""
  property string controlScript: ""
  property int startVolume: 100
  property var observedProperties: []

  // down | starting | up
  property string mpvState: "down"
  readonly property bool up: mpvState === "up"

  signal propertyUpdated(string name, var value)
  signal event(var message)
  signal ready()

  property int _nextId: 1
  property var _pending: ({})
  property var _queue: []
  property int _attempts: 0
  // The connected Socket. Loader.item is not set yet when a fresh Socket
  // reports its connection, so the instance is passed in by the Socket.
  property var _sock: null

  function command(args, callback) {
    var id = _nextId++
    if (callback) _pending[id] = { callback: callback, deadline: Date.now() + 5000 }
    var line = JSON.stringify({ command: args, request_id: id }) + "\n"
    if (up) {
      _write(line)
      _flush()
    } else {
      _queue.push(line)
      if (mpvState === "down") start()
    }
    if (callback) sweep.start()
    return id
  }

  function commands(list) {
    for (var i = 0; i < list.length; i++) command(list[i])
  }

  function start() {
    if (mpvState !== "down") return
    mpvState = "starting"
    Quickshell.execDetached([controlScript, "start", "--volume", String(startVolume)])
    _attempts = 0
    retry.interval = 150
    retry.restart()
  }

  function stopPlayer() {
    Quickshell.execDetached([controlScript, "stop"])
  }

  // Quickshell's Socket never retries once an attempt has failed (setting
  // `connected` again does nothing), so every attempt gets a fresh Socket.
  function _connect() {
    _sock = null
    socketLoader.active = false
    socketLoader.active = true
  }

  function _write(line) {
    if (_sock) _sock.write(line)
  }

  function _flush() {
    if (_sock) _sock.flush()
  }

  function _handleLine(line) {
    var message = Model.parseMpvLine(line)
    if (!message) return
    if (message.event === "property-change") {
      propertyUpdated(message.name, message.data)
      return
    }
    if (message.event) {
      event(message)
      return
    }
    var pending = message.request_id !== undefined ? _pending[message.request_id] : null
    if (!pending) return
    delete _pending[message.request_id]
    pending.callback(message)
  }

  function _failPending(reason) {
    var pending = _pending
    _pending = ({})
    for (var id in pending) pending[id].callback({ error: reason })
  }

  function _onConnected(sock) {
    _sock = sock
    retry.stop()
    mpvState = "up"
    for (var i = 0; i < observedProperties.length; i++)
      _write(JSON.stringify({ command: ["observe_property", i + 1, observedProperties[i]] }) + "\n")
    var queued = _queue
    _queue = []
    for (var j = 0; j < queued.length; j++) _write(queued[j])
    _flush()
    ready()
  }

  function _onDisconnected(sock) {
    // A replaced Socket going away is not a disconnect.
    if (mpvState !== "up" || sock !== _sock) return
    _sock = null
    mpvState = "down"
    _failPending("disconnected")
    // mpv quit (idle timeout, stop) or is restarting: look once more shortly.
    _attempts = 39
    retry.interval = 500
    retry.restart()
  }

  Component {
    id: socketComponent

    Socket {
      id: socketItem
      path: root.socketPath
      connected: true

      parser: SplitParser {
        onRead: data => root._handleLine(data)
      }

      onConnectionStateChanged: {
        if (connected) root._onConnected(socketItem)
        else root._onDisconnected(socketItem)
      }
    }
  }

  Loader {
    id: socketLoader
    active: false
    sourceComponent: socketComponent
  }

  // Connection attempts while mpv starts (150 ms × 40) or after a drop (one).
  Timer {
    id: retry
    interval: 150
    repeat: true
    onTriggered: {
      if (root.up) {
        retry.stop()
        return
      }
      if (root._attempts++ >= 40) {
        retry.stop()
        root.mpvState = "down"
        root._queue = []
        root._failPending("mpv did not start")
        return
      }
      root._connect()
    }
  }

  // Replies that never come (mpv hung or gone) must not leak callbacks.
  Timer {
    id: sweep
    interval: 1000
    repeat: true
    onTriggered: {
      var now = Date.now()
      var any = false
      for (var id in root._pending) {
        var pending = root._pending[id]
        if (pending.deadline < now) {
          delete root._pending[id]
          pending.callback({ error: "timeout" })
        } else {
          any = true
        }
      }
      if (!any) sweep.stop()
    }
  }

  // Pick up a player that is already running (plugin reload, shell restart).
  Component.onCompleted: if (socketPath !== "") _connect()
}
