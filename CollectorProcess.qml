import QtQuick
import Quickshell.Io

// Own one command until it exits, including cancellation and the case where
// the binary is missing (Quickshell's Process emits nothing then). Bounded
// buffers keep a runaway command out of the shared shell's memory.
//
// Every run gets its own Process and a token. A cancelled run's late `exited`
// (a kill does not stop the signal) carries an old token and is dropped, so it
// can never complete the run that replaced it with an empty buffer.
Item {
  id: root
  property var command: []
  property int timeoutMs: 20000
  property int maxBytes: 1048576
  property bool active: false
  property bool accepting: false
  property bool launched: false
  property string buffer: ""
  property int errorSize: 0
  property int token: 0
  property var current: null
  signal completed(string text)
  signal failed(string reason)

  function start() {
    if (active || !command.length) return
    token++
    buffer = ""; errorSize = 0; accepting = true; active = true; launched = false
    current = worker.createObject(root, {runToken: token, command: command})
    deadline.restart()
    current.running = true
  }
  function stopCurrent() {
    if (current) { current.running = false; current = null }
  }
  function cancel() {
    token++
    accepting = false; buffer = ""; deadline.stop(); active = false
    stopCurrent()
  }
  function reject(reason) {
    if (!accepting) return
    token++
    accepting = false; buffer = ""; active = false
    stopCurrent()
    root.failed(reason)
  }
  Component.onDestruction: cancel()
  Timer {
    id: deadline
    interval: root.timeoutMs
    // A binary that never launched emits nothing; a slow one has a pid.
    onTriggered: root.reject(root.launched ? "timeout" : "nostart")
  }
  Component {
    id: worker
    Process {
      id: proc
      property int runToken: 0
      readonly property bool mine: runToken === root.token
      stdout: SplitParser {
        splitMarker: ""
        onRead: function(chunk) {
          if (!proc.mine || !root.accepting) return
          if (root.buffer.length + chunk.length > root.maxBytes) { root.reject("size"); return }
          root.buffer += chunk
        }
      }
      stderr: SplitParser {
        splitMarker: ""
        onRead: function(chunk) {
          if (!proc.mine || !root.accepting) return
          root.errorSize += chunk.length
          if (root.errorSize > 65536) root.reject("size")
        }
      }
      onStarted: if (proc.mine) root.launched = true
      onExited: function(exitCode) {
        var mine = proc.mine
        proc.destroy()
        if (!mine) return
        deadline.stop()
        root.active = false
        root.current = null
        if (!root.accepting) return
        root.accepting = false
        var out = root.buffer
        root.buffer = ""
        if (exitCode !== 0) root.failed("exit")
        else root.completed(out)
      }
    }
  }
}
