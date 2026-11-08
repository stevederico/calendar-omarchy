import QtQuick
import Quickshell
import Quickshell.Io

// Sequential Agent Cloud HTTP via scripts/cloud-events.sh. Key never leaves that script.
Item {
  id: root

  property var queue: []
  property bool inFlight: false
  property int token: 0

  signal finished(string op, bool ok, string body, int token)

  function scriptPath() {
    var url = String(Qt.resolvedUrl("scripts/cloud-events.sh") || "")
    if (url.indexOf("file://") === 0) return url.slice(7)
    return url
  }

  function enqueue(op, args, jobToken) {
    var next = queue.slice()
    next.push({ op: op, args: args, token: jobToken })
    queue = next
    kick()
  }

  // rev: the event's server rev, sent as If-Match. A stale one prints ERROR:conflict.
  function withRev(args, rev) {
    if (rev) args.push("--rev", String(rev))
    return args
  }

  function post(calId, bodyPath, jobToken, rev) {
    enqueue("post", withRev(["post", "--cal", String(calId || ""), "--body-file", String(bodyPath || "")], rev), jobToken)
  }

  function remove(calId, uid, jobToken, rev) {
    enqueue("delete", withRev(["delete", "--cal", String(calId || ""), "--uid", String(uid || "")], rev), jobToken)
  }

  // One date of a repeating event: date YYYY-MM-DD and time HH:MM ("" all-day), as shown.
  function skip(calId, uid, date, time, jobToken, rev) {
    var args = ["skip", "--cal", String(calId || ""), "--uid", String(uid || ""), "--date", String(date || "")]
    if (time) args.push("--time", String(time))
    enqueue("skip", withRev(args, rev), jobToken)
  }

  function kick() {
    if (inFlight) return
    if (queue.length === 0) return
    var job = queue[0]
    var rest = []
    for (var i = 1; i < queue.length; i++) rest.push(queue[i])
    queue = rest
    inFlight = true
    proc.running = false
    proc.op = job.op
    proc.token = job.token
    proc.command = [scriptPath()].concat(job.args)
    proc.running = true
  }

  function done(ok, body) {
    var op = proc.op
    var jobToken = proc.token
    inFlight = false
    finished(op, ok, body, jobToken)
    kick()
  }

  Process {
    id: proc
    property string op: ""
    property int token: 0
    property string lastBody: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: proc.lastBody = String(text || "")
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function (code) {
      var body = proc.lastBody
      proc.lastBody = ""
      var ok = code === 0 && body.indexOf("ERROR:") !== 0
      if (!ok && body.indexOf("ERROR:") !== 0)
        body = body.length ? body : "ERROR:Agent Cloud request failed"
      root.done(ok, body)
    }
  }
}
